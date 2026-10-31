import AppKit
import Foundation

/// Independent grid coordinates and instrumented clipboard boundary; no live screen or general board.
@main
struct CaptureBoundarySecurityTests {
    enum Failure: Error { case invariant }
    static func require(_ value: @autoclosure () -> Bool) throws {
        if !value() { throw Failure.invariant }
    }

    @MainActor
    static func main() throws {
        try referenceGrid()
        print("PASS BOUNDARY-01 1024 top-origin grid crops across 1x/2x and negative/portrait displays")
        try outsideRelease()
        print("PASS BOUNDARY-02 edge release cannot turn an out-of-display drag into capture")
        try clipboardTrace()
        print("PASS BOUNDARY-03 real synchronous boundary reports prepare/write only when reached")
        print("PASS 3 boundary security groups; no live capture or general clipboard")
    }

    static func referenceGrid() throws {
        // The oracle begins in a top-origin integer raster. World selections are input data;
        // expected crop indices never call the production snapping or conversion helpers.
        let frames = [CGRect(x: 0, y: 0, width: 640, height: 480),
                      CGRect(x: -640, y: 80, width: 640, height: 480),
                      CGRect(x: 200, y: -800, width: 480, height: 800),
                      CGRect(x: -300, y: -200, width: 800, height: 480)]
        var seed: UInt64 = 0x1C11_2026
        func next(_ maximum: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(maximum))
        }
        for frame in frames {
            for scale: CGFloat in [1, 2] {
                let width = Int(frame.width * scale), height = Int(frame.height * scale)
                let display = try CaptureDisplaySnapshot(id: 7, frame: frame, scale: scale)
                for index in 0..<128 {
                    let left = index < 4 ? (index % 2 == 0 ? 0 : width - 1) : next(width)
                    let top = index < 4 ? (index < 2 ? 0 : height - 1) : next(height)
                    let w = index < 4 ? 1 : 1 + next(width - left)
                    let h = index < 4 ? 1 : 1 + next(height - top)
                    let rect = CGRect(x: frame.minX + CGFloat(left) / scale,
                                      y: frame.maxY - CGFloat(top + h) / scale,
                                      width: CGFloat(w) / scale, height: CGFloat(h) / scale)
                    let selection = try CaptureSelection(display: display, rect: rect)
                    let plan = try RegionGeometry.plan(selection: selection, filterScale: scale)
                    try require(plan.pixelWidth == w && plan.pixelHeight == h)
                    try require(plan.sourceRect == CGRect(x: CGFloat(left) / scale, y: CGFloat(top) / scale,
                                                           width: CGFloat(w) / scale, height: CGFloat(h) / scale))
                    try require(plan.sourceRect.minX >= 0 && plan.sourceRect.minY >= 0)
                    try require(plan.sourceRect.maxX <= frame.width && plan.sourceRect.maxY <= frame.height)
                }
            }
        }
    }

    static func outsideRelease() throws {
        let display = try CaptureDisplaySnapshot(id: 8, frame: CGRect(x: -640, y: -100, width: 640, height: 480), scale: 2)
        let start = CGPoint(x: -300, y: 100)
        for end in [CGPoint(x: -640.5, y: 0), CGPoint(x: 0.5, y: 0),
                    CGPoint(x: -300, y: -100.5), CGPoint(x: -300, y: 380.5)] {
            _ = try RegionGeometry.dragRect(display: display, start: start, current: end)
            do {
                _ = try RegionGeometry.finishDrag(display: display, start: start, end: end)
                throw Failure.invariant
            } catch let error as RegionGeometryError {
                try require(error == .endOutsideDisplay)
            }
        }
    }

    @MainActor
    final class Destination: M0ClipboardProbeDestination {
        var changeCount = 9
        var conflictAfterPrepare = false
        var accept = true
        var writes = 0
        var options: NSPasteboard.ContentsOptions?
        func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
            self.options = options
            changeCount += 1
            let prepared = changeCount
            if conflictAfterPrepare { changeCount += 1 }
            return prepared
        }
        func write(_ item: NSPasteboardItem) -> Bool {
            writes += 1
            return accept
        }
    }

    @MainActor
    static func clipboardTrace() throws {
        let source = try M0ImageFixture.make(index: 1, width: 17, height: 11)
        let png = try M0ImageComposer.compose(assets: [source]).pngData
        for condition in 0..<5 {
            let trace = CaptureSecurityTrace(enabled: true, trial: UInt32(condition))
            let destination = Destination()
            destination.conflictAfterPrepare = condition == 2
            destination.accept = condition != 3
            let outcome = M0ClipboardProbe.writePNG(png, to: destination,
                expectedChangeCount: condition == 1 ? 8 : 9, securityTrace: trace, traceMode: .single,
                itemFactory: { data in condition == 0 ? nil : M0ClipboardProbe.makePNGItem(data) })
            let entries = trace.snapshot().entries
            let expected: [CaptureSecurityTrace.Code] = condition < 2 ? []
                : condition == 2 ? [.clipboardPrepared] : [.clipboardPrepared, .clipboardWrite]
            try require(entries.map(\.code) == expected)
            try require(entries.allSatisfy { $0.mode == .single && $0.phase == .writing && $0.trial == UInt32(condition) })
            try require(destination.writes == (condition >= 3 ? 1 : 0))
            try require(outcome.writeAccepted == (condition == 4))
            if condition >= 2 { try require(destination.options == .currentHostOnly) }
        }
    }
}
