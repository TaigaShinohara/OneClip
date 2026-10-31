#!/bin/bash
# Build opt-in test executables only. Building does not authorize OS operations or clipboard use.
set -euo pipefail
cd "$(dirname "$0")/.."
ONECLIP_SECURITY_TOOLS_DIR="${ONECLIP_SECURITY_TOOLS_DIR:-$(mktemp -d -t oneclip-security-tools)}"
python3 - "$ONECLIP_SECURITY_TOOLS_DIR" <<'PY'
import hashlib, json, os, stat, sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.exists():
    p.mkdir(mode=0o700, parents=False)
s = p.lstat()
if not stat.S_ISDIR(s.st_mode) or p.is_symlink() or s.st_uid != os.getuid() or any(p.iterdir()):
    raise SystemExit('Security tools require a new, empty, owned directory.')
app = Path('OneClip/OneClipApp.swift').read_text()
assert app.count('@main\nstruct OneClipApp') == 1
(p / 'OneClipAppForTests.swift').write_text(app.replace('@main\nstruct OneClipApp', 'struct OneClipApp'))
inputs = sorted([*Path('OneClip').glob('*.swift'), Path('Tests/M4ResourceOwnershipProbe.swift'),
                 Path('Tests/SecurityRuntimeTrial.swift'), Path('Tests/M4Fixture.swift')])
(p / 'build-inputs.json').write_text(json.dumps(
    {str(q): hashlib.sha256(q.read_bytes()).hexdigest() for q in inputs}, sort_keys=True))
PY

preflight() {
    local processes
    processes="$(ps -axo pid=,comm=)"
    if printf '%s\n' "$processes" | rg 'xcodebuild|swift-frontend|swift-build|GradleDaemon|ninja'; then
        echo 'Another build is active; retry after it finishes.' >&2
        exit 1
    fi
    memory_pressure -Q
    df -h . "$ONECLIP_SECURITY_TOOLS_DIR"
}

sources=()
for source in OneClip/*.swift; do
    [[ "$source" == OneClip/OneClipApp.swift ]] || sources+=("$source")
done
preflight
xcrun swiftc -swift-version 6 -strict-concurrency=complete -O -whole-module-optimization \
    -D ONECLIP_RESOURCE_PRODUCT_STATES -parse-as-library \
    -module-cache-path "$ONECLIP_SECURITY_TOOLS_DIR/module-cache" \
    "${sources[@]}" "$ONECLIP_SECURITY_TOOLS_DIR/OneClipAppForTests.swift" \
    Tests/M4ResourceOwnershipProbe.swift -o "$ONECLIP_SECURITY_TOOLS_DIR/ownership-probe"
preflight
xcrun swiftc -swift-version 6 -strict-concurrency=complete -O -whole-module-optimization \
    -parse-as-library -module-cache-path "$ONECLIP_SECURITY_TOOLS_DIR/module-cache" \
    "${sources[@]}" "$ONECLIP_SECURITY_TOOLS_DIR/OneClipAppForTests.swift" \
    Tests/SecurityRuntimeTrial.swift -o "$ONECLIP_SECURITY_TOOLS_DIR/SecurityRuntimeTrial"
preflight
xcrun swiftc -swift-version 6 -strict-concurrency=complete -O -D DEBUG -parse-as-library \
    -module-cache-path "$ONECLIP_SECURITY_TOOLS_DIR/module-cache" \
    OneClip/CaptureSecurityTrace.swift OneClip/M0ImageCore.swift OneClip/M3PracticeFixture.swift \
    Tests/M4Fixture.swift -o "$ONECLIP_SECURITY_TOOLS_DIR/M4Fixture"
python3 - "$ONECLIP_SECURITY_TOOLS_DIR" <<'PY'
import hashlib, json, subprocess, sys
from pathlib import Path
out = Path(sys.argv[1])
inputs = sorted([*Path('OneClip').glob('*.swift'), Path('Tests/M4ResourceOwnershipProbe.swift'),
                 Path('Tests/SecurityRuntimeTrial.swift'), Path('Tests/M4Fixture.swift')])
hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
assert hashes == json.loads((out / 'build-inputs.json').read_text()), 'Sources changed during compilation.'
source_id = hashlib.sha1(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
manifest = {'schema': 'oneclip-security-tools-v1', 'sourceIDKind': 'build-inputs-sha1',
            'sourceID': source_id, 'inputs': hashes, 'optimization': '-O',
            'toolchain': {'swift': subprocess.run(['/usr/bin/xcrun', 'swiftc', '--version'],
                          capture_output=True, text=True, check=True).stdout.strip(),
                          'sdk': subprocess.run(['/usr/bin/xcrun', '--show-sdk-version'],
                          capture_output=True, text=True, check=True).stdout.strip()},
            'binaries': {name: hashlib.sha256((out / name).read_bytes()).hexdigest()
                         for name in ['ownership-probe', 'SecurityRuntimeTrial', 'M4Fixture']}}
(out / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
print(json.dumps({'status': 'built_not_run', 'sourceID': source_id, 'binaries': manifest['binaries']}, sort_keys=True))
PY
