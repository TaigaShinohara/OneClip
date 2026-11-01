#!/bin/bash
# Build one object-lifetime-only pilot in a new private OS-temp directory. Never run it.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 2 || "$1" != --output-dir ]]; then
    echo 'Usage: build_render_ownership_tools.sh --output-dir NEW_OS_TEMP_DIRECTORY' >&2
    exit 2
fi
ONECLIP_RENDER_OUTPUT="$2"
ONECLIP_RENDER_COMPILER="$(/usr/bin/xcrun --find swiftc)"
python3 -B - "$PWD" "$ONECLIP_RENDER_OUTPUT" "$ONECLIP_RENDER_COMPILER" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts'))
import run_render_ownership_pilot as tool
try:
    tool.prepare_build(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]))
except BaseException:
    raise SystemExit('Render ownership source preparation failed; nothing was built or run.') from None
PY

# Same build/process, memory and disk preflight as the other local security tools.
ONECLIP_RENDER_PROCESSES="$(ps -axo pid=,comm=)"
if printf '%s\n' "$ONECLIP_RENDER_PROCESSES" | rg 'xcodebuild|swift-frontend|swift-build|GradleDaemon|ninja'; then
    echo 'Another build is active; retry after it finishes.' >&2
    exit 1
fi
memory_pressure -Q
df -h . "$ONECLIP_RENDER_OUTPUT"
printf 'SDK version: %s\n' "$(/usr/bin/xcrun --show-sdk-version)"
/usr/bin/xcrun swiftc -swift-version 6 -strict-concurrency=complete -O -whole-module-optimization \
    -parse-as-library -module-cache-path "$ONECLIP_RENDER_OUTPUT/module-cache" \
    "$ONECLIP_RENDER_OUTPUT/CaptureSecurityTrace.swift" \
    "$ONECLIP_RENDER_OUTPUT/M0ImageCore.observed.swift" \
    "$ONECLIP_RENDER_OUTPUT/M4RenderOwnershipPilot.swift" \
    -o "$ONECLIP_RENDER_OUTPUT/render-ownership-pilot"
python3 -B - "$PWD" "$ONECLIP_RENDER_OUTPUT" "$ONECLIP_RENDER_COMPILER" <<'PY'
from pathlib import Path
import json, sys
sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts'))
import run_render_ownership_pilot as tool
try:
    value = tool.finish_build(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]))
except BaseException:
    raise SystemExit('Render ownership binding failed; the pilot was not run.') from None
print(json.dumps({'status':'built_not_run','binarySHA256':value['binarySHA256'],
                  'resourceAcceptance':False}, sort_keys=True))
PY
