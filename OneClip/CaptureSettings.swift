import Accessibility
import AppKit
import Carbon
import SwiftUI

@MainActor
final class CaptureSettingsController: NSObject, NSWindowDelegate {
    static let shared = CaptureSettingsController()
    private var window: NSWindow?
    var isVisible: Bool {
        #if DEBUG
        if showingNotificationDiagnostics { return true }
        #endif
        return window?.isVisible == true
    }
    /// The app supplies collection/confirmation availability without coupling settings to its owner.
    var canShowAdditional: (@MainActor () -> Bool)?
    #if DEBUG
    private var attemptCount = 0
    private var postAttemptCount = 0
    private var lastAppActive = false
    private var lastWindowVisible = false
    private var lastWindowKey = false
    private var showingNotificationDiagnostics = false
    #endif

    fileprivate func isRecordingWindow(_ candidate: NSWindow?) -> Bool {
        guard let window, candidate === window else { return false }
        return window.isVisible && window.isKeyWindow
    }

    fileprivate func announceKeySettingResult(_ message: String) {
        #if DEBUG
        if attemptCount < Int.max { attemptCount += 1 }
        lastAppActive = NSApp.isActive
        lastWindowVisible = window?.isVisible == true
        lastWindowKey = window?.isKeyWindow == true
        #endif
        guard NSApp.isActive, isRecordingWindow(window) else { return }
        #if DEBUG
        if postAttemptCount < Int.max { postAttemptCount += 1 }
        #endif
        // Posting is an attempt, not evidence that VoiceOver consumed or spoke the result.
        AccessibilityNotification.Announcement(message).post()
    }

    #if DEBUG
    var canShowNotificationDiagnostics: Bool {
        guard !M2FailureLab.isEnabled, !M3FailureLab.isEnabled,
              !M0LabController.shared.busy, !showingNotificationDiagnostics,
              !CaptureWorkerSlot.shared.isOccupied else { return false }
        let capture = SingleCaptureCoordinator.shared
        let collection = CollectionCaptureCoordinator.shared
        let interface = NativeCaptureInterface.shared
        return !capture.isWorking && [.idle, .failure].contains(capture.phase)
            && !collection.isWorking && [.idle, .ready].contains(collection.phase)
            && !interface.hasDiscardConfirmation && !interface.collectionPresentationBlocksEntry
            && window?.attachedSheet == nil && canShowAdditional?() != false
    }

    func showNotificationDiagnostics() {
        guard canShowNotificationDiagnostics else { return }
        let keys = ProductHotKeyController.shared
        keys.cancelShortcutRecording()
        showingNotificationDiagnostics = true
        keys.settingsInteractionBlocked = true
        defer {
            showingNotificationDiagnostics = false
            keys.settingsInteractionBlocked = window?.isVisible == true
            NativeCaptureInterface.shared.collectionCoordinator?.objectWillChange.send()
        }
        let alert = NSAlert()
        alert.messageText = "設定結果の通知診断"
        alert.informativeText = "attemptCount: \(attemptCount)\npostAttemptCount: \(postAttemptCount)\nlastAppActive: \(lastAppActive)\nlastWindowVisible: \(lastWindowVisible)\nlastWindowKey: \(lastWindowKey)"
        alert.addButton(withTitle: "閉じる")
        alert.runModal()
    }
    #endif

    func show() {
        #if DEBUG
        if M2FailureLab.isEnabled || M3FailureLab.isEnabled || showingNotificationDiagnostics { return }
        #endif
        let capture = SingleCaptureCoordinator.shared
        guard !capture.isWorking, capture.phase != .selecting,
              !NativeCaptureInterface.shared.hasDiscardConfirmation,
              canShowAdditional?() != false else { return }
        ProductHotKeyController.shared.settingsInteractionBlocked = true
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "OneClip — 設定"
            panel.isRestorable = false
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.center()
            window = panel
        }
        window?.contentView = NSHostingView(rootView: CaptureSettingsView(keys: .shared))
        if let content = window?.contentView { window?.setContentSize(content.fittingSize) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        ProductHotKeyController.shared.cancelShortcutRecording()
        window?.orderOut(nil)
        ProductHotKeyController.shared.settingsInteractionBlocked = false
        NativeCaptureInterface.shared.collectionCoordinator?.objectWillChange.send()
    }

    func windowWillClose(_ notification: Notification) {
        ProductHotKeyController.shared.cancelShortcutRecording()
        ProductHotKeyController.shared.settingsInteractionBlocked = false
        NativeCaptureInterface.shared.collectionCoordinator?.objectWillChange.send()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        ProductHotKeyController.shared.settingsInteractionBlocked = true
    }

    func windowDidResignKey(_ notification: Notification) {
        ProductHotKeyController.shared.cancelShortcutRecording()
    }
}

private struct CaptureSettingsView: View {
    @ObservedObject var keys: ProductHotKeyController
    @State private var role: CaptureHotKeyRole = .single
    @State private var candidate: HotKeyChord?
    @State private var recording = false
    @State private var inputMessage = ""
    @State private var showsHelp = false

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 24)).foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("撮影キー").font(.title2.bold())
                            Text("未設定でも、OneClipメニューから使えます。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if keys.hasPendingCleanup {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("両方の撮影キーを停止しています", systemImage: "exclamationmark.triangle")
                                .font(.callout.weight(.semibold))
                            Button("登録解除を再試行") {
                                resetInput(for: role)
                                let succeeded = keys.retryCleanup()
                                report(succeeded ? "登録解除を完了しました。" : keys.statusText(for: role))
                            }.disabled(recording)
                            ForEach(CaptureHotKeyRole.allCases) { keyRole in
                                if let detail = keys.statusDetail(for: keyRole),
                                   keyRole == .single || detail != keys.statusDetail(for: .single) {
                                    Text(detail).font(.callout).lineSpacing(3)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                    }
                    ForEach(CaptureHotKeyRole.allCases) { keyRole in
                        shortcutCard(for: keyRole)
                    }
                    Label(keys.hasPendingCleanup ? "メニューから撮影できます。" : "設定済みのキーは、設定を閉じると使えます。", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    DisclosureGroup("キーの使い方", isExpanded: $showsHelp) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("⌃ Control・⌥ Option・⌘ Commandのいずれかと、文字や数字などを組み合わせます。2つの撮影には別のキーを設定します。")
                            Text("ほかのアプリと重なる場合は、別の組み合わせを試してください。反応しない場合はシステム設定のショートカットも確認できます。すべての重複は自動検出できません。")
                            Text("キーは物理的な位置で保存します。画像・選択範囲・セッションは保存しません。")
                        }
                        .font(.callout).foregroundStyle(.secondary).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                    }.font(.callout)
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: recording) { _, isRecording in
                if isRecording { scroll.scrollTo(role, anchor: .top) }
            }
        }
        .frame(width: 500, height: min(460, (NSScreen.main?.visibleFrame.height ?? 800) - 120))
    }

    private func shortcutCard(for keyRole: CaptureHotKeyRole) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: keyRole == .single ? "viewfinder" : "square.stack")
                    .font(.system(size: 21)).foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(keyRole.title).font(.headline)
                    Text(keyRole == .single ? "選んだ範囲をすぐコピー" : "必要な箇所を1枚にまとめる")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(keys.desiredChord(for: keyRole) == nil ? "設定…" : "変更…") {
                    resetInput(for: keyRole)
                    recording = true
                }.disabled(recording || keys.hasPendingCleanup)
            }
            HStack(alignment: .center, spacing: 12) {
                if keys.hasPendingCleanup {
                    Label("停止中", systemImage: "pause.circle").foregroundStyle(.secondary)
                } else if let chord = keys.activeChord(for: keyRole) {
                    ShortcutKeycaps(chord: chord)
                    Text("設定済み").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(keys.desiredChord(for: keyRole) == nil ? "未設定" : "未登録")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                }
                Spacer(minLength: 0)
                if keys.desiredChord(for: keyRole) != nil || keys.activeChord(for: keyRole) != nil {
                    Button("解除") {
                        resetInput(for: keyRole)
                        let succeeded = keys.setChord(nil, for: keyRole)
                        report(succeeded ? "キーを解除しました。メニューから使えます。" : keys.statusText(for: keyRole))
                    }.buttonStyle(.link).disabled(recording)
                }
            }
            if let saved = keys.desiredChord(for: keyRole),
               saved != keys.activeChord(for: keyRole), !keys.hasPendingCleanup {
                VStack(alignment: .leading, spacing: 8) {
                    Text("保存したキーは未登録です").font(.callout)
                    ShortcutKeycaps(chord: saved)
                    Button("このキーで再登録") {
                        resetInput(for: keyRole)
                        let succeeded = keys.setChord(saved, for: keyRole)
                        report(succeeded ? "キーを再登録しました。" : keys.statusText(for: keyRole))
                    }.disabled(recording)
                }
            }
            if keyRole == role {
                if recording {
                    VStack(alignment: .leading, spacing: 10) {
                        Divider()
                        Text("⌃・⌥・⌘のいずれかと、文字や数字を押します。")
                            .font(.callout).foregroundStyle(.secondary)
                        ShortcutRecorder(keys: keys, recording: $recording, candidate: $candidate, message: $inputMessage)
                            .frame(height: 42)
                        Button("入力を取り消す") { resetInput(for: keyRole) }
                    }
                } else if let candidate {
                    VStack(alignment: .leading, spacing: 10) {
                        Divider()
                        Text("新しいキー").font(.callout).foregroundStyle(.secondary)
                        ShortcutKeycaps(chord: candidate)
                        HStack {
                            Button("このキーを設定") {
                                let succeeded = keys.setChord(candidate, for: role)
                                if succeeded { self.candidate = nil }
                                report(succeeded ? "設定しました。設定を閉じると使えます。" : keys.statusText(for: role))
                            }.buttonStyle(.borderedProminent)
                            Button("取り消す") { resetInput(for: keyRole) }
                        }
                    }
                }
                if !inputMessage.isEmpty {
                    Text(inputMessage).font(.callout).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let detail = keys.statusDetail(for: keyRole), !keys.hasPendingCleanup,
               keyRole != role || inputMessage.isEmpty {
                Text(detail).font(.callout).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
        .id(keyRole)
    }

    private func resetInput(for newRole: CaptureHotKeyRole) {
        keys.cancelShortcutRecording()
        recording = false
        candidate = nil
        inputMessage = ""
        role = newRole
    }

    private func report(_ message: String) {
        inputMessage = message
        CaptureSettingsController.shared.announceKeySettingResult(message)
    }
}

private struct ShortcutKeycaps: View {
    let chord: HotKeyChord

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) { caps }.fixedSize()
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    ForEach(Array(chord.keycapLabels.dropLast().enumerated()), id: \.offset) { _, label in
                        cap(label)
                    }
                }
                cap(chord.keycapLabels.last ?? "")
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(chord.displayName)
        .help(chord.displayName)
    }

    private var caps: some View {
        ForEach(Array(chord.keycapLabels.enumerated()), id: \.offset) { _, label in cap(label) }
    }

    private func cap(_ label: String) -> some View {
        Text(label).font(.system(.body, design: .rounded).weight(.medium))
            .padding(.horizontal, 8).frame(minWidth: 28, minHeight: 29)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.16)))
    }
}

/// A local first responder. No event tap, arbitrary-key observer or Accessibility access.
private struct ShortcutRecorder: NSViewRepresentable {
    let keys: ProductHotKeyController
    @Binding var recording: Bool
    @Binding var candidate: HotKeyChord?
    @Binding var message: String

    func makeNSView(context: Context) -> ShortcutRecorderView { ShortcutRecorderView() }
    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.label = recording ? "組合せを押してください（Escで取消）" : candidate?.displayName ?? "新しいキーはまだ選んでいません"
        view.onCancel = { recording = false; message = "キー入力を取り消しました。現在の設定は変えていません。" }
        view.onCandidate = { chord in
            if let reason = chord.validationMessage { message = reason; return }
            candidate = chord
            recording = false
            message = "候補です。「このキーを設定」で登録します。"
        }
        view.needsDisplay = true
        view.setRecording(recording, keys: keys)
        if recording {
            let generation = view.focusGeneration
            DispatchQueue.main.async { [weak view] in
                guard let view, view.recording, view.focusGeneration == generation,
                      NSApp.isActive, CaptureSettingsController.shared.isRecordingWindow(view.window) else { return }
                view.window?.makeFirstResponder(view)
                view.armIfNeeded()
            }
        }
    }

    static func dismantleNSView(_ view: ShortcutRecorderView, coordinator: ()) {
        view.tearDown()
    }
}

private final class ShortcutRecorderView: NSView {
    private(set) var recording = false
    private(set) var focusGeneration = UUID()
    private weak var keys: ProductHotKeyController?
    private var recordingIdentifier: UUID?
    var label = ""
    var onCandidate: ((HotKeyChord) -> Void)?
    var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    func setRecording(_ value: Bool, keys: ProductHotKeyController) {
        self.keys = keys
        if !value { cancelRecording(notify: false); return }
        if !recording { focusGeneration = UUID(); recording = true }
        armIfNeeded()
    }

    private var canRecord: Bool {
        recording && NSApp.isActive && CaptureSettingsController.shared.isRecordingWindow(window)
            && window?.firstResponder === self
    }

    func armIfNeeded() {
        guard recordingIdentifier == nil, canRecord else { return }
        let generation = focusGeneration
        recordingIdentifier = keys?.beginShortcutRecording(allowed: { [weak self] in
            guard let self else { return false }
            return self.focusGeneration == generation && self.canRecord
        }, candidate: { [weak self] chord in
            guard let self, self.focusGeneration == generation, self.canRecord else { return }
            // Do this before SwiftUI's asynchronous update, so local/Carbon duplicates cannot win.
            self.recordingIdentifier = nil
            self.recording = false
            self.focusGeneration = UUID()
            self.onCandidate?(chord)
        })
    }

    private func cancelRecording(notify: Bool) {
        if let recordingIdentifier { keys?.cancelShortcutRecording(recordingIdentifier) }
        recordingIdentifier = nil
        let wasRecording = recording
        recording = false
        focusGeneration = UUID()
        if notify && wasRecording { onCancel?() }
    }

    func tearDown() {
        cancelRecording(notify: false)
        NotificationCenter.default.removeObserver(self)
        keys = nil
        onCandidate = nil
        onCancel = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self)
        if let window {
            center.addObserver(self, selector: #selector(contextLost), name: NSWindow.didResignKeyNotification, object: window)
            center.addObserver(self, selector: #selector(contextLost), name: NSWindow.willCloseNotification, object: window)
            center.addObserver(self, selector: #selector(contextLost), name: NSApplication.didResignActiveNotification, object: NSApp)
        } else {
            cancelRecording(notify: true)
        }
    }

    @objc private func contextLost(_ notification: Notification) { cancelRecording(notify: true) }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { armIfNeeded() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { cancelRecording(notify: true) }
        return accepted
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard canRecord else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard canRecord else { super.keyDown(with: event); return }
        guard !event.isARepeat else { return }
        if event.keyCode == UInt16(kVK_Escape) { cancelRecording(notify: true); return }
        if event.keyCode == UInt16(kVK_Tab) { cancelRecording(notify: true); super.keyDown(with: event); return }
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let chord = HotKeyChord(keyCode: UInt32(event.keyCode), modifiers: modifiers & HotKeyChord.supportedModifiers)
        if chord.validationMessage != nil { onCandidate?(chord); return }
        guard let recordingIdentifier else { return }
        keys?.submitShortcutCandidate(chord, occurredAt: event.timestamp, recording: recordingIdentifier)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        (label as NSString).draw(at: NSPoint(x: 12, y: 12), withAttributes: attributes)
        setAccessibilityLabel(label)
        setAccessibilityRole(.textField)
    }
}
