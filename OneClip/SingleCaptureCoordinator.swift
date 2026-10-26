import AppKit
import Combine
import Foundation

enum SingleCapturePhase: String {
    case idle, onboarding, permission, selecting, capturing, encoding, writing, failure, cancelling
}

/// Availability signals, not a claim that every macOS lock path is observable.
enum CaptureEnvironmentEvent: String, CaseIterable {
    case systemSleep = "システムスリープ"
    case displaySleep = "ディスプレイスリープ"
    case sessionResigned = "セッション離脱"
    case displayChanged = "画面構成変更"
    case protectedDataUnavailable = "保護データ利用不可"
    case consoleSessionChanged = "コンソールセッション変更"
    case consoleSessionUnavailable = "コンソールセッション利用不可"
    case consoleUserChanged = "コンソールユーザー変更"
    case consoleUserUnavailable = "コンソールユーザー利用不可"
}

enum CapturePermissionStatus: String {
    case notChecked, notConfirmed, requestUnconfirmed, granted, noLongerAvailable
}

enum SingleCaptureFailureStage: String {
    case selection, capture, encoding, clipboard
}

struct SingleCaptureProblem: Equatable {
    let stage: SingleCaptureFailureStage
    let message: String
    let clipboardMayHaveChanged: Bool

    var title: String {
        switch stage {
        case .selection: return "撮影を始められませんでした"
        case .capture: return "画像を取得できませんでした"
        case .encoding: return "画像を準備できませんでした"
        case .clipboard: return "画像をコピーできませんでした"
        }
    }

    init(stage: SingleCaptureFailureStage = .capture, message: String, clipboardMayHaveChanged: Bool) {
        self.stage = stage
        self.message = message
        self.clipboardMayHaveChanged = clipboardMayHaveChanged
    }
}

@MainActor
protocol SingleCaptureInterface: AnyObject {
    var isOneClipActive: Bool { get }
    var captureEntryBlocked: Bool { get }
    var captureEnvironmentStatus: String { get }
    func prepareCaptureEnvironment() -> Bool
    func validateCaptureEnvironment() -> Bool
    func showCaptureGuide(started: @escaping @MainActor () -> Void,
                          cancelled: @escaping @MainActor () -> Void)
    func hideCaptureGuide()
    func prepareForSelection() -> Bool
    func showSelection(on display: CaptureDisplaySnapshot,
                       selected: @escaping @MainActor (CaptureSelection) -> Void,
                       cancelled: @escaping @MainActor () -> Void)
    func hideSelection() -> Bool
    func showPermission()
    func hidePermission()
    func showProblem(activate: Bool)
    func hideProblem()
    func showFeedback(_ message: String)
    func dismissAll()
    func rememberExternalApplication()
    func returnToExternalApplication()
}

extension SingleCaptureInterface {
    var captureEntryBlocked: Bool { false }
    var captureEnvironmentStatus: String { "利用状態を確認できません。復帰後にもう一度選んでください" }
    func validateCaptureEnvironment() -> Bool { true }
    func prepareCaptureEnvironment() -> Bool { validateCaptureEnvironment() }
    func showCaptureGuide(started: @escaping @MainActor () -> Void,
                          cancelled: @escaping @MainActor () -> Void) { started() }
    func hideCaptureGuide() {}
}

@MainActor
protocol CaptureClipboardWriting {
    var changeCount: Int { get }
    func writePNG(_ data: Data, expectedChangeCount: Int) -> M0ClipboardProbe.Outcome
}

@MainActor
struct GeneralCaptureClipboard: CaptureClipboardWriting {
    var changeCount: Int { NSPasteboard.general.changeCount }
    func writePNG(_ data: Data, expectedChangeCount: Int) -> M0ClipboardProbe.Outcome {
        M0ClipboardProbe.writePNG(data, to: .general, expectedChangeCount: expectedChangeCount)
    }
}

/// Both capture modes hold this permit until their actual worker returns.
@MainActor
final class CaptureWorkerSlot {
    static let shared = CaptureWorkerSlot()
    private var owner: UUID?
    var isOccupied: Bool { owner != nil }
    func acquire(_ identifier: UUID) -> Bool {
        guard owner == nil else { return false }
        owner = identifier
        return true
    }
    func release(_ identifier: UUID) { if owner == identifier { owner = nil } }
}

/// One operation owns the worker slot until capture/encoding really finishes, even after invalidation.
@MainActor
final class SingleCaptureCoordinator: ObservableObject {
    static let shared: SingleCaptureCoordinator = {
        let interface = NativeCaptureInterface.shared
        #if DEBUG
        if M2FailureLab.isEnabled || M3FailureLab.isEnabled {
            let value = M2FailureLab.shared.makeCoordinator(interface: interface)
            interface.coordinator = value
            return value
        }
        #endif
        let value = SingleCaptureCoordinator(capturer: ScreenshotService(), interface: interface)
        interface.coordinator = value
        #if DEBUG
        value.practiceScopeProvider = { [weak interface] display in try interface?.practiceScope(for: display) }
        #endif
        return value
    }()

    @Published private(set) var phase = SingleCapturePhase.idle
    @Published private(set) var statusText = "範囲を選んでコピーできます"
    @Published private(set) var permissionMessage = "選んだ範囲をコピーするために必要です。"
    @Published private(set) var permissionStatus = CapturePermissionStatus.notChecked
    @Published private(set) var problem: SingleCaptureProblem?
    @Published private(set) var isWorking = false

    #if DEBUG
    // Fixed, in-memory test facts only. No screen contents, ranges or event history.
    @Published private(set) var environmentInvalidationCount = 0
    @Published private(set) var lastEnvironmentEvent = "未受信"
    @Published private(set) var invalidatedWhileWorking = false
    @Published private(set) var invalidatedWithImage = false
    var hasRetainedPNG: Bool { retainedPNG != nil }
    #endif

    var hasRetainedImage: Bool { retainedAsset != nil }
    var canBegin: Bool {
        !isWorking && !workSlot.isOccupied && phase != .selecting && phase != .permission && phase != .onboarding
            && !isStopping && !interface.captureEntryBlocked
    }

    private let workSlot: CaptureWorkerSlot
    private let capturer: any ScreenshotCapturing
    private let interface: any SingleCaptureInterface
    private let clipboard: any CaptureClipboardWriting
    private let permissionCheck: @MainActor () -> Bool
    private let permissionRequest: @MainActor () -> Bool
    private let protectedDataCheck: @MainActor () -> Bool
    private let displayAtPointer: @MainActor () throws -> CaptureDisplaySnapshot
    private let encode: @Sendable (M0ImageAsset) async throws -> M0CompositionResult
    private let preferences: CapturePreferences
    private var operationID: UUID?
    private var worker: Task<Void, Never>?
    private var selectionDisplay: CaptureDisplaySnapshot?
    private var retainedAsset: M0ImageAsset?
    private var retainedPNG: Data?
    private var isStopping = false
    private var hasRequestedPermission = false
    private var hasObservedPermission = false
    #if DEBUG
    var practiceScopeProvider: (@MainActor (CaptureDisplaySnapshot) throws -> PracticeCaptureScope?)?
    private var selectedPractice: PracticeCaptureScope?
    #endif

    init(capturer: any ScreenshotCapturing, interface: any SingleCaptureInterface,
         clipboard: any CaptureClipboardWriting = GeneralCaptureClipboard(),
         workSlot: CaptureWorkerSlot = .shared,
         permissionCheck: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
         permissionRequest: @escaping @MainActor () -> Bool = { CGRequestScreenCaptureAccess() },
         protectedDataCheck: @escaping @MainActor () -> Bool = { NSApp.isProtectedDataAvailable },
         displayAtPointer: @escaping @MainActor () throws -> CaptureDisplaySnapshot = {
             let point = NSEvent.mouseLocation
             guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else {
                 throw ScreenshotError.displayChanged
             }
             return try ScreenshotService.snapshot(for: screen)
         },
         preferences: CapturePreferences = .shared,
         encode: @escaping @Sendable (M0ImageAsset) async throws -> M0CompositionResult = { asset in
             try await Task.detached(priority: .userInitiated) {
                 try M0ImageComposer.compose(assets: [asset])
             }.value
         }) {
        self.workSlot = workSlot
        self.capturer = capturer
        self.interface = interface
        self.clipboard = clipboard
        self.permissionCheck = permissionCheck
        self.permissionRequest = permissionRequest
        self.protectedDataCheck = protectedDataCheck
        self.displayAtPointer = displayAtPointer
        self.preferences = preferences
        self.encode = encode
    }

    func begin() {
        guard canBegin else { return }
        guard validateEnvironment(startIfNeeded: true) else { return }
        guard !hasRetainedImage else { interface.showProblem(activate: true); return }
        interface.rememberExternalApplication()
        guard preferences.hasSeenCaptureGuide else {
            let identifier = UUID()
            operationID = identifier
            phase = .onboarding
            statusText = "範囲コピーの使い方を確認してください"
            interface.showCaptureGuide(started: { [weak self] in
                guard let self, self.phase == .onboarding, self.operationID == identifier,
                      !self.isStopping else { return }
                self.interface.hideCaptureGuide()
                self.phase = .idle
                self.operationID = nil
                guard !self.interface.captureEntryBlocked else { return }
                self.preferences.hasSeenCaptureGuide = true
                self.begin()
            }, cancelled: { [weak self] in
                guard self?.phase == .onboarding, self?.operationID == identifier else { return }
                self?.cancel()
            })
            return
        }
        problem = nil
        interface.hideProblem()
        guard protectedDataCheck() else { invalidate(message: "画面を利用できません。解除後にもう一度選んでください。"); return }
        guard observePermission() else {
            permissionMessage = permissionStatus == .noLongerAvailable
                ? "以前の許可を確認できません。システム設定でOneClipを確認してください。"
                : "選んだ範囲をコピーするために必要です。"
            phase = .permission
            statusText = "画面収録の許可を確認してください"
            interface.showPermission()
            return
        }
        guard interface.prepareForSelection() else {
            fail("別の検証処理が終了してから、もう一度選んでください。", stage: .selection)
            return
        }
        do {
            let display = try displayAtPointer()
            #if DEBUG
            selectedPractice = try practiceScopeProvider?(display)
            #endif
            selectionDisplay = display
            let identifier = UUID()
            operationID = identifier
            problem = nil
            phase = .selecting
            statusText = "ドラッグで範囲を選択・Escで取消"
            interface.showSelection(on: display, selected: { [weak self] selection in
                self?.confirm(selection, operationID: identifier)
            }, cancelled: { [weak self] in
                guard self?.operationID == identifier else { return }
                self?.cancel()
            })
        } catch {
            fail("選択する画面を確認できません。画面の内側で、もう一度選んでください。", stage: .selection)
        }
    }

    func requestPermission() {
        guard phase == .permission, !isStopping, !interface.captureEntryBlocked else { return }
        guard validateEnvironment() else { return }
        hasRequestedPermission = true
        _ = permissionRequest() // Only this explicit button can request OS permission.
        permissionMessage = observePermission()
            ? "許可を確認できました。範囲を選べます。"
            : "まだ許可を確認できません。システム設定でOneClipをオンにしてください。"
    }

    func retryPermission() {
        guard phase == .permission, !isStopping, !interface.captureEntryBlocked else { return }
        guard validateEnvironment() else { return }
        guard observePermission() else {
            permissionMessage = "まだ許可を確認できません。設定後にもう一度確認してください。"
            return
        }
        interface.hidePermission()
        phase = .idle
        begin() // This is a new explicit operation, never a permission-change callback.
    }

    func cancel() {
        guard phase != .writing else { return }
        invalidate(message: worker == nil ? "取り消しました。コピーしていません" : "取り消しています…")
        if interface.isOneClipActive { interface.returnToExternalApplication() }
    }

    func invalidate(message: String) {
        operationID = nil
        selectionDisplay = nil
        #if DEBUG
        selectedPractice = nil
        #endif
        worker?.cancel()
        retainedAsset = nil
        retainedPNG = nil
        problem = nil
        phase = worker == nil ? .idle : .cancelling
        statusText = message
        interface.dismissAll()
    }

    func environmentDidChange(_ event: CaptureEnvironmentEvent) {
        #if DEBUG
        environmentInvalidationCount += 1
        lastEnvironmentEvent = event.rawValue
        invalidatedWhileWorking = isWorking
        invalidatedWithImage = hasRetainedImage
        #endif
        invalidate(message: event == .displayChanged
                   ? "画面の構成が変わったため中止しました"
                   : "利用状態が変わったため中止しました")
    }

    func showCurrentProblem() {
        guard validateEnvironment() else { return }
        guard problem != nil else { return }
        interface.showProblem(activate: true)
    }

    func retrySelection() {
        guard !isWorking, !hasRetainedImage, !isStopping, !interface.captureEntryBlocked else { return }
        interface.hideProblem()
        problem = nil
        phase = .idle
        begin()
    }

    func retryCopy() {
        guard !isWorking, !isStopping, !interface.captureEntryBlocked else { return }
        guard validateEnvironment(), let asset = retainedAsset else { return }
        interface.rememberExternalApplication()
        interface.hideProblem()
        let identifier = UUID()
        operationID = identifier
        let expectedCount = clipboard.changeCount
        startWorker(identifier: identifier, expectedCount: expectedCount, existing: asset, request: nil)
    }

    func discard() {
        guard !isWorking else { return }
        invalidate(message: "画像を破棄しました。コピーしていません")
        if interface.isOneClipActive { interface.returnToExternalApplication() }
    }

    func stop() {
        isStopping = true
        invalidate(message: "終了しました")
    }

    /// Freeze adoption before showing a quit confirmation, retaining only an already acquired image.
    func prepareToQuit() {
        guard validateEnvironment() else { return }
        operationID = nil
        selectionDisplay = nil
        #if DEBUG
        selectedPractice = nil
        #endif
        worker?.cancel()
        _ = interface.hideSelection()
        interface.hideCaptureGuide()
        interface.hidePermission()
        if hasRetainedImage {
            phase = .failure
            statusText = "未コピーの画像があります"
            if problem == nil {
                problem = SingleCaptureProblem(stage: .encoding, message: "処理を取り消しました。取得画像を保持しています。", clipboardMayHaveChanged: false)
            }
        } else {
            phase = worker == nil ? .idle : .cancelling
        }
    }

    func waitForWorker() async { await worker?.value }

    private func confirm(_ selection: CaptureSelection, operationID identifier: UUID) {
        guard phase == .selecting, self.operationID == identifier, worker == nil,
              !interface.captureEntryBlocked,
              selection.display == selectionDisplay else { return }
        guard validateEnvironment(), self.operationID == identifier else { return }
        do { _ = try RegionGeometry.plan(selection: selection, filterScale: selection.display.scale) }
        catch { fail("範囲を確認できません。もう一度選んでください。", stage: .selection); return }
        guard interface.hideSelection() else {
            fail("選択画面を閉じられませんでした。撮影せずに中止しました。", stage: .selection)
            return
        }
        #if DEBUG
        let request = SingleCaptureRequest(selection: selection, operationID: identifier, practice: selectedPractice)
        #else
        let request = SingleCaptureRequest(selection: selection, operationID: identifier)
        #endif
        let expectedCount = clipboard.changeCount
        startWorker(identifier: identifier, expectedCount: expectedCount, existing: nil, request: request)
    }

    private func startWorker(identifier: UUID, expectedCount: Int, existing: M0ImageAsset?, request: SingleCaptureRequest?) {
        guard worker == nil, workSlot.acquire(identifier) else { return }
        isWorking = true
        problem = nil
        phase = existing == nil ? .capturing : .encoding
        statusText = existing == nil ? "画像を取得しています…" : "画像を準備しています…"
        worker = Task { [weak self, workSlot] in
            defer { workSlot.release(identifier) }
            guard let self else { return }
            defer {
                self.worker = nil
                self.isWorking = false
                if self.phase == .cancelling {
                    self.phase = .idle
                    if self.statusText == "取り消しています…" { self.statusText = "取り消しました。コピーしていません" }
                }
            }
            do {
                try self.checkCurrent(identifier)
                let asset: M0ImageAsset
                if let existing { asset = existing }
                else if let request {
                    asset = try await self.capturer.capture(request, isCurrent: { [weak self] in
                        guard let self, self.operationID == identifier, !self.isStopping else { return false }
                        return self.validateEnvironment() && self.operationID == identifier
                    })
                } else { throw ScreenshotError.invalidSelection }
                try self.checkCurrent(identifier)
                self.retainedAsset = asset
                self.phase = .encoding
                self.statusText = "画像を準備しています…"
                let data: Data
                if let cached = self.retainedPNG, existing != nil { data = cached }
                else {
                    let result = try await self.encode(asset)
                    try self.checkCurrent(identifier)
                    self.retainedPNG = result.pngData
                    data = result.pngData
                }
                try self.checkCurrent(identifier)
                self.phase = .writing
                // No await between the final operation check and the synchronous pasteboard write.
                let result = self.clipboard.writePNG(data, expectedChangeCount: expectedCount)
                if result.writeAccepted {
                    self.retainedAsset = nil
                    self.retainedPNG = nil
                    self.operationID = nil
                    self.selectionDisplay = nil
                    #if DEBUG
                    self.selectedPractice = nil
                    #endif
                    self.phase = .idle
                    self.statusText = "コピーしました"
                    self.interface.hideProblem()
                    let text = self.preferences.hasSeenPasteHint ? "コピーしました" : "コピーしました。Command + Vで貼り付けられます"
                    self.preferences.hasSeenPasteHint = true
                    self.interface.showFeedback(text)
                    if self.interface.isOneClipActive { self.interface.returnToExternalApplication() }
                } else {
                    let conflict = result.code == .conflictBeforePrepare || result.code == .conflictAfterPrepare
                    self.fail(conflict ? "ほかのコピーと重なったため、画像をコピーしませんでした。取得画像は保持しています。"
                                       : "画像をコピーできませんでした。取得画像は保持しています。",
                              clipboardMayHaveChanged: result.prepared, stage: .clipboard)
                }
            } catch {
                guard self.operationID == identifier, !self.isStopping else { return }
                guard self.validateEnvironment(), self.operationID == identifier else { return }
                if !self.protectedDataCheck() {
                    self.invalidate(message: "利用状態が変わったため中止しました。もう一度選んでください。")
                    return
                }
                if !self.observePermission() {
                    self.invalidate(message: "画面収録の許可を確認できなくなったため中止しました。メニューから許可を確認し直してください。")
                    return
                }
                let message: String
                if self.hasRetainedImage {
                    message = "画像の準備ができませんでした。取得画像は保持しています。再コピーを試すか、破棄できます。"
                } else if let failure = error as? ScreenshotError {
                    switch failure {
                    case .practiceUnavailable: message = "練習画面の内側で範囲を選んでください。画面を動かした場合は選び直してください。"
                    case .displayChanged: message = "画面の構成が変わったため取得を中止しました。もう一度選んでください。"
                    case .imageLimitExceeded: message = "画像の大きさが上限を超えます。小さい範囲を選んでください。"
                    default: message = "画像を取得できませんでした。もう一度範囲を選んでください。"
                    }
                } else { message = "画像を取得できませんでした。もう一度範囲を選んでください。" }
                self.fail(message, stage: self.hasRetainedImage ? .encoding : .capture)
            }
        }
    }

    private func checkCurrent(_ identifier: UUID) throws {
        guard operationID == identifier, !isStopping, !Task.isCancelled else { throw ScreenshotError.invalidated }
        guard validateEnvironment(), operationID == identifier else { throw ScreenshotError.invalidated }
        guard protectedDataCheck() else { throw ScreenshotError.protectedDataUnavailable }
        guard observePermission() else { throw ScreenshotError.permissionRequired }
    }

    private func validateEnvironment(startIfNeeded: Bool = false) -> Bool {
        let available = startIfNeeded ? interface.prepareCaptureEnvironment() : interface.validateCaptureEnvironment()
        guard available else {
            // Never turn a session-fence failure into an image-retaining retry problem.
            invalidate(message: interface.captureEnvironmentStatus)
            return false
        }
        return true
    }

    private func observePermission() -> Bool {
        let allowed = permissionCheck()
        if allowed {
            hasObservedPermission = true
            permissionStatus = .granted
        } else if hasObservedPermission {
            permissionStatus = .noLongerAvailable
        } else {
            permissionStatus = hasRequestedPermission ? .requestUnconfirmed : .notConfirmed
        }
        return allowed
    }

    private func fail(_ message: String, clipboardMayHaveChanged: Bool = false,
                      stage: SingleCaptureFailureStage = .capture) {
        _ = interface.hideSelection()
        problem = SingleCaptureProblem(stage: stage, message: message, clipboardMayHaveChanged: clipboardMayHaveChanged)
        phase = .failure
        statusText = hasRetainedImage ? "未コピーの画像があります" : stage == .selection ? "撮影を始められませんでした" : "取得できませんでした"
        interface.showProblem(activate: false)
    }
}
