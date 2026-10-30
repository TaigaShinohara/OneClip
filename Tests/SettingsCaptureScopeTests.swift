import AppKit
import CoreGraphics
import Darwin
import Foundation

/// Default: synthetic metadata only. --window-lifecycle adds explicit synthetic NSWindow checks.
/// --capture-fixture explicitly captures only an opaque synthetic fixture, in memory, if already permitted.
/// No mode requests permission, accesses the clipboard, or delivers input to other apps.
@main
struct SettingsCaptureScopeTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct CaptureFixtureUnavailable: Error { let reason: String }

    @MainActor
    static func main() async throws {
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
            guard redMatches && greenMatches && blueMatches && pixels[offset + 3] >= 250 else { return false }
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
