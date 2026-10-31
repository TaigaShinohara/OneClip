import AppKit
import Foundation

/// Injected services and fabricated images only. No Native UI, TCC, real keys or OS pasteboards.
@main
struct CollectionCaptureCoordinatorTests {
    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor
    static func main() async throws {
        if CommandLine.arguments.contains("--m4-resource-cycles") {
            try await runM4ResourceCycles()
            return
        }
        let groups: [(String, @MainActor () async throws -> Void)] = [
            ("M3-COORD-01 initial cancel differs from an edited empty session", testEmpty),
            ("M3-COORD-02 successful additions preserve order and enforce four sources", testAddAndDelete),
            ("M3-COORD-03 replacement waits for explicit adoption at the same position", testReplacement),
            ("M3-COORD-04 cancelled or failed addition preserves existing sources", testAdditionFailure),
            ("M3-COORD-05 composition and clipboard failures retain sources for retry", testFailureAndRetry),
            ("M3-COORD-06 encoding cancel keeps sources and owns the worker until return", testEncodingCancellation),
            ("M3-COORD-07 discard rejects late capture without releasing the worker early", testDiscardLateCapture),
            ("M3-COORD-08 environment loss releases images and rejects late PNG", testEnvironmentLateEncoding),
            ("M3-COORD-09 cancellation before a queued worker starts never acquires an image", testQueuedCancellation),
            ("M3-COORD-10 both capture modes share the real worker lifetime", testSharedWorker),
            ("M3-COORD-11 result fence rejects unavailable environment without a callback", testEnvironmentFence),
            ("M3-COORD-12 permission recovery requires a new explicit selection", testPermission),
            ("M3-COORD-13 app switch during acquisition or copy does not steal focus", testInactiveFocus),
            ("M3-COORD-14 writing cannot be cancelled or started twice", testWritingBoundary),
            ("M3-COORD-15 stale selection callback cannot confirm a later operation", testStaleSelection),
            ("M3-COORD-16 retained panel and quit recheck permission and protected data", testRetainedPanelFence),
            ("M3-COORD-17 invalidated UI callbacks cannot revive a session", testInvalidatedCancel),
            ("M3-COORD-18 released queued owner still relinquishes its shared permit", testReleasedOwner),
            ("M3-COORD-19 clipboard guidance distinguishes preparation from retained retry", testClipboardGuidance),
            ("M3-COORD-20 deletion decision preserves cache until one exact commit", testDeletionDecision),
            ("M3-COORD-21 deletion rejects obsolete revision and session targets", testStaleDeletion),
            ("M3-COORD-22 deletion rechecks environment permission and shared occupancy", testDeletionFences),
            ("M3-COORD-23 hidden or replaced decisions reject old buttons and completions", testDecisionLifetime),
            ("M3-COORD-24 delivered display change invalidates retained and pending owners", testDisplayChangeDelivery),
            ("M3-COORD-25 cancel rechecks environment permission and protected data", testUnavailableCancellation),
            ("M3-COORD-26 display errors invalidate while ordinary capture failures retain sources", testDisplayChangeError),
            ("SETTINGS-COLLECTION-01 invalid settings preserves additions and replacements", testSettingsBoundary),
            ("SETTINGS-COLLECTION-02 guide and permission preserve entry origin", testSettingsOrigin),
            ("UX-COLLECTION-01 replacement review changes content only on adoption", testReplacementContentRevision),
            ("UX-COLLECTION-02 copied content survives cancelled selections and workers", testCopiedContentCancellation),
            ("UX-COLLECTION-03 a failed recopy stays visible alongside previous copy state", testRecopyFailureStatus),
            ("UX-COLLECTION-04 invalidation notice survives empty events and the next shortcut", testInvalidationNotice),
            ("UX-COLLECTION-05 new-session admission preserves a rejected copied draft", testNewSessionAdmission),
            ("UX-COLLECTION-06 retained collection permits an independent single capture", testSingleWithRetainedCollection),
            ("UX-COLLECTION-07 replacement decisions recheck unavailable data", testReplacementDecisionFences),
            ("UX-COLLECTION-08 single entry fences retained collection without blocking first permission guidance", testSingleEntryRetainedFence),
            ("SECURITY-COLLECTION-01 every environment event clears copied and candidate owners", testEnvironmentRetainedMatrix),
            ("SECURITY-COLLECTION-02 every event rejects late success and failure at worker boundaries", testEnvironmentLateMatrix),
            ("RESULT-COLLECTION-01 confirmed PNGs publish with exact clipboard results and content retry identity", testCaptureResultPublication),
            ("SECURITY-COLLECTION-03 external result images share acquisition and composition capacity", testExternalResultBudget),
            ("SECURITY-COLLECTION-04 result handoff counts live worker and retained completed images", testResultHandoffBudget),
            ("SECURITY-COLLECTION-05 acquisition rechecks newly occupied external capacity", testExternalAdoptionBudget),
            ("ANNOTATION-COLLECTION-01 retained annotation budget includes completed PNGs and comparison candidates", testAnnotationRetention)
        ]
        for (name, body) in groups {
            try await body()
            print("PASS \(name)")
        }
        print("PASS \(groups.count) collection coordinator groups; injected services only")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }

    @MainActor
    static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        throw Failure(description: "Injected worker did not reach its expected gate")
    }

    @MainActor
    final class FakeInterface: CollectionCaptureInterface {
        var isOneClipActive = true
        var captureEntryBlocked = false
        var rejectSettings = false
        func settingsCaptureScope(for selection: CaptureSelection) throws -> SettingsCaptureScope? {
            if rejectSettings { throw ScreenshotError.settingsUnavailable }
            return nil
        }
        var environmentAvailable = true
        var captureEnvironmentStatus: String { "模擬利用状態を確認できません" }
        var prepareResult = true
        var hideSelectionResult = true
        var selectionCalls = 0
        var hideSelectionCalls = 0
        var hideCollectionCalls = 0
        var collectionVisible = false
        var permissionCalls = 0
        var dismissCalls = 0
        var rememberCalls = 0
        var returnCalls = 0
        var guideCalls = 0
        var collectionActivations: [Bool] = []
        var feedback: [String] = []
        var selected: (@MainActor (CaptureSelection) -> Void)?
        var cancelled: (@MainActor () -> Void)?
        var guideStarted: (@MainActor () -> Void)?
        var guideCancelled: (@MainActor () -> Void)?

        func prepareCaptureEnvironment() -> Bool { environmentAvailable }
        func validateCaptureEnvironment() -> Bool { environmentAvailable }
        func prepareForSelection() -> Bool { prepareResult }
        func showSelection(on display: CaptureDisplaySnapshot,
                           selected: @escaping @MainActor (CaptureSelection) -> Void,
                           cancelled: @escaping @MainActor () -> Void) {
            selectionCalls += 1
            self.selected = selected
            self.cancelled = cancelled
        }
        func hideSelection() -> Bool { hideSelectionCalls += 1; return hideSelectionResult }
        func showCollection(activate: Bool) { collectionVisible = true; collectionActivations.append(activate) }
        func hideCollection() { collectionVisible = false; hideCollectionCalls += 1 }
        func showCollectionGuide(started: @escaping @MainActor () -> Void,
                                 cancelled: @escaping @MainActor () -> Void) {
            guideCalls += 1; guideStarted = started; guideCancelled = cancelled
        }
        func hideCaptureGuide() {}
        func showCollectionPermission() { permissionCalls += 1 }
        func showPermission() { permissionCalls += 1 }
        func hidePermission() {}
        func showProblem(activate: Bool) {}
        func hideProblem() {}
        func showFeedback(_ message: String) { feedback.append(message) }
        func dismissAll() { dismissCalls += 1 }
        func rememberExternalApplication() { rememberCalls += 1 }
        func returnToExternalApplication() { returnCalls += 1 }
    }

    @MainActor
    final class Permissions {
        var allowed = true
        var protectedData = true
        var requestCalls = 0
        var requestAllows = true
        func request() -> Bool { requestCalls += 1; allowed = requestAllows; return allowed }
    }

    @MainActor
    final class FakeClipboard: CaptureClipboardWriting {
        enum Mode: Equatable { case accepted, rejectedBeforePrepare, rejectedAfterPrepare, conflictAfterPrepare }
        var mode = Mode.accepted
        var count = 1
        var calls = 0
        var accepted = 0
        var expectedCounts: [Int] = []
        var attemptedData: [Data] = []
        var beforeWrite: (@MainActor () -> Void)?
        var changeCount: Int { count }
        func writePNG(_ data: Data, expectedChangeCount: Int) -> M0ClipboardProbe.Outcome {
            calls += 1; expectedCounts.append(expectedChangeCount)
            attemptedData.append(data)
            beforeWrite?()
            guard count == expectedChangeCount else {
                return .init(code: .conflictBeforePrepare, expectedChangeCount: expectedChangeCount,
                             observedChangeCount: count, preparedChangeCount: nil)
            }
            if mode == .rejectedBeforePrepare {
                return .init(code: .itemPreparationFailed, expectedChangeCount: expectedChangeCount,
                             observedChangeCount: count, preparedChangeCount: nil)
            }
            count += 1
            if mode == .conflictAfterPrepare {
                let prepared = count
                count += 1
                return .init(code: .conflictAfterPrepare, expectedChangeCount: expectedChangeCount,
                             observedChangeCount: count, preparedChangeCount: prepared)
            }
            guard mode == .accepted else {
                return .init(code: .writeRejected, expectedChangeCount: expectedChangeCount,
                             observedChangeCount: count, preparedChangeCount: count)
            }
            accepted += 1
            return .init(code: .writeAccepted, expectedChangeCount: expectedChangeCount,
                         observedChangeCount: count, preparedChangeCount: count)
        }
    }

    @MainActor
    final class FakeCapture: ScreenshotCapturing {
        var nextAsset: M0ImageAsset
        var failNext = false
        var errorNext: ScreenshotError?
        var pauseNext = false
        var calls = 0
        var requests: [SingleCaptureRequest] = []
        private var pending: CheckedContinuation<M0ImageAsset, any Error>?
        private var pendingAsset: M0ImageAsset?
        var isWaiting: Bool { pending != nil }
        init(asset: M0ImageAsset) { nextAsset = asset }
        func capture(_ request: SingleCaptureRequest,
                     isCurrent: @escaping @MainActor () -> Bool) async throws -> M0ImageAsset {
            calls += 1; requests.append(request)
            if let errorNext { self.errorNext = nil; throw errorNext }
            if failNext { failNext = false; throw ScreenshotError.captureFailed }
            let asset = nextAsset
            if pauseNext {
                pauseNext = false
                pendingAsset = asset
                // The service deliberately ignores cancellation to exercise late adoption fences.
                return try await withCheckedThrowingContinuation { pending = $0 }
            }
            return asset
        }
        func release(error: ScreenshotError? = nil) throws {
            guard let pending, let pendingAsset else { throw Failure(description: "No pending fabricated capture") }
            self.pending = nil; self.pendingAsset = nil
            if let error { pending.resume(throwing: error) }
            else { pending.resume(returning: pendingAsset) }
        }
        func releaseIfPending() { if pending != nil { try? release() } }
    }

    @MainActor
    final class FakeComposer {
        var calls = 0
        var failNext = false
        var pauseNext = false
        private var pending: CheckedContinuation<Void, Never>?
        var isWaiting: Bool { pending != nil }
        func run(_ assets: [M0ImageAsset], _ limits: M0ImageLimits) async throws -> M0CompositionResult {
            calls += 1
            if pauseNext {
                pauseNext = false
                await withCheckedContinuation { pending = $0 }
            }
            if failNext { failNext = false; throw M0ImageError.encodingFailed }
            // A late framework result remains possible even after cancellation. Do not
            // let the production composer's cancellation mask that adoption-fence test.
            return try M0ImageComposer.compose(assets: assets, limits: limits,
                                               checkCancellation: { _ in })
        }
        func release() throws {
            guard let pending else { throw Failure(description: "No pending fabricated composition") }
            self.pending = nil
            pending.resume()
        }
        func releaseIfPending() { if pending != nil { try? release() } }
    }

    @MainActor
    final class Harness {
        let display: CaptureDisplaySnapshot
        let interface: FakeInterface
        let clipboard: FakeClipboard
        let permissions: Permissions
        let composer: FakeComposer
        let slot: CaptureWorkerSlot
        let capturer: FakeCapture
        let preferences: CapturePreferences
        let coordinator: CollectionCaptureCoordinator
        private let defaults: UserDefaults
        private let suite: String

        init(displayAtPointer: (@MainActor () throws -> CaptureDisplaySnapshot)? = nil) throws {
            let display = try CaptureDisplaySnapshot(id: 99, frame: CGRect(x: 0, y: 0, width: 640, height: 480), scale: 1)
            let capturer = FakeCapture(asset: try M0ImageFixture.make(index: 1, width: 16, height: 16))
            let interface = FakeInterface(), clipboard = FakeClipboard(), permissions = Permissions()
            let composer = FakeComposer(), slot = CaptureWorkerSlot()
            let suite = "OneClip.CollectionCaptureTests.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "Test preference suite unavailable") }
            let preferences = CapturePreferences(defaults: defaults, hasSeenCaptureGuide: true,
                                                  hasSeenPasteHint: true, hasSeenCollectionGuide: true)
            let coordinator = CollectionCaptureCoordinator(capturer: capturer, interface: interface, clipboard: clipboard,
                workSlot: slot, preferences: preferences,
                permissionCheck: { permissions.allowed }, permissionRequest: { permissions.request() },
                protectedDataCheck: { permissions.protectedData }, displayAtPointer: displayAtPointer ?? { display },
                compose: { assets, limits in try await composer.run(assets, limits) })
            self.display = display; self.capturer = capturer; self.interface = interface
            self.clipboard = clipboard; self.permissions = permissions; self.composer = composer
            self.slot = slot; self.suite = suite; self.defaults = defaults
            self.preferences = preferences; self.coordinator = coordinator
        }

        func selection(width: Int = 16, height: Int = 16, x: Int = 20) throws -> CaptureSelection {
            try CaptureSelection(display: display, rect: CGRect(x: CGFloat(x), y: 30,
                                                               width: CGFloat(width), height: CGFloat(height)))
        }
        func select(width: Int = 16, height: Int = 16, x: Int = 20) throws {
            guard coordinator.phase == .selecting, let selected = interface.selected else {
                throw Failure(description: "Collection selection was not presented")
            }
            selected(try selection(width: width, height: height, x: x))
        }
        func add(index: Int = 1, width: Int = 16, height: Int = 16) async throws {
            capturer.nextAsset = try M0ImageFixture.make(index: index, width: width, height: height)
            // This helper represents an explicitly acknowledged fresh operation. Shortcut-only
            // preservation of the notice is covered separately by testInvalidationNotice.
            coordinator.acknowledgeInvalidation()
            coordinator.beginOrAdd()
            try select(width: width, height: height)
            await coordinator.waitForWorker()
        }
        func delete(at index: Int) throws {
            guard let target = coordinator.deletionTarget(at: index), coordinator.delete(target) else {
                throw Failure(description: "The current fabricated deletion target was rejected")
            }
        }
        func cleanUp() {
            clipboard.beforeWrite = nil
            coordinator.stop(); capturer.releaseIfPending(); composer.releaseIfPending()
            defaults.removePersistentDomain(forName: suite)
        }
        func makeSingle(interface: FakeInterface, capturer: FakeCapture) -> SingleCaptureCoordinator {
            let display = self.display, permissions = self.permissions
            return SingleCaptureCoordinator(capturer: capturer, interface: interface, clipboard: clipboard, workSlot: slot,
                permissionCheck: { permissions.allowed }, permissionRequest: { permissions.request() },
                protectedDataCheck: { permissions.protectedData }, displayAtPointer: { display }, preferences: preferences)
        }
    }

    /// Separate finite repetition of existing injected contracts, using tiny fixtures.
    /// Each representative keeps its own assertions and cleanup; this adds no new mock.
    @MainActor
    static func runM4ResourceCycles() async throws {
        let representatives: [@MainActor () async throws -> Void] = [
            testFailureAndRetry, testDiscardLateCapture, testEnvironmentLateEncoding, testSharedWorker
        ]
        print("M4_COORD_SCOPE warmupCycles=2 measuredCycles=30 representativesPerCycle=4 tinyFixtures=1 fakeWriter=1")
        print("M4_COORD_LIMITS sourceCacheWorker=existing_logical_assertions allCGImagePhysicalRelease=unobserved PNGBackingRelease=unobserved RSS=not_measured realSCK_UI_OS=not_exercised")
        var warmupCompleted = 0, measuredCompleted = 0, measuredRepresentativePasses = 0
        for iteration in 1...32 {
            let warmup = iteration <= 2
            let series = warmup ? "warmup" : "measured"
            let seriesIteration = warmup ? iteration : iteration - 2
            do {
                for body in representatives {
                    try await body()
                    if !warmup { measuredRepresentativePasses += 1 }
                }
                if warmup { warmupCompleted += 1 } else { measuredCompleted += 1 }
                print("M4_COORD_CYCLE series=\(series) iteration=\(seriesIteration) representativePasses=4 failures=0")
            } catch {
                print("M4_COORD_RESULT warmupCompleted=\(warmupCompleted) measuredCompleted=\(measuredCompleted) measuredRepresentativePasses=\(measuredRepresentativePasses) failures=1 failingSeries=\(series) failingIteration=\(seriesIteration)")
                throw Failure(description: "M4 finite injected coordinator resource cycle failed")
            }
        }
        print("M4_COORD_RESULT warmupCompleted=\(warmupCompleted) measuredCompleted=\(measuredCompleted) measuredRepresentativePasses=\(measuredRepresentativePasses) failures=0 finiteLogicalObservationOnly=1")
    }

    @MainActor
    static func testAnnotationRetention() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        try await h.add(index: 1, width: 80)
        try await h.add(index: 2, width: 90)
        let sourcesOnly = h.coordinator.retainedImageBytes
        h.coordinator.preparePreview()
        await h.coordinator.waitForWorker()
        guard let completed = h.coordinator.completed else { throw Failure(description: "Missing completed annotation budget fixture") }
        let outputBytes = completed.image.bytesPerRow * completed.image.height
        try expect(h.coordinator.annotationRetainedImageBytes >= sourcesOnly + outputBytes + completed.pngData.count,
                   "Completed preview bitmap or PNG escaped annotation retention")
        h.clipboard.mode = .rejectedBeforePrepare
        h.coordinator.copy()
        await h.coordinator.waitForWorker()
        try expect(h.coordinator.completed != nil && h.coordinator.annotationRetainedImageBytes >= sourcesOnly + outputBytes + completed.pngData.count,
                   "Clipboard failure hid a retained completed output from annotation budgeting")
        let id = h.coordinator.items[0].id
        h.capturer.nextAsset = try M0ImageFixture.make(index: 3, width: 70, height: 20)
        h.coordinator.replace(assetID: id)
        try h.select(width: 70, height: 20)
        await h.coordinator.waitForWorker()
        guard let candidate = h.coordinator.pendingReplacement?.candidate else { throw Failure(description: "Missing annotation candidate fixture") }
        try expect(!h.coordinator.canStartSingle,
                   "An unresolved candidate allowed an annotation entry")
        try expect(h.coordinator.annotationRetainedImageBytes == h.coordinator.retainedImageBytes
                   && h.coordinator.annotationRetainedImageBytes >= sourcesOnly + candidate.image.bytesPerRow * candidate.image.height,
                   "Comparison candidate escaped annotation retention")
    }

    @MainActor
    static func testEmpty() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        h.coordinator.copy(); h.coordinator.preparePreview()
        try expect(h.clipboard.calls == 0 && h.composer.calls == 0, "Inactive empty collection started work")
        h.coordinator.beginOrAdd(); h.interface.cancelled?()
        try expect(!h.coordinator.isActive && h.coordinator.phase == .idle, "First selection Esc left a collection session")
        try await h.add()
        try h.delete(at: 0)
        try expect(h.coordinator.isActive && h.coordinator.assets.isEmpty && h.coordinator.canAdd && !h.coordinator.canCopy,
                   "Deleting the last source lost the empty addable session")
        h.coordinator.copy()
        try expect(h.composer.calls == 0 && h.clipboard.calls == 0, "Empty session copied")
        h.coordinator.beginOrAdd(); h.interface.cancelled?()
        try expect(h.coordinator.isActive && h.coordinator.phase == .ready, "Esc destroyed a previously edited empty session")
    }

    @MainActor
    static func testExternalResultBudget() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        try await h.add()
        let originalID = h.coordinator.items[0].id
        for invalid in [-1, Int.max] {
            h.coordinator.externalRetainedBytes = { invalid }
            h.coordinator.beginOrAdd()
            try h.select()
            await h.coordinator.waitForWorker()
            try expect(h.capturer.calls == 1 && h.coordinator.assets.count == 1
                && h.coordinator.items[0].id == originalID && !h.slot.isOccupied,
                "External result capacity loss captured or discarded an existing source")
            let calls = h.composer.calls
            h.coordinator.copy()
            await h.coordinator.waitForWorker()
            try expect(h.composer.calls == calls && h.clipboard.calls == 0 && !h.slot.isOccupied,
                "External result capacity loss reached composition or retained a permit")
        }
        h.coordinator.externalRetainedBytes = { 1_234 }
        try await h.add(index: 2)
        try expect(h.capturer.requests.last?.budget.retainingExtraBytes == 1_234,
            "Acquisition omitted the external image owner's bytes")
        h.coordinator.copy()
        await h.coordinator.waitForWorker()
        try expect(h.clipboard.accepted == 1 && h.coordinator.assets.count == 2 && !h.slot.isOccupied,
            "Explicit operation did not recover after external image capacity was restored")
    }

    @MainActor
    static func testResultHandoffBudget() async throws {
        for mode in [FakeClipboard.Mode.accepted, .rejectedAfterPrepare] {
            let h = try Harness(); defer { h.cleanUp() }
            try await h.add(); try await h.add(index: 2)
            guard let plan = h.coordinator.plan else { throw Failure(description: "Missing handoff fixture plan") }
            let raw = h.coordinator.assets.reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height }
            h.clipboard.mode = mode
            var observed = false
            var publishedBytes = 0
            h.coordinator.onCaptureResult = { data, _, _ in
                publishedBytes = data.count
                observed = h.coordinator.isWorking && h.slot.isOccupied
                    && h.coordinator.retainedImageBytes >= raw + plan.outputBytes + data.count
            }
            h.coordinator.copy(); await h.coordinator.waitForWorker()
            try expect(observed && !h.slot.isOccupied, "Publication lost live worker ownership before return")
            if mode != .accepted {
                try expect(h.coordinator.completed != nil
                    && h.coordinator.retainedImageBytes >= raw + plan.outputBytes + publishedBytes,
                    "Failed copy's completed bitmap and PNG disappeared from the shared estimate")
            } else {
                try expect(h.coordinator.completed == nil && h.coordinator.retainedImageBytes < raw + plan.outputBytes + publishedBytes,
                    "Successful copy kept the returned worker's output reservation")
            }
        }
        let candidate = try Harness(); defer { candidate.cleanUp() }
        try await candidate.add()
        let previous = candidate.coordinator.retainedImageBytes
        candidate.capturer.nextAsset = try M0ImageFixture.make(index: 2, width: 32, height: 32)
        candidate.coordinator.replace(at: 0)
        try candidate.select(width: 32, height: 32)
        await candidate.coordinator.waitForWorker()
        try expect(candidate.coordinator.pendingReplacement != nil
            && candidate.coordinator.retainedImageBytes >= previous + 32 * 32 * 4,
            "Unadopted candidate was omitted from retained image ownership")
    }

    @MainActor
    static func testExternalAdoptionBudget() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        try await h.add()
        final class ExternalBudget { var bytes = 0 }
        let external = ExternalBudget()
        h.coordinator.externalRetainedBytes = { external.bytes }
        h.capturer.pauseNext = true
        h.coordinator.beginOrAdd(); try h.select()
        try await waitUntil { h.capturer.isWaiting }
        external.bytes = Int.max
        try h.capturer.release()
        await h.coordinator.waitForWorker()
        try expect(h.coordinator.assets.count == 1 && h.clipboard.calls == 0 && !h.slot.isOccupied,
            "Late acquisition used a stale external capacity snapshot")
        external.bytes = 0
        try await h.add(index: 2)
        try expect(h.coordinator.assets.count == 2, "Explicit acquisition failed after capacity was restored")
    }

    @MainActor
    static func testAddAndDelete() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        for index in 1...4 { try await h.add(index: index, width: 10 + index) }
        try expect(h.coordinator.assets.map { $0.image.width } == [11, 12, 13, 14], "Successful additions changed order")
        let assetIDs = h.coordinator.items.map(\.id)
        try expect(Set(assetIDs).count == 4, "Source rows do not have distinct identities")
        let selected = h.interface.selectionCalls, captured = h.capturer.calls
        h.coordinator.beginOrAdd()
        try expect(!h.coordinator.canAdd && h.interface.selectionCalls == selected && h.capturer.calls == captured,
                   "Fifth addition started selection or acquisition")
        try h.delete(at: 1)
        try expect(h.coordinator.assets.map { $0.image.width } == [11, 13, 14], "Delete removed the wrong source")
        try expect(h.coordinator.items.map(\.id) == [assetIDs[0], assetIDs[2], assetIDs[3]]
                   && h.coordinator.items.map(\.index) == [0, 1, 2],
                   "Deleting a source replaced surviving identities instead of only renumbering them")
        try expect(h.coordinator.plan?.placements.map(\.index) == [0, 1, 2], "Delete left stale numbering")
        try expect(h.clipboard.calls == 0, "Collection/editing wrote the clipboard")
    }

    @MainActor
    static func testReplacement() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        try await h.add(index: 1, width: 16); try await h.add(index: 2, width: 20)
        let original = h.coordinator.assets[0].image
        h.coordinator.replace(at: 0)
        try expect(h.coordinator.assets[0].image === original && h.coordinator.replacementIndex == 0,
                   "Replacement removed old source before successful capture")
        h.interface.cancelled?()
        try expect(h.coordinator.assets[0].image === original && h.clipboard.calls == 0, "Replacement Esc lost or copied old source")
        h.capturer.failNext = true; h.coordinator.replace(at: 0); try h.select(x: 60)
        await h.coordinator.waitForWorker()
        try expect(h.coordinator.assets[0].image === original && h.coordinator.assets.count == 2, "Failed replacement changed old source")
        h.capturer.nextAsset = try M0ImageFixture.make(index: 3, width: 24, height: 12)
        h.coordinator.replace(at: 0)
        try expect(h.coordinator.phase == .selecting, "Replacement reused a prior region without selection")
        try h.select(width: 24, height: 12, x: 80)
        await h.coordinator.waitForWorker()
        guard let candidate = h.coordinator.pendingReplacement else {
            throw Failure(description: "Successful capture did not enter replacement review")
        }
        try expect(h.coordinator.phase == .reviewingReplacement && h.coordinator.assets[0].image === original
                   && candidate.candidate.image.width == 24 && !h.coordinator.canCopy && !h.coordinator.canAdd,
                   "Successful replacement capture adopted before the explicit decision")
        h.coordinator.acceptReplacement(id: candidate.id)
        try expect(h.coordinator.assets.map { $0.image.width } == [24, 20], "Successful replacement changed the source position")
        try expect(h.capturer.requests.last?.selection.rect.minX == 80, "Replacement reused old coordinates")
    }

    @MainActor
    static func testAdditionFailure() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        try await h.add()
        let original = h.coordinator.assets[0].image
        h.coordinator.beginOrAdd(); h.interface.cancelled?()
        h.capturer.failNext = true; h.coordinator.beginOrAdd(); try h.select()
        await h.coordinator.waitForWorker()
        try expect(h.coordinator.assets.count == 1 && h.coordinator.assets[0].image === original
                   && h.coordinator.phase == .ready && h.clipboard.calls == 0, "Cancelled/failed addition lost old source or wrote")
        try await h.add(index: 2, width: 18)
        try expect(h.coordinator.assets.count == 2 && h.coordinator.assets[0].image === original, "Addition could not explicitly recover")
    }

    @MainActor
    static func testSettingsBoundary() async throws {
        for replacing in [false, true] {
            let h = try Harness(); defer { h.cleanUp() }
            try await h.add()
            let original = h.coordinator.assets[0].image
            let calls = h.capturer.calls
            h.interface.rejectSettings = true
            if replacing { h.coordinator.replace(at: 0) } else { h.coordinator.beginOrAdd() }
            try h.select(); await h.coordinator.waitForWorker()
            try expect(h.capturer.calls == calls && h.clipboard.calls == 0 && !h.slot.isOccupied
                       && h.coordinator.assets.count == 1 && h.coordinator.assets[0].image === original,
                       "Settings rejection captured, wrote, or lost an existing source")
            try expect(h.coordinator.phase == .ready && h.coordinator.statusText.contains("設定画面"),
                       "Settings rejection did not return to the retained collection")
            h.interface.rejectSettings = false
            try await h.add(index: 2)
            try expect(h.coordinator.assets.count == 2, "Fresh addition failed after window rejection")
            h.capturer.errorNext = .settingsUnavailable
            h.coordinator.replace(at: 0); try h.select(); await h.coordinator.waitForWorker()
            try expect(h.coordinator.assets[0].image === original && h.clipboard.calls == 0
                       && h.coordinator.statusText.contains("設定画面"),
                       "Late settings invalidation replaced old material or lost its explanation")
        }
    }

    @MainActor
    static func testSettingsOrigin() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        h.preferences.hasSeenCollectionGuide = false
        h.coordinator.beginOrAdd()
        try expect(h.interface.rememberCalls == 1, "Entry did not remember origin")
        h.interface.guideStarted?()
        try expect(h.interface.rememberCalls == 1 && h.coordinator.phase == .selecting,
                   "Collection guide replaced the entry origin")
        h.coordinator.cancelOperation()
        h.permissions.allowed = false
        h.coordinator.beginOrAdd()
        let entries = h.interface.rememberCalls
        h.permissions.allowed = true
        h.coordinator.retryPermission()
        try expect(h.interface.rememberCalls == entries && h.coordinator.phase == .selecting,
                   "Permission retry replaced origin after hiding its window")
        h.coordinator.cancelOperation()
    }

    @MainActor
    static func testCaptureResultPublication() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        var results: [(png: Data, copied: Bool, id: UUID)] = []
        h.coordinator.onCaptureResult = { results.append(($0, $1, $2)) }
        try await h.add()
        h.coordinator.preparePreview()
        await h.coordinator.waitForWorker()
        try expect(results.isEmpty && h.clipboard.calls == 0 && h.coordinator.completed != nil,
                   "Collection acquisition or preview published an unconfirmed PNG")

        h.clipboard.mode = .rejectedAfterPrepare
        h.coordinator.copy()
        await h.coordinator.waitForWorker()
        try expect(results.count == 1 && !results[0].copied
                   && results[0].png == h.clipboard.attemptedData[0]
                   && h.coordinator.hasRetainedImages,
                   "A failed collection copy did not publish its exact saveable PNG")

        h.clipboard.mode = .accepted
        h.coordinator.copy()
        await h.coordinator.waitForWorker()
        try expect(results.count == 2 && results[1].copied && results[1].id == results[0].id
                   && results[1].png == results[0].png
                   && results[1].png == h.clipboard.attemptedData[1],
                   "An unchanged-content retry lost its PNG, result, or retry identity")
        h.coordinator.copy()
        await h.coordinator.waitForWorker()
        try expect(results.count == 3 && results[2].copied && results[2].id == results[1].id
                   && results[2].png == h.clipboard.attemptedData[2]
                   && h.interface.feedback.isEmpty,
                   "Repeated copying of the same content was republished as a new capture or duplicate feedback")

        try await h.add(index: 2, width: 18)
        try expect(results.count == 3, "Adding a source published an unfinished collection")
        h.coordinator.copy()
        await h.coordinator.waitForWorker()
        try expect(results.count == 4 && results[3].copied && results[3].id != results[2].id
                   && results[3].png == h.clipboard.attemptedData[3]
                   && results[3].png != results[2].png,
                   "Modified collection content retained an obsolete retry identity or output")

        h.composer.pauseNext = true
        h.coordinator.copy()
        try await waitUntil { h.composer.isWaiting }
        h.coordinator.cancelOperation()
        try h.composer.release()
        await h.coordinator.waitForWorker()
        try expect(results.count == 4 && h.clipboard.calls == 4 && h.coordinator.hasRetainedImages,
                   "A cancelled late collection PNG was published for saving")
    }

    @MainActor
    static func testFailureAndRetry() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        try await h.add()
        h.composer.failNext = true; h.coordinator.copy(); await h.coordinator.waitForWorker()
        try expect(h.coordinator.hasRetainedImages && h.coordinator.completed == nil && h.clipboard.calls == 0,
                   "Failed composition wrote or dropped sources")
        h.clipboard.mode = .rejectedAfterPrepare
        h.coordinator.copy(); await h.coordinator.waitForWorker()
        try expect(h.coordinator.hasRetainedImages && h.coordinator.completed != nil && h.clipboard.calls == 1
                   && h.interface.feedback.isEmpty, "Write failure lost retry data or reported success")
        h.clipboard.mode = .accepted
        h.coordinator.copy(); await h.coordinator.waitForWorker()
        try expect(h.composer.calls == 2 && h.capturer.calls == 1 && h.clipboard.accepted == 1,
                   "Retry recaptured or recomposed a cached completed image")
        try expect(h.clipboard.expectedCounts == [1, 2], "Retry reused stale clipboard revision")
        try expect(h.coordinator.isActive && h.coordinator.assets.count == 1 && h.coordinator.completed == nil
                   && h.coordinator.isCopiedCurrent && !h.slot.isOccupied && h.interface.feedback.count == 1,
                   "Success lost the editable copied draft or retained its output cache/worker")
    }

    @MainActor
    static func testEncodingCancellation() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        try await h.add()
        h.composer.pauseNext = true; h.coordinator.preparePreview()
        try await waitUntil { h.composer.isWaiting }
        h.coordinator.cancelOperation()
        try expect(h.coordinator.hasRetainedImages && h.coordinator.isWorking && h.slot.isOccupied,
                   "Encode cancellation discarded sources or released a live worker")
        let selections = h.interface.selectionCalls
        h.coordinator.beginOrAdd(); h.coordinator.copy()
        try expect(h.interface.selectionCalls == selections && h.composer.calls == 1, "Cancelled worker overlapped new work")
        try h.composer.release(); await h.coordinator.waitForWorker()
        try expect(h.coordinator.phase == .ready && h.coordinator.completed == nil && h.clipboard.calls == 0
                   && h.coordinator.canAdd, "Cancelled late preview revived completed data or stranded retry")
    }

    @MainActor
    static func testDiscardLateCapture() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        try await h.add()
        h.capturer.pauseNext = true; h.coordinator.beginOrAdd(); try h.select()
        try await waitUntil { h.capturer.isWaiting }
        h.coordinator.discard()
        let activations = h.interface.collectionActivations.count
        try expect(!h.coordinator.isActive && h.coordinator.assets.isEmpty && h.coordinator.completed == nil
                   && h.coordinator.isWorking && h.slot.isOccupied, "Discard retained sources or released pending acquisition")
        h.coordinator.beginOrAdd()
        try expect(!h.coordinator.isActive, "Discard automatically opened a replacement session")
        try h.capturer.release(); await h.coordinator.waitForWorker()
        try expect(!h.coordinator.isActive && h.coordinator.phase == .idle && !h.slot.isOccupied
                   && h.interface.collectionActivations.count == activations && h.clipboard.calls == 0,
                   "Late discarded capture revived collection UI or copy")
    }

    @MainActor
    static func testEnvironmentLateEncoding() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        try await h.add(); h.coordinator.preparePreview(); await h.coordinator.waitForWorker()
        try expect(h.coordinator.completed != nil, "Preview precondition missing")
        try h.delete(at: 0); try await h.add()
        h.composer.pauseNext = true; h.coordinator.copy()
        try await waitUntil { h.composer.isWaiting }
        h.coordinator.environmentDidChange(.systemSleep)
        try expect(h.coordinator.assets.isEmpty && h.coordinator.completed == nil && !h.coordinator.isActive
                   && h.coordinator.isWorking && h.slot.isOccupied && h.interface.dismissCalls > 0,
                   "Environment loss did not synchronously release UI-owned data and preserve worker occupancy")
        let shown = h.interface.collectionActivations.count
        try h.composer.release(); await h.coordinator.waitForWorker()
        try expect(h.clipboard.calls == 0 && h.interface.feedback.isEmpty
                   && h.interface.collectionActivations.count == shown && h.coordinator.completed == nil,
                   "Late invalidated PNG restored success or retry UI")
        try await h.add(index: 2)
        try expect(h.coordinator.assets.count == 1, "Fresh explicit operation could not recover after worker completion")
    }

    @MainActor
    static func testQueuedCancellation() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        try await h.add()
        let calls = h.capturer.calls
        h.coordinator.beginOrAdd(); try h.select()
        // No suspension: cancel before the newly queued Task can enter the capture service.
        h.coordinator.cancelOperation()
        try expect(h.coordinator.isWorking && h.slot.isOccupied && h.coordinator.assets.count == 1,
                   "Queued cancellation released the permit early or dropped sources")
        await h.coordinator.waitForWorker()
        try expect(h.capturer.calls == calls && h.coordinator.canAdd && h.clipboard.calls == 0,
                   "Queued cancelled task entered capture or stranded collection")
    }

    @MainActor
    static func testSharedWorker() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        let singleUI = FakeInterface()
        let singleCapture = FakeCapture(asset: try M0ImageFixture.make(index: 4, width: 16, height: 16))
        let single = h.makeSingle(interface: singleUI, capturer: singleCapture)
        defer { single.stop(); singleCapture.releaseIfPending() }
        singleCapture.pauseNext = true; single.begin()
        singleUI.selected?(try h.selection())
        try await waitUntil { singleCapture.isWaiting }
        h.coordinator.beginOrAdd()
        try expect(!h.coordinator.isActive && h.interface.selectionCalls == 0, "Collection overlapped a live single worker")
        single.cancel()
        h.coordinator.beginOrAdd()
        try expect(!h.coordinator.isActive && h.slot.isOccupied, "Single cancellation released a pending worker")
        try singleCapture.release(); await single.waitForWorker()
        h.capturer.pauseNext = true; h.coordinator.beginOrAdd(); try h.select()
        try await waitUntil { h.capturer.isWaiting }
        let selections = singleUI.selectionCalls
        single.begin()
        try expect(!single.canBegin && singleUI.selectionCalls == selections, "Single overlapped live collection acquisition")
        h.coordinator.discard(); single.begin()
        try expect(singleUI.selectionCalls == selections, "Collection discard released a pending worker")
        try h.capturer.release(); await h.coordinator.waitForWorker()
        single.begin()
        try expect(singleUI.selectionCalls == selections + 1, "Single did not recover after collection worker finished")
        single.cancel()
    }

    @MainActor
    static func testEnvironmentFence() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        h.capturer.pauseNext = true; h.coordinator.beginOrAdd(); try h.select()
        try await waitUntil { h.capturer.isWaiting }
        h.interface.environmentAvailable = false
        try h.capturer.release(); await h.coordinator.waitForWorker()
        try expect(!h.coordinator.isActive && h.coordinator.assets.isEmpty && h.clipboard.calls == 0,
                   "Unavailable environment adopted a late capture without a callback")
        h.coordinator.beginOrAdd()
        try expect(!h.coordinator.isActive, "Unavailable environment admitted a new session")
        h.interface.environmentAvailable = true
        try await h.add()
        try expect(h.coordinator.assets.count == 1, "Explicit environment recovery failed")
    }

    @MainActor
    static func testPermission() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        h.permissions.allowed = false; h.coordinator.beginOrAdd()
        try expect(h.coordinator.phase == .permission && h.permissions.requestCalls == 0 && h.interface.selectionCalls == 0,
                   "Permission was requested or selected implicitly")
        h.coordinator.requestPermission()
        try expect(h.permissions.requestCalls == 1 && h.interface.selectionCalls == 0, "Grant auto-started selection")
        h.coordinator.retryPermission(); try h.select(); await h.coordinator.waitForWorker()
        try expect(h.coordinator.assets.count == 1 && h.clipboard.calls == 0, "Explicit permission retry failed")
        h.permissions.allowed = false; h.coordinator.beginOrAdd()
        try expect(!h.coordinator.isActive && h.coordinator.assets.isEmpty, "Permission loss retained collected images")
    }

    @MainActor
    static func testInactiveFocus() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        h.capturer.pauseNext = true; h.coordinator.beginOrAdd(); try h.select()
        try await waitUntil { h.capturer.isWaiting }
        h.interface.isOneClipActive = false
        try h.capturer.release(); await h.coordinator.waitForWorker()
        try expect(h.interface.collectionActivations.last == false && h.interface.returnCalls == 0,
                   "Acquisition completion stole external focus")
        h.composer.pauseNext = true; h.coordinator.copy()
        try await waitUntil { h.composer.isWaiting }
        try h.composer.release(); await h.coordinator.waitForWorker()
        try expect(h.clipboard.accepted == 1 && h.interface.returnCalls == 0 && h.interface.feedback.count == 1,
                   "Inactive success failed or activated an external application")
    }

    @MainActor
    static func testWritingBoundary() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        try await h.add()
        var sawWriting = false
        h.clipboard.beforeWrite = {
            sawWriting = h.coordinator.phase == .writing && h.coordinator.isWorking && h.slot.isOccupied
            h.coordinator.cancelOperation(); h.coordinator.discard(); h.coordinator.copy(); h.coordinator.beginOrAdd()
        }
        h.coordinator.copy(); await h.coordinator.waitForWorker()
        h.clipboard.beforeWrite = nil
        try expect(sawWriting && h.clipboard.calls == 1 && h.clipboard.accepted == 1 && h.composer.calls == 1,
                   "Writing could be cancelled or duplicated")
        try expect(h.coordinator.isActive && h.coordinator.isCopiedCurrent && !h.slot.isOccupied,
                   "Writing completion lost the copied draft or retained the shared worker")
    }

    @MainActor
    static func testStaleSelection() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        h.coordinator.beginOrAdd()
        let old = h.interface.selected
        h.interface.cancelled?()
        h.coordinator.beginOrAdd()
        old?(try h.selection())
        try expect(h.capturer.calls == 0 && h.coordinator.phase == .selecting, "Old callback confirmed a later selection")
        try h.select(x: 40); await h.coordinator.waitForWorker()
        try expect(h.capturer.calls == 1 && h.coordinator.assets.count == 1
                   && h.capturer.requests[0].selection.rect.minX == 40, "Current selection did not recover")
    }
    @MainActor
    static func testRetainedPanelFence() async throws {
        for permissionLoss in [true, false] {
            let h = try Harness(); defer { h.cleanUp() }
            try await h.add()
            let shows = h.interface.collectionActivations.count
            if permissionLoss { h.permissions.allowed = false } else { h.permissions.protectedData = false }
            h.coordinator.showPanel()
            try expect(!h.coordinator.isActive && h.coordinator.assets.isEmpty && h.interface.collectionActivations.count == shows,
                       "Unavailable retained display revived images")
        }
        let h = try Harness(); defer { h.cleanUp() }
        try await h.add(); h.permissions.protectedData = false
        h.coordinator.prepareToQuit()
        try expect(!h.coordinator.hasRetainedImages && !h.coordinator.isActive, "Quit retained unavailable sources")
    }

    @MainActor
    static func testInvalidatedCancel() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        try await h.add(); h.coordinator.environmentDidChange(.systemSleep)
        let shows = h.interface.collectionActivations.count
        h.coordinator.cancelOperation()
        try expect(h.coordinator.phase == .idle && !h.coordinator.isActive && h.interface.collectionActivations.count == shows,
                   "Invalidated callback revived collection UI")
        h.coordinator.showPanel()
        try expect(!h.coordinator.isActive && h.coordinator.assets.isEmpty
                   && h.coordinator.invalidationNotice != nil && h.interface.collectionActivations.count == shows + 1,
                   "Explicit review of an invalidation notice revived sources or hid the notice")
        h.coordinator.stop(); h.coordinator.cancelOperation()
        try expect(h.coordinator.phase == .idle && !h.coordinator.isActive, "Stopped callback revived collection")
    }

    @MainActor
    static func testReleasedOwner() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        let interface = FakeInterface()
        let display = h.display
        var owner: CollectionCaptureCoordinator? = CollectionCaptureCoordinator(capturer: h.capturer, interface: interface,
            clipboard: h.clipboard, workSlot: h.slot, preferences: h.preferences,
            permissionCheck: { true }, protectedDataCheck: { true }, displayAtPointer: { display })
        weak var weakOwner = owner
        owner?.beginOrAdd(); interface.selected?(try h.selection())
        try expect(h.slot.isOccupied, "Worker permit was not acquired")
        owner = nil
        try expect(weakOwner == nil, "Unstarted worker unexpectedly owns its coordinator")
        try await waitUntil { !h.slot.isOccupied }
        try expect(h.capturer.calls == 0, "Released queued owner started capture")
    }

    @MainActor
    static func testClipboardGuidance() async throws {
        for mode in [FakeClipboard.Mode.rejectedBeforePrepare, .rejectedAfterPrepare, .conflictAfterPrepare] {
            let h = try Harness(); defer { h.cleanUp() }
            try await h.add()
            h.clipboard.mode = mode
            h.coordinator.copy(); await h.coordinator.waitForWorker()
            try expect(h.coordinator.hasRetainedImages && h.coordinator.completed != nil && h.interface.feedback.isEmpty,
                       "Clipboard rejection lost retry data or announced success")
            if mode == .rejectedBeforePrepare {
                try expect(h.clipboard.count == 1 && h.coordinator.statusText.contains("書込み前")
                           && !h.coordinator.statusText.contains("残っていない"), "Pre-prepare failure claimed a clear")
            } else {
                try expect(h.coordinator.statusText.contains("書込み準備後") && h.coordinator.statusText.contains("残っていない"),
                           "Post-prepare rejection omitted clipboard uncertainty")
            }
            h.clipboard.mode = .accepted
            h.coordinator.copy(); await h.coordinator.waitForWorker()
            try expect(h.coordinator.isActive && h.coordinator.isCopiedCurrent
                       && h.clipboard.accepted == 1 && h.composer.calls == 1,
                       "Explicit retry failed or needlessly recomposed")
        }
    }

    @MainActor
    static func testDeletionDecision() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        for index in 1...4 { try await h.add(index: index, width: 10 + index) }
        h.coordinator.preparePreview(); await h.coordinator.waitForWorker()
        guard let target = h.coordinator.deletionTarget(at: 1), let completed = h.coordinator.completed else {
            throw Failure(description: "Deletion confirmation cache precondition missing")
        }
        let revision = h.coordinator.revision
        let captures = h.capturer.calls, compositions = h.composer.calls
        h.interface.captureEntryBlocked = true
        try expect(!h.coordinator.delete(target), "A pending presentation allowed an early deletion")
        // Cancel does not invoke commit or prepareToQuit: the same cached output and revision survive.
        h.interface.captureEntryBlocked = false
        try expect(h.coordinator.revision == revision && h.coordinator.completed?.image === completed.image
                   && h.coordinator.completed?.pngData == completed.pngData
                   && h.coordinator.assets.map { $0.image.width } == [11, 12, 13, 14],
                   "Opening or cancelling a deletion changed retained images, PNG or revision")
        try expect(h.coordinator.delete(target), "The current exact target was not deleted")
        try expect(h.coordinator.assets.map { $0.image.width } == [11, 13, 14]
                   && h.coordinator.plan?.placements.map(\.index) == [0, 1, 2]
                   && h.coordinator.completed == nil && h.coordinator.revision != revision,
                   "Confirmed deletion removed the wrong source or kept stale completed output")
        try expect(!h.coordinator.delete(target) && h.coordinator.assets.count == 3,
                   "A repeated confirmation removed another source")
        try expect(h.capturer.calls == captures && h.composer.calls == compositions && h.clipboard.calls == 0,
                   "A deletion decision acquired, recomposed or copied an image")
    }

    @MainActor
    static func testStaleDeletion() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        for index in 1...3 { try await h.add(index: index, width: 10 + index) }
        guard let shifted = h.coordinator.deletionTarget(at: 1) else { throw Failure(description: "Missing deletion target") }
        try h.delete(at: 0)
        try expect(!h.coordinator.delete(shifted) && h.coordinator.assets.map { $0.image.width } == [12, 13],
                   "Old index removed a different renumbered source")
        guard let replacing = h.coordinator.deletionTarget(at: 0) else { throw Failure(description: "Missing replacement target") }
        h.coordinator.replace(at: 0)
        try expect(!h.coordinator.delete(replacing) && h.coordinator.deletionTarget(at: 0) == nil,
                   "A deletion committed during a later selection")
        h.interface.cancelled?()
        try expect(!h.coordinator.delete(replacing), "A pre-selection confirmation survived its revision")
        guard let ended = h.coordinator.deletionTarget(at: 0) else { throw Failure(description: "Missing old-session target") }
        h.coordinator.discard(); try await h.add(index: 4, width: 24)
        try expect(!h.coordinator.delete(ended) && h.coordinator.assets.map { $0.image.width } == [24],
                   "A previous session's confirmation deleted a fresh same-index source")
        try expect(h.coordinator.deletionTarget(at: -1) == nil && h.coordinator.deletionTarget(at: 1) == nil,
                   "Out-of-range deletion target was accepted")
    }

    @MainActor
    static func testDeletionFences() async throws {
        for unavailable in 0..<3 {
            let h = try Harness(); defer { h.cleanUp() }
            try await h.add(); h.coordinator.preparePreview(); await h.coordinator.waitForWorker()
            guard let target = h.coordinator.deletionTarget(at: 0) else { throw Failure(description: "Missing fenced target") }
            switch unavailable {
            case 0: h.interface.environmentAvailable = false
            case 1: h.permissions.allowed = false
            default: h.permissions.protectedData = false
            }
            try expect(!h.coordinator.delete(target) && !h.coordinator.isActive
                       && h.coordinator.assets.isEmpty && h.coordinator.completed == nil
                       && h.clipboard.calls == 0 && h.interface.feedback.isEmpty,
                       "A deletion decision retained unavailable data or announced success")
        }
        let h = try Harness(); defer { h.cleanUp() }
        try await h.add()
        guard let target = h.coordinator.deletionTarget(at: 0) else { throw Failure(description: "Missing occupied-slot target") }
        let permit = UUID()
        try expect(h.slot.acquire(permit), "Cannot acquire fabricated competing worker")
        try expect(h.coordinator.deletionTarget(at: 0) == nil && !h.coordinator.delete(target)
                   && h.coordinator.assets.count == 1 && h.coordinator.revision == target.revision,
                   "Another mode's worker did not block a deletion decision")
        h.slot.release(permit)
        try expect(h.coordinator.delete(target) && h.coordinator.isActive && h.coordinator.assets.isEmpty,
                   "Released shared slot did not permit an exact last-source deletion")
    }

    @MainActor
    static func testDecisionLifetime() async throws {
        var decision = CollectionDecisionState()
        guard let first = decision.begin() else { throw Failure(description: "Cannot open first decision") }
        try expect(decision.begin() == nil && !decision.answer(UUID()), "A second presentation or foreign button was accepted")
        try expect(decision.answer(first) && !decision.answer(first), "A button answered the same decision twice")
        try expect(decision.consume(first) && !decision.consume(first), "A completion consumed the same decision twice")
        guard let second = decision.begin() else { throw Failure(description: "Cannot open second decision") }
        try expect(!decision.answer(first) && !decision.consume(first) && decision.identifier == second,
                   "An old button or completion affected the new decision")
        decision.invalidate() // hide/session invalidation revokes both unclicked and already-clicked sheets.
        try expect(!decision.answer(second) && !decision.consume(second), "A hidden sheet completed later")
        guard let third = decision.begin() else { throw Failure(description: "Cannot reopen after hide") }
        try expect(decision.answer(third), "Fresh explicit decision did not resume")
        decision.invalidate()
        try expect(!decision.consume(third), "An already-answered sheet survived hide before its callback")
    }

    @MainActor
    static func testDisplayChangeDelivery() async throws {
        // Inject delivery to the owner, not an OS notification or a real display transition.
        for state in 0..<3 {
            let h = try Harness(); defer { h.cleanUp() }
            try await h.add(); try await h.add(index: 2, width: 20)
            switch state {
            case 0:
                h.coordinator.preparePreview(); await h.coordinator.waitForWorker()
                try expect(h.coordinator.completed != nil, "Retained display-change fixture has no completed PNG")
            case 1:
                h.capturer.pauseNext = true; h.coordinator.beginOrAdd(); try h.select()
                try await waitUntil { h.capturer.isWaiting }
            default:
                h.composer.pauseNext = true; h.coordinator.copy()
                try await waitUntil { h.composer.isWaiting }
            }
            let shown = h.interface.collectionActivations.count
            h.coordinator.environmentDidChange(.displayChanged)
            try expect(!h.coordinator.isActive && h.coordinator.assets.isEmpty && h.coordinator.completed == nil
                       && h.interface.dismissCalls > 0
                       && h.coordinator.isWorking == (state != 0) && h.slot.isOccupied == (state != 0),
                       "Display-change delivery retained owner data or released a pending worker")
            h.interface.cancelled?(); h.coordinator.cancelOperation(); h.coordinator.showPanel()
            if state != 0 {
                let selections = h.interface.selectionCalls
                h.coordinator.beginOrAdd()
                try expect(h.interface.selectionCalls == selections, "Invalidated worker allowed a new selection")
            }
            if state == 1 { try h.capturer.release() }
            if state == 2 { try h.composer.release() }
            await h.coordinator.waitForWorker()
            try expect(h.coordinator.phase == .idle && !h.slot.isOccupied && !h.coordinator.isWorking
                       && h.interface.collectionActivations.count == shown + 1 && h.clipboard.calls == 0
                       && h.interface.feedback.isEmpty && h.coordinator.completed == nil,
                       "Display-change late result or old UI restored images, success, or copy")
            try await h.add(index: 3)
            try expect(h.coordinator.assets.count == 1, "Display change prevented a fresh explicit session")
        }
    }

    @MainActor
    static func testUnavailableCancellation() async throws {
        for unavailable in 0..<3 {
            for state in 0..<3 {
                let h = try Harness(); defer { h.cleanUp() }
                try await h.add(); try await h.add(index: 2, width: 20)
                switch state {
                case 0: h.coordinator.beginOrAdd()
                case 1:
                    h.capturer.pauseNext = true; h.coordinator.beginOrAdd(); try h.select()
                    try await waitUntil { h.capturer.isWaiting }
                default:
                    h.composer.pauseNext = true; h.coordinator.preparePreview()
                    try await waitUntil { h.composer.isWaiting }
                }
                let shown = h.interface.collectionActivations.count
                switch unavailable {
                case 0: h.interface.environmentAvailable = false
                case 1: h.permissions.allowed = false
                default: h.permissions.protectedData = false
                }
                h.coordinator.cancelOperation()
                try expect(!h.coordinator.isActive && h.coordinator.assets.isEmpty && h.coordinator.completed == nil
                           && h.interface.dismissCalls > 0
                           && h.interface.collectionActivations.count == shown
                           && h.coordinator.isWorking == (state != 0) && h.slot.isOccupied == (state != 0),
                           "Cancel redisplayed unavailable sources or released a pending worker")
                // Becoming available again cannot make the invalidated result current.
                h.interface.environmentAvailable = true; h.permissions.allowed = true; h.permissions.protectedData = true
                if state == 1 { try h.capturer.release(error: .displayChanged) }
                if state == 2 { try h.composer.release() }
                await h.coordinator.waitForWorker()
                try expect(h.coordinator.phase == .idle && !h.slot.isOccupied && h.coordinator.assets.isEmpty
                           && h.coordinator.completed == nil && h.interface.collectionActivations.count == shown
                           && h.clipboard.calls == 0 && h.interface.feedback.isEmpty,
                           "Late unavailable-cancel result or error revived the old session")
                try await h.add(index: 3)
                try expect(h.coordinator.assets.count == 1, "Cancel fence prevented fresh explicit recovery")
            }
        }
    }

    @MainActor
    static func testDisplayChangeError() async throws {
        @MainActor final class DisplayAvailability { var unavailable = false }
        for replacing in [false, true] {
            for error in [ScreenshotError.displayChanged, .captureFailed] {
                let h = try Harness(); defer { h.cleanUp() }
                try await h.add(); try await h.add(index: 2, width: 20)
                let originals = h.coordinator.assets.map(\.image)
                h.capturer.errorNext = error
                if replacing { h.coordinator.replace(at: 0) } else { h.coordinator.beginOrAdd() }
                let shown = h.interface.collectionActivations.count
                try h.select(); await h.coordinator.waitForWorker()
                if error == .displayChanged {
                    try expect(!h.coordinator.isActive && h.coordinator.assets.isEmpty && h.coordinator.completed == nil
                               && h.interface.dismissCalls > 0
                               && h.interface.collectionActivations.count == shown,
                               "Detected display change became a retry with old sources")
                } else {
                    try expect(h.coordinator.phase == .ready && h.coordinator.assets.count == 2
                               && h.coordinator.assets[0].image === originals[0]
                               && h.coordinator.assets[1].image === originals[1],
                               "Ordinary capture failure discarded or replaced old sources")
                }
                try expect(!h.slot.isOccupied && h.clipboard.calls == 0 && h.interface.feedback.isEmpty,
                           "Capture error retained a worker or reported copy success")
            }
        }
        let display = try CaptureDisplaySnapshot(id: 99, frame: CGRect(x: 0, y: 0, width: 640, height: 480), scale: 1)
        let availability = DisplayAvailability()
        let selection = try Harness(displayAtPointer: {
            if availability.unavailable { throw ScreenshotError.displayChanged }
            return display
        })
        defer { selection.cleanUp() }
        try await selection.add(); selection.coordinator.preparePreview(); await selection.coordinator.waitForWorker()
        let captures = selection.capturer.calls, shown = selection.interface.collectionActivations.count
        availability.unavailable = true; selection.coordinator.replace(at: 0)
        try expect(!selection.coordinator.isActive && selection.coordinator.assets.isEmpty && selection.coordinator.completed == nil
                   && selection.capturer.calls == captures && selection.interface.collectionActivations.count == shown,
                   "Display lookup failure retained a session or started capture")

        let late = try Harness(); defer { late.cleanUp() }
        try await late.add()
        let original = late.coordinator.assets[0].image
        late.capturer.pauseNext = true; late.coordinator.beginOrAdd(); try late.select()
        try await waitUntil { late.capturer.isWaiting }
        late.coordinator.cancelOperation()
        let token = late.coordinator.revision, session = late.coordinator.sessionID
        let activations = late.interface.collectionActivations.count
        try late.capturer.release(error: .displayChanged); await late.coordinator.waitForWorker()
        try expect(late.coordinator.phase == .ready && late.coordinator.sessionID == session && late.coordinator.revision == token
                   && late.coordinator.assets.count == 1 && late.coordinator.assets[0].image === original
                   && late.interface.collectionActivations.count == activations && late.clipboard.calls == 0,
                   "An obsolete worker's display error invalidated a healthy cancelled session")
    }

    @MainActor
    static func testReplacementContentRevision() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        try await h.add(); try await h.add(index: 2, width: 20)
        h.coordinator.copy(); await h.coordinator.waitForWorker()
        let content = h.coordinator.contentRevision, copied = h.coordinator.copiedContentRevision
        let sourceIDs = h.coordinator.items.map(\.id), original = h.coordinator.assets[0].image
        h.capturer.nextAsset = try M0ImageFixture.make(index: 3, width: 24, height: 12)
        h.coordinator.replace(assetID: sourceIDs[0]); try h.select(width: 24, height: 12)
        await h.coordinator.waitForWorker()
        guard let rejected = h.coordinator.pendingReplacement else { throw Failure(description: "Missing replacement decision") }
        try expect(h.coordinator.contentRevision == content && h.coordinator.copiedContentRevision == copied
                   && h.coordinator.isCopiedCurrent && h.coordinator.needsEndConfirmation
                   && h.coordinator.assets[0].image === original && h.coordinator.items.map(\.id) == sourceIDs,
                   "Acquiring a candidate changed copied content, source identity or the old image")
        h.coordinator.keepOriginalReplacement(id: rejected.id)
        try expect(h.coordinator.pendingReplacement == nil && h.coordinator.contentRevision == content
                   && h.coordinator.copiedContentRevision == copied && h.coordinator.isCopiedCurrent
                   && !h.coordinator.needsEndConfirmation && h.coordinator.assets[0].image === original,
                   "Keeping the original changed content or lost the previous copy state")
        h.coordinator.replace(assetID: sourceIDs[0]); try h.select(width: 24, height: 12)
        await h.coordinator.waitForWorker()
        guard let accepted = h.coordinator.pendingReplacement else { throw Failure(description: "Missing second replacement decision") }
        h.coordinator.acceptReplacement(id: rejected.id)
        try expect(h.coordinator.pendingReplacement?.id == accepted.id && h.coordinator.contentRevision == content,
                   "A stale candidate decision changed the current review")
        h.coordinator.acceptReplacement(id: accepted.id)
        let adoptedContent = h.coordinator.contentRevision
        try expect(adoptedContent != content && h.coordinator.copiedContentRevision == copied
                   && !h.coordinator.isCopiedCurrent && h.coordinator.needsEndConfirmation
                   && h.coordinator.items.map(\.id) == sourceIDs && h.coordinator.assets.map { $0.image.width } == [24, 20],
                   "Adoption failed to change only the selected content at its stable identity")
        h.coordinator.acceptReplacement(id: accepted.id)
        h.coordinator.keepOriginalReplacement(id: rejected.id)
        try expect(h.coordinator.contentRevision == adoptedContent && h.coordinator.pendingReplacement == nil,
                   "An already completed review changed content again")
        h.coordinator.copy(); await h.coordinator.waitForWorker()
        try expect(h.coordinator.isCopiedCurrent && h.coordinator.copiedContentRevision == adoptedContent,
                   "Copying the adopted content did not acknowledge its revision")
    }

    @MainActor
    static func testCopiedContentCancellation() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        try await h.add()
        h.coordinator.copy(); await h.coordinator.waitForWorker()
        let session = h.coordinator.sessionID, content = h.coordinator.contentRevision
        let copied = h.coordinator.copiedContentRevision, image = h.coordinator.assets[0].image
        h.coordinator.beginOrAdd(); h.coordinator.cancelOperation()
        try expect(h.coordinator.sessionID == session && h.coordinator.contentRevision == content
                   && h.coordinator.copiedContentRevision == copied && h.coordinator.isCopiedCurrent
                   && h.coordinator.assets[0].image === image, "Selection cancellation changed the copied draft")
        h.composer.pauseNext = true; h.coordinator.preparePreview()
        try await waitUntil { h.composer.isWaiting }
        h.coordinator.cancelOperation()
        let selections = h.interface.selectionCalls, writes = h.clipboard.calls
        try expect(h.coordinator.phase == .cancelling && h.coordinator.isWorking && h.slot.isOccupied
                   && h.coordinator.latestResultText.contains("取り消して")
                   && !h.coordinator.latestResultText.contains("取り消しました"),
                   "Cancellation reported completion before the worker returned")
        h.coordinator.beginFromShortcut(); h.coordinator.copy()
        try expect(h.interface.selectionCalls == selections && h.clipboard.calls == writes
                   && h.coordinator.contentRevision == content && h.coordinator.copiedContentRevision == copied,
                   "Cancellation waiting started the next operation or changed copy state")
        try h.composer.release(); await h.coordinator.waitForWorker()
        try expect(h.coordinator.phase == .ready && !h.slot.isOccupied && h.coordinator.completed == nil
                   && h.coordinator.latestResultText.contains("取り消しました")
                   && h.coordinator.sessionID == session && h.coordinator.contentRevision == content
                   && h.coordinator.copiedContentRevision == copied && h.coordinator.isCopiedCurrent
                   && h.clipboard.calls == writes && h.coordinator.assets[0].image === image,
                   "A cancelled late result replaced retained content, copy state or the cancellation result")
    }

    @MainActor
    static func testRecopyFailureStatus() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        try await h.add()
        h.coordinator.copy(); await h.coordinator.waitForWorker()
        let copied = h.coordinator.copiedContentRevision
        h.clipboard.mode = .rejectedAfterPrepare
        h.coordinator.copy(); await h.coordinator.waitForWorker()
        try expect(h.coordinator.isCopiedCurrent && h.coordinator.copiedContentRevision == copied
                   && h.coordinator.contentStatusText.contains("前回コピー後に素材変更なし")
                   && h.coordinator.latestResultText.contains("コピーできませんでした")
                   && h.coordinator.latestResultText.contains("残っていない場合")
                   && h.clipboard.accepted == 1 && h.coordinator.hasRetainedImages,
                   "A prior successful copy hid the latest recopy failure or its clipboard uncertainty")
    }

    @MainActor
    static func testInvalidationNotice() async throws {
        for copyState in 0..<3 {
            let h = try Harness(); defer { h.cleanUp() }
            try await h.add(); try await h.add(index: 2, width: 20)
            if copyState > 0 { h.coordinator.copy(); await h.coordinator.waitForWorker() }
            if copyState == 2 { try await h.add(index: 3, width: 24) }
            let count = h.coordinator.assets.count
            h.coordinator.environmentDidChange(.systemSleep)
            guard let notice = h.coordinator.invalidationNotice else { throw Failure(description: "Missing invalidation notice") }
            let expectedCopyState = copyState == 0 ? "このまとめはコピーしていません"
                : (copyState == 1 ? "この内容の前回コピーは成功しました" : "前回コピー後の変更はコピーしていません")
            try expect(notice.contains("前のまとめ\(count)枚") && notice.contains(expectedCopyState)
                       && !h.coordinator.isActive && h.coordinator.assets.isEmpty,
                       "Invalidation omitted the previous image count or the last copied content state")
            h.coordinator.environmentDidChange(.displayChanged)
            try expect(h.coordinator.invalidationNotice == notice && h.coordinator.latestResultText == notice,
                       "An environment event with no sources overwrote the substantive loss notice")
            let selections = h.interface.selectionCalls, shown = h.interface.collectionActivations.count
            h.coordinator.beginFromShortcut(); h.coordinator.beginOrAdd()
            try expect(h.coordinator.invalidationNotice == notice && !h.coordinator.isActive
                       && h.interface.selectionCalls == selections && h.interface.collectionActivations.count == shown + 2,
                       "The next shortcut/add action erased the notice or silently started a new draft")
            h.coordinator.beginNewSession()
            try expect(h.coordinator.invalidationNotice == nil && h.coordinator.phase == .selecting
                       && h.interface.selectionCalls == selections + 1,
                       "An explicit new draft could not acknowledge the notice and resume")
            h.coordinator.cancelOperation()
        }
    }

    @MainActor
    static func testNewSessionAdmission() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        try await h.add()
        h.coordinator.copy(); await h.coordinator.waitForWorker()
        let session = h.coordinator.sessionID, content = h.coordinator.contentRevision
        let copied = h.coordinator.copiedContentRevision, image = h.coordinator.assets[0].image
        let sourceID = h.coordinator.items[0].id, selections = h.interface.selectionCalls
        h.interface.prepareResult = false
        h.coordinator.beginNewSession()
        h.interface.prepareResult = true
        h.coordinator.externalOperationBlocked = { true }
        h.coordinator.beginNewSession()
        h.coordinator.externalOperationBlocked = { false }
        h.interface.captureEntryBlocked = true
        h.coordinator.beginFromShortcut()
        try expect(h.coordinator.sessionID == session && h.coordinator.contentRevision == content
                   && h.coordinator.copiedContentRevision == copied && h.coordinator.items[0].id == sourceID
                   && h.coordinator.assets[0].image === image && h.interface.selectionCalls == selections,
                   "Rejected new-draft admission discarded the retained copied draft")
        h.interface.captureEntryBlocked = false
        h.coordinator.beginFromShortcut()
        try expect(h.coordinator.phase == .selecting && h.coordinator.sessionID != session
                   && h.coordinator.assets.isEmpty && h.coordinator.copiedContentRevision == nil
                   && h.interface.selectionCalls == selections + 1,
                   "An unchanged copied draft required confirmation or failed to start the next shortcut draft")
        h.coordinator.cancelOperation()
        try await h.add()
        let uncopiedSession = h.coordinator.sessionID
        h.coordinator.beginNewSession()
        try expect(h.coordinator.sessionID == uncopiedSession && h.coordinator.hasRetainedImages
                   && h.coordinator.latestResultText.contains("終了を確認"),
                   "An unconfirmed new draft discarded uncopied content")
        h.coordinator.beginNewSession(discardConfirmed: true)
        try expect(h.coordinator.phase == .selecting && h.coordinator.sessionID != uncopiedSession
                   && h.coordinator.assets.isEmpty, "Confirmed draft replacement did not start a fresh selection")
        h.coordinator.cancelOperation()
    }

    @MainActor
    static func testSingleWithRetainedCollection() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        try await h.add(); try await h.add(index: 2, width: 20)
        h.coordinator.preparePreview(); await h.coordinator.waitForWorker()
        try expect(h.coordinator.completed != nil, "Missing collection cache for independent single capture")
        let content = h.coordinator.contentRevision, sourceIDs = h.coordinator.items.map(\.id)
        // Record identity without retaining source buffers past an explicit end of editing.
        let originals = h.coordinator.assets.map { ObjectIdentifier($0.image) }
        let singleUI = FakeInterface(), singleCapture = FakeCapture(asset: try M0ImageFixture.make(index: 4, width: 16, height: 16))
        let single = h.makeSingle(interface: singleUI, capturer: singleCapture)
        defer { single.stop(); singleCapture.releaseIfPending() }
        single.prepareExternalCapture = { h.coordinator.prepareForSingleCapture() }
        single.externalRetainedBytes = { h.coordinator.retainedImageBytes }
        h.coordinator.externalOperationBlocked = { [weak single] in
            guard let single else { return false }
            return single.isWorking || single.hasRetainedImage || [.onboarding, .permission, .selecting].contains(single.phase)
        }
        h.coordinator.externalWorkInProgress = { [weak single] in
            guard let single else { return false }
            return single.isWorking || [.selecting, .permission, .onboarding].contains(single.phase)
        }
        single.begin()
        try expect(h.coordinator.completed == nil && single.phase == .selecting
                   && !h.coordinator.canEdit && !h.coordinator.canEndSession,
                   "Independent single entry retained regenerable collection output or allowed parallel editing")
        h.coordinator.discard()
        try expect(h.coordinator.isActive && h.coordinator.contentRevision == content
                   && h.coordinator.items.map(\.id) == sourceIDs && single.phase == .selecting,
                   "Collection ending during single selection discarded the draft or changed the single operation")
        let expectedBudget = h.coordinator.retainedImageBytes
        singleCapture.pauseNext = true
        singleUI.selected?(try h.selection())
        try await waitUntil { singleCapture.isWaiting }
        h.coordinator.discard()
        try expect(!h.coordinator.canEndSession && h.coordinator.isActive
                   && h.coordinator.contentRevision == content && h.coordinator.items.map(\.id) == sourceIDs
                   && single.isWorking && h.slot.isOccupied,
                   "Collection ending during single acquisition discarded sources or released live work")
        try singleCapture.release(); await single.waitForWorker()
        try expect(singleCapture.calls == 1 && h.clipboard.accepted == 1
                   && singleCapture.requests.last?.budget.retainingExtraBytes == expectedBudget
                   && h.coordinator.contentRevision == content && h.coordinator.copiedContentRevision == nil
                   && h.coordinator.items.map(\.id) == sourceIDs && ObjectIdentifier(h.coordinator.assets[0].image) == originals[0]
                   && ObjectIdentifier(h.coordinator.assets[1].image) == originals[1] && h.coordinator.canEdit,
                   "Single capture did not copy independently while preserving the collection and its byte accounting")
        h.clipboard.mode = .rejectedBeforePrepare
        single.begin(); singleUI.selected?(try h.selection()); await single.waitForWorker()
        try expect(single.hasRetainedImage && !h.coordinator.canEdit && !h.coordinator.canCopy
                   && h.coordinator.canEndSession,
                   "A failed single image did not make collection editing/copying read-only")
        let captures = h.capturer.calls, compositions = h.composer.calls, writes = h.clipboard.calls
        h.coordinator.beginOrAdd(); h.coordinator.replace(assetID: sourceIDs[0]); h.coordinator.copy(); h.coordinator.preparePreview()
        try expect(h.coordinator.deletionTarget(assetID: sourceIDs[0]) == nil && h.capturer.calls == captures
                   && h.composer.calls == compositions && h.clipboard.calls == writes
                   && h.coordinator.contentRevision == content && h.coordinator.items.map(\.id) == sourceIDs,
                   "A retained failed single image allowed collection acquisition, composition, deletion or copying")
        h.coordinator.showPanel()
        single.discard()
        try expect(h.coordinator.canEdit && h.coordinator.contentRevision == content
                   && ObjectIdentifier(h.coordinator.assets[0].image) == originals[0]
                   && ObjectIdentifier(h.coordinator.assets[1].image) == originals[1],
                   "Discarding only the single image damaged or failed to re-enable the collection")

        single.begin(); singleUI.selected?(try h.selection()); await single.waitForWorker()
        let singleProblem = single.problem, singleCaptures = singleCapture.calls
        let collectionBytes = h.coordinator.retainedImageBytes, previousWrites = h.clipboard.calls
        try expect(single.hasRetainedImage && !single.isWorking && h.coordinator.canEndSession
                   && !h.coordinator.canEdit && !h.coordinator.canCopy,
                   "A retained single retry unexpectedly permitted collection editing or blocked explicit ending")
        #if DEBUG
        try expect(single.hasRetainedPNG, "Single end-session precondition has no retained PNG")
        #endif
        // The fake service must also relinquish its last collection fixture, just as the real
        // service does. Only coordinator/UI image retention belongs in this shared estimate.
        h.capturer.nextAsset = try M0ImageFixture.make(index: 3, width: 1, height: 1)
        h.coordinator.discard()
        try expect(!h.coordinator.isActive && h.coordinator.assets.isEmpty && h.coordinator.completed == nil
                   && h.coordinator.retainedImageBytes < collectionBytes && single.hasRetainedImage
                   && single.phase == .failure && single.problem == singleProblem
                   && singleCapture.calls == singleCaptures && h.clipboard.calls == previousWrites,
                   "Explicit collection ending failed to release its budget or changed the retained single image")
        #if DEBUG
        try expect(single.hasRetainedPNG, "Ending the collection discarded the single PNG cache")
        #endif
        h.clipboard.mode = .accepted
        single.retryCopy(); await single.waitForWorker()
        try expect(h.clipboard.accepted == 2 && singleCapture.calls == singleCaptures
                   && !single.hasRetainedImage && !h.coordinator.isActive,
                   "The retained single image could not retry after collection ending without recapture")
    }

    @MainActor
    static func testReplacementDecisionFences() async throws {
        for unavailable in 0..<3 {
            for decision in 0..<3 {
                let h = try Harness(); defer { h.cleanUp() }
                try await h.add()
                h.capturer.nextAsset = try M0ImageFixture.make(index: 2, width: 20, height: 12)
                h.coordinator.replace(at: 0); try h.select(width: 20, height: 12)
                await h.coordinator.waitForWorker()
                guard let pending = h.coordinator.pendingReplacement else { throw Failure(description: "Missing fenced replacement") }
                switch unavailable {
                case 0: h.interface.environmentAvailable = false
                case 1: h.permissions.allowed = false
                default: h.permissions.protectedData = false
                }
                switch decision {
                case 0: h.coordinator.acceptReplacement(id: pending.id)
                case 1: h.coordinator.keepOriginalReplacement(id: pending.id)
                default: h.coordinator.retryReplacement(id: pending.id)
                }
                try expect(!h.coordinator.isActive && h.coordinator.assets.isEmpty
                           && h.coordinator.pendingReplacement == nil && h.coordinator.invalidationNotice != nil
                           && h.clipboard.calls == 0 && !h.slot.isOccupied,
                           "A replacement decision retained unavailable original/candidate data or copied it")
            }
        }
    }

    /// All environment signals share the same security invariant even when the draft was
    /// copied, edited afterwards, or owns a replacement candidate. No OS event is emitted.
    @MainActor
    static func testEnvironmentRetainedMatrix() async throws {
        var cases = 0
        for event in CaptureEnvironmentEvent.allCases {
            for copyState in 0..<3 {
                for withCandidate in [false, true] {
                  for visible in [false, true] {
                    let h = try Harness(); defer { h.cleanUp() }
                    try await h.add(); try await h.add(index: 2, width: 20)
                    if copyState > 0 { h.coordinator.copy(); await h.coordinator.waitForWorker() }
                    if copyState == 2 { try await h.add(index: 3, width: 24) }
                    if withCandidate {
                        h.capturer.nextAsset = try M0ImageFixture.make(index: 4, width: 28, height: 16)
                        h.coordinator.replace(at: 0); try h.select(width: 28)
                        await h.coordinator.waitForWorker()
                        try expect(h.coordinator.pendingReplacement != nil, "Candidate precondition missing")
                    } else {
                        h.coordinator.preparePreview(); await h.coordinator.waitForWorker()
                        try expect(h.coordinator.completed != nil, "Cached output precondition missing")
                    }
                    let candidateID = h.coordinator.pendingReplacement?.id
                    if visible { h.coordinator.showPanel() } else { h.interface.hideCollection() }
                    try expect(h.interface.collectionVisible == visible, "Visibility precondition missing")
                    let staleSelection = h.interface.selected
                    let calls = h.capturer.calls, writes = h.clipboard.calls
                    let feedback = h.interface.feedback.count
                    h.coordinator.environmentDidChange(event)
                    try expect(!h.coordinator.isActive && h.coordinator.assets.isEmpty
                               && h.coordinator.completed == nil && h.coordinator.pendingReplacement == nil
                               && h.coordinator.copiedContentRevision == nil && !h.slot.isOccupied,
                               "Environment event retained a copied draft, candidate, cache or session")
                    try expect(!h.interface.collectionVisible, "Invalidation left image presentation visible")
                    staleSelection?(try h.selection())
                    if let candidateID { h.coordinator.acceptReplacement(id: candidateID) }
                    h.coordinator.showPanel(); h.coordinator.copy(); h.coordinator.beginFromShortcut()
                    try expect(h.capturer.calls == calls && h.clipboard.calls == writes
                               && h.interface.feedback.count == feedback && !h.coordinator.isActive,
                               "An obsolete callback, copy or shortcut revived invalidated content")
                    h.coordinator.beginNewSession()
                    try expect(h.coordinator.phase == .selecting && h.coordinator.assets.isEmpty,
                               "A new explicit session could not recover after invalidation")
                    h.coordinator.cancelOperation()
                    cases += 1
                  }
                }
            }
        }
        try expect(cases == CaptureEnvironmentEvent.allCases.count * 12,
                   "The retained-state matrix did not cover every event and state")
        print("PASS SECURITY retained-state matrix cases=\(cases) injectedEvents=1")
    }

    /// The injected services deliberately return after cancellation. Each event is tested
    /// with both a late success and an exception at capture and composition boundaries.
    @MainActor
    static func testEnvironmentLateMatrix() async throws {
        var cases = 0
        for event in CaptureEnvironmentEvent.allCases {
            for duringEncoding in [false, true] {
                for lateFailure in [false, true] {
                    let h = try Harness(); defer { h.cleanUp() }
                    try await h.add()
                    h.coordinator.copy(); await h.coordinator.waitForWorker()
                    let writes = h.clipboard.calls, feedback = h.interface.feedback.count
                    if duringEncoding {
                        h.composer.pauseNext = true; h.coordinator.copy()
                        try await waitUntil { h.composer.isWaiting }
                    } else {
                        h.capturer.pauseNext = true; h.coordinator.beginOrAdd(); try h.select()
                        try await waitUntil { h.capturer.isWaiting }
                    }
                    h.coordinator.environmentDidChange(event)
                    try expect(!h.coordinator.isActive && h.coordinator.assets.isEmpty
                               && h.coordinator.pendingReplacement == nil && h.coordinator.completed == nil
                               && h.coordinator.isWorking && h.slot.isOccupied,
                               "Invalidation released the live worker permit or retained source state")
                    let selections = h.interface.selectionCalls
                    let shown = h.interface.collectionActivations.count
                    h.coordinator.beginNewSession(); h.coordinator.copy()
                    try expect(h.interface.selectionCalls == selections && h.clipboard.calls == writes,
                               "New work overlapped an invalidated but unfinished worker")
                    if duringEncoding {
                        h.composer.failNext = lateFailure
                        try h.composer.release()
                    } else {
                        try h.capturer.release(error: lateFailure ? .captureFailed : nil)
                    }
                    await h.coordinator.waitForWorker()
                    try expect(!h.slot.isOccupied && !h.coordinator.isWorking && !h.coordinator.isActive
                               && h.coordinator.assets.isEmpty && h.coordinator.completed == nil
                               && h.coordinator.pendingReplacement == nil && h.clipboard.calls == writes
                               && h.interface.feedback.count == feedback
                               && h.interface.collectionActivations.count == shown,
                               "A late success or failure revived invalidated pixels, UI or clipboard output")
                    try await h.add(index: 2)
                    try expect(h.coordinator.assets.count == 1,
                               "Fresh explicit capture failed after the old worker actually returned")
                    cases += 1
                }
            }
        }
        try expect(cases == CaptureEnvironmentEvent.allCases.count * 4,
                   "The late-result matrix did not cover every event and outcome")
        print("PASS SECURITY late-result matrix cases=\(cases) injectedEvents=1")
    }

    @MainActor
    static func testSingleEntryRetainedFence() async throws {
        for unavailable in 0..<3 {
            let h = try Harness(); defer { h.cleanUp() }
            try await h.add()
            h.coordinator.preparePreview(); await h.coordinator.waitForWorker()
            switch unavailable {
            case 0: h.permissions.allowed = false
            case 1: h.permissions.protectedData = false
            default: h.interface.environmentAvailable = false
            }
            let admitted = h.coordinator.prepareForSingleCapture()
            try expect(admitted == (unavailable != 2) && !h.coordinator.isActive
                       && h.coordinator.assets.isEmpty && h.coordinator.completed == nil
                       && h.coordinator.pendingReplacement == nil && h.coordinator.invalidationNotice != nil
                       && h.permissions.requestCalls == 0 && h.clipboard.calls == 0 && !h.slot.isOccupied,
                       "Single entry retained unavailable collection data, requested permission, or used the wrong admission result")
        }

        let fresh = try Harness(); defer { fresh.cleanUp() }
        fresh.permissions.allowed = false
        let singleUI = FakeInterface(), singleCapture = FakeCapture(asset: try M0ImageFixture.make(index: 4, width: 16, height: 16))
        let single = fresh.makeSingle(interface: singleUI, capturer: singleCapture)
        defer { single.stop(); singleCapture.releaseIfPending() }
        single.prepareExternalCapture = { fresh.coordinator.prepareForSingleCapture() }
        single.begin()
        try expect(single.phase == .permission && singleUI.permissionCalls == 1
                   && singleCapture.calls == 0 && fresh.permissions.requestCalls == 0
                   && !fresh.coordinator.isActive && fresh.coordinator.invalidationNotice == nil,
                   "An inactive collection blocked the single mode's explicit first permission guidance")

        let empty = try Harness(); defer { empty.cleanUp() }
        try await empty.add(); try empty.delete(at: 0)
        let session = empty.coordinator.sessionID
        empty.permissions.allowed = false; empty.permissions.protectedData = false
        try expect(empty.coordinator.prepareForSingleCapture() && empty.coordinator.sessionID == session
                   && empty.coordinator.assets.isEmpty && empty.coordinator.invalidationNotice == nil,
                   "An empty edited collection blocked single entry or invented a retained-image loss")
    }

}
