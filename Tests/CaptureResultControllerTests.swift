import AppKit
import Foundation

/// Default execution uses fabricated PNGs, a temporary archive and disabled previews.
/// It never initializes NSApplication, captures a screen, opens another app, or reads a pasteboard.
private final class SaveGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false, released = false
    let archive: CaptureArchive
    init(_ archive: CaptureArchive) { self.archive = archive }
    var isWaiting: Bool {
        condition.lock(); defer { condition.unlock() }
        return entered && !released
    }
    func waitForRelease() {
        condition.lock()
        entered = true
        while !released { condition.wait() }
        condition.unlock()
    }
    func save(_ png: Data) throws -> URL {
        waitForRelease()
        return try archive.save(png)
    }
    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

private final class InputLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    var isReleased: Bool { lock.lock(); defer { lock.unlock() }; return released }
    func finish() { lock.lock(); released = true; lock.unlock() }
}


@MainActor
private final class ExternalBudgetBox {
    var bytes: Int
    init(_ bytes: Int = 0) { self.bytes = bytes }
}

/// Captured MainActor callbacks model delayed Launch Services completion without opening an
/// app. Delivery is synchronous in tests, so stale-error rejection needs no timing assumption.
@MainActor
private final class PreviewLaunchProbe {
    private(set) var applications: [URL] = []
    private(set) var targets: [URL] = []
    private var completions: [CaptureResultController.PreviewServices.Completion?] = []
    private(set) var errors = 0
    var services: CaptureResultController.PreviewServices {
        .init(resolveApplication: { TrustedPreviewApplication.systemURL }, launch: { [self] target, application, completion in
            targets.append(target); applications.append(application); completions.append(completion)
        }, errorPresenter: { [self] in errors += 1 })
    }
    func complete(_ index: Int, failed: Bool) {
        let callback = completions[index]
        completions[index] = nil
        callback?(failed)
    }
}

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
        try await testGatedWorkerInvalidation(root: root, png: png)
        print("PASS RESULT-07 real save worker retains its budget until return and rejects stale UI")
        try await testBudgetAdmissionAndRecovery(root: root, png: png)
        print("PASS RESULT-08 budget rejection preserves input and explicit retry recovers")
        try await testIndependentThumbnail(root: root, png: png)
        print("PASS RESULT-09 bounded independent thumbnail releases its input PNG allocation")
        try await testChangedSavedCapture(root: root, png: png)
        print("PASS RESULT-10 saved-ID reuse verifies current bytes and replaces no existing file")
        try await testEditingWorkerInvalidation(root: root, png: png)
        print("PASS RESULT-11 editing worker keeps admission until return and suppresses stale open")
        try await testEditingBudgetAndRecovery(root: root, png: png)
        print("PASS RESULT-12 edit workspace joins the image budget and explicit retry recovers")
        try await testExplicitEditingAfterDismissal(root: root, png: png)
        print("PASS RESULT-13 a new explicit edit works after dismissal while a mid-worker close suppresses late open")
        try await testDelayedPreviewLaunchErrors(root: root, png: png)
        print("PASS RESULT-14 delayed Preview errors obey close, edit, receipt and invalidation generations")
        print("PASS 14 result groups; synthetic files, disabled previews and injected launch services only")
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
        try await waitUntil { !controller.isSaving }
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
        try await waitUntil { !controller.isSaving }
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

    static func testGatedWorkerInvalidation(root: URL, png: Data) async throws {
        let archive = CaptureArchive(directory: root.appendingPathComponent("gated-invalidation"))
        let gate = SaveGate(archive)
        defer { gate.release() }
        let trace = CaptureSecurityTrace(enabled: true, trial: 1)
        let controller = CaptureResultController(archive: archive, previewsEnabled: false,
            securityTrace: trace, saver: { try gate.save($0) })
        controller.receive(png, copied: true, mode: .collection)
        try await waitUntil { gate.isWaiting }
        let workerPNG = png.count * 2
        let thumbnailReserve = CaptureResultController.thumbnailWorkspaceReserveBytes
        try expect(controller.saveWorkerPNGBytes == workerPNG && controller.workerThumbnailReserveBytes == thumbnailReserve
                   && controller.retainedImageBytes == png.count + workerPNG + thumbnailReserve,
                   "Pending PNG, active worker or thumbnail reserve was omitted")
        controller.environmentDidChange()
        try expect(controller.isSaving && !controller.hasPendingSave && controller.thumbnailHeldBytes == 0
                   && controller.retainedImageBytes == workerPNG + thumbnailReserve,
                   "Invalidation released the live worker reservation or retained pending image state")
        controller.receive(png, copied: false, mode: .single)
        controller.retrySave()
        let whileBlocked = trace.snapshot().entries
        try expect(whileBlocked.filter { $0.code == .archiveQueued }.count == 1
                   && whileBlocked.contains { $0.code == .resultReceived && $0.outcome == .rejected },
                   "A second save overlapped an invalidated live worker")
        gate.release()
        try await waitUntil { !controller.isSaving }
        try expect(controller.retainedImageBytes == 0 && controller.saveWorkerPNGBytes == 0
                   && controller.workerThumbnailReserveBytes == 0 && controller.latestURL == nil
                   && !controller.hasPendingSave && !controller.isPreviewVisible,
                   "Actual return restored stale image/UI state or leaked its gate")
        let rows = trace.snapshot().entries
        guard let invalidation = rows.first(where: { $0.code == .resultInvalidated }),
              let returned = rows.first(where: { $0.code == .archiveReturned }),
              let stale = rows.first(where: { $0.code == .archiveOutcome && $0.outcome == .stale }) else {
            throw Failure(description: "Save/invalidation/return evidence was incomplete")
        }
        try expect(invalidation.sequence < returned.sequence && returned.sequence < stale.sequence,
                   "Worker return or stale disposition ordering changed")
        try expect(!rows.contains { $0.sequence > invalidation.sequence && ($0.code == .resultPreviewShown
                   || $0.code == .resultPreviewDraw || ($0.code == .archiveOutcome && $0.outcome == .accepted)) },
                   "An obsolete save produced accepted state or image presentation")
        let files = try outputs(in: archive)
        guard files.count == 1 else { throw Failure(description: "Requested durable output was missing or duplicated") }
        let savedBytes = try Data(contentsOf: files[0])
        try expect(savedBytes == png, "The requested durable save was deleted or corrupted by image invalidation")
        controller.receive(png, copied: false, mode: .collection)
        try await waitUntil { !controller.isSaving }
        try expect(controller.latestURL != nil && !controller.hasPendingSave && controller.thumbnailHeldBytes > 0,
                   "A fresh explicit receipt did not recover after the old worker returned")
        try expect(!trace.snapshot().entries.contains { [.resultPreviewShown, .resultPreviewHidden, .resultPreviewDraw].contains($0.code) },
                   "Disabled preview reported a real display observation")
        controller.dismissPreview()
    }

    static func testBudgetAdmissionAndRecovery(root: URL, png: Data) async throws {
        let archive = CaptureArchive(directory: root.appendingPathComponent("budget-recovery"))
        let gate = SaveGate(archive)
        defer { gate.release() }
        let trace = CaptureSecurityTrace(enabled: true, trial: 1)
        let exact = png.count * 3 + CaptureResultController.thumbnailWorkspaceReserveBytes
        var limits = M0ImageLimits(); limits.maximumImageBytes = exact
        let controller = CaptureResultController(archive: archive, previewsEnabled: false,
            securityTrace: trace, limits: limits, saver: { try gate.save($0) })
        let external = ExternalBudgetBox(Int.max)
        let resultID = UUID()
        controller.externalRetainedBytes = { external.bytes }
        controller.receive(png, copied: true, id: resultID)
        for rejected in [Int.max, -1, 1] {
            external.bytes = rejected
            controller.retrySave()
            try expect(!controller.isSaving && controller.hasPendingSave && controller.retainedImageBytes == png.count
                       && controller.saveWorkerPNGBytes == 0 && controller.workerThumbnailReserveBytes == 0
                       && controller.message.contains("作業領域"), "Invalid external budget started a worker or lost the pending capture")
        }
        try expect(!trace.snapshot().entries.contains { $0.code == .archiveQueued || $0.code == .archiveStarted },
                   "A rejected budget allocated a thumbnail/save worker")
        controller.externalRetainedBytes = { throw M0ImageError.memoryLimit }
        controller.retrySave()
        try expect(!controller.isSaving && controller.hasPendingSave, "A failed external estimate admitted work")
        controller.externalRetainedBytes = { external.bytes }
        external.bytes = 0
        controller.retrySave()
        try await waitUntil { gate.isWaiting }
        try expect(controller.isSaving && controller.retainedImageBytes == exact,
                   "The exact finite budget was not admitted after explicit retry")
        gate.release()
        try await waitUntil { !controller.isSaving }
        try expect(!controller.hasPendingSave && controller.latestURL != nil
                   && controller.saveWorkerPNGBytes == 0 && controller.workerThumbnailReserveBytes == 0,
                   "Budget recovery failed to finish or release its reservation")
        controller.dismissPreview()
        external.bytes = Int.max
        controller.receive(png, copied: true, id: resultID)
        try expect(!controller.isSaving && controller.hasPendingSave && controller.latestURL == nil
                   && controller.thumbnailHeldBytes == 0, "Saved-ID thumbnail work bypassed admission or claimed unchecked success")
        external.bytes = 0
        controller.retrySave()
        try await waitUntil { !controller.isSaving }
        let reusedFiles = try outputs(in: archive)
        try expect(reusedFiles.count == 1 && controller.latestURL != nil
                   && trace.snapshot().entries.contains { $0.code == .archiveReturned && $0.outcome == .unchanged },
                   "Budget recovery did not validate/reuse the exact saved bytes")
        controller.dismissPreview()
        let blockedArchive = CaptureArchive(directory: root.appendingPathComponent("budget-below"))
        limits.maximumImageBytes = exact - 1
        let below = CaptureResultController(archive: blockedArchive, previewsEnabled: false, limits: limits)
        below.receive(png, copied: false)
        try expect(!below.isSaving && below.hasPendingSave && below.thumbnailHeldBytes == 0
                   && !FileManager.default.fileExists(atPath: blockedArchive.directory.path),
                   "One byte over the proposed budget performed disk or thumbnail work")
        below.discardUnsaved()
    }

    static func testIndependentThumbnail(root: URL, png: Data) async throws {
        let archive = CaptureArchive(directory: root.appendingPathComponent("independent-thumbnail"))
        let controller = CaptureResultController(archive: archive, previewsEnabled: false)
        let lifetime = InputLifetime()
        let sourcePNG = try M0ImageComposer.compose(assets: [M0ImageFixture.make(index: 1, width: 960, height: 640)]).pngData
        let allocation = UnsafeMutableRawPointer.allocate(byteCount: sourcePNG.count, alignment: 16)
        sourcePNG.copyBytes(to: allocation.assumingMemoryBound(to: UInt8.self), count: sourcePNG.count)
        var input: Data? = Data(bytesNoCopy: allocation, count: sourcePNG.count, deallocator: .custom { memory, _ in
            memory.deallocate(); lifetime.finish()
        })
        controller.receive(input!, copied: true)
        input = nil
        try await waitUntil { !controller.isSaving && lifetime.isReleased }
        try expect(controller.thumbnailHeldBytes > 0
                   && controller.thumbnailHeldBytes <= 480 * 480 * 4
                   && controller.retainedImageBytes == controller.thumbnailHeldBytes,
                   "Thumbnail dimensions/storage were unbounded or still owned its input PNG")
        controller.environmentDidChange()
        try expect(controller.retainedImageBytes == 0 && controller.thumbnailHeldBytes == 0,
                   "Invalidation retained the independent thumbnail")
    }

    static func testChangedSavedCapture(root: URL, png: Data) async throws {
        let changedPNG = try M0ImageComposer.compose(assets: [M0ImageFixture.make(index: 2, width: 360, height: 210)]).pngData
        for kind in 0..<3 {
            let archive = CaptureArchive(directory: root.appendingPathComponent("changed-cache-\(kind)"))
            let controller = CaptureResultController(archive: archive, previewsEnabled: false)
            let id = UUID()
            controller.receive(png, copied: true, id: id)
            try await waitUntil { !controller.isSaving }
            guard let original = controller.latestURL else { throw Failure(description: "Cache precondition was missing") }
            if kind == 0 { try changedPNG.write(to: original) }
            else if kind == 1 { try FileManager.default.removeItem(at: original) }
            else {
                let replacement = root.appendingPathComponent("synthetic-cache-target.png")
                try changedPNG.write(to: replacement)
                try FileManager.default.removeItem(at: original)
                try FileManager.default.createSymbolicLink(at: original, withDestinationURL: replacement)
            }
            controller.receive(png, copied: true, id: id)
            try await waitUntil { !controller.isSaving }
            guard let current = controller.latestURL else { throw Failure(description: "Changed cache did not save a current PNG") }
            let currentBytes = try Data(contentsOf: current)
            try expect(current != original && currentBytes == png,
                       "Modified, missing or replaced saved path was reused as the current PNG")
            if kind == 0 {
                let oldBytes = try Data(contentsOf: original)
                try expect(oldBytes == changedPNG, "Saving current bytes overwrote the changed old file")
            }
            controller.dismissPreview()
        }
    }

    static func testEditingWorkerInvalidation(root: URL, png: Data) async throws {
        let directory = root.appendingPathComponent("gated-edit")
        let gate = SaveGate(CaptureArchive(directory: directory))
        defer { gate.release() }
        let archive = CaptureArchive(directory: directory, testingHooks: .init(afterSourceOpened: { gate.waitForRelease() }))
        let trace = CaptureSecurityTrace(enabled: true, trial: 1)
        var opened: [URL] = []
        let controller = CaptureResultController(archive: archive, previewsEnabled: false,
            securityTrace: trace, opener: { opened.append($0) })
        let id = UUID()
        controller.receive(png, copied: true, id: id)
        try await waitUntil { !controller.isSaving }
        guard let original = controller.latestURL else { throw Failure(description: "Editing precondition missing") }
        let thumbnailBytes = controller.thumbnailHeldBytes
        controller.editLatest()
        try expect(controller.isSaving && controller.editWorkerReserveBytes == 65_536,
                   "Editing did not acquire the shared admission/quit gate")
        try await waitUntil { gate.isWaiting }
        try expect(controller.retainedImageBytes == thumbnailBytes + 65_536,
                   "Editing workspace was not counted alongside the visible thumbnail")
        controller.environmentDidChange()
        try expect(controller.isSaving && controller.retainedImageBytes == 65_536
                   && controller.editWorkerReserveBytes == 65_536 && controller.thumbnailHeldBytes == 0,
                   "Environment invalidation freed a live editing worker or retained its preview")
        controller.editLatest()
        controller.receive(png, copied: true)
        gate.release()
        try await waitUntil { !controller.isSaving }
        try expect(opened.isEmpty && controller.retainedImageBytes == 0 && controller.editWorkerReserveBytes == 0,
                   "An invalidated editing completion opened a file or retained capacity")
        let staleFiles = try outputs(in: archive)
        try expect(staleFiles.count == 2 && controller.latestURL == original,
                   "Invalidation deleted the requested durable editing output or original")
        try expect(!controller.isSaving && trace.snapshot().entries.filter { $0.code == .editCopyStarted }.count == 1,
                   "A stale hidden result automatically started another editing worker")
        let rows = trace.snapshot().entries
        guard let invalidated = rows.first(where: { $0.code == .resultInvalidated }),
              let returned = rows.first(where: { $0.code == .editCopyReturned }) else {
            throw Failure(description: "Editing return/invalidation evidence missing")
        }
        try expect(invalidated.sequence < returned.sequence && !rows.contains { $0.code == .resultPreviewShown || $0.code == .resultPreviewDraw },
                   "Editing interval was not established or a disabled preview claimed display evidence")
        controller.receive(png, copied: true, id: id)
        try await waitUntil { !controller.isSaving }
        controller.editLatest()
        try await waitUntil { !controller.isSaving }
        guard let target = opened.first else { throw Failure(description: "Explicit edit did not open its injected target") }
        let targetBytes = try Data(contentsOf: target)
        try expect(opened.count == 1 && target != original && targetBytes == png,
                   "Explicit editing failed to preserve original bytes or escaped the injected opener")
        let beforeReuse = try outputs(in: archive).count
        controller.receive(png, copied: true, id: id)
        try await waitUntil { !controller.isSaving }
        controller.editLatest()
        try await waitUntil { !controller.isSaving }
        let afterReuse = try outputs(in: archive).count
        try expect(opened.count == 2 && opened[1] == target && beforeReuse == afterReuse,
                   "A validated editing association made an unnecessary copy")
        let replacement = root.appendingPathComponent("synthetic-edited-target.png")
        try png.write(to: replacement)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: replacement)
        controller.receive(png, copied: true, id: id)
        try await waitUntil { !controller.isSaving }
        controller.editLatest()
        try await waitUntil { !controller.isSaving }
        try expect(opened.count == 2 && controller.message.contains("作れませんでした"),
                   "A replaced editing path reached the opener or hid failure")
        controller.dismissPreview()
    }

    static func testEditingBudgetAndRecovery(root: URL, png: Data) async throws {
        let archive = CaptureArchive(directory: root.appendingPathComponent("edit-budget"))
        let trace = CaptureSecurityTrace(enabled: true, trial: 1)
        var limits = M0ImageLimits()
        limits.maximumImageBytes = png.count * 3 + CaptureResultController.thumbnailWorkspaceReserveBytes
        var opened: [URL] = []
        let controller = CaptureResultController(archive: archive, previewsEnabled: false,
            securityTrace: trace, limits: limits, opener: { opened.append($0) })
        controller.receive(png, copied: true)
        try await waitUntil { !controller.isSaving }
        let external = ExternalBudgetBox()
        controller.externalRetainedBytes = { external.bytes }
        let before = controller.retainedImageBytes
        for unavailable in [Int.max, -1, limits.maximumImageBytes - before - 65_536 + 1] {
            external.bytes = unavailable
            controller.editLatest()
            try expect(!controller.isSaving && controller.editWorkerReserveBytes == 0
                       && controller.retainedImageBytes == before && opened.isEmpty
                       && controller.message.contains("作業領域"), "Editing bypassed its checked workspace admission")
        }
        try expect(!trace.snapshot().entries.contains { $0.code == .editCopyStarted },
                   "An over-budget editing request reached file IO")
        external.bytes = 0
        controller.editLatest()
        try await waitUntil { !controller.isSaving }
        try expect(opened.count == 1 && controller.editWorkerReserveBytes == 0
                   && controller.retainedImageBytes == 0, "Explicit editing failed to recover and release the preview")
    }

    static func testExplicitEditingAfterDismissal(root: URL, png: Data) async throws {
        let archive = CaptureArchive(directory: root.appendingPathComponent("explicit-hidden-edit"))
        var opened: [URL] = []
        let controller = CaptureResultController(archive: archive, previewsEnabled: false,
            opener: { opened.append($0) })
        controller.receive(png, copied: true)
        try await waitUntil { !controller.isSaving }
        guard let original = controller.latestURL else { throw Failure(description: "Hidden edit precondition missing") }
        controller.dismissPreview()
        controller.editLatest()
        try await waitUntil { !controller.isSaving }
        guard let edited = opened.first else { throw Failure(description: "A fresh explicit edit after dismissal was ignored") }
        let originalBytes = try Data(contentsOf: original)
        let editingBytes = try Data(contentsOf: edited)
        try expect(opened.count == 1 && original != edited && originalBytes == png && editingBytes == png,
                   "Explicit menu editing after hide lost or changed the saved image")

        let directory = root.appendingPathComponent("closed-during-edit")
        let gate = SaveGate(CaptureArchive(directory: directory))
        defer { gate.release() }
        let gatedArchive = CaptureArchive(directory: directory, testingHooks: .init(afterSourceOpened: { gate.waitForRelease() }))
        var lateOpens: [URL] = []
        let closed = CaptureResultController(archive: gatedArchive, previewsEnabled: false,
            opener: { lateOpens.append($0) })
        closed.receive(png, copied: true)
        try await waitUntil { !closed.isSaving }
        closed.dismissPreview()
        closed.editLatest()
        try await waitUntil { gate.isWaiting }
        closed.dismissPreview()
        try expect(closed.isSaving && closed.editWorkerReserveBytes == 65_536,
                   "Closing a preview released the real editing worker early")
        gate.release()
        try await waitUntil { !closed.isSaving }
        try expect(lateOpens.isEmpty && closed.editWorkerReserveBytes == 0,
                   "A close during editing allowed a late external open")
    }

    static func testDelayedPreviewLaunchErrors(root: URL, png: Data) async throws {
        // Each case first launches through the production controller path with a fake resolver,
        // launcher and error presenter. No system bundle is read and no NSApplication is made.
        for invalidator in 0..<4 {
            let archive = CaptureArchive(directory: root.appendingPathComponent("delayed-preview-\(invalidator)"))
            let probe = PreviewLaunchProbe()
            let controller = CaptureResultController(archive: archive, previewsEnabled: false,
                previewServices: probe.services)
            controller.receive(png, copied: true)
            try await waitUntil { !controller.isSaving }
            controller.editLatest()
            try await waitUntil { probe.targets.count == 1 }
            try expect(!controller.isSaving && !controller.isPreviewVisible
                       && probe.applications == [TrustedPreviewApplication.systemURL] && probe.errors == 0,
                       "Injected Preview launch did not reach the normal completion fence")
            switch invalidator {
            case 0:
                controller.dismissPreview() // A newer close invalidates the already requested launch.
            case 1:
                controller.editLatest() // Same capture ID, but a fresh explicit edit generation.
                try await waitUntil { probe.targets.count == 2 }
            case 2:
                controller.environmentDidChange()
            default:
                controller.receive(png, copied: false) // A new capture replaces the old record.
                try await waitUntil { !controller.isSaving }
            }
            probe.complete(0, failed: true)
            try expect(probe.errors == 0,
                       "A delayed old Preview failure displayed an error after a newer action")
            if invalidator != 1 {
                controller.editLatest()
                try await waitUntil { probe.targets.count == 2 }
            }
            probe.complete(1, failed: true)
            try expect(probe.errors == 1,
                       "The current Preview failure was suppressed with the obsolete callback")
            try expect(probe.applications.allSatisfy { $0 == TrustedPreviewApplication.systemURL }
                       && !controller.isPreviewVisible && !controller.isSaving,
                       "Preview callback testing escaped the injected launcher or retained an editing worker")
            controller.environmentDidChange()
        }
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
