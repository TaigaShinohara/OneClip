import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fabricated in-memory images and unique temporary files only; no screen or pasteboard access.
@main
struct CaptureAnnotationsTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    enum Injected: Error { case cancelled }
    final class Checkpoints: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OneClip-Annotations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try whiteImage(width: 800, height: 500)
        try testRasterization(image)
        print("PASS ANNOTATION-01 all four annotation kinds flatten into original-size PNG without changing the source")
        try testCommentLayout(image)
        print("PASS ANNOTATION-02 Japanese multiline text is drawn fully and edge layouts stay inside the image")
        try testValidation(image)
        print("PASS ANNOTATION-03 nonfinite coordinates, empty or oversized text and excessive notes are rejected")
        try testBudget(image)
        print("PASS ANNOTATION-04 source, output and external retention enforce the image budget")
        try testCancellation(image)
        print("PASS ANNOTATION-05 cancellation at rendering boundaries does not mutate the source")
        try testLoad(image, root: root)
        print("PASS ANNOTATION-06 PNG load validates metadata, regular files and source boundaries")
        print("PASS 6 annotation renderer groups; synthetic images and temporary files only")
    }

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(description: message) }
    }
    static func expectError(_ body: () throws -> Void) throws {
        var threw = false
        do { try body() } catch { threw = true }
        try expect(threw, "Invalid operation unexpectedly succeeded")
    }
    static func whiteImage(width: Int, height: Int) throws -> CGImage {
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw Failure(description: "Could not make fabricated image")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw Failure(description: "Could not finish fabricated image") }
        return result
    }
    static func bytes(_ image: CGImage) throws -> [UInt8] {
        var storage = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try storage.withUnsafeMutableBytes { buffer in
            guard let color = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: color,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw Failure(description: "Could not inspect fabricated pixels")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return storage
    }
    static func decoded(_ png: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(description: "Output was not a PNG") }
        return image
    }
    static func testRasterization(_ source: CGImage) throws {
        let before = try bytes(source)
        let kinds: [CaptureAnnotation] = [
            .init(kind: .comment, start: CGPoint(x: 0.12, y: 0.1), end: .zero, text: "ここを修正してください\n余白を広くする"),
            .init(kind: .arrow, start: CGPoint(x: 0.15, y: 0.2), end: CGPoint(x: 0.82, y: 0.78)),
            .init(kind: .rectangle, start: CGPoint(x: 0.1, y: 0.1), end: CGPoint(x: 0.85, y: 0.85)),
            .init(kind: .number, start: CGPoint(x: 0.5, y: 0.5), end: .zero, number: 12)
        ]
        for note in kinds {
            let result = try CaptureAnnotationRenderer.render(image: source, annotations: [note])
            let pngImage = try decoded(result.pngData)
            try expect(result.image.width == source.width && result.image.height == source.height
                       && pngImage.width == source.width && pngImage.height == source.height, "Annotations changed pixel dimensions")
            let after = try bytes(pngImage)
            try expect(after != before, "Annotation was not flattened into the PNG")
            let redPixels = stride(from: 0, to: after.count, by: 4).filter { after[$0] > 140 && after[$0 + 1] < 100 && after[$0 + 2] < 120 }.count
            try expect(redPixels > 20, "Annotation has no visible red mark or outline")
        }
        let unchanged = try bytes(source)
        try expect(before == unchanged, "Rendering changed the original image")
    }
    static func testCommentLayout(_ source: CGImage) throws {
        let size = CGSize(width: source.width, height: source.height)
        let canvas = CGRect(origin: .zero, size: size)
        let text = "①このボタンの色を変更してください\n②ラベルを『保存する』に変更\n③余白を少し広げてください"
        for point in [CGPoint.zero, CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)] {
            let note = CaptureAnnotation(kind: .comment, start: point, end: point, text: text)
            let bounds = try CaptureAnnotationRenderer.bounds(for: note, imageSize: size)
            try expect(canvas.contains(bounds) && bounds.height > 50 && bounds.width > 100, "Multiline comment escaped its image")
            let rendered = try CaptureAnnotationRenderer.render(image: source, annotations: [note])
            let renderedBytes = try bytes(try decoded(rendered.pngData))
            let darkPixels = stride(from: 0, to: renderedBytes.count, by: 4).filter {
                renderedBytes[$0] < 90 && renderedBytes[$0 + 1] < 90 && renderedBytes[$0 + 2] < 90
            }.count
            try expect(darkPixels > 100, "Japanese text was not drawn into the comment")
        }
        let tiny = try whiteImage(width: 24, height: 24)
        let note = CaptureAnnotation(kind: .comment, start: .zero, end: .zero, text: "画像に入らないコメント")
        try expectError { _ = try CaptureAnnotationRenderer.render(image: tiny, annotations: [note]) }
    }
    static func testValidation(_ image: CGImage) throws {
        let bad: [CaptureAnnotation] = [
            .init(kind: .arrow, start: CGPoint(x: CGFloat.nan, y: 0), end: CGPoint(x: 1, y: 1)),
            .init(kind: .comment, start: .zero, end: .zero, text: "   \n "),
            .init(kind: .comment, start: .zero, end: .zero, text: String(repeating: "字", count: 501)),
            .init(kind: .number, start: .zero, end: .zero, number: 0),
            .init(kind: .number, start: .zero, end: .zero, number: 1_000)
        ]
        for note in bad { try expectError { _ = try CaptureAnnotationRenderer.makePlan(image: image, annotations: [note]) } }
        let note = CaptureAnnotation(kind: .number, start: CGPoint(x: 0.5, y: 0.5), end: .zero)
        try expectError { _ = try CaptureAnnotationRenderer.makePlan(image: image, annotations: Array(repeating: note, count: 101)) }
        let outside = CaptureAnnotation(kind: .number, start: CGPoint(x: -5, y: 8), end: .zero)
        let bounds = try CaptureAnnotationRenderer.bounds(for: outside, imageSize: CGSize(width: image.width, height: image.height))
        try expect(CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(bounds), "Finite outside coordinates were not clamped")
    }
    static func testBudget(_ image: CGImage) throws {
        let notes = [CaptureAnnotation(kind: .comment, start: .zero, end: .zero, text: "変更する場所")]
        let plan = try CaptureAnnotationRenderer.makePlan(image: image, annotations: notes)
        try expect(plan.estimatedPeakBytes > image.bytesPerRow * image.height * 2, "Render budget omitted source and output buffers")
        var limit = M0ImageLimits()
        limit.maximumImageBytes = plan.estimatedPeakBytes - 1
        try expectError { _ = try CaptureAnnotationRenderer.makePlan(image: image, annotations: notes, limits: limit) }
        limit.maximumImageBytes = plan.estimatedPeakBytes
        _ = try CaptureAnnotationRenderer.makePlan(image: image, annotations: notes, limits: limit)
        try expectError { _ = try CaptureAnnotationRenderer.makePlan(image: image, annotations: notes, limits: limit, retainingExtraBytes: 1) }
        try expectError { _ = try CaptureAnnotationRenderer.makePlan(image: image, annotations: notes, retainingExtraBytes: Int.max) }
        try expectError { _ = try CaptureAnnotationRenderer.makePlan(image: image, annotations: notes, retainingExtraBytes: -1) }
    }
    static func testCancellation(_ image: CGImage) throws {
        let original = try bytes(image)
        let note = CaptureAnnotation(kind: .arrow, start: CGPoint(x: 0.1, y: 0.1), end: CGPoint(x: 0.8, y: 0.8))
        let checkpoints = Checkpoints()
        try expectError {
            _ = try CaptureAnnotationRenderer.render(image: image, annotations: [note]) {
                if checkpoints.next() == 3 { throw Injected.cancelled }
            }
        }
        let after = try bytes(image)
        try expect(original == after, "Cancelled render changed the original")
    }
    static func testLoad(_ image: CGImage, root: URL) throws {
        let encoded = try M0ImageComposer.compose(assets: [M0ImageAsset(image: image)]).pngData
        let original = root.appendingPathComponent("original.png")
        try encoded.write(to: original)
        let loaded = try CaptureAnnotationRenderer.load(from: original)
        try expect(loaded.image.width == image.width && loaded.image.height == image.height, "Loading changed image dimensions")
        let loadedBytes = try bytes(loaded.image), sourceBytes = try bytes(image)
        try expect(loadedBytes == sourceBytes, "RGBA normalization changed fabricated pixels")
        var limit = M0ImageLimits(); limit.maximumDimension = 100
        try expectError { _ = try CaptureAnnotationRenderer.load(from: original, limits: limit) }
        let corrupt = root.appendingPathComponent("corrupt.png")
        try Data([1, 2, 3]).write(to: corrupt)
        try expectError { _ = try CaptureAnnotationRenderer.load(from: corrupt) }
        let link = root.appendingPathComponent("symbolic.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        try expectError { _ = try CaptureAnnotationRenderer.load(from: link) }
        try expectError { _ = try CaptureAnnotationRenderer.load(from: root) }
        try expectError { _ = try CaptureAnnotationRenderer.load(from: URL(string: "https://example.invalid/test.png")!) }
        let unchanged = try Data(contentsOf: original)
        try expect(unchanged == encoded, "Load checks modified the saved original")
    }
}
