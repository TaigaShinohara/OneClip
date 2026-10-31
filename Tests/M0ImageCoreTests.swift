import CoreGraphics
import Dispatch
import Foundation
import ImageIO

/// Compile with M0ImageCore.swift as a small, dependency-free command-line test executable.
/// Every image is fabricated and stays in memory; this test never touches the clipboard.
@main
struct M0ImageCoreTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() async throws {
        // Opt-in only: root must check running builds, memory and disk before this allocation.
        if CommandLine.arguments.contains("--stress-2") {
            try runStress(count: 2, sourceHeight: 1_900)
            return
        }
        if CommandLine.arguments.contains("--stress-4") {
            try runStress(count: 4, sourceHeight: 950)
            return
        }
        let tests: [(String, () throws -> Void)] = [
            ("M0-IMG-01 single image exception and complete PNG", testSingle),
            ("M0-IMG-02 exact layout, padding and pixel order", testTwo),
            ("M0-IMG-03 four images, different scales and numbers", testFour),
            ("M0-IMG-04 empty/count/invalid metadata", testInvalid),
            ("M0-IMG-05 pixel and dimension boundaries", testBoundaries),
            ("M0-IMG-06 output includes padding before acceptance", testOutputPreflight),
            ("M0-IMG-07 replacement retains old allocation", testReplacementPeak),
            ("M0-IMG-08 addition, replacement order and atomic rejection", testChanges),
            ("M0-IMG-09 encoded-data budget and overflow", testEncodedBudget),
            ("M0-IMG-10 checked arithmetic before allocation", testOverflow),
            ("M0-IMG-11 fabricated text/grid and asymmetric orientation", testFixtures),
            ("M3-IMG-01 external buffers survive planning and encoded-byte validation", testExternalRetention),
            ("M3-IMG-02 replacement accounts for old source and external buffers", testExternalReplacement),
            ("M3-IMG-03 composition retains actual padded stride and declared extras", testExternalComposition),
            ("M3-IMG-04 external buffer arithmetic rejects negative and overflow", testExternalOverflow),
            ("M3-IMG-05 mutable and immutable PNG coexistence budget", testTwoPNGPeak),
            ("CANCEL-IMG-01 cancellation precedes planning and allocation", testCancellationBeforeAllocation),
            ("CANCEL-IMG-02 cancellation between source renders", testCancellationBetweenSources),
            ("CANCEL-IMG-03 cancellation before PNG encoding", testCancellationBeforeEncoding),
            ("CANCEL-IMG-04 cancellation after PNG encoding", testCancellationAfterEncoding),
            ("CANCEL-IMG-05 cancellation before returning completed PNG", testCancellationBeforeResult)
        ]
        let asyncTests: [(String, () async throws -> Void)] = [
            ("CANCEL-IMG-06 cancellable worker preserves output and budget", testCancellableComposition),
            ("CANCEL-IMG-07 already cancelled caller starts no worker", testCancelledCaller),
            ("CANCEL-IMG-08 caller cancellation reaches detached worker", testCancelledWorker)
        ]
        let start = ContinuousClock.now
        for (name, test) in tests {
            try autoreleasepool { try test() }
            print("PASS \(name)")
        }
        for (name, test) in asyncTests {
            try await test()
            print("PASS \(name)")
        }
        print("PASS \(tests.count + asyncTests.count) groups; elapsed \(start.duration(to: .now)); in-memory synthetic images only")
    }

    static func runStress(count: Int, sourceHeight: Int) throws {
        let start = ContinuousClock.now
        try autoreleasepool {
            let assets = try (1...count).map { index in
                try M0ImageFixture.make(index: index, width: 6_000, height: sourceHeight,
                                        scale: index.isMultiple(of: 2) ? 2 : 1)
            }
            let result = try M0ImageComposer.compose(assets: assets)
            try expect(result.image.width == result.plan.width && result.image.height == result.plan.height,
                       "Stress output dimensions differ")
            print("PASS M0-IMG-STRESS count=\(count) output=\(result.plan.width)x\(result.plan.height) " +
                  "sourcePixels=\(result.plan.sourcePixels) estimatedPeakBytes=\(result.plan.estimatedPeakBytes) " +
                  "retainedOnePNGEstimateBytes=\(result.actualImageBytes) " +
                  "encodingTwoPNGPeakEstimateBytes=\(result.actualImageBytes + result.pngData.count) " +
                  "pngBytes=\(result.pngData.count)")
        }
        print("PASS elapsed \(start.duration(to: .now)); in-memory synthetic images only")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }

    static func expectError(_ expected: M0ImageError, _ body: () throws -> Void) throws {
        do {
            try body()
            throw Failure(description: "Expected \(expected)")
        } catch let error as M0ImageError {
            try expect(error == expected, "Expected \(expected), received \(error)")
        }
    }

    static func expectCancellation(_ body: () throws -> Void) throws {
        do {
            try body()
            throw Failure(description: "Cancelled composition returned a result")
        } catch is CancellationError {}
    }

    /// Only synthetic checkpoint classifications cross threads; no image or pixel data is retained.
    final class CancellationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let cancellationPoint: M0CompositionCheckpoint?
        private var points: [M0CompositionCheckpoint] = []

        init(cancellationPoint: M0CompositionCheckpoint? = nil) {
            self.cancellationPoint = cancellationPoint
        }

        func check(_ point: M0CompositionCheckpoint) throws {
            let cancelled = lock.withLock {
                points.append(point)
                return point == cancellationPoint
            }
            if cancelled { throw CancellationError() }
        }

        var checkpoints: [M0CompositionCheckpoint] { lock.withLock { points } }
    }

    /// A finite test-only barrier keeps real synchronous work in progress while its caller cancels.
    /// Cancellation must not claim that the framework/worker has already finished.
    final class CancellationGate: @unchecked Sendable {
        private let lock = NSLock()
        private let releaseSignal = DispatchSemaphore(value: 0)
        private var entered = false
        private var exited = false
        private var cancelledAtExit = false
        private var laterCheckpointSeen = false

        func check(_ point: M0CompositionCheckpoint) throws {
            guard point == .beforeEncoding else {
                if point == .afterEncoding || point == .beforeResult {
                    lock.withLock { laterCheckpointSeen = true }
                }
                return
            }
            lock.withLock { entered = true }
            let released = releaseSignal.wait(timeout: .now() + 5) == .success
            lock.withLock {
                exited = true
                cancelledAtExit = Task.isCancelled
            }
            guard released else { throw Failure(description: "Synthetic cancellation barrier timed out") }
        }

        func release() { releaseSignal.signal() }
        var hasEntered: Bool { lock.withLock { entered } }
        var hasExited: Bool { lock.withLock { exited } }
        var observedCancellation: Bool { lock.withLock { cancelledAtExit } }
        var reachedLaterCheckpoint: Bool { lock.withLock { laterCheckpointSeen } }
    }

    static func metric(_ width: Int, _ height: Int, scale: Double = 1) -> M0ImageMetrics {
        M0ImageMetrics(width: width, height: height, bytesPerRow: width * 4, scale: scale)
    }

    static func solid(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat,
                      scale: Double = 1) throws -> M0ImageAsset {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                        CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw Failure(description: "Synthetic context unavailable")
        }
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        guard let image = context.makeImage() else { throw Failure(description: "Synthetic image unavailable") }
        return M0ImageAsset(image: image, scale: scale)
    }

    /// CGImage cropping uses pixel coordinates from the top-left; a 1px crop avoids row-order assumptions.
    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        guard let cropped = image.cropping(to: CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)) else {
            throw Failure(description: "Pixel crop unavailable")
        }
        var bytes: [UInt8] = [0, 0, 0, 0]
        try bytes.withUnsafeMutableBytes { memory in
            guard let context = CGContext(data: memory.baseAddress, width: 1, height: 1,
                                          bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                            CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw Failure(description: "Pixel normalization context unavailable")
            }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }

    static func expectPixel(_ image: CGImage, x: Int, y: Int, equals expected: [UInt8]) throws {
        let value = try pixel(image, x: x, y: y)
        try expect(zip(value, expected).allSatisfy { pair in abs(Int(pair.0) - Int(pair.1)) <= 1 },
                   "Unexpected pixel at \(x),\(y): \(value)")
    }

    static func testSingle() throws {
        let asset = try solid(width: 13, height: 7, red: 1, green: 0, blue: 0, scale: 2)
        let result = try M0ImageComposer.compose(assets: [asset])
        try expect(result.image === asset.image, "Single image must not be redrawn or padded")
        try expect(result.plan.width == 13 && result.plan.height == 7, "Single image dimensions changed")
        try expect(result.plan.placements == [M0ImagePlacement(index: 0, x: 0, y: 0, width: 13,
                                                               height: 7, numberTop: nil)], "Single image numbered")
        try expect(Array(result.pngData.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10], "Missing PNG signature")
        guard let source = CGImageSourceCreateWithData(result.pngData as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure(description: "Complete PNG cannot decode from memory")
        }
        try expect(CGImageSourceGetCount(source) == 1, "Output must contain exactly one image")
        try expect(decoded.width == 13 && decoded.height == 7, "PNG dimensions changed")
        try expectPixel(decoded, x: 12, y: 6, equals: [255, 0, 0, 255])
    }

    static func testTwo() throws {
        let assets = [try solid(width: 13, height: 11, red: 1, green: 0, blue: 0),
                      try solid(width: 7, height: 5, red: 0, green: 0, blue: 1)]
        let result = try M0ImageComposer.compose(assets: assets)
        try expect(result.plan.width == 45 && result.plan.height == 112, "Two-image formula changed")
        try expect(result.plan.placements[0] == M0ImagePlacement(index: 0, x: 16, y: 40,
                                                                width: 13, height: 11, numberTop: 16), "First placement")
        try expect(result.plan.placements[1] == M0ImagePlacement(index: 1, x: 16, y: 91,
                                                                width: 7, height: 5, numberTop: 67), "Second placement")
        try expectPixel(result.image, x: 16, y: 40, equals: [255, 0, 0, 255])
        try expectPixel(result.image, x: 28, y: 50, equals: [255, 0, 0, 255])
        try expectPixel(result.image, x: 16, y: 91, equals: [0, 0, 255, 255])
        try expectPixel(result.image, x: 22, y: 95, equals: [0, 0, 255, 255])
        for point in [(0, 0), (44, 111), (15, 40), (29, 40), (23, 91), (16, 51)] {
            try expectPixel(result.image, x: point.0, y: point.1, equals: [255, 255, 255, 255])
        }
    }

    static func testFour() throws {
        let dimensions = [(11, 7), (3, 5), (9, 2), (6, 4)]
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 0, 1)]
        let expected: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 0, 255, 255]]
        let assets = try dimensions.enumerated().map { index, value in
            try solid(width: value.0, height: value.1, red: colors[index].0, green: colors[index].1,
                      blue: colors[index].2, scale: index.isMultiple(of: 2) ? 1 : 2)
        }
        let result = try M0ImageComposer.compose(assets: assets)
        try expect(result.plan.width == 43 && result.plan.height == 194, "Four-image formula changed")
        for (index, placement) in result.plan.placements.enumerated() {
            try expect(placement.width == dimensions[index].0 && placement.height == dimensions[index].1,
                       "Scale must not resample source pixels")
            try expectPixel(result.image, x: placement.x, y: placement.y, equals: expected[index])
            guard let bandTop = placement.numberTop else { throw Failure(description: "Missing number band") }
            var hasDarkNumber = false
            for y in bandTop..<(bandTop + 24) {
                for x in 16..<28 {
                    let value = try pixel(result.image, x: x, y: y)
                    if value[0] < 128 && value[1] < 128 && value[2] < 128 { hasDarkNumber = true }
                }
            }
            try expect(hasDarkNumber, "Number missing from band \(index + 1)")
        }
    }

    static func testInvalid() throws {
        try expectError(.emptyCollection) { _ = try M0ImageComposer.makePlan(metrics: []) }
        try expectError(.countLimit) { _ = try M0ImageComposer.makePlan(metrics: Array(repeating: metric(1, 1), count: 5)) }
        for value in [M0ImageMetrics(width: 0, height: 1, bytesPerRow: 4),
                      M0ImageMetrics(width: -1, height: 1, bytesPerRow: 4),
                      M0ImageMetrics(width: 2, height: 1, bytesPerRow: 1),
                      M0ImageMetrics(width: 1, height: 1, bytesPerRow: 4, scale: .nan),
                      M0ImageMetrics(width: 1, height: 1, bytesPerRow: 4, scale: 0)] {
            try expectError(.invalidMetrics) { _ = try M0ImageComposer.makePlan(metrics: [value]) }
        }
        try expectError(.invalidReplacement) {
            _ = try M0ImageComposer.validateChange(existing: [metric(1, 1)], replacementIndex: 1, candidate: metric(1, 1))
        }
    }

    static func testBoundaries() throws {
        _ = try M0ImageComposer.makePlan(metrics: [metric(6_000, 4_000)]) // Exactly 24 MP, no allocation.
        _ = try M0ImageComposer.makePlan(metrics: [metric(16_384, 1)])
        try expectError(.dimensionLimit) { _ = try M0ImageComposer.makePlan(metrics: [metric(16_385, 1)]) }
        try expectError(.sourcePixelLimit) { _ = try M0ImageComposer.makePlan(metrics: [metric(6_001, 4_000)]) }
        try expectError(.sourcePixelLimit) {
            _ = try M0ImageComposer.makePlan(metrics: [metric(3_500, 3_500), metric(3_500, 3_500)])
        }
        var budget = M0ImageLimits()
        let baseline = try M0ImageComposer.makePlan(metrics: [metric(10, 10)])
        budget.maximumImageBytes = baseline.estimatedPeakBytes
        _ = try M0ImageComposer.makePlan(metrics: [metric(10, 10)], limits: budget)
        budget.maximumImageBytes -= 1
        try expectError(.memoryLimit) { _ = try M0ImageComposer.makePlan(metrics: [metric(10, 10)], limits: budget) }
    }

    static func testOutputPreflight() throws {
        try expectError(.dimensionLimit) {
            _ = try M0ImageComposer.makePlan(metrics: [metric(16_353, 1), metric(1, 1)])
        }
        var limits = M0ImageLimits()
        limits.maximumOutputPixels = 3_233
        try expectError(.outputPixelLimit) {
            _ = try M0ImageComposer.makePlan(metrics: [metric(1, 1), metric(1, 1)], limits: limits)
        }
        limits.maximumOutputPixels = 3_234
        _ = try M0ImageComposer.makePlan(metrics: [metric(1, 1), metric(1, 1)], limits: limits)
    }

    static func testReplacementPeak() throws {
        let original = metric(50, 50)
        let acceptedAlone = try M0ImageComposer.makePlan(metrics: [original])
        let replacement = try M0ImageComposer.validateChange(existing: [original], replacementIndex: 0, candidate: original)
        try expect(replacement.estimatedPeakBytes >= acceptedAlone.estimatedPeakBytes + 10_000,
                   "Old image was omitted from replacement peak")
        var limits = M0ImageLimits()
        limits.maximumImageBytes = acceptedAlone.estimatedPeakBytes
        try expectError(.memoryLimit) {
            _ = try M0ImageComposer.validateChange(existing: [original], replacementIndex: 0,
                                                  candidate: original, limits: limits)
        }
        try expect(original == metric(50, 50), "Rejected replacement changed original")
    }

    static func testChanges() throws {
        let originals = [metric(20, 10), metric(30, 11, scale: 2)]
        let added = try M0ImageComposer.validateChange(existing: originals, candidate: metric(40, 12))
        try expect(added.placements.map(\.width) == [20, 30, 40], "Addition reordered sources")
        let replaced = try M0ImageComposer.validateChange(existing: originals, replacementIndex: 0, candidate: metric(50, 13))
        try expect(replaced.placements.map(\.width) == [50, 30], "Replacement changed order")
        try expect(originals.map(\.width) == [20, 30], "Preflight mutated retained sources")
        try expectError(.countLimit) {
            _ = try M0ImageComposer.validateChange(existing: Array(repeating: metric(1, 1), count: 4), candidate: metric(1, 1))
        }
    }

    static func testEncodedBudget() throws {
        let plan = try M0ImageComposer.makePlan(metrics: [metric(10, 10)])
        var limits = M0ImageLimits()
        let retainedBytes = plan.sourceBytes + plan.previewReserveBytes + 100
        limits.maximumImageBytes = retainedBytes + 100
        let accepted = try M0ImageComposer.validateEncodedBytes(plan: plan, pngByteCount: 100,
                                                               isSingleImage: true, limits: limits)
        try expect(accepted == retainedBytes, "Returned retention included the temporary PNG copy")
        try expectError(.memoryLimit) {
            _ = try M0ImageComposer.validateEncodedBytes(plan: plan, pngByteCount: 101, isSingleImage: true, limits: limits)
        }
        try expectError(.encodingFailed) {
            _ = try M0ImageComposer.validateEncodedBytes(plan: plan, pngByteCount: 0, isSingleImage: true)
        }
        try expectError(.arithmeticOverflow) {
            _ = try M0ImageComposer.validateEncodedBytes(plan: plan, pngByteCount: Int.max, isSingleImage: true)
        }
    }

    static func testOverflow() throws {
        var limits = M0ImageLimits()
        limits.maximumDimension = .max
        limits.maximumSourcePixels = .max
        limits.maximumOutputPixels = .max
        limits.maximumImageBytes = .max
        let cases: [[M0ImageMetrics]] = [
            [M0ImageMetrics(width: .max, height: 2, bytesPerRow: .max)],
            [M0ImageMetrics(width: 1, height: 2, bytesPerRow: .max)],
            [M0ImageMetrics(width: 1, height: 1, bytesPerRow: .max), metric(1, 1)],
            [M0ImageMetrics(width: Int.max - 1, height: 1, bytesPerRow: Int.max - 1),
             M0ImageMetrics(width: 1, height: 1, bytesPerRow: 1)],
            [M0ImageMetrics(width: 1, height: Int.max - 1, bytesPerRow: 1),
             M0ImageMetrics(width: 1, height: 1, bytesPerRow: 1)],
            [M0ImageMetrics(width: 1, height: Int.max / 2 - 100, bytesPerRow: 1),
             M0ImageMetrics(width: 1, height: Int.max / 2 - 100, bytesPerRow: 1)]
        ]
        for values in cases {
            try expectError(.arithmeticOverflow) { _ = try M0ImageComposer.makePlan(metrics: values, limits: limits) }
        }
    }

    static func testExternalRetention() throws {
        let values = [metric(10, 10)]
        let baseline = try M0ImageComposer.makePlan(metrics: values)
        let extra = 43_000 // Previously completed image, PNG and bounded UI buffers held by caller.
        let held = try M0ImageComposer.makePlan(metrics: values, retainingExtraBytes: extra)
        try expect(held.sourceBytes == baseline.sourceBytes && held.outputBytes == baseline.outputBytes,
                   "External buffers changed source/output accounting")
        try expect(held.retainingExtraBytes == extra && held.estimatedPeakBytes == baseline.estimatedPeakBytes + extra,
                   "External buffers were omitted or counted twice in the peak")
        var limits = M0ImageLimits()
        limits.maximumImageBytes = held.estimatedPeakBytes
        _ = try M0ImageComposer.makePlan(metrics: values, limits: limits, retainingExtraBytes: extra)
        limits.maximumImageBytes -= 1
        try expectError(.memoryLimit) {
            _ = try M0ImageComposer.makePlan(metrics: values, limits: limits, retainingExtraBytes: extra)
        }
        let encodedBytes = held.sourceBytes + held.previewReserveBytes + extra + 100
        limits.maximumImageBytes = encodedBytes + 100
        let accepted = try M0ImageComposer.validateEncodedBytes(plan: held, pngByteCount: 100,
                                                                isSingleImage: true, limits: limits)
        try expect(accepted == encodedBytes, "Encoded check lost or duplicated plan-owned extras")
        try expectError(.memoryLimit) {
            _ = try M0ImageComposer.validateEncodedBytes(plan: held, pngByteCount: 101,
                                                        isSingleImage: true, limits: limits)
        }
        limits.maximumImageBytes = encodedBytes + 100 + 21
        _ = try M0ImageComposer.validateEncodedBytes(plan: held, pngByteCount: 100, isSingleImage: true,
                                                    limits: limits, retainingExtraBytes: 21)
        limits.maximumImageBytes -= 1
        try expectError(.memoryLimit) {
            _ = try M0ImageComposer.validateEncodedBytes(plan: held, pngByteCount: 100, isSingleImage: true,
                                                        limits: limits, retainingExtraBytes: 21)
        }
    }

    static func testExternalReplacement() throws {
        let old = metric(50, 50)
        let candidate = metric(60, 40, scale: 2)
        let baseline = try M0ImageComposer.validateChange(existing: [old], replacementIndex: 0, candidate: candidate)
        let plan = try M0ImageComposer.validateChange(existing: [old], replacementIndex: 0,
                                                     candidate: candidate, retainingExtraBytes: 20_000)
        try expect(plan.retainingExtraBytes == old.bytesPerRow * old.height + 20_000,
                   "Replacement dropped old source or unrelated retained output")
        try expect(plan.sourceBytes == candidate.bytesPerRow * candidate.height
                   && plan.estimatedPeakBytes == baseline.estimatedPeakBytes + 20_000,
                   "Replacement inflated source set or omitted external peak")
        let pngBytes = 200
        let encoded = try M0ImageComposer.validateEncodedBytes(plan: plan, pngByteCount: pngBytes, isSingleImage: true)
        try expect(encoded == plan.sourceBytes + plan.retainingExtraBytes + pngBytes + plan.previewReserveBytes,
                   "Replacement's old source was lost at encoded validation")
        var limits = M0ImageLimits()
        limits.maximumImageBytes = baseline.estimatedPeakBytes
        try expectError(.memoryLimit) {
            _ = try M0ImageComposer.validateChange(existing: [old], replacementIndex: 0, candidate: candidate,
                                                  limits: limits, retainingExtraBytes: 20_000)
        }
        try expect(old == metric(50, 50), "Rejected candidate mutated the old source")
    }

    static func testExternalComposition() throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: 13, height: 7, bitsPerComponent: 8,
                                      bytesPerRow: 64, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                        | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw Failure(description: "Padded fixture context unavailable")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 13, height: 7))
        guard let image = context.makeImage() else { throw Failure(description: "Padded fixture unavailable") }
        let asset = M0ImageAsset(image: image, scale: 2)
        try expect(asset.metrics.bytesPerRow == 64, "Fixture did not retain its real padded stride")
        let extra = 8_000
        let single = try M0ImageComposer.compose(assets: [asset], retainingExtraBytes: extra)
        try expect(single.plan.sourceBytes == 64 * 7 && single.plan.retainingExtraBytes == extra,
                   "Composition estimated width*4 instead of actual source stride")
        try expect(single.actualImageBytes == single.plan.sourceBytes + single.pngData.count
                   + single.plan.previewReserveBytes + extra, "Single source alias counted twice or extras lost")
        let multiple = try M0ImageComposer.compose(assets: [asset, asset], retainingExtraBytes: extra)
        try expect(multiple.actualImageBytes == multiple.plan.sourceBytes + multiple.plan.outputBytes
                   + multiple.pngData.count + multiple.plan.previewReserveBytes + extra,
                   "Multi-image encoded result omitted output or external buffers")
        try expectError(.invalidMetrics) {
            _ = try M0ImageComposer.validateEncodedBytes(plan: multiple.plan, pngByteCount: multiple.pngData.count,
                                                        isSingleImage: true)
        }
    }

    static func testExternalOverflow() throws {
        let value = metric(1, 1)
        try expectError(.invalidMetrics) {
            _ = try M0ImageComposer.validateChange(existing: [], candidate: value, retainingExtraBytes: -1)
        }
        var limits = M0ImageLimits()
        limits.maximumImageBytes = .max
        try expectError(.arithmeticOverflow) {
            _ = try M0ImageComposer.makePlan(metrics: [value], limits: limits, retainingExtraBytes: .max)
        }
        try expectError(.arithmeticOverflow) {
            _ = try M0ImageComposer.validateChange(existing: [value], replacementIndex: 0, candidate: value,
                                                  limits: limits, retainingExtraBytes: .max)
        }
        let plan = try M0ImageComposer.makePlan(metrics: [value], retainingExtraBytes: 5)
        try expectError(.invalidMetrics) {
            _ = try M0ImageComposer.validateEncodedBytes(plan: plan, pngByteCount: 1, isSingleImage: true,
                                                        retainingExtraBytes: -1)
        }
        try expectError(.arithmeticOverflow) {
            _ = try M0ImageComposer.validateEncodedBytes(plan: plan, pngByteCount: 1, isSingleImage: true,
                                                        limits: limits, retainingExtraBytes: .max)
        }
    }

    static func testTwoPNGPeak() throws {
        for values in [[metric(10, 10)], [metric(10, 10), metric(20, 5)]] {
            let plan = try M0ImageComposer.makePlan(metrics: values, retainingExtraBytes: 37)
            let base = plan.sourceBytes + (values.count == 1 ? 0 : plan.outputBytes)
                + plan.previewReserveBytes + plan.retainingExtraBytes
            let twoPNGPeak = base + plan.pngReserveBytes * 2
            try expect(plan.estimatedPeakBytes == twoPNGPeak,
                       "Small fixture's plan omitted the second PNG reserve")
            var limits = M0ImageLimits()
            limits.maximumImageBytes = twoPNGPeak
            _ = try M0ImageComposer.makePlan(metrics: values, limits: limits, retainingExtraBytes: 37)
            limits.maximumImageBytes -= 1
            try expectError(.memoryLimit) {
                _ = try M0ImageComposer.makePlan(metrics: values, limits: limits, retainingExtraBytes: 37)
            }

            let pngBytes = 123
            let retained = base + pngBytes
            limits.maximumImageBytes = retained // One PNG fits, but the encoding copy does not.
            try expectError(.memoryLimit) {
                _ = try M0ImageComposer.validateEncodedBytes(plan: plan, pngByteCount: pngBytes,
                                                            isSingleImage: values.count == 1, limits: limits)
            }
            limits.maximumImageBytes = retained + pngBytes
            let accepted = try M0ImageComposer.validateEncodedBytes(plan: plan, pngByteCount: pngBytes,
                                                                    isSingleImage: values.count == 1, limits: limits)
            try expect(accepted == retained, "Post-encoding retention should contain one PNG")
            limits.maximumImageBytes -= 1
            try expectError(.memoryLimit) {
                _ = try M0ImageComposer.validateEncodedBytes(plan: plan, pngByteCount: pngBytes,
                                                            isSingleImage: values.count == 1, limits: limits)
            }
        }

        var unlimited = M0ImageLimits()
        unlimited.maximumImageBytes = .max
        try expectError(.arithmeticOverflow) {
            // One reserve fits Int, but twice that reserve does not; no image is allocated.
            _ = try M0ImageComposer.makePlan(metrics: [.init(width: 1, height: 1, bytesPerRow: Int.max / 2)],
                                           limits: unlimited)
        }
        let plan = try M0ImageComposer.makePlan(metrics: [metric(1, 1)])
        try expectError(.arithmeticOverflow) {
            // Retained one-PNG arithmetic fits; adding its temporary twin overflows.
            _ = try M0ImageComposer.validateEncodedBytes(plan: plan, pngByteCount: Int.max / 2 + 1,
                                                        isSingleImage: true, limits: unlimited)
        }
    }

    static func cancellationAssets() throws -> [M0ImageAsset] {
        [try solid(width: 13, height: 7, red: 1, green: 0, blue: 0),
         try solid(width: 9, height: 5, red: 0, green: 0, blue: 1),
         try solid(width: 7, height: 3, red: 0, green: 1, blue: 0)]
    }

    static func testCancellationBeforeAllocation() throws {
        let assets = try cancellationAssets()
        let probe = CancellationProbe(cancellationPoint: .beforeAllocation)
        var limits = M0ImageLimits()
        limits.maximumImageBytes = 0 // Planning would fail if it ran before cancellation.
        try expectCancellation {
            _ = try M0ImageComposer.compose(assets: assets, limits: limits, checkCancellation: probe.check)
        }
        try expect(probe.checkpoints == [.beforeAllocation], "Cancelled work continued into planning/rendering")
    }

    static func testCancellationBetweenSources() throws {
        let assets = try cancellationAssets()
        let probe = CancellationProbe(cancellationPoint: .beforeSource(index: 1))
        try expectCancellation {
            _ = try M0ImageComposer.compose(assets: assets, checkCancellation: probe.check)
        }
        try expect(probe.checkpoints.contains(.beforeSource(index: 0)), "First source boundary was not reached")
        try expect(!probe.checkpoints.contains(.beforeSource(index: 2)), "Cancelled rendering reached a later source")
        try expect(!probe.checkpoints.contains(.beforeEncoding), "Cancelled rendering started PNG encoding")
    }

    static func testCancellationBeforeEncoding() throws {
        let asset = try solid(width: 13, height: 7, red: 1, green: 0, blue: 0)
        let probe = CancellationProbe(cancellationPoint: .beforeEncoding)
        try expectCancellation {
            _ = try M0ImageComposer.compose(assets: [asset], checkCancellation: probe.check)
        }
        try expect(probe.checkpoints.last == .beforeEncoding, "Cancelled work continued into PNG encoding")
        try expect(!probe.checkpoints.contains(.afterEncoding), "PNG encoding completed after pre-encode cancellation")
    }

    static func testCancellationAfterEncoding() throws {
        let assets = try cancellationAssets()
        let probe = CancellationProbe(cancellationPoint: .afterEncoding)
        var result: M0CompositionResult?
        try expectCancellation {
            result = try M0ImageComposer.compose(assets: assets, checkCancellation: probe.check)
        }
        try expect(result == nil && probe.checkpoints.last == .afterEncoding,
                   "Cancelled ImageIO output escaped composition")
        try expect(!probe.checkpoints.contains(.beforeResult), "Cancelled output continued to result delivery")
    }

    static func testCancellationBeforeResult() throws {
        let assets = try cancellationAssets()
        let probe = CancellationProbe(cancellationPoint: .beforeResult)
        var result: M0CompositionResult?
        try expectCancellation {
            result = try M0ImageComposer.compose(assets: assets, checkCancellation: probe.check)
        }
        try expect(probe.checkpoints.contains(.afterEncoding), "Post-encoding boundary was not exercised")
        try expect(result == nil, "Cancelled completed PNG was returned")
    }

    static func testCancellableComposition() async throws {
        let assets = try cancellationAssets()
        let baseline = try M0ImageComposer.compose(assets: assets, retainingExtraBytes: 137)
        let result = try await M0ImageComposer.composeCancellable(assets: assets, retainingExtraBytes: 137)
        try expect(result.plan == baseline.plan && result.actualImageBytes == baseline.actualImageBytes,
                   "Cancellable worker changed the image/extra-buffer budget")
        try expect(result.pngData == baseline.pngData, "Cancellable worker changed the synthetic PNG")
        try expectPixel(result.image, x: result.plan.placements[0].x, y: result.plan.placements[0].y,
                        equals: [255, 0, 0, 255])
    }

    static func testCancelledCaller() async throws {
        let assets = try cancellationAssets()
        let probe = CancellationProbe()
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await M0ImageComposer.composeCancellable(assets: assets, checkCancellation: probe.check)
        }
        do {
            _ = try await caller.value
            throw Failure(description: "Already cancelled caller returned an image")
        } catch is CancellationError {}
        try expect(probe.checkpoints.isEmpty, "Already cancelled caller started a composition worker")
    }

    static func testCancelledWorker() async throws {
        let assets = try cancellationAssets()
        let gate = CancellationGate()
        let caller = Task {
            try await M0ImageComposer.composeCancellable(assets: assets, checkCancellation: gate.check)
        }
        defer { gate.release() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !gate.hasEntered && clock.now < deadline { await Task.yield() }
        guard gate.hasEntered else {
            caller.cancel(); gate.release()
            _ = try? await caller.value
            throw Failure(description: "Detached worker did not reach the synthetic barrier")
        }
        caller.cancel()
        try expect(!gate.hasExited, "Cancellation released synchronous work before it finished")
        gate.release()
        do {
            _ = try await caller.value
            throw Failure(description: "Cancelled caller returned the worker's PNG")
        } catch is CancellationError {}
        try expect(gate.hasExited && gate.observedCancellation, "Caller cancellation did not reach the detached worker")
        try expect(!gate.reachedLaterCheckpoint, "Cancelled worker continued into PNG encoding/result delivery")
    }

    static func testFixtures() throws {
        let assets = try M0ImageFixture.makeSamples(count: 4)
        try expect(assets.map(\.scale) == [1, 2, 1, 2], "Missing mixed-scale fixtures")
        let image = assets[0].image
        try expectPixel(image, x: 2, y: 2, equals: [255, 191, 0, 255])
        try expectPixel(image, x: image.width - 2, y: image.height - 2, equals: [0, 230, 255, 255])
        let result = try M0ImageComposer.compose(assets: assets)
        for placement in result.plan.placements {
            try expectPixel(result.image, x: placement.x + 2, y: placement.y + 2, equals: [255, 191, 0, 255])
        }
    }
}
