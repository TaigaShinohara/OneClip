import AppKit
import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

/// Default: synthetic metadata only. --window-lifecycle adds explicit synthetic NSWindow checks.
/// --capture-fixture explicitly captures only an opaque synthetic fixture, in memory, if already permitted.
/// --grid-oracle draws a detached NSView into a bitmap only: no window, screen, TCC, SCK or board.
/// --grid-oracle-padded checks the same grid inside a 16pt opaque synthetic margin, offscreen only.
/// --capture-grid-padded is a separate explicit SCK ablation; it never replaces --capture-grid.
/// --sampling-oracle checks synthetic normalization/provider-alpha logic, with no OS capture.
/// --capture-sampling[-origins] explicitly compares only a flat opaque synthetic fixture region.
/// No mode requests permission, accesses the clipboard, or delivers input to other apps.
@main
struct SettingsCaptureScopeTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct CaptureFixtureUnavailable: Error { let reason: String }

    @MainActor
    static func main() async throws {
        let oracleModes = ["--grid-oracle", "--grid-oracle-padded", "--sampling-oracle"]
        if CommandLine.arguments.contains(where: { oracleModes.contains($0) }) {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 1, oracleModes.contains(arguments[0]) else {
                print("FAIL GRID-ORACLE: invalid_mode_combination"); exit(2)
            }
            do {
                if arguments[0] == "--sampling-oracle" { try testSamplingOracle() }
                else { try testGridOracle(padded: arguments[0] == "--grid-oracle-padded") }
            }
            catch let failure as Failure { print("FAIL GRID-ORACLE: \(failure.description)"); exit(1) }
            catch { print("FAIL GRID-ORACLE: offscreen_render_failed"); exit(1) }
            return
        }
        let samplingModes = ["--capture-sampling", "--capture-sampling-origins"]
        if CommandLine.arguments.contains(where: { samplingModes.contains($0) }) {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 1, samplingModes.contains(arguments[0]) else {
                print("FAIL CAPTURE-SAMPLING: invalid_mode_combination"); exit(2)
            }
            do { try await testCaptureSampling(includeOrigins: arguments[0] == "--capture-sampling-origins") }
            catch let unavailable as CaptureFixtureUnavailable {
                print("UNAVAILABLE CAPTURE-SAMPLING: \(unavailable.reason)"); exit(77)
            } catch let failure as Failure {
                print("FAIL CAPTURE-SAMPLING: \(failure.description)"); exit(1)
            } catch { print("FAIL CAPTURE-SAMPLING: synthetic_capture_failed"); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--capture-grid-padded"),
           Array(CommandLine.arguments.dropFirst()) != ["--capture-grid-padded"] {
            print("FAIL CAPTURE-GRID-PADDED: invalid_mode_combination"); exit(2)
        }
        let groups: [(String, @MainActor () throws -> Void)] = [
            ("SETTINGS-SCOPE-01 only the explicitly scoped window is admitted", testExactWindow),
            ("SETTINGS-SCOPE-02 missing, duplicated and recycled IDs fail closed", testIdentityRejection),
            ("SETTINGS-SCOPE-03 hidden, moved and resized windows fail closed", testWindowChanges),
            ("SETTINGS-SCOPE-04 malformed metadata cannot widen the capture", testMalformedMetadata),
            ("SETTINGS-SCOPE-05 ordinary requests do not opt into self capture", testDefaultRequest)
        ]
        for (name, test) in groups {
            try test()
            print("PASS \(name)")
        }
        print("PASS \(groups.count) settings scope groups; synthetic metadata only")
        if CommandLine.arguments.contains("--window-lifecycle") {
            do { try testWindowLifecycle() }
            catch {
                print("FAIL WINDOW-LIFECYCLE: synthetic window lifecycle or foreground preservation check failed")
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--capture-fixture") {
            do { try await testCaptureFixture() }
            catch let unavailable as CaptureFixtureUnavailable {
                print("UNAVAILABLE CAPTURE-FIXTURE: \(unavailable.reason)")
                exit(77)
            } catch {
                print("FAIL CAPTURE-FIXTURE: synthetic fixture verification failed")
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--capture-grid") {
            do { try await testCaptureGrid() }
            catch let unavailable as CaptureFixtureUnavailable {
                print("UNAVAILABLE CAPTURE-GRID: \(unavailable.reason)"); exit(77)
            } catch let failure as Failure {
                print("FAIL CAPTURE-GRID: \(failure.description)"); exit(1)
            } catch { print("FAIL CAPTURE-GRID: synthetic pixel or service interval mismatch"); exit(1) }
        }
        if CommandLine.arguments.contains("--capture-grid-padded") {
            do { try await testCaptureGrid(padded: true) }
            catch let unavailable as CaptureFixtureUnavailable {
                print("UNAVAILABLE CAPTURE-GRID-PADDED: \(unavailable.reason)"); exit(77)
            } catch let failure as Failure {
                print("FAIL CAPTURE-GRID-PADDED: \(failure.description)"); exit(1)
            } catch { print("FAIL CAPTURE-GRID-PADDED: synthetic pixel or service interval mismatch"); exit(1) }
        }
    }

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(description: message) }
    }

    static let expectedFrame = CGRect(x: -320, y: 40, width: 540, height: 440)
    static var identity: SettingsCaptureWindowIdentity {
        .init(windowID: 42, processID: 101, quartzFrame: expectedFrame)
    }

    static func window(_ id: CGWindowID = 42, processID: Int32? = 101,
                       frame: CGRect = expectedFrame, visible: Bool = true) -> SettingsCaptureWindowMetadata {
        .init(windowID: id, processID: processID, frame: frame, isOnScreen: visible)
    }

    static func reject(_ windows: [SettingsCaptureWindowMetadata],
                       identity expected: SettingsCaptureWindowIdentity = identity) throws {
        do {
            _ = try expected.matchingIndex(in: windows)
            throw Failure(description: "Unsafe settings metadata was accepted")
        } catch let error as ScreenshotError {
            try expect(error == .settingsUnavailable, "Incorrect failure classification")
        }
    }

    static func testExactWindow() throws {
        // Other OneClip windows and an external window may be listed, but none is an exception.
        let candidates = [window(7), window(8, processID: 202), window(), window(9)]
        let index = try identity.matchingIndex(in: candidates)
        try expect(index == 2 && candidates[index].windowID == 42,
                   "Settings matching admitted a collection panel, overlay, or external window")
        let changedOrder = [window(), window(8, processID: 202)]
        let reorderedIndex = try identity.matchingIndex(in: changedOrder)
        try expect(reorderedIndex == 0, "Matching depended on window order")
    }

    static func testIdentityRejection() throws {
        try reject([])
        try reject([window(7), window(8)])
        try reject([window(), window()])
        try reject([window(), window(processID: 202)])
        try reject([window(processID: 202)])
        try reject([window(processID: nil)])
    }

    static func testWindowChanges() throws {
        try reject([window(visible: false)])
        try reject([window(frame: expectedFrame.offsetBy(dx: 1, dy: 0))])
        try reject([window(frame: expectedFrame.offsetBy(dx: 0, dy: 1))])
        try reject([window(frame: CGRect(x: -320, y: 40, width: 541, height: 440))])
        try reject([window(frame: CGRect(x: -320, y: 40, width: 540, height: 441))])
        // A valid neighbouring window must not substitute for the changed target.
        try reject([window(frame: expectedFrame.offsetBy(dx: 10, dy: 10)), window(43)])
    }

    static func testMalformedMetadata() throws {
        try reject([window(frame: .null)])
        try reject([window(frame: .infinite)])
        try reject([window()], identity: .init(windowID: 0, processID: 101, quartzFrame: expectedFrame))
        try reject([window()], identity: .init(windowID: 42, processID: 0, quartzFrame: expectedFrame))
        try reject([window()], identity: .init(windowID: 42, processID: 101, quartzFrame: .zero))
        try reject([window()], identity: .init(windowID: 42, processID: 101, quartzFrame: .infinite))
    }

    @MainActor
    static func testDefaultRequest() throws {
        let display = try CaptureDisplaySnapshot(id: 1, frame: CGRect(x: 0, y: 0, width: 640, height: 480), scale: 1)
        let selection = try CaptureSelection(display: display, rect: CGRect(x: 20, y: 20, width: 100, height: 80))
        let request = SingleCaptureRequest(selection: selection, operationID: UUID())
        try expect(request.settings == nil, "Normal capture implicitly included a OneClip window")
        #if DEBUG
        try expect(request.practice == nil, "Settings support enabled synthetic practice capture by default")
        #endif
    }

    /// Run only on an explicitly selected interactive test host. An unavailable GUI is a failure,
    /// not an implicit pass; no screen-capture permission is queried or requested.
    @MainActor
    static func testWindowLifecycle() throws {
        let app = NSApplication.shared
        guard app.setActivationPolicy(.accessory), let screen = NSScreen.screens.first,
              screen.visibleFrame.width >= 200, screen.visibleFrame.height >= 160 else {
            throw Failure(description: "WINDOW-LIFECYCLE UNAVAILABLE: an interactive WindowServer and screen are required")
        }
        let originalFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frame = CGRect(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20,
                           width: 160, height: 100)
        let window = SyntheticScopeWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable],
                                          backing: .buffered, defer: false)
        window.title = "OneClip synthetic scope test"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.animationBehavior = .none
        window.backgroundColor = .systemTeal
        window.collectionBehavior = [.stationary, .ignoresCycle]
        defer {
            window.orderOut(nil)
            window.close()
        }
        window.orderBack(nil)
        window.displayIfNeeded()
        guard settleUntil({ window.isVisible && window.screen != nil && window.windowNumber > 0 }) else {
            throw Failure(description: "WINDOW-LIFECYCLE UNAVAILABLE: synthetic window did not become visible")
        }
        try expect(!window.isKeyWindow && !window.isMainWindow, "Synthetic window took keyboard focus")
        let baseline = window.frame
        let owner = ScopeOwnerGeneration()

        @MainActor func newScope() throws -> SettingsCaptureScope {
            let capturedGeneration = owner.value
            return try SettingsCaptureScope(window: window, validate: { owner.value == capturedGeneration })
        }

        let initial = try newScope()
        try expect(initial.validate(), "Visible synthetic window did not produce a valid scope")
        print("PASS WINDOW-LIFECYCLE-01 actual visible window scope")

        window.setFrameOrigin(NSPoint(x: baseline.minX + 8, y: baseline.minY))
        try expect(!initial.validate(), "Moved window retained an earlier scope")
        window.setFrame(baseline, display: false)
        print("PASS WINDOW-LIFECYCLE-02 moved window rejects")

        let beforeResize = try newScope()
        window.setFrame(CGRect(x: baseline.minX, y: baseline.minY,
                               width: baseline.width + 8, height: baseline.height + 8), display: false)
        try expect(!beforeResize.validate(), "Resized window retained an earlier scope")
        window.setFrame(baseline, display: false)
        print("PASS WINDOW-LIFECYCLE-03 resized window rejects")

        let beforeGeneration = try newScope()
        owner.value = UUID()
        try expect(!beforeGeneration.validate(), "Owner invalidation retained an earlier scope")
        let afterGeneration = try newScope()
        try expect(afterGeneration.validate(), "Fresh generation could not issue a valid scope")
        print("PASS WINDOW-LIFECYCLE-04 owner generation rejects stale scopes")

        window.orderOut(nil)
        try expect(!afterGeneration.validate(), "Hidden window retained an earlier scope")
        window.orderBack(nil)
        guard settleUntil({ window.isVisible && window.screen != nil }) else {
            throw Failure(description: "WINDOW-LIFECYCLE UNAVAILABLE: synthetic window could not be shown again")
        }
        print("PASS WINDOW-LIFECYCLE-05 hidden window rejects")

        let beforeClose = try newScope()
        window.close()
        try expect(!beforeClose.validate() && !window.isVisible,
                   "Closed window retained a usable scope or stayed visible")
        owner.value = UUID()
        window.orderBack(nil)
        guard settleUntil({ window.isVisible && window.screen != nil }) else {
            throw Failure(description: "WINDOW-LIFECYCLE UNAVAILABLE: synthetic window could not reopen")
        }
        try expect(!beforeClose.validate(), "Reopened window revived an invalid owner generation")
        print("PASS WINDOW-LIFECYCLE-06 closed window rejects")

        let beforeMiniaturize = try newScope()
        window.miniaturize(nil)
        guard settleUntil({ window.isMiniaturized }) else {
            throw Failure(description: "WINDOW-LIFECYCLE UNAVAILABLE: synthetic window did not miniaturize")
        }
        try expect(!beforeMiniaturize.validate(), "Miniaturized window retained an earlier scope")

        // Close directly from miniaturized state; do not deminiaturize or activate the app.
        window.close()
        try expect(!beforeMiniaturize.validate() && !window.isVisible,
                   "Closed window retained a usable scope or stayed visible")
        try expect(!window.isKeyWindow && !window.isMainWindow, "Synthetic window became a key/main window")
        try expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == originalFrontmost,
                   "Foreground application changed during the synthetic window trial")
        print("PASS WINDOW-LIFECYCLE-07 miniaturized window, cleanup, and foreground preservation")
        print("PASS 7 synthetic NSWindow lifecycle groups; no capture, TCC, or clipboard access")
    }

    @MainActor
    static func testCaptureFixture() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureFixtureUnavailable(reason: "existing screen-capture permission is required; no request was made")
        }
        let app = NSApplication.shared
        guard app.setActivationPolicy(.accessory), let screen = NSScreen.screens.first,
              screen.visibleFrame.width >= 200, screen.visibleFrame.height >= 160 else {
            throw CaptureFixtureUnavailable(reason: "an interactive WindowServer and screen are required")
        }
        let originalFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frame = CGRect(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20, width: 160, height: 100)
        let color = NSColor(srgbRed: 0.2, green: 0.7, blue: 0.3, alpha: 1)
        let fixture = makeFixture(frame: frame, color: color, level: .screenSaver)
        let overlay = makeFixture(frame: CGRect(x: frame.midX, y: frame.minY + 10, width: 80, height: 80),
                                  color: NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1),
                                  level: NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1))
        defer { for window in [overlay, fixture] { window.orderOut(nil); window.close() } }
        fixture.orderFrontRegardless()
        overlay.orderFrontRegardless()
        fixture.displayIfNeeded()
        overlay.displayIfNeeded()
        guard settleUntil({ fixture.isVisible && overlay.isVisible && fixture.isOnActiveSpace && overlay.isOnActiveSpace }) else {
            throw CaptureFixtureUnavailable(reason: "synthetic windows are unavailable in the active Space")
        }
        let scope = try SettingsCaptureScope(window: fixture, validate: {
            fixture.isOpaque && fixture.alphaValue == 1 && fixture.frame == frame
        })
        let display = try ScreenshotService.snapshot(for: screen)
        let selection = try CaptureSelection(display: display, rect: frame.insetBy(dx: 20, dy: 20))
        try expect(scope.validate() && scope.frame.contains(selection.rect), "Crop escaped the opaque fixture")
        let asset = try await ScreenshotService().capture(
            SingleCaptureRequest(selection: selection, operationID: UUID(), settings: scope),
            isCurrent: { scope.validate() && scope.frame.contains(selection.rect) })
        try expect(scope.validate() && scope.frame.contains(selection.rect), "Fixture changed during capture")
        try expect(matchesFixtureColor(asset.image), "Opaque fixture or self-UI exclusion did not match")
        try expect(!fixture.isKeyWindow && !overlay.isKeyWindow
                   && NSWorkspace.shared.frontmostApplication?.processIdentifier == originalFrontmost,
                   "Fixture capture changed foreground focus")
        print("PASS CAPTURE-FIXTURE: in-memory synthetic crop matches; self overlay excluded; foreground preserved")
    }

    @MainActor
    private static func makeFixture(frame: CGRect, color: NSColor, level: NSWindow.Level) -> SyntheticScopeWindow {
        let window = SyntheticScopeWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.level = level
        window.backgroundColor = color
        window.contentView = FixtureColorView(frame: CGRect(origin: .zero, size: frame.size), color: color)
        return window
    }

    @MainActor
    static func testCaptureGrid(padded: Bool = false) async throws {
        // The fixture/oracle must agree before querying permission or creating a visible window.
        try testGridOracle(report: false, padded: padded)
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureFixtureUnavailable(reason: "existing permission required; no request was made")
        }
        let app = NSApplication.shared
        guard app.setActivationPolicy(.accessory), let screen = NSScreen.screens.first,
              screen.visibleFrame.width >= 240, screen.visibleFrame.height >= 180 else {
            throw CaptureFixtureUnavailable(reason: "interactive display required")
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost > 0 else {
            throw CaptureFixtureUnavailable(reason: "grid_foreground_identity_not_established")
        }
        let padding: CGFloat = padded ? 16 : 0
        let frame = CGRect(x: screen.visibleFrame.minX + 24, y: screen.visibleFrame.minY + 24,
                           width: 160 + padding * 2, height: 100 + padding * 2)
        let gridFrame = CGRect(x: frame.minX + padding, y: frame.minY + padding, width: 160, height: 100)
        let fixture = makeFixture(frame: frame, color: padded ? FixturePaddedGridView.marginColor : .black, level: .screenSaver)
        if padded { fixture.contentView = FixturePaddedGridView(frame: CGRect(origin: .zero, size: frame.size)) }
        else { fixture.contentView = FixtureGridView(frame: CGRect(origin: .zero, size: frame.size)) }
        let overlayFrame = CGRect(x: gridFrame.midX, y: gridFrame.midY, width: 60, height: 40)
        let overlay = makeFixture(frame: overlayFrame, color: .magenta, level: .init(rawValue: NSWindow.Level.screenSaver.rawValue + 1))
        defer { for w in [overlay, fixture] { w.orderOut(nil); w.close() } }
        fixture.orderFrontRegardless(); overlay.orderFrontRegardless()
        fixture.displayIfNeeded(); overlay.displayIfNeeded()
        guard settleUntil({ fixture.isVisible && overlay.isVisible && fixture.isOnActiveSpace }) else {
            throw CaptureFixtureUnavailable(reason: "opaque synthetic windows unavailable")
        }
        let scope = try SettingsCaptureScope(window: fixture, validate: { fixture.frame == frame && fixture.isOpaque })
        let display = try ScreenshotService.snapshot(for: screen)
        let scale = display.scale
        let width = Int(gridFrame.width * scale), height = Int(gridFrame.height * scale)
        let overlayID = overlay.windowNumber
        let fence = TrialCaptureFence()
        func current(_ rect: CGRect) -> Bool {
            fence.accepts(scope.validate() && fixture.isVisible && !fixture.isMiniaturized && fixture.isOnActiveSpace
                && fixture.frame == frame && fixture.isOpaque && fixture.alphaValue == 1
                && overlay.isVisible && !overlay.isMiniaturized && overlay.isOnActiveSpace
                && overlay.frame == overlayFrame && overlay.isOpaque && overlay.alphaValue == 1
                && overlay.windowNumber == overlayID && overlay.attachedSheet == nil && (overlay.childWindows?.isEmpty ?? true)
                && frame.contains(rect) && gridFrame.contains(rect) && ScreenshotService.currentDisplayMatches(display)
                && CGPreflightScreenCaptureAccess()
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost)
        }
        let scaleClass = BackingScaleClass(scale)
        print("GRID-CELL schema=grid_pixel_v2 scaleOrdinal=\(scaleClass.ordinal) backingScaleClass=\(scaleClass.rawValue) sampledPointsPerCrop=8 fixture=\(padded ? "inner_grid_padding16" : "window_edge_grid") paddingPoints=\(padded ? 16 : 0) originalFailureResolvedByThisCell=0")
        let crops = gridCrops(width: width, height: height)
        for (cropIndex, crop) in crops.enumerated() {
            let selection = try CaptureSelection(display: display,
                rect: CGRect(x: gridFrame.minX + crop.minX / scale, y: gridFrame.maxY - crop.maxY / scale,
                             width: crop.width / scale, height: crop.height / scale))
            guard current(selection.rect) else { throw CaptureFixtureUnavailable(reason: "grid_pre_capture_fence_not_established") }
            print("GRID-REQUEST captureOrdinal=\(cropIndex) scaleOrdinal=\(scaleClass.ordinal) backingScaleClass=\(scaleClass.rawValue) sourceWidthHalfPoints=\(halfPointUnits(selection.rect.width)) sourceHeightHalfPoints=\(halfPointUnits(selection.rect.height)) outputWidthPixels=\(Int(crop.width)) outputHeightPixels=\(Int(crop.height))")
            let trace = CaptureSecurityTrace(enabled: true)
            let asset: M0ImageAsset
            do {
                asset = try await ScreenshotService().capture(
                    SingleCaptureRequest(selection: selection, operationID: UUID(), settings: scope, securityTrace: trace),
                    isCurrent: { current(selection.rect) })
            } catch {
                guard !fence.failed, current(selection.rect) else {
                    throw CaptureFixtureUnavailable(reason: "grid_capture_fence_not_established")
                }
                throw Failure(description: "grid_capture_service_rejected")
            }
            guard current(selection.rect) else { throw CaptureFixtureUnavailable(reason: "grid_post_capture_fence_not_established") }
            try expect(asset.image.width == Int(crop.width) && asset.image.height == Int(crop.height), "Grid crop dimensions changed")
            do {
                try verifyGrid(asset.image, crop: crop, width: width, height: height,
                               backingScale: scale, cropOrdinal: cropIndex)
            } catch {
                guard current(selection.rect) else { throw CaptureFixtureUnavailable(reason: "grid_observation_fence_not_established") }
                throw error
            }
            guard current(selection.rect) else { throw CaptureFixtureUnavailable(reason: "grid_observation_fence_not_established") }
            let entries = trace.snapshot().entries
            try expect(entries.map(\.code) == [.captureRequested, .captureCallback, .captureReturned], "Actual SCK service interval missing")
            try expect(trace.snapshot().droppedCount == 0, "Grid trace overflow")
        }
        guard current(gridFrame) else { throw CaptureFixtureUnavailable(reason: "grid_final_fence_not_established") }
        if padded {
            print("PASS CAPTURE-GRID-PADDED: 6 inner-grid SCK crops; 16pt opaque margin; original outer-edge failure remains separate")
        } else {
            print("PASS CAPTURE-GRID: 6 real SCK crops; 1px corners, asymmetric quadrants, self-overlay exclusion; in-memory only")
        }
    }

    @MainActor
    final class TrialCaptureFence {
        private(set) var failed = false
        func accepts(_ condition: @autoclosure () -> Bool) -> Bool {
            guard !failed else { return false }
            if !condition() { failed = true }
            return !failed
        }
    }

    struct SamplingCell {
        let ordinal: Int
        let extent: CGFloat
        let outputPixels: Int
        let direct: Bool
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
        var originOrdinal: Int {
            guard [CGFloat(0), 0.5].contains(offsetX), [CGFloat(0), 0.5].contains(offsetY) else { return -1 }
            return (offsetX == 0.5 ? 1 : 0) + (offsetY == 0.5 ? 2 : 0)
        }
    }
    enum ProviderAlpha: Equatable {
        case unknown, opaque, zero, other
        var known: Int { self == .unknown ? 0 : 1 }
        var opaqueCode: Int { self == .unknown ? -1 : self == .opaque ? 1 : 0 }
        var zeroCode: Int { self == .unknown ? -1 : self == .zero ? 1 : 0 }
    }
    struct SamplingResult { let matchesExpected: Bool; let empty: Bool }

    static var samplingCells: [SamplingCell] {
        [.init(ordinal: 0, extent: 0.5, outputPixels: 1, direct: false),
         .init(ordinal: 1, extent: 1, outputPixels: 2, direct: false),
         .init(ordinal: 2, extent: 0.5, outputPixels: 2, direct: true),
         .init(ordinal: 3, extent: 1, outputPixels: 1, direct: true)]
    }

    /// Independent from CGContext normalization. Only bounded 8-bit four-component RGB images
    /// with an explicit byte order and real alpha channel are interpreted; all else is unknown.
    static func providerAlpha(_ image: CGImage) -> ProviderAlpha {
        guard image.width > 0, image.width <= 2, image.height > 0, image.height <= 2,
              image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              image.colorSpace?.model == .rgb, !image.isMask,
              !image.bitmapInfo.contains(.floatComponents),
              image.bytesPerRow >= image.width * 4, image.bytesPerRow <= 4_096 else { return .unknown }
        let order = image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        let alphaIndex: Int
        switch (order, image.alphaInfo) {
        case (CGBitmapInfo.byteOrder32Little.rawValue, .first),
             (CGBitmapInfo.byteOrder32Little.rawValue, .premultipliedFirst): alphaIndex = 3 // BGRA
        case (CGBitmapInfo.byteOrder32Big.rawValue, .last),
             (CGBitmapInfo.byteOrder32Big.rawValue, .premultipliedLast): alphaIndex = 3 // RGBA
        case (CGBitmapInfo.byteOrder32Big.rawValue, .first),
             (CGBitmapInfo.byteOrder32Big.rawValue, .premultipliedFirst): alphaIndex = 0 // ARGB
        case (CGBitmapInfo.byteOrder32Little.rawValue, .last),
             (CGBitmapInfo.byteOrder32Little.rawValue, .premultipliedLast): alphaIndex = 0 // ABGR
        default: return .unknown // No host-endian guesses, skipped-alpha or float interpretation.
        }
        guard let data = image.dataProvider?.data,
              CFDataGetLength(data) >= image.bytesPerRow * image.height,
              CFDataGetLength(data) <= 8_192, let bytes = CFDataGetBytePtr(data) else { return .unknown }
        var allOpaque = true, allZero = true
        for y in 0..<image.height {
            for x in 0..<image.width {
                let alpha = bytes[y * image.bytesPerRow + x * 4 + alphaIndex]
                allOpaque = allOpaque && alpha == 255
                allZero = allZero && alpha == 0
            }
        }
        return allOpaque ? .opaque : allZero ? .zero : .other
    }

    @MainActor
    static func recordSampling(_ image: CGImage, cell: SamplingCell, backingScale: CGFloat,
                               captureOrdinal: Int) throws -> SamplingResult {
        try expect(image.width == cell.outputPixels && image.height == cell.outputPixels, "sampling_output_dimensions")
        let expected = FixtureGridView.colors[0]
        var matches = true, opaque = true, zero = true, hasPartial = false
        for y in 0..<image.height {
            for x in 0..<image.width {
                let observation = observePixel(image, x: x, y: y)
                guard observation.available else {
                    throw Failure(description: "sampling_normalization_unavailable stage=\(observation.stage.rawValue) normalizedAlphaClass=unavailable")
                }
                matches = matches && observation.rgbMatches(expected)
                opaque = opaque && observation.alpha == .opaque
                zero = zero && observation.alpha == .zero
                hasPartial = hasPartial || observation.alpha == .partial
            }
        }
        let raw = providerAlpha(image)
        let palette = [[0, 0, 0, 255]] + FixtureGridView.colors
        let actualClass = palette.firstIndex { pixelMatches(image, x: 0, y: 0, expected: $0) } ?? 5
        let knownEmpty = zero && raw == .zero
        let normalizedAlpha: NormalizedAlpha = opaque ? .opaque : zero ? .zero : hasPartial ? .partial : .mixed
        let scaleClass = BackingScaleClass(backingScale)
        print("SAMPLING-CELL schema=grid_pixel_v2 captureOrdinal=\(captureOrdinal) originOrdinal=\(cell.originOrdinal) scaleOrdinal=\(scaleClass.ordinal) backingScaleClass=\(scaleClass.rawValue) sourceExtentHalfPoints=\(halfPointUnits(cell.extent)) sourcePixelsAtBackingScale=\(scaleClass == .twoX ? halfPointUnits(cell.extent) : -1) normalizedAlphaClass=\(normalizedAlpha.rawValue) normalizedRGBAAvailable=1 normalizationStage=draw_returned cell=\(cell.ordinal) path=\(cell.direct ? "diagnostic_direct_config" : "production_service") halfPointExtent=\(cell.extent == 0.5 ? 1 : 0) outputPixels=\(cell.outputPixels) expectedClass=1 actualClass=\(actualClass) expectedMatch=\(matches && opaque ? 1 : 0) normalizedRGBMatch=\(matches ? 1 : 0) normalizedAlphaOpaque=\(opaque ? 1 : 0) normalizedAlphaZero=\(zero ? 1 : 0) providerAlphaKnown=\(raw.known) providerAlphaOpaque=\(raw.opaqueCode) providerAlphaZero=\(raw.zeroCode) knownEmptyAlphaZero=\(knownEmpty ? 1 : 0)")
        // Empty alpha is the known diagnostic outcome. An opaque wrong color, unsupported
        // provider interpretation on a mismatch, or disagreement cannot be waved through.
        let knownAlphaDisagrees = (opaque && raw != .unknown && raw != .opaque)
            || (zero && raw != .unknown && raw != .zero)
        guard !knownAlphaDisagrees, (matches && opaque) || knownEmpty else {
            throw Failure(description: "sampling_unexpected_pixel cell=\(cell.ordinal)")
        }
        return .init(matchesExpected: matches && opaque, empty: knownEmpty)
    }

    @MainActor
    static func testCaptureSampling(includeOrigins: Bool) async throws {
        try testSamplingOracle()
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureFixtureUnavailable(reason: "existing permission required; no request was made")
        }
        let app = NSApplication.shared
        guard app.setActivationPolicy(.accessory), let screen = NSScreen.screens.first,
              screen.visibleFrame.width >= 240, screen.visibleFrame.height >= 180 else {
            throw CaptureFixtureUnavailable(reason: "interactive display required")
        }
        let display = try ScreenshotService.snapshot(for: screen)
        guard abs(display.scale - 2) <= 0.000_001 else {
            throw CaptureFixtureUnavailable(reason: "sampling ablation requires the selected 2x display")
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost > 0 else {
            throw CaptureFixtureUnavailable(reason: "sampling_foreground_identity_not_established")
        }
        let frame = CGRect(x: screen.visibleFrame.minX + 24, y: screen.visibleFrame.minY + 24, width: 192, height: 132)
        let gridFrame = CGRect(x: frame.minX + 16, y: frame.minY + 16, width: 160, height: 100)
        let uniformFrame = CGRect(x: gridFrame.minX, y: gridFrame.midY, width: 80, height: 50).insetBy(dx: 8, dy: 8)
        let fixture = makeFixture(frame: frame, color: FixturePaddedGridView.marginColor, level: .screenSaver)
        fixture.contentView = FixturePaddedGridView(frame: CGRect(origin: .zero, size: frame.size))
        defer { fixture.orderOut(nil); fixture.close() }
        fixture.orderFrontRegardless(); fixture.displayIfNeeded()
        guard settleUntil({ fixture.isVisible && fixture.isOnActiveSpace }) else {
            throw CaptureFixtureUnavailable(reason: "opaque synthetic fixture unavailable")
        }
        let scope = try SettingsCaptureScope(window: fixture, validate: { fixture.frame == frame && fixture.isOpaque })
        let fence = TrialCaptureFence()
        func current(_ rect: CGRect) -> Bool {
            fence.accepts(scope.validate() && fixture.isVisible && !fixture.isMiniaturized && fixture.isOnActiveSpace
                && fixture.frame == frame && fixture.isOpaque && fixture.alphaValue == 1
                && frame.contains(rect) && gridFrame.contains(rect) && ScreenshotService.currentDisplayMatches(display)
                && CGPreflightScreenCaptureAccess()
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost)
        }
        let reference = try CaptureSelection(display: display, rect: gridFrame)
        guard current(reference.rect) else { throw CaptureFixtureUnavailable(reason: "sampling_reference_fence_not_established") }
        let full: M0ImageAsset
        do {
            full = try await ScreenshotService().capture(
                SingleCaptureRequest(selection: reference, operationID: UUID(), settings: scope),
                isCurrent: { current(reference.rect) })
        } catch {
            guard !fence.failed, current(reference.rect) else {
                throw CaptureFixtureUnavailable(reason: "sampling_reference_fence_not_established")
            }
            throw Failure(description: "sampling_reference_service_rejected")
        }
        guard current(reference.rect) else { throw CaptureFixtureUnavailable(reason: "sampling_reference_fence_not_established") }
        try expect(full.image.width == 320 && full.image.height == 200, "sampling_reference_dimensions")
        do {
            try verifyGrid(full.image, crop: CGRect(x: 0, y: 0, width: 320, height: 200),
                           width: 320, height: 200, backingScale: display.scale, cropOrdinal: 0)
        } catch {
            guard current(reference.rect) else { throw CaptureFixtureUnavailable(reason: "sampling_reference_observation_fence_not_established") }
            throw error
        }
        guard current(reference.rect) else { throw CaptureFixtureUnavailable(reason: "sampling_reference_observation_fence_not_established") }
        print("SAMPLING-REFERENCE schema=grid_pixel_v2 captureOrdinal=0 scaleOrdinal=1 backingScaleClass=two_x sourceWidthHalfPoints=320 sourceHeightHalfPoints=200 outputWidthPixels=320 outputHeightPixels=200 sampledPoints=8 passed=1 captures=1 fixture=inner_grid_padding16 originalFailureResolved=0")
        let captureLimit = includeOrigins ? 8 : 5
        var completed = 1
        var outcomes: [SamplingResult] = []
        func run(_ cell: SamplingCell) async throws -> SamplingResult {
            let rect = CGRect(x: gridFrame.minX + 16 + cell.offsetX,
                              y: gridFrame.maxY - 16 - cell.offsetY - cell.extent,
                              width: cell.extent, height: cell.extent)
            guard current(rect), uniformFrame.contains(rect), completed < captureLimit else {
                throw CaptureFixtureUnavailable(reason: "sampling_pre_capture_scope_or_count_fence_not_established")
            }
            let selection = try CaptureSelection(display: display, rect: rect)
            let asset: M0ImageAsset
            do {
                if cell.direct {
                    asset = try await diagnosticSamplingCapture(selection: selection, settings: scope,
                        outputPixels: cell.outputPixels, isCurrent: { current(rect) && uniformFrame.contains(rect) })
                } else {
                    asset = try await ScreenshotService().capture(
                        SingleCaptureRequest(selection: selection, operationID: UUID(), settings: scope),
                        isCurrent: { current(rect) && uniformFrame.contains(rect) })
                }
            } catch {
                guard !fence.failed, current(rect), uniformFrame.contains(rect) else {
                    throw CaptureFixtureUnavailable(reason: "sampling_capture_fence_not_established")
                }
                throw Failure(description: "sampling_capture_service_rejected")
            }
            completed += 1
            guard current(rect), uniformFrame.contains(rect) else { throw CaptureFixtureUnavailable(reason: "sampling_post_capture_fence_not_established") }
            let result: SamplingResult
            do { result = try recordSampling(asset.image, cell: cell, backingScale: display.scale, captureOrdinal: completed - 1) }
            catch {
                guard current(rect), uniformFrame.contains(rect) else { throw CaptureFixtureUnavailable(reason: "sampling_observation_fence_not_established") }
                throw error
            }
            guard current(rect), uniformFrame.contains(rect) else { throw CaptureFixtureUnavailable(reason: "sampling_observation_fence_not_established") }
            return result
        }
        for cell in samplingCells { outcomes.append(try await run(cell)) }
        let needsOrigins = outcomes.contains(where: \.empty) && outcomes[1].matchesExpected
        if includeOrigins && needsOrigins {
            for (index, offset) in [(CGFloat(0.5), CGFloat(0)), (0, 0.5), (0.5, 0.5)].enumerated() {
                _ = try await run(.init(ordinal: index + 4, extent: 1, outputPixels: 2, direct: false,
                                       offsetX: offset.0, offsetY: offset.1))
            }
        }
        guard current(gridFrame), completed <= captureLimit else { throw CaptureFixtureUnavailable(reason: "sampling_final_fence_not_established") }
        print("DONE CAPTURE-SAMPLING captures=\(completed) maximumCaptures=\(captureLimit) retries=0 originsRequested=\(includeOrigins ? 1 : 0) originsNeeded=\(needsOrigins ? 1 : 0) knownEmptyCells=\(outcomes.filter(\.empty).count) diagnosticOnly=1 originalFailureResolved=0")
    }

    /// Test-only SCK configuration ablation. Rebuild the same display/excluded-app filter with
    /// exactly this live opaque fixture as the sole self-window exception; never widen on failure.
    @MainActor
    static func diagnosticSamplingCapture(selection: CaptureSelection, settings: SettingsCaptureScope,
                                           outputPixels: Int, isCurrent: @escaping @MainActor () -> Bool)
        async throws -> M0ImageAsset {
        guard [1, 2].contains(outputPixels), isCurrent(), settings.validate(),
              settings.frame.contains(selection.rect), ScreenshotService.currentDisplayMatches(selection.display),
              let primary = NSScreen.screens.first else { throw Failure(description: "sampling_direct_initial_fence") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard isCurrent(), settings.validate(), ScreenshotService.currentDisplayMatches(selection.display),
              let display = content.displays.first(where: { $0.displayID == selection.display.id }),
              display.frame == CGDisplayBounds(selection.display.id),
              CGFloat(display.width) == selection.display.frame.width,
              CGFloat(display.height) == selection.display.frame.height else {
            throw Failure(description: "sampling_direct_metadata_fence")
        }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        guard own.count == 1, let application = own.first else { throw Failure(description: "sampling_direct_self_missing") }
        let quartzFrame = CGRect(x: settings.frame.minX, y: primary.frame.maxY - settings.frame.maxY,
                                 width: settings.frame.width, height: settings.frame.height)
        let identity = SettingsCaptureWindowIdentity(windowID: settings.windowID,
            processID: ProcessInfo.processInfo.processIdentifier, quartzFrame: quartzFrame)
        let metadata = content.windows.map { SettingsCaptureWindowMetadata(windowID: $0.windowID,
            processID: $0.owningApplication?.processID, frame: $0.frame, isOnScreen: $0.isOnScreen) }
        let window = content.windows[try identity.matchingIndex(in: metadata)]
        let filter = SCContentFilter(display: display, excludingApplications: [application], exceptingWindows: [window])
        guard abs(CGFloat(filter.pointPixelScale) - selection.display.scale) <= 0.000_001 else {
            throw Failure(description: "sampling_direct_scale_fence")
        }
        let plan = try RegionGeometry.plan(selection: selection, filterScale: CGFloat(filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = plan.sourceRect
        configuration.width = outputPixels; configuration.height = outputPixels
        configuration.pixelFormat = kCVPixelFormatType_32BGRA; configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false; configuration.capturesAudio = false
        configuration.ignoreShadowsDisplay = true; configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        if #available(macOS 14.2, *) { configuration.includeChildWindows = false }
        guard isCurrent(), settings.validate() else { throw Failure(description: "sampling_direct_request_fence") }
        let scale = Double(selection.display.scale)
        let asset: M0ImageAsset = try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                guard error == nil, let image else { continuation.resume(throwing: ScreenshotError.captureFailed); return }
                continuation.resume(returning: M0ImageAsset(image: image, scale: scale))
            }
        }
        guard isCurrent(), settings.validate(), asset.image.width == outputPixels, asset.image.height == outputPixels,
              asset.image.bitsPerComponent == 8, asset.image.bitsPerPixel == 32,
              !asset.image.bitmapInfo.contains(.floatComponents), asset.image.colorSpace?.name == CGColorSpace.sRGB else {
            throw Failure(description: "sampling_direct_result_fence")
        }
        return asset
    }

    static func gridCrops(width: Int, height: Int) -> [CGRect] {
        [CGRect(x: 0, y: 0, width: width, height: height),
         CGRect(x: 0, y: 0, width: 1, height: 1),
         CGRect(x: width - 1, y: 0, width: 1, height: 1),
         CGRect(x: 0, y: height - 1, width: 1, height: 1),
         CGRect(x: width - 1, y: height - 1, width: 1, height: 1),
         CGRect(x: 1, y: 1, width: width - 2, height: height - 2)]
    }

    @MainActor
    static func verifyGrid(_ image: CGImage, crop: CGRect, width: Int, height: Int,
                           backingScale: CGFloat, cropOrdinal: Int) throws {
        try expect(backingScale.isFinite && backingScale > 0, "grid_oracle_scale_unavailable")
        let samples: [(Int, Int)] = [(0, 0), (image.width - 1, 0), (0, image.height - 1),
            (image.width - 1, image.height - 1), (image.width / 4, image.height / 4),
            (image.width * 3 / 4, image.height / 4), (image.width / 4, image.height * 3 / 4),
            (image.width * 3 / 4, image.height * 3 / 4)]
        for (sampleOrdinal, sample) in samples.enumerated() {
            let (x, y) = sample
            let gx = Int(crop.minX) + x, gy = Int(crop.minY) + y
            let border = gx == 0 || gy == 0 || gx == width - 1 || gy == height - 1
            let expectedClass = border ? 0 : 1 + (gy < height / 2 ? 0 : 2) + (gx < width / 2 ? 0 : 1)
            let palette = [[0, 0, 0, 255]] + FixtureGridView.colors
            let observation = observePixel(image, x: x, y: y)
            guard observation.matchesOpaqueFixture(palette[expectedClass]) else {
                // Legacy palette ordinals are display-only. Acceptance requires a completed
                // normalized read, RGB tolerance and exact opaque alpha, independently.
                let actualClass = palette.firstIndex { observation.matchesOpaqueFixture($0) } ?? 5
                let raw = providerAlpha(image)
                let scaleClass = BackingScaleClass(backingScale)
                throw Failure(description: "grid_sample_mismatch schema=grid_pixel_v2 scaleOrdinal=\(scaleClass.ordinal) backingScaleClass=\(scaleClass.rawValue) cropOrdinal=\(cropOrdinal) sampleOrdinal=\(sampleOrdinal) outputWidthPixels=\(image.width) outputHeightPixels=\(image.height) sourceWidthHalfPoints=\(halfPointUnits(CGFloat(image.width) / backingScale)) sourceHeightHalfPoints=\(halfPointUnits(CGFloat(image.height) / backingScale)) expectedClass=\(expectedClass) actualClass=\(actualClass) normalizationStage=\(observation.stage.rawValue) normalizedRGBAAvailable=\(observation.available ? 1 : 0) normalizedAlphaClass=\(observation.alpha.rawValue) normalizedAlphaOpaque=\(observation.alpha.opaqueCode) normalizedAlphaZero=\(observation.alpha.zeroCode) providerAlphaKnown=\(raw.known) providerAlphaOpaque=\(raw.opaqueCode) providerAlphaZero=\(raw.zeroCode) providerScope=whole_image_up_to_2px expectedMatch=0 originalFailureResolved=0")
            }
        }
    }

    @MainActor
    static func testSamplingOracle() throws {
        try testGridOracle(report: false, padded: true)
        try testPixelObservationControls()
        let layouts: [(CGBitmapInfo, CGImageAlphaInfo, [Int])] = [
            (.byteOrder32Little, .premultipliedFirst, [2, 1, 0, 3]), // BGRA
            (.byteOrder32Big, .premultipliedLast, [0, 1, 2, 3]), // RGBA
            (.byteOrder32Big, .premultipliedFirst, [3, 0, 1, 2]), // ARGB
            (.byteOrder32Little, .premultipliedLast, [3, 2, 1, 0])] // ABGR
        for (order, info, indices) in layouts {
            for alpha in [UInt8(0), 127, 255] {
                let rgba = [UInt8(204 * Int(alpha) / 255), UInt8(26 * Int(alpha) / 255),
                            UInt8(51 * Int(alpha) / 255), alpha]
                let image = try alphaFixture(bytes: indices.map { rgba[$0] }, order: order, alpha: info)
                let expected: ProviderAlpha = alpha == 0 ? .zero : alpha == 255 ? .opaque : .other
                try expect(providerAlpha(image) == expected, "sampling_oracle_provider_alpha_mismatch")
                if alpha == 0 || alpha == 255 {
                    try expect(renderedPixel(image, x: 0, y: 0)?.last == alpha,
                               "sampling_oracle_normalized_alpha_mismatch")
                }
            }
        }
        for (order, info) in [(CGBitmapInfo.byteOrderDefault, CGImageAlphaInfo.premultipliedFirst),
                              (.byteOrder32Little, .noneSkipFirst)] {
            let image = try alphaFixture(bytes: [0, 0, 0, 255], order: order, alpha: info)
            try expect(providerAlpha(image) == .unknown, "sampling_oracle_unknown_format_guessed")
        }
        let canvas = try renderGridOffscreen(scale: 2, padded: true)
        let grid = try oracleInnerGrid(canvas, scale: 2, padded: true)
        for cell in samplingCells {
            guard let part = grid.cropping(to: CGRect(x: 32, y: 32, width: cell.extent * 2, height: cell.extent * 2)),
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: cell.outputPixels, height: cell.outputPixels,
                    bitsPerComponent: 8, bytesPerRow: cell.outputPixels * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw Failure(description: "sampling_oracle_context_failed") }
            context.interpolationQuality = .none
            context.draw(part, in: CGRect(x: 0, y: 0, width: cell.outputPixels, height: cell.outputPixels))
            guard let image = context.makeImage() else { throw Failure(description: "sampling_oracle_image_failed") }
            try expect(providerAlpha(image) == .opaque, "sampling_oracle_output_alpha_mismatch")
            for y in 0..<cell.outputPixels {
                for x in 0..<cell.outputPixels {
                    try expect(pixelMatches(image, x: x, y: y, expected: FixtureGridView.colors[0]),
                               "sampling_oracle_flat_color_mismatch")
                }
            }
        }
        print("PASS SAMPLING-ORACLE alphaControls=14 flatColorResamplingCells=4 captures=0 offscreenOnly=1")
    }

    /// Pure controls for the same observation path used by live diagnostics. These are not
    /// SCK evidence: they establish only that an unavailable read cannot become an opaque PASS.
    @MainActor
    static func testPixelObservationControls() throws {
        let black = [0, 0, 0, 255]
        for alpha in [UInt8(0), 1, 127, 247, 254, 255] {
            let image = try alphaFixture(bytes: [0, 0, 0, alpha], order: .byteOrder32Big, alpha: .premultipliedLast)
            let observation = observePixel(image, x: 0, y: 0)
            let expected: NormalizedAlpha = alpha == 0 ? .zero : alpha == 255 ? .opaque : .partial
            try expect(observation.stage == .drawReturned && observation.available && observation.alpha == expected,
                       "pixel_observation_alpha_class_mismatch")
            try expect(observation.rgbMatches(black), "pixel_observation_rgb_tolerance_included_alpha")
            try expect(observation.matchesOpaqueFixture(black) == (alpha == 255)
                       && pixelMatches(image, x: 0, y: 0, expected: black) == (alpha == 255),
                       "pixel_observation_nonopaque_fixture_accepted")
        }
        for red in [UInt8(8), 9] {
            let image = try alphaFixture(bytes: [red, 0, 0, 255], order: .byteOrder32Big, alpha: .premultipliedLast)
            try expect(pixelMatches(image, x: 0, y: 0, expected: black) == (red == 8),
                       "pixel_observation_rgb_tolerance_boundary_changed")
        }
        for alpha in [UInt8(250), 254, 255] {
            let rgba = [UInt8(51 * Int(alpha) / 255), UInt8(179 * Int(alpha) / 255),
                        UInt8(77 * Int(alpha) / 255), alpha]
            let image = try alphaFixture(bytes: rgba, order: .byteOrder32Big, alpha: .premultipliedLast)
            try expect(matchesFixtureColor(image) == (alpha == 255), "uniform_fixture_nonopaque_alpha_accepted")
        }
        let image = try alphaFixture(bytes: [0, 0, 0, 255], order: .byteOrder32Big, alpha: .premultipliedLast)
        let unavailable: [(PixelObservation, PixelNormalizationStage)] = [
            (observePixel(image, x: -1, y: 0), .invalidCoordinates),
            (observePixel(image, x: 0, y: 0, cropper: { _, _ in nil }), .cropUnavailable),
            (observePixel(image, x: 0, y: 0, colorSpaceFactory: { nil }), .colorSpaceUnavailable),
            (observePixel(image, x: 0, y: 0, contextFactory: { _, _ in nil }), .contextUnavailable)]
        for (observation, stage) in unavailable {
            try expect(observation.stage == stage && !observation.available && observation.bytes == nil
                       && observation.alpha == .unavailable && observation.alpha.opaqueCode == -1
                       && observation.alpha.zeroCode == -1 && !observation.matchesOpaqueFixture(black),
                       "pixel_observation_unavailable_read_became_known_alpha_or_pass")
        }
        let observed = observePixel(image, x: 0, y: 0)
        try expect(!observed.matchesOpaqueFixture([]), "pixel_observation_missing_expected_channels_accepted")
        try expect(!observed.matchesOpaqueFixture([0, 0, 0, 0]), "pixel_observation_nonopaque_expectation_accepted")
        let metadata = [BackingScaleClass(2).ordinal == 1, BackingScaleClass(2) == .twoX,
            halfPointUnits(0.5) == 1, halfPointUnits(1) == 2, halfPointUnits(0.25) == -1,
            halfPointUnits(.nan) == -1,
            SamplingCell(ordinal: 6, extent: 1, outputPixels: 2, direct: false, offsetX: 0.5, offsetY: 0.5).originOrdinal == 3]
        try expect(metadata.allSatisfy { $0 }, "pixel_observation_scale_or_origin_unit_metadata_mismatch")
        let fence = TrialCaptureFence()
        try expect(fence.accepts(true), "pixel_observation_valid_capture_fence_rejected")
        try expect(!fence.accepts(false) && fence.failed, "pixel_observation_failed_capture_fence_not_latched")
        try expect(!fence.accepts(true), "pixel_observation_failed_capture_trial_resumed")
        print("PASS PIXEL-OBSERVATION-ORACLE strictAlphaControls=6 rgbControls=2 uniformFixtureControls=3 unavailableControls=4 invalidExpectedControls=2 metadataControls=7 captureFenceControls=3 captures=0 offscreenOnly=1 originalFailureResolved=0")
    }

    static func alphaFixture(bytes: [UInt8], order: CGBitmapInfo, alpha: CGImageAlphaInfo) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: order.rawValue | alpha.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw Failure(description: "sampling_oracle_alpha_fixture_failed")
        }
        return image
    }

    /// Exercise the actual fixture NSView.draw and independent top-left pixel oracle at 1x/2x.
    /// No NSApplication, NSScreen, NSWindow or capture service is constructed here.
    @MainActor
    static func testGridOracle(report: Bool = true, padded: Bool = false) throws {
        for (scaleOrdinal, scale) in [CGFloat(1), 2].enumerated() {
            let width = Int(160 * scale), height = Int(100 * scale)
            let canvas = try renderGridOffscreen(scale: scale, padded: padded)
            let image = try oracleInnerGrid(canvas, scale: scale, padded: padded)
            try expect(image.width == width && image.height == height, "grid_oracle_dimensions")
            if padded {
                for point in [(0, 0), (canvas.width - 1, 0), (0, canvas.height - 1), (canvas.width - 1, canvas.height - 1)] {
                    try expect(pixelMatches(canvas, x: point.0, y: point.1, expected: FixtureGridView.colors[1]),
                               "grid_oracle_margin_color_or_opacity_mismatch")
                }
            }
            let crops = gridCrops(width: width, height: height)
            for (cropOrdinal, crop) in crops.enumerated() {
                guard let part = image.cropping(to: crop) else { throw Failure(description: "grid_oracle_crop_failed") }
                try verifyGrid(part, crop: crop, width: width, height: height,
                               backingScale: scale, cropOrdinal: cropOrdinal)
            }
            // Counterevidence: the same checker must reject a known incorrect two-pixel border.
            // The interior crop's corners distinguish it from the required one-pixel border.
            let wrongCanvas = try renderGridOffscreen(scale: scale, borderPixels: 2, padded: padded)
            let wrongBorder = try oracleInnerGrid(wrongCanvas, scale: scale, padded: padded)
            guard let part = wrongBorder.cropping(to: crops[5]) else {
                throw Failure(description: "grid_oracle_negative_crop_failed")
            }
            var rejectedWrongBorder = false
            do { try verifyGrid(part, crop: crops[5], width: width, height: height,
                               backingScale: scale, cropOrdinal: 5) }
            catch is Failure { rejectedWrongBorder = true }
            try expect(rejectedWrongBorder, "grid_oracle_wrong_border_accepted")
            if report { print("PASS GRID-ORACLE scaleOrdinal=\(scaleOrdinal) backingScaleClass=\(BackingScaleClass(scale).rawValue) fixture=\(padded ? "inner_grid_padding16" : "window_edge_grid") crops=6 samples=48 wrongBorderRejected=1 offscreenOnly=1 originalFailureResolvedByThisCell=0") }
        }
    }

    static func oracleInnerGrid(_ canvas: CGImage, scale: CGFloat, padded: Bool) throws -> CGImage {
        guard padded else { return canvas }
        guard let image = canvas.cropping(to: CGRect(x: 16 * scale, y: 16 * scale,
                                                     width: 160 * scale, height: 100 * scale)) else {
            throw Failure(description: "grid_oracle_inner_crop_failed")
        }
        return image
    }

    @MainActor
    static func renderGridOffscreen(scale: CGFloat, borderPixels: CGFloat = 1, padded: Bool = false) throws -> CGImage {
        let width = Int((padded ? 192 : 160) * scale), height = Int((padded ? 132 : 100) * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw Failure(description: "grid_oracle_context_failed") }
        // A bitmap CGContext already maps its unflipped drawing coordinates into a CGImage.
        // Match the product fixture's bottom-left NSView coordinates without a second flip.
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        if padded {
            let view = FixturePaddedGridView(frame: CGRect(x: 0, y: 0, width: 192, height: 132),
                                             fixtureScale: scale, borderPixels: borderPixels)
            view.draw(view.bounds)
            // Calling NSView.draw directly does not traverse subviews. Reproduce the fixed
            // child-frame transform explicitly, then invoke the real child NSView.draw too.
            context.saveGState()
            context.translateBy(x: view.grid.frame.minX, y: view.grid.frame.minY)
            view.grid.draw(view.grid.bounds)
            context.restoreGState()
        } else {
            let view = FixtureGridView(frame: CGRect(x: 0, y: 0, width: 160, height: 100),
                                      fixtureScale: scale, borderPixels: borderPixels)
            view.draw(view.bounds)
        }
        guard let image = context.makeImage() else { throw Failure(description: "grid_oracle_image_failed") }
        return image
    }

    enum PixelNormalizationStage: String {
        case drawReturned = "draw_returned"
        case invalidCoordinates = "invalid_coordinates"
        case cropUnavailable = "crop_unavailable"
        case colorSpaceUnavailable = "color_space_unavailable"
        case contextUnavailable = "context_unavailable"
    }

    enum NormalizedAlpha: String {
        case unavailable, zero, partial, mixed, opaque
        var opaqueCode: Int { self == .unavailable ? -1 : self == .opaque ? 1 : 0 }
        var zeroCode: Int { self == .unavailable ? -1 : self == .zero ? 1 : 0 }
    }

    struct PixelObservation {
        let stage: PixelNormalizationStage
        // Ephemeral normalized test bytes. Diagnostics may emit only classifications below.
        let bytes: [UInt8]?
        var available: Bool { stage == .drawReturned && bytes?.count == 4 }
        var alpha: NormalizedAlpha {
            guard available, let bytes else { return .unavailable }
            return bytes[3] == 0 ? .zero : bytes[3] == 255 ? .opaque : .partial
        }
        func rgbMatches(_ expected: [Int]) -> Bool {
            guard available, let bytes, expected.count == 4 else { return false }
            return (0..<3).allSatisfy { abs(Int(bytes[$0]) - expected[$0]) <= 8 }
        }
        func matchesOpaqueFixture(_ expected: [Int]) -> Bool {
            expected.count == 4 && expected[3] == 255 && alpha == .opaque && rgbMatches(expected)
        }
    }

    enum BackingScaleClass: String {
        case oneX = "one_x", twoX = "two_x", other
        init(_ scale: CGFloat) { self = scale == 1 ? .oneX : scale == 2 ? .twoX : .other }
        var ordinal: Int { self == .oneX ? 0 : self == .twoX ? 1 : 2 }
    }

    /// Fixed unit labels avoid confusing ordinal 1 with a physical 1x display. Unknown or
    /// nonrepresentable half-point sizes are marked -1, never rounded into known metadata.
    static func halfPointUnits(_ points: CGFloat) -> Int {
        let units = points * 2
        guard units.isFinite, units >= 0, units < CGFloat(Int.max), units.rounded() == units else { return -1 }
        return Int(units)
    }

    static func pixelMatches(_ image: CGImage, x: Int, y: Int, expected: [Int]) -> Bool {
        observePixel(image, x: x, y: y).matchesOpaqueFixture(expected)
    }

    /// The actual crop/context boundaries are independently replaceable only in this test file.
    /// A failed read never becomes alpha zero, a palette class, or an accepted fixture sample.
    static func observePixel(_ image: CGImage, x: Int, y: Int,
        cropper: (CGImage, CGRect) -> CGImage? = { $0.cropping(to: $1) },
        colorSpaceFactory: () -> CGColorSpace? = { CGColorSpace(name: CGColorSpace.sRGB) },
        contextFactory: (UnsafeMutableRawPointer?, CGColorSpace) -> CGContext? = { pointer, space in
            CGContext(data: pointer, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        }) -> PixelObservation {
        guard x >= 0, y >= 0, x < image.width, y < image.height else {
            return .init(stage: .invalidCoordinates, bytes: nil)
        }
        guard let pixel = cropper(image, CGRect(x: x, y: y, width: 1, height: 1)) else {
            return .init(stage: .cropUnavailable, bytes: nil)
        }
        guard let space = colorSpaceFactory() else { return .init(stage: .colorSpaceUnavailable, bytes: nil) }
        var bytes: [UInt8] = [0, 0, 0, 0]
        let returned = bytes.withUnsafeMutableBytes { memory -> Bool in
            guard let context = contextFactory(memory.baseAddress, space) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true // The API returned; it does not report whether a source provider decoded.
        }
        return returned ? .init(stage: .drawReturned, bytes: bytes) : .init(stage: .contextUnavailable, bytes: nil)
    }

    /// Compatibility for alpha controls only; fixture acceptance always uses PixelObservation.
    static func renderedPixel(_ image: CGImage, x: Int, y: Int) -> [UInt8]? {
        observePixel(image, x: x, y: y).bytes
    }

    static func matchesFixtureColor(_ image: CGImage) -> Bool {
        guard image.width > 0, image.height > 0, image.width <= 640, image.height <= 400,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { return false }
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let redMatches = abs(Int(pixels[offset]) - 51) <= 8
            let greenMatches = abs(Int(pixels[offset + 1]) - 179) <= 8
            let blueMatches = abs(Int(pixels[offset + 2]) - 77) <= 8
            guard redMatches && greenMatches && blueMatches && pixels[offset + 3] == 255 else { return false }
        }
        return true
    }

    @MainActor
    static func settleUntil(_ condition: () -> Bool) -> Bool {
        for _ in 0..<30 {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}

@MainActor
private final class ScopeOwnerGeneration {
    var value = UUID()
}

@MainActor
private final class SyntheticScopeWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class FixtureColorView: NSView {
    let color: NSColor
    init(frame: CGRect, color: NSColor) { self.color = color; super.init(frame: frame) }
    required init?(coder: NSCoder) { return nil }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
}

@MainActor
private final class FixturePaddedGridView: NSView {
    // Reuse the fixed fixture-green class; a padding sample can be classified without raw RGB.
    static var marginColor: NSColor {
        let color = FixtureGridView.colors[1]
        return NSColor(srgbRed: CGFloat(color[0]) / 255, green: CGFloat(color[1]) / 255,
                       blue: CGFloat(color[2]) / 255, alpha: 1)
    }
    let grid: FixtureGridView
    init(frame: CGRect, fixtureScale: CGFloat? = nil, borderPixels: CGFloat = 1) {
        grid = FixtureGridView(frame: CGRect(x: 16, y: 16, width: 160, height: 100),
                               fixtureScale: fixtureScale, borderPixels: borderPixels)
        super.init(frame: frame)
        addSubview(grid)
    }
    required init?(coder: NSCoder) { return nil }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { Self.marginColor.setFill(); bounds.fill() }
}

@MainActor
private final class FixtureGridView: NSView {
    static let colors = [[204, 26, 51, 255], [26, 191, 51, 255], [26, 51, 204, 255], [217, 191, 26, 255]]
    private let fixtureScale: CGFloat?
    private let borderPixels: CGFloat
    init(frame: CGRect, fixtureScale: CGFloat? = nil, borderPixels: CGFloat = 1) {
        self.fixtureScale = fixtureScale; self.borderPixels = borderPixels
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { return nil }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        NSGraphicsContext.current?.shouldAntialias = false
        let pixel = borderPixels / (fixtureScale ?? window?.backingScaleFactor ?? 1)
        let inner = bounds.insetBy(dx: pixel, dy: pixel)
        let boxes = [CGRect(x: inner.minX, y: bounds.midY, width: bounds.midX - pixel, height: bounds.midY - pixel),
                     CGRect(x: bounds.midX, y: bounds.midY, width: bounds.midX - pixel, height: bounds.midY - pixel),
                     CGRect(x: inner.minX, y: inner.minY, width: bounds.midX - pixel, height: bounds.midY - pixel),
                     CGRect(x: bounds.midX, y: inner.minY, width: bounds.midX - pixel, height: bounds.midY - pixel)]
        for (box, color) in zip(boxes, Self.colors) {
            NSColor(srgbRed: CGFloat(color[0]) / 255, green: CGFloat(color[1]) / 255,
                    blue: CGFloat(color[2]) / 255, alpha: 1).setFill()
            box.fill()
        }
    }
}
