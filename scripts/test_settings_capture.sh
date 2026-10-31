#!/bin/bash
# Synthetic services only by default. No capture, TCC changes or general pasteboard access.
set -euo pipefail
cd "$(dirname "$0")/.."
ONECLIP_TEST_DIR="${ONECLIP_TEST_DIR:-$(mktemp -d -t oneclip-settings-tests)}"
mkdir -p "$ONECLIP_TEST_DIR"

preflight() {
    local processes
    processes="$(ps -axo pid=,comm=)"
    if printf '%s\n' "$processes" | rg 'xcodebuild|swift-frontend|swift-build|GradleDaemon|ninja'; then
        echo 'Another build is active; retry after it finishes.' >&2
        exit 1
    fi
    memory_pressure -Q
    df -h . "$ONECLIP_TEST_DIR"
}

# Keep the production wiring in coordinator tests without running the App entry point.
python3 - "$ONECLIP_TEST_DIR/OneClipAppForTests.swift" <<'PY'
from pathlib import Path
import sys
source = Path('OneClip/OneClipApp.swift').read_text()
assert source.count('@main\nstruct OneClipApp') == 1
Path(sys.argv[1]).write_text(source.replace('@main\nstruct OneClipApp', 'struct OneClipApp'))
PY

sources=()
for source in OneClip/*.swift; do
    [[ "$source" == OneClip/OneClipApp.swift ]] || sources+=("$source")
done
tests=("$@")
if [[ ${#tests[@]} == 0 ]]; then
    tests=(CaptureAnnotationsTests CaptureAnnotationControllerTests CaptureArchiveTests CaptureResultControllerTests ProductHotKeyTests SettingsCaptureScopeTests SingleCaptureCoordinatorTests CollectionCaptureCoordinatorTests CollectionPreviewNavigationTests RegionGeometryTests ScreenshotBudgetTests M0ImageCoreTests)
fi
for test in "${tests[@]}"; do
    case "$test" in
        CaptureAnnotationsTests|CaptureAnnotationControllerTests|CaptureResultControllerTests|CaptureArchiveTests|ProductHotKeyTests|SettingsCaptureScopeTests|SingleCaptureCoordinatorTests|CollectionCaptureCoordinatorTests|CollectionPreviewNavigationTests|RegionGeometryTests|ScreenshotBudgetTests|M0ImageCoreTests|CaptureSessionMonitorTests|CaptureConsoleUserMonitorTests|CaptureSessionNotificationTests|M0ClipboardProbeTests) ;;
        *) echo "Unknown test suite: $test" >&2; exit 1 ;;
    esac
    preflight
    xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
        -module-cache-path "$ONECLIP_TEST_DIR/module-cache" \
        "${sources[@]}" "$ONECLIP_TEST_DIR/OneClipAppForTests.swift" "Tests/$test.swift" \
        -o "$ONECLIP_TEST_DIR/$test"
    "$ONECLIP_TEST_DIR/$test"
done
echo "Synthetic settings capture tests passed: $ONECLIP_TEST_DIR"
# Optional window lifecycle test (no screenshots): "$ONECLIP_TEST_DIR/SettingsCaptureScopeTests" --window-lifecycle
# Optional in-memory opaque fixture capture with existing permission only:
# "$ONECLIP_TEST_DIR/SettingsCaptureScopeTests" --capture-fixture
