import AppKit
import Foundation
import ImageIO
import QuartzCore

/// Uses fabricated PNGs, temporary archives and an injected fake clipboard.
/// NSApplication is initialized only by the explicit --window-fixture option.
@main
@MainActor
struct CaptureAnnotationControllerTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor final class Environment { var available = true }
    @MainActor final class Clipboard: CaptureClipboardWriting {
        enum Mode { case accepted, rejected }
        var mode = Mode.accepted
        var count = 4
        var calls = 0
        var payloads: [Data] = []
        var accepted: [Data] = []
        var changeCount: Int { count }
        func writePNG(_ data: Data, expectedChangeCount: Int) -> M0ClipboardProbe.Outcome {
            calls += 1
            payloads.append(data)
            guard count == expectedChangeCount else {
                return .init(code: .conflictBeforePrepare, expectedChangeCount: expectedChangeCount,
                             observedChangeCount: count, preparedChangeCount: nil)
            }
            count += 1
            guard mode == .accepted else {
                return .init(code: .writeRejected, expectedChangeCount: expectedChangeCount,
                             observedChangeCount: count, preparedChangeCount: count)
            }
            accepted.append(data)
            return .init(code: .writeAccepted, expectedChangeCount: expectedChangeCount,
                         observedChangeCount: count, preparedChangeCount: count)
        }
    }
    @MainActor final class Harness {
        let source: URL
        let sourcePNG: Data
        let archive: CaptureArchive
        let results: CaptureResultController
        let clipboard: Clipboard
        let environment: Environment
        let controller: CaptureAnnotationController
        init(root: URL, name: String, saveWorks: Bool = true, showsWindow: Bool = false) throws {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sourceURL = directory.appendingPathComponent("capture-original.png")
            let encoded = try M0ImageComposer.compose(assets: [M0ImageFixture.make(index: 1, width: 1000, height: 600)]).pngData
            let outputArchive = CaptureArchive(directory: directory.appendingPathComponent("outputs"))
            let outputResults = CaptureResultController(archive: outputArchive, previewsEnabled: false)
            let injectedClipboard = Clipboard()
            let injectedEnvironment = Environment()
            try encoded.write(to: sourceURL)
            if !saveWorks { try Data([0]).write(to: outputArchive.directory) }
            source = sourceURL
            sourcePNG = encoded
            archive = outputArchive
            results = outputResults
            clipboard = injectedClipboard
            environment = injectedEnvironment
            controller = CaptureAnnotationController(results: outputResults, clipboard: injectedClipboard, showsWindow: showsWindow,
                                                     environmentCheck: { injectedEnvironment.available })
        }
        func load() async throws {
            controller.open(source)
            await controller.waitForWorker()
            try expect(controller.image != nil && controller.isOpen && !controller.isWorking,
                       "Fabricated source did not open")
        }
        func draft(_ text: String = "ここを修正してください\nラベルを短くする", at point: CGPoint = CGPoint(x: 0.08, y: 0.1)) {
            controller.tool = .comment
            controller.gesture(from: point, to: point)
            controller.commentDraft = text
        }
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OneClip-AnnotationController-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if CommandLine.arguments.contains("--window-fixture") || CommandLine.arguments.contains("--show-window") {
            try await writeWindowFixture(root); return
        }
        try await testDraftExport(root)
        print("PASS ANNOTATION-DOC-01 draft comments flatten, save and copy identical PNG while preserving the original")
        try await testEditingAndHistory(root)
        print("PASS ANNOTATION-DOC-02 comment re-editing, grouped movement and Undo/Redo retain one document")
        try await testPartialFailures(root)
        print("PASS ANNOTATION-DOC-03 copy/save outcomes remain independent and save-only retries do not recopy")
        try await testInvalidation(root)
        print("PASS ANNOTATION-DOC-04 invalidation rejects late load and export without reviving a document or copying")
        try await testAdmissionAndDirtyClose(root)
        print("PASS ANNOTATION-DOC-05 dirty close and repeated entry preserve pending annotations")
        try await testClipboardConflict(root)
        print("PASS ANNOTATION-DOC-06 a clipboard change during rendering is not overwritten")
        try await testRemovingLastAnnotation(root)
        print("PASS ANNOTATION-DOC-07 removing the last annotation exports the original pixels and clears dirty state")
        try await testNewDocumentIdentity(root)
        print("PASS ANNOTATION-DOC-08 a new document exports its own pixels rather than a previous result URL")
        try await testSynchronousEnvironmentFences(root)
        print("PASS ANNOTATION-DOC-09 reopen, show, Undo and Redo synchronously invalidate unavailable images")
        print("PASS 9 annotation controller groups; injected clipboard and synthetic files only")
    }
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(description: message) }
    }
    static func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw Failure(description: "Worker did not settle") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    static func outputs(_ archive: CaptureArchive) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: archive.directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: archive.directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
    }
    static func testDraftExport(_ root: URL) async throws {
        let h = try Harness(root: root, name: "export")
        try await h.load()
        h.draft()
        try expect(h.controller.annotations.isEmpty && h.controller.hasDraftChanges && h.controller.canExport,
                   "Unapplied comment draft was not eligible for explicit export")
        h.controller.saveAndCopy()
        await h.controller.waitForWorker()
        try expect(h.controller.annotations.count == 1 && h.controller.annotations[0].text.contains("ラベル"),
                   "Export omitted the unapplied Japanese draft")
        try expect(h.clipboard.accepted.count == 1, "Export did not copy its flattened image")
        guard let saved = h.results.latestURL else { throw Failure(description: "Export did not create a saved file") }
        let savedPNG = try Data(contentsOf: saved)
        let originalPNG = try Data(contentsOf: h.source)
        try expect(savedPNG == h.clipboard.accepted[0] && savedPNG != originalPNG && originalPNG == h.sourcePNG,
                   "Saved and copied pixels differ, or the original was changed")
        try expect(!h.controller.isDirty && h.controller.statusText.contains("保存・コピー"), "Complete success remained dirty or was not described")
        h.controller.saveAndCopy()
        await h.controller.waitForWorker()
        let files = try outputs(h.archive)
        try expect(h.clipboard.accepted.count == 2 && files.count == 1 && h.results.latestURL == saved,
                   "Copying unchanged annotations duplicated the archive")
        try expect(h.controller.requestClose() && !h.controller.isOpen && h.controller.image == nil,
                   "A clean exported document did not close")
        let remaining = try Data(contentsOf: saved)
        try expect(remaining == savedPNG, "Closing the document removed or changed its saved PNG")
    }
    static func testEditingAndHistory(_ root: URL) async throws {
        let h = try Harness(root: root, name: "history")
        try await h.load()
        h.draft("最初の指示")
        h.controller.applyComment()
        let id = h.controller.annotations[0].id
        h.controller.commentDraft = "改稿した指示\n位置も動かす"
        h.controller.applyComment()
        try expect(h.controller.annotations[0].id == id && h.controller.annotations[0].text.contains("改稿"),
                   "Re-editing changed the annotation identity or lost the text")
        let beforeMove = h.controller.annotations
        h.controller.beginMove()
        h.controller.moveSelected(by: CGPoint(x: 0.1, y: 0.05))
        h.controller.moveSelected(by: CGPoint(x: 0.02, y: 0.02))
        h.controller.endMove()
        let afterMove = h.controller.annotations
        try expect(afterMove != beforeMove && h.controller.canUndo, "Dragging did not move the selected comment")
        h.controller.undo()
        try expect(h.controller.annotations == beforeMove && h.controller.canRedo, "One Undo did not reverse the whole drag")
        h.controller.redo()
        try expect(h.controller.annotations == afterMove, "Redo did not restore the drag")
        h.controller.tool = nil
        let bounds = try CaptureAnnotationRenderer.bounds(for: h.controller.annotations[0], imageSize: CGSize(width: 1000, height: 600))
        h.controller.select(at: CGPoint(x: bounds.midX / 1000, y: bounds.midY / 600))
        try expect(h.controller.selectedID == id, "Hit testing did not select the comment")
        h.controller.deleteSelected()
        try expect(h.controller.annotations.isEmpty, "Selected comment was not deleted")
        h.controller.undo()
        try expect(h.controller.annotations == afterMove, "Undo did not restore the deleted comment")
        h.controller.invalidate()
    }
    static func testPartialFailures(_ root: URL) async throws {
        for saveWorks in [false, true] {
            for copyWorks in [false, true] {
                let h = try Harness(root: root, name: "outcome-\(saveWorks)-\(copyWorks)", saveWorks: saveWorks)
                try await h.load()
                h.clipboard.mode = copyWorks ? .accepted : .rejected
                h.draft("AIへ渡す指示")
                h.controller.saveAndCopy()
                await h.controller.waitForWorker()
                try expect(h.clipboard.calls == 1 && (h.clipboard.accepted.count == 1) == copyWorks,
                           "Save failure changed clipboard acceptance")
                try expect((h.results.latestURL != nil) == saveWorks && h.results.hasPendingSave == !saveWorks,
                           "Clipboard failure changed independent save outcome")
                try expect(h.controller.annotations.count == 1, "Partial failure discarded the editing document")
                if let url = h.results.latestURL {
                    let saved = try Data(contentsOf: url)
                    try expect(saved == h.clipboard.payloads[0], "Partial success saved a different PNG")
                }
                if !saveWorks {
                    try FileManager.default.removeItem(at: h.archive.directory)
                    h.results.retrySave()
                    try await waitUntil { !h.results.isSaving }
                    try expect(h.results.latestURL != nil && !h.results.hasPendingSave && h.clipboard.calls == 1,
                               "Save-only retry either copied again or failed to preserve the PNG")
                    let before = try outputs(h.archive)
                    h.clipboard.mode = .accepted
                    h.controller.saveAndCopy()
                    await h.controller.waitForWorker()
                    let after = try outputs(h.archive)
                    try expect(before.count == 1 && after.count == 1 && h.clipboard.calls == 2,
                               "Retrying clipboard after repaired save duplicated the file")
                }
                h.controller.invalidate()
            }
        }
    }
    static func testInvalidation(_ root: URL) async throws {
        let loading = try Harness(root: root, name: "late-load")
        loading.controller.open(loading.source)
        loading.controller.invalidate()
        try expect(loading.controller.isWorking && loading.controller.blocksCapture, "Invalidating a load released its live worker gate")
        loading.controller.open(loading.source)
        try expect(!loading.controller.isOpen, "A new document entered while the old load was returning")
        await loading.controller.waitForWorker()
        try expect(!loading.controller.isOpen && !loading.controller.isWorking && loading.controller.image == nil,
                   "Late load resurrected an invalidated image")
        let exporting = try Harness(root: root, name: "late-export")
        try await exporting.load()
        exporting.draft()
        exporting.controller.applyComment()
        exporting.controller.saveAndCopy()
        exporting.controller.invalidate()
        await exporting.controller.waitForWorker()
        try expect(exporting.clipboard.calls == 0 && exporting.results.latestURL == nil
                   && exporting.controller.annotations.isEmpty && exporting.controller.image == nil && !exporting.controller.isOpen,
                   "Late export copied or revived an invalidated document")
        let unavailable = try Harness(root: root, name: "environment-check")
        try await unavailable.load()
        unavailable.draft()
        unavailable.controller.saveAndCopy()
        unavailable.environment.available = false
        await unavailable.controller.waitForWorker()
        try expect(unavailable.clipboard.calls == 0 && !unavailable.controller.isOpen && unavailable.controller.image == nil,
                   "Final environment fence did not stop export")
    }
    static func testAdmissionAndDirtyClose(_ root: URL) async throws {
        let h = try Harness(root: root, name: "admission")
        h.controller.canOpen = { false }
        h.controller.open(h.source)
        try expect(!h.controller.isOpen && !h.controller.isWorking, "Rejected entry opened a document")
        h.controller.canOpen = { true }
        try await h.load()
        h.draft("保存前のコメント")
        try expect(!h.controller.requestClose() && h.controller.hasDraftChanges && h.controller.isOpen,
                   "Dirty close silently dropped an unapplied comment")
        h.controller.applyComment()
        let oldNotes = h.controller.annotations
        let other = root.appendingPathComponent("different.png")
        let otherPNG = try M0ImageComposer.compose(assets: [M0ImageFixture.make(index: 2, width: 800, height: 400)]).pngData
        try otherPNG.write(to: other)
        h.controller.open(other)
        try expect(h.controller.annotations == oldNotes && h.controller.image?.image.width == 1000,
                   "Repeated entry silently replaced the existing document")
        h.controller.invalidate()
        try expect(!h.controller.isOpen && !h.controller.canUndo && !h.controller.canRedo && !h.controller.blocksCapture,
                   "Invalidation retained a document or its history gate")
    }
    static func testClipboardConflict(_ root: URL) async throws {
        let h = try Harness(root: root, name: "clipboard-race")
        try await h.load()
        h.draft("この範囲を修正")
        h.controller.saveAndCopy()
        h.clipboard.count += 1 // Another app copies after the explicit export starts.
        await h.controller.waitForWorker()
        try expect(h.clipboard.calls == 1 && h.clipboard.accepted.isEmpty && h.results.latestURL != nil,
                   "Clipboard conflict either overwrote a new copy or prevented saving")
        try expect(h.controller.statusText.contains("コピーできません"), "Clipboard conflict was reported as success")
        h.controller.invalidate()
    }
    static func rgba(_ image: CGImage) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try buffer.withUnsafeMutableBytes { bytes in
            guard let color = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: color,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw Failure(description: "Could not inspect synthetic pixels")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return buffer
    }
    static func testRemovingLastAnnotation(_ root: URL) async throws {
        let h = try Harness(root: root, name: "remove-last")
        try await h.load()
        guard let original = h.controller.image?.image else { throw Failure(description: "Source image missing") }
        let originalPixels = try rgba(original)
        h.draft("あとで削除する指示")
        h.controller.saveAndCopy()
        await h.controller.waitForWorker()
        h.controller.deleteSelected()
        try expect(h.controller.annotations.isEmpty && h.controller.isDirty && h.controller.canExport,
                   "Removing the last note made an unexportable dirty document")
        h.controller.saveAndCopy()
        await h.controller.waitForWorker()
        guard let data = h.clipboard.accepted.last,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let output = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let url = h.results.latestURL else { throw Failure(description: "Empty annotation output missing") }
        let outputPixels = try rgba(output)
        let savedData = try Data(contentsOf: url)
        try expect(outputPixels == originalPixels && savedData == data && !h.controller.isDirty,
                   "Removing all notes failed to export and save the original pixels")
        h.controller.invalidate()
    }
    static func testNewDocumentIdentity(_ root: URL) async throws {
        let h = try Harness(root: root, name: "new-document")
        try await h.load()
        h.draft("前の画像だけに付けた指示")
        h.controller.saveAndCopy()
        await h.controller.waitForWorker()
        guard let firstURL = h.results.latestURL else { throw Failure(description: "First export missing") }
        try expect(h.controller.requestClose(), "First clean document did not close")
        let secondSource = root.appendingPathComponent("new-document-source-B.png")
        let secondPNG = try M0ImageComposer.compose(assets: [M0ImageFixture.make(index: 2, width: 800, height: 400)]).pngData
        try secondPNG.write(to: secondSource)
        h.controller.open(secondSource)
        await h.controller.waitForWorker()
        guard let image = h.controller.image?.image else { throw Failure(description: "Second document did not load") }
        let expectedPixels = try rgba(image)
        try expect(h.controller.annotations.isEmpty && h.controller.canExport, "New document inherited old annotations")
        h.controller.saveAndCopy()
        await h.controller.waitForWorker()
        guard let secondURL = h.results.latestURL, let copied = h.clipboard.accepted.last,
              let source = CGImageSourceCreateWithData(copied as CFData, nil),
              let output = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure(description: "Second document export missing")
        }
        let saved = try Data(contentsOf: secondURL)
        let outputPixels = try rgba(output)
        let sourceUnchanged = try Data(contentsOf: secondSource)
        try expect(secondURL != firstURL && output.width == 800 && output.height == 400
                   && saved == copied && outputPixels == expectedPixels && sourceUnchanged == secondPNG,
                   "New document reused the previous capture's saved URL or pixels")
        h.controller.invalidate()
    }
    static func testSynchronousEnvironmentFences(_ root: URL) async throws {
        for operation in ["show", "open", "undo", "redo"] {
            let h = try Harness(root: root, name: "fence-" + operation)
            try await h.load()
            h.draft("環境失効時に残さない指示")
            h.controller.applyComment()
            if operation == "redo" { h.controller.undo() }
            h.environment.available = false
            switch operation {
            case "show": h.controller.show()
            case "open": h.controller.open(h.source)
            case "undo": h.controller.undo()
            default: h.controller.redo()
            }
            try expect(!h.controller.isOpen && h.controller.image == nil && h.controller.annotations.isEmpty
                       && !h.controller.canUndo && !h.controller.canRedo && !h.controller.blocksCapture
                       && h.clipboard.calls == 0,
                       "A public editing action retained or revived an unavailable document")
        }
    }
    /// Pump this process's event loop so AppKit and SwiftUI can commit their own layers.
    /// No display pixels, other processes, or screenshot APIs are accessed.
    static func pumpApplication(_ application: NSApplication, seconds: TimeInterval) {
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                application.stop(nil)
                if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                    application.postEvent(event, atStart: false)
                }
            }
        }
        application.run()
        timer.invalidate()
    }
    static func usableFixture(_ bitmap: NSBitmapImageRep) throws -> Bool {
        guard let image = bitmap.cgImage else { return false }
        let pixels = try rgba(image)
        var opaque = 0
        var colors = Set<UInt32>()
        // Sample independently of the bitmap's native layout or premultiplication.
        for index in stride(from: 0, to: pixels.count, by: 64) {
            guard index + 3 < pixels.count, pixels[index + 3] > 32 else { continue }
            opaque += 1
            colors.insert(UInt32(pixels[index]) << 16 | UInt32(pixels[index + 1]) << 8 | UInt32(pixels[index + 2]))
        }
        return opaque > max(100, pixels.count / 64 / 10) && colors.count > 16
    }
    static func writeWindowFixture(_ root: URL) async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let h = try Harness(root: root, name: "window-fixture", showsWindow: true)
        try await h.load()
        h.controller.tool = .rectangle
        h.controller.gesture(from: CGPoint(x: 0.07, y: 0.3), to: CGPoint(x: 0.4, y: 0.76))
        h.controller.tool = .arrow
        h.controller.gesture(from: CGPoint(x: 0.6, y: 0.7), to: CGPoint(x: 0.34, y: 0.45))
        h.controller.tool = .number
        h.controller.gesture(from: CGPoint(x: 0.11, y: 0.2), to: CGPoint(x: 0.11, y: 0.2))
        h.draft("① 囲んだ説明文を短くする\n② 余白を少し広くしてください", at: CGPoint(x: 0.5, y: 0.1))
        h.controller.applyComment()
        pumpApplication(application, seconds: 0.4)
        guard let window = application.windows.first(where: { $0.title.contains("コメント・記号") && $0.isVisible }),
              let content = window.contentView else { throw Failure(description: "Synthetic annotation editor did not appear") }
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        window.display()
        content.displayIfNeeded()
        content.layer?.displayIfNeeded()
        CATransaction.flush()
        pumpApplication(application, seconds: 0.2)
        var rendered: NSBitmapImageRep?
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            if try usableFixture(bitmap) { rendered = bitmap }
        }
        if rendered == nil, let layer = content.layer {
            let scale = window.backingScaleFactor
            let width = Int(ceil(content.bounds.width * scale)), height = Int(ceil(content.bounds.height * scale))
            if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
               let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                context.cgContext.scaleBy(x: scale, y: scale)
                layer.render(in: context.cgContext)
                if try usableFixture(bitmap) { rendered = bitmap }
            }
        }
        let showWindow = CommandLine.arguments.contains("--show-window")
        if let rendered, let png = rendered.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: "/private/tmp/oneclip-annotation-fixture.png"))
            print("PASS ANNOTATION-FIXTURE nonblank own editor view rendered; no screenshot API or OS pasteboard used")
        } else if !showWindow {
            h.controller.invalidate()
            throw Failure(description: "Own editor view rendering was transparent or single-color; fixture is not verified")
        } else {
            print("UNVERIFIED ANNOTATION-FIXTURE direct rendering unavailable; own window remains available for inspection")
        }
        if showWindow {
            FileHandle.standardOutput.write(Data("ANNOTATION-FIXTURE_READY own synthetic window retained for 45 seconds\n".utf8))
            pumpApplication(application, seconds: 45)
        }
        h.controller.invalidate()
    }
}
