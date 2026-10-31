import AppKit
import Foundation

/// All services are injected. This executable does not initialize the shared coordinator,
/// create windows, request permissions, capture a screen, or access any OS pasteboard.
@main
struct SingleCaptureCoordinatorTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    static func main() async throws {
        let groups: [(String, @MainActor () async throws -> Void)] = [
            ("M1-COORD-01 normal write and release", testNormal),
            ("M1-COORD-02 permission is explicit and never auto-restarts", testPermission),
            ("M1-COORD-03 Esc and stale selection callback", testSelectionCancellation),
            ("M1-COORD-04 late capture cancellation owns worker slot", testLateCaptureCancellation),
            ("M1-COORD-05 late encoder cancellation owns worker slot", testLateEncodeCancellation),
            ("M1-COORD-06 duplicate begin and confirmation", testDuplicates),
            ("M1-COORD-07 capture failure retries selection", testCaptureFailure),
            ("M1-COORD-08 encode failure retries without recapture", testEncodeFailure),
            ("M1-COORD-09 rejected write retries cached image", testWriteFailure),
            ("M1-COORD-10 discard releases failed image", testDiscard),
            ("M1-COORD-11 count race never reports success", testCountConflict),
            ("M1-COORD-12 permission revoked during capture", testPermissionRevocation),
            ("M1-COORD-13 protected data revoked during encoding", testProtectedDataRevocation),
            ("M1-COORD-14 hidden-overlay failure and wrong display", testInvalidSelectionBoundary),
            ("M1-COORD-15 inactive app keeps external focus", testInactiveFocus),
            ("M1-COORD-16 cancelled quit keeps acquired image without late write", testQuitPreparation),
            ("M2-COORD-17 first guide requires acknowledgement and rejects stale callbacks", testFirstGuide),
            ("M2-COORD-18 guide and paste acknowledgements persist separately", testPreferences),
            ("M2-COORD-19 blocked settings/sheet reject all entry paths", testBlockedEntries),
            ("M2-COORD-20 request-unconfirmed permission and explicit recovery", testUnconfirmedPermission),
            ("M2-COORD-21 revoked permission returns to explicit guidance", testRevokedPermissionGuidance),
            ("M2-COORD-22 failure stage and quit retain clipboard uncertainty", testFailureStages),
            ("M2-COORD-23 discard and stop reject late results", testDiscardAndStopLateResults),
            ("M2-COORD-24 first paste hint waits for an accepted write", testFirstPasteHint),
            ("M2-COORD-25 switching apps during processing keeps external focus", testExternalSwitchDuringWorker),
            ("D06-COORD-01 environment events release retained image and PNG synchronously", testEnvironmentRetainedInvalidation),
            ("D06-COORD-02 environment events reject gated late capture and keep worker occupied", testEnvironmentLateCapture),
            ("D06-COORD-03 environment events reject gated late encoding and keep worker occupied", testEnvironmentLateEncoding),
            ("D06-COORD-04 unavailable session blocks entry and retained retry", testSessionFenceEntry),
            ("D06-COORD-05 session fence rejects late capture without a delivered callback", testSessionFenceCapture),
            ("D06-COORD-06 session fence rejects late encoding and error UI", testSessionFenceEncoding),
            ("SETTINGS-COORD-01 invalid window stops before capture or write", testSettingsBoundary),
            ("SETTINGS-COORD-02 guide and retry preserve entry origin", testSettingsOrigin),
            ("UX-SINGLE-01 external preparation blocks entry without discarding state", testExternalPreparation),
            ("UX-SINGLE-02 retained collection bytes reach acquisition and enforce its boundary", testExternalAcquisitionBudget),
            ("UX-SINGLE-03 changed external retention rejects a late image before adoption", testExternalAdoptionBudget),
            ("UX-SINGLE-04 changed external retention rejects encoded PNG and keeps its source", testExternalEncodingBudget),
            ("UX-SINGLE-05 cached retry rechecks external retention before writing", testExternalCachedBudget),
            ("UX-SINGLE-06 actual encoded size cannot bypass the shared budget", testActualEncodedBudget),
            ("UX-SINGLE-07 activation refreshes permission without starting capture", testPermissionRefresh)
        ]
        for (name, body) in groups {
            try await body()
            print("PASS \(name)")
        }
        print("PASS \(groups.count) coordinator groups; injected services only")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }

    @MainActor
    static func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        throw Failure(description: "Injected worker did not reach the expected gate")
    }

    @MainActor
    final class PermissionBox {
        var allowed = true
        var protectedData = true
        var requestGrants = false
        var requestCalls = 0
    }

    @MainActor
    final class RetainedImageBudgetBox {
        var bytes = 0
    }

    @MainActor
    final class FakeClipboard: CaptureClipboardWriting {
        enum Mode: Equatable { case accepted, rejected, conflict }
        var mode = Mode.accepted
        var count = 7
        var calls = 0
        var successfulWrites = 0
        var expectedCounts: [Int] = []
        var writtenData: [Data] = []

        var changeCount: Int { count }

        func writePNG(_ data: Data, expectedChangeCount: Int) -> M0ClipboardProbe.Outcome {
            calls += 1
            expectedCounts.append(expectedChangeCount)
            guard count == expectedChangeCount, mode != .conflict else {
                return M0ClipboardProbe.Outcome(code: .conflictBeforePrepare, expectedChangeCount: expectedChangeCount,
                                                observedChangeCount: count, preparedChangeCount: nil)
            }
            count += 1
            guard mode == .accepted else {
                return M0ClipboardProbe.Outcome(code: .writeRejected, expectedChangeCount: expectedChangeCount,
                                                observedChangeCount: count, preparedChangeCount: count)
            }
            successfulWrites += 1
            writtenData.append(data)
            return M0ClipboardProbe.Outcome(code: .writeAccepted, expectedChangeCount: expectedChangeCount,
                                            observedChangeCount: count, preparedChangeCount: count)
        }
    }

    @MainActor
    final class FakeInterface: SingleCaptureInterface {
        var isOneClipActive = true
        var captureEntryBlocked = false
        var rejectSettings = false
        func settingsCaptureScope(for selection: CaptureSelection) throws -> SettingsCaptureScope? {
            if rejectSettings { throw ScreenshotError.settingsUnavailable }
            return nil
        }
        var environmentAvailable = true
        var environmentValidation: (@MainActor () -> Bool)?
        func validateCaptureEnvironment() -> Bool { environmentValidation?() ?? environmentAvailable }
        var guideCalls = 0
        var hideGuideCalls = 0
        var guideStarted: (@MainActor () -> Void)?
        var guideCancelled: (@MainActor () -> Void)?
        var prepareResult = true
        var hideSelectionResult = true
        var prepareCalls = 0
        var selectionCalls = 0
        var hideSelectionCalls = 0
        var permissionCalls = 0
        var hidePermissionCalls = 0
        var hideProblemCalls = 0
        var dismissCalls = 0
        var rememberCalls = 0
        var returnCalls = 0
        var problemActivations: [Bool] = []
        var feedback: [String] = []
        var selected: (@MainActor (CaptureSelection) -> Void)?
        var cancelled: (@MainActor () -> Void)?

        func showCaptureGuide(started: @escaping @MainActor () -> Void,
                              cancelled: @escaping @MainActor () -> Void) {
            guideCalls += 1
            captureEntryBlocked = true
            guideStarted = started
            guideCancelled = cancelled
        }
        func hideCaptureGuide() { hideGuideCalls += 1; captureEntryBlocked = false }
        func prepareForSelection() -> Bool { prepareCalls += 1; return prepareResult }
        func showSelection(on display: CaptureDisplaySnapshot,
                           selected: @escaping @MainActor (CaptureSelection) -> Void,
                           cancelled: @escaping @MainActor () -> Void) {
            selectionCalls += 1
            self.selected = selected
            self.cancelled = cancelled
        }
        func hideSelection() -> Bool { hideSelectionCalls += 1; return hideSelectionResult }
        func showPermission() { permissionCalls += 1 }
        func hidePermission() { hidePermissionCalls += 1 }
        func showProblem(activate: Bool) { problemActivations.append(activate) }
        func hideProblem() { hideProblemCalls += 1 }
        func showFeedback(_ message: String) { feedback.append(message) }
        func dismissAll() { dismissCalls += 1; captureEntryBlocked = false }
        func rememberExternalApplication() { rememberCalls += 1 }
        func returnToExternalApplication() { returnCalls += 1 }
    }

    @MainActor
    final class FakeCapturer: ScreenshotCapturing {
        enum Mode { case immediate, failure, paused }
        var mode = Mode.immediate
        let asset: M0ImageAsset
        var calls = 0
        var pending: CheckedContinuation<M0ImageAsset, any Error>?
        var lastSelection: CaptureSelection?
        var lastBudget: CaptureImageBudgetContext?

        init(asset: M0ImageAsset) { self.asset = asset }

        func capture(_ request: SingleCaptureRequest,
                     isCurrent: @escaping @MainActor () -> Bool) async throws -> M0ImageAsset {
            calls += 1
            lastSelection = request.selection
            lastBudget = request.budget
            switch mode {
            case .immediate: return asset
            case .failure: throw ScreenshotError.captureFailed
            case .paused:
                // Deliberately ignores cancellation/currentness to simulate a late framework callback.
                return try await withCheckedThrowingContinuation { pending = $0 }
            }
        }

        func release() throws {
            guard let pending else { throw Failure(description: "No paused capture to release") }
            self.pending = nil
            pending.resume(returning: asset)
        }
    }

    actor FakeEncoder {
        enum EncodeFailure: Error { case injected }
        private(set) var calls = 0
        private var failuresRemaining: Int
        private let paused: Bool
        private let pngByteCount: Int?
        private var pending: CheckedContinuation<Void, Never>?

        init(failures: Int = 0, paused: Bool = false, pngByteCount: Int? = nil) {
            failuresRemaining = failures
            self.paused = paused
            self.pngByteCount = pngByteCount
        }

        var isWaiting: Bool { pending != nil }

        func encode(_ asset: M0ImageAsset) async throws -> M0CompositionResult {
            calls += 1
            if paused && calls == 1 {
                // Deliberately finishes after cancellation; the coordinator must reject its result.
                await withCheckedContinuation { pending = $0 }
            }
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                throw EncodeFailure.injected
            }
            let result = try M0ImageComposer.compose(assets: [asset])
            guard let pngByteCount else { return result }
            // Fabricated bytes test actual encoded-size admission without allocating large images.
            return M0CompositionResult(image: result.image, pngData: Data(repeating: 0, count: pngByteCount),
                                       plan: result.plan, actualImageBytes: result.actualImageBytes)
        }

        func release() throws {
            guard let pending else { throw Failure(description: "No paused encoder to release") }
            self.pending = nil
            pending.resume()
        }
    }

    @MainActor
    final class Harness {
        let display: CaptureDisplaySnapshot
        let selection: CaptureSelection
        let interface: FakeInterface
        let clipboard: FakeClipboard
        let permissions: PermissionBox
        let capturer: FakeCapturer
        let encoder: FakeEncoder
        let preferences: CapturePreferences
        let coordinator: SingleCaptureCoordinator

        init(encoderFailures: Int = 0, pauseEncoder: Bool = false,
             guideSeen: Bool = true, pasteHintSeen: Bool = false,
             limits: M0ImageLimits = .init(), pngByteCount: Int? = nil) throws {
            let display = try CaptureDisplaySnapshot(id: 41, frame: CGRect(x: -1_000, y: 0, width: 1_000, height: 800), scale: 2)
            let selection = try CaptureSelection(display: display, rect: CGRect(x: -990, y: 20, width: 8, height: 8))
            let interface = FakeInterface()
            let clipboard = FakeClipboard()
            let permissions = PermissionBox()
            let capturer = FakeCapturer(asset: try M0ImageFixture.make(index: 1, width: 16, height: 16, scale: 2))
            let encoder = FakeEncoder(failures: encoderFailures, paused: pauseEncoder, pngByteCount: pngByteCount)
            let preferences = CapturePreferences(defaults: nil, hasSeenCaptureGuide: guideSeen,
                                                 hasSeenPasteHint: pasteHintSeen)
            let coordinator = SingleCaptureCoordinator(capturer: capturer, interface: interface, clipboard: clipboard,
                permissionCheck: { permissions.allowed },
                permissionRequest: {
                    permissions.requestCalls += 1
                    if permissions.requestGrants { permissions.allowed = true }
                    return permissions.allowed
                },
                protectedDataCheck: { permissions.protectedData },
                displayAtPointer: { display },
                preferences: preferences,
                limits: limits,
                encode: { asset in try await encoder.encode(asset) })
            self.display = display
            self.selection = selection
            self.interface = interface
            self.clipboard = clipboard
            self.permissions = permissions
            self.capturer = capturer
            self.encoder = encoder
            self.preferences = preferences
            self.coordinator = coordinator
        }

        func beginAndSelect() throws {
            coordinator.begin()
            guard let selected = interface.selected else { throw Failure(description: "Selection interface not presented") }
            selected(selection)
        }
    }

    @MainActor
    static func testNormal() async throws {
        let h = try Harness()
        try h.beginAndSelect()
        await h.coordinator.waitForWorker()
        try expect(h.clipboard.calls == 1 && h.clipboard.successfulWrites == 1, "Normal path must write exactly once")
        try expect(h.clipboard.expectedCounts == [7] && !h.clipboard.writtenData[0].isEmpty, "Confirmation count/PNG missing")
        try expect(h.coordinator.phase == .idle && !h.coordinator.isWorking && !h.coordinator.hasRetainedImage,
                   "Successful operation kept retained image or worker")
        try expect(h.coordinator.problem == nil && h.interface.feedback.count == 1 && h.interface.returnCalls == 1,
                   "Success feedback/focus mismatch")
        h.coordinator.retryCopy()
        await Task.yield()
        try expect(h.clipboard.calls == 1, "Released image remained available for another write")
    }

    static func smallImageLimits(extraBytes: Int = 0) throws -> M0ImageLimits {
        let metrics = M0ImageMetrics(width: 16, height: 16, bytesPerRow: 64, scale: 2)
        let baseline = try CaptureImageBudgetContext().validateCandidate(metrics)
        var limits = M0ImageLimits()
        limits.maximumImageBytes = baseline.estimatedPeakBytes + extraBytes
        return limits
    }

    @MainActor
    static func testExternalPreparation() async throws {
        let h = try Harness()
        var preparationCalls = 0
        h.coordinator.prepareExternalCapture = { preparationCalls += 1; return false }
        h.coordinator.begin()
        try expect(preparationCalls == 1 && h.coordinator.phase == .idle && h.interface.selectionCalls == 0
                   && h.interface.rememberCalls == 0 && h.capturer.calls == 0 && h.clipboard.calls == 0,
                   "Blocked collection preparation changed focus, selected or wrote")
        h.coordinator.prepareExternalCapture = { true }
        h.clipboard.mode = .rejected
        try h.beginAndSelect()
        await h.coordinator.waitForWorker()
        h.coordinator.prepareExternalCapture = { preparationCalls += 1; return false }
        h.coordinator.begin()
        try expect(h.coordinator.hasRetainedImage && preparationCalls == 1 && h.capturer.calls == 1,
                   "Existing single image was discarded or collection caches touched during begin")
        h.coordinator.discard()
    }

    @MainActor
    static func testExternalAcquisitionBudget() async throws {
        let limits = try smallImageLimits(extraBytes: 10_000)
        let h = try Harness(limits: limits)
        var externalBytes = 10_001
        h.coordinator.externalRetainedBytes = { externalBytes }
        try h.beginAndSelect()
        try expect(h.capturer.calls == 0 && !h.coordinator.hasRetainedImage && h.clipboard.calls == 0
                   && h.coordinator.problem?.message.contains("小さい範囲") == true,
                   "Over-budget selection reached capture or lost its recovery guidance")
        externalBytes = 10_000
        try h.beginAndSelect()
        await h.coordinator.waitForWorker()
        try expect(h.capturer.lastBudget?.retainingExtraBytes == externalBytes
                   && h.capturer.lastBudget?.existing.isEmpty == true && h.clipboard.successfulWrites == 1,
                   "Single acquisition omitted retained collection bytes or treated them as single sources")

        for invalidBytes in [-1, Int.max] {
            let invalid = try Harness(limits: limits)
            invalid.coordinator.externalRetainedBytes = { invalidBytes }
            try invalid.beginAndSelect()
            try expect(invalid.capturer.calls == 0 && invalid.clipboard.calls == 0
                       && invalid.coordinator.phase == .failure, "Invalid external bytes reached acquisition")
        }
    }

    @MainActor
    static func testExternalAdoptionBudget() async throws {
        let limits = try smallImageLimits()
        let h = try Harness(limits: limits)
        var externalBytes = 0
        h.coordinator.externalRetainedBytes = { externalBytes }
        h.capturer.mode = .paused
        try h.beginAndSelect()
        try await waitUntil { h.capturer.pending != nil }
        externalBytes = limits.maximumImageBytes
        try h.capturer.release()
        await h.coordinator.waitForWorker()
        let encodeCalls = await h.encoder.calls
        try expect(!h.coordinator.hasRetainedImage && encodeCalls == 0 && h.clipboard.calls == 0
                   && h.coordinator.problem?.stage == .capture && externalBytes == limits.maximumImageBytes,
                   "Late image bypassed fresh external retention or changed the collection's retention")
    }

    @MainActor
    static func testExternalEncodingBudget() async throws {
        let limits = try smallImageLimits()
        let h = try Harness(pauseEncoder: true, limits: limits)
        let externalBudget = RetainedImageBudgetBox()
        h.coordinator.externalRetainedBytes = { externalBudget.bytes }
        try h.beginAndSelect()
        try await waitUntil { await h.encoder.isWaiting }
        externalBudget.bytes = limits.maximumImageBytes
        try await h.encoder.release()
        await h.coordinator.waitForWorker()
        try expect(h.coordinator.hasRetainedImage && h.clipboard.calls == 0
                   && h.coordinator.problem?.stage == .encoding,
                   "External budget growth adopted or wrote encoded PNG, or discarded the acquired source")
        #if DEBUG
        try expect(!h.coordinator.hasRetainedPNG, "Rejected encoding cached its PNG")
        #endif
        externalBudget.bytes = 0
        h.coordinator.retryCopy()
        await h.coordinator.waitForWorker()
        let encodeCalls = await h.encoder.calls
        try expect(h.clipboard.successfulWrites == 1 && encodeCalls == 2 && h.capturer.calls == 1,
                   "Retained image could not recover without recapture after budget became available")
    }

    @MainActor
    static func testExternalCachedBudget() async throws {
        let limits = try smallImageLimits()
        let h = try Harness(limits: limits)
        let externalBudget = RetainedImageBudgetBox()
        h.coordinator.externalRetainedBytes = { externalBudget.bytes }
        h.clipboard.mode = .rejected
        try h.beginAndSelect()
        await h.coordinator.waitForWorker()
        externalBudget.bytes = limits.maximumImageBytes
        h.coordinator.retryCopy()
        await h.coordinator.waitForWorker()
        try expect(h.coordinator.hasRetainedImage && h.clipboard.calls == 1,
                   "Over-budget cached retry wrote or discarded its source")
        #if DEBUG
        try expect(h.coordinator.hasRetainedPNG, "Over-budget cached retry discarded its existing PNG")
        #endif
        externalBudget.bytes = 0
        h.clipboard.mode = .accepted
        h.coordinator.retryCopy()
        await h.coordinator.waitForWorker()
        let encodeCalls = await h.encoder.calls
        try expect(h.clipboard.successfulWrites == 1 && encodeCalls == 1 && h.capturer.calls == 1,
                   "Cached retry unnecessarily recaptured/re-encoded after capacity returned")
    }

    @MainActor
    static func testActualEncodedBudget() async throws {
        let h = try Harness(limits: smallImageLimits(), pngByteCount: 80_000)
        try h.beginAndSelect()
        await h.coordinator.waitForWorker()
        try expect(h.coordinator.hasRetainedImage && h.clipboard.calls == 0
                   && h.coordinator.problem?.stage == .encoding,
                   "Actual PNG byte count bypassed final resource validation")
        #if DEBUG
        try expect(!h.coordinator.hasRetainedPNG, "Oversized PNG became a retry cache")
        #endif
        h.coordinator.discard()
    }

    @MainActor
    static func testPermissionRefresh() async throws {
        let h = try Harness()
        h.permissions.allowed = false
        h.coordinator.begin()
        h.permissions.allowed = true
        h.coordinator.refreshPermissionStatus()
        try expect(h.coordinator.phase == .permission && h.coordinator.permissionStatus == .granted
                   && h.interface.selectionCalls == 0 && h.permissions.requestCalls == 0,
                   "Activation refresh requested OS permission or started a selection")
        h.coordinator.retryPermission()
        try expect(h.interface.selectionCalls == 1, "Explicit retry after activation refresh did not select")
        h.coordinator.cancel()
        h.permissions.allowed = false
        h.coordinator.refreshPermissionStatus()
        try expect(h.coordinator.permissionStatus == .granted && h.permissions.requestCalls == 0,
                   "Inactive permission flow was changed by a background refresh")
    }

    @MainActor
    static func testPermission() async throws {
        let h = try Harness()
        h.permissions.allowed = false
        h.coordinator.begin()
        try expect(h.coordinator.phase == .permission && h.interface.permissionCalls == 1, "Missing permission interface")
        try expect(h.permissions.requestCalls == 0 && h.interface.selectionCalls == 0, "Begin requested permission or selected automatically")
        h.coordinator.retryPermission()
        try expect(h.interface.selectionCalls == 0, "Denied retry started selection")
        h.permissions.allowed = true
        await Task.yield()
        try expect(h.coordinator.phase == .permission && h.interface.selectionCalls == 0, "Permission change auto-restarted")
        h.coordinator.requestPermission()
        try expect(h.permissions.requestCalls == 1 && h.interface.selectionCalls == 0, "Explicit OS request auto-selected")
        h.coordinator.retryPermission()
        try expect(h.coordinator.phase == .selecting && h.interface.selectionCalls == 1 && h.interface.hidePermissionCalls == 1,
                   "Explicit permission retry did not enter selection")
        h.coordinator.cancel()
        h.coordinator.requestPermission()
        try expect(h.permissions.requestCalls == 1 && h.capturer.calls == 0 && h.clipboard.calls == 0,
                   "Permission request escaped its explicit phase")

        let reset = try Harness()
        reset.permissions.allowed = false
        reset.coordinator.begin()
        let neutralMessage = reset.coordinator.permissionMessage
        reset.permissions.requestGrants = true
        reset.coordinator.requestPermission()
        try expect(reset.permissions.allowed && reset.coordinator.permissionMessage != neutralMessage,
                   "Explicit grant did not update permission guidance")
        reset.coordinator.cancel()
        reset.permissions.allowed = false
        reset.permissions.requestGrants = false
        reset.coordinator.begin()
        try expect(reset.coordinator.phase == .permission && reset.coordinator.permissionStatus == .noLongerAvailable
                   && !reset.coordinator.permissionMessage.contains("許可を確認できました"),
                   "A revoked permission retained stale success guidance")
        try expect(reset.permissions.requestCalls == 1 && reset.interface.selectionCalls == 0,
                   "Reset permission guidance requested or resumed automatically")
        reset.coordinator.cancel()
    }

    @MainActor
    static func testSelectionCancellation() async throws {
        let h = try Harness()
        h.coordinator.begin()
        guard let selected = h.interface.selected, let cancelled = h.interface.cancelled else {
            throw Failure(description: "Selection callbacks missing")
        }
        cancelled()
        selected(h.selection)
        await Task.yield()
        try expect(h.coordinator.phase == .idle && h.coordinator.canBegin, "Esc did not return to idle")
        try expect(h.capturer.calls == 0 && h.clipboard.calls == 0 && h.interface.feedback.isEmpty,
                   "Esc/stale callback captured or wrote")
    }

    @MainActor
    static func testLateCaptureCancellation() async throws {
        let h = try Harness()
        h.capturer.mode = .paused
        try h.beginAndSelect()
        try await waitUntil { h.capturer.pending != nil }
        h.coordinator.cancel()
        try expect(h.coordinator.phase == .cancelling && h.coordinator.isWorking && !h.coordinator.canBegin,
                   "Cancelled capture released worker prematurely")
        h.coordinator.begin()
        h.coordinator.retryCopy()
        try expect(h.interface.selectionCalls == 1 && h.capturer.calls == 1, "Reentered while late capture pending")
        try h.capturer.release()
        await h.coordinator.waitForWorker()
        try expect(h.clipboard.calls == 0 && h.interface.feedback.isEmpty && !h.coordinator.hasRetainedImage,
                   "Late capture was adopted")
        try expect(!h.coordinator.isWorking && h.coordinator.phase == .idle && h.coordinator.canBegin,
                   "Worker did not become reusable after real completion")
    }

    @MainActor
    static func testLateEncodeCancellation() async throws {
        let h = try Harness(pauseEncoder: true)
        try h.beginAndSelect()
        try await waitUntil { await h.encoder.isWaiting }
        try expect(h.coordinator.hasRetainedImage, "Encoder did not retain acquired image")
        h.coordinator.cancel()
        try expect(h.coordinator.phase == .cancelling && h.coordinator.isWorking && !h.coordinator.hasRetainedImage,
                   "Cancel must clear UI retention and keep worker occupied")
        h.coordinator.begin()
        try expect(h.interface.selectionCalls == 1, "Reentered while encoder pending")
        try await h.encoder.release()
        await h.coordinator.waitForWorker()
        try expect(h.clipboard.calls == 0 && h.interface.feedback.isEmpty && h.coordinator.phase == .idle,
                   "Late PNG reached writer")
    }

    @MainActor
    static func testDuplicates() async throws {
        let h = try Harness()
        h.capturer.mode = .paused
        h.coordinator.begin()
        h.coordinator.begin()
        try expect(h.interface.selectionCalls == 1, "Duplicate begin presented multiple selectors")
        guard let selected = h.interface.selected else { throw Failure(description: "No selection callback") }
        selected(h.selection)
        selected(h.selection)
        try await waitUntil { h.capturer.pending != nil }
        h.coordinator.begin()
        try expect(h.capturer.calls == 1 && h.interface.selectionCalls == 1, "Duplicate confirmation started workers")
        try h.capturer.release()
        await h.coordinator.waitForWorker()
        try expect(h.clipboard.calls == 1 && h.clipboard.successfulWrites == 1, "Duplicate operation wrote more than once")
    }

    @MainActor
    static func testCaptureFailure() async throws {
        let h = try Harness()
        h.capturer.mode = .failure
        try h.beginAndSelect()
        await h.coordinator.waitForWorker()
        try expect(h.coordinator.phase == .failure && !h.coordinator.hasRetainedImage && h.coordinator.problem != nil,
                   "Capture failure must have no retry-copy image")
        try expect(h.clipboard.calls == 0 && h.interface.feedback.isEmpty, "Capture failure reported success")
        h.capturer.mode = .immediate
        h.coordinator.retrySelection()
        try expect(h.interface.selectionCalls == 2 && h.coordinator.phase == .selecting, "Retry selection did not reopen")
        h.interface.selected?(h.selection)
        await h.coordinator.waitForWorker()
        try expect(h.capturer.calls == 2 && h.clipboard.successfulWrites == 1, "Capture retry did not complete")
    }

    @MainActor
    static func testSettingsBoundary() async throws {
        let h = try Harness()
        h.interface.rejectSettings = true
        try h.beginAndSelect()
        await h.coordinator.waitForWorker()
        try expect(h.capturer.calls == 0 && h.clipboard.calls == 0 && !h.coordinator.hasRetainedImage,
                   "Changed settings window reached capture or clipboard")
        try expect(h.coordinator.phase == .failure && h.coordinator.problem?.message.contains("設定画面") == true,
                   "Changed settings did not explain why selection stopped")
        h.interface.rejectSettings = false
        h.coordinator.retrySelection()
        h.interface.selected?(h.selection)
        await h.coordinator.waitForWorker()
        try expect(h.capturer.calls == 1 && h.clipboard.successfulWrites == 1,
                   "A fresh explicit selection could not recover after settings changed")
    }

    @MainActor
    static func testSettingsOrigin() async throws {
        let h = try Harness(guideSeen: false)
        h.coordinator.begin()
        try expect(h.interface.rememberCalls == 1, "Entry did not remember its origin")
        h.interface.guideStarted?()
        try expect(h.interface.rememberCalls == 1 && h.coordinator.phase == .selecting,
                   "Guide dismissal replaced origin with its newly key underlying window")
        h.interface.rejectSettings = true
        h.interface.selected?(h.selection)
        h.interface.rejectSettings = false
        h.coordinator.retrySelection()
        try expect(h.interface.rememberCalls == 1, "Retry replaced the task origin")
        h.coordinator.cancel()
        h.permissions.allowed = false
        h.coordinator.begin()
        try expect(h.interface.rememberCalls == 2 && h.coordinator.phase == .permission,
                   "New entry failed to refresh origin")
        h.permissions.allowed = true
        h.coordinator.retryPermission()
        try expect(h.interface.rememberCalls == 2 && h.coordinator.phase == .selecting,
                   "Permission retry replaced origin after hiding its window")
        h.coordinator.cancel()
    }

    @MainActor
    static func testEncodeFailure() async throws {
        let h = try Harness(encoderFailures: 1)
        try h.beginAndSelect()
        await h.coordinator.waitForWorker()
        try expect(h.coordinator.phase == .failure && h.coordinator.hasRetainedImage && h.clipboard.calls == 0,
                   "Encode failure lost acquired image or wrote")
        h.coordinator.retrySelection()
        try expect(h.interface.selectionCalls == 1, "Retained image retry unexpectedly selected again")
        h.coordinator.retryCopy()
        await h.coordinator.waitForWorker()
        let encodeCalls = await h.encoder.calls
        try expect(h.capturer.calls == 1 && encodeCalls == 2 && h.clipboard.successfulWrites == 1,
                   "Encode retry recaptured or failed to reencode")
        try expect(!h.coordinator.hasRetainedImage && h.coordinator.phase == .idle, "Encode retry retained successful image")
    }

    @MainActor
    static func testWriteFailure() async throws {
        let h = try Harness()
        h.clipboard.mode = .rejected
        try h.beginAndSelect()
        await h.coordinator.waitForWorker()
        try expect(h.coordinator.phase == .failure && h.coordinator.hasRetainedImage,
                   "Rejected write did not retain image")
        try expect(h.coordinator.problem?.clipboardMayHaveChanged == true && h.interface.feedback.isEmpty,
                   "Post-prepare failure uncertainty/success mismatch")
        h.coordinator.prepareToQuit()
        try expect(h.coordinator.phase == .failure && h.coordinator.hasRetainedImage,
                   "Quit preparation discarded an acquired image/PNG")
        h.clipboard.mode = .accepted
        h.coordinator.retryCopy()
        await h.coordinator.waitForWorker()
        let encodeCalls = await h.encoder.calls
        try expect(h.capturer.calls == 1 && encodeCalls == 1, "Write retry recaptured or regenerated cached PNG")
        try expect(h.clipboard.expectedCounts == [7, 8] && h.clipboard.calls == 2 && h.clipboard.successfulWrites == 1,
                   "Retry must use a fresh explicit change count")
        try expect(!h.coordinator.hasRetainedImage && h.coordinator.problem == nil, "Successful retry retained failure state")
    }

    @MainActor
    static func testDiscard() async throws {
        let h = try Harness()
        h.clipboard.mode = .rejected
        try h.beginAndSelect()
        await h.coordinator.waitForWorker()
        h.coordinator.begin()
        try expect(h.interface.selectionCalls == 1 && h.interface.problemActivations.last == true,
                   "Begin overwrote an un-copied image")
        h.coordinator.discard()
        try expect(h.coordinator.phase == .idle && !h.coordinator.hasRetainedImage && h.coordinator.problem == nil,
                   "Discard kept retained failure image")
        h.coordinator.retryCopy()
        await Task.yield()
        try expect(h.clipboard.calls == 1 && h.interface.feedback.isEmpty, "Discarded image was written")
    }

    @MainActor
    static func testCountConflict() async throws {
        let h = try Harness(pauseEncoder: true)
        try h.beginAndSelect()
        try await waitUntil { await h.encoder.isWaiting }
        h.clipboard.count += 1
        try await h.encoder.release()
        await h.coordinator.waitForWorker()
        try expect(h.clipboard.expectedCounts == [7] && h.clipboard.calls == 1 && h.clipboard.successfulWrites == 0,
                   "Confirmation count was silently refreshed before write")
        try expect(h.coordinator.phase == .failure && h.coordinator.hasRetainedImage,
                   "Conflict did not retain failed image")
        try expect(h.coordinator.problem?.clipboardMayHaveChanged == false && h.interface.feedback.isEmpty,
                   "Before-prepare conflict reported success or preparation")
        h.coordinator.discard()
    }

    @MainActor
    static func testPermissionRevocation() async throws {
        let h = try Harness()
        h.capturer.mode = .paused
        try h.beginAndSelect()
        try await waitUntil { h.capturer.pending != nil }
        h.permissions.allowed = false
        try h.capturer.release()
        await h.coordinator.waitForWorker()
        let encodeCalls = await h.encoder.calls
        try expect(h.clipboard.calls == 0 && encodeCalls == 0 && !h.coordinator.hasRetainedImage,
                   "Revoked permission adopted late capture")
        try expect(h.permissions.requestCalls == 0 && h.interface.feedback.isEmpty && h.coordinator.phase == .idle,
                   "Revocation requested permission or reported success")
    }

    @MainActor
    static func testProtectedDataRevocation() async throws {
        let h = try Harness(pauseEncoder: true)
        try h.beginAndSelect()
        try await waitUntil { await h.encoder.isWaiting }
        h.permissions.protectedData = false
        try await h.encoder.release()
        await h.coordinator.waitForWorker()
        try expect(h.clipboard.calls == 0 && !h.coordinator.hasRetainedImage && h.interface.feedback.isEmpty,
                   "Protected-data revocation allowed a late write")
        try expect(h.coordinator.phase == .idle && !h.coordinator.isWorking, "Revocation stranded worker state")
    }

    @MainActor
    static func testInvalidSelectionBoundary() async throws {
        let hiddenFailure = try Harness()
        hiddenFailure.interface.hideSelectionResult = false
        try hiddenFailure.beginAndSelect()
        await Task.yield()
        try expect(hiddenFailure.capturer.calls == 0 && hiddenFailure.clipboard.calls == 0 && hiddenFailure.coordinator.phase == .failure,
                   "Capture started while overlay hiding failed")
        let mismatch = try Harness()
        mismatch.coordinator.begin()
        let other = try CaptureDisplaySnapshot(id: mismatch.display.id + 1, frame: mismatch.display.frame, scale: mismatch.display.scale)
        let selection = try CaptureSelection(display: other, rect: mismatch.selection.rect)
        mismatch.interface.selected?(selection)
        await Task.yield()
        try expect(mismatch.capturer.calls == 0 && mismatch.clipboard.calls == 0 && mismatch.coordinator.phase == .selecting,
                   "Wrong-display selection reached capture")
        mismatch.coordinator.cancel()
    }

    @MainActor
    static func testInactiveFocus() async throws {
        let h = try Harness()
        h.interface.isOneClipActive = false
        try h.beginAndSelect()
        await h.coordinator.waitForWorker()
        try expect(h.clipboard.successfulWrites == 1 && h.interface.feedback.count == 1 && h.interface.returnCalls == 0,
                   "Successful async result took external focus")
        let failed = try Harness()
        failed.interface.isOneClipActive = false
        failed.capturer.mode = .failure
        try failed.beginAndSelect()
        await failed.coordinator.waitForWorker()
        try expect(failed.interface.problemActivations == [false] && failed.interface.returnCalls == 0,
                   "Failure activated/returned focus while another app was active")
        failed.coordinator.discard()
        try expect(failed.interface.returnCalls == 0, "Inactive discard took external focus")
    }

    @MainActor
    static func testQuitPreparation() async throws {
        let acquired = try Harness(pauseEncoder: true)
        try acquired.beginAndSelect()
        try await waitUntil { await acquired.encoder.isWaiting }
        acquired.coordinator.prepareToQuit()
        try expect(acquired.coordinator.phase == .failure && acquired.coordinator.hasRetainedImage && acquired.coordinator.isWorking,
                   "Quit preparation must preserve acquired image and freeze adoption")
        acquired.coordinator.retryCopy()
        acquired.coordinator.begin()
        try expect(acquired.interface.selectionCalls == 1 && acquired.clipboard.calls == 0,
                   "Quit preparation allowed reentry while old encoder was pending")
        try await acquired.encoder.release()
        await acquired.coordinator.waitForWorker()
        try expect(acquired.clipboard.calls == 0 && acquired.interface.feedback.isEmpty && acquired.coordinator.hasRetainedImage,
                   "Late encoder wrote or discarded the image during quit confirmation")
        try expect(acquired.coordinator.phase == .failure && !acquired.coordinator.isWorking,
                   "Frozen worker failed to settle into retained-image failure")
        // The user cancelled the app's quit confirmation and explicitly chose to retry copying.
        acquired.coordinator.retryCopy()
        await acquired.coordinator.waitForWorker()
        let encodeCalls = await acquired.encoder.calls
        try expect(acquired.capturer.calls == 1 && encodeCalls == 2 && acquired.clipboard.successfulWrites == 1,
                   "Cancelled quit did not permit an explicit retry without recapture")
        try expect(!acquired.coordinator.hasRetainedImage && acquired.coordinator.phase == .idle,
                   "Explicit retry after cancelled quit did not release successful image")

        let pending = try Harness()
        pending.capturer.mode = .paused
        try pending.beginAndSelect()
        try await waitUntil { pending.capturer.pending != nil }
        pending.coordinator.prepareToQuit()
        try expect(!pending.coordinator.hasRetainedImage && pending.coordinator.isWorking && !pending.coordinator.canBegin,
                   "Quit before acquisition created an image or released worker early")
        try pending.capturer.release()
        await pending.coordinator.waitForWorker()
        try expect(pending.clipboard.calls == 0 && !pending.coordinator.hasRetainedImage && pending.interface.feedback.isEmpty,
                   "Late acquisition after quit preparation was adopted")
        try expect(pending.coordinator.phase == .idle && !pending.coordinator.isWorking,
                   "No-image quit preparation stranded its worker")
    }

    @MainActor
    static func testFirstGuide() async throws {
        let h = try Harness(guideSeen: false)
        try expect(h.coordinator.phase == .idle && h.interface.guideCalls == 0 && h.permissions.requestCalls == 0,
                   "Initialization showed guidance or requested OS permission")
        h.coordinator.begin()
        try expect(h.coordinator.phase == .onboarding && h.interface.guideCalls == 1 && !h.coordinator.canBegin,
                   "First explicit begin did not show the guide")
        try expect(!h.preferences.hasSeenCaptureGuide && h.interface.selectionCalls == 0 && h.permissions.requestCalls == 0,
                   "Showing the guide acknowledged it or began capture")
        let oldStart = h.interface.guideStarted
        h.coordinator.begin()
        try expect(h.interface.guideCalls == 1, "Duplicate begin repeated the guide")
        h.interface.guideCancelled?()
        oldStart?()
        try expect(!h.preferences.hasSeenCaptureGuide && h.interface.selectionCalls == 0 && h.coordinator.phase == .idle,
                   "Cancelled/stale guide began capture or marked it read")
        h.coordinator.begin()
        h.interface.guideStarted?()
        try expect(h.preferences.hasSeenCaptureGuide && h.coordinator.phase == .selecting && h.interface.selectionCalls == 1,
                   "Acknowledged guide did not enter explicit selection")
        h.coordinator.cancel()
        h.coordinator.begin()
        try expect(h.interface.guideCalls == 2 && h.interface.selectionCalls == 2,
                   "Repeat capture added another guide")
        h.coordinator.cancel()
        let quitting = try Harness(guideSeen: false)
        quitting.coordinator.begin()
        let quitStart = quitting.interface.guideStarted
        quitting.coordinator.prepareToQuit()
        quitStart?()
        try expect(!quitting.preferences.hasSeenCaptureGuide && quitting.interface.selectionCalls == 0,
                   "A late guide callback after quit preparation started capture")
    }

    @MainActor
    static func testPreferences() async throws {
        let memory = CapturePreferences(defaults: nil)
        try expect(!memory.hasSeenWelcome && !memory.hasSeenCaptureGuide && !memory.hasSeenCollectionGuide,
                   "A new memory preference store skipped welcome or a mode guide")
        memory.hasSeenCaptureGuide = true
        let other = CapturePreferences(defaults: nil)
        try expect(memory.hasSeenCaptureGuide && !memory.hasSeenCollectionGuide && !memory.hasSeenPasteHint && !other.hasSeenCaptureGuide,
                   "Memory preferences leaked between instances or acknowledged another guide early")
        try expect(memory.hasSeenWelcome && !other.hasSeenWelcome
                   && CapturePreferences(defaults: nil, hasSeenCollectionGuide: true).hasSeenWelcome
                   && !CapturePreferences(defaults: nil, hasSeenPasteHint: true).hasSeenWelcome,
                   "Welcome migration did not recognize either legacy mode guide independently")
        memory.hasSeenCollectionGuide = true
        try expect(memory.hasSeenCollectionGuide && !other.hasSeenCollectionGuide,
                   "Collection guide acknowledgement leaked between memory stores")
        let suiteName = "OneClip.CoordinatorTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw Failure(description: "Could not create an isolated preferences suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = CapturePreferences(defaults: defaults)
        first.hasSeenCaptureGuide = true
        first.hasSeenPasteHint = true
        let restored = CapturePreferences(defaults: defaults)
        try expect(restored.hasSeenCaptureGuide && restored.hasSeenPasteHint && !restored.hasSeenCollectionGuide,
                   "Stored single acknowledgements were not restored independently of collection")
        restored.hasSeenCollectionGuide = true
        try expect(CapturePreferences(defaults: defaults).hasSeenCollectionGuide,
                   "Collection guide acknowledgement was not restored")
        let domain = defaults.persistentDomain(forName: suiteName) ?? [:]
        try expect(domain.count == 3 && domain.values.allSatisfy { $0 is Bool },
                   "Preferences stored values other than the three acknowledgement flags")
        defaults.removePersistentDomain(forName: suiteName)
        let welcome = CapturePreferences(defaults: defaults)
        welcome.hasSeenWelcome = true
        let restoredWelcome = CapturePreferences(defaults: defaults)
        try expect(restoredWelcome.hasSeenWelcome && !restoredWelcome.hasSeenCaptureGuide
                   && !restoredWelcome.hasSeenCollectionGuide && !restoredWelcome.hasSeenPasteHint,
                   "Stored welcome acknowledgement marked a mode guide or paste hint seen")
        let welcomeDomain = defaults.persistentDomain(forName: suiteName) ?? [:]
        try expect(welcomeDomain.count == 1 && welcomeDomain["OneClip.hasSeenWelcome"] as? Bool == true,
                   "Explicit welcome acknowledgement persisted unexpected preference keys")
    }

    @MainActor
    static func testBlockedEntries() async throws {
        let idle = try Harness()
        idle.interface.captureEntryBlocked = true
        idle.coordinator.begin()
        idle.coordinator.retrySelection()
        try expect(!idle.coordinator.canBegin && idle.interface.selectionCalls == 0,
                   "Settings/sheet allowed a new capture")
        idle.interface.captureEntryBlocked = false
        idle.coordinator.begin()
        idle.interface.captureEntryBlocked = true
        idle.interface.selected?(idle.selection)
        try expect(idle.capturer.calls == 0 && idle.clipboard.calls == 0,
                   "Blocked selector confirmation started a worker")
        idle.coordinator.cancel()

        let noImage = try Harness()
        noImage.capturer.mode = .failure
        try noImage.beginAndSelect()
        await noImage.coordinator.waitForWorker()
        noImage.interface.captureEntryBlocked = true
        noImage.coordinator.retrySelection()
        try expect(noImage.interface.selectionCalls == 1 && noImage.coordinator.problem != nil,
                   "Blocked retry selected or cleared the error")

        let retained = try Harness()
        retained.clipboard.mode = .rejected
        try retained.beginAndSelect()
        await retained.coordinator.waitForWorker()
        retained.interface.captureEntryBlocked = true
        retained.coordinator.retryCopy()
        retained.coordinator.begin()
        try expect(retained.clipboard.calls == 1 && retained.coordinator.hasRetainedImage,
                   "Discard confirmation allowed a background copy/start")
        retained.interface.captureEntryBlocked = false
        retained.clipboard.mode = .accepted
        retained.coordinator.retryCopy()
        await retained.coordinator.waitForWorker()
        try expect(retained.clipboard.successfulWrites == 1 && retained.capturer.calls == 1,
                   "Closing the blocking UI did not allow explicit retained-image retry")
    }

    @MainActor
    static func testUnconfirmedPermission() async throws {
        let h = try Harness()
        h.permissions.allowed = false
        h.coordinator.begin()
        try expect(h.coordinator.permissionStatus == .notConfirmed && h.permissions.requestCalls == 0,
                   "First unavailable check claimed denial or requested automatically")
        h.coordinator.requestPermission()
        try expect(h.coordinator.permissionStatus == .requestUnconfirmed && h.permissions.requestCalls == 1,
                   "Unconfirmed explicit request was not distinguished")
        h.interface.captureEntryBlocked = true
        h.coordinator.requestPermission()
        h.permissions.allowed = true
        h.coordinator.retryPermission()
        try expect(h.permissions.requestCalls == 1 && h.interface.selectionCalls == 0,
                   "Blocked permission controls requested/resumed behind another window")
        h.interface.captureEntryBlocked = false
        await Task.yield()
        try expect(h.interface.selectionCalls == 0 && h.coordinator.phase == .permission,
                   "A permission change or closing settings auto-resumed")
        h.coordinator.retryPermission()
        try expect(h.interface.selectionCalls == 1 && h.coordinator.permissionStatus == .granted,
                   "Explicit retry did not observe permission and select")
        h.coordinator.cancel()
    }

    @MainActor
    static func testRevokedPermissionGuidance() async throws {
        let h = try Harness()
        h.coordinator.begin()
        h.coordinator.cancel()
        h.permissions.allowed = false
        h.coordinator.begin()
        try expect(h.coordinator.phase == .permission && h.coordinator.permissionStatus == .noLongerAvailable,
                   "Previously observed permission did not become unavailable")
        try expect(h.coordinator.permissionMessage.contains("以前") && h.permissions.requestCalls == 0,
                   "Revocation omitted recovery guidance or requested automatically")
        h.permissions.allowed = true
        await Task.yield()
        try expect(h.interface.selectionCalls == 1, "Permission restoration auto-resumed capture")
        h.coordinator.retryPermission()
        try expect(h.interface.selectionCalls == 2, "Explicit retry after permission restoration did not resume")
        h.coordinator.cancel()
    }

    @MainActor
    static func testFailureStages() async throws {
        let capture = try Harness()
        capture.capturer.mode = .failure
        try capture.beginAndSelect()
        await capture.coordinator.waitForWorker()
        try expect(capture.coordinator.problem?.stage == .capture && !capture.coordinator.hasRetainedImage,
                   "Acquisition failure stage/retention mismatch")
        let encode = try Harness(encoderFailures: 1)
        try encode.beginAndSelect()
        await encode.coordinator.waitForWorker()
        try expect(encode.coordinator.problem?.stage == .encoding && encode.coordinator.hasRetainedImage,
                   "Encoding failure stage/retention mismatch")
        let write = try Harness()
        write.clipboard.mode = .rejected
        try write.beginAndSelect()
        await write.coordinator.waitForWorker()
        try expect(write.coordinator.problem?.stage == .clipboard && write.coordinator.problem?.clipboardMayHaveChanged == true,
                   "Clipboard failure stage/uncertainty mismatch")
        let previous = write.coordinator.problem
        write.coordinator.prepareToQuit()
        try expect(write.coordinator.problem == previous && write.coordinator.hasRetainedImage,
                   "Quit confirmation overwrote the original failure/clipboard uncertainty")
        capture.coordinator.discard()
        encode.coordinator.discard()
        write.coordinator.discard()
    }

    @MainActor
    static func testDiscardAndStopLateResults() async throws {
        let discarded = try Harness(pauseEncoder: true)
        try discarded.beginAndSelect()
        try await waitUntil { await discarded.encoder.isWaiting }
        discarded.coordinator.prepareToQuit()
        discarded.coordinator.discard() // Still working: a direct reentrant call must do nothing.
        try expect(discarded.coordinator.hasRetainedImage && discarded.coordinator.isWorking,
                   "Reentrant discard released a running worker")
        discarded.coordinator.stop()
        try await discarded.encoder.release()
        await discarded.coordinator.waitForWorker()
        discarded.coordinator.begin()
        try expect(!discarded.coordinator.hasRetainedImage && discarded.clipboard.calls == 0
                   && discarded.interface.feedback.isEmpty && !discarded.coordinator.canBegin,
                   "Stopped late encoder restored/copied an image or reopened entry")
        let capture = try Harness()
        capture.capturer.mode = .paused
        try capture.beginAndSelect()
        try await waitUntil { capture.capturer.pending != nil }
        capture.coordinator.stop()
        try capture.capturer.release()
        await capture.coordinator.waitForWorker()
        try expect(capture.clipboard.calls == 0 && !capture.coordinator.hasRetainedImage && !capture.coordinator.canBegin,
                   "Stopped late acquisition reached writer or reopened entry")
    }

    @MainActor
    static func testFirstPasteHint() async throws {
        let h = try Harness()
        h.clipboard.mode = .rejected
        try h.beginAndSelect()
        await h.coordinator.waitForWorker()
        try expect(!h.preferences.hasSeenPasteHint && h.interface.feedback.isEmpty,
                   "Rejected write marked the paste hint seen")
        h.clipboard.mode = .accepted
        h.coordinator.retryCopy()
        await h.coordinator.waitForWorker()
        try expect(h.preferences.hasSeenPasteHint && h.interface.feedback.last?.contains("Command + V") == true,
                   "First accepted write did not acknowledge/show the paste hint")
        try h.beginAndSelect()
        await h.coordinator.waitForWorker()
        try expect(h.interface.feedback.last == "コピーしました", "Repeat capture repeated first-use paste guidance")
    }

    @MainActor
    static func testExternalSwitchDuringWorker() async throws {
        let success = try Harness(pauseEncoder: true)
        try success.beginAndSelect()
        try await waitUntil { await success.encoder.isWaiting }
        success.interface.isOneClipActive = false
        try await success.encoder.release()
        await success.coordinator.waitForWorker()
        try expect(success.clipboard.successfulWrites == 1 && success.interface.returnCalls == 0,
                   "Switching away during encoding lost external focus on success")

        let failure = try Harness(encoderFailures: 1, pauseEncoder: true)
        try failure.beginAndSelect()
        try await waitUntil { await failure.encoder.isWaiting }
        failure.interface.isOneClipActive = false
        try await failure.encoder.release()
        await failure.coordinator.waitForWorker()
        try expect(failure.coordinator.hasRetainedImage && failure.interface.problemActivations == [false]
                   && failure.interface.returnCalls == 0 && failure.clipboard.calls == 0,
                   "Switching away during encoding lost external focus or the retained image on failure")
        failure.coordinator.discard()
        try expect(failure.interface.returnCalls == 0, "Inactive discard activated an external application")
    }

    @MainActor
    static func testSessionFenceEntry() async throws {
        let h = try Harness(guideSeen: false)
        h.interface.environmentAvailable = false
        h.coordinator.begin()
        try expect(h.interface.guideCalls == 0 && h.interface.selectionCalls == 0
                   && h.permissions.requestCalls == 0 && h.clipboard.calls == 0,
                   "Unmonitored session opened a guide, selection or permission request")
        let retained = try Harness()
        retained.clipboard.mode = .rejected
        try retained.beginAndSelect()
        await retained.coordinator.waitForWorker()
        try expect(retained.coordinator.hasRetainedImage, "Retry precondition missing")
        // A fence can synchronously invalidate while the caller is in its entry method.
        retained.interface.environmentValidation = {
            retained.coordinator.environmentDidChange(.consoleSessionChanged)
            return false
        }
        retained.coordinator.retryCopy()
        retained.coordinator.showCurrentProblem()
        try expect(!retained.coordinator.hasRetainedImage && retained.coordinator.problem == nil
                   && retained.clipboard.calls == 1 && !retained.coordinator.isWorking
                   && retained.interface.problemActivations == [false],
                   "Changed session retained/copied old data or reopened its retry problem")
        retained.interface.environmentValidation = nil
        retained.clipboard.mode = .accepted
        try retained.beginAndSelect()
        await retained.coordinator.waitForWorker()
        try expect(retained.clipboard.successfulWrites == 1, "New explicit operation did not recover")
    }

    @MainActor
    static func testSessionFenceCapture() async throws {
        let h = try Harness()
        h.capturer.mode = .paused
        try h.beginAndSelect()
        try await waitUntil { h.capturer.pending != nil }
        // No notification callback is delivered; only the post-capture fence observes the loss.
        h.interface.environmentAvailable = false
        try h.capturer.release()
        await h.coordinator.waitForWorker()
        let encodeCalls = await h.encoder.calls
        try expect(!h.coordinator.hasRetainedImage && h.coordinator.problem == nil
                   && h.coordinator.phase == .idle && encodeCalls == 0
                   && h.clipboard.calls == 0 && h.interface.feedback.isEmpty,
                   "Fence loss adopted a late capture or showed stale UI")
    }

    @MainActor
    static func testSessionFenceEncoding() async throws {
        for failures in [0, 1] {
            let h = try Harness(encoderFailures: failures, pauseEncoder: true)
            try h.beginAndSelect()
            try await waitUntil { await h.encoder.isWaiting }
            try expect(h.coordinator.hasRetainedImage, "Encoder precondition missing")
            h.interface.environmentAvailable = false
            try await h.encoder.release()
            await h.coordinator.waitForWorker()
            try expect(!h.coordinator.hasRetainedImage && h.coordinator.problem == nil
                       && h.clipboard.calls == 0 && h.interface.feedback.isEmpty
                       && h.interface.problemActivations.isEmpty,
                       "Fence loss revived encoded data, failure UI or success")
            #if DEBUG
            try expect(!h.coordinator.hasRetainedPNG, "Fence loss retained late PNG")
            #endif
        }
    }

    /// These invoke the product invalidation boundary; they do not simulate or prove OS delivery.
    @MainActor
    static func testEnvironmentRetainedInvalidation() async throws {
        for event in CaptureEnvironmentEvent.allCases {
            let h = try Harness()
            h.clipboard.mode = .rejected
            try h.beginAndSelect()
            await h.coordinator.waitForWorker()
            try expect(h.coordinator.hasRetainedImage && h.coordinator.phase == .failure,
                       "\(event): retained-image precondition missing")
            #if DEBUG
            try expect(h.coordinator.hasRetainedPNG, "\(event): retained-PNG precondition missing")
            #endif

            h.coordinator.environmentDidChange(event)
            // No suspension before the release/dismiss checks: invalidation must be synchronous.
            try expect(!h.coordinator.hasRetainedImage && h.coordinator.problem == nil
                       && h.coordinator.phase == .idle && h.interface.dismissCalls == 1,
                       "\(event): retained state/UI was not cleared synchronously")
            #if DEBUG
            try expect(!h.coordinator.hasRetainedPNG, "\(event): invalidation kept cached PNG")
            #endif
            h.coordinator.retryCopy()
            await Task.yield()
            try expect(h.clipboard.calls == 1 && h.clipboard.successfulWrites == 0
                       && h.interface.feedback.isEmpty && h.interface.selectionCalls == 1,
                       "\(event): invalidated image copied or operation resumed automatically")

            h.clipboard.mode = .accepted
            try h.beginAndSelect()
            await h.coordinator.waitForWorker()
            try expect(h.capturer.calls == 2 && h.clipboard.calls == 2
                       && h.clipboard.successfulWrites == 1 && h.interface.feedback.count == 1,
                       "\(event): a new explicit selection did not recover after retained-state invalidation")
        }
    }

    @MainActor
    static func testEnvironmentLateCapture() async throws {
        for event in CaptureEnvironmentEvent.allCases {
            let h = try Harness()
            h.capturer.mode = .paused
            try h.beginAndSelect()
            try await waitUntil { h.capturer.pending != nil }

            h.coordinator.environmentDidChange(event)
            try expect(!h.coordinator.hasRetainedImage && h.coordinator.problem == nil
                       && h.coordinator.phase == .cancelling && h.coordinator.isWorking
                       && !h.coordinator.canBegin && h.interface.dismissCalls == 1,
                       "\(event): pending capture did not synchronously invalidate and retain the worker slot")
            h.coordinator.begin()
            h.coordinator.retrySelection()
            h.coordinator.retryCopy()
            h.interface.selected?(h.selection) // An overlay callback queued before the environment event.
            try expect(h.interface.selectionCalls == 1 && h.capturer.calls == 1,
                       "\(event): invalidation allowed overlapping capture")

            try h.capturer.release() // The injected capturer deliberately ignores cancellation.
            await h.coordinator.waitForWorker()
            let encodeCalls = await h.encoder.calls
            try expect(!h.coordinator.hasRetainedImage && h.coordinator.problem == nil
                       && h.coordinator.phase == .idle && !h.coordinator.isWorking
                       && h.coordinator.canBegin && encodeCalls == 0
                       && h.clipboard.calls == 0 && h.interface.feedback.isEmpty,
                       "\(event): late capture revived an image, writer, UI or success feedback")
            #if DEBUG
            try expect(!h.coordinator.hasRetainedPNG, "\(event): late capture revived cached PNG")
            #endif
            h.coordinator.retryCopy()
            await Task.yield()
            try expect(h.clipboard.calls == 0 && h.interface.selectionCalls == 1,
                       "\(event): stale capture remained available for recopy or auto-resumed")

            h.capturer.mode = .immediate
            try h.beginAndSelect()
            await h.coordinator.waitForWorker()
            try expect(h.capturer.calls == 2 && h.clipboard.successfulWrites == 1
                       && h.interface.feedback.count == 1,
                       "\(event): explicit recovery failed after the old capture worker finished")
        }
    }

    @MainActor
    static func testEnvironmentLateEncoding() async throws {
        for event in CaptureEnvironmentEvent.allCases {
            let h = try Harness(pauseEncoder: true)
            try h.beginAndSelect()
            try await waitUntil { await h.encoder.isWaiting }
            try expect(h.coordinator.hasRetainedImage, "\(event): pending encoder did not own an image")

            h.coordinator.environmentDidChange(event)
            try expect(!h.coordinator.hasRetainedImage && h.coordinator.problem == nil
                       && h.coordinator.phase == .cancelling && h.coordinator.isWorking
                       && !h.coordinator.canBegin && h.interface.dismissCalls == 1,
                       "\(event): pending encoder did not synchronously release UI/image state")
            #if DEBUG
            try expect(!h.coordinator.hasRetainedPNG, "\(event): encoder invalidation kept PNG")
            #endif
            h.coordinator.begin()
            h.coordinator.retrySelection()
            h.coordinator.retryCopy()
            h.interface.selected?(h.selection)
            let beforeReleaseCalls = await h.encoder.calls
            try expect(h.interface.selectionCalls == 1 && h.capturer.calls == 1 && beforeReleaseCalls == 1,
                       "\(event): encoder cancellation released the worker slot prematurely")

            try await h.encoder.release() // Returns a real synthetic PNG after the invalidation.
            await h.coordinator.waitForWorker()
            try expect(!h.coordinator.hasRetainedImage && h.coordinator.problem == nil
                       && h.coordinator.phase == .idle && !h.coordinator.isWorking
                       && h.coordinator.canBegin && h.clipboard.calls == 0 && h.interface.feedback.isEmpty,
                       "\(event): late encoded data revived image, UI, write or success")
            #if DEBUG
            try expect(!h.coordinator.hasRetainedPNG, "\(event): late encoding revived cached PNG")
            #endif
            h.coordinator.retryCopy()
            await Task.yield()
            try expect(h.clipboard.calls == 0 && h.interface.selectionCalls == 1,
                       "\(event): late PNG remained available for recopy or auto-resumed")

            try h.beginAndSelect()
            await h.coordinator.waitForWorker()
            let recoveredEncodeCalls = await h.encoder.calls
            try expect(h.capturer.calls == 2 && recoveredEncodeCalls == 2
                       && h.clipboard.successfulWrites == 1 && h.interface.feedback.count == 1,
                       "\(event): new explicit operation failed after the old encoder finished")
        }
    }
}
