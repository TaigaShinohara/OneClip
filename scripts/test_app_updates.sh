#!/bin/bash
# Explicit local integration test only. Never operates on the user's OneClip.app.
# Usage: ONECLIP_RUN_UPDATE_FIXTURE=1 bash scripts/test_app_updates.sh SPARKLE_ROOT IDENTITY MODE [NEW_TMP_DIR]
# MODE is success or signature-reject. No production EdDSA account is accessed.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${ONECLIP_RUN_UPDATE_FIXTURE:-0}" == 1 ]] || { echo 'Set ONECLIP_RUN_UPDATE_FIXTURE=1 to opt in.' >&2; exit 2; }
python3 - "$@" <<'PY'
import base64, functools, hashlib, http.server, json, os, plistlib, re
import shutil, socketserver, subprocess, sys, tempfile, threading, time, uuid
from pathlib import Path
if len(sys.argv) not in (4,5):
    raise SystemExit('Usage: SPARKLE_ROOT DEVELOPER_ID_IDENTITY success|signature-reject [NEW_TMP_DIR]')
sparkle, identity, mode = Path(sys.argv[1]).resolve(), sys.argv[2], sys.argv[3]
if mode not in ('success','signature-reject') or not re.fullmatch(r'[A-Fa-f0-9]{40}', identity):
    raise SystemExit('Use a fixed Developer ID certificate SHA-1 and a known fixture mode.')
if len(sys.argv)==5:
    work=Path(sys.argv[4]).absolute()
    if work.exists() or work.is_symlink() or not work.parent.resolve().is_relative_to(Path('/private/tmp')):
        raise SystemExit('The work path must be new and under /private/tmp.')
    work.mkdir(mode=0o700)
else:
    work=Path(tempfile.mkdtemp(prefix='oneclip-update-fixture.',dir='/private/tmp'))
framework=sparkle/'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
sign=sparkle/'bin/sign_update'
if not framework.is_dir() or not sign.is_file(): raise SystemExit('Sparkle distribution is incomplete.')
env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(Path.home()),'TMPDIR':str(work/'tmp'),'LANG':'C','LC_ALL':'C'}
(work/'tmp').mkdir()
def run(args, *, output=False):
    r=subprocess.run(list(map(str,args)),stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=180)
    if r.returncode:
        # Keep code/tool diagnostics local; never echo credential or signing tool output.
        (work/'last-tool.stdout').write_bytes(r.stdout); (work/'last-tool.stderr').write_bytes(r.stderr)
        raise RuntimeError('fixture_tool_failed:'+Path(str(args[0])).name)
    return r.stdout if output else None
def preflight():
    processes=run(['/bin/ps','-axo','comm='],output=True).decode()
    if re.search(r'xcodebuild|swift-frontend|swift-build|GradleDaemon|ninja',processes):
        raise RuntimeError('another_build_is_active')
    run(['/usr/bin/memory_pressure','-Q']); run(['/bin/df','-h',work])
def inventory(app):
    return {str(p.relative_to(app)):('link',os.readlink(p)) if p.is_symlink() else ('file',hashlib.sha256(p.read_bytes()).hexdigest())
            for p in app.rglob('*') if p.is_symlink() or p.is_file()}
class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*args): pass
http=work/'http'; http.mkdir()
server=socketserver.TCPServer(('127.0.0.1',0),functools.partial(Handler,directory=str(http)))
port=server.server_address[1]
test_id=str(uuid.uuid4()); bundle_id='local.OneClip.UpdateFixture'
old_version=str(time.time_ns()//1_000_000); new_version=str(int(old_version)+1)
key=work/'fixture-key.txt'; public=work/'fixture-public.txt'
keygen=work/'keygen.swift'
keygen.write_text('''import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let privateURL = URL(fileURLWithPath: CommandLine.arguments[1])
try key.rawRepresentation.base64EncodedData().write(to: privateURL, options: .atomic)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateURL.path)
try key.publicKey.rawRepresentation.base64EncodedData().write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
''')
preflight(); run(['/usr/bin/xcrun','swift','-module-cache-path',work/'modules',keygen,key,public])
pubkey=public.read_text().strip()
if len(base64.b64decode(pubkey,validate=True))!=32: raise RuntimeError('invalid_fixture_key')
old=work/'host/UpdateFixture.app'; new=work/'payload/UpdateFixture.app'
for app,version in ((old,old_version),(new,new_version)):
    contents=app/'Contents'; (contents/'MacOS').mkdir(parents=True); (contents/'Frameworks').mkdir()
    run(['/usr/bin/ditto',framework,contents/'Frameworks/Sparkle.framework'])
    info={'CFBundleIdentifier':bundle_id,'CFBundleName':'OneClip Update Fixture','CFBundleExecutable':'UpdateFixture',
          'CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0.0' if version==old_version else '1.0.1',
          'CFBundleVersion':version,'LSUIElement':True,'NSPrincipalClass':'NSApplication','LSMinimumSystemVersion':'14.0',
          'FixtureTestID':test_id,'FixtureExpectedVersion':new_version,'FixtureMode':mode,
          'SUFeedURL':f'http://localhost:{port}/appcast.xml','SUPublicEDKey':pubkey,
          'SUEnableAutomaticChecks':False,'SUAutomaticallyUpdate':False,'SUAllowsAutomaticUpdates':False,
          'SUEnableSystemProfiling':False,'SUShowReleaseNotes':False,'SUEnableJavaScript':False,
          'SUVerifyUpdateBeforeExtraction':True,'SURequireSignedFeed':True,'SUSignedFeedFailureExpirationInterval':0,
          'SUEnableInstallerLauncherService':True,'SUEnableDownloaderService':True,
          'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True}}
    (contents/'Info.plist').write_bytes(plistlib.dumps(info))
    downloader=contents/'Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/Info.plist'
    xpc_info=plistlib.loads(downloader.read_bytes())
    xpc_info.setdefault('NSAppTransportSecurity',{})['NSAllowsLocalNetworking']=True
    downloader.write_bytes(plistlib.dumps(xpc_info))
preflight()
run(['/usr/bin/xcrun','swiftc','-swift-version','6','-strict-concurrency=complete','-parse-as-library',
     '-module-cache-path',work/'modules','-F',framework.parent,'-framework','Sparkle',
     '-Xlinker','-rpath','-Xlinker','@executable_path/../Frameworks','Tests/AppUpdateIntegrationFixture.swift',
     '-o',old/'Contents/MacOS/UpdateFixture'])
shutil.copy2(old/'Contents/MacOS/UpdateFixture',new/'Contents/MacOS/UpdateFixture')
ent=work/'fixture.entitlements'
ent.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,
    'com.apple.security.temporary-exception.mach-lookup.global-name':[bundle_id+'-spks',bundle_id+'-spki']}))
for app in (old,new):
    fw=app/'Contents/Frameworks/Sparkle.framework/Versions/B'
    for target in (fw/'XPCServices/Installer.xpc',fw/'XPCServices/Downloader.xpc',fw/'Autoupdate',fw/'Updater.app',fw.parent.parent):
        args=['/usr/bin/codesign','--force','--sign',identity,'--options','runtime','--timestamp']
        if target.name=='Autoupdate': args+=['--preserve-metadata=entitlements']
        run(args+[target])
    run(['/usr/bin/codesign','--force','--sign',identity,'--options','runtime','--timestamp','--entitlements',ent,app])
    run(['/usr/bin/codesign','--verify','--strict','--deep',app])
archive=http/'UpdateFixture.zip'
run(['/usr/bin/ditto','-c','-k','--sequesterRsrc','--keepParent',new,archive])
signature=run([sign,'--ed-key-file',key,'-p',archive],output=True).decode().strip()
if mode=='signature-reject': signature=base64.b64encode(bytes(64)).decode()
feed=http/'appcast.xml'
feed.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<title>OneClip local integration fixture</title><item><title>Fixture 1.0.1</title>
<sparkle:version>{new_version}</sparkle:version><sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0.0</sparkle:minimumSystemVersion>
<enclosure url="http://localhost:{port}/UpdateFixture.zip" sparkle:edSignature="{signature}" length="{archive.stat().st_size}" type="application/octet-stream" />
</item></channel></rss>''')
run([sign,'--ed-key-file',key,feed]); run([sign,'--ed-key-file',key,'--verify',feed])
before=inventory(old)
receipt=Path.home()/'Library/Containers'/bundle_id/'Data/Library/Application Support/OneClipUpdateFixture'/test_id/'result.json'
thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
try:
    run(['/usr/bin/open','-n','-g',old])
    deadline=time.monotonic()+90
    while not receipt.is_file() and time.monotonic()<deadline: time.sleep(.25)
    if not receipt.is_file(): raise RuntimeError('fixture_receipt_timeout')
    result=json.loads(receipt.read_text())
    expected='passed_relaunch_and_state' if mode=='success' else 'passed_invalid_archive_signature'
    if result.get('status')!=expected: raise RuntimeError('fixture_did_not_pass:'+str(result.get('status')))
    if mode=='signature-reject' and inventory(old)!=before: raise RuntimeError('rejected_update_changed_host')
    if mode=='success' and plistlib.loads((old/'Contents/Info.plist').read_bytes())['CFBundleVersion']!=new_version:
        raise RuntimeError('installed_version_did_not_change')
    summary={'status':'passed','mode':mode,'bundle_id':bundle_id,'test_id':test_id,
             'saved_data_and_settings_retained':mode=='success','old_bundle_unchanged':mode=='signature-reject'}
    (work/'summary.json').write_text(json.dumps(summary,sort_keys=True)+'\n')
    print(json.dumps(summary,sort_keys=True))
finally:
    server.shutdown(); server.server_close(); thread.join(timeout=3)
PY
