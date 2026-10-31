import AppKit
import Carbon
import Combine
import SwiftUI

@main
struct OneClipApp: App {
    @NSApplicationDelegateAdaptor(OneClipAppDelegate.self) private var delegate
    @StateObject private var capture = SingleCaptureCoordinator.shared
    @StateObject private var collection = CollectionCaptureCoordinator.shared
    @StateObject private var keys = ProductHotKeyController.shared
    @StateObject private var result = CaptureResultController.shared
    var body: some Scene {
        MenuBarExtra {
            Text("OneClip — まとめ撮りbeta 開発中")
            #if DEBUG
            if M2FailureLab.isEnabled || M3FailureLab.isEnabled { Text("安全な試験モード・一般コピーなし") }
            #endif
            Text(capture.statusText)
            if result.hasPendingSave {
                Text(result.message)
                Button(result.isSaving ? "画像を保存中…" : "画像の保存を再試行") { result.retrySave() }.disabled(result.isSaving)
                Button("保存せずに続ける") { result.discardUnsaved() }.disabled(result.isSaving)
            }
            Button("最新の画像をプレビューで編集…") { result.editLatest() }
                .disabled(result.latestURL == nil)
            Button("保存フォルダを開く") { result.openFolder() }
            Divider()
            Button { OneClipModeActions.single() } label: {
                Label("範囲をコピー", systemImage: "viewfinder")
            }
                .disabled(!OneClipModeActions.canStartSingle)
            if capture.isWorking || capture.phase == .selecting {
                Button("撮影を取り消す") { capture.cancel() }
                    .disabled(capture.phase == .writing)
            }
            if capture.problem != nil {
                Button(capture.hasRetainedImage ? "未コピーの画像を確認…" : "取得結果を確認…") { capture.showCurrentProblem() }
            }
            Button { OneClipModeActions.collection() } label: {
                Label(OneClipModeActions.collectionEntryTitle, systemImage: "square.stack")
            }
                .disabled(!OneClipModeActions.canStartCollection)
            if collection.isActive {
                Text(collection.contentStatusText)
                Text(collection.statusText)
                Button("集めた素材を編集…") { collection.showPanel() }
                if collection.isCopiedCurrent {
                    Button("このまとめに追加…") { collection.beginOrAdd() }.disabled(!collection.canAdd)
                }
                Button("新しいまとめを開始…") { OneClipModeActions.newCollection() }.disabled(!collection.canEdit)
                Button("まとめ撮りの編集を終了…") {
                    collection.showPanel(); CollectionPanelController.shared.requestClose()
                }.disabled(!collection.canEndSession)
            }
            if let notice = collection.invalidationNotice {
                Text(notice)
                Button("前のまとめの結果を確認…") { collection.showPanel() }
            }
            if collection.externalOperationBlocked(), collection.isActive {
                Text(collection.blockedOperationMessage ?? "単発の処理が終わるまで素材は閲覧のみです")
                Button("単発の画像を確認…") { capture.showCurrentProblem() }
                    .disabled(capture.problem == nil)
            }
            Divider()
            Text("まとめ撮りキー: \(keys.hasPendingCleanup ? "停止中・登録解除が必要" : keys.activeCollectionChord?.displayName ?? "未登録")")
            Text("撮影キー: \(keys.hasPendingCleanup ? "停止中・登録解除が必要" : keys.activeChord?.displayName ?? "未登録")")
            Button { CaptureSettingsController.shared.show() } label: {
                Label("設定…", systemImage: "slider.horizontal.3")
            }
                .disabled(capture.isWorking || capture.phase == .selecting || capture.phase == .permission || capture.phase == .onboarding || NativeCaptureInterface.shared.hasDiscardConfirmation || collection.isWorking || collection.phase == .selecting || collection.phase == .onboarding || collection.phase == .permission || NativeCaptureInterface.shared.collectionPresentationBlocksEntry)
                .keyboardShortcut(",")
            Button("使い方…") { NativeCaptureInterface.shared.showUsageGuide() }
                .disabled(NativeCaptureInterface.shared.hasDiscardConfirmation || capture.isWorking || collection.isWorking
                          || capture.phase == .selecting || collection.phase == .selecting)
            #if DEBUG
            Divider()
            if M3FailureLab.isEnabled {
                Button("M3 安全な失敗試験…") { M3FailureLab.shared.show() }
                    .disabled(NativeCaptureInterface.shared.collectionConfirmationPending)
            }
            if M2FailureLab.isEnabled {
                Button("M2 安全な失敗試験…") { M2FailureLab.shared.show() }
                    .disabled(capture.phase == .selecting || NativeCaptureInterface.shared.hasDiscardConfirmation)
            }
            Button("M1 練習画面を開く…") { NativeCaptureInterface.shared.showPractice() }
                .disabled(capture.isWorking || capture.phase == .selecting || NativeCaptureInterface.shared.hasDiscardConfirmation || M2FailureLab.isEnabled || M3FailureLab.isEnabled)
            if !M2FailureLab.isEnabled && !M3FailureLab.isEnabled {
                Menu("M3 試用の架空画面") {
                    ForEach(M3PracticeStage.allCases, id: \.self) { stage in
                        Button(stage.menuTitle) { NativeCaptureInterface.shared.showPractice(stage: stage) }
                            .disabled(capture.isWorking || collection.isWorking || capture.phase == .selecting || collection.phase == .selecting || NativeCaptureInterface.shared.captureEntryBlocked)
                    }
                    Divider()
                    Button("設定結果の通知診断…") { CaptureSettingsController.shared.showNotificationDiagnostics() }
                        .disabled(!CaptureSettingsController.shared.canShowNotificationDiagnostics)
                }
            }
            Button("M0 検証パネル…") { M0LabController.shared.show() }
                .disabled(collection.isActive || collection.isWorking || capture.isWorking || capture.phase == .selecting || NativeCaptureInterface.shared.hasDiscardConfirmation || keys.desiredChord != nil || M2FailureLab.isEnabled || M3FailureLab.isEnabled)
            #endif
            Divider()
            Button("OneClipを終了") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Label(collection.hasRetainedImages ? "OneClip・\(collection.assets.count)枚" : "OneClip", systemImage: "viewfinder")
        }
        .menuBarExtraStyle(.menu)
        #if DEBUG
        .commands {
            CommandMenu("試験") {
                if !M2FailureLab.isEnabled && !M3FailureLab.isEnabled {
                    ForEach(M3PracticeStage.allCases, id: \.self) { stage in
                        Button(stage.menuTitle) { NativeCaptureInterface.shared.showPractice(stage: stage) }
                            .disabled(capture.isWorking || collection.isWorking || capture.phase == .selecting || collection.phase == .selecting || NativeCaptureInterface.shared.captureEntryBlocked)
                    }
                    Button("設定結果の通知診断…") { CaptureSettingsController.shared.showNotificationDiagnostics() }
                        .disabled(!CaptureSettingsController.shared.canShowNotificationDiagnostics)
                }
                if M3FailureLab.isEnabled {
                    Button("M3 安全な失敗試験を表示") { M3FailureLab.shared.show() }
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                        .disabled(NativeCaptureInterface.shared.collectionConfirmationPending)
                }
                if M2FailureLab.isEnabled {
                    Button("M2 安全な失敗試験を表示") { M2FailureLab.shared.show() }
                        .disabled(NativeCaptureInterface.shared.hasDiscardConfirmation)
                }
            }
        }
        #endif
    }
}

@MainActor
final class OneClipAppDelegate: NSObject, NSApplicationDelegate {
    private var awaitingQuitDecision = false
    private var stateSubscriptions: Set<AnyCancellable> = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--m0-self-test"), !M2FailureLab.isEnabled, !M3FailureLab.isEnabled {
            Task { await M0RuntimeChecks.run() }
            return
        }
        #endif
        let capture = SingleCaptureCoordinator.shared
        let interface = NativeCaptureInterface.shared
        let collection = CollectionCaptureCoordinator.shared
        CaptureSettingsController.shared.canShowAdditional = {
            !collection.isWorking && ![.selecting, .onboarding, .permission].contains(collection.phase) && !interface.collectionPresentationBlocksEntry
        }
        interface.settingsBlockCapture = {
            if CaptureSettingsController.shared.blocksCapture { return true }
            #if DEBUG
            if M2FailureLab.isEnabled, M2FailureLab.shared.isVisible { return true }
            if M3FailureLab.isEnabled, M3FailureLab.shared.isVisible { return true }
            #endif
            return false
        }
        collection.externalOperationBlocked = {
            capture.isWorking || capture.hasRetainedImage || [.selecting, .onboarding, .permission].contains(capture.phase)
        }
        collection.externalWorkInProgress = {
            capture.isWorking || [.selecting, .onboarding, .permission].contains(capture.phase)
        }
        collection.externalOperationMessage = {
            capture.hasRetainedImage ? "単発の未コピー画像があります。確認して再コピーするか破棄してください。"
                : "単発の処理が終わるまで、このまとめの追加・編集・コピーを停止しています。"
        }
        collection.recoverExternalOperation = { capture.showCurrentProblem() }
        capture.prepareExternalCapture = { collection.prepareForSingleCapture() }
        capture.externalRetainedBytes = { collection.retainedImageBytes }
        capture.objectWillChange.sink { [weak collection] _ in
            MainActor.assumeIsolated { collection?.objectWillChange.send() }
        }.store(in: &stateSubscriptions)
        CaptureResultController.shared.objectWillChange.sink { [weak capture, weak collection] _ in
            MainActor.assumeIsolated {
                capture?.objectWillChange.send()
                collection?.objectWillChange.send()
            }
        }.store(in: &stateSubscriptions)
        let keys = ProductHotKeyController.shared
        keys.deliveryAllowed = {
            OneClipModeActions.canStartSingle
        }
        keys.onPressed = { OneClipModeActions.single() }
        keys.collectionDeliveryAllowed = {
            OneClipModeActions.canStartCollection
        }
        keys.onCollectionPressed = { OneClipModeActions.collection() }
        #if DEBUG
        keys.reservedChords = {
            M0LabController.shared.hotKey.isRegistered
                ? [HotKeyChord(keyCode: 25, modifiers: UInt32(controlKey | optionKey | cmdKey))] : []
        }
        if M2FailureLab.isEnabled { M2FailureLab.shared.show(); return }
        if M3FailureLab.isEnabled { M3FailureLab.shared.show(); return }
        #endif
        keys.start()
        interface.showWelcomeIfNeeded()
        #if DEBUG && ONECLIP_M3_SETTINGS_TRIAL
        // Explicit, separately identified Debug artifact; keep the normal settings path.
        CaptureSettingsController.shared.show()
        #endif
    }

    func applicationProtectedDataWillBecomeUnavailable(_ notification: Notification) {
        NativeCaptureInterface.shared.environmentDidChange(.protectedDataUnavailable)
        #if DEBUG
        M0LabController.shared.invalidate(hide: true)
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !awaitingQuitDecision else { return .terminateLater }
        guard CaptureResultController.shared.prepareToQuit() else { return .terminateCancel }
        let interface = NativeCaptureInterface.shared
        guard !interface.collectionConfirmationPending, !interface.hasDiscardConfirmation else { return .terminateCancel }
        let capture = SingleCaptureCoordinator.shared
        let collection = CollectionCaptureCoordinator.shared
        guard capture.phase != .writing, collection.phase != .writing else { return .terminateCancel }
        capture.prepareToQuit(); collection.prepareToQuit()
        guard capture.hasRetainedImage || collection.needsEndConfirmation else { return .terminateNow }
        awaitingQuitDecision = true
        interface.confirmEndAll(singleImage: capture.hasRetainedImage, collectionCount: collection.assets.count,
                                hasCandidate: collection.pendingReplacement != nil) { [weak self] confirmed in
            if confirmed { capture.stop(); collection.stop() }
            Task { @MainActor [weak self] in
                self?.awaitingQuitDecision = false
                sender.reply(toApplicationShouldTerminate: confirmed)
            }
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let capture = SingleCaptureCoordinator.shared
        let collection = CollectionCaptureCoordinator.shared
        let interface = NativeCaptureInterface.shared
        if interface.hasDiscardConfirmation || interface.collectionConfirmationPending { return true }
        if capture.problem != nil { capture.showCurrentProblem() }
        else if collection.isActive || collection.invalidationNotice != nil { collection.showPanel() }
        else if !capture.isWorking && !collection.isWorking && capture.phase != .selecting { interface.showUsageGuide() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        CaptureResultController.shared.environmentDidChange()
        ProductHotKeyController.shared.stop()
        CaptureSettingsController.shared.hide()
        SingleCaptureCoordinator.shared.stop()
        CollectionCaptureCoordinator.shared.stop()
        NativeCaptureInterface.shared.stopEnvironmentMonitoring()
        #if DEBUG
        if M2FailureLab.isEnabled || M3FailureLab.isEnabled { M2FailureLab.shared.stop() }
        if M3FailureLab.isEnabled { M3FailureLab.shared.stop() }
        M0LabController.shared.stop()
        #endif
    }
}

@MainActor
enum OneClipModeActions {
    static var canStartSingle: Bool {
        let single = SingleCaptureCoordinator.shared
        return single.canBegin && !single.hasRetainedImage && CollectionCaptureCoordinator.shared.canStartSingle
            && !NativeCaptureInterface.shared.captureEntryBlocked
    }
    static var canStartCollection: Bool {
        let single = SingleCaptureCoordinator.shared
        let collection = CollectionCaptureCoordinator.shared
        return !single.isWorking && !single.hasRetainedImage
            && ![.selecting, .onboarding, .permission].contains(single.phase)
            && !NativeCaptureInterface.shared.captureEntryBlocked && !collection.isWorking
            && [.idle, .ready].contains(collection.phase) && collection.pendingReplacement == nil
    }
    static var collectionEntryTitle: String {
        let collection = CollectionCaptureCoordinator.shared
        if collection.invalidationNotice != nil { return "前のまとめの結果を確認…" }
        if collection.isCopiedCurrent { return "新しく集めてコピー…" }
        if collection.assets.count == 4 { return "集めた素材を確認…" }
        return collection.isActive ? "収集に追加…" : "集めてコピー…"
    }
    static func single() {
        guard canStartSingle else { return }
        SingleCaptureCoordinator.shared.begin()
    }
    static func collection() {
        guard canStartCollection else { return }
        #if DEBUG
        if M2FailureLab.isEnabled { return }
        #endif
        CollectionCaptureCoordinator.shared.beginFromShortcut()
    }
    static func newCollection() {
        let collection = CollectionCaptureCoordinator.shared
        guard collection.canEdit else { return }
        if collection.needsEndConfirmation {
            collection.showPanel(); CollectionPanelController.shared.requestNewSession()
        } else { collection.beginNewSession() }
    }
}
