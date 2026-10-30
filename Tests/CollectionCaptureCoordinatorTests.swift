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
            ("M3-COORD-03 replacement adopts only success at the same position", testReplacement),
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
            ("SETTINGS-COLLECTION-02 guide and permission preserve entry origin", testSettingsOrigin)
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
        func showCollection(activate: Bool) { collectionActivations.append(activate) }
        func hideCollection() { hideCollectionCalls += 1 }
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
        var beforeWrite: (@MainActor () -> Void)?
        var changeCount: Int { count }
        func writePNG(_ data: Data, expectedChangeCount: Int) -> M0ClipboardProbe.Outcome {
            calls += 1; expectedCounts.append(expectedChangeCount)
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
            return try M0ImageComposer.compose(assets: assets, limits: limits)
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
    static func testAddAndDelete() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        for index in 1...4 { try await h.add(index: index, width: 10 + index) }
        try expect(h.coordinator.assets.map { $0.image.width } == [11, 12, 13, 14], "Successful additions changed order")
        let selected = h.interface.selectionCalls, captured = h.capturer.calls
        h.coordinator.beginOrAdd()
        try expect(!h.coordinator.canAdd && h.interface.selectionCalls == selected && h.capturer.calls == captured,
                   "Fifth addition started selection or acquisition")
        try h.delete(at: 1)
        try expect(h.coordinator.assets.map { $0.image.width } == [11, 13, 14], "Delete removed the wrong source")
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
        try expect(!h.coordinator.isActive && h.coordinator.assets.isEmpty && h.coordinator.completed == nil
                   && !h.slot.isOccupied && h.interface.feedback.count == 1, "Success retained a session or worker")
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
        try expect(!h.coordinator.isActive && !h.slot.isOccupied, "Writing completion retained the session")
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
        h.coordinator.cancelOperation(); h.coordinator.showPanel()
        try expect(h.coordinator.phase == .idle && !h.coordinator.isActive && h.interface.collectionActivations.count == shows,
                   "Invalidated callback revived collection UI")
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
            try expect(!h.coordinator.isActive && h.clipboard.accepted == 1 && h.composer.calls == 1,
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
                       && h.interface.collectionActivations.count == shown && h.clipboard.calls == 0
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

}
