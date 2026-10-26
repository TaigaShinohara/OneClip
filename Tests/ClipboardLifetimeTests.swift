import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Invoke producer and consumer as separate processes with the same fresh, dedicated UUID name.
/// This executable never accesses the general pasteboard, screen, permission API, or external file.
@main
struct ClipboardLifetimeTests {
    private enum Mode: String { case producer, consumer }
    private enum CheckFailure: Error { case failed }

    private static let prefix = "OneClip.ClipboardLifetime."
    private static let fixtureWidth = 73
    private static let fixtureHeight = 41

    @MainActor
    static func main() {
        // Complete all validation before constructing any pasteboard object.
        let arguments = CommandLine.arguments
        guard arguments.count == 3,
              let mode = Mode(rawValue: arguments[1]),
              isDedicatedName(arguments[2]) else {
            finish(passed: false)
            return
        }

        do {
            let board = NSPasteboard(name: NSPasteboard.Name(arguments[2]))
            switch mode {
            case .producer: try produce(to: board)
            case .consumer:
                // The consumer owns final cleanup, including a failed lifetime check.
                defer { board.releaseGlobally() }
                try consume(from: board)
            }
            finish(passed: true)
        } catch {
            finish(passed: false)
        }
    }

    private static func isDedicatedName(_ name: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let suffix = String(name.dropFirst(prefix.count))
        guard suffix.utf8.count == 36,
              let identifier = UUID(uuidString: suffix),
              identifier.uuidString == suffix.uppercased() else { return false }
        return true
    }

    @MainActor
    private static func produce(to board: NSPasteboard) throws {
        let asset = try M0ImageFixture.make(index: 1, width: fixtureWidth, height: fixtureHeight)
        let result = try M0ImageComposer.compose(assets: [asset])
        let outcome = M0ClipboardProbe.writePNG(result.pngData, to: board,
                                               expectedChangeCount: board.changeCount)
        guard outcome.writeAccepted else { throw CheckFailure.failed }
        // Deliberately no releaseGlobally: eager PNG bytes must survive this producer process.
    }

    @MainActor
    private static func consume(from board: NSPasteboard) throws {
        guard board.pasteboardItems?.count == 1,
              board.types?.contains(.png) == true,
              let data = board.data(forType: .png),
              Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sourceType = CGImageSourceGetType(source),
              sourceType as String == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == fixtureWidth, image.height == fixtureHeight,
              image.bitsPerComponent == 8 else { throw CheckFailure.failed }
        try checkPixel(image, x: 2, y: 2, expected: [255, 191, 0, 255])
        try checkPixel(image, x: fixtureWidth - 2, y: fixtureHeight - 2,
                       expected: [0, 230, 255, 255])
    }

    private static func checkPixel(_ image: CGImage, x: Int, y: Int, expected: [UInt8]) throws {
        guard let cropped = image.cropping(to: CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw CheckFailure.failed }
        var bytes: [UInt8] = [0, 0, 0, 0]
        try bytes.withUnsafeMutableBytes { memory in
            guard let context = CGContext(data: memory.baseAddress, width: 1, height: 1,
                                          bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                            CGBitmapInfo.byteOrder32Big.rawValue) else { throw CheckFailure.failed }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        guard zip(bytes, expected).allSatisfy({ pair in abs(Int(pair.0) - Int(pair.1)) <= 1 }) else {
            throw CheckFailure.failed
        }
    }

    private static func finish(passed: Bool) {
        print(passed ? "PASS" : "FAIL")
        if !passed { exit(EXIT_FAILURE) }
    }
}
