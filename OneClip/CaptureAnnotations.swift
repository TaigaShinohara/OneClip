import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Points use the original image's top-left origin, normalized to 0...1.
struct CaptureAnnotation: Sendable, Identifiable, Equatable {
    enum Kind: Sendable, Equatable { case comment, arrow, rectangle, number }
    let id: UUID
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var text: String
    var number: Int
    init(id: UUID = UUID(), kind: Kind, start: CGPoint, end: CGPoint,
         text: String = "", number: Int = 1) {
        self.id = id; self.kind = kind; self.start = start; self.end = end
        self.text = text; self.number = number
    }
}

enum CaptureAnnotationError: Error, Equatable, LocalizedError, Sendable {
    case tooManyAnnotations, invalidAnnotation, textLimit, emptyComment, commentDoesNotFit
    case invalidImageSource, unsupportedImage
    var errorDescription: String? {
        switch self {
        case .tooManyAnnotations: "注釈は100個までです。"
        case .invalidAnnotation: "注釈の位置・大きさ・番号を確認してください。"
        case .textLimit: "コメントは500文字までにしてください。"
        case .emptyComment: "コメントを入力してください。"
        case .commentDoesNotFit: "コメントを画像内に収められません。短くするか、大きい画像を使ってください。"
        case .invalidImageSource: "保存したPNG画像を読み込めませんでした。"
        case .unsupportedImage: "この画像形式には対応していません。8ビットのPNGを使ってください。"
        }
    }
}

/// Rasterizes annotations into PNG pixels; no editable layer or original is embedded.
/// Estimates cover owned buffers, not framework-private allocations or total process RSS.
enum CaptureAnnotationRenderer {
    static let maximumAnnotations = 100
    static let maximumCommentCharacters = 500
    private static var red: CGColor { CGColor(srgbRed: 0.88, green: 0.08, blue: 0.12, alpha: 1) }
    private static var white: CGColor { CGColor(gray: 1, alpha: 1) }
    private static var black: CGColor { CGColor(gray: 0.08, alpha: 1) }

    /// Metadata and file-size checks precede full decode. Normalize into an owned RGBA
    /// bitmap, so the returned image does not retain an ImageIO compressed-data provider.
    static func load(from url: URL, limits: M0ImageLimits = .init(),
                     retainingExtraBytes: Int = 0) throws -> M0ImageAsset {
        try Task.checkCancellation()
        try validateLimits(limits, extra: retainingExtraBytes)
        guard url.isFileURL else { throw CaptureAnnotationError.invalidImageSource }
        // Reserve the encoded Data and a possible ImageIO/CFData bridge before reading.
        guard retainingExtraBytes < limits.maximumImageBytes else { throw M0ImageError.memoryLimit }
        let maximumEncodedBytes = (limits.maximumImageBytes - retainingExtraBytes) / 2
        let archive = CaptureArchive(directory: url.standardizedFileURL.deletingLastPathComponent())
        let png = try archive.readSavedPNG(url, maximumBytes: maximumEncodedBytes)
        return try load(png: png, limits: limits, retainingExtraBytes: retainingExtraBytes)
    }

    static func load(png: Data, limits: M0ImageLimits = .init(), retainingExtraBytes: Int = 0) throws -> M0ImageAsset {
        try Task.checkCancellation()
        try validateLimits(limits, extra: retainingExtraBytes)
        guard !png.isEmpty else { throw CaptureAnnotationError.invalidImageSource }
        let encodedStores = try multiply(png.count, 2)
        let encodedExtra = try add(retainingExtraBytes, encodedStores)
        guard encodedExtra <= limits.maximumImageBytes else { throw M0ImageError.memoryLimit }
        return try autoreleasepool {
            guard let source = CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetType(source) as String? == UTType.png.identifier,
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                throw CaptureAnnotationError.invalidImageSource
            }
            let width = try positiveInteger(properties[kCGImagePropertyPixelWidth])
            let height = try positiveInteger(properties[kCGImagePropertyPixelHeight])
            guard try positiveInteger(properties[kCGImagePropertyDepth]) == 8 else { throw CaptureAnnotationError.unsupportedImage }
            let rgbaStride = try multiply(width, 4)
            let decodeStride = try multiply(try add(rgbaStride, 255) / 256, 256)
            _ = try makePlan(width: width, height: height, sourceStride: decodeStride,
                             annotationReserve: 0, limits: limits, extra: encodedExtra)
            try Task.checkCancellation()
            guard let decoded = CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  decoded.width == width, decoded.height == height,
                  decoded.bitsPerComponent == 8, decoded.bitsPerPixel <= 32,
                  !decoded.bitmapInfo.contains(.floatComponents) else { throw CaptureAnnotationError.unsupportedImage }
            _ = try makePlan(width: width, height: height, sourceStride: decoded.bytesPerRow,
                             annotationReserve: 0, limits: limits, extra: encodedExtra)
            try Task.checkCancellation()
            let normalized = try normalize(decoded, stride: rgbaStride)
            try Task.checkCancellation()
            return M0ImageAsset(image: normalized)
        }
    }

    static func makePlan(image: CGImage, annotations: [CaptureAnnotation], limits: M0ImageLimits = .init(),
                         retainingExtraBytes: Int = 0) throws -> M0CompositionPlan {
        try validateAnnotations(annotations)
        let longest = annotations.map { $0.text.utf16.count }.max() ?? 0
        // Only one CoreText layout is live at a time; text is bounded before layout.
        let reserve = annotations.isEmpty ? 0 : try add(1_048_576, multiply(longest, 1_024))
        let plan = try makePlan(width: image.width, height: image.height, sourceStride: image.bytesPerRow,
                                annotationReserve: reserve, limits: limits, extra: retainingExtraBytes)
        let size = CGSize(width: image.width, height: image.height)
        for annotation in annotations { _ = try bounds(for: annotation, imageSize: size) }
        return plan
    }

    static func render(image: CGImage, annotations: [CaptureAnnotation], limits: M0ImageLimits = .init(),
                       retainingExtraBytes: Int = 0,
                       checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> M0CompositionResult {
        try checkCancellation()
        let result = try autoreleasepool {
            let plan = try makePlan(image: image, annotations: annotations, limits: limits, retainingExtraBytes: retainingExtraBytes)
            try checkCancellation()
            let output = try renderedImage(image: image, annotations: annotations, checkCancellation: checkCancellation)
            try checkCancellation()
            let buffer = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(buffer as CFMutableData,
                    UTType.png.identifier as CFString, 1, nil) else { throw M0ImageError.encodingFailed }
            CGImageDestinationAddImage(destination, output, nil)
            guard CGImageDestinationFinalize(destination) else { throw M0ImageError.encodingFailed }
            try checkCancellation()
            // The plan's extras include the output bitmap. Check two PNG stores before bridging.
            let retained = try M0ImageComposer.validateEncodedBytes(plan: plan, pngByteCount: buffer.length,
                                                                    isSingleImage: true, limits: limits)
            let png = Data(referencing: buffer)
            return M0CompositionResult(image: output, pngData: png, plan: plan, actualImageBytes: retained)
        }
        try checkCancellation()
        return result
    }

    /// Shared by hit testing, selection frames and final output. Includes visible outlines.
    static func bounds(for annotation: CaptureAnnotation, imageSize: CGSize) throws -> CGRect {
        try validateAnnotation(annotation); try validateSize(imageSize)
        switch annotation.kind {
        case .comment: return try commentLayout(annotation, size: imageSize).rect
        case .number: return try numberLayout(annotation, size: imageSize).rect
        case .rectangle:
            return try rectangle(annotation, size: imageSize)
                .insetBy(dx: -outlineWidth(imageSize) / 2, dy: -outlineWidth(imageSize) / 2)
                .intersection(CGRect(origin: .zero, size: imageSize))
        case .arrow:
            let points = try arrowPoints(annotation, size: imageSize)
            let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
            let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .insetBy(dx: -outlineWidth(imageSize) / 2, dy: -outlineWidth(imageSize) / 2)
                .intersection(CGRect(origin: .zero, size: imageSize))
        }
    }

    /// The caller supplies a top-left-origin, Y-down pixel coordinate system.
    static func draw(_ annotations: [CaptureAnnotation], in context: CGContext, imageSize: CGSize) throws {
        try validateAnnotations(annotations); try validateSize(imageSize)
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: CGRect(origin: .zero, size: imageSize))
        context.setAllowsAntialiasing(true); context.setShouldAntialias(true)
        context.setLineCap(.round); context.setLineJoin(.round)
        for annotation in annotations {
            try autoreleasepool {
                switch annotation.kind {
                case .comment:
                    let layout = try commentLayout(annotation, size: imageSize)
                    let path = CGPath(roundedRect: layout.rect, cornerWidth: 7, cornerHeight: 7, transform: nil)
                    context.setFillColor(white); context.addPath(path); context.fillPath()
                    context.setStrokeColor(red); context.setLineWidth(min(2, min(imageSize.width, imageSize.height) / 4))
                    context.addPath(path); context.strokePath()
                    drawTextFrame(layout.frame, rect: layout.textRect, context: context)
                case .number:
                    let layout = try numberLayout(annotation, size: imageSize)
                    context.setFillColor(red); context.fillEllipse(in: layout.rect.insetBy(dx: 1, dy: 1))
                    context.setStrokeColor(white); context.setLineWidth(2)
                    context.strokeEllipse(in: layout.rect.insetBy(dx: 1, dy: 1))
                    drawCenteredLine(layout.line, rect: layout.rect, context: context)
                case .rectangle:
                    stroke(CGPath(rect: try rectangle(annotation, size: imageSize), transform: nil), context: context, size: imageSize)
                case .arrow:
                    let points = try arrowPoints(annotation, size: imageSize)
                    let path = CGMutablePath()
                    path.move(to: points[0]); path.addLine(to: points[1])
                    path.move(to: points[2]); path.addLine(to: points[1]); path.addLine(to: points[3])
                    stroke(path, context: context, size: imageSize)
                }
            }
        }
    }

    private static func makePlan(width: Int, height: Int, sourceStride: Int, annotationReserve: Int,
                                 limits: M0ImageLimits, extra: Int) throws -> M0CompositionPlan {
        try validateLimits(limits, extra: extra)
        guard width > 0, height > 0, sourceStride > 0, annotationReserve >= 0 else { throw M0ImageError.invalidMetrics }
        guard max(width, height) <= limits.maximumDimension else { throw M0ImageError.dimensionLimit }
        let pixels = try multiply(width, height)
        guard pixels <= limits.maximumSourcePixels else { throw M0ImageError.sourcePixelLimit }
        guard pixels <= limits.maximumOutputPixels else { throw M0ImageError.outputPixelLimit }
        let source = try multiply(sourceStride, height), output = try multiply(width, height, 4)
        let png = try add(output, output / 100, 65_536)
        let preview = try multiply(min(width, 1_024), min(height, 1_024), 4)
        let common = try add(source, preview, extra, annotationReserve)
        let peak = max(try add(common, multiply(output, 2)), try add(common, output, multiply(png, 2)))
        guard peak <= limits.maximumImageBytes else { throw M0ImageError.memoryLimit }
        return M0CompositionPlan(width: width, height: height,
            placements: [M0ImagePlacement(index: 0, x: 0, y: 0, width: width, height: height, numberTop: nil)],
            sourcePixels: pixels, sourceBytes: source, outputBytes: output, pngReserveBytes: png,
            previewReserveBytes: preview, retainingExtraBytes: try add(extra, output, annotationReserve), estimatedPeakBytes: peak)
    }

    private static func normalize(_ image: CGImage, stride: Int) throws -> CGImage {
        guard let context = makeContext(width: image.width, height: image.height, stride: stride) else { throw M0ImageError.contextCreationFailed }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw M0ImageError.contextCreationFailed }
        return result
    }

    private static func renderedImage(image: CGImage, annotations: [CaptureAnnotation],
                                      checkCancellation: @Sendable () throws -> Void) throws -> CGImage {
        guard let context = makeContext(width: image.width, height: image.height, stride: try multiply(image.width, 4)) else { throw M0ImageError.contextCreationFailed }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.translateBy(x: 0, y: CGFloat(image.height)); context.scaleBy(x: 1, y: -1)
        for annotation in annotations {
            try checkCancellation()
            try draw([annotation], in: context, imageSize: CGSize(width: image.width, height: image.height))
        }
        try checkCancellation()
        guard let output = context.makeImage() else { throw M0ImageError.contextCreationFailed }
        return output
    }

    private static func makeContext(width: Int, height: Int, stride: Int) -> CGContext? {
        guard let color = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride, space: color,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    }

    private struct CommentLayout { let rect: CGRect; let textRect: CGRect; let frame: CTFrame }
    private static func commentLayout(_ annotation: CaptureAnnotation, size: CGSize) throws -> CommentLayout {
        let text = annotation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CaptureAnnotationError.emptyComment }
        let margin = min(5, min(size.width, size.height) / 8), padding: CGFloat = 9
        let fontSize = max(14, min(34, size.width / 40))
        let font = CTFontCreateWithName("HiraginoSans-W4" as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): black
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let maxWidth = size.width - margin * 2, maxHeight = size.height - margin * 2
        guard maxWidth > padding * 2, maxHeight > padding * 2 + fontSize else { throw CaptureAnnotationError.commentDoesNotFit }
        for fraction in [CGFloat(0.42), 0.6, 0.8, 1] {
            let width = min(maxWidth, max(140, size.width * fraction)), innerWidth = width - padding * 2
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0),
                nil, CGSize(width: innerWidth, height: 1_000_000), nil)
            guard suggested.height.isFinite, suggested.height >= 0 else { throw CaptureAnnotationError.commentDoesNotFit }
            let innerHeight = ceil(suggested.height) + 2, height = innerHeight + padding * 2
            guard height <= maxHeight else { continue }
            let anchor = point(annotation.start, size: size, inset: 0)
            let rect = CGRect(x: clamp(anchor.x, margin, size.width - margin - width),
                              y: clamp(anchor.y, margin, size.height - margin - height), width: width, height: height)
            let textRect = rect.insetBy(dx: padding, dy: padding)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                CGPath(rect: CGRect(origin: .zero, size: textRect.size), transform: nil), nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.location == 0, visible.length >= attributed.length else { continue }
            return CommentLayout(rect: rect, textRect: textRect, frame: frame)
        }
        throw CaptureAnnotationError.commentDoesNotFit
    }

    private struct NumberLayout { let rect: CGRect; let line: CTLine }
    private static func numberLayout(_ annotation: CaptureAnnotation, size: CGSize) throws -> NumberLayout {
        let fontSize = max(12, min(28, min(size.width, size.height) / 24))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(annotation.number), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): white
        ]) as CFAttributedString)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), radius = ceil(max(fontSize, width / 2 + 6))
        guard radius * 2 + 2 <= min(size.width, size.height) else { throw CaptureAnnotationError.invalidAnnotation }
        let center = point(annotation.start, size: size, inset: radius + 1)
        return NumberLayout(rect: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), line: line)
    }

    private static func drawTextFrame(_ frame: CTFrame, rect: CGRect, context: CGContext) {
        context.saveGState(); context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity; CTFrameDraw(frame, context); context.restoreGState()
    }
    private static func drawCenteredLine(_ line: CTLine, rect: CGRect, context: CGContext) {
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        context.saveGState(); context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: (rect.width - width) / 2, y: (rect.height - ascent - descent) / 2 + descent)
        CTLineDraw(line, context); context.restoreGState()
    }

    private static func rectangle(_ annotation: CaptureAnnotation, size: CGSize) throws -> CGRect {
        let inset = outlineWidth(size) / 2
        let first = point(annotation.start, size: size, inset: inset), last = point(annotation.end, size: size, inset: inset)
        let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(first.x - last.x), height: abs(first.y - last.y))
        guard rect.width >= 1, rect.height >= 1 else { throw CaptureAnnotationError.invalidAnnotation }
        return rect
    }
    private static func arrowPoints(_ annotation: CaptureAnnotation, size: CGSize) throws -> [CGPoint] {
        let inset = outlineWidth(size) / 2
        let start = point(annotation.start, size: size, inset: inset), end = point(annotation.end, size: size, inset: inset)
        let dx = end.x - start.x, dy = end.y - start.y, length = hypot(dx, dy)
        guard length >= 1 else { throw CaptureAnnotationError.invalidAnnotation }
        let ux = dx / length, uy = dy / length
        let head = min(length * 0.4, max(8, min(24, min(size.width, size.height) / 25)))
        let left = CGPoint(x: end.x - ux * head - uy * head * 0.55, y: end.y - uy * head + ux * head * 0.55)
        let right = CGPoint(x: end.x - ux * head + uy * head * 0.55, y: end.y - uy * head - ux * head * 0.55)
        func bounded(_ p: CGPoint) -> CGPoint { CGPoint(x: clamp(p.x, inset, size.width - inset), y: clamp(p.y, inset, size.height - inset)) }
        return [start, end, bounded(left), bounded(right)]
    }
    private static func stroke(_ path: CGPath, context: CGContext, size: CGSize) {
        context.addPath(path); context.setStrokeColor(white); context.setLineWidth(outlineWidth(size)); context.strokePath()
        context.addPath(path); context.setStrokeColor(red); context.setLineWidth(max(0.5, outlineWidth(size) - 2)); context.strokePath()
    }
    private static func outlineWidth(_ size: CGSize) -> CGFloat { min(min(size.width, size.height), max(3, min(6, min(size.width, size.height) / 80))) }
    private static func point(_ p: CGPoint, size: CGSize, inset: CGFloat) -> CGPoint {
        CGPoint(x: clamp(clamp(p.x, 0, 1) * size.width, inset, size.width - inset), y: clamp(clamp(p.y, 0, 1) * size.height, inset, size.height - inset))
    }
    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat { max(lower, min(max(lower, upper), value)) }
    private static func validateAnnotations(_ annotations: [CaptureAnnotation]) throws {
        guard annotations.count <= maximumAnnotations else { throw CaptureAnnotationError.tooManyAnnotations }
        for annotation in annotations { try validateAnnotation(annotation) }
    }
    private static func validateAnnotation(_ a: CaptureAnnotation) throws {
        guard a.start.x.isFinite, a.start.y.isFinite, a.end.x.isFinite, a.end.y.isFinite else { throw CaptureAnnotationError.invalidAnnotation }
        guard a.text.count <= maximumCommentCharacters, a.text.utf16.count <= 2_000 else { throw CaptureAnnotationError.textLimit }
        if a.kind == .number, !(1...999).contains(a.number) { throw CaptureAnnotationError.invalidAnnotation }
    }
    private static func validateSize(_ size: CGSize) throws {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { throw M0ImageError.invalidMetrics }
    }
    private static func validateLimits(_ limits: M0ImageLimits, extra: Int) throws {
        guard extra >= 0, limits.maximumCount > 0, limits.maximumDimension > 0, limits.maximumSourcePixels > 0,
              limits.maximumOutputPixels > 0, limits.maximumImageBytes > 0 else { throw M0ImageError.invalidMetrics }
    }
    private static func positiveInteger(_ value: Any?) throws -> Int {
        guard let value = value as? NSNumber else { throw CaptureAnnotationError.invalidImageSource }
        let number = value.doubleValue
        guard number.isFinite, number > 0, number < Double(Int.max), number.rounded(.towardZero) == number else { throw CaptureAnnotationError.invalidImageSource }
        return value.intValue
    }
    private static func add(_ values: Int...) throws -> Int {
        var result = 0
        for value in values { let next = result.addingReportingOverflow(value); guard !next.overflow else { throw M0ImageError.arithmeticOverflow }; result = next.partialValue }
        return result
    }
    private static func multiply(_ values: Int...) throws -> Int {
        var result = 1
        for value in values { let next = result.multipliedReportingOverflow(by: value); guard !next.overflow else { throw M0ImageError.arithmeticOverflow }; result = next.partialValue }
        return result
    }
}
