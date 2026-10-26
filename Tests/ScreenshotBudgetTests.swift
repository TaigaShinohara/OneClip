import CoreGraphics
import Foundation

/// Pure request/metric validation only. Does not initialize ScreenshotService or use SCK/TCC/UI.
@main
struct ScreenshotBudgetTests {
    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor
    static func main() throws {
        let groups: [(String, @MainActor () throws -> Void)] = [
            ("M3-ACQUIRE-01 default request remains single-image compatible", testDefaults),
            ("M3-ACQUIRE-02 full collection and padded output reject before capture", testCollectionBoundary),
            ("M3-ACQUIRE-03 replacement retains old allocation and position", testReplacement),
            ("M3-ACQUIRE-04 actual stride can reject an accepted minimum-stride estimate", testActualStride),
            ("M3-ACQUIRE-05 external output buffers and overflow fail before allocation", testExtraBuffers)
        ]
        for (name, test) in groups {
            try test()
            print("PASS \(name)")
        }
        print("PASS \(groups.count) acquisition-budget groups; metrics only")
    }

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(description: message) }
    }

    static func expectError(_ expected: M0ImageError, _ body: () throws -> Void) throws {
        do {
            try body()
            throw Failure(description: "Expected resource rejection")
        } catch let error as M0ImageError {
            try expect(error == expected, "Wrong resource rejection")
        }
    }

    static func metric(_ width: Int, _ height: Int, stride: Int? = nil, scale: Double = 1) -> M0ImageMetrics {
        .init(width: width, height: height, bytesPerRow: stride ?? width * 4, scale: scale)
    }

    @MainActor
    static func testDefaults() throws {
        let display = try CaptureDisplaySnapshot(id: 1, frame: CGRect(x: 0, y: 0, width: 640, height: 360), scale: 2)
        let selection = try CaptureSelection(display: display, rect: CGRect(x: 20, y: 20, width: 100, height: 80))
        let request = SingleCaptureRequest(selection: selection, operationID: UUID())
        try expect(request.budget.existing.isEmpty && request.budget.replacementIndex == nil
                   && request.budget.retainingExtraBytes == 0, "Default request changed single capture")
        let plan = try request.budget.validateCandidate(metric(200, 160, scale: 2))
        try expect(plan.width == 200 && plan.height == 160 && plan.placements[0].numberTop == nil,
                   "Default acquisition added collection padding or changed scale")
    }

    static func testCollectionBoundary() throws {
        let full = CaptureImageBudgetContext(existing: Array(repeating: metric(1, 1), count: 4))
        try expectError(.countLimit) { _ = try full.validateCandidate(metric(1, 1)) }
        let lastAcceptedWidth = CaptureImageBudgetContext(existing: [metric(16_352, 1)])
        let plan = try lastAcceptedWidth.validateCandidate(metric(1, 1))
        try expect(plan.width == 16_384 && plan.placements.count == 2, "Output dimension boundary changed")
        let exceedsAfterPadding = CaptureImageBudgetContext(existing: [metric(16_353, 1)])
        try expectError(.dimensionLimit) { _ = try exceedsAfterPadding.validateCandidate(metric(1, 1)) }
    }

    static func testReplacement() throws {
        let existing = [metric(30, 20), metric(40, 10, scale: 2)]
        let context = CaptureImageBudgetContext(existing: existing, replacementIndex: 0, retainingExtraBytes: 10_000)
        let plan = try context.validateCandidate(metric(50, 25, scale: 2))
        try expect(plan.placements.map(\.width) == [50, 40] && context.existing == existing,
                   "Candidate changed source order or mutated the old collection")
        try expect(plan.retainingExtraBytes == 30 * 20 * 4 + 10_000,
                   "Acquisition omitted replaced source or previous completed buffers")
        let invalid = CaptureImageBudgetContext(existing: existing, replacementIndex: 2)
        try expectError(.invalidReplacement) { _ = try invalid.validateCandidate(metric(1, 1)) }
    }

    static func testActualStride() throws {
        let context = CaptureImageBudgetContext(existing: [metric(50, 50)], replacementIndex: 0)
        let minimum = metric(200, 100)
        let plan = try context.validateCandidate(minimum)
        var limits = M0ImageLimits()
        limits.maximumImageBytes = plan.estimatedPeakBytes
        _ = try context.validateCandidate(minimum, limits: limits)
        let padded = metric(200, 100, stride: 1_024)
        try expectError(.memoryLimit) { _ = try context.validateCandidate(padded, limits: limits) }
        try expect(context.existing == [metric(50, 50)], "Stride rejection changed existing sources")
    }

    static func testExtraBuffers() throws {
        let candidate = metric(20, 20)
        let plain = CaptureImageBudgetContext()
        let withOldOutput = CaptureImageBudgetContext(retainingExtraBytes: 20_000)
        let baseline = try plain.validateCandidate(candidate)
        var limits = M0ImageLimits()
        limits.maximumImageBytes = baseline.estimatedPeakBytes
        _ = try plain.validateCandidate(candidate, limits: limits)
        try expectError(.memoryLimit) { _ = try withOldOutput.validateCandidate(candidate, limits: limits) }
        let negative = CaptureImageBudgetContext(retainingExtraBytes: -1)
        try expectError(.invalidMetrics) { _ = try negative.validateCandidate(candidate) }
        let overflow = CaptureImageBudgetContext(retainingExtraBytes: .max)
        limits.maximumImageBytes = .max
        try expectError(.arithmeticOverflow) { _ = try overflow.validateCandidate(candidate, limits: limits) }
    }
}
