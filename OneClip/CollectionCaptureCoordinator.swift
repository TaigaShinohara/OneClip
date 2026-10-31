import AppKit
import Combine
import Foundation

enum CollectionCapturePhase: String {
    case idle, onboarding, permission, ready, selecting, capturing, reviewingReplacement, encoding, writing, cancelling
}

struct CollectionItemMetadata: Identifiable {
    let id: UUID
    let index: Int
    let image: CGImage
    let width: Int
    let height: Int
    let scale: Double
}

/// A confirmation identifies one revision without retaining any image or completed output.
struct CollectionDeletionTarget: Equatable, Sendable {
    let sessionID: UUID
    let revision: UUID
    let index: Int
    let assetID: UUID
}

private final class CollectionImageBorrow {
    weak var image: CGImage?
    init(_ image: CGImage) { self.image = image }
}

struct CollectionReplacement: Identifiable {
    let id = UUID()
    let sessionID: UUID
    let contentRevision: UUID
    let assetID: UUID
    let index: Int
    let original: M0ImageAsset
    let candidate: M0ImageAsset
}

@MainActor
protocol CollectionCaptureInterface: SingleCaptureInterface {
    func showCollection(activate: Bool)
    func hideCollection()
    func showCollectionGuide(started: @escaping @MainActor () -> Void,
                             cancelled: @escaping @MainActor () -> Void)
    func showCollectionPermission()
    var collectionCopyBlocked: Bool { get }
    func hideCollectionGuide()
    func hideCollectionPermission()
    func dismissCollectionUI()
    func rememberCollectionOrigin()
    func returnToCollectionOrigin()
    func hideCollectionSelection() -> Bool
    func prepareForCollectionSelection() -> Bool
}

extension CollectionCaptureInterface {
    var collectionCopyBlocked: Bool { captureEntryBlocked }
    func hideCollectionGuide() { hideCaptureGuide() }
    func hideCollectionPermission() { hidePermission() }
    func dismissCollectionUI() { dismissAll() }
    func rememberCollectionOrigin() { rememberExternalApplication() }
    func returnToCollectionOrigin() { returnToExternalApplication() }
    func hideCollectionSelection() -> Bool { hideSelection() }
    func prepareForCollectionSelection() -> Bool { prepareForSelection() }
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
    @Published private(set) var pendingReplacement: CollectionReplacement?
    @Published private(set) var permissionMessage = "画面収録の許可を確認してください。画像の保存・送信は行いません。"
    @Published private(set) var permissionStatus = CapturePermissionStatus.notChecked
    @Published private(set) var contentRevision = UUID()
    @Published private(set) var copiedContentRevision: UUID?
    @Published private(set) var invalidationNotice: String?
    @Published var previewExpanded = false
    @Published var previewActualPixels = false
    @Published var replacementShowsCandidate = true
    @Published var replacementActualPixels = false
    var externalOperationBlocked: @MainActor () -> Bool = { false }
    var externalOperationMessage: @MainActor () -> String? = { nil }
    var externalWorkInProgress: @MainActor () -> Bool = { false }
    var canEndSession: Bool { phase != .writing && phase != .cancelling && !externalWorkInProgress() }
    var recoverExternalOperation: @MainActor () -> Void = {}
    var blockedOperationMessage: String? { externalOperationBlocked() ? externalOperationMessage() : nil }
    private var assetIDs: [UUID] = []
    // A disappearing SwiftUI view may briefly borrow the former image. No history is owned here.
    private var retiredImageBorrows: [CollectionImageBorrow] = []
    private var retiredImageBytes: Int {
        var total = 0
        for borrow in retiredImageBorrows {
            guard let image = borrow.image else { continue }
            let bytes = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
            let sum = total.addingReportingOverflow(bytes.partialValue)
            guard !bytes.overflow, !sum.overflow else { return Int.max }
            total = sum.partialValue
        }
        return total
    }
    private func trackRetiringImage(_ image: CGImage) {
        retiredImageBorrows.removeAll { $0.image == nil }
        if !retiredImageBorrows.contains(where: { $0.image === image }) {
            retiredImageBorrows.append(CollectionImageBorrow(image))
        }
    }
    private var permissionWasGranted = false
    private var hasRequestedPermission = false
    private(set) var sessionID: UUID?
    private(set) var revision = UUID()
    var items: [CollectionItemMetadata] {
        assets.indices.map { index in
            CollectionItemMetadata(id: assetIDs[index], index: index, image: assets[index].image,
                width: assets[index].image.width, height: assets[index].image.height, scale: assets[index].scale)
        }
    }
    var isActive: Bool { sessionID != nil }
    var hasRetainedImages: Bool { !assets.isEmpty }
    var isCopiedCurrent: Bool { copiedContentRevision == contentRevision && copiedContentRevision != nil }
    var needsEndConfirmation: Bool { pendingReplacement != nil || (hasRetainedImages && !isCopiedCurrent) }
    var contentStatusText: String {
        guard !assets.isEmpty else { return "素材はありません。追加できます" }
        let state = copiedContentRevision == nil ? "未コピー"
            : (isCopiedCurrent ? "前回コピー後に素材変更なし" : "前回コピー後に素材変更あり")
        return "このまとめ：\(assets.count)/4枚・\(state)"
    }
    var latestResultText: String { statusText }
    var canEdit: Bool { isActive && phase == .ready && !isWorking && !interface.captureEntryBlocked
        && !externalOperationBlocked() && !isStopping && pendingReplacement == nil }
    var canAdd: Bool { canEdit && assets.count < limits.maximumCount && !workSlot.isOccupied }
    var canCopy: Bool { isActive && phase == .ready && !isWorking && !interface.collectionCopyBlocked
        && !externalOperationBlocked() && !isStopping && pendingReplacement == nil
        && !assets.isEmpty && !workSlot.isOccupied }
    var canStartSingle: Bool { !isStopping && !isWorking && pendingReplacement == nil
        && (phase == .idle || phase == .ready) && !workSlot.isOccupied }
    var plan: M0CompositionPlan? { try? M0ImageComposer.makePlan(assets: assets, limits: limits) }
    /// Checked aggregate source/UI estimate. This is not a process RSS promise.
    var retainedImageBytes: Int {
        var total = retiredImageBytes
        for asset in assets {
            let bytes = asset.image.bytesPerRow.multipliedReportingOverflow(by: asset.image.height)
            let sum = total.addingReportingOverflow(bytes.partialValue)
            guard !bytes.overflow, !sum.overflow else { return Int.max }
            total = sum.partialValue
        }
        if let plan {
            let sum = total.addingReportingOverflow(plan.previewReserveBytes)
            guard !sum.overflow else { return Int.max }; total = sum.partialValue
        }
        return total
    }
    func prepareForSingleCapture() -> Bool {
        guard canStartSingle else { return false }
        if hasRetainedImages {
            guard environmentAvailable() else { return false }
            if !permissionCheck() || !protectedDataCheck() {
                // Entry into the other mode must also fence this mode's retained images.
                invalidate(message: "利用状態または画面収録の許可が変わりました")
            }
        }
        completed = nil
        return true
    }
    func acknowledgeInvalidation() { invalidationNotice = nil }

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

    /// Explicit addition differs from the next independent collection after a successful copy.
    func beginFromShortcut() {
        if invalidationNotice != nil || pendingReplacement != nil { showPanel(); return }
        if isCopiedCurrent { beginNewSession() } else { beginOrAdd() }
    }

    func beginNewSession(discardConfirmed: Bool = false) {
        guard !isStopping, !interface.captureEntryBlocked, !isWorking, !workSlot.isOccupied,
              !externalOperationBlocked(), pendingReplacement == nil || discardConfirmed else { return }
        guard environmentAvailable(start: true) else { return }
        if needsEndConfirmation && !discardConfirmed {
            statusText = "未コピーの素材または変更があります。終了を確認してから新しく始めてください"
            showPanel(); return
        }
        // Admission precedes ending a copied draft; an ordinary gate rejection preserves it.
        guard interface.prepareForCollectionSelection() else { return }
        if isActive { releaseSession() }
        acknowledgeInvalidation()
        beginOrAdd()
    }

    func beginOrAdd() {
        beginOrAdd(rememberOrigin: true)
    }

    private func beginOrAdd(rememberOrigin: Bool) {
        #if DEBUG
        if M2FailureLab.isEnabled { return }
        #endif
        guard !isStopping, !interface.captureEntryBlocked, !isWorking, !workSlot.isOccupied,
              !externalOperationBlocked(), pendingReplacement == nil else { return }
        guard environmentAvailable(start: true) else { return }
        if invalidationNotice != nil { interface.showCollection(activate: true); return }
        if !isActive { sessionID = UUID(); revision = UUID(); contentRevision = UUID(); phase = .ready }
        if rememberOrigin { interface.rememberCollectionOrigin() }
        if !preferences.hasSeenCollectionGuide {
            let token = revision
            phase = .onboarding
            interface.showCollectionGuide(started: { [weak self] in
                guard let self, self.revision == token, self.phase == .onboarding else { return }
                self.interface.hideCollectionGuide()
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
        if !isActive, invalidationNotice != nil { interface.showCollection(activate: true); return }
        guard isActive, environmentAvailable() else { return }
        guard permissionCheck(), protectedDataCheck() else { invalidate(message: "利用状態が変わったため素材を破棄しました"); return }
        interface.showCollection(activate: true)
    }

    func replace(at index: Int) {
        guard canEdit, assets.indices.contains(index), !workSlot.isOccupied else { return }
        interface.rememberCollectionOrigin()
        select(replacing: index)
    }

    func replace(assetID: UUID) {
        guard let index = assetIDs.firstIndex(of: assetID) else { return }
        replace(at: index)
    }

    private func select(replacing index: Int?) {
        guard environmentAvailable() else { return }
        guard observePermission() else {
            // Never retain existing sources after a permission loss.
            if !assets.isEmpty { invalidate(message: "画面収録の許可を確認できなくなったため、素材を破棄しました"); return }
            phase = .permission
            interface.showCollectionPermission()
            return
        }
        guard protectedDataCheck() else { invalidate(message: "画面を利用できません。解除後に選び直してください"); return }
        completed = nil // Release old output/PNG before acquiring a candidate.
        guard interface.prepareForCollectionSelection() else { fail("別の操作が終わってから追加してください"); return }
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
        hasRequestedPermission = true
        _ = permissionRequest()
        if !observePermission() { permissionStatus = permissionWasGranted ? .noLongerAvailable : .requestUnconfirmed }
        permissionMessage = permissionStatus == .granted ? "許可を確認できました。範囲を選べます。"
            : "許可を確認できません。システム設定でOneClipを確認してください。"
    }

    func refreshPermissionStatus() {
        guard phase == .permission, !isStopping else { return }
        _ = observePermission()
        permissionMessage = permissionStatus == .granted ? "許可を確認できました。範囲を選べます。"
            : "画面収録の許可を確認してください。"
    }

    private func observePermission() -> Bool {
        if permissionCheck() { permissionWasGranted = true; permissionStatus = .granted; return true }
        permissionStatus = permissionWasGranted ? .noLongerAvailable : (hasRequestedPermission ? .requestUnconfirmed : .notConfirmed)
        return false
    }

    func retryPermission() {
        guard phase == .permission, !interface.captureEntryBlocked, environmentAvailable() else { return }
        guard observePermission() else { permissionMessage = "許可を確認してから範囲を選んでください"; return }
        interface.hideCollectionPermission(); phase = .ready; beginOrAdd(rememberOrigin: false)
    }

    private func confirm(_ selection: CaptureSelection, token: UUID) {
        guard phase == .selecting, revision == token, selection.display == selectionDisplay,
              worker == nil, !interface.captureEntryBlocked, environmentAvailable() else { return }
        do {
            let geometry = try RegionGeometry.plan(selection: selection, filterScale: selection.display.scale)
            let (stride, overflow) = geometry.pixelWidth.multipliedReportingOverflow(by: 4)
            guard !overflow else { throw M0ImageError.arithmeticOverflow }
            let budget = CaptureImageBudgetContext(existing: assets.map(\.metrics), replacementIndex: replacementIndex,
                                                   retainingExtraBytes: retiredImageBytes)
            _ = try budget.validateCandidate(M0ImageMetrics(width: geometry.pixelWidth, height: geometry.pixelHeight,
                                                            bytesPerRow: stride, scale: Double(selection.display.scale)), limits: limits)
            let settings = try interface.settingsCaptureScope(for: selection)
            guard interface.hideCollectionSelection() else { fail("選択画面を閉じられず、取得を中止しました"); return }
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
                    if let target, let session, self.assets.indices.contains(target) {
                        self.pendingReplacement = CollectionReplacement(sessionID: session,
                            contentRevision: self.contentRevision, assetID: self.assetIDs[target], index: target,
                            original: self.assets[target], candidate: candidate)
                        self.replacementShowsCandidate = true; self.replacementActualPixels = false
                        self.phase = .reviewingReplacement
                        self.statusText = "新旧の素材を確認してください。まだ置き換えていません"
                    } else {
                        self.assets.append(candidate); self.assetIDs.append(UUID())
                        self.contentRevision = UUID(); self.phase = .ready
                        self.statusText = "素材を追加しました。完成画像を確認してコピーできます"
                    }
                    self.hasAdoptedSource = true
                    self.revision = UUID(); self.replacementIndex = nil; self.selectionDisplay = nil
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

    func acceptReplacement(id: UUID) {
        guard let pending = pendingReplacement, pending.id == id, !isWorking,
              !externalOperationBlocked(), !interface.collectionCopyBlocked,
              sessionID == pending.sessionID, contentRevision == pending.contentRevision,
              assetIDs.indices.contains(pending.index), assetIDs[pending.index] == pending.assetID,
              environmentAvailable() else { return }
        guard permissionCheck(), protectedDataCheck() else {
            invalidate(message: "利用状態または画面収録の許可が変わりました"); return
        }
        do {
            _ = try M0ImageComposer.validateChange(existing: assets, replacementIndex: pending.index,
                                                   candidate: pending.candidate, limits: limits)
            trackRetiringImage(assets[pending.index].image)
            assets[pending.index] = pending.candidate
            pendingReplacement = nil; completed = nil
            contentRevision = UUID(); revision = UUID(); phase = .ready
            statusText = "素材を置き換えました。完成画像を確認してコピーできます"
        } catch { statusText = errorMessage(error, fallback: "置き換えられません。旧素材は保持しています") }
    }

    func keepOriginalReplacement(id: UUID) {
        guard pendingReplacement?.id == id, !isWorking else { return }
        guard environmentAvailable() else { return }
        guard permissionCheck(), protectedDataCheck() else {
            invalidate(message: "利用状態または画面収録の許可が変わりました"); return
        }
        if let image = pendingReplacement?.candidate.image { trackRetiringImage(image) }
        pendingReplacement = nil; revision = UUID(); phase = .ready
        statusText = "元の素材を残しました。素材の内容は変わっていません"
    }

    func retryReplacement(id: UUID) {
        guard let pending = pendingReplacement, pending.id == id, !isWorking else { return }
        let assetID = pending.assetID
        keepOriginalReplacement(id: id)
        replace(assetID: assetID)
    }

    func deletionTarget(assetID: UUID) -> CollectionDeletionTarget? {
        guard let index = assetIDs.firstIndex(of: assetID) else { return nil }
        return deletionTarget(at: index)
    }

    func deletionTarget(at index: Int) -> CollectionDeletionTarget? {
        guard canEdit, !workSlot.isOccupied, assets.indices.contains(index), let sessionID else { return nil }
        guard environmentAvailable() else { return nil }
        guard permissionCheck(), protectedDataCheck() else {
            invalidate(message: "利用状態が変わったため素材を破棄しました")
            return nil
        }
        return CollectionDeletionTarget(sessionID: sessionID, revision: revision, index: index, assetID: assetIDs[index])
    }

    @discardableResult
    func delete(_ target: CollectionDeletionTarget) -> Bool {
        guard canEdit, !workSlot.isOccupied, sessionID == target.sessionID,
              revision == target.revision, assets.indices.contains(target.index), assetIDs[target.index] == target.assetID else { return false }
        guard environmentAvailable() else { return false }
        guard permissionCheck(), protectedDataCheck() else {
            invalidate(message: "利用状態が変わったため素材を破棄しました")
            return false
        }
        trackRetiringImage(assets[target.index].image)
        completed = nil; assets.remove(at: target.index); assetIDs.remove(at: target.index)
        revision = UUID(); contentRevision = UUID()
        statusText = assets.isEmpty ? "素材はありません。追加できます" : "素材を削除しました。完成画像を確認してください"
        return true
    }

    func preparePreview() { encodeAndOptionallyCopy(write: false) }
    func copy() { encodeAndOptionallyCopy(write: true) }

    private func encodeAndOptionallyCopy(write: Bool) {
        guard canCopy, environmentAvailable(), let session = sessionID else { return }
        guard permissionCheck(), protectedDataCheck() else { invalidate(message: "利用状態が変わったため素材を破棄しました"); return }
        interface.rememberCollectionOrigin()
        let identifier = UUID()
        guard workSlot.acquire(identifier) else { return }
        let token = revision
        let content = contentRevision
        let extra = retiredImageBytes
        var compositionLimits = limits
        guard extra >= 0, extra < limits.maximumImageBytes else {
            fail("画像の作業領域の解放を待ってから、もう一度コピーしてください"); workSlot.release(identifier); return
        }
        compositionLimits.maximumImageBytes -= extra
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
                    _ = try M0ImageComposer.makePlan(assets: sources, limits: self.limits, retainingExtraBytes: extra)
                    result = try await self.compose(sources, compositionLimits)
                }
                guard self.isCurrent(session: session, token: token), !Task.isCancelled else { return }
                let checkedPlan = try M0ImageComposer.makePlan(assets: sources, limits: self.limits, retainingExtraBytes: extra)
                _ = try M0ImageComposer.validateEncodedBytes(plan: checkedPlan, pngByteCount: result.pngData.count, isSingleImage: sources.count == 1, limits: self.limits)
                self.completed = result
                if !write {
                    self.phase = .ready; self.statusText = "完成画像を確認できます"
                    return
                }
                // Last fence, no await before synchronous write.
                guard self.isCurrent(session: session, token: token) else { return }
                self.phase = .writing
                let outcome = self.clipboard.writePNG(result.pngData, expectedChangeCount: expectedCount)
                if outcome.writeAccepted {
                    self.copiedContentRevision = content
                    self.completed = nil
                    self.phase = .ready
                    self.statusText = "このまとめをコピーしました。次のまとめ撮りを始めるまで編集できます"
                    self.interface.hideCollection()
                    self.interface.showFeedback("コピーしました。Command + Vで貼り付け。素材は次のまとめ撮りまで編集できます")
                    if self.interface.isOneClipActive { self.interface.returnToCollectionOrigin() }
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
        worker?.cancel(); _ = interface.hideCollectionSelection(); interface.hideCollectionPermission()
        phase = worker == nil ? .ready : .cancelling
        statusText = worker == nil ? "取り消しました。素材は保持しています"
            : "取り消しています。処理の終了を待っています。素材\(assets.count)枚は残っています"
        interface.showCollection(activate: interface.isOneClipActive)
    }

    func discard() {
        guard canEndSession else { return }
        worker?.cancel(); releaseSession(); interface.hideCollection(); interface.dismissCollectionUI()
        statusText = "まとめ撮りの編集を終了しました。クリップボードは変更していません"
        if interface.isOneClipActive { interface.returnToCollectionOrigin() }
    }

    func invalidate(message: String) {
        let count = assets.count
        let hadCandidate = pendingReplacement != nil
        if count > 0 {
            let copyState = copiedContentRevision == nil ? "このまとめはコピーしていません。"
                : (isCopiedCurrent ? "この内容の前回コピーは成功しました。" : "前回コピー後の変更はコピーしていません。")
            invalidationNotice = "前のまとめ\(count)枚を破棄しました。\(message) \(copyState)"
                + (hadCandidate ? "取り直し候補も破棄しました。" : "")
        }
        worker?.cancel(); releaseSession(); interface.hideCollection(); interface.dismissCollectionUI()
        statusText = invalidationNotice ?? message
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
        _ = interface.hideCollectionSelection(); interface.hideCollectionGuide(); interface.hideCollectionPermission()
        phase = worker == nil ? (pendingReplacement != nil ? .reviewingReplacement : (isActive ? .ready : .idle)) : .cancelling
    }
    func stop() { isStopping = true; invalidate(message: "終了しました") }
    func waitForWorker() async { await worker?.value }

    private func releaseSession() {
        for asset in assets { trackRetiringImage(asset.image) }
        if let candidate = pendingReplacement?.candidate.image { trackRetiringImage(candidate) }
        sessionID = nil; revision = UUID(); assets.removeAll(); assetIDs.removeAll(); completed = nil; hasAdoptedSource = false
        pendingReplacement = nil; contentRevision = UUID(); copiedContentRevision = nil
        previewExpanded = false; previewActualPixels = false
        replacementShowsCandidate = true; replacementActualPixels = false
        selectionDisplay = nil; replacementIndex = nil
        #if DEBUG
        selectedPractice = nil
        #endif
        phase = worker == nil ? .idle : .cancelling
    }
    private func finishWorker(_ identifier: UUID) {
        worker = nil; isWorking = false
        if phase == .cancelling {
            phase = isActive ? .ready : .idle
            if isActive { statusText = "取り消しました。素材\(assets.count)枚は残っています" }
        }
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
        _ = interface.hideCollectionSelection(); selectionDisplay = nil; replacementIndex = nil
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
