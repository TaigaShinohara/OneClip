import AppKit
import Foundation

/// Real product NSPanel/SwiftUI/image consumers, fabricated images and services only.
/// No SCK, screen read, pasteboard, permission API, input delivery, live monitor or VoiceOver.
@main
struct CaptureViewSecurityTests {
    struct Failure: Error { let code: String }
    struct Unavailable: Error { let code: String }
    enum Presentation: CaseIterable { case normal, actualPixels, hidden }
    enum ForegroundCheckpoint: String {
        case afterLaunch, beforeHarness, beforePanelShow, afterPanelShow, afterDraw, afterHide
        case afterInvalidation, afterNoticeShow, afterNoticeDraw, afterSheetPresentation
        case afterSheetEnd, afterFreshSession, afterCleanup
    }
    @MainActor private static var lastStableCheckpoint = ForegroundCheckpoint.afterLaunch

    @MainActor
    static func main() async {
        let originalFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let application = NSApplication.shared
        guard application.setActivationPolicy(.accessory), !NSScreen.screens.isEmpty else {
            print("NOT_ESTABLISHED VIEW_INTERACTIVE_WINDOWSERVER_REQUIRED"); exit(2)
        }
        application.finishLaunching()
        do {
            try verifyFrontmost(originalFrontmost, at: .afterLaunch)
            try await retainedMatrix(originalFrontmost: originalFrontmost)
            try await staleSheetResponse(originalFrontmost: originalFrontmost)
            CollectionPanelController.shared.hide()
            try verifyFrontmost(originalFrontmost, at: .afterCleanup)
            print("PASS VIEW_SECURITY matrixCases=162 sheetRace=1 realProductView=1 syntheticData=1 realOSTransition=0")
        } catch let error as Unavailable {
            CollectionPanelController.shared.hide()
            print("NOT_ESTABLISHED \(error.code)"); exit(2)
        } catch let error as Failure {
            CollectionPanelController.shared.hide()
            print("FAIL \(error.code)"); exit(1)
        } catch {
            CollectionPanelController.shared.hide()
            print("FAIL VIEW_UNEXPECTED"); exit(1)
        }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ code: String) throws {
        guard condition() else { throw Failure(code: code) }
    }
    @MainActor
    static func verifyFrontmost(_ original: Int32?, at checkpoint: ForegroundCheckpoint,
                                trace: CaptureSecurityTrace? = nil) throws {
        let current = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let classification: String
        if let original, let current, original == current { classification = "original" }
        else if current == ProcessInfo.processInfo.processIdentifier { classification = "test_process" }
        else if current == nil || original == nil { classification = "unknown" }
        else { classification = "other" }
        guard classification == "original" else {
            let entry = trace?.snapshot().entries.last
            print("VIEW_FOREGROUND firstChangeAfter=\(lastStableCheckpoint.rawValue) observedAt=\(checkpoint.rawValue) class=\(classification) lastSequence=\(entry?.sequence ?? 0) lastCode=\(entry?.code.rawValue ?? "none")")
            throw Unavailable(code: "VIEW_FRONTMOST_CHANGED_OR_UNKNOWN")
        }
        lastStableCheckpoint = checkpoint
    }
    @MainActor
    static func pump() { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    @MainActor
    static func settle(_ passes: Int = 4) async {
        for _ in 0..<passes {
            pump()
            CollectionPanelController.shared.diagnosticDisplayIfNeeded()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    final class Selector: CollectionCaptureInterface {
        weak var native: NativeCaptureInterface?
        var selected: (@MainActor (CaptureSelection) -> Void)?
        var isOneClipActive: Bool { false }
        var captureEntryBlocked: Bool { native?.captureEntryBlocked ?? true }
        var collectionCopyBlocked: Bool { native?.collectionCopyBlocked ?? true }
        var captureEnvironmentStatus: String { "Synthetic view environment unavailable" }
        func prepareCaptureEnvironment() -> Bool { native?.prepareCaptureEnvironment() == true }
        func validateCaptureEnvironment() -> Bool { native?.validateCaptureEnvironment() == true }
        func prepareForSelection() -> Bool { true }
        func showSelection(on display: CaptureDisplaySnapshot, selected: @escaping @MainActor (CaptureSelection) -> Void,
                           cancelled: @escaping @MainActor () -> Void) { self.selected = selected }
        func hideSelection() -> Bool { selected = nil; return true }
        func showCollection(activate: Bool) { native?.showCollection(activate: false) }
        func hideCollection() { native?.hideCollection() }
        func showCollectionGuide(started: @escaping @MainActor () -> Void, cancelled: @escaping @MainActor () -> Void) { started() }
        func showCollectionPermission() {}
        func showPermission() {}
        func hidePermission() {}
        func showProblem(activate: Bool) {}
        func hideProblem() {}
        func showFeedback(_ message: String) {}
        func dismissAll() { selected = nil; native?.hideCollection() }
        func dismissCollectionUI() { selected = nil; native?.dismissCollectionUI() }
        func rememberExternalApplication() {}
        func returnToExternalApplication() {}
    }

    @MainActor
    final class Writer: CaptureClipboardWriting {
        var changeCount = 0
        var calls = 0
        func writePNG(_ data: Data, expectedChangeCount: Int) -> M0ClipboardProbe.Outcome {
            calls += 1; changeCount += 1
            return .init(code: .writeAccepted, expectedChangeCount: expectedChangeCount,
                         observedChangeCount: changeCount, preparedChangeCount: changeCount)
        }
    }
    @MainActor
    final class Capturer: ScreenshotCapturing {
        private var index = 1
        func capture(_ request: SingleCaptureRequest, isCurrent: @escaping @MainActor () -> Bool) async throws -> M0ImageAsset {
            defer { index += 1 }
            return try M0ImageFixture.make(index: index, width: 64, height: 48)
        }
    }

    @MainActor
    final class Harness {
        let trace: CaptureSecurityTrace
        let native: NativeCaptureInterface
        let selector: Selector
        let writer: Writer
        let coordinator: CollectionCaptureCoordinator
        let selection: CaptureSelection

        init() throws {
            let trace = CaptureSecurityTrace(enabled: true, trial: 1)
            let native = NativeCaptureInterface(environmentSources: .init(workspace: NotificationCenter(), application: NotificationCenter()),
                sessionBackend: .init(registerDispatch: { _ in .init(token: 11, succeeded: true) },
                    registerCheck: { .init(token: 12, succeeded: true) }, check: { _ in .unchanged }, cancel: { _ in true },
                    session: { .init(onConsole: true, loginDone: true, userID: 501) }, ownUserID: { 501 }),
                consoleBackend: .init(register: { _ in .init(token: UUID(), succeeded: true) }, check: { _ in .unchanged },
                    cancel: { _ in true }, consoleUserID: { 501 }, ownUserID: { 501 }), securityTrace: trace)
            let selector = Selector(), writer = Writer()
            selector.native = native
            let display = try CaptureDisplaySnapshot(id: 91, frame: CGRect(x: 0, y: 0, width: 640, height: 480), scale: 1)
            let selection = try CaptureSelection(display: display, rect: CGRect(x: 20, y: 20, width: 64, height: 48))
            let preferences = CapturePreferences(defaults: nil, hasSeenCaptureGuide: true, hasSeenPasteHint: true, hasSeenCollectionGuide: true)
            let coordinator = CollectionCaptureCoordinator(capturer: Capturer(), interface: selector, clipboard: writer,
                workSlot: CaptureWorkerSlot(), preferences: preferences, securityTrace: trace,
                permissionCheck: { true }, permissionRequest: { false }, protectedDataCheck: { true }, displayAtPointer: { display })
            native.collectionCoordinator = coordinator
            self.trace = trace; self.native = native; self.selector = selector; self.writer = writer
            self.coordinator = coordinator; self.selection = selection
        }

        func select() throws {
            guard let selected = selector.selected else { throw Failure(code: "VIEW_SELECTION_MISSING") }
            selected(selection)
        }
        func add() async throws {
            coordinator.beginOrAdd(); try select(); await coordinator.waitForWorker()
        }
        func close() async {
            coordinator.stop(); native.stopEnvironmentMonitoring(); CollectionPanelController.shared.hide()
            await coordinator.waitForWorker()
            await settle(2)
        }
    }

    @MainActor
    static func withHarness(originalFrontmost: Int32?, _ body: @MainActor (Harness) async throws -> Void) async throws {
        try verifyFrontmost(originalFrontmost, at: .beforeHarness)
        let h = try Harness()
        do { try await body(h) }
        catch { await h.close(); throw error }
        await h.close()
        try verifyFrontmost(originalFrontmost, at: .afterCleanup, trace: h.trace)
    }

    @MainActor
    static func retainedMatrix(originalFrontmost: Int32?) async throws {
        var cases = 0
        for event in CaptureEnvironmentEvent.allCases {
            for copyState in 0..<3 {
                for candidate in [false, true] {
                    for presentation in Presentation.allCases {
                        try await withHarness(originalFrontmost: originalFrontmost) { h in
                            try await h.add()
                            if copyState > 0 { h.coordinator.copy(); await h.coordinator.waitForWorker() }
                            if copyState == 2 { try await h.add() }
                            if candidate {
                                h.coordinator.replace(at: 0); try h.select(); await h.coordinator.waitForWorker()
                                try expect(h.coordinator.pendingReplacement != nil, "VIEW_CANDIDATE_PRECONDITION")
                            }
                            if presentation == .actualPixels {
                                if candidate { h.coordinator.replacementActualPixels = true }
                                else { h.coordinator.previewExpanded = true; h.coordinator.previewActualPixels = true }
                            }
                            try verifyFrontmost(originalFrontmost, at: .beforePanelShow, trace: h.trace)
                            h.native.showCollection(activate: false)
                            try verifyFrontmost(originalFrontmost, at: .afterPanelShow, trace: h.trace)
                            for _ in 0..<20 {
                                await settle(1)
                                if h.trace.snapshot().entries.contains(where: { $0.code == .viewDraw }) { break }
                            }
                            try verifyFrontmost(originalFrontmost, at: .afterDraw, trace: h.trace)
                            guard h.trace.snapshot().entries.contains(where: { $0.code == .viewDraw }) else {
                                throw Unavailable(code: "VIEW_DRAW_NOT_ESTABLISHED")
                            }
                            try expect(CollectionPanelController.shared.diagnosticPresentationIsVisible
                                       && CollectionPanelController.shared.diagnosticHasContent, "VIEW_SHOW_DID_NOT_ATTACH_CONTENT")
                            if presentation == .hidden {
                                CollectionPanelController.shared.closePanel()
                                try verifyFrontmost(originalFrontmost, at: .afterHide, trace: h.trace)
                                try expect(!CollectionPanelController.shared.diagnosticPresentationIsVisible
                                           && !CollectionPanelController.shared.diagnosticHasContent
                                           && h.coordinator.hasRetainedImages, "VIEW_CLOSE_DID_NOT_PRESERVE_HIDDEN_DRAFT")
                                try expect((h.coordinator.pendingReplacement != nil) == candidate, "VIEW_CLOSE_DROPPED_CANDIDATE")
                            }
                            let pendingID = h.coordinator.pendingReplacement?.id
                            let writes = h.writer.calls
                            h.native.environmentDidChange(event)
                            try verifyFrontmost(originalFrontmost, at: .afterInvalidation, trace: h.trace)
                            try expect(!CollectionPanelController.shared.diagnosticPresentationIsVisible
                                       && !CollectionPanelController.shared.diagnosticHasContent
                                       && h.coordinator.assets.isEmpty && h.coordinator.pendingReplacement == nil,
                                       "VIEW_INVALIDATION_RETAINED_PRESENTATION_OR_SOURCE")
                            let invalidation = h.trace.snapshot().entries.last(where: { $0.code == .operationInvalidated && $0.mode == .collection })!.sequence
                            await settle()
                            if let pendingID { h.coordinator.acceptReplacement(id: pendingID) }
                            h.coordinator.copy()
                            // Reopening an invalidation notice is allowed, but it contains no image.
                            h.coordinator.showPanel()
                            try verifyFrontmost(originalFrontmost, at: .afterNoticeShow, trace: h.trace)
                            await settle()
                            try expect(h.coordinator.assets.isEmpty && h.writer.calls == writes, "VIEW_OLD_CONSUMER_REVIVED_SOURCE_OR_WRITE")
                            try expect(!h.trace.snapshot().entries.contains {
                                $0.sequence > invalidation && $0.mode == .collection
                                    && [.viewDraw, .resultAdopted, .clipboardWrite].contains($0.code)
                            }, "VIEW_OLD_IMAGE_DREW_OR_ADOPTED_AFTER_INVALIDATION")
                            try expect(h.trace.snapshot().droppedCount == 0, "VIEW_TRACE_OVERFLOW")
                            try verifyFrontmost(originalFrontmost, at: .afterNoticeDraw, trace: h.trace)
                        }
                        cases += 1
                    }
                }
            }
            print("PASS VIEW_EVENT_MATRIX completedCases=\(cases)")
        }
        try expect(cases == 162, "VIEW_MATRIX_INCOMPLETE")
    }

    @MainActor
    static func staleSheetResponse(originalFrontmost: Int32?) async throws {
        try await withHarness(originalFrontmost: originalFrontmost) { h in
            try await h.add(); await settle()
            guard let id = h.coordinator.items.first?.id else { throw Failure(code: "VIEW_DELETE_SOURCE_MISSING") }
            var responses: [Bool] = []
            CollectionPanelController.shared.requestDelete(assetID: id) { responses.append($0) }
            await settle()
            guard let sheet = NSApp.windows.first(where: { $0.sheetParent != nil }), let parent = sheet.sheetParent else {
                throw Unavailable(code: "VIEW_SHEET_NOT_ESTABLISHED")
            }
            try verifyFrontmost(originalFrontmost, at: .afterSheetPresentation, trace: h.trace)
            // Queue the actual AppKit completion, invalidate before its MainActor Task consumes it,
            // then create a fresh session. No old answer may target that session's new asset.
            parent.endSheet(sheet, returnCode: .OK)
            try verifyFrontmost(originalFrontmost, at: .afterSheetEnd, trace: h.trace)
            h.native.environmentDidChange(.systemSleep)
            try verifyFrontmost(originalFrontmost, at: .afterInvalidation, trace: h.trace)
            try expect(!h.native.collectionConfirmationPending && !CollectionPanelController.shared.diagnosticHasContent,
                       "VIEW_INVALIDATION_LEFT_SHEET_GATE_OR_CONTENT")
            h.coordinator.beginNewSession(); try h.select(); await h.coordinator.waitForWorker(); await settle()
            try expect(h.coordinator.assets.count == 1 && !responses.contains(true) && h.writer.calls == 0,
                       "VIEW_STALE_SHEET_APPLIED_TO_FRESH_SESSION")
            try verifyFrontmost(originalFrontmost, at: .afterFreshSession, trace: h.trace)
        }
    }
}
