import AppKit
import Combine
import Foundation

enum CollectionCapturePhase: String {
    case idle, onboarding, permission, ready, selecting, capturing, encoding, writing, cancelling
}

struct CollectionItemMetadata: Identifiable {
    let id: Int
    let width: Int
    let height: Int
    let scale: Double
}

/// A confirmation identifies one revision without retaining any image or completed output.
struct CollectionDeletionTarget: Equatable, Sendable {
    let sessionID: UUID
    let revision: UUID
    let index: Int
}

@MainActor
protocol CollectionCaptureInterface: SingleCaptureInterface {
    func showCollection(activate: Bool)
    func hideCollection()
    func showCollectionGuide(started: @escaping @MainActor () -> Void,
                             cancelled: @escaping @MainActor () -> Void)
    func showCollectionPermission()
}

/// A collection owns its sources; workers borrow immutable references until actual completion.
@MainActor
final class CollectionCaptureCoordinator: ObservableObject {
    static let shared: CollectionCaptureCoordinator = {
        let interface = NativeCaptureInterface.shared
        #if DEBUG
        if M3FailureLab.isEnabled {
            let value = M3FailureLab.shared.makeCoordinator(interface: interface)
            interface.collectionCoordinator = value
            return value
        }
        #endif
        let value = CollectionCaptureCoordinator(capturer: ScreenshotService(), interface: interface)
        interface.collectionCoordinator = value
        #if DEBUG
        value.practiceScopeProvider = { [weak interface] display in try interface?.practiceScope(for: display) }
        #endif
        return value
    }()

    @Published private(set) var phase = CollectionCapturePhase.idle
    @Published private(set) var assets: [M0ImageAsset] = []
    @Published private(set) var completed: M0CompositionResult?
    @Published private(set) var statusText = "必要なところを集めて、一枚にコピーできます"
    @Published private(set) var isWorking = false
    @Published private(set) var replacementIndex: Int?
    @Published private(set) var permissionMessage = "画面収録の許可を確認してください。画像の保存・送信は行いません。"
    private(set) var sessionID: UUID?
    private(set) var revision = UUID()
    var items: [CollectionItemMetadata] {
        assets.enumerated().map { CollectionItemMetadata(id: $0.offset, width: $0.element.image.width,
                                                          height: $0.element.image.height, scale: $0.element.scale) }
    }
    var isActive: Bool { sessionID != nil }
    var hasRetainedImages: Bool { !assets.isEmpty }
    var canEdit: Bool { isActive && phase == .ready && !isWorking && !interface.captureEntryBlocked && !isStopping }
    var canAdd: Bool { canEdit && assets.count < limits.maximumCount && !workSlot.isOccupied }
    var canCopy: Bool { canEdit && !assets.isEmpty && !workSlot.isOccupied }
    var plan: M0CompositionPlan? { try? M0ImageComposer.makePlan(assets: assets, limits: limits) }

    private let capturer: any ScreenshotCapturing
    private let interface: any CollectionCaptureInterface
    private let clipboard: any CaptureClipboardWriting
    private let workSlot: CaptureWorkerSlot
    private let preferences: CapturePreferences
    private let limits: M0ImageLimits
    private let permissionCheck: @MainActor () -> Bool
    private let permissionRequest: @MainActor () -> Bool
    private let protectedDataCheck: @MainActor () -> Bool
    private let displayAtPointer: @MainActor () throws -> CaptureDisplaySnapshot
    private let compose: @Sendable ([M0ImageAsset], M0ImageLimits) async throws -> M0CompositionResult
    private var worker: Task<Void, Never>?
    private var selectionDisplay: CaptureDisplaySnapshot?
    private var isStopping = false
    private var hasAdoptedSource = false
    #if DEBUG
    var practiceScopeProvider: (@MainActor (CaptureDisplaySnapshot) throws -> PracticeCaptureScope?)?
    private var selectedPractice: PracticeCaptureScope?
    #endif

    init(capturer: any ScreenshotCapturing, interface: any CollectionCaptureInterface,
         clipboard: any CaptureClipboardWriting = GeneralCaptureClipboard(),
         workSlot: CaptureWorkerSlot = .shared, preferences: CapturePreferences = .shared,
         limits: M0ImageLimits = .init(),
         permissionCheck: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
         permissionRequest: @escaping @MainActor () -> Bool = { CGRequestScreenCaptureAccess() },
         protectedDataCheck: @escaping @MainActor () -> Bool = { NSApp.isProtectedDataAvailable },
         displayAtPointer: @escaping @MainActor () throws -> CaptureDisplaySnapshot = {
             guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) else {
                 throw ScreenshotError.displayChanged
             }
             return try ScreenshotService.snapshot(for: screen)
         },
         compose: @escaping @Sendable ([M0ImageAsset], M0ImageLimits) async throws -> M0CompositionResult = { assets, limits in
             try await Task.detached(priority: .userInitiated) {
                 try M0ImageComposer.compose(assets: assets, limits: limits)
             }.value
         }) {
        self.capturer = capturer; self.interface = interface; self.clipboard = clipboard
        self.workSlot = workSlot; self.preferences = preferences; self.limits = limits
        self.permissionCheck = permissionCheck; self.permissionRequest = permissionRequest
        self.protectedDataCheck = protectedDataCheck; self.displayAtPointer = displayAtPointer
        self.compose = compose
    }

    /// Menu and collection key add; the single key only reveals the current panel.
    func beginOrAdd() {
        beginOrAdd(rememberOrigin: true)
    }

    private func beginOrAdd(rememberOrigin: Bool) {
        #if DEBUG
        if M2FailureLab.isEnabled { return }
        #endif
        guard !isStopping, !interface.captureEntryBlocked, !isWorking, !workSlot.isOccupied else { return }
        guard environmentAvailable(start: true) else { return }
        if !isActive { sessionID = UUID(); revision = UUID(); phase = .ready }
        if rememberOrigin { interface.rememberExternalApplication() }
        if !preferences.hasSeenCollectionGuide {
            let token = revision
            phase = .onboarding
            interface.showCollectionGuide(started: { [weak self] in
                guard let self, self.revision == token, self.phase == .onboarding else { return }
                self.interface.hideCaptureGuide()
                self.preferences.hasSeenCollectionGuide = true
                self.phase = .ready
                self.beginOrAdd(rememberOrigin: false)
            }, cancelled: { [weak self] in
                guard self?.revision == token else { return }
                self?.discard()
            })
            return
        }
        guard phase == .ready else { return }
        guard assets.count < limits.maximumCount else {
            statusText = "4枚まで集められます。追加するには素材を削除するか、取り直してください"
            interface.showCollection(activate: true)
            return
        }
        select(replacing: nil)
    }

    func showPanel() {
        guard isActive, environmentAvailable() else { return }
        guard permissionCheck(), protectedDataCheck() else { invalidate(message: "利用状態が変わったため素材を破棄しました"); return }
        interface.showCollection(activate: true)
    }

    func replace(at index: Int) {
        guard canEdit, assets.indices.contains(index), !workSlot.isOccupied else { return }
        interface.rememberExternalApplication()
        select(replacing: index)
    }

    private func select(replacing index: Int?) {
        guard environmentAvailable() else { return }
        guard permissionCheck() else {
            // Never retain existing sources after a permission loss.
            if !assets.isEmpty { invalidate(message: "画面収録の許可を確認できなくなったため、素材を破棄しました"); return }
            phase = .permission
            interface.showCollectionPermission()
            return
        }
        guard protectedDataCheck() else { invalidate(message: "画面を利用できません。解除後に選び直してください"); return }
        completed = nil // Release old output/PNG before acquiring a candidate.
        guard interface.prepareForSelection() else { fail("別の操作が終わってから追加してください"); return }
        do {
            let display = try displayAtPointer()
            #if DEBUG
            selectedPractice = try practiceScopeProvider?(display)
            #endif
            selectionDisplay = display
            replacementIndex = index
            revision = UUID()
            let token = revision
            phase = .selecting
            statusText = index.map { "素材\($0 + 1)を取り直す範囲を選択・Escで旧素材を保持" } ?? "追加する範囲を選択・Escで取消"
            interface.hideCollection()
            interface.showSelection(on: display, selected: { [weak self] selection in
                self?.confirm(selection, token: token)
            }, cancelled: { [weak self] in
                guard self?.revision == token else { return }
                self?.cancelOperation()
            })
        } catch ScreenshotError.displayChanged {
            environmentDidChange(.displayChanged)
        } catch { fail("選択する画面を確認できません。画面の内側で選び直してください") }
    }

    func requestPermission() {
        guard phase == .permission, !isStopping, !interface.captureEntryBlocked, environmentAvailable() else { return }
        _ = permissionRequest()
        permissionMessage = permissionCheck() ? "許可を確認できました。「もう一度試す」で範囲を選べます。"
            : "許可を確認できません。システム設定の画面収録でOneClipを確認してください。再起動が必要な場合もあります。"
    }

    func retryPermission() {
        guard phase == .permission, !interface.captureEntryBlocked, environmentAvailable() else { return }
        guard permissionCheck() else { permissionMessage = "許可後に「もう一度試す」を押してください"; return }
        interface.hidePermission(); phase = .ready; beginOrAdd(rememberOrigin: false)
    }

    private func confirm(_ selection: CaptureSelection, token: UUID) {
        guard phase == .selecting, revision == token, selection.display == selectionDisplay,
              worker == nil, !interface.captureEntryBlocked, environmentAvailable() else { return }
        do {
            let geometry = try RegionGeometry.plan(selection: selection, filterScale: selection.display.scale)
            let (stride, overflow) = geometry.pixelWidth.multipliedReportingOverflow(by: 4)
            guard !overflow else { throw M0ImageError.arithmeticOverflow }
            let budget = CaptureImageBudgetContext(existing: assets.map(\.metrics), replacementIndex: replacementIndex)
            _ = try budget.validateCandidate(M0ImageMetrics(width: geometry.pixelWidth, height: geometry.pixelHeight,
                                                            bytesPerRow: stride, scale: Double(selection.display.scale)), limits: limits)
            let settings = try interface.settingsCaptureScope(for: selection)
            guard interface.hideSelection() else { fail("選択画面を閉じられず、取得を中止しました"); return }
            let identifier = UUID()
            guard workSlot.acquire(identifier) else { fail("前の処理が終わるまで待ってください"); return }
            #if DEBUG
            let request = SingleCaptureRequest(selection: selection, operationID: identifier, budget: budget, settings: settings, practice: selectedPractice)
            #else
            let request = SingleCaptureRequest(selection: selection, operationID: identifier, budget: budget, settings: settings)
            #endif
            let session = sessionID
            let target = replacementIndex
            phase = .capturing; isWorking = true
            statusText = "画像を取得しています…"
            worker = Task { [weak self, workSlot] in
                defer { workSlot.release(identifier) }
                guard let self else { return }
                defer { self.finishWorker(identifier) }
                do {
                    guard self.isCurrent(session: session, token: token), !Task.isCancelled else { return }
                    let candidate = try await self.capturer.capture(request, isCurrent: { [weak self] in
                        self?.isCurrent(session: session, token: token) == true
                    })
                    guard self.isCurrent(session: session, token: token), !Task.isCancelled else { return }
                    if let settings = request.settings, !settings.validate() { throw ScreenshotError.settingsUnavailable }
                    _ = try budget.validateCandidate(candidate.metrics, limits: self.limits)
                    if let target { self.assets[target] = candidate } else { self.assets.append(candidate) }
                    self.hasAdoptedSource = true
                    self.revision = UUID(); self.replacementIndex = nil; self.selectionDisplay = nil
                    self.phase = .ready
                    self.statusText = "\(self.assets.count)/4枚・未コピー"
                    self.interface.showCollection(activate: self.interface.isOneClipActive)
                } catch {
                    guard self.isCurrent(session: session, token: token), !Task.isCancelled else { return }
                    if error as? ScreenshotError == .displayChanged {
                        self.environmentDidChange(.displayChanged)
                        return
                    }
                    self.fail(self.errorMessage(error, fallback: "取得できませんでした。旧素材は保持しています。範囲を選び直してください"))
                }
            }
        } catch { fail(errorMessage(error, fallback: "範囲を確認できません。選び直してください")) }
    }

    func deletionTarget(at index: Int) -> CollectionDeletionTarget? {
        guard canEdit, !workSlot.isOccupied, assets.indices.contains(index), let sessionID else { return nil }
        guard environmentAvailable() else { return nil }
        guard permissionCheck(), protectedDataCheck() else {
            invalidate(message: "利用状態が変わったため素材を破棄しました")
            return nil
        }
        return CollectionDeletionTarget(sessionID: sessionID, revision: revision, index: index)
    }

    @discardableResult
    func delete(_ target: CollectionDeletionTarget) -> Bool {
        guard canEdit, !workSlot.isOccupied, sessionID == target.sessionID,
              revision == target.revision, assets.indices.contains(target.index) else { return false }
        guard environmentAvailable() else { return false }
        guard permissionCheck(), protectedDataCheck() else {
            invalidate(message: "利用状態が変わったため素材を破棄しました")
            return false
        }
        completed = nil; assets.remove(at: target.index); revision = UUID()
        statusText = assets.isEmpty ? "素材はありません。追加できます" : "\(assets.count)/4枚・未コピー"
        return true
    }

    func preparePreview() { encodeAndOptionallyCopy(write: false) }
    func copy() { encodeAndOptionallyCopy(write: true) }

    private func encodeAndOptionallyCopy(write: Bool) {
        guard canCopy, environmentAvailable(), let session = sessionID else { return }
        guard permissionCheck(), protectedDataCheck() else { invalidate(message: "利用状態が変わったため素材を破棄しました"); return }
        interface.rememberExternalApplication()
        let identifier = UUID()
        guard workSlot.acquire(identifier) else { return }
        let token = revision
        let sources = assets // Immutable aliases, not duplicated image buffers.
        let cached = completed
        completed = nil
        let expectedCount = clipboard.changeCount
        isWorking = true; phase = .encoding; statusText = "完成画像を準備しています…"
        worker = Task { [weak self, workSlot] in
            defer { workSlot.release(identifier) }
            guard let self else { return }
            defer { self.finishWorker(identifier) }
            do {
                guard self.isCurrent(session: session, token: token), !Task.isCancelled else { return }
                let result: M0CompositionResult
                if let cached { result = cached }
                else {
                    _ = try M0ImageComposer.makePlan(assets: sources, limits: self.limits)
                    result = try await self.compose(sources, self.limits)
                }
                guard self.isCurrent(session: session, token: token), !Task.isCancelled else { return }
                _ = try M0ImageComposer.validateEncodedBytes(plan: result.plan, pngByteCount: result.pngData.count, isSingleImage: sources.count == 1, limits: self.limits)
                self.completed = result
                if !write {
                    self.phase = .ready; self.statusText = "完成画像を確認できます。まだコピーしていません"
                    return
                }
                // Last fence, no await before synchronous write.
                guard self.isCurrent(session: session, token: token) else { return }
                self.phase = .writing
                let outcome = self.clipboard.writePNG(result.pngData, expectedChangeCount: expectedCount)
                if outcome.writeAccepted {
                    self.releaseSession()
                    self.statusText = "コピーしました"
                    self.interface.hideCollection()
                    self.interface.showFeedback("コピーしました。Command + Vで貼り付けられます")
                    if self.interface.isOneClipActive { self.interface.returnToExternalApplication() }
                } else {
                    let conflict = outcome.code == .conflictBeforePrepare || outcome.code == .conflictAfterPrepare
                    let reason = conflict ? "ほかのコピーと重なりました。" : "コピーできませんでした。"
                    let boundary = outcome.prepared
                        ? "書込み準備後に中止したため、以前のクリップボード内容は残っていない場合があります。"
                        : "書込み前に中止しました。"
                    self.fail(reason + boundary + "素材を保持しています。確認して再試行してください")
                }
            } catch {
                guard self.isCurrent(session: session, token: token), !Task.isCancelled else { return }
                self.fail(self.errorMessage(error, fallback: "完成画像を準備できませんでした。素材を保持しています。再試行できます"))
            }
        }
    }

    func cancelOperation() {
        guard isActive, !isStopping, [.selecting, .capturing, .encoding, .permission].contains(phase) else { return }
        guard environmentAvailable() else { return }
        guard permissionCheck(), protectedDataCheck() else {
            invalidate(message: "利用状態または画面収録の許可が変わったため素材を破棄しました")
            return
        }
        if !hasAdoptedSource && assets.isEmpty && worker == nil { discard(); return }
        revision = UUID(); selectionDisplay = nil; replacementIndex = nil
        worker?.cancel(); _ = interface.hideSelection(); interface.hidePermission()
        phase = worker == nil ? .ready : .cancelling
        statusText = "取り消しました。素材は保持しています"
        interface.showCollection(activate: interface.isOneClipActive)
    }

    func discard() {
        guard phase != .writing else { return }
        worker?.cancel(); releaseSession(); interface.hideCollection(); interface.dismissAll()
        statusText = "素材を破棄しました。コピーしていません"
        if interface.isOneClipActive { interface.returnToExternalApplication() }
    }

    func invalidate(message: String) {
        worker?.cancel(); releaseSession(); interface.hideCollection(); interface.dismissAll()
        statusText = message
    }

    func environmentDidChange(_ event: CaptureEnvironmentEvent) {
        invalidate(message: event == .displayChanged ? "画面の構成が変わったため素材を破棄しました" : "利用状態が変わったため素材を破棄しました")
    }

    func prepareToQuit() {
        guard phase != .writing else { return }
        guard environmentAvailable() else { return }
        if hasRetainedImages && (!permissionCheck() || !protectedDataCheck()) {
            invalidate(message: "利用状態が変わったため素材を破棄しました"); return
        }
        revision = UUID(); worker?.cancel(); selectionDisplay = nil; replacementIndex = nil
        _ = interface.hideSelection(); interface.hideCaptureGuide(); interface.hidePermission()
        phase = worker == nil ? (isActive ? .ready : .idle) : .cancelling
    }
    func stop() { isStopping = true; invalidate(message: "終了しました") }
    func waitForWorker() async { await worker?.value }

    private func releaseSession() {
        sessionID = nil; revision = UUID(); assets.removeAll(); completed = nil; hasAdoptedSource = false
        selectionDisplay = nil; replacementIndex = nil
        #if DEBUG
        selectedPractice = nil
        #endif
        phase = worker == nil ? .idle : .cancelling
    }
    private func finishWorker(_ identifier: UUID) {
        worker = nil; isWorking = false
        if phase == .cancelling { phase = isActive ? .ready : .idle }
    }
    private func isCurrent(session: UUID?, token: UUID) -> Bool {
        guard session != nil, sessionID == session, revision == token, !isStopping else { return false }
        guard environmentAvailable() else { return false }
        guard protectedDataCheck(), permissionCheck() else {
            invalidate(message: "利用状態または画面収録の許可が変わったため素材を破棄しました")
            return false
        }
        return sessionID == session && revision == token
    }
    private func environmentAvailable(start: Bool = false) -> Bool {
        let available = start ? interface.prepareCaptureEnvironment() : interface.validateCaptureEnvironment()
        if !available { invalidate(message: interface.captureEnvironmentStatus) }
        return available
    }
    private func fail(_ message: String) {
        _ = interface.hideSelection(); selectionDisplay = nil; replacementIndex = nil
        phase = .ready; statusText = message
        interface.showCollection(activate: interface.isOneClipActive)
    }
    private func errorMessage(_ error: any Error, fallback: String) -> String {
        if error as? ScreenshotError == .settingsUnavailable { return "設定画面が変わりました。旧素材を保持しています。範囲を選び直してください" }
        if let error = error as? M0ImageError { return (error.errorDescription ?? fallback) + " 小さい範囲にするか、不要な素材を削除してください。" }
        if let error = error as? ScreenshotError, error == .imageLimitExceeded { return "画像が上限を超えます。旧素材を保持しています。小さい範囲を選んでください" }
        return fallback
    }
}
