import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// M0 estimates image buffers, not the process's total resident memory.
struct M0ImageLimits: Sendable {
    var maximumCount = 4
    var maximumSourcePixels = 24_000_000
    var maximumOutputPixels = 24_000_000
    var maximumDimension = 16_384
    var maximumImageBytes = 384 * 1_024 * 1_024
}

/// Integer pixel dimensions are independent of the source's point scale.
struct M0ImageMetrics: Equatable, Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let scale: Double

    init(width: Int, height: Int, bytesPerRow: Int, scale: Double = 1) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.scale = scale
    }
}

/// CGImage is immutable; only immutable references cross the worker boundary.
struct M0ImageAsset: @unchecked Sendable {
    let image: CGImage
    let scale: Double

    init(image: CGImage, scale: Double = 1) {
        self.image = image
        self.scale = scale
    }

    var metrics: M0ImageMetrics {
        M0ImageMetrics(width: image.width, height: image.height,
                       bytesPerRow: image.bytesPerRow, scale: scale)
    }
}

struct M0ImagePlacement: Equatable, Sendable {
    let index: Int
    let x: Int
    /// Top-left pixel origin, including the number band for multi-image output.
    let y: Int
    let width: Int
    let height: Int
    let numberTop: Int?
}

struct M0CompositionPlan: Equatable, Sendable {
    let width: Int
    let height: Int
    let placements: [M0ImagePlacement]
    let sourcePixels: Int
    let sourceBytes: Int
    let outputBytes: Int
    /// Reserve for one PNG; encodingPeak includes two while mutable and immutable storage coexist.
    let pngReserveBytes: Int
    let previewReserveBytes: Int
    /// Buffers outside the proposed source set, including a replaced source still held by a worker.
    /// Carried into the post-encoding check; it is not part of sourceBytes or a process RSS estimate.
    let retainingExtraBytes: Int
    let estimatedPeakBytes: Int
}

struct M0CompositionResult: @unchecked Sendable {
    let image: CGImage
    let pngData: Data
    let plan: M0CompositionPlan
    /// After compose's autorelease pool drains: sources, output, one PNG, preview reserve and extras.
    /// This retained-buffer estimate excludes the second temporary PNG checked during encoding.
    let actualImageBytes: Int
}

/// Cooperative boundaries only. A synchronous CoreGraphics/ImageIO call may finish before
/// cancellation is observed; rejecting its result does not erase its underlying storage.
enum M0CompositionCheckpoint: Equatable, Sendable {
    case beforeAllocation
    case beforeSource(index: Int)
    case beforeEncoding
    case afterEncoding
    case beforeResult
}

enum M0ImageError: Error, Equatable, LocalizedError, Sendable {
    case emptyCollection
    case invalidMetrics
    case invalidReplacement
    case countLimit
    case dimensionLimit
    case sourcePixelLimit
    case outputPixelLimit
    case memoryLimit
    case arithmeticOverflow
    case contextCreationFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .emptyCollection: "素材がありません。"
        case .invalidMetrics: "画像の寸法・行バイト数・倍率が不正です。"
        case .invalidReplacement: "取り直す素材が見つかりません。"
        case .countLimit: "素材は最大4枚です。既存の素材は保持します。"
        case .dimensionLimit: "画像の長辺が上限を超えます。既存の素材は保持します。"
        case .sourcePixelLimit: "元画像の合計画素数が上限を超えます。既存の素材は保持します。"
        case .outputPixelLimit: "余白を含む完成画像の画素数が上限を超えます。既存の素材は保持します。"
        case .memoryLimit: "画像バッファの見積りまたは実データが予算を超えます。既存の素材は保持します。"
        case .arithmeticOverflow: "画像サイズを安全に計算できません。"
        case .contextCreationFailed: "画像の作業領域を確保できません。"
        case .encodingFailed: "PNGを作成できません。素材を保持して再試行してください。"
        }
    }
}

enum M0ImageComposer {
    static func makePlan(assets: [M0ImageAsset], limits: M0ImageLimits = .init(),
                         retainingExtraBytes: Int = 0) throws -> M0CompositionPlan {
        try makePlan(metrics: assets.map(\.metrics), limits: limits, retainingExtraBytes: retainingExtraBytes)
    }

    /// Also used before capture/allocation and for arithmetic boundary tests.
    static func makePlan(metrics: [M0ImageMetrics], limits: M0ImageLimits = .init(),
                         retainingExtraBytes: Int = 0) throws -> M0CompositionPlan {
        guard !metrics.isEmpty else { throw M0ImageError.emptyCollection }
        guard metrics.count <= limits.maximumCount else { throw M0ImageError.countLimit }
        guard retainingExtraBytes >= 0, limits.maximumCount > 0,
              limits.maximumSourcePixels > 0, limits.maximumOutputPixels > 0,
              limits.maximumDimension > 0, limits.maximumImageBytes > 0 else {
            throw M0ImageError.invalidMetrics
        }

        var sourcePixels = 0
        var sourceBytes = 0
        var largestSourceBytes = 0
        for value in metrics {
            guard value.width > 0, value.height > 0, value.bytesPerRow > 0,
                  value.scale.isFinite, value.scale > 0 else { throw M0ImageError.invalidMetrics }
            guard max(value.width, value.height) <= limits.maximumDimension else {
                throw M0ImageError.dimensionLimit
            }
            // At least one byte per pixel; real CGImages supply their actual stride.
            guard value.bytesPerRow >= value.width else { throw M0ImageError.invalidMetrics }
            sourcePixels = try add(sourcePixels, multiply(value.width, value.height))
            let bytes = try multiply(value.bytesPerRow, value.height)
            sourceBytes = try add(sourceBytes, bytes)
            largestSourceBytes = max(largestSourceBytes, bytes)
        }
        guard sourcePixels <= limits.maximumSourcePixels else { throw M0ImageError.sourcePixelLimit }

        let width: Int
        let height: Int
        var placements: [M0ImagePlacement] = []
        if metrics.count == 1 {
            width = metrics[0].width
            height = metrics[0].height
            placements = [M0ImagePlacement(index: 0, x: 0, y: 0, width: width,
                                           height: height, numberTop: nil)]
        } else {
            width = try add(metrics.map(\.width).max()!, 32)
            var cursor = 16
            for (index, value) in metrics.enumerated() {
                let numberTop = cursor
                cursor = try add(cursor, 24)
                placements.append(M0ImagePlacement(index: index, x: 16, y: cursor,
                                                    width: value.width, height: value.height,
                                                    numberTop: numberTop))
                cursor = try add(cursor, value.height)
                if index < metrics.count - 1 { cursor = try add(cursor, 16) }
            }
            height = try add(cursor, 16)
        }
        guard max(width, height) <= limits.maximumDimension else { throw M0ImageError.dimensionLimit }
        let outputPixels = try multiply(width, height)
        guard outputPixels <= limits.maximumOutputPixels else { throw M0ImageError.outputPixelLimit }
        let outputBytes = metrics.count == 1 ? sourceBytes : try multiply(outputPixels, 4)
        // A reserve, not a promise about ImageIO's internal allocator. Check actual PNG afterwards.
        let pngReserve = try add(outputBytes, outputBytes / 100, 65_536)
        let previewWidth = min(width, 1_024)
        let previewHeight = min(height, 1_024)
        let previewReserve = try multiply(previewWidth, previewHeight, 4)
        let heldBytes = try add(sourceBytes, retainingExtraBytes)
        let renderingPeak: Int
        if metrics.count == 1 {
            renderingPeak = try add(heldBytes, previewReserve)
        } else {
            // Include conversion scratch and a possible context/makeImage copy, even if CG shares it.
            renderingPeak = try add(heldBytes, largestSourceBytes, outputBytes, outputBytes, previewReserve)
        }
        // Converting the mutable ImageIO destination into Data can copy the complete PNG.
        // Account for both stores instead of depending on a Foundation bridging optimization.
        let encodingPeak = try add(heldBytes, metrics.count == 1 ? 0 : outputBytes,
                                   multiply(pngReserve, 2), previewReserve)
        let peak = max(renderingPeak, encodingPeak)
        guard peak <= limits.maximumImageBytes else { throw M0ImageError.memoryLimit }
        return M0CompositionPlan(width: width, height: height, placements: placements,
                                 sourcePixels: sourcePixels, sourceBytes: sourceBytes,
                                 outputBytes: outputBytes, pngReserveBytes: pngReserve,
                                 previewReserveBytes: previewReserve, retainingExtraBytes: retainingExtraBytes,
                                 estimatedPeakBytes: peak)
    }

    /// The caller adopts a candidate only after this succeeds. Existing assets are never mutated.
    static func validateChange(existing: [M0ImageAsset], replacementIndex: Int? = nil,
                               candidate: M0ImageAsset, limits: M0ImageLimits = .init(),
                               retainingExtraBytes: Int = 0) throws -> M0CompositionPlan {
        try validateChange(existing: existing.map(\.metrics), replacementIndex: replacementIndex,
                           candidate: candidate.metrics, limits: limits, retainingExtraBytes: retainingExtraBytes)
    }

    static func validateChange(existing: [M0ImageMetrics], replacementIndex: Int? = nil,
                               candidate: M0ImageMetrics, limits: M0ImageLimits = .init(),
                               retainingExtraBytes: Int = 0) throws -> M0CompositionPlan {
        guard retainingExtraBytes >= 0 else { throw M0ImageError.invalidMetrics }
        var proposed = existing
        var extraOldBytes = 0
        if let index = replacementIndex {
            guard proposed.indices.contains(index) else { throw M0ImageError.invalidReplacement }
            let old = proposed[index]
            extraOldBytes = try multiply(old.bytesPerRow, old.height)
            proposed[index] = candidate
        } else {
            proposed.append(candidate)
        }
        let heldExtraBytes = try add(extraOldBytes, retainingExtraBytes)
        let plan = try makePlan(metrics: proposed, limits: limits, retainingExtraBytes: heldExtraBytes)
        // During acquisition/color normalization, both old and new candidates can coexist.
        let candidateBytes = try multiply(candidate.bytesPerRow, candidate.height)
        let acquisitionPeak = try add(plan.sourceBytes, heldExtraBytes, candidateBytes)
        guard acquisitionPeak <= limits.maximumImageBytes else { throw M0ImageError.memoryLimit }
        return M0CompositionPlan(width: plan.width, height: plan.height, placements: plan.placements,
                                 sourcePixels: plan.sourcePixels, sourceBytes: plan.sourceBytes,
                                 outputBytes: plan.outputBytes, pngReserveBytes: plan.pngReserveBytes,
                                 previewReserveBytes: plan.previewReserveBytes,
                                 retainingExtraBytes: heldExtraBytes,
                                 estimatedPeakBytes: max(plan.estimatedPeakBytes, acquisitionPeak))
    }

    /// Cancel the detached worker explicitly and await its actual completion before returning.
    /// Sources remain borrowed until that completion, including during synchronous framework work.
    static func composeCancellable(assets: [M0ImageAsset], limits: M0ImageLimits = .init(),
                                   retainingExtraBytes: Int = 0,
                                   checkCancellation: @escaping @Sendable (M0CompositionCheckpoint) throws -> Void = { _ in })
        async throws -> M0CompositionResult {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try compose(assets: assets, limits: limits, retainingExtraBytes: retainingExtraBytes,
                        checkCancellation: { checkpoint in
                            try Task.checkCancellation()
                            try checkCancellation(checkpoint)
                            try Task.checkCancellation()
                        })
        }
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    static func compose(assets: [M0ImageAsset], limits: M0ImageLimits = .init(),
                        retainingExtraBytes: Int = 0,
                        checkCancellation: @Sendable (M0CompositionCheckpoint) throws -> Void = { _ in try Task.checkCancellation() })
        throws -> M0CompositionResult {
        try checkCancellation(.beforeAllocation)
        // Drain temporary Objective-C/bridging objects before handing the retained result to callers.
        // ImageIO's private allocations and allocator retention are not a process-memory guarantee.
        let result = try autoreleasepool {
            let plan = try makePlan(assets: assets, limits: limits, retainingExtraBytes: retainingExtraBytes)
            let image: CGImage
            if assets.count == 1 {
                image = assets[0].image
            } else {
                image = try render(assets: assets, plan: plan, checkCancellation: checkCancellation)
            }
            try checkCancellation(.beforeEncoding)
            let buffer = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(buffer as CFMutableData,
                                                                   UTType.png.identifier as CFString, 1, nil) else {
                throw M0ImageError.encodingFailed
            }
            CGImageDestinationAddImage(destination, image, nil)
            let encoded = CGImageDestinationFinalize(destination)
            try checkCancellation(.afterEncoding)
            guard encoded else { throw M0ImageError.encodingFailed }
            // Check the actual encoded length, including a second PNG store, before copying it.
            let retainedBytes = try validateEncodedBytes(plan: plan, pngByteCount: buffer.length,
                                                       isSingleImage: assets.count == 1, limits: limits)
            // Data(referencing:) may copy mutable NSData. Both stores were budgeted above.
            let pngData = Data(referencing: buffer)
            return M0CompositionResult(image: image, pngData: pngData, plan: plan, actualImageBytes: retainedBytes)
        }
        // Includes cancellation during the immutable Data copy or autorelease-pool cleanup.
        try checkCancellation(.beforeResult)
        return result
    }

    static func validateEncodedBytes(plan: M0CompositionPlan, pngByteCount: Int,
                                     isSingleImage: Bool, limits: M0ImageLimits = .init(),
                                     retainingExtraBytes: Int = 0) throws -> Int {
        guard pngByteCount > 0 else { throw M0ImageError.encodingFailed }
        guard retainingExtraBytes >= 0, isSingleImage == (plan.placements.count == 1) else {
            throw M0ImageError.invalidMetrics
        }
        // The plan's extra buffers are always inherited. This argument adds only buffers
        // not already represented by that plan (for example, a new UI-owned preview).
        let retainedBytes = try add(plan.sourceBytes, isSingleImage ? 0 : plan.outputBytes,
                                    pngByteCount, plan.previewReserveBytes,
                                    plan.retainingExtraBytes, retainingExtraBytes)
        let encodingPeak = try add(retainedBytes, pngByteCount)
        guard encodingPeak <= limits.maximumImageBytes else { throw M0ImageError.memoryLimit }
        // Return post-pool retention (one PNG), not the temporary encoding peak (two PNGs).
        return retainedBytes
    }

    private static func render(assets: [M0ImageAsset], plan: M0CompositionPlan,
                               checkCancellation: @Sendable (M0CompositionCheckpoint) throws -> Void) throws -> CGImage {
        let stride = try multiply(plan.width, 4)
        try checkCancellation(.beforeAllocation)
        guard let context = makeContext(width: plan.width, height: plan.height, bytesPerRow: stride) else {
            throw M0ImageError.contextCreationFailed
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(plan.width), height: CGFloat(plan.height)))
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        for placement in plan.placements {
            try checkCancellation(.beforeSource(index: placement.index))
            context.draw(assets[placement.index].image,
                         in: CGRect(x: CGFloat(placement.x),
                                    y: CGFloat(plan.height - placement.y - placement.height),
                                    width: CGFloat(placement.width), height: CGFloat(placement.height)))
            if let numberTop = placement.numberTop {
                drawText(String(placement.index + 1), size: 14, color: CGColor(gray: 0, alpha: 1),
                         x: 16, baseline: CGFloat(plan.height - numberTop - 18), context: context)
            }
        }
        try checkCancellation(.beforeAllocation)
        guard let image = context.makeImage() else { throw M0ImageError.contextCreationFailed }
        return image
    }

    fileprivate static func makeContext(width: Int, height: Int, bytesPerRow: Int) -> CGContext? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                         bytesPerRow: bytesPerRow, space: colorSpace,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                            CGBitmapInfo.byteOrder32Big.rawValue)
    }

    fileprivate static func drawText(_ text: String, size: CGFloat, color: CGColor,
                                     x: CGFloat, baseline: CGFloat, context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
        context.saveGState()
        context.setShouldAntialias(true)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    fileprivate static func add(_ values: Int...) throws -> Int {
        var result = 0
        for value in values {
            let next = result.addingReportingOverflow(value)
            guard !next.overflow else { throw M0ImageError.arithmeticOverflow }
            result = next.partialValue
        }
        return result
    }

    fileprivate static func multiply(_ values: Int...) throws -> Int {
        var result = 1
        for value in values {
            let next = result.multipliedReportingOverflow(by: value)
            guard !next.overflow else { throw M0ImageError.arithmeticOverflow }
            result = next.partialValue
        }
        return result
    }
}

/// These fabricated samples contain no screen, file or clipboard content.
enum M0ImageFixture {
    static func makeSamples(count: Int) throws -> [M0ImageAsset] {
        guard (1...4).contains(count) else { throw M0ImageError.countLimit }
        let sizes = [(720, 260, 1.0), (900, 320, 2.0), (640, 400, 1.0), (1_100, 220, 2.0)]
        return try (0..<count).map { index in
            try make(index: index + 1, width: sizes[index].0, height: sizes[index].1, scale: sizes[index].2)
        }
    }

    static func make(index: Int, width: Int, height: Int, scale: Double = 1) throws -> M0ImageAsset {
        guard (1...4).contains(index) else { throw M0ImageError.invalidMetrics }
        let metrics = M0ImageMetrics(width: width, height: height,
                                    bytesPerRow: try M0ImageComposer.multiply(width, 4), scale: scale)
        _ = try M0ImageComposer.makePlan(metrics: [metrics])
        guard let context = M0ImageComposer.makeContext(width: width, height: height, bytesPerRow: metrics.bytesPerRow) else {
            throw M0ImageError.contextCreationFailed
        }
        let palettes: [(CGFloat, CGFloat, CGFloat)] = [(0.12, 0.32, 0.57), (0.14, 0.43, 0.25),
                                                       (0.45, 0.20, 0.40), (0.45, 0.30, 0.08)]
        let color = palettes[index - 1]
        context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
        context.setLineWidth(1)
        for x in stride(from: 0, through: width, by: 32) {
            context.move(to: CGPoint(x: CGFloat(x), y: 0))
            context.addLine(to: CGPoint(x: CGFloat(x), y: CGFloat(height)))
        }
        for y in stride(from: 0, through: height, by: 32) {
            context.move(to: CGPoint(x: 0, y: CGFloat(y)))
            context.addLine(to: CGPoint(x: CGFloat(width), y: CGFloat(y)))
        }
        context.strokePath()
        let white = CGColor(gray: 1, alpha: 1)
        let lines: [(String, CGFloat)] = [
            ("OneClip fabricated sample \(index) / \(scale)x", 22),
            ("Error EXAMPLE-01 / setting: enabled", 16),
            ("Small text 12 px: before -> after / ABC 0123456789", 12)
        ]
        var baseline = CGFloat(height - 36)
        for (text, size) in lines {
            M0ImageComposer.drawText(text, size: size, color: white, x: 20, baseline: baseline, context: context)
            baseline -= 32
        }
        // Asymmetric markers make rotation, clipping and order visible.
        context.setFillColor(CGColor(srgbRed: 1, green: 0.75, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: CGFloat(max(0, height - 8)),
                            width: CGFloat(min(width, 40)), height: CGFloat(min(height, 8))))
        context.setFillColor(CGColor(srgbRed: 0, green: 0.9, blue: 1, alpha: 1))
        context.fill(CGRect(x: CGFloat(max(0, width - 16)), y: 0,
                            width: CGFloat(min(width, 16)), height: CGFloat(min(height, 16))))
        // Unique interior marker, distinct from the periodic grid/background.
        // Its absolute top-left origin is (300,160); runtime region tests must find it.
        if width >= 340, height >= 200 {
            context.setFillColor(CGColor(srgbRed: 1, green: 0.25, blue: 0.4, alpha: 1))
            context.fill(CGRect(x: 300, y: CGFloat(height - 176), width: 16, height: 16))
        }
        guard let image = context.makeImage() else { throw M0ImageError.contextCreationFailed }
        return M0ImageAsset(image: image, scale: scale)
    }
}
