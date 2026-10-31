import AppKit
import Darwin
import Foundation

/// Production Native/router/monitor/coordinator wiring with private centers and fake backends.
/// No live subscription, foreground lookup, hotkey registration, SCK, TCC, OS transition or board.
@main
struct CaptureEnvironmentIntegrationTests {
    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor
    static func main() async throws {
        let groups: [(String, @MainActor () async throws -> Void)] = [
            ("TRACE-01 default off, bounded storage and concurrent sequence", testTrace),
            ("ENV-01 nine production routes invalidate both retained owners", testRetainedRoutes),
            ("ENV-02 nine routes reject late capture and encode outcomes in both modes", testLateRoutes),
            ("ENV-03 poll-before-dispatch conservatively invalidates a fresh operation", testPollBeforeDispatch),
            ("ENV-04 old CG and SC generations cannot invalidate a later operation", testOldGenerations),
            ("ENV-05 monitor faults close admission and require explicit recovery", testMonitorFaults),
            ("ENV-06 failed cleanup prevents overlapping subscriptions", testCleanupFailure),
            ("ENV-07 stopped test configuration has no subscription side effects", testStoppedConfiguration),
            ("ENV-08 nine routes reach result services before both capture owners", testResultServiceRoutes),
            ("ENV-09 result admission and preview dismissal use isolated dependencies", testResultServiceAdmission),
            ("ENV-10 nine native routes fence real result PNGs and gated archive workers", testRealResultWorkerRoutes),
            ("ENV-11 nine native routes invalidate isolated annotation before other owners", testAnnotationServiceRoutes),
            ("ENV-12 nine native routes fence actual annotation load and render workers", testRealAnnotationWorkerRoutes)
        ]
        for (name, body) in groups {
            try await body()
            print("PASS \(name)")
        }
        print("PASS \(groups.count) environment integration groups; synthetic routes only")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }

    @MainActor
    static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        throw Failure(description: "Synthetic worker did not reach its gate")
    }

    @MainActor
    final class SessionBackend {
        var checks: [CaptureSessionMonitor.CheckResult] = []
        var callbacks: [@MainActor @Sendable () -> Void] = []
        var registrationSucceeds = true
        var cancellationSucceeds = true
        private var nextToken: Int32 = 10
        var registrations: Int { callbacks.count }

        var backend: CaptureSessionMonitor.Backend {
            .init(registerDispatch: { [self] delivered in
                callbacks.append(delivered)
                nextToken += 1
                return .init(token: nextToken, succeeded: registrationSucceeds)
            }, registerCheck: { [self] in
                nextToken += 1
                checks = [.changed] // Only the registration baseline, never an OS event.
                return .init(token: nextToken, succeeded: true)
            }, check: { [self] _ in checks.isEmpty ? .unchanged : checks.removeFirst() },
            cancel: { [self] _ in cancellationSucceeds },
            session: { .init(onConsole: true, loginDone: true, userID: 501) }, ownUserID: { 501 })
        }

        func dispatch(_ result: CaptureSessionMonitor.CheckResult = .changed) {
            checks = [result]
            callbacks.last?()
        }
    }

    @MainActor
    final class ConsoleBackend {
        var checks: [CaptureConsoleUserMonitor.CheckResult] = []
        var callbacks: [@MainActor @Sendable (CaptureConsoleUserMonitor.Delivery) -> Void] = []
        var registrationSucceeds = true
        var cancellationSucceeds = true
        var registrations: Int { callbacks.count }

        var backend: CaptureConsoleUserMonitor.Backend {
            .init(register: { [self] delivered in
                callbacks.append(delivered)
                return .init(token: UUID(), succeeded: registrationSucceeds)
            }, check: { [self] _ in checks.isEmpty ? .unchanged : checks.removeFirst() },
            cancel: { [self] _ in cancellationSucceeds }, consoleUserID: { 501 }, ownUserID: { 501 })
        }
    }

    @MainActor
    final class Interface: CollectionCaptureInterface {
        weak var native: NativeCaptureInterface?
        var isOneClipActive = false
        var captureEntryBlocked: Bool { native?.captureEntryBlocked == true }
        var collectionCopyBlocked: Bool { native?.collectionCopyBlocked == true }
        var selected: (@MainActor (CaptureSelection) -> Void)?
        var selectionCalls = 0
        var shows = 0
        var feedback = 0
        var permissionShows = 0
        var captureEnvironmentStatus: String { "Synthetic environment unavailable" }
        func prepareCaptureEnvironment() -> Bool { native?.prepareCaptureEnvironment() == true }
        func validateCaptureEnvironment() -> Bool { native?.validateCaptureEnvironment() == true }
        func prepareForSelection() -> Bool { true }
        func showSelection(on display: CaptureDisplaySnapshot,
                           selected: @escaping @MainActor (CaptureSelection) -> Void,
                           cancelled: @escaping @MainActor () -> Void) {
            selectionCalls += 1
            self.selected = selected
        }
        func hideSelection() -> Bool { selected = nil; return true }
        func showCollection(activate: Bool) { shows += 1 }
        func hideCollection() {}
        func showCollectionGuide(started: @escaping @MainActor () -> Void,
                                 cancelled: @escaping @MainActor () -> Void) { started() }
        func showCollectionPermission() { permissionShows += 1 }
        func showPermission() { permissionShows += 1 }
        func hidePermission() {}
        func showProblem(activate: Bool) { shows += 1 }
        func hideProblem() {}
        func showFeedback(_ message: String) { feedback += 1 }
        func dismissAll() { selected = nil }
        func rememberExternalApplication() {}
        func returnToExternalApplication() {}
    }

    @MainActor
    final class Writer: CaptureClipboardWriting {
        var changeCount = 0
        var calls = 0
        var accepts = true
        func writePNG(_ data: Data, expectedChangeCount: Int) -> M0ClipboardProbe.Outcome {
            calls += 1
            changeCount += 1
            return .init(code: accepts ? .writeAccepted : .writeRejected,
                         expectedChangeCount: expectedChangeCount, observedChangeCount: changeCount,
                         preparedChangeCount: changeCount)
        }
    }

    @MainActor
    final class Capturer: ScreenshotCapturing {
        let asset: M0ImageAsset
        var paused = false
        private var pending: CheckedContinuation<M0ImageAsset, any Error>?
        var isWaiting: Bool { pending != nil }
        init(asset: M0ImageAsset) { self.asset = asset }
        func capture(_ request: SingleCaptureRequest,
                     isCurrent: @escaping @MainActor () -> Bool) async throws -> M0ImageAsset {
            if paused { return try await withCheckedThrowingContinuation { pending = $0 } }
            return asset
        }
        func release(failure: Bool = false) {
            guard let pending else { return }
            self.pending = nil
            if failure { pending.resume(throwing: ScreenshotError.captureFailed) }
            else { pending.resume(returning: asset) }
        }
    }

    actor Encoder {
        private var paused = false
        private var fails = false
        private var pending: CheckedContinuation<Void, Never>?
        var isWaiting: Bool { pending != nil }
        func pause() { paused = true }
        func run(_ assets: [M0ImageAsset], limits: M0ImageLimits = .init()) async throws -> M0CompositionResult {
            if paused { await withCheckedContinuation { pending = $0 } }
            if fails { throw M0ImageError.encodingFailed }
            // Deliberately uncooperative: success after cancellation must still fail adoption.
            return try M0ImageComposer.compose(assets: assets, limits: limits, checkCancellation: { _ in })
        }
        func release(failure: Bool = false) {
            fails = failure
            paused = false
            let continuation = pending
            pending = nil
            continuation?.resume()
        }
    }

    /// A synthetic result owner proves the dependency route, not a real archive/UI outcome.
    /// Product result cancellation and file boundaries have their own tests.
    @MainActor
    final class ResultOwner {
        var blocksCapture = false
        var retainsImage = false
        var previewVisible = false
        var invalidations: [CaptureEnvironmentEvent] = []
        var dismissals = 0
        var services: NativeCaptureInterface.ResultServices {
            .init(blocksCapture: { [self] in blocksCapture }, invalidate: { [self] event in
                invalidations.append(event)
                blocksCapture = false
                retainsImage = false
                previewVisible = false
            }, dismissPreview: { [self] in
                dismissals += 1
                previewVisible = false
            })
        }
    }

    /// Only the injected route is under test here. The actual annotation worker has separate
    /// controller/renderer tests and never resolves a singleton in this configuration.
    @MainActor
    final class AnnotationOwner {
        var blocksCapture = false
        var retainsImage = false
        var invalidations: [CaptureEnvironmentEvent] = []
        var services: NativeCaptureInterface.AnnotationServices {
            .init(blocksCapture: { [self] in blocksCapture }, invalidate: { [self] event in
                invalidations.append(event)
                blocksCapture = false
                retainsImage = false
            })
        }
    }

    @MainActor
    final class Harness {
        let cg = SessionBackend()
        let sc = ConsoleBackend()
        let workspace = NotificationCenter()
        let application = NotificationCenter()
        let trace: CaptureSecurityTrace
        let result = ResultOwner()
        let annotation = AnnotationOwner()
        let native: NativeCaptureInterface
        let slot = CaptureWorkerSlot()
        let singleUI = Interface(), collectionUI = Interface()
        let singleWriter = Writer(), collectionWriter = Writer()
        let singleCapture: Capturer, collectionCapture: Capturer
        let singleEncoder = Encoder(), collectionEncoder = Encoder()
        let single: SingleCaptureCoordinator
        let collection: CollectionCaptureCoordinator
        let selection: CaptureSelection

        init(startMonitoring: Bool = true, cgRegistrationSucceeds: Bool = true, scRegistrationSucceeds: Bool = true,
             actualResult: CaptureResultController? = nil, actualAnnotation: CaptureAnnotationController? = nil) throws {
            trace = actualResult?.securityTrace ?? actualAnnotation?.securityTrace ?? CaptureSecurityTrace(enabled: true, trial: 1)
            let display = try CaptureDisplaySnapshot(id: 99, frame: CGRect(x: 0, y: 0, width: 640, height: 480), scale: 1)
            selection = try CaptureSelection(display: display, rect: CGRect(x: 20, y: 20, width: 16, height: 16))
            let asset = try M0ImageFixture.make(index: 1, width: 16, height: 16)
            singleCapture = Capturer(asset: asset); collectionCapture = Capturer(asset: asset)
            cg.registrationSucceeds = cgRegistrationSucceeds
            sc.registrationSucceeds = scRegistrationSucceeds
            let resultServices: NativeCaptureInterface.ResultServices
            if let actualResult {
                resultServices = .init(blocksCapture: {
                    actualResult.hasPendingSave || actualResult.isSaving
                }, invalidate: { _ in actualResult.environmentDidChange() },
                   dismissPreview: { actualResult.dismissPreview() })
            } else { resultServices = result.services }
            let annotationServices: NativeCaptureInterface.AnnotationServices
            if let actualAnnotation {
                annotationServices = .init(blocksCapture: { actualAnnotation.blocksCapture },
                    invalidate: { _ in actualAnnotation.invalidate() })
            } else { annotationServices = annotation.services }
            native = NativeCaptureInterface(environmentSources: .init(workspace: workspace, application: application),
                sessionBackend: cg.backend, consoleBackend: sc.backend, securityTrace: trace,
                startMonitoring: startMonitoring, resultServices: resultServices, annotationServices: annotationServices)
            let preferences = CapturePreferences(defaults: nil, hasSeenCaptureGuide: true,
                hasSeenPasteHint: true, hasSeenCollectionGuide: true)
            let encoder = singleEncoder
            single = SingleCaptureCoordinator(capturer: singleCapture, interface: singleUI,
                clipboard: singleWriter, workSlot: slot, permissionCheck: { true }, permissionRequest: { false },
                protectedDataCheck: { true }, displayAtPointer: { display }, preferences: preferences,
                securityTrace: trace, encode: { asset in try await encoder.run([asset]) })
            let composer = collectionEncoder
            collection = CollectionCaptureCoordinator(capturer: collectionCapture, interface: collectionUI,
                clipboard: collectionWriter, workSlot: slot, preferences: preferences, securityTrace: trace,
                permissionCheck: { true }, permissionRequest: { false }, protectedDataCheck: { true },
                displayAtPointer: { display }, compose: { assets, limits in try await composer.run(assets, limits: limits) })
            singleUI.native = native; collectionUI.native = native
            native.coordinator = single; native.collectionCoordinator = collection
            let capture = single, retained = collection
            retained.externalOperationBlocked = {
                capture.isWorking || capture.hasRetainedImage || [.selecting, .onboarding, .permission].contains(capture.phase)
            }
            retained.externalWorkInProgress = {
                capture.isWorking || [.selecting, .onboarding, .permission].contains(capture.phase)
            }
            capture.prepareExternalCapture = { retained.prepareForSingleCapture() }
            capture.externalRetainedBytes = { retained.retainedImageBytes }
        }

        func emit(_ event: CaptureEnvironmentEvent) {
            switch event {
            case .systemSleep: workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
            case .displaySleep: workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            case .sessionResigned: workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            case .displayChanged: application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            case .protectedDataUnavailable: native.protectedDataWillBecomeUnavailable()
            case .consoleSessionChanged: cg.dispatch()
            case .consoleSessionUnavailable:
                cg.checks = [.failed]; _ = native.validateCaptureEnvironment()
            case .consoleUserChanged: sc.callbacks.last?(.changed)
            case .consoleUserUnavailable:
                sc.checks = [.failed]; _ = native.validateCaptureEnvironment()
            }
        }

        func begin(_ mode: CaptureSecurityTrace.Mode) { if mode == .single { single.begin() } else { collection.beginOrAdd() } }
        func select(_ mode: CaptureSecurityTrace.Mode) throws {
            guard let selected = mode == .single ? singleUI.selected : collectionUI.selected else {
                throw Failure(description: "Missing synthetic selection")
            }
            selected(selection)
        }
        func waitForWorker(_ mode: CaptureSecurityTrace.Mode) async {
            if mode == .single { await single.waitForWorker() } else { await collection.waitForWorker() }
        }
        func close() async {
            single.stop(); collection.stop(); native.stopEnvironmentMonitoring()
            singleCapture.release(); collectionCapture.release()
            await singleEncoder.release(); await collectionEncoder.release()
            await single.waitForWorker(); await collection.waitForWorker()
        }
    }

    @MainActor
    static func withHarness(startMonitoring: Bool = true, _ body: @MainActor (Harness) async throws -> Void) async throws {
        let h = try Harness(startMonitoring: startMonitoring)
        do { try await body(h); await h.close() }
        catch { await h.close(); throw error }
    }

    static func testTrace() async throws {
        let disabled = CaptureSecurityTrace()
        disabled.record(.clipboardWrite, mode: .single, phase: .writing)
        try expect(!disabled.snapshot().isEnabled && disabled.snapshot().entries.isEmpty, "Default trace recorded data")
        let capped = CaptureSecurityTrace(enabled: true, capacity: Int.max, trial: 7)
        for _ in 0..<(CaptureSecurityTrace.maximumCapacity + 3) { capped.record(.environmentValidated) }
        let full = capped.snapshot()
        try expect(full.capacity == 8_192 && full.entries.count == 8_192 && full.droppedCount == 3,
                   "Trace exceeded its cap, overwrote evidence or hid overflow")
        try expect(full.entries.first?.trial == 7 && full.entries.first?.sequence == 1
                   && full.entries.last?.sequence == 8_192, "Trace lost the initial evidence")
        let annotation = CaptureSecurityTrace(enabled: true, trial: 3)
        annotation.record(.annotationOpened, mode: .annotation)
        let row = annotation.snapshot().entries[0]
        let encoded = try JSONEncoder().encode(row)
        let decoded = try JSONDecoder().decode(CaptureSecurityTrace.Entry.self, from: encoded)
        try expect(row == decoded && decoded.mode == .annotation && decoded.code == .annotationOpened,
                   "Annotation mode/fixed code failed their internal codec boundary")
        let concurrent = CaptureSecurityTrace(enabled: true, capacity: 256)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 { group.addTask { concurrent.record(.captureCallback); concurrent.record(.workerReturned) } }
        }
        let records = concurrent.snapshot().entries
        try expect(records.count == 200 && concurrent.snapshot().droppedCount == 0, "Concurrent trace lost entries")
        for (index, entry) in records.enumerated() {
            try expect(entry.sequence == UInt64(index + 1), "Concurrent sequence was not serialized")
            if index > 0 { try expect(records[index - 1].relativeNanos <= entry.relativeNanos, "Relative time went backwards") }
        }
    }

    @MainActor
    static func testRetainedRoutes() async throws {
        for event in CaptureEnvironmentEvent.allCases {
            for mode in [CaptureSecurityTrace.Mode.single, .collection] {
                try await withHarness { h in
                    if mode == .single {
                        // Retained single means a fabricated writer failure, not normal success.
                        h.singleWriter.accepts = false
                        h.begin(.single); try h.select(.single); await h.single.waitForWorker()
                        try expect(h.single.hasRetainedImage, "Single retained-image precondition missing")
                    } else {
                        h.begin(.collection); try h.select(.collection); await h.collection.waitForWorker()
                        h.collection.copy(); await h.collection.waitForWorker()
                        h.collection.replace(at: 0); try h.select(.collection); await h.collection.waitForWorker()
                        try expect(h.collection.pendingReplacement != nil && h.collection.copiedContentRevision != nil,
                                   "Copied collection/candidate precondition missing")
                    }
                    let candidate = h.collection.pendingReplacement?.id
                    let writes = h.singleWriter.calls + h.collectionWriter.calls
                    h.emit(event)
                    try expect(!h.single.hasRetainedImage && h.collection.assets.isEmpty
                               && h.collection.pendingReplacement == nil && !h.collection.isActive,
                               "A production environment route retained an image owner")
                    h.single.retryCopy()
                    if let candidate { h.collection.acceptReplacement(id: candidate) }
                    h.collection.copy()
                    try expect(h.singleWriter.calls + h.collectionWriter.calls == writes, "An old consumer wrote after invalidation")
                    try expect(h.trace.snapshot().droppedCount == 0, "Integration trace overflowed")
                }
            }
        }
    }

    @MainActor
    static func testLateRoutes() async throws {
        var cases = 0
        for event in CaptureEnvironmentEvent.allCases {
            for mode in [CaptureSecurityTrace.Mode.single, .collection] {
                for encoding in [false, true] {
                    for failure in [false, true] {
                        try await withHarness { h in
                            let capturer = mode == .single ? h.singleCapture : h.collectionCapture
                            let encoder = mode == .single ? h.singleEncoder : h.collectionEncoder
                            let ui = mode == .single ? h.singleUI : h.collectionUI
                            let writer = mode == .single ? h.singleWriter : h.collectionWriter
                            if encoding && mode == .single { await encoder.pause() }
                            if !encoding { capturer.paused = true }
                            h.begin(mode); try h.select(mode)
                            if encoding && mode == .collection {
                                await h.collection.waitForWorker(); await encoder.pause(); h.collection.copy()
                            }
                            try await waitUntil { encoding ? await encoder.isWaiting : capturer.isWaiting }
                            let writes = writer.calls, shows = ui.shows, feedback = ui.feedback
                            h.emit(event)
                            try expect(h.slot.isOccupied && !h.single.hasRetainedImage && h.collection.assets.isEmpty,
                                       "Invalidation released a running permit or retained images")
                            let selections = h.singleUI.selectionCalls + h.collectionUI.selectionCalls
                            h.single.begin(); h.collection.beginNewSession()
                            try expect(h.singleUI.selectionCalls + h.collectionUI.selectionCalls == selections,
                                       "New work overlapped the cancelled worker")
                            if encoding { await encoder.release(failure: failure) } else { capturer.release(failure: failure) }
                            await h.waitForWorker(mode)
                            try expect(!h.slot.isOccupied && !h.single.hasRetainedImage && h.collection.assets.isEmpty
                                       && writer.calls == writes && ui.shows == shows && ui.feedback == feedback,
                                       "A late outcome revived pixels, presentation or writing")
                            try expect(h.trace.snapshot().droppedCount == 0, "Late-route trace overflowed")
                        }
                        cases += 1
                    }
                }
            }
        }
        try expect(cases == 72, "Missing native-route late-outcome combinations")
        print("PASS ENV late cases=72 injectedRoutes=1 realOSTransition=0")
    }

    @MainActor
    static func testPollBeforeDispatch() async throws {
        try await withHarness { h in
            h.begin(.collection)
            h.cg.checks = [.changed]
            try expect(!h.native.validateCaptureEnvironment() && !h.collection.isActive, "Pending poll did not invalidate")
            h.collection.beginNewSession()
            try expect(h.collection.phase == .selecting, "Explicit recovery did not start")
            // Same-generation late duplicate remains a stop signal even after the check was consumed.
            h.cg.dispatch(.unchanged)
            try expect(!h.collection.isActive, "Late duplicate was incorrectly ignored")
            let entries = h.trace.snapshot().entries
            try expect(entries.contains { $0.code == .cgCheck && $0.outcome == .changed }
                       && entries.contains { $0.code == .cgDispatch }, "Route observations are missing")
        }
    }

    @MainActor
    static func testOldGenerations() async throws {
        try await withHarness { h in
            let oldCG = h.cg.callbacks.last!, oldSC = h.sc.callbacks.last!
            h.native.stopEnvironmentMonitoring()
            try expect(h.native.prepareCaptureEnvironment(), "Fresh monitor subscriptions unavailable")
            h.collection.beginNewSession()
            oldCG(); oldSC(.changed)
            try expect(h.collection.phase == .selecting && h.collection.isActive, "Old generation invalidated the new session")
            h.application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            try expect(!h.collection.isActive, "Restart lost the current private notification subscription")
        }
    }

    @MainActor
    static func testMonitorFaults() async throws {
        for cgFault in [false, true] {
            try await withHarness { h in
                h.begin(.collection)
                if cgFault { h.cg.checks = [.failed]; _ = h.native.validateCaptureEnvironment() }
                else { h.sc.callbacks.last?(.restarted) }
                try expect(!h.collection.isActive, "Monitor failure retained the session")
                let calls = h.collectionUI.selectionCalls
                for _ in 0..<3 { await Task.yield() }
                try expect(h.collectionUI.selectionCalls == calls, "Failure automatically resumed work")
                h.collection.beginNewSession()
                try expect(h.collection.phase == .selecting, "Explicit recovery after monitor failure failed")
            }
        }
        for cgFault in [false, true] {
            let h = try Harness(cgRegistrationSucceeds: !cgFault, scRegistrationSucceeds: cgFault)
            do {
                h.collection.beginNewSession()
                try expect(h.collectionUI.selectionCalls == 0 && !h.collection.isActive && !h.slot.isOccupied,
                           "An unavailable initial monitor permitted acquisition")
                h.cg.registrationSucceeds = true; h.sc.registrationSucceeds = true
                h.collection.beginNewSession()
                try expect(h.collection.phase == .selecting, "Explicit registration recovery failed")
                await h.close()
            } catch { await h.close(); throw error }
        }
    }

    @MainActor
    static func testCleanupFailure() async throws {
        try await withHarness { h in
            h.cg.cancellationSucceeds = false; h.sc.cancellationSucceeds = false
            h.native.stopEnvironmentMonitoring()
            let cg = h.cg.registrations, sc = h.sc.registrations
            try expect(!h.native.prepareCaptureEnvironment(), "Failed cleanup permitted use")
            try expect(h.cg.registrations == cg && h.sc.registrations == sc, "Failed cleanup overlapped subscriptions")
            h.cg.cancellationSucceeds = true; h.sc.cancellationSucceeds = true
            try expect(h.native.prepareCaptureEnvironment(), "Explicit cleanup recovery failed")
        }
    }

    @MainActor
    static func testResultServiceRoutes() async throws {
        for event in CaptureEnvironmentEvent.allCases {
            try await withHarness { h in
                h.result.blocksCapture = true
                h.result.retainsImage = true
                h.result.previewVisible = true
                try expect(h.native.captureEntryBlocked && h.native.collectionCopyBlocked,
                           "Pending result did not block capture/copy admission")
                let initialCount = h.trace.snapshot().entries.count
                let singleSelections = h.singleUI.selectionCalls, collectionSelections = h.collectionUI.selectionCalls
                h.emit(event)
                try expect(h.result.invalidations == [event] && !h.result.retainsImage
                           && !h.result.previewVisible && !h.result.blocksCapture,
                           "A production route bypassed the isolated result owner")
                let delivery = Array(h.trace.snapshot().entries.dropFirst(initialCount)).filter {
                    $0.code == .resultInvalidationDelivered || $0.code == .operationInvalidated
                }
                try expect(delivery.count == 3 && delivery[0].code == .resultInvalidationDelivered
                           && delivery[1].code == .operationInvalidated && delivery[1].mode == .single
                           && delivery[2].code == .operationInvalidated && delivery[2].mode == .collection,
                           "Result/single/collection invalidation order changed or duplicated")
                try expect(!h.native.captureEntryBlocked && !h.native.collectionCopyBlocked,
                           "Invalidated result left a stale admission fence")
                for _ in 0..<3 { await Task.yield() }
                try expect(h.singleUI.selectionCalls == singleSelections && h.collectionUI.selectionCalls == collectionSelections,
                           "Result invalidation automatically restarted capture")
                h.collection.beginNewSession()
                try expect(h.collection.phase == .selecting, "Explicit operation did not recover after result invalidation")
            }
        }
        print("PASS ENV result routes=9 syntheticResultServices=1 actualDiskSave=0")
    }

    @MainActor
    static func testAnnotationServiceRoutes() async throws {
        for event in CaptureEnvironmentEvent.allCases {
            try await withHarness { h in
                h.annotation.blocksCapture = true
                h.annotation.retainsImage = true
                h.result.blocksCapture = true
                h.result.retainsImage = true
                let initialCount = h.trace.snapshot().entries.count
                h.emit(event)
                try expect(h.annotation.invalidations == [event] && !h.annotation.retainsImage
                           && !h.annotation.blocksCapture && h.result.invalidations == [event] && !h.result.retainsImage,
                           "A production route bypassed annotation or result invalidation")
                let deliveries = Array(h.trace.snapshot().entries.dropFirst(initialCount)).filter {
                    [.annotationInvalidationDelivered, .resultInvalidationDelivered, .operationInvalidated].contains($0.code)
                }
                try expect(deliveries.count == 4 && deliveries[0].code == .annotationInvalidationDelivered
                           && deliveries[0].mode == .none && deliveries[1].code == .resultInvalidationDelivered
                           && deliveries[2].code == .operationInvalidated && deliveries[2].mode == .single
                           && deliveries[3].code == .operationInvalidated && deliveries[3].mode == .collection,
                           "Annotation/result/single/collection invalidation order changed")
                try expect(!h.native.captureEntryBlocked && !h.native.collectionCopyBlocked,
                           "Invalidation left an annotation admission fence behind")
                for _ in 0..<3 { await Task.yield() }
                try expect(h.singleUI.selectionCalls == 0 && h.collectionUI.selectionCalls == 0,
                           "Annotation invalidation automatically restarted a capture")
            }
        }
        print("PASS ENV annotation routes=9 syntheticAnnotationServices=1 actualAnnotationWorker=0")
    }

    @MainActor
    static func testResultServiceAdmission() async throws {
        try await withHarness(startMonitoring: false) { h in
            h.annotation.blocksCapture = true
            try expect(h.native.captureEntryBlocked && h.native.collectionCopyBlocked,
                       "Annotation admission dependency was not queried")
            try expect(!h.native.prepareForSelection() && h.result.dismissals == 0,
                       "Blocked annotation admission reached selection or result presentation")
            h.annotation.blocksCapture = false
            h.result.blocksCapture = true
            try expect(h.native.captureEntryBlocked && h.native.collectionCopyBlocked,
                       "Result admission dependency was not queried")
            try expect(!h.native.prepareForSelection() && h.result.dismissals == 0,
                       "Blocked admission dismissed an unresolved result")
            h.result.blocksCapture = false
            h.result.previewVisible = true
            try expect(h.native.prepareForSelection() && h.result.dismissals == 1 && !h.result.previewVisible,
                       "Selection preparation bypassed the result preview dependency")
        }
        let cg = SessionBackend(), sc = ConsoleBackend()
        let native = NativeCaptureInterface(environmentSources: .init(workspace: NotificationCenter(), application: NotificationCenter()),
            sessionBackend: cg.backend, consoleBackend: sc.backend, startMonitoring: false)
        try expect(!native.captureEntryBlocked && !native.collectionCopyBlocked,
                   "Default test result services were not isolated")
        try expect(native.prepareForSelection(), "Isolated test preparation was blocked")
        native.environmentDidChange(.systemSleep)
        native.stopEnvironmentMonitoring()
        try expect(cg.registrations == 0 && sc.registrations == 0,
                   "Isolated result dependencies started live monitoring")
    }

    /// The first deliberately failed save creates a real independent thumbnail and pending
    /// PNG. The retry pauses the actual archive worker, allowing invalidation to be observed
    /// while a worker still borrows the same tracked PNG allocation. No preview is displayed.
    final class RealResultSaveGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var calls = 0
        private var entered = false
        private var released = false
        let archive: CaptureArchive
        init(archive: CaptureArchive) { self.archive = archive }
        var isWaiting: Bool {
            condition.lock(); defer { condition.unlock() }
            return entered && !released
        }
        var callCount: Int { condition.lock(); defer { condition.unlock() }; return calls }
        func save(_ png: Data) throws -> URL {
            condition.lock()
            calls += 1
            if calls == 1 {
                condition.unlock()
                throw CaptureArchive.ArchiveError.unavailable // Explicit initial failure injection.
            }
            entered = true
            let deadline = Date(timeIntervalSinceNow: 10)
            while !released {
                if !condition.wait(until: deadline) && !released {
                    condition.unlock()
                    throw CaptureArchive.ArchiveError.unavailable
                }
            }
            condition.unlock()
            return try archive.save(png)
        }
        func release() {
            condition.lock(); released = true; condition.broadcast(); condition.unlock()
        }
    }

    final class RealResultPNGLifetime: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        var isReleased: Bool { lock.lock(); defer { lock.unlock() }; return released }
        func finish() { lock.lock(); released = true; lock.unlock() }
    }

    static func trackedResultPNG(_ png: Data, lifetime: RealResultPNGLifetime) -> Data {
        let allocation = UnsafeMutableRawPointer.allocate(byteCount: png.count, alignment: 16)
        png.copyBytes(to: allocation.assumingMemoryBound(to: UInt8.self), count: png.count)
        return Data(bytesNoCopy: allocation, count: png.count, deallocator: .custom { memory, _ in
            memory.deallocate(); lifetime.finish()
        })
    }

    @MainActor
    static func waitForRealResult(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw Failure(description: "Real result worker did not reach its expected state")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @MainActor
    static func testRealResultWorkerRoutes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneClip-EnvironmentResult-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        var workersJoined = true
        defer {
            // Retain the private fabricated fixture if an actual worker could not be joined.
            // Never remove a directory while that worker might still be writing into it.
            if workersJoined { try? FileManager.default.removeItem(at: root) }
        }
        let png = try M0ImageComposer.compose(assets: [M0ImageFixture.make(index: 1, width: 64, height: 48)]).pngData
        var cases = 0
        for event in CaptureEnvironmentEvent.allCases {
            for mode in [CaptureResultMode.single, .collection] {
                let archive = CaptureArchive(directory: root.appendingPathComponent("trial-\(cases + 1)", isDirectory: true))
                let gate = RealResultSaveGate(archive: archive)
                let trace = CaptureSecurityTrace(enabled: true, trial: UInt32(cases + 1))
                let controller = CaptureResultController(archive: archive, previewsEnabled: false,
                    securityTrace: trace, saver: { try gate.save($0) })
                let h = try Harness(actualResult: controller)
                let lifetime = RealResultPNGLifetime()
                do {
                    var input: Data? = trackedResultPNG(png, lifetime: lifetime)
                    workersJoined = false
                    controller.receive(input!, copied: mode == .single, mode: mode)
                    input = nil
                    try await waitForRealResult { !controller.isSaving }
                    try expect(controller.hasPendingSave && controller.thumbnailHeldBytes > 0
                               && !lifetime.isReleased && !controller.isPreviewVisible,
                               "Real failed-save thumbnail or pending PNG precondition missing")
                    controller.retrySave()
                    try await waitForRealResult { gate.isWaiting }
                    let workerPNG = png.count * 2
                    let workspace = CaptureResultController.thumbnailWorkspaceReserveBytes
                    try expect(controller.isSaving && controller.hasPendingSave && controller.thumbnailHeldBytes > 0
                               && controller.saveWorkerPNGBytes == workerPNG
                               && controller.workerThumbnailReserveBytes == workspace
                               && h.native.captureEntryBlocked && h.native.collectionCopyBlocked,
                               "Real retry worker or native result gate was not established")
                    let singleSelections = h.singleUI.selectionCalls, collectionSelections = h.collectionUI.selectionCalls
                    h.emit(event)
                    try expect(controller.isSaving && !controller.hasPendingSave
                               && controller.thumbnailHeldBytes == 0 && controller.retiredThumbnailBytes == 0
                               && controller.retainedImageBytes == workerPNG + workspace
                               && !lifetime.isReleased && !controller.isPreviewVisible
                               && h.native.captureEntryBlocked && h.native.collectionCopyBlocked,
                               "Native invalidation dropped a live archive reservation or retained pending pixels")
                    h.single.begin(); h.collection.beginNewSession()
                    controller.receive(png, copied: false, mode: mode)
                    controller.retrySave()
                    try expect(h.singleUI.selectionCalls == singleSelections
                               && h.collectionUI.selectionCalls == collectionSelections && gate.callCount == 2,
                               "Native admission or result receipt overlapped the invalidated live save")
                    gate.release()
                    try await waitForRealResult { !controller.isSaving && lifetime.isReleased }
                    workersJoined = true
                    try expect(!controller.hasPendingSave && controller.retainedImageBytes == 0
                               && controller.saveWorkerPNGBytes == 0 && controller.workerThumbnailReserveBytes == 0
                               && controller.thumbnailHeldBytes == 0 && controller.latestURL == nil
                               && !controller.isPreviewVisible && !h.native.captureEntryBlocked
                               && !h.native.collectionCopyBlocked,
                               "Real archive return restored stale result state or retained the native gate")
                    let snapshot = trace.snapshot()
                    guard let invalidation = snapshot.entries.first(where: { $0.code == .resultInvalidated }),
                          let returned = snapshot.entries.last(where: { $0.code == .archiveReturned }),
                          let stale = snapshot.entries.last(where: { $0.code == .archiveOutcome && $0.outcome == .stale }) else {
                        throw Failure(description: "Real result invalidation/return/stale evidence was incomplete")
                    }
                    try expect(snapshot.droppedCount == 0 && invalidation.sequence < returned.sequence
                               && returned.sequence < stale.sequence,
                               "Real result trace overflowed or accepted an obsolete archive callback")
                    try expect(!snapshot.entries.contains { $0.sequence > invalidation.sequence
                               && ($0.code == .resultAdopted || ($0.code == .archiveOutcome && $0.outcome == .accepted)) }
                               && !snapshot.entries.contains { [.resultPreviewShown, .resultPreviewDraw, .resultPreviewHidden].contains($0.code) },
                               "A stale real save adopted pixels or claimed image presentation")
                    let files = try FileManager.default.contentsOfDirectory(at: archive.directory, includingPropertiesForKeys: nil)
                    try expect(files.count == 1 && files[0].pathExtension == "png",
                               "Previously requested durable save was missing, duplicated or left staging")
                    let saved = try Data(contentsOf: files[0])
                    try expect(saved == png, "Native invalidation altered a previously requested fabricated saved PNG")
                    for _ in 0..<3 { await Task.yield() }
                    try expect(h.singleUI.selectionCalls == singleSelections
                               && h.collectionUI.selectionCalls == collectionSelections,
                               "A real archive callback automatically resumed capture")
                    h.collection.beginNewSession()
                    try expect(h.collection.phase == .selecting,
                               "A fresh explicit capture did not recover after the actual archive return")
                    controller.environmentDidChange()
                    await h.close()
                } catch {
                    gate.release()
                    controller.environmentDidChange()
                    do {
                        try await waitForRealResult { !controller.isSaving }
                        workersJoined = true
                    } catch { /* The unique private fixture remains if real cleanup was unproved. */ }
                    await h.close()
                    throw error
                }
                cases += 1
            }
        }
        try expect(cases == 18, "Missing native-route and real result mode combinations")
        print("PASS ENV realResultRoutes=18 syntheticPNG=1 actualArchiveWorker=1 injectedInitialSaveFailure=1 realOSTransition=0 displayedPreview=0")
    }

    /// This is an in-process worker gate, never an artificial SCK/OS transition interval.
    /// The real FD load or flattened render has completed before its immutable output waits.
    final class RealAnnotationGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var entered = false, released = false
        private weak var observedImage: CGImage?
        private var loadingCalls = 0, renderingCalls = 0
        var isWaiting: Bool {
            condition.lock(); defer { condition.unlock() }
            return entered && !released
        }
        var imageIsAlive: Bool {
            condition.lock(); defer { condition.unlock() }; return observedImage != nil
        }
        var callCounts: (Int, Int) {
            condition.lock(); defer { condition.unlock() }; return (loadingCalls, renderingCalls)
        }
        func didLoad() { condition.lock(); loadingCalls += 1; condition.unlock() }
        func didRender() { condition.lock(); renderingCalls += 1; condition.unlock() }
        func pause(holding image: CGImage) throws {
            condition.lock()
            observedImage = image; entered = true
            let deadline = Date(timeIntervalSinceNow: 10)
            while !released {
                if !condition.wait(until: deadline) && !released {
                    condition.unlock()
                    throw Failure(description: "Actual annotation worker gate timed out")
                }
            }
            condition.unlock()
        }
        func release() {
            condition.lock(); released = true; condition.broadcast(); condition.unlock()
        }
    }

    @MainActor
    final class AnnotationNativeReference {
        weak var native: NativeCaptureInterface?
        func available() -> Bool { native?.validateCaptureEnvironment() == true }
    }

    @MainActor
    static func testRealAnnotationWorkerRoutes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneClip-EnvironmentAnnotation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        var workersJoined = true
        defer { if workersJoined { try? FileManager.default.removeItem(at: root) } }
        let png = try M0ImageComposer.compose(assets: [M0ImageFixture.make(index: 2, width: 640, height: 360)]).pngData
        func metadata(_ url: URL) -> stat? {
            var info = stat()
            return Darwin.lstat(url.path, &info) == 0 ? info : nil
        }
        var cases = 0
        for event in CaptureEnvironmentEvent.allCases {
            for rendering in [false, true] {
                let archive = CaptureArchive(directory: root.appendingPathComponent("trial-\(cases + 1)", isDirectory: true))
                let source = try archive.save(png) // Fabricated source only; no general board or capture.
                guard let sourceAtCreation = metadata(source),
                      sourceAtCreation.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                      sourceAtCreation.st_uid == geteuid(), sourceAtCreation.st_nlink == 1 else {
                    throw Failure(description: "ANNOTATION_FABRICATED_SOURCE_IDENTITY_UNAVAILABLE")
                }
                // Pin the original inode/device internally before any worker or event. These
                // raw metadata values are never logged; later checks compare to this baseline.
                let trace = CaptureSecurityTrace(enabled: true, trial: UInt32(cases + 1))
                let results = CaptureResultController(archive: archive, previewsEnabled: false, securityTrace: trace)
                let writer = Writer()
                let gate = RealAnnotationGate()
                let outputLifetime = RealResultPNGLifetime()
                let environment = AnnotationNativeReference()
                let controller = CaptureAnnotationController(results: results, clipboard: writer, showsWindow: false,
                    environmentCheck: { environment.available() }, securityTrace: trace,
                    loader: { url, limits, extra in
                        gate.didLoad()
                        let asset = try CaptureAnnotationRenderer.load(from: url, limits: limits, retainingExtraBytes: extra)
                        if !rendering { try gate.pause(holding: asset.image) }
                        return asset
                    }, renderer: { asset, notes, limits, extra in
                        gate.didRender()
                        let rendered = try CaptureAnnotationRenderer.render(image: asset.image, annotations: notes,
                            limits: limits, retainingExtraBytes: extra)
                        // Test-only immutable copy makes actual PNG backing release observable.
                        // This is not a claim that the production renderer makes this extra copy.
                        let tracked = trackedResultPNG(rendered.pngData, lifetime: outputLifetime)
                        let output = M0CompositionResult(image: rendered.image, pngData: tracked,
                            plan: rendered.plan, actualImageBytes: rendered.actualImageBytes)
                        try gate.pause(holding: output.image)
                        return output
                    })
                let h = try Harness(actualResult: results, actualAnnotation: controller)
                environment.native = h.native
                do {
                    workersJoined = false
                    try expect(controller.open(source), "Actual annotation load was not admitted")
                    if rendering {
                        await controller.waitForWorker()
                        try expect(controller.isOpen && controller.image != nil && !controller.isWorking,
                                   "Actual annotation load did not establish the render input")
                        controller.tool = .rectangle
                        controller.gesture(from: CGPoint(x: 0.15, y: 0.15), to: CGPoint(x: 0.8, y: 0.75))
                        controller.tool = .comment
                        controller.gesture(from: CGPoint(x: 0.2, y: 0.2), to: CGPoint(x: 0.2, y: 0.2))
                        controller.commentDraft = "SYNTHETIC NOTE"
                        controller.applyComment()
                        try expect(controller.annotations.count == 2 && !controller.commentDraft.isEmpty,
                                   "Actual annotation render had no note/draft ownership to invalidate")
                        controller.saveAndCopy()
                    }
                    try await waitForRealResult { gate.isWaiting }
                    let heldAtGate = controller.retainedImageBytes
                    try expect(controller.isWorking && controller.blocksCapture && heldAtGate > 0
                               && gate.imageIsAlive && h.native.captureEntryBlocked && h.native.collectionCopyBlocked,
                               "Actual annotation worker lease or native admission fence was not established")
                    if rendering {
                        try expect(!outputLifetime.isReleased, "Gated flattened PNG backing was released before worker return")
                    }
                    let singleSelections = h.singleUI.selectionCalls, collectionSelections = h.collectionUI.selectionCalls
                    let callsAtGate = gate.callCounts
                    h.emit(event)
                    try expect(!controller.isOpen && controller.isWorking && controller.blocksCapture
                               && controller.image == nil && controller.annotations.isEmpty && controller.commentDraft.isEmpty
                               && controller.pendingCommentPoint == nil && controller.selectedID == nil
                               && !controller.canUndo && !controller.canRedo && !controller.canExport
                               && controller.retainedImageBytes >= heldAtGate && gate.imageIsAlive
                               && h.native.captureEntryBlocked && h.native.collectionCopyBlocked,
                               "Native annotation invalidation retained document pixels or released its actual worker lease")
                    if rendering {
                        try expect(!outputLifetime.isReleased, "Native invalidation freed a flattened PNG still borrowed by its worker")
                    }
                    try expect(!controller.open(source), "A new annotation load overlapped an invalidated actual worker")
                    controller.show(); controller.saveAndCopy(); controller.undo(); controller.redo()
                    controller.recordImageDraw() // A stale draw attempt must not become display evidence.
                    h.single.begin(); h.collection.beginNewSession()
                    try expect(gate.callCounts == callsAtGate && writer.calls == 0
                               && h.singleUI.selectionCalls == singleSelections && h.collectionUI.selectionCalls == collectionSelections
                               && !results.isSaving && !results.hasPendingSave,
                               "An invalidated annotation consumer started new work, copied or saved")
                    gate.release()
                    await controller.waitForWorker()
                    try await waitForRealResult {
                        !controller.isWorking && !gate.imageIsAlive && (!rendering || outputLifetime.isReleased)
                    }
                    workersJoined = true
                    try expect(!controller.blocksCapture && controller.retainedImageBytes == 0
                               && controller.image == nil && controller.annotations.isEmpty
                               && !h.native.captureEntryBlocked && !h.native.collectionCopyBlocked
                               && writer.calls == 0 && !results.isSaving && !results.hasPendingSave && results.latestURL == nil,
                               "Actual annotation return revived old output, retained capacity or kept the native gate")
                    let snapshot = trace.snapshot()
                    guard let invalidation = snapshot.entries.first(where: { $0.code == .annotationInvalidated }),
                          let returned = snapshot.entries.last(where: { $0.code == .workerReturned && $0.mode == .annotation }) else {
                        throw Failure(description: "Actual annotation invalidation/return evidence was incomplete")
                    }
                    try expect(snapshot.droppedCount == 0 && invalidation.sequence < returned.sequence,
                               "Actual annotation worker return was not observed after native invalidation")
                    try expect(!snapshot.entries.contains { $0.sequence > invalidation.sequence
                               && ($0.code == .annotationResultAdopted || $0.code == .clipboardWrite
                                   || $0.code == .clipboardOutcome || $0.code == .archiveQueued || $0.code == .archiveStarted
                                   || $0.code == .resultReceived) }
                               && !snapshot.entries.contains { [.annotationViewShown, .annotationViewDraw, .annotationViewHidden,
                                                                 .resultPreviewShown, .resultPreviewDraw].contains($0.code) },
                               "An invalidated actual annotation worker adopted/copied/saved or claimed real view evidence")
                    let files = try FileManager.default.contentsOfDirectory(at: archive.directory, includingPropertiesForKeys: nil)
                    let sourceAfterInvalidation = try Data(contentsOf: source)
                    let oneFile = files.count == 1
                    let exactURLMatch = oneFile && files[0] == source
                    let standardizedURLMatch = oneFile && files[0].standardizedFileURL == source.standardizedFileURL
                    let pathMatch = oneFile && files[0].path == source.path
                    let canonicalMatch = oneFile && (files[0].resolvingSymlinksInPath().standardizedFileURL
                        == source.resolvingSymlinksInPath().standardizedFileURL)
                    let canonicalPathMatch = oneFile && (files[0].resolvingSymlinksInPath().standardizedFileURL.path
                        == source.resolvingSymlinksInPath().standardizedFileURL.path)
                    let sourceInfo = metadata(source)
                    let listedInfo = oneFile ? metadata(files[0]) : nil
                    let sameFileObject = sourceInfo.flatMap { expected in
                        listedInfo.map { expected.st_dev == $0.st_dev && expected.st_ino == $0.st_ino }
                    } ?? false
                    let sourceRegular = sourceInfo.map { $0.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) } ?? false
                    let listedRegular = listedInfo.map { $0.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) } ?? false
                    let uniqueOwnedSource = sourceInfo.map { $0.st_nlink == 1 && $0.st_uid == geteuid() } ?? false
                    let listedUniqueOwnedSource = listedInfo.map { $0.st_nlink == 1 && $0.st_uid == geteuid() } ?? false
                    let sourceMatchesOriginal = sourceInfo.map {
                        $0.st_dev == sourceAtCreation.st_dev && $0.st_ino == sourceAtCreation.st_ino
                    } ?? false
                    let listedMatchesOriginal = listedInfo.map {
                        $0.st_dev == sourceAtCreation.st_dev && $0.st_ino == sourceAtCreation.st_ino
                    } ?? false
                    let sourceBytesMatch = sourceAfterInvalidation == png
                    let allPNG = files.allSatisfy { $0.pathExtension.lowercased() == "png" }
                    let listedURLHasBase = oneFile && files[0].baseURL != nil
                    let sourceURLHasBase = source.baseURL != nil
                    let routeIndex = (CaptureEnvironmentEvent.allCases.firstIndex(of: event) ?? -1) + 1
                    // Write synchronously: top-level test failure may otherwise lose buffered print.
                    // All fields are fixed classifications/counts; no URL, filename, hash or pixels.
                    let diagnostic = "ENV_ANNOTATION_PERSISTENCE routeIndex=\(routeIndex) phaseIndex=\(rendering ? 2 : 1) caseIndex=\(cases + 1) fileCount=\(files.count) expectedFileCount=1 exactURLMatch=\(exactURLMatch ? 1 : 0) standardizedURLMatch=\(standardizedURLMatch ? 1 : 0) pathMatch=\(pathMatch ? 1 : 0) canonicalMatch=\(canonicalMatch ? 1 : 0) canonicalPathMatch=\(canonicalPathMatch ? 1 : 0) sameFileObject=\(sameFileObject ? 1 : 0) sourceRegular=\(sourceRegular ? 1 : 0) listedRegular=\(listedRegular ? 1 : 0) uniqueOwnedSource=\(uniqueOwnedSource ? 1 : 0) listedUniqueOwnedSource=\(listedUniqueOwnedSource ? 1 : 0) sourceMatchesOriginal=\(sourceMatchesOriginal ? 1 : 0) listedMatchesOriginal=\(listedMatchesOriginal ? 1 : 0) sourceBytesMatch=\(sourceBytesMatch ? 1 : 0) allPNG=\(allPNG ? 1 : 0) listedURLHasBase=\(listedURLHasBase ? 1 : 0) sourceURLHasBase=\(sourceURLHasBase ? 1 : 0)\n"
                    FileHandle.standardOutput.write(Data(diagnostic.utf8))
                    try expect(oneFile, "ANNOTATION_OBSOLETE_EXPORT_FILE_COUNT_FAILED")
                    try expect(sourceRegular && listedRegular && uniqueOwnedSource && listedUniqueOwnedSource,
                               "ANNOTATION_OBSOLETE_EXPORT_SOURCE_NOT_OWNED_REGULAR")
                    // Foundation's directory listing can spell the same /var object through a
                    // different URL representation. Require canonical path plus original file
                    // identity, rather than URL value equality; retain that difference above.
                    try expect(canonicalPathMatch && sameFileObject && sourceMatchesOriginal && listedMatchesOriginal,
                               "ANNOTATION_OBSOLETE_EXPORT_SOURCE_IDENTITY_CHANGED")
                    try expect(sourceBytesMatch, "ANNOTATION_OBSOLETE_EXPORT_SOURCE_PNG_CHANGED")
                    for _ in 0..<3 { await Task.yield() }
                    try expect(!controller.isOpen && gate.callCounts == callsAtGate,
                               "Actual annotation return automatically reopened or rerendered a document")
                    try expect(h.native.prepareCaptureEnvironment(), "Explicit annotation recovery could not refresh its private monitors")
                    workersJoined = false
                    try expect(controller.open(source), "A fresh explicit annotation open failed after actual worker return")
                    await controller.waitForWorker()
                    workersJoined = true
                    try expect(controller.isOpen && controller.image != nil && !controller.isWorking
                               && writer.calls == 0 && !results.isSaving && !results.hasPendingSave,
                               "Explicit annotation recovery failed or copied/saved automatically")
                    controller.invalidate()
                    results.environmentDidChange()
                    await h.close()
                } catch {
                    gate.release(); controller.invalidate(); results.environmentDidChange()
                    await controller.waitForWorker()
                    workersJoined = !controller.isWorking && !results.isSaving
                    await h.close()
                    throw error
                }
                cases += 1
            }
        }
        try expect(cases == 18, "Missing native annotation load/render route combinations")
        print("PASS ENV actualAnnotationRoutes=18 realFDLoad=1 realRender=1 trackedPNGCopy=1 actualWorkerGate=1 realOSTransition=0 displayedWindow=0")
    }

    @MainActor
    static func testStoppedConfiguration() async throws {
        try await withHarness(startMonitoring: false) { h in
            h.native.collectionExpanded = true; h.native.collectionExpanded = false
            h.native.collectionConfirmationPending = true; h.native.collectionConfirmationPending = false
            h.native.rememberExternalApplication(); h.native.rememberCollectionOrigin()
            h.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
            try expect(h.cg.registrations == 0 && h.sc.registrations == 0
                       && h.trace.snapshot().entries.isEmpty, "Stopped diagnostic configuration began monitoring")
        }
    }
}
