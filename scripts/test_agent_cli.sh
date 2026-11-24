#!/bin/bash
# OneClipAgent CLI checks: SwiftPM unit tests + black-box contract tests.
# Operates on temporary fixture roots only. No app data, capture, TCC changes
# or general pasteboard access.
set -euo pipefail
cd "$(dirname "$0")/.."

preflight() {
    local processes
    processes="$(ps -axo pid=,comm=)"
    if printf '%s\n' "$processes" | grep -E 'xcodebuild|swift-frontend|swift-build|GradleDaemon|ninja' | grep -v grep >/dev/null; then
        echo 'Another build is active; retry after it finishes.' >&2
        exit 1
    fi
    df -h . >/dev/null
}

command -v swift >/dev/null 2>&1 || { echo 'swift toolchain not found; install Swift or Xcode.' >&2; exit 2; }

preflight

echo '== swift test (OneClipAgentCore) =='
(cd Tools/OneClipAgent && swift test)

echo '== contract tests (built CLI) =='
BIN="$(cd Tools/OneClipAgent && swift build --show-bin-path)/oneclip-agent"
ONECLIP_AGENT_BIN="$BIN" python3 -m unittest Tests.OneClipAgentContractTests -v

echo 'All OneClipAgent checks passed.'
