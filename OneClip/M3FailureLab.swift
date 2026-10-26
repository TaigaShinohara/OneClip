#if DEBUG
import AppKit
import SwiftUI

/// Explicit Debug mode. Every retry continues to use fabricated images, memory-only
/// permission/preferences and one unique pasteboard. It never acquires a screen.
@MainActor
final class M3FailureLab: ObservableObject, ScreenshotCapturing, CaptureClipboardWriting {
    static let shared = M3FailureLab()
    static var isEnabled: Bool {
        #if ONECLIP_M3_SAFE_LAB
        true
        #else
        CommandLine.arguments.contains("--m3-failure-lab")
        #endif
    }

    enum CaptureMode { case normal, failure, manual, selectionCancel }
    enum CompositionMode { case normal, failure, manual }
    enum PendingWorker: String {
        case capture = "取得結果の手動返却待ち"
        case composition = "合成結果の手動返却待ち"
    }

    @Published private(set) var pendingWorker: PendingWorker?
    @Published private(set) var captureStarts = 0
    @Published private(set) var captureResultsReturned = 0
    @Published private(set) var compositionStarts = 0
    @Published private(set) var compositionResultsReturned = 0
    @Published private(set) var clipboardWriteAttempts = 0
    @Published private(set) var clipboardWritesAccepted = 0
    @Published private(set) var selectionCancels = 0
    @Published private(set) var permissionAllowed = true
    @Published private(set) var writingFailureArmed = false
    @Published private(set) var timedReturnScheduled = false

    private struct Fixture {
        let width: Int
        let height: Int
        let scale: Double
    }
    // Pixel dimensions differ; 2x samples occupy half those dimensions in points.
    private let fixtures = [Fixture(width: 720, height: 260, scale: 1),
                            Fixture(width: 900, height: 320, scale: 2),
                            Fixture(width: 640, height: 400, scale: 1),
                            Fixture(width: 1_100, height: 220, scale: 2)]
    private var fixtureCursor = 0
    private var captureFailureArmed = false
    private var compositionFailureArmed = false
    private var holdNextCapture = false
    private var holdNextComposition = false
    private var cancelNextSelection = false
    private var pendingResult: CheckedContinuation<Void, Never>?
    private var pendingIdentifier: UUID?
    private var timedReturnIdentifier: UUID?
    private var timedReturnTask: Task<Void, Never>?
    private var hasStopped = false
    private var window: NSWindow?
    private var board: NSPasteboard?
    private weak var native: NativeCaptureInterface?
    private weak var coordinator: CollectionCaptureCoordinator?
    private var trialInterface: CollectionTrialInterface?
    private let preferences = CapturePreferences(defaults: nil, hasSeenCaptureGuide: true,
                                                  hasSeenPasteHint: true, hasSeenCollectionGuide: true)

    var isVisible: Bool { window?.isVisible == true }
    var canStartCapture: Bool {
        guard let coordinator else { return false }
        return !hasStopped && pendingWorker == nil && !coordinator.isWorking
            && !CaptureWorkerSlot.shared.isOccupied && [.idle, .ready].contains(coordinator.phase)
            && native?.hasDiscardConfirmation != true && native?.collectionPresentationBlocksEntry != true
    }
    var canPrepareOutput: Bool {
        canStartCapture && coordinator?.phase == .ready && coordinator?.hasRetainedImages == true
    }
    var canStartFresh: Bool { canStartCapture && coordinator?.isActive == false }
    var canResetCounters: Bool {
        !hasStopped && pendingWorker == nil && coordinator?.isWorking != true && !CaptureWorkerSlot.shared.isOccupied
    }
    var canSchedulePendingReturn: Bool {
        Self.isEnabled && !hasStopped && pendingResult != nil && pendingWorker != nil
            && pendingIdentifier != nil && !timedReturnScheduled
    }

    func makeCoordinator(interface: NativeCaptureInterface) -> CollectionCaptureCoordinator {
        if let coordinator { return coordinator }
        native = interface
        board = .withUniqueName()
        let trial = CollectionTrialInterface(native: interface, lab: self)
        trialInterface = trial
        let value = CollectionCaptureCoordinator(capturer: self, interface: trial, clipboard: self,
            preferences: preferences,
            permissionCheck: { [weak self] in self?.permissionAllowed == true },
            permissionRequest: { [weak self] in
                guard let self, !self.hasStopped else { return false }
                self.permissionAllowed = true
                return true // The coordinator still requires an explicit retry.
            },
            protectedDataCheck: { NSApp.isProtectedDataAvailable },
            displayAtPointer: { [weak self] in
                guard let self, !self.hasStopped else { throw ScreenshotError.invalidated }
                return try self.fixtureDisplay()
            },
            compose: { [weak self] assets, limits in
                guard let self else { throw ScreenshotError.invalidated }
                return try await self.composeFixture(assets, limits: limits)
            })
        coordinator = value
        return value
    }

    func show() {
        guard Self.isEnabled, !hasStopped, let coordinator,
              native?.hasDiscardConfirmation != true else { return }
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 530, height: 580),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "OneClip — M3 安全な失敗試験"
            panel.isRestorable = false
            panel.isReleasedWhenClosed = false
            panel.center()
            panel.contentView = NSHostingView(rootView: M3FailureLabView(lab: self, capture: coordinator))
            window = panel
        }
        if let content = window?.contentView { window?.setContentSize(content.fittingSize) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Diagnostics never activate the app when a worker or an OS transition is pending.
    private func showDiagnosticsWithoutActivation() {
        guard Self.isEnabled, !hasStopped else { return }
        window?.orderFront(nil)
    }

    func beginCapture(_ mode: CaptureMode = .normal, showFirstGuide: Bool? = nil) {
        guard canStartCapture, let coordinator else { return }
        if let showFirstGuide {
            guard !coordinator.isActive else { return }
            preferences.hasSeenCollectionGuide = !showFirstGuide
        }
        captureFailureArmed = mode == .failure
        holdNextCapture = mode == .manual
        cancelNextSelection = mode == .selectionCancel
        window?.orderOut(nil) // The real entry fence must see the diagnostic window closed.
        coordinator.beginOrAdd()
    }

    func prepareOutput(_ mode: CompositionMode = .normal, write: Bool) {
        guard canPrepareOutput, let coordinator else { return }
        compositionFailureArmed = mode == .failure
        holdNextComposition = mode == .manual
        window?.orderOut(nil)
        if write { coordinator.copy() } else { coordinator.preparePreview() }
    }

    func armWritingFailure() {
        guard !hasStopped, coordinator?.isWorking != true else { return }
        writingFailureArmed = true
    }

    func beginWithPermissionDenied() {
        guard canStartFresh else { return }
        permissionAllowed = false
        beginCapture()
    }

    func allowPermissionForExplicitRetry() {
        guard !hasStopped, coordinator?.phase == .permission else { return }
        permissionAllowed = true
        window?.orderOut(nil)
        // Deliberately do not call retryPermission() or beginOrAdd().
    }

    func returnToCollection() {
        guard !hasStopped else { return }
        window?.orderOut(nil)
        if coordinator?.isActive == true { coordinator?.showPanel() }
    }

    func capture(_ request: SingleCaptureRequest, isCurrent: @escaping @MainActor () -> Bool) async throws -> M0ImageAsset {
        guard !hasStopped else { throw ScreenshotError.invalidated }
        captureStarts += 1
        defer { captureResultsReturned += 1 }
        let index = fixtureCursor
        let fixture = fixtures[index]
        fixtureCursor = (fixtureCursor + 1) % fixtures.count
        let fail = captureFailureArmed
        let hold = holdNextCapture
        captureFailureArmed = false
        holdNextCapture = false
        if hold { try await waitForManualResult(.capture) }
        guard !hasStopped else { throw ScreenshotError.invalidated }
        if fail { throw ScreenshotError.captureFailed }
        // No isCurrent/cancellation check here: the product must reject a genuinely late result.
        let asset = try M0ImageFixture.make(index: index + 1, width: fixture.width,
                                          height: fixture.height, scale: fixture.scale)
        _ = try request.budget.validateCandidate(asset.metrics)
        return asset
    }

    private func composeFixture(_ assets: [M0ImageAsset], limits: M0ImageLimits) async throws -> M0CompositionResult {
        guard !hasStopped else { throw ScreenshotError.invalidated }
        compositionStarts += 1
        defer { compositionResultsReturned += 1 }
        let fail = compositionFailureArmed
        let hold = holdNextComposition
        compositionFailureArmed = false
        holdNextComposition = false
        if hold { try await waitForManualResult(.composition) }
        guard !hasStopped else { throw ScreenshotError.invalidated }
        if fail { throw ScreenshotError.captureFailed }
        // Immutable borrowed source references survive until this worker actually returns.
        // Cancellation intentionally does not end the manual gate or the detached composer.
        return try await Task.detached(priority: .userInitiated) {
            try M0ImageComposer.compose(assets: assets, limits: limits)
        }.value
    }

    private func waitForManualResult(_ worker: PendingWorker) async throws {
        guard pendingResult == nil, pendingWorker == nil, !hasStopped else { throw ScreenshotError.busy }
        cancelTimedReturn()
        // No automatic timeout/cancellation handler. Only an explicit manual or scheduled Lab
        // return completes this gate; an OS transition must not silently complete the work.
        await withCheckedContinuation { continuation in
            pendingIdentifier = UUID()
            pendingResult = continuation
            pendingWorker = worker
            showDiagnosticsWithoutActivation()
        }
    }

    func returnPendingResult() {
        cancelTimedReturn()
        guard let continuation = pendingResult else { return }
        pendingIdentifier = nil
        pendingResult = nil
        pendingWorker = nil
        continuation.resume()
    }

    /// Explicit T08 support only. This returns a fabricated worker result, not an OS safety timeout.
    func schedulePendingReturn() {
        guard canSchedulePendingReturn, let pendingIdentifier else { return }
        let reservation = UUID()
        timedReturnIdentifier = reservation
        timedReturnScheduled = true
        timedReturnTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(20)) }
            catch { return }
            guard !Task.isCancelled, let self, !self.hasStopped,
                  self.pendingIdentifier == pendingIdentifier,
                  self.timedReturnIdentifier == reservation, self.pendingResult != nil else { return }
            // No show/orderFront/activate here. Observe the existing product completion path.
            self.returnPendingResult()
        }
    }

    private func cancelTimedReturn() {
        timedReturnIdentifier = nil
        timedReturnTask?.cancel()
        timedReturnTask = nil
        timedReturnScheduled = false
    }

    fileprivate func fixtureDisplay() throws -> CaptureDisplaySnapshot {
        try CaptureDisplaySnapshot(id: 1, frame: CGRect(x: 0, y: 0, width: 1_000, height: 700),
                                   scale: CGFloat(fixtures[fixtureCursor].scale))
    }

    fileprivate func selection(on display: CaptureDisplaySnapshot) throws -> CaptureSelection {
        let fixture = fixtures[fixtureCursor]
        return try CaptureSelection(display: display, rect: CGRect(x: 40, y: 40,
            width: Double(fixture.width) / fixture.scale, height: Double(fixture.height) / fixture.scale))
    }

    fileprivate func consumeSelectionCancel() -> Bool {
        let cancel = cancelNextSelection
        cancelNextSelection = false
        return cancel
    }
    fileprivate func selectionCancelled() { selectionCancels += 1 }

    var changeCount: Int { board?.changeCount ?? 0 }
    func writePNG(_ data: Data, expectedChangeCount: Int) -> M0ClipboardProbe.Outcome {
        clipboardWriteAttempts += 1
        if writingFailureArmed {
            writingFailureArmed = false
            return .init(code: .writeRejected, expectedChangeCount: expectedChangeCount,
                         observedChangeCount: changeCount, preparedChangeCount: nil)
        }
        guard !hasStopped, let board else {
            return .init(code: .writeRejected, expectedChangeCount: expectedChangeCount,
                         observedChangeCount: changeCount, preparedChangeCount: nil)
        }
        let outcome = M0ClipboardProbe.writePNG(data, to: board, expectedChangeCount: expectedChangeCount)
        if outcome.writeAccepted { clipboardWritesAccepted += 1 }
        return outcome
    }

    func resetCounters() {
        guard canResetCounters else { return }
        captureStarts = 0; captureResultsReturned = 0
        compositionStarts = 0; compositionResultsReturned = 0
        clipboardWriteAttempts = 0; clipboardWritesAccepted = 0; selectionCancels = 0
    }

    func stop() {
        hasStopped = true
        cancelTimedReturn()
        trialInterface?.invalidateSelection()
        captureFailureArmed = false; compositionFailureArmed = false; writingFailureArmed = false
        holdNextCapture = false; holdNextComposition = false; cancelNextSelection = false
        returnPendingResult() // No suspended test continuation is left at shutdown.
        board?.releaseGlobally(); board = nil
        window?.orderOut(nil)
    }
}

/// The product UI and availability monitors remain real. Selection is fabricated locally;
/// no overlay, ScreenCaptureKit service, TCC request or global key registration is involved.
@MainActor
private final class CollectionTrialInterface: CollectionCaptureInterface {
    private let native: NativeCaptureInterface
    private weak var lab: M3FailureLab?
    private var selectionGeneration = UUID()
    init(native: NativeCaptureInterface, lab: M3FailureLab) { self.native = native; self.lab = lab }
    var isOneClipActive: Bool { native.isOneClipActive }
    var captureEntryBlocked: Bool { native.captureEntryBlocked }
    var captureEnvironmentStatus: String { native.captureEnvironmentStatus }
    func prepareCaptureEnvironment() -> Bool { native.prepareCaptureEnvironment() }
    func validateCaptureEnvironment() -> Bool { native.validateCaptureEnvironment() }
    func prepareForSelection() -> Bool { native.prepareForSelection() }
    func showSelection(on display: CaptureDisplaySnapshot, selected: @escaping @MainActor (CaptureSelection) -> Void,
                       cancelled: @escaping @MainActor () -> Void) {
        let generation = UUID()
        selectionGeneration = generation
        let cancel = lab?.consumeSelectionCancel() == true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.selectionGeneration == generation, let lab = self.lab else { return }
            if cancel { lab.selectionCancelled(); cancelled(); return }
            do { selected(try lab.selection(on: display)) } catch { cancelled() }
        }
    }
    func invalidateSelection() { selectionGeneration = UUID() }
    func hideSelection() -> Bool { invalidateSelection(); return true }
    func showCaptureGuide(started: @escaping @MainActor () -> Void, cancelled: @escaping @MainActor () -> Void) {
        native.showCaptureGuide(started: started, cancelled: cancelled)
    }
    func hideCaptureGuide() { native.hideCaptureGuide() }
    func showCollectionGuide(started: @escaping @MainActor () -> Void, cancelled: @escaping @MainActor () -> Void) {
        native.showCollectionGuide(started: started, cancelled: cancelled)
    }
    func showCollection(activate: Bool) { native.showCollection(activate: activate) }
    func hideCollection() { native.hideCollection() }
    func showCollectionPermission() { native.showCollectionPermission() }
    func showPermission() { native.showPermission() }
    func hidePermission() { native.hidePermission() }
    func showProblem(activate: Bool) { native.showProblem(activate: activate) }
    func hideProblem() { native.hideProblem() }
    func showFeedback(_ message: String) { native.showFeedback("安全な試験: \(message)（専用board）") }
    func dismissAll() { invalidateSelection(); native.dismissAll() }
    func rememberExternalApplication() { native.rememberExternalApplication() }
    func returnToExternalApplication() { native.returnToExternalApplication() }
}

private struct M3FailureLabView: View {
    @ObservedObject var lab: M3FailureLab
    @ObservedObject var capture: CollectionCaptureCoordinator
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("M3 安全な失敗試験").font(.title2.bold())
                Text("架空の4種類（1倍・2倍）を順に取得し、製品の収集パネルで操作します。この起動中は実画面・一般クリップボード・実TCC・撮影キー登録を使いません。")
                Text("内部差替えとUI・実OS遷移を組み合わせる支援です。製品の実画面取得中の成立や、すべてのOS遷移を証明するものではありません。")
                    .font(.callout).foregroundStyle(.secondary)
                diagnostics
                HStack {
                    Button("遅い結果を返す") { lab.returnPendingResult() }.disabled(lab.pendingWorker == nil)
                    Button("測定値をリセット") { lab.resetCounters() }.disabled(!lab.canResetCounters)
                }
                Button("20秒後に遅い結果を返す") { lab.schedulePendingReturn() }
                    .disabled(!lab.canSchedulePendingReturn)
                Text(lab.timedReturnScheduled ? "時限返却: 20秒後の返却を予約中" : "時限返却: 予約なし")
                    .font(.callout)
                Text("明示した試験結果を返すための予約です。OS失効の安全期限ではありません。予約後は別のアプリへ移り、返却完了時の焦点を確認できます。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("手動待機は取消や失効で終了しません。失効後もworkerの局所参照が実終了まで残り得ます。返却後に旧素材・完成画像・成功表示が復活せず、書込み数が増えないことを確認します。診断には画像や操作履歴を保持しません。")
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Button("初回案内から開始") { lab.beginCapture(showFirstGuide: true) }.disabled(!lab.canStartFresh)
                    Button("案内既読で開始") { lab.beginCapture(showFirstGuide: false) }.disabled(!lab.canStartFresh)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Button("通常の取得で開始・追加") { lab.beginCapture() }
                    Button("次の取得を1回失敗させて開始・追加") { lab.beginCapture(.failure) }
                    Button("次の取得を手動待機して開始・追加") { lab.beginCapture(.manual) }
                    Button("次の追加選択をEscで取消") { lab.beginCapture(.selectionCancel) }
                }.disabled(!lab.canStartCapture)
                VStack(alignment: .leading, spacing: 8) {
                    Button("完成を準備（コピーしない）") { lab.prepareOutput(write: false) }
                    Button("合成を1回失敗させる") { lab.prepareOutput(.failure, write: false) }
                    Button("合成を手動待機してコピー") { lab.prepareOutput(.manual, write: true) }
                    Button("専用boardへコピー・再試行") { lab.prepareOutput(write: true) }
                    Button("次の書込みだけ1回失敗させる") { lab.armWritingFailure() }
                }.disabled(!lab.canPrepareOutput)
                Text("完成データが既にある再試行はそのデータを使い、合成の差替えを通りません。合成失敗・手動待機は、追加・削除・取り直しの後に試してください。書込み失敗はprepare前の模擬拒否です。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("模擬許可なしで開始") { lab.beginWithPermissionDenied() }.disabled(!lab.canStartFresh)
                    Button("模擬許可を成立・再試行は手動") { lab.allowPermissionForExplicitRetry() }
                        .disabled(capture.phase != .permission)
                }
                Button("診断を隠して収集パネルへ戻る") { lab.returnToCollection() }
                Text(capture.statusText).font(.callout).fixedSize(horizontal: false, vertical: true)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(width: 530, height: min(660, (NSScreen.main?.visibleFrame.height ?? 800) - 120))
    }
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("状態: \(capture.phase.rawValue)・処理中: \(capture.isWorking ? "はい" : "いいえ")・共有worker: \(CaptureWorkerSlot.shared.isOccupied ? "使用中" : "空き")")
            Text("保持素材: \(capture.assets.count)枚・完成画像/PNG: \(capture.completed == nil ? "なし" : "あり")")
            Text("手動待機: \(lab.pendingWorker?.rawValue ?? "なし")")
            Text("取得 開始\(lab.captureStarts)／返却\(lab.captureResultsReturned)・合成 開始\(lab.compositionStarts)／返却\(lab.compositionResultsReturned)")
            Text("返却には失敗も含む・選択Esc \(lab.selectionCancels)回")
            Text("専用board 書込み試行\(lab.clipboardWriteAttempts)／受理\(lab.clipboardWritesAccepted)・次回失敗 \(lab.writingFailureArmed ? "あり" : "なし")")
            Text("模擬許可: \(lab.permissionAllowed ? "成立" : "不成立")")
            Text("セッション監視: \(NativeCaptureInterface.shared.captureEnvironmentStatus)")
            Text(NativeCaptureInterface.shared.captureSessionDiagnostics)
        }.font(.callout).monospacedDigit()
    }
}
#endif
