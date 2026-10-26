#if DEBUG
import AppKit
import SwiftUI

/// An explicit launch mode. All acquisition, permission and clipboard services are replaced.
/// This mode never reads a screen or the general pasteboard, even after a retry succeeds.
@MainActor
final class M2FailureLab: ObservableObject, ScreenshotCapturing, CaptureClipboardWriting {
    static let shared = M2FailureLab()
    static var isEnabled: Bool { CommandLine.arguments.contains("--m2-failure-lab") }
    enum Scenario: String, CaseIterable {
        case capture = "取得失敗（画像なし）"
        case encoding = "画像準備の失敗（画像保持）"
        case writing = "書込み失敗（画像保持）"
        case delayed = "8秒待つ処理（取消・アプリ切替）"
        case delayedFailure = "8秒後の取得失敗（アプリ切替）"
        case permission = "権限案内（OSは変更しない）"
        case d06Retained = "D06 画像とPNGを保持して待機"
        case d06CapturePending = "D06 取得を待機（手動返却）"
        case d06EncodingPending = "D06 画像準備を待機（手動返却）"
    }
    enum PendingWorker: String {
        case capture = "取得結果の返却待ち"
        case encoding = "画像準備結果の返却待ち"
    }
    @Published private(set) var pendingWorker: PendingWorker?
    @Published private(set) var captureStarts = 0
    @Published private(set) var encodingStarts = 0
    @Published private(set) var captureResultsReturned = 0
    @Published private(set) var encodingResultsReturned = 0
    @Published private(set) var clipboardWriteAttempts = 0
    private var window: NSWindow?
    private var board: NSPasteboard?
    private var captureFails = false
    private var encodingFails = false
    private var writingFails = false
    private var delayed = false
    private var permissionAllowed = true
    private var holdNextCapture = false
    private var holdNextEncoding = false
    private var pendingResult: CheckedContinuation<Void, Never>?
    private var hasStopped = false
    private weak var native: NativeCaptureInterface?
    private(set) var scenario = Scenario.capture
    var isVisible: Bool { window?.isVisible == true }

    func makeCoordinator(interface: NativeCaptureInterface) -> SingleCaptureCoordinator {
        native = interface
        board = .withUniqueName()
        return SingleCaptureCoordinator(capturer: self, interface: M2TrialInterface(native: interface), clipboard: self,
            permissionCheck: { [weak self] in self?.permissionAllowed == true },
            permissionRequest: { [weak self] in self?.permissionAllowed = true; return true },
            protectedDataCheck: { NSApp.isProtectedDataAvailable },
            displayAtPointer: { try CaptureDisplaySnapshot(id: 1, frame: CGRect(x: 0, y: 0, width: 640, height: 360), scale: 1) },
            preferences: CapturePreferences(defaults: nil, hasSeenCaptureGuide: true, hasSeenPasteHint: true),
            encode: { [weak self] asset in
                guard let self else { throw ScreenshotError.invalidated }
                return try await self.encodeFixture(asset)
            })
    }

    func show() {
        guard Self.isEnabled, !NativeCaptureInterface.shared.hasDiscardConfirmation else { return }
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 390),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "OneClip — M2 安全な失敗試験"
            panel.isRestorable = false
            panel.isReleasedWhenClosed = false
            panel.center()
            panel.contentView = NSHostingView(rootView: M2FailureLabView(lab: self, capture: .shared))
            window = panel
        }
        if let content = window?.contentView { window?.setContentSize(content.fittingSize) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// This image-free diagnostic window is separate from the product's capture/failure UI.
    /// It must not activate OneClip or become key when an external application is in use.
    private func showDiagnosticsWithoutActivation() {
        guard Self.isEnabled, !hasStopped else { return }
        window?.orderFront(nil)
    }

    func run(_ scenario: Scenario) {
        let capture = SingleCaptureCoordinator.shared
        guard !hasStopped, pendingWorker == nil, pendingResult == nil,
              !capture.isWorking, !capture.hasRetainedImage, capture.phase != .selecting,
              capture.phase != .permission, capture.phase != .onboarding else { return }
        self.scenario = scenario
        captureFails = scenario == .capture || scenario == .delayedFailure
        encodingFails = scenario == .encoding
        writingFails = scenario == .writing || scenario == .d06Retained
        delayed = scenario == .delayed || scenario == .delayedFailure
        permissionAllowed = scenario != .permission
        holdNextCapture = scenario == .d06CapturePending
        holdNextEncoding = scenario == .d06EncodingPending
        window?.orderOut(nil)
        capture.begin()
    }

    func capture(_ request: SingleCaptureRequest, isCurrent: @escaping @MainActor () -> Bool) async throws -> M0ImageAsset {
        captureStarts += 1
        if holdNextCapture {
            holdNextCapture = false
            try await waitForManualResult(.capture)
        }
        if delayed {
            delayed = false
            // Deliberately finishes after cancellation; coordinator must reject the stale result.
            await Task.detached { try? await Task.sleep(for: .seconds(8)) }.value
        }
        if captureFails { captureFails = false; throw ScreenshotError.captureFailed }
        let asset = try M0ImageFixture.make(index: 1, width: 320, height: 180, scale: 1)
        captureResultsReturned += 1
        return asset
    }

    private func encodeFixture(_ asset: M0ImageAsset) async throws -> M0CompositionResult {
        encodingStarts += 1
        let fail = encodingFails
        encodingFails = false
        if fail { throw ScreenshotError.captureFailed }
        if holdNextEncoding {
            holdNextEncoding = false
            try await waitForManualResult(.encoding)
        }
        // The detached worker deliberately ignores cancellation, just like a late framework result.
        let result = try await Task.detached { try M0ImageComposer.compose(assets: [asset]) }.value
        encodingResultsReturned += 1
        return result
    }

    private func waitForManualResult(_ worker: PendingWorker) async throws {
        guard pendingResult == nil, pendingWorker == nil, !hasStopped else { throw ScreenshotError.busy }
        // No timer or cancellation handler: an OS transition cannot accidentally finish this worker.
        // The coordinator must retain its worker slot until the explicit release returns a result.
        await withCheckedContinuation { continuation in
            pendingResult = continuation
            pendingWorker = worker
            // Selection has already been confirmed. Showing this earlier would block confirm()
            // through captureEntryBlocked because the diagnostic window counts as settings UI.
            showDiagnosticsWithoutActivation()
        }
    }

    func returnPendingResult() {
        guard let continuation = pendingResult else { return }
        pendingResult = nil
        pendingWorker = nil
        continuation.resume()
    }

    func resetCounters() {
        guard !hasStopped, pendingResult == nil, pendingWorker == nil,
              !SingleCaptureCoordinator.shared.isWorking else { return }
        captureStarts = 0
        encodingStarts = 0
        captureResultsReturned = 0
        encodingResultsReturned = 0
        clipboardWriteAttempts = 0
    }

    var changeCount: Int { board?.changeCount ?? 0 }
    func writePNG(_ data: Data, expectedChangeCount: Int) -> M0ClipboardProbe.Outcome {
        clipboardWriteAttempts += 1
        if writingFails {
            writingFails = false
            if scenario == .d06Retained {
                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, !self.hasStopped, self.scenario == .d06Retained else { return }
                    let capture = SingleCaptureCoordinator.shared
                    guard !capture.isWorking, capture.phase == .failure,
                          capture.hasRetainedImage, capture.hasRetainedPNG else { return }
                    self.showDiagnosticsWithoutActivation()
                }
            }
            return .init(code: .writeRejected, expectedChangeCount: expectedChangeCount,
                         observedChangeCount: changeCount, preparedChangeCount: nil)
        }
        guard let board else {
            return .init(code: .writeRejected, expectedChangeCount: expectedChangeCount,
                         observedChangeCount: 0, preparedChangeCount: nil)
        }
        return M0ClipboardProbe.writePNG(data, to: board, expectedChangeCount: expectedChangeCount)
    }

    func stop() {
        hasStopped = true
        holdNextCapture = false
        holdNextEncoding = false
        // Application shutdown must never leave a test continuation suspended indefinitely.
        returnPendingResult()
        board?.releaseGlobally()
        board = nil
        window?.orderOut(nil)
    }
}

@MainActor
private final class M2TrialInterface: SingleCaptureInterface {
    let native: NativeCaptureInterface
    init(native: NativeCaptureInterface) { self.native = native }
    var isOneClipActive: Bool { native.isOneClipActive }
    var captureEntryBlocked: Bool { native.captureEntryBlocked }
    var captureEnvironmentStatus: String { native.captureEnvironmentStatus }
    func prepareCaptureEnvironment() -> Bool { native.prepareCaptureEnvironment() }
    func validateCaptureEnvironment() -> Bool { native.validateCaptureEnvironment() }
    func prepareForSelection() -> Bool { native.prepareForSelection() }
    func showSelection(on display: CaptureDisplaySnapshot, selected: @escaping @MainActor (CaptureSelection) -> Void,
                       cancelled: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            await Task.yield()
            if let selection = try? CaptureSelection(display: display, rect: CGRect(x: 40, y: 40, width: 320, height: 180)) {
                selected(selection)
            } else { cancelled() }
        }
    }
    func hideSelection() -> Bool { true }
    func showPermission() { native.showPermission() }
    func hidePermission() { native.hidePermission() }
    func showProblem(activate: Bool) { native.showProblem(activate: activate) }
    func hideProblem() { native.hideProblem() }
    func showFeedback(_ message: String) { native.showFeedback("安全な試験: \(message)（専用board）") }
    func dismissAll() { native.dismissAll() }
    func rememberExternalApplication() { native.rememberExternalApplication() }
    func returnToExternalApplication() { native.returnToExternalApplication() }
}

private struct M2FailureLabView: View {
    @ObservedObject var lab: M2FailureLab
    @ObservedObject var capture: SingleCaptureCoordinator
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text("M2 安全な失敗試験").font(.title2.bold())
            Text("この起動中は架空画像・専用クリップボードだけを使います。実画面取得、一般クリップボードの変更、OSへの許可要求は行いません。")
            Text("各失敗は1回だけ発生し、再試行は同じ安全な経路を使います。権限案内の「許可を要求」も模擬です。実TCC合格の根拠にはなりません。")
                .font(.callout).foregroundStyle(.secondary)
            Text("D06の検証支援です。まとめ撮りの製品機能ではありません。保持待機ではPNG作成後の書込みだけを模擬失敗させます。手動返却の処理は、実際のロック・スリープ・ユーザー切替から戻っても自動終了しません。")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("状態: \(capture.phase.rawValue)・処理中: \(capture.isWorking ? "はい" : "いいえ")")
                Text("保持画像: \(capture.hasRetainedImage ? "あり" : "なし")・保持PNG: \(capture.hasRetainedPNG ? "あり" : "なし")")
                Text("セッション監視: \(NativeCaptureInterface.shared.captureEnvironmentStatus)")
                Text(NativeCaptureInterface.shared.captureSessionDiagnostics)
                Text("利用状態の失効: \(capture.environmentInvalidationCount)回・最終通知: \(capture.lastEnvironmentEvent)")
                Text("直近失効時: 処理中 \(capture.invalidatedWhileWorking ? "はい" : "いいえ")・画像保持 \(capture.invalidatedWithImage ? "あり" : "なし")")
                Text("手動待機: \(lab.pendingWorker?.rawValue ?? "なし")")
                Text("取得開始 \(lab.captureStarts)・画像準備開始 \(lab.encodingStarts)")
                Text("結果返却: 取得 \(lab.captureResultsReturned)・画像準備 \(lab.encodingResultsReturned)・専用board書込み試行 \(lab.clipboardWriteAttempts)")
            }.font(.callout).monospacedDigit()
            Button("遅い結果を返す") { lab.returnPendingResult() }
                .disabled(lab.pendingWorker == nil)
            Text("D06の待機中はこの診断画面を再表示します。この画面には画像を表示せず、製品の確認画面とは別です。閉じた場合はメニューの「M2 安全な失敗試験…」で戻れます。返却前に「処理中: はい」と手動待機の種類を確認します。失効後の返却で旧画像・再コピー・成功表示が戻らないことを別に確認してください。")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(M2FailureLab.Scenario.allCases, id: \.self) { scenario in
                Button(scenario.rawValue) { lab.run(scenario) }
                    .disabled(lab.pendingWorker != nil || capture.isWorking || capture.hasRetainedImage || [.permission, .selecting, .onboarding].contains(capture.phase))
            }
            Button("測定値をリセット") { lab.resetCounters() }
                .disabled(lab.pendingWorker != nil || capture.isWorking)
            Text(capture.statusText).font(.callout)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(width: 490, height: min(500, (NSScreen.main?.visibleFrame.height ?? 800) - 120))
    }
}
#endif
