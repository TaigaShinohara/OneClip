#!/bin/bash
# Build the separate tiny ownership diagnostic; never execute it here.
set -euo pipefail
if [[ $# -ne 1 ]]; then
    echo 'usage: build_owned_backing_tools.sh NEW_OS_TEMP_DIRECTORY' >&2
    exit 2
fi
ONECLIP_BACKING_REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
exec /usr/bin/python3 - "$ONECLIP_BACKING_REPO" "$1" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

repo, output = Path(sys.argv[1]), Path(sys.argv[2]).absolute()
sys.path.insert(0, str(repo / 'scripts'))
import migrate_resource_policy as safe

NAMES = (
    'Tests/OwnedBackingLifetimeProbe.swift',
    'scripts/run_owned_backing_trial.py',
    'scripts/build_owned_backing_tools.sh',
    'scripts/migrate_resource_policy.py',
    'scripts/prepare_resource_observation.py',
    'scripts/resource_policy_migration.py',
    'scripts/run_security_resources.py',
    'scripts/run_security_trial.py',
)
BASE_FLAGS = ['-swift-version', '6', '-strict-concurrency=complete', '-O',
              '-whole-module-optimization', '-parse-as-library']

def inputs():
    return {name: hashlib.sha256(safe.owned_bytes(repo / name, 2_097_152)).hexdigest()
            for name in NAMES}

# Require an already-safe private temp parent, then exclusively create a new child.
parent, parent_fd = safe.private_temp_directory(output.parent)
try:
    os.mkdir(output.name, mode=0o700, dir_fd=parent_fd)
finally:
    os.close(parent_fd)
output, output_fd = safe.private_temp_directory(parent / output.name)
os.close(output_fd)
before = inputs()
sdk = subprocess.check_output(['/usr/bin/xcrun', '--show-sdk-path'], text=True).strip()
swift = subprocess.check_output(['/usr/bin/xcrun', 'swiftc', '--version'], text=True).strip()
if not all(value and len(value) <= 256 and '\x00' not in value for value in (sdk, swift)):
    raise RuntimeError('toolchain_description_invalid')
# The human-readable toolchain field stays one line; no compiler invocation is hidden.
swift = ' '.join(swift.splitlines())
flags = BASE_FLAGS + ['-module-cache-path', str(output / 'module-cache'), '-sdk', sdk]
subprocess.run(['/usr/bin/xcrun', 'swiftc', *flags,
                str(repo / NAMES[0]), '-o', str(output / 'owned-backing-probe')], check=True)
after = inputs()
if before != after:
    raise RuntimeError('build_input_changed')
binary = hashlib.sha256(safe.owned_bytes(output / 'owned-backing-probe',
                                       16_777_216, executable=True)).hexdigest()
manifest = {'schema': 'oneclip-owned-backing-tools-v1', 'inputs': before,
            'binarySHA256': binary, 'toolchain': {'swift': swift, 'sdk': sdk},
            'flags': flags}
_, descriptor = safe.private_temp_directory(output)
try:
    digest = safe.save_new(descriptor, 'manifest.json', manifest)
finally:
    os.close(descriptor)
print(json.dumps({'state': 'built_not_run', 'manifestSHA256': digest,
                  'binarySHA256': binary}, sort_keys=True))
PY
