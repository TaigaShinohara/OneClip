import CoreGraphics
import Foundation

/// Pure coordinate tests: no AppKit, screen access, files, clipboard or global input.
@main
struct RegionGeometryTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() throws {
        let groups: [(String, () throws -> Void)] = [
            ("M1-GEO-01 four drag directions", testFourDirections),
            ("M1-GEO-02 negative/global coordinates and top-origin plans", testPlans),
            ("M1-GEO-03 pixel grid anchored to display origin", testSnapping),
            ("M1-GEO-04 preview clamp and raw release rejection", testBoundaries),
            ("M1-GEO-05 zero/subpixel/minimum selection", testSmallSelections),
            ("M1-GEO-06 invalid display and nonfinite inputs", testInvalidInputs),
            ("M1-GEO-07 invalid confirmed rectangles and scale mismatch", testValidation),
            ("M1-GEO-08 initial keyboard selection", testInitialSelection),
            ("M1-GEO-09 keyboard move and accelerated move", testKeyboardMovement),
            ("M1-GEO-10 keyboard resize, limits and minimum pixel", testKeyboardResize),
            ("M1-GEO-11 snapshot mismatch and repeated adjustments", testSnapshotAndRepetition),
            ("M1-GEO-12 representable integer pixel sizes", testIntegerLimits)
        ]
        for (name, body) in groups {
            try body()
            print("PASS \(name)")
        }
        print("PASS \(groups.count) pure geometry groups")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }

    static func expectError(_ expected: RegionGeometryError, _ body: () throws -> Void) throws {
        do {
            try body()
            throw Failure(description: "Expected \(expected)")
        } catch let error as RegionGeometryError {
            try expect(error == expected, "Expected \(expected), received \(error)")
        }
    }

    static func display(frame: CGRect = CGRect(x: 0, y: 0, width: 1_000, height: 800),
                        scale: CGFloat = 1, id: UInt32 = 1) throws -> CaptureDisplaySnapshot {
        try CaptureDisplaySnapshot(id: id, frame: frame, scale: scale)
    }

    static func testFourDirections() throws {
        let screen = try display()
        let pairs: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 100.2, y: 200.2), CGPoint(x: 300.2, y: 400.2)),
            (CGPoint(x: 300.2, y: 200.2), CGPoint(x: 100.2, y: 400.2)),
            (CGPoint(x: 100.2, y: 400.2), CGPoint(x: 300.2, y: 200.2)),
            (CGPoint(x: 300.2, y: 400.2), CGPoint(x: 100.2, y: 200.2))
        ]
        for (start, end) in pairs {
            let drawn = try RegionGeometry.dragRect(display: screen, start: start, current: end)
            let selected = try RegionGeometry.finishDrag(display: screen, start: start, end: end)
            try expect(drawn == CGRect(x: 100, y: 200, width: 200, height: 200), "Four-direction normalization")
            try expect(selected.rect == drawn, "Preview and confirmed bounds diverged")
            let plan = try RegionGeometry.plan(selection: selected, filterScale: 1)
            try expect(plan.pixelWidth == 200 && plan.pixelHeight == 200, "Drag pixel dimensions")
        }
    }

    static func testPlans() throws {
        let negative = try display(frame: CGRect(x: -1_920, y: -200, width: 1_920, height: 1_080))
        let selection = try CaptureSelection(display: negative, rect: CGRect(x: -1_800, y: -100, width: 300, height: 200))
        let plan = try RegionGeometry.plan(selection: selection, filterScale: 1)
        try expect(plan == RegionCapturePlan(sourceRect: CGRect(x: 120, y: 780, width: 300, height: 200),
                                              pixelWidth: 300, pixelHeight: 200), "Negative display transform")
        let retina = try display(frame: CGRect(x: 1_440, y: -900, width: 1_728, height: 1_117), scale: 2)
        let selected = try CaptureSelection(display: retina,
                                            rect: CGRect(x: 1_450.5, y: -899.5, width: 50.5, height: 30.5))
        let retinaPlan = try RegionGeometry.plan(selection: selected, filterScale: 2)
        try expect(retinaPlan.sourceRect == CGRect(x: 10.5, y: 1_086, width: 50.5, height: 30.5),
                   "Retina point rectangle must remain points")
        try expect(retinaPlan.pixelWidth == 101 && retinaPlan.pixelHeight == 61, "Retina integer dimensions")
    }

    static func testSnapping() throws {
        let retina = try display(scale: 2)
        let start = CGPoint(x: 10.24, y: 20.26)
        let end = CGPoint(x: 11.26, y: 22.24)
        let selection = try RegionGeometry.finishDrag(display: retina, start: start, end: end)
        try expect(selection.rect == CGRect(x: 10, y: 20.5, width: 1.5, height: 1.5), "2x pixel rounding")
        let preview = try RegionGeometry.dragRect(display: retina, start: start, current: end)
        try expect(selection.rect == preview, "Preview must show the rounded result")
        let shifted = try display(frame: CGRect(x: -100.25, y: 20.25, width: 100, height: 80), scale: 2)
        let anchored = try RegionGeometry.finishDrag(display: shifted, start: CGPoint(x: -99.99, y: 20.51),
                                                      end: CGPoint(x: -97.99, y: 23.01))
        try expect(anchored.rect == CGRect(x: -99.75, y: 20.75, width: 2, height: 2.5),
                   "Grid was anchored globally instead of to display origin")
        let plan = try RegionGeometry.plan(selection: anchored, filterScale: 2)
        try expect(plan.pixelWidth == 4 && plan.pixelHeight == 5, "Origin-relative pixels")
    }

    static func testBoundaries() throws {
        let screen = try display(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let start = CGPoint(x: 50, y: 50)
        let endpoints = [CGPoint(x: -1, y: 50), CGPoint(x: 101, y: 50),
                         CGPoint(x: 50, y: -1), CGPoint(x: 50, y: 101), CGPoint(x: 140, y: -10)]
        for end in endpoints {
            let drawn = try RegionGeometry.dragRect(display: screen, start: start, current: end)
            try expect(drawn.minX >= 0 && drawn.minY >= 0 && drawn.maxX <= 100 && drawn.maxY <= 100,
                       "Preview escaped start display")
            try expectError(.endOutsideDisplay) { _ = try RegionGeometry.finishDrag(display: screen, start: start, end: end) }
        }
        let drawn = try RegionGeometry.dragRect(display: screen, start: start, current: CGPoint(x: 140, y: -10))
        try expect(drawn == CGRect(x: 50, y: 0, width: 50, height: 50), "Boundary preview")
        let edge = try RegionGeometry.finishDrag(display: screen, start: .zero, end: CGPoint(x: 100, y: 100))
        try expect(edge.rect == screen.frame, "Exact edge must be selectable")
        try expectError(.endOutsideDisplay) {
            _ = try RegionGeometry.finishDrag(display: screen, start: .zero, end: CGPoint(x: CGFloat(100).nextUp, y: 100))
        }
        try expectError(.startOutsideDisplay) {
            _ = try RegionGeometry.dragRect(display: screen, start: CGPoint(x: -1, y: 50), current: start)
        }
    }

    static func testSmallSelections() throws {
        let screen = try display(scale: 2)
        let start = CGPoint(x: 1.1, y: 1.1)
        try expectError(.emptySelection) { _ = try RegionGeometry.finishDrag(display: screen, start: start, end: start) }
        try expectError(.emptySelection) {
            _ = try RegionGeometry.finishDrag(display: screen, start: start, end: CGPoint(x: 1.2, y: 1.2))
        }
        let minimum = try RegionGeometry.finishDrag(display: screen, start: CGPoint(x: 1.24, y: 1.24),
                                                     end: CGPoint(x: 1.26, y: 1.26))
        try expect(minimum.rect == CGRect(x: 1, y: 1, width: 0.5, height: 0.5), "Smallest displayable region")
        let plan = try RegionGeometry.plan(selection: minimum, filterScale: 2)
        try expect(plan.pixelWidth == 1 && plan.pixelHeight == 1, "Minimum must be one pixel")
        try expectError(.emptySelection) {
            _ = try CaptureSelection(display: screen, rect: CGRect(x: 1, y: 1, width: 0, height: 1))
        }
    }

    static func testInvalidInputs() throws {
        for scale in [CGFloat(0), -1, .nan, .infinity] {
            try expectError(.invalidDisplay) { _ = try display(scale: scale) }
        }
        let invalidFrames = [CGRect.zero, CGRect(x: 0, y: 0, width: -1, height: 1),
                             CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1),
                             CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1),
                             CGRect(x: 0, y: 0, width: 100.25, height: 100)]
        for frame in invalidFrames {
            try expectError(.invalidDisplay) { _ = try display(frame: frame, scale: 2) }
        }
        let screen = try display()
        for point in [CGPoint(x: CGFloat.nan, y: 1), CGPoint(x: 1, y: CGFloat.infinity)] {
            try expectError(.invalidPoint) { _ = try RegionGeometry.dragRect(display: screen, start: point, current: .zero) }
            try expectError(.invalidPoint) { _ = try RegionGeometry.dragRect(display: screen, start: .zero, current: point) }
            try expectError(.invalidPoint) { _ = try RegionGeometry.finishDrag(display: screen, start: .zero, end: point) }
        }
    }

    static func testValidation() throws {
        let screen = try display(scale: 2)
        try expectError(.selectionOutsideDisplay) {
            _ = try CaptureSelection(display: screen, rect: CGRect(x: -0.5, y: 0, width: 1, height: 1))
        }
        try expectError(.selectionOutsideDisplay) {
            _ = try CaptureSelection(display: screen, rect: CGRect(x: 999.5, y: 0, width: 1, height: 1))
        }
        try expectError(.invalidPoint) {
            _ = try CaptureSelection(display: screen, rect: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 1))
        }
        for rect in [CGRect(x: 0.25, y: 0, width: 1, height: 1), CGRect(x: 0, y: 0, width: 1.25, height: 1)] {
            try expectError(.notPixelAligned) { _ = try CaptureSelection(display: screen, rect: rect) }
        }
        let selected = try CaptureSelection(display: screen, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        for scale in [CGFloat(0), 1, 2.0001, .nan, .infinity] {
            try expectError(.scaleMismatch) { _ = try RegionGeometry.plan(selection: selected, filterScale: scale) }
        }
        _ = try RegionGeometry.plan(selection: selected, filterScale: 2)
    }

    static func testInitialSelection() throws {
        let screen = try display(frame: CGRect(x: 0, y: 0, width: 1_440, height: 900), scale: 2)
        let expected = CGRect(x: 560, y: 350, width: 320, height: 200)
        let initial = try RegionGeometry.initialSelection(display: screen)
        try expect(initial.rect == expected, "Initial centered region")
        let firstArrow = try RegionGeometry.adjusting(selection: nil, display: screen, direction: .left,
                                                       resize: true, accelerated: true)
        try expect(firstArrow == initial, "First arrow must initialize only")
        let small = try display(frame: CGRect(x: -200, y: -100, width: 200, height: 100), scale: 2)
        let smallInitial = try RegionGeometry.initialSelection(display: small)
        try expect(smallInitial.rect == small.frame, "Small display initial region")
        let onePixel = try display(frame: CGRect(x: -0.5, y: -0.5, width: 0.5, height: 0.5), scale: 2)
        let minimum = try RegionGeometry.initialSelection(display: onePixel)
        try expect(minimum.rect == onePixel.frame, "One-pixel display initialization")
        let odd = try display(frame: CGRect(x: -500, y: 20, width: 500.5, height: 300.5), scale: 2)
        let oddInitial = try RegionGeometry.initialSelection(display: odd)
        try expect(oddInitial.rect.width == 320 && oddInitial.rect.height == 200, "Odd pixel centering dimensions")
        _ = try RegionGeometry.plan(selection: oddInitial, filterScale: 2)
    }

    static func testKeyboardMovement() throws {
        let screen = try display(frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2)
        let original = try CaptureSelection(display: screen, rect: CGRect(x: 10, y: 20, width: 30, height: 40))
        let movements: [(RegionArrowDirection, CGRect)] = [
            (.left, CGRect(x: 9, y: 20, width: 30, height: 40)),
            (.right, CGRect(x: 11, y: 20, width: 30, height: 40)),
            (.down, CGRect(x: 10, y: 19, width: 30, height: 40)),
            (.up, CGRect(x: 10, y: 21, width: 30, height: 40))
        ]
        for (direction, rect) in movements {
            let moved = try RegionGeometry.adjusting(selection: original, display: screen, direction: direction)
            try expect(moved.rect == rect, "Arrow movement")
        }
        let fast = try RegionGeometry.adjusting(selection: original, display: screen, direction: .right, accelerated: true)
        try expect(fast.rect == CGRect(x: 20, y: 20, width: 30, height: 40), "Option arrow ten points")
        let edge = try CaptureSelection(display: screen, rect: CGRect(x: 80, y: 90, width: 20, height: 10))
        let rightAtEdge = try RegionGeometry.adjusting(selection: edge, display: screen, direction: .right)
        let upAtEdge = try RegionGeometry.adjusting(selection: edge, display: screen, direction: .up)
        try expect(rightAtEdge.rect == edge.rect, "Right edge move escaped display")
        try expect(upAtEdge.rect == edge.rect, "Top edge move escaped display")
        try expect(original.rect == CGRect(x: 10, y: 20, width: 30, height: 40), "Input selection mutated")
    }

    static func testKeyboardResize() throws {
        let screen = try display(frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2)
        let original = try CaptureSelection(display: screen, rect: CGRect(x: 10, y: 20, width: 30, height: 40))
        let resizes: [(RegionArrowDirection, CGSize)] = [
            (.left, CGSize(width: 29, height: 40)), (.right, CGSize(width: 31, height: 40)),
            (.down, CGSize(width: 30, height: 39)), (.up, CGSize(width: 30, height: 41))
        ]
        for (direction, size) in resizes {
            let resized = try RegionGeometry.adjusting(selection: original, display: screen, direction: direction, resize: true)
            try expect(resized.rect.origin == original.rect.origin && resized.rect.size == size, "Resize anchor/direction")
        }
        let large = try RegionGeometry.adjusting(selection: original, display: screen, direction: .up,
                                                  resize: true, accelerated: true)
        try expect(large.rect.height == 50, "Option resize ten points")
        let minimum = try CaptureSelection(display: screen, rect: CGRect(x: 10, y: 20, width: 0.5, height: 0.5))
        let shrinking: [RegionArrowDirection] = [.left, .down]
        for direction in shrinking {
            let resized = try RegionGeometry.adjusting(selection: minimum, display: screen, direction: direction,
                                                       resize: true, accelerated: true)
            try expect(resized == minimum, "Resize erased final pixel")
        }
        let maximum = try CaptureSelection(display: screen, rect: CGRect(x: 10, y: 20, width: 90, height: 80))
        let enlarging: [RegionArrowDirection] = [.right, .up]
        for direction in enlarging {
            let resized = try RegionGeometry.adjusting(selection: maximum, display: screen, direction: direction,
                                                       resize: true, accelerated: true)
            try expect(resized == maximum, "Resize crossed display edge")
        }
    }

    static func testSnapshotAndRepetition() throws {
        let screen = try display(frame: CGRect(x: -100, y: -100, width: 100, height: 100), scale: 2)
        var selected = try CaptureSelection(display: screen, rect: CGRect(x: -90, y: -90, width: 30, height: 20))
        let changed = try display(frame: screen.frame, scale: screen.scale, id: screen.id + 1)
        try expectError(.displayMismatch) {
            _ = try RegionGeometry.adjusting(selection: selected, display: changed, direction: .right)
        }
        for _ in 0..<1_000 {
            selected = try RegionGeometry.adjusting(selection: selected, display: screen, direction: .left)
            selected = try RegionGeometry.adjusting(selection: selected, display: screen, direction: .down, resize: true)
        }
        try expect(selected.rect.minX == -100 && selected.rect.height == 0.5, "Repeated adjustments did not saturate")
        let plan = try RegionGeometry.plan(selection: selected, filterScale: 2)
        try expect(plan.pixelWidth == 60 && plan.pixelHeight == 1, "Repeated adjustments lost pixel alignment")
    }

    static func testIntegerLimits() throws {
        try expectError(.unrepresentablePixelSize) {
            _ = try display(frame: CGRect(x: 0, y: 0, width: CGFloat(Int.max), height: 1))
        }
        try expectError(.unrepresentablePixelSize) {
            _ = try display(frame: CGRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 1), scale: 2)
        }
        try expectError(.invalidDisplay) {
            _ = try display(frame: CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0,
                                           width: CGFloat.greatestFiniteMagnitude, height: 1))
        }
    }
}
