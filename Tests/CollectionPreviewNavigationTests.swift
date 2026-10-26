import AppKit
import Foundation
import SwiftUI

/// Image-free geometry and offscreen clip views only. No window, screen capture, keys or pasteboard.
@main
struct CollectionPreviewNavigationTests {
    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor
    static func main() throws {
        let groups: [(String, @MainActor () throws -> Void)] = [
            ("M3-PREVIEW-01 navigation is scoped to focused 100% without a confirmation", testKeyPolicy),
            ("M3-PREVIEW-02 unflipped arrows move both axes and clamp at image edges", testArrows),
            ("M3-PREVIEW-03 document and page commands respect the viewport", testDocumentCommands),
            ("M3-PREVIEW-04 entering 100% resets once and resize preserves a constrained position", testModeAndResize),
            ("M3-PREVIEW-05 weak synchronous bridge applies every repeated command once", testNativeBridge),
            ("M3-PREVIEW-06 detached and released native views cannot receive navigation", testBridgeLifetime)
        ]
        for (name, body) in groups {
            try body()
            print("PASS \(name)")
        }
        print("PASS \(groups.count) preview navigation groups; no images or UI presentation")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }

    static func command(_ key: KeyEquivalent, modifiers: EventModifiers = [], expanded: Bool = true,
                        actualPixels: Bool = true, focused: Bool = true, confirmation: Bool = false)
        -> CollectionPreviewNavigation.Command? {
        CollectionPreviewNavigation.command(for: key, modifiers: modifiers, expanded: expanded,
                                            actualPixels: actualPixels, focused: focused,
                                            confirmationPending: confirmation)
    }

    static func testKeyPolicy() throws {
        let mappings: [(KeyEquivalent, CollectionPreviewNavigation.Command)] = [
            (.leftArrow, .left), (.rightArrow, .right), (.upArrow, .up), (.downArrow, .down),
            (.home, .home), (.end, .end), (.pageUp, .pageUp), (.pageDown, .pageDown)
        ]
        for (key, expected) in mappings {
            try expect(command(key) == expected, "A navigation key selected the wrong movement")
        }
        let shortcutModifiers: [EventModifiers] = [.command, .control, .option, .shift, [.control, .option]]
        for key in CollectionPreviewNavigation.keys {
            try expect(command(key) != nil, "A supported plain navigation key was rejected")
            try expect(command(key, expanded: false) == nil, "Collapsed preview consumed a key")
            try expect(command(key, actualPixels: false) == nil, "Fit preview consumed a key")
            try expect(command(key, focused: false) == nil, "Unfocused preview consumed a key")
            try expect(command(key, confirmation: true) == nil, "Preview consumed a confirmation key")
            for modifier in shortcutModifiers {
                try expect(command(key, modifiers: modifier) == nil, "A modified or VoiceOver key was consumed")
            }
        }
        for key in [KeyEquivalent.tab, .escape, .return, .space, "a"] {
            try expect(command(key) == nil, "An existing focus/action key was consumed")
        }
        try expect(command(.downArrow, modifiers: [.capsLock, .numericPad]) != nil,
                   "Arrow metadata incorrectly disabled navigation")
    }

    static func testArrows() throws {
        let document = CGSize(width: 1_237, height: 947)
        let viewport = CGSize(width: 331, height: 257)
        let point = CGPoint(x: 260, y: 310)
        let cases: [(CollectionPreviewNavigation.Command, CGPoint)] = [
            (.left, CGPoint(x: 220, y: 310)), (.right, CGPoint(x: 300, y: 310)),
            (.up, CGPoint(x: 260, y: 350)), (.down, CGPoint(x: 260, y: 270))
        ]
        for (action, expected) in cases {
            try expect(CollectionPreviewNavigation.origin(after: action, current: point,
                                                          document: document, viewport: viewport) == expected,
                       "An arrow moved the wrong axis or direction")
        }
        let lowerLeft = CGPoint.zero
        let upperRight = CGPoint(x: 906, y: 690)
        for action in [CollectionPreviewNavigation.Command.left, .down] {
            try expect(CollectionPreviewNavigation.origin(after: action, current: lowerLeft,
                                                          document: document, viewport: viewport) == lowerLeft,
                       "Navigation escaped the lower/left image edge")
        }
        for action in [CollectionPreviewNavigation.Command.right, .up] {
            try expect(CollectionPreviewNavigation.origin(after: action, current: upperRight,
                                                          document: document, viewport: viewport) == upperRight,
                       "Navigation escaped the upper/right image edge")
        }
        try expect(CollectionPreviewNavigation.clamped(CGPoint(x: -20, y: 800), document: document,
                                                       viewport: viewport) == CGPoint(x: 0, y: 690),
                   "An out-of-bounds origin was not constrained")
    }

    static func testDocumentCommands() throws {
        let document = CGSize(width: 932, height: 676)
        let viewport = CGSize(width: 300, height: 200)
        let point = CGPoint(x: 150, y: 240)
        let cases: [(CollectionPreviewNavigation.Command, CGPoint)] = [
            (.home, CGPoint(x: 0, y: 476)), (.end, CGPoint(x: 632, y: 0)),
            (.pageUp, CGPoint(x: 150, y: 420)), (.pageDown, CGPoint(x: 150, y: 60))
        ]
        for (action, expected) in cases {
            try expect(CollectionPreviewNavigation.origin(after: action, current: point,
                                                          document: document, viewport: viewport) == expected,
                       "Document/page navigation used an incorrect viewport")
        }
        for action in [CollectionPreviewNavigation.Command.left, .right, .up, .down, .home, .end, .pageUp, .pageDown] {
            try expect(CollectionPreviewNavigation.origin(after: action, current: point,
                                                          document: CGSize(width: 40, height: 30),
                                                          viewport: viewport) == .zero,
                       "A fully visible image acquired a scroll offset")
        }
        // The same fabricated 932x676 pixels at 2x occupy half as many window points.
        try expect(CollectionPreviewNavigation.topLeft(document: CGSize(width: 466, height: 338),
                                                       viewport: viewport) == CGPoint(x: 0, y: 138),
                   "Logical document dimensions were confused with image pixels")
    }

    static func testModeAndResize() throws {
        var state = CollectionPreviewViewport()
        let document = CGSize(width: 932, height: 676)
        let viewport = CGSize(width: 300, height: 200)
        let panned = CGPoint(x: 200, y: 110)
        state.setActualPixels(true)
        try expect(state.originAfterLayout(current: panned, document: document, viewport: viewport)
                   == CGPoint(x: 0, y: 476), "Entering 100% did not show the visual top-left")
        state.setActualPixels(true)
        try expect(state.originAfterLayout(current: panned, document: document, viewport: viewport) == panned,
                   "An ordinary update reset a panned 100% image")
        try expect(state.originAfterLayout(current: panned, document: document,
                                            viewport: CGSize(width: 800, height: 620)) == CGPoint(x: 132, y: 56),
                   "Resize did not preserve the nearest valid position")
        state.setActualPixels(false)
        try expect(state.originAfterLayout(current: panned, document: viewport, viewport: viewport) == .zero,
                   "Fit mode kept an invalid old origin")
        state.setActualPixels(true)
        state.setActualPixels(false) // A superseded transition must not reset a later fit layout.
        try expect(state.originAfterLayout(current: panned, document: document, viewport: viewport) == panned,
                   "A cancelled mode transition left a pending top reset")
        state.setActualPixels(true)
        try expect(state.originAfterLayout(current: panned, document: document, viewport: viewport)
                   == CGPoint(x: 0, y: 476), "Re-entering 100% did not request a new top reset")
    }

    @MainActor
    static func makeScroll() -> CollectionScrollView {
        let scroll = CollectionScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 932, height: 676))
        scroll.setActualPixels(true)
        scroll.layout()
        return scroll
    }

    @MainActor
    static func testNativeBridge() throws {
        let actions = CollectionPreviewActions()
        let scroll = makeScroll()
        actions.attach(scroll)
        let viewport = scroll.contentView.bounds.size
        let top = CollectionPreviewNavigation.topLeft(document: CGSize(width: 932, height: 676), viewport: viewport)
        try expect(scroll.contentView.bounds.origin == top, "The native clip did not start at top-left")
        try expect(actions.pan(.down) && actions.pan(.down) && actions.pan(.right),
                   "A live native clip rejected a synchronous command")
        try expect(scroll.contentView.bounds.origin == CGPoint(x: 40, y: top.y - 80),
                   "Repeated commands were coalesced, doubled, or reset by layout")
        scroll.layout()
        try expect(scroll.contentView.bounds.origin == CGPoint(x: 40, y: top.y - 80),
                   "Native layout reset an explicitly panned image")
        try expect(actions.pan(.home) && scroll.contentView.bounds.origin == top,
                   "Home did not reach the native clip's visual top-left")
        scroll.setActualPixels(false)
        try expect(!actions.pan(.down), "A stale bridge panned fit mode")
        scroll.documentView = nil
        scroll.setActualPixels(true)
        try expect(!actions.pan(.down), "A dismantled canvas accepted navigation")
    }

    @MainActor
    static func testBridgeLifetime() throws {
        let actions = CollectionPreviewActions()
        weak var weakOld: CollectionScrollView?
        weak var weakCurrent: CollectionScrollView?
        // Creation, layout and scrolling can create AppKit autoreleased references. Drain those
        // before asserting deallocation; bridge delivery and weak lifetime are separate checks.
        try autoreleasepool {
            var current: CollectionScrollView? = makeScroll()
            weakCurrent = current
            autoreleasepool {
                let old = makeScroll()
                weakOld = old
                actions.attach(old)
                actions.attach(current!)
                actions.detach(old)
            }
            try expect(weakOld == nil, "The old native view survived its creation/layout autorelease pool")
            try expect(actions.pan(.right), "Dismantling an old view cleared the current bridge")
            try expect(current?.contentView.bounds.origin.x == 40, "A command did not target the current native view")
            actions.detach(current!)
            try expect(!actions.pan(.right), "A detached view still accepted a command")
            actions.attach(current!)
            current = nil
        }
        try expect(weakCurrent == nil, "The bridge retained a native view after its AppKit autorelease pool drained")
        try expect(!actions.pan(.right), "The bridge accepted navigation after its native view was released")
    }
}
