import AppKit
import Carbon
import SwiftUI

@main
struct OneClipApp: App {
    @NSApplicationDelegateAdaptor(OneClipAppDelegate.self) private var delegate
    @StateObject private var capture = SingleCaptureCoordinator.shared
    @StateObject private var collection = CollectionCaptureCoordinator.shared
    @StateObject private var keys = ProductHotKeyController.shared
    var body: some Scene {
        MenuBarExtra {
            Text("OneClip — まとめ撮りbeta 開発中")
            #if DEBUG
            if M2FailureLab.isEnabled || M3FailureLab.isEnabled { Text("安全な試験モード・一般コピーなし") }
            #endif
            Text(capture.statusText)
            Divider()
            Button { OneClipModeActions.single() } label: {
                Label("範囲をコピー", systemImage: "viewfinder")
            }
                .disabled(!capture.canBegin || capture.hasRetainedImage || collection.isWorking || collection.phase == .selecting || collection.phase == .permission || collection.phase == .onboarding)
            if capture.isWorking || capture.phase == .selecting {
                Button("撮影を取り消す") { capture.cancel() }
                    .disabled(capture.phase == .writing)
            }
            if capture.problem != nil {
                Button(capture.hasRetainedImage ? "未コピーの画像を確認…" : "取得結果を確認…") { capture.showCurrentProblem() }
            }
            Button { OneClipModeActions.collection() } label: {
                Label(collection.isActive ? "収集に追加…" : "集めてコピー…", systemImage: "square.stack")
            }
                .disabled(capture.isWorking || capture.phase == .selecting || capture.phase == .permission || capture.phase == .onboarding || collection.isWorking || collection.phase == .selecting || collection.phase == .permission || collection.phase == .onboarding || NativeCaptureInterface.shared.captureEntryBlocked)
            if collection.isActive {
                Text(collection.statusText)
                Button("集めた素材を確認…") { collection.showPanel() }
            }
            Divider()
            Text("まとめ撮りキー: \(keys.hasPendingCleanup ? "停止中・登録解除が必要" : keys.activeCollectionChord?.displayName ?? "未登録")")
            Text("撮影キー: \(keys.hasPendingCleanup ? "停止中・登録解除が必要" : keys.activeChord?.displayName ?? "未登録")")
            Button { CaptureSettingsController.shared.show() } label: {
                Label("設定…", systemImage: "slider.horizontal.3")
            }
                .disabled(capture.isWorking || capture.phase == .selecting || capture.phase == .permission || capture.phase == .onboarding || NativeCaptureInterface.shared.hasDiscardConfirmation || collection.isWorking || collection.phase == .selecting || collection.phase == .onboarding || collection.phase == .permission || NativeCaptureInterface.shared.collectionPresentationBlocksEntry)
                .keyboardShortcut(",")
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
            Label("OneClip", systemImage: "viewfinder")
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
        let keys = ProductHotKeyController.shared
        keys.deliveryAllowed = {
            capture.canBegin && !interface.captureEntryBlocked && !collection.isWorking
                && ![.selecting, .onboarding, .permission].contains(collection.phase)
        }
        keys.onPressed = { OneClipModeActions.single() }
        keys.collectionDeliveryAllowed = {
            !capture.isWorking && ![.selecting, .onboarding, .permission].contains(capture.phase)
                && !interface.captureEntryBlocked && !collection.isWorking
                && [.idle, .ready].contains(collection.phase)
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
        // Keep an already visible collection decision valid. Preparing quit would change
        // its revision before requestClose can reject the overlapping presentation.
        guard !NativeCaptureInterface.shared.collectionConfirmationPending else { return .terminateCancel }
        let capture = SingleCaptureCoordinator.shared
        capture.prepareToQuit()
        let collection = CollectionCaptureCoordinator.shared
        collection.prepareToQuit()
        if collection.hasRetainedImages {
            awaitingQuitDecision = true
            collection.showPanel()
            CollectionPanelController.shared.requestClose { [weak self] confirmed in
                if confirmed { capture.stop(); collection.stop() }
                // requestClose may reject synchronously when another decision is already open.
                // Reply only after this delegate method has returned terminateLater.
                Task { @MainActor [weak self] in
                    self?.awaitingQuitDecision = false
                    sender.reply(toApplicationShouldTerminate: confirmed)
                }
            }
            return .terminateLater
        }
        guard capture.hasRetainedImage else { return .terminateNow }
        awaitingQuitDecision = true
        NativeCaptureInterface.shared.confirmDiscard { [weak self] confirmed in
            if confirmed { capture.stop(); collection.stop() }
            Task { @MainActor [weak self] in
                self?.awaitingQuitDecision = false
                sender.reply(toApplicationShouldTerminate: confirmed)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
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
    static func single() {
        guard !NativeCaptureInterface.shared.captureEntryBlocked else { return }
        let collection = CollectionCaptureCoordinator.shared
        if collection.isActive { collection.showPanel(); return }
        SingleCaptureCoordinator.shared.begin()
    }
    static func collection() {
        guard !NativeCaptureInterface.shared.captureEntryBlocked else { return }
        #if DEBUG
        if M2FailureLab.isEnabled { return }
        #endif
        let single = SingleCaptureCoordinator.shared
        guard !single.isWorking, ![.selecting, .onboarding, .permission].contains(single.phase) else { return }
        if single.hasRetainedImage { single.showCurrentProblem(); return }
        CollectionCaptureCoordinator.shared.beginOrAdd()
    }
}
