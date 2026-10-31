import AppKit
import Foundation

/// Default execution uses fabricated PNGs, a temporary archive and disabled previews.
/// It never initializes NSApplication, captures a screen, opens another app, or reads a pasteboard.
@main
@MainActor
struct CaptureResultControllerTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneClip-ResultTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if CommandLine.arguments.contains("--window-fixture") {
            try await writeWindowFixture(root: root)
            return
        }
        let png = try M0ImageComposer.compose(assets: [M0ImageFixture.make(index: 1, width: 360, height: 210)]).pngData
        try await testCopiedAndSaved(root: root, png: png)
        print("PASS RESULT-01 clipboard acceptance preserves identical saved PNG")
        try await testCopyFailureAndRetry(root: root, png: png)
        print("PASS RESULT-02 copy failure still saves and copy retry does not duplicate the file")
        try await testModeIdentity(root: root, png: png)
        print("PASS RESULT-03 result identity and mode keep archive URLs associated correctly")
        try await testSaveFailureAndRepair(root: root, png: png)
        print("PASS RESULT-04 save failure retains PNG and explicit retry recovers it")
        try await testDiscard(root: root, png: png)
        print("PASS RESULT-05 discarding unsaved data ends retention and prevents retry")
        try await testInvalidation(root: root, png: png)
        print("PASS RESULT-06 environment invalidation rejects late UI and state callbacks")
        print("PASS 6 result groups; synthetic files and disabled previews only")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }

    static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw Failure(description: "Result worker did not reach its expected state")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    static func outputs(in archive: CaptureArchive) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: archive.directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
    }

    static func testCopiedAndSaved(root: URL, png: Data) async throws {
        let archive = CaptureArchive(directory: root.appendingPathComponent("copied"))
        let controller = CaptureResultController(archive: archive, previewsEnabled: false)
        controller.receive(png, copied: true)
        try expect(controller.isSaving && controller.hasPendingSave, "Save was not started independently")
        try await waitUntil { !controller.isSaving }
        guard let saved = controller.latestURL else { throw Failure(description: "Accepted copy was not saved") }
        let savedBytes = try Data(contentsOf: saved)
        try expect(savedBytes == png, "Saved bytes differ from copied PNG")
        try expect(!controller.hasPendingSave, "Saved PNG remained pending")
        try expect(controller.message == "コピー・保存しました", "Combined success was reported incorrectly")
        try expect(!controller.isPreviewVisible, "Disabled preview created a window")
        controller.dismissPreview()
        try expect(FileManager.default.fileExists(atPath: saved.path), "Dismissing preview removed the saved capture")
        controller.environmentDidChange()
        try expect(controller.latestURL == saved, "Environment change lost the saved file reference")
    }

    static func testCopyFailureAndRetry(root: URL, png: Data) async throws {
        let archive = CaptureArchive(directory: root.appendingPathComponent("copy-failed"))
        let controller = CaptureResultController(archive: archive, previewsEnabled: false)
        let resultID = UUID()
        controller.receive(png, copied: false, id: resultID)
        try await waitUntil { !controller.isSaving }
        guard let saved = controller.latestURL else { throw Failure(description: "Clipboard failure prevented saving") }
        let savedBytes = try Data(contentsOf: saved)
        try expect(savedBytes == png && !controller.hasPendingSave, "Copy failure lost PNG bytes")
        try expect(controller.message == "保存しました。コピーはできませんでした", "Copy failure was hidden by save success")
        controller.receive(png, copied: true, id: resultID)
        let retryFiles = try outputs(in: archive)
        try expect(!controller.isSaving && controller.latestURL == saved && retryFiles.count == 1,
                   "Retrying the same copy duplicated the archive")
        try expect(controller.message == "コピー・保存しました", "Accepted retry did not update copy status")
        controller.receive(png, copied: true)
        try await waitUntil { !controller.isSaving }
        let repeatedFiles = try outputs(in: archive)
        try expect(controller.latestURL != saved && repeatedFiles.count == 2, "A new capture reused an old output")
        let originalBytes = try Data(contentsOf: saved)
        try expect(originalBytes == png, "Repeated capture replaced its predecessor")
    }

    static func testModeIdentity(root: URL, png: Data) async throws {
        let archive = CaptureArchive(directory: root.appendingPathComponent("identities"))
        let controller = CaptureResultController(archive: archive, previewsEnabled: false)
        let collectionID = UUID()
        let singleID = UUID()
        let singlePNG = try M0ImageComposer.compose(assets: [M0ImageFixture.make(index: 2, width: 360, height: 210)]).pngData
        controller.receive(png, copied: true, id: collectionID, mode: .collection)
        try await waitUntil { !controller.isSaving }
        guard let collectionURL = controller.latestURL else { throw Failure(description: "Collection output missing") }
        controller.receive(singlePNG, copied: true, id: singleID, mode: .single)
        try await waitUntil { !controller.isSaving }
        guard let singleURL = controller.latestURL else { throw Failure(description: "Single output missing") }
        try expect(singleURL != collectionURL, "Different capture modes shared one file")
        controller.receive(png, copied: true, id: collectionID, mode: .collection)
        let afterCollectionRetry = try outputs(in: archive)
        try expect(!controller.isSaving && controller.latestURL == collectionURL && afterCollectionRetry.count == 2,
                   "Collection recopy after a single capture used the wrong URL or duplicated its file")
        let originalCollection = try Data(contentsOf: collectionURL)
        let originalSingle = try Data(contentsOf: singleURL)
        try expect(originalCollection == png && originalSingle == singlePNG, "Interleaved modes changed saved bytes")

        // A failed encode never publishes a result. Its eventual successful retry has a
        // fresh result identity and must not borrow the preceding single capture's URL.
        let newID = UUID()
        controller.receive(png, copied: true, id: newID, mode: .single)
        try await waitUntil { !controller.isSaving }
        guard let newSingleURL = controller.latestURL else { throw Failure(description: "New single result missing") }
        try expect(newSingleURL != singleURL && newSingleURL != collectionURL,
                   "A new capture identity borrowed an older saved file")
        controller.receive(png, copied: true, id: newID, mode: .collection)
        try await waitUntil { !controller.isSaving }
        guard let newCollectionURL = controller.latestURL else { throw Failure(description: "New collection result missing") }
        let modeFiles = try outputs(in: archive)
        try expect(newCollectionURL != newSingleURL && modeFiles.count == 4,
                   "Equal IDs from different modes reused one archive entry")
        controller.receive(png, copied: true, id: collectionID, mode: .collection)
        try await waitUntil { !controller.isSaving }
        let boundedCacheFiles = try outputs(in: archive)
        try expect(controller.latestURL != collectionURL && boundedCacheFiles.count == 5,
                   "Archive association retained more than the last result for its mode")
    }

    static func testSaveFailureAndRepair(root: URL, png: Data) async throws {
        let blocked = root.appendingPathComponent("repair")
        try Data([0]).write(to: blocked)
        let archive = CaptureArchive(directory: blocked)
        let controller = CaptureResultController(archive: archive, previewsEnabled: false)
        controller.receive(png, copied: true)
        try await waitUntil { !controller.isSaving }
        try expect(controller.hasPendingSave && controller.latestURL == nil, "Failed save lost pending data or claimed a file")
        try expect(controller.message == "コピーしました。保存できませんでした", "Save failure changed copy result")
        try FileManager.default.removeItem(at: blocked)
        controller.retrySave()
        try expect(controller.isSaving, "Explicit retry did not start saving")
        try await waitUntil { !controller.isSaving }
        guard let saved = controller.latestURL else { throw Failure(description: "Repaired destination did not save pending PNG") }
        let savedBytes = try Data(contentsOf: saved)
        try expect(savedBytes == png && !controller.hasPendingSave, "Retry did not preserve pending capture")
        try expect(controller.message == "コピー・保存しました", "Recovered save did not report both outcomes")
    }

    static func testDiscard(root: URL, png: Data) async throws {
        let blocked = root.appendingPathComponent("discard")
        try Data([0]).write(to: blocked)
        let controller = CaptureResultController(archive: CaptureArchive(directory: blocked), previewsEnabled: false)
        controller.receive(png, copied: false)
        try await waitUntil { !controller.isSaving }
        try expect(controller.hasPendingSave && controller.message == "コピー・保存ができませんでした",
                   "Double failure did not retain unsaved capture")
        controller.discardUnsaved()
        try expect(!controller.hasPendingSave && !controller.isSaving && controller.latestURL == nil,
                   "Discard did not clear pending ownership")
        try FileManager.default.removeItem(at: blocked)
        controller.retrySave()
        try expect(!controller.isSaving && !FileManager.default.fileExists(atPath: blocked.path),
                   "Retry resurrected discarded capture")
    }

    static func testInvalidation(root: URL, png: Data) async throws {
        let archive = CaptureArchive(directory: root.appendingPathComponent("invalidated"))
        let controller = CaptureResultController(archive: archive, previewsEnabled: false)
        controller.receive(png, copied: true)
        // No suspension before invalidation: the main-actor completion cannot have run.
        controller.environmentDidChange()
        try expect(controller.isSaving && !controller.hasPendingSave && controller.latestURL == nil,
                   "Invalidation lost the active save gate or retained unsaved ownership")
        try await waitUntil { !controller.isSaving }
        // The gate stays occupied until the disk task actually returns. Its obsolete
        // callback must release the gate without restoring invalidated image state.
        try expect(!controller.isSaving && !controller.hasPendingSave && controller.latestURL == nil,
                   "Late save callback restored invalidated state")
        try expect(!controller.isPreviewVisible, "Late callback reopened preview")
        let files = try outputs(in: archive)
        let durableBytes = try Data(contentsOf: files[0])
        try expect(durableBytes == png, "Previously requested durable save was corrupted by invalidation")
    }

    /// Opt-in only. This renders this process's own synthetic panel content directly;
    /// it does not use screenshot APIs, inspect another window, or access the display pixels.
    static func writeWindowFixture(root: URL) async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let archive = CaptureArchive(directory: root.appendingPathComponent("fixture"))
        let controller = CaptureResultController(archive: archive)
        let png = try M0ImageComposer.compose(assets: [M0ImageFixture.make(index: 1, width: 720, height: 320)]).pngData
        let fixtureID = UUID()
        controller.receive(png, copied: true, id: fixtureID)
        controller.dismissPreview()
        try await waitUntil { !controller.isSaving }
        try expect(!controller.isPreviewVisible, "Save completion reopened a dismissed preview")
        controller.receive(png, copied: true, id: fixtureID)
        try await waitUntil { controller.isPreviewVisible }
        guard let window = application.windows.first(where: { $0 is NSPanel && $0.isVisible }),
              let content = window.contentView else {
            throw Failure(description: "Synthetic preview panel did not appear")
        }
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw Failure(description: "Synthetic panel could not allocate its bitmap")
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure(description: "Synthetic panel could not encode its bitmap")
        }
        try data.write(to: URL(fileURLWithPath: "/private/tmp/oneclip-preview-fixture.png"), options: .atomic)
        controller.dismissPreview()
        try expect(!controller.isPreviewVisible, "Fixture panel remained visible")
        controller.receive(png, copied: true)
        controller.environmentDidChange()
        try await waitUntil { !controller.isSaving }
        try expect(!controller.isPreviewVisible, "Environment invalidation allowed a late preview")
        print("PASS RESULT-FIXTURE own synthetic panel bitmap rendered; dismissal and invalidation keep it hidden")
    }
}
