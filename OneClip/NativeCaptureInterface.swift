import AppKit
import Carbon
import SwiftUI

@MainActor
final class NativeCaptureInterface: NSObject, SingleCaptureInterface, NSWindowDelegate, CollectionCaptureInterface {
    static let shared = NativeCaptureInterface()
    weak var coordinator: SingleCaptureCoordinator?
    weak var collectionCoordinator: CollectionCaptureCoordinator?
    var collectionExpanded = false {
        didSet {
            if oldValue != collectionExpanded {
                ProductHotKeyController.shared.discardQueuedPresses()
                collectionCoordinator?.objectWillChange.send()
            }
        }
    }
    var collectionConfirmationPending = false {
        didSet {
            if oldValue != collectionConfirmationPending {
                ProductHotKeyController.shared.discardQueuedPresses()
                collectionCoordinator?.objectWillChange.send()
            }
        }
    }
    var collectionPresentationBlocksEntry: Bool { collectionExpanded || collectionConfirmationPending }
    var isOneClipActive: Bool { NSApp.isActive }
    var settingsAreVisible: (@MainActor () -> Bool)?
    var hasDiscardConfirmation: Bool { discardWindow != nil || !discardHandlers.isEmpty }
    var captureEntryBlocked: Bool {
        settingsAreVisible?() == true || collectionPresentationBlocksEntry || captureGuideWindow?.isVisible == true
            || discardWindow != nil || !discardHandlers.isEmpty
    }
    private var selectionWindow: SelectionWindow?
    private var captureGuideWindow: NSWindow?
    private var expandedSelectionHelp = false
    private var collectionGuideIsPresented = false
    private var collectionPermissionIsPresented = false
    private var permissionWindow: NSWindow?
    private var problemWindow: NSWindow?
    private var discardWindow: NSWindow?
    private var feedbackWindow: NSPanel?
    private var feedbackRevision = 0
    private var lastExternalApplication: NSRunningApplication?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var sessionMonitor: CaptureSessionMonitor!
    private var consoleUserMonitor: CaptureConsoleUserMonitor!
    var captureEnvironmentStatus: String {
        if !consoleUserMonitor.isReady { return consoleUserMonitor.statusText }
        return sessionMonitor.statusText
    }
    #if DEBUG
    var captureSessionDiagnostics: String {
        sessionMonitor.diagnosticText + "\n" + consoleUserMonitor.diagnosticText
    }
    #endif
    func prepareCaptureEnvironment() -> Bool {
        sessionMonitor.start() // Existing subscriptions never re-prime a pending change.
        consoleUserMonitor.start()
        return validateCaptureEnvironment()
    }
    func validateCaptureEnvironment() -> Bool {
        let sessionReady = sessionMonitor.validate()
        let consoleReady = consoleUserMonitor.validate()
        return sessionReady && consoleReady
    }
    func stopEnvironmentMonitoring() {
        sessionMonitor.stop()
        consoleUserMonitor.stop()
    }
    private var discardHandlers: [@MainActor (Bool) -> Void] = []
    #if DEBUG
    private var welcomeWindow: NSWindow?
    private var practiceWindow: NSWindow?
    private var practiceGeneration: UInt64 = 0
    #endif

    override init() {
        super.init()
        sessionMonitor = CaptureSessionMonitor { [weak self] event in
            self?.environmentDidChange(event == .consoleChanged
                ? .consoleSessionChanged : .consoleSessionUnavailable)
        }
        consoleUserMonitor = CaptureConsoleUserMonitor { [weak self] event in
            self?.environmentDidChange(event == .changed
                ? .consoleUserChanged : .consoleUserUnavailable)
        }
        sessionMonitor.start()
        consoleUserMonitor.start()
        rememberExternalApplication()
        let workspace = NSWorkspace.shared.notificationCenter
        let environmentEvents: [(Notification.Name, CaptureEnvironmentEvent)] = [
            (NSWorkspace.willSleepNotification, .systemSleep),
            (NSWorkspace.screensDidSleepNotification, .displaySleep),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionResigned)
        ]
        for (name, event) in environmentEvents {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // queue .main supplies the executor. Invalidate before a queued worker can adopt a result.
                MainActor.assumeIsolated { self?.environmentDidChange(event) }
            }
            observers.append((workspace, token))
        }
        let activation = workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                               object: nil, queue: .main) { [weak self] notification in
            let processID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor in
                guard let self, let processID, processID != ProcessInfo.processInfo.processIdentifier,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
                      let application = NSRunningApplication(processIdentifier: processID) else { return }
                self.lastExternalApplication = application
                if self.coordinator?.phase == .selecting { self.coordinator?.cancel() }
                if self.collectionCoordinator?.phase == .selecting { self.collectionCoordinator?.cancelOperation() }
            }
        }
        observers.append((workspace, activation))
        let screenChange = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.environmentDidChange(.displayChanged) }
        }
        observers.append((.default, screenChange))
    }

    func environmentDidChange(_ event: CaptureEnvironmentEvent) {
        coordinator?.environmentDidChange(event)
        collectionCoordinator?.environmentDidChange(event)
    }

    func showCollection(activate: Bool) {
        guard let collectionCoordinator else { return }
        collectionCoordinator.objectWillChange.send()
        CollectionPanelController.shared.show(coordinator: collectionCoordinator, interface: self, activate: activate)
    }
    func hideCollection() { CollectionPanelController.shared.hide() }
    func showCollectionGuide(started: @escaping @MainActor () -> Void,
                             cancelled: @escaping @MainActor () -> Void) {
        collectionGuideIsPresented = true
        if captureGuideWindow == nil {
            captureGuideWindow = makeWindow(title: "OneClip — 集めてコピー", size: NSSize(width: 480, height: 390))
        }
        captureGuideWindow?.title = "OneClip — 集めてコピー"
        captureGuideWindow?.contentView = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 18) {
                Text("必要なところを集めて、ひと貼り").font(.title3.bold())
                Text("範囲を選ぶと素材が追加されます。別のアプリを操作しながら、最大4枚まで集められます。")
                Text("収集中はクリップボードを変更しません。順序と完成画像を確認し、最後に「コピー」を押してください。")
                Text("追加や取り直しのEscは旧素材を残します。パネルを閉じる時は全体破棄を確認します。スリープ・ロック・ユーザー切替・画面構成変更では素材を破棄します。")
                HStack {
                    Button("最初の範囲を選ぶ") { [weak self] in
                        self?.expandedSelectionHelp = true
                        started()
                    }.keyboardShortcut(.defaultAction)
                    Button("取消") { cancelled() }.keyboardShortcut(.cancelAction)
                }
            }.fixedSize(horizontal: false, vertical: true).padding(24).frame(width: 480))
        show(captureGuideWindow)
    }
    func showCollectionPermission() {
        collectionPermissionIsPresented = true
        guard let collectionCoordinator else { return }
        if permissionWindow == nil {
            permissionWindow = makeWindow(title: "OneClip — 画面収録の許可", size: NSSize(width: 460, height: 340))
        }
        permissionWindow?.contentView = NSHostingView(rootView: CollectionPermissionView(coordinator: collectionCoordinator))
        show(permissionWindow)
    }

    func rememberExternalApplication() {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApplication = app
        }
    }

    func returnToExternalApplication() {
        guard NSApp.isActive, let app = lastExternalApplication, !app.isTerminated else { return }
        _ = app.activate(options: [])
    }

    func prepareForSelection() -> Bool {
        guard !captureEntryBlocked else { return false }
        #if DEBUG
        guard !M0LabController.shared.busy else { return false }
        M0LabController.shared.invalidate(hide: true)
        welcomeWindow?.orderOut(nil)
        #endif
        hidePermission()
        hideProblem()
        feedbackWindow?.orderOut(nil)
        return true
    }

    func showCaptureGuide(started: @escaping @MainActor () -> Void,
                          cancelled: @escaping @MainActor () -> Void) {
        collectionGuideIsPresented = false
        if captureGuideWindow == nil {
            captureGuideWindow = makeWindow(title: "OneClip — はじめての範囲コピー", size: NSSize(width: 480, height: 390))
        }
        captureGuideWindow?.title = "OneClip — はじめての範囲コピー"
        captureGuideWindow?.contentView = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 18) {
                Text("必要なところを選んで、コピー").font(.title3.bold())
                Text("1つの画面内でドラッグし、離すとその範囲をコピーします。確認画面や保存先の選択はありません。")
                    .fixedSize(horizontal: false, vertical: true)
                Text("キーボードでは、矢印で範囲を作り、矢印で移動、Shift + 矢印で大きさを変更します。Enterで確定、Escapeで取り消せます。")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("範囲を確定すると今のクリップボードを置き換えます。撮影に必要な場合だけ画面収録の許可を案内します。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("範囲選択を始める") { [weak self] in
                        self?.expandedSelectionHelp = true
                        started()
                    }.keyboardShortcut(.defaultAction)
                    Button("取消") { cancelled() }.keyboardShortcut(.cancelAction)
                }
            }.padding(24).frame(width: 480, alignment: .leading))
        show(captureGuideWindow)
    }

    func hideCaptureGuide() { captureGuideWindow?.orderOut(nil) }

    func showSelection(on display: CaptureDisplaySnapshot,
                       selected: @escaping @MainActor (CaptureSelection) -> Void,
                       cancelled: @escaping @MainActor () -> Void) {
        _ = hideSelection()
        let window = SelectionWindow(contentRect: display.frame, styleMask: .borderless,
                                     backing: .buffered, defer: false)
        window.setFrame(display.frame, display: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let collection = collectionCoordinator?.phase == .selecting
        let target = collectionCoordinator?.replacementIndex
        let action = collection ? (target == nil ? "追加" : "取り直し") : "コピー"
        let title = collection ? target.map { "素材\($0 + 1)を取り直す範囲" } ?? "追加する範囲" : "撮影範囲"
        let view = RegionSelectionView(display: display, expandedHelp: expandedSelectionHelp,
                                       actionLabel: action, selectionTitle: title,
                                       selected: selected, cancelled: cancelled)
        expandedSelectionHelp = false
        view.frame = NSRect(origin: .zero, size: display.frame.size)
        window.contentView = view
        selectionWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        window.displayIfNeeded()
    }

    func hideSelection() -> Bool {
        guard let window = selectionWindow else { return true }
        window.orderOut(nil)
        let hidden = !window.isVisible
        if hidden { selectionWindow = nil }
        return hidden
    }

    func showPermission() {
        collectionPermissionIsPresented = false
        guard let coordinator else { return }
        if permissionWindow == nil {
            permissionWindow = makeWindow(title: "OneClip — 画面収録の許可", size: NSSize(width: 460, height: 340))
        }
        permissionWindow?.contentView = NSHostingView(rootView: CapturePermissionView(coordinator: coordinator,
            contentSizeChanged: { [weak self] in
                // Wait for SwiftUI to lay out expanded help before measuring. Never activate over OS settings.
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.collectionPermissionIsPresented,
                          self.coordinator?.phase == .permission,
                          let window = self.permissionWindow, window.isVisible else { return }
                    if let scroll = window.contentView as? NSScrollView, let content = scroll.documentView {
                        // Re-measure the document after every change, including after a small-screen fallback.
                        scroll.documentView = nil
                        window.contentView = content
                    }
                    window.contentView?.layoutSubtreeIfNeeded()
                    self.resizeToFit(window)
                }
            }))
        show(permissionWindow)
    }

    func hidePermission() { permissionWindow?.orderOut(nil) }

    func showProblem(activate: Bool) {
        guard let coordinator else { return }
        if discardWindow != nil {
            if activate { show(problemWindow) }
            return
        }
        guard activate || NSApp.isActive else {
            showFeedback("コピーできませんでした。OneClipのメニューから確認できます")
            return
        }
        if problemWindow == nil {
            problemWindow = makeWindow(title: "OneClip — コピーの確認", size: NSSize(width: 470, height: 400))
        }
        problemWindow?.contentView = NSHostingView(rootView: CaptureProblemView(coordinator: coordinator, interface: self))
        show(problemWindow)
    }

    func hideProblem() { problemWindow?.orderOut(nil) }

    func showFeedback(_ message: String) {
        feedbackRevision &+= 1
        let revision = feedbackRevision
        if feedbackWindow == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 58),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isRestorable = false
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            feedbackWindow = panel
        }
        feedbackWindow?.contentView = NSHostingView(rootView:
            Text(message).font(.body.weight(.medium)).padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)))
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            feedbackWindow?.setFrameOrigin(NSPoint(x: frame.midX - 210, y: frame.maxY - 90))
        }
        feedbackWindow?.orderFrontRegardless()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard self?.feedbackRevision == revision else { return }
            self?.feedbackWindow?.orderOut(nil)
        }
    }

    func dismissAll() {
        hideCollection()
        _ = hideSelection()
        hideCaptureGuide()
        if let sheet = discardWindow { problemWindow?.endSheet(sheet, returnCode: .cancel) }
        hidePermission()
        hideProblem()
        feedbackRevision &+= 1
        feedbackWindow?.orderOut(nil)
    }

    func closeProblem() {
        guard let coordinator else { return }
        guard discardWindow == nil, discardHandlers.isEmpty else { return }
        if coordinator.hasRetainedImage {
            confirmDiscard { [weak coordinator] confirmed in if confirmed { coordinator?.discard() } }
        } else { coordinator.cancel() }
    }

    func confirmDiscard(_ completion: @escaping @MainActor (Bool) -> Void) {
        discardHandlers.append(completion)
        guard discardHandlers.count == 1 else { return }
        showProblem(activate: true)
        guard let window = problemWindow else { finishDiscard(false); return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 180),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isRestorable = false
        sheet.isReleasedWhenClosed = false
        sheet.contentView = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 18) {
                Text("未コピーの画像を破棄しますか？").font(.headline)
                Text("破棄すると、この画像は再コピーできません。")
                HStack {
                    Button("画像を残す") { [weak self] in self?.answerDiscard(false) }.keyboardShortcut(.defaultAction)
                    Button("破棄する") { [weak self] in self?.answerDiscard(true) }
                }
            }.padding(24).onExitCommand { [weak self] in self?.answerDiscard(false) })
        discardWindow = sheet
        window.beginSheet(sheet) { [weak self] response in
            Task { @MainActor in
                self?.discardWindow = nil
                self?.finishDiscard(response == .OK)
            }
        }
    }

    private func answerDiscard(_ confirmed: Bool) {
        guard let sheet = discardWindow else { return }
        problemWindow?.endSheet(sheet, returnCode: confirmed ? .OK : .cancel)
    }

    private func finishDiscard(_ confirmed: Bool) {
        let handlers = discardHandlers
        discardHandlers.removeAll()
        for handler in handlers { handler(confirmed) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === problemWindow, coordinator?.hasRetainedImage == true { closeProblem(); return false }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === captureGuideWindow, collectionGuideIsPresented {
            collectionCoordinator?.discard()
        } else if window === permissionWindow, collectionPermissionIsPresented {
            collectionCoordinator?.cancelOperation()
        } else if window === permissionWindow || window === problemWindow || window === captureGuideWindow {
            coordinator?.cancel()
        }
        #if DEBUG
        if window === practiceWindow { practiceDidChange() }
        #endif
    }

    #if DEBUG
    func windowDidMove(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === practiceWindow { practiceDidChange() }
    }
    func windowDidResize(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === practiceWindow { practiceDidChange() }
    }

    private func practiceDidChange() {
        practiceGeneration &+= 1
        if let phase = collectionCoordinator?.phase, [.selecting, .capturing, .encoding].contains(phase) {
            collectionCoordinator?.invalidate(message: "練習画面が変わったため中止しました。もう一度選んでください。")
        }
        if let phase = coordinator?.phase, [.selecting, .capturing, .encoding].contains(phase) {
            coordinator?.invalidate(message: "練習画面が変わったため中止しました。もう一度選んでください。")
        }
    }

    func practiceScope(for display: CaptureDisplaySnapshot) throws -> PracticeCaptureScope? {
        guard let window = practiceWindow, window.isVisible else { return nil }
        guard let screen = window.screen else { throw ScreenshotError.practiceUnavailable }
        let ownDisplay = try ScreenshotService.snapshot(for: screen)
        guard ownDisplay.id == display.id else { return nil }
        let generation = practiceGeneration
        return try PracticeCaptureScope(window: window, display: ownDisplay) { [weak self, weak window] in
            guard let self, let window else { return false }
            return self.practiceWindow === window && self.practiceGeneration == generation
        }
    }

    func showPractice(stage: M3PracticeStage? = nil) {
        guard coordinator?.isWorking == false, coordinator?.phase != .selecting,
              collectionCoordinator?.isWorking != true, collectionCoordinator?.phase != .selecting,
              !captureEntryBlocked else { return }
        do {
            if practiceWindow == nil {
                let window = makeWindow(title: "OneClip — 架空の練習画面", size: NSSize(width: 640, height: 360))
                window.styleMask.remove(.resizable)
                practiceWindow = window
            }
            let asset = try stage.map { try M3PracticeFixture.make($0) }
                ?? M0ImageFixture.make(index: 1, width: 1280, height: 720, scale: 2)
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
            imageView.imageScaling = .scaleAxesIndependently
            imageView.image = NSImage(cgImage: asset.image, size: NSSize(width: 640, height: 360))
            imageView.setAccessibilityLabel(stage?.menuTitle ?? "架空の練習画面")
            practiceWindow?.title = "OneClip — " + (stage?.menuTitle ?? "架空の練習画面")
            practiceWindow?.contentView = imageView
            practiceGeneration &+= 1
            welcomeWindow?.orderOut(nil)
            show(practiceWindow)
        } catch { showFeedback("練習画面を作成できませんでした") }
    }

    func showDebugWelcome() {
        guard welcomeWindow == nil else { show(welcomeWindow); return }
        let window = makeWindow(title: "OneClip — M1の確認", size: NSSize(width: 460, height: 250))
        window.contentView = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 18) {
                Text("M1 範囲コピーの確認").font(.title2.bold())
                Text("画面上端のOneClipメニューに「範囲をコピー」を追加しました。まず、内容を確かめられる架空の練習画面を開けます。")
                Button("練習画面を開く") { [weak self] in self?.showPractice() }
                Text("画面を開くだけでは、撮影・コピー・許可要求を行いません。まとめ撮りとキー設定はまだ使えません。")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(24))
        welcomeWindow = window
        show(window)
    }
    #endif

    private func makeWindow(title: String, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func resizeToFit(_ window: NSWindow?) {
        if let window, let content = window.contentView, !(content is NSScrollView) {
            let ideal = content.fittingSize
            let available = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
            if ideal.width > 0, ideal.height > 0 {
                let size = NSSize(width: min(ideal.width, available.width - 60),
                                  height: min(ideal.height, available.height - 100))
                if ideal.height > size.height || ideal.width > size.width {
                    let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
                    scroll.hasVerticalScroller = true
                    scroll.hasHorizontalScroller = ideal.width > size.width
                    scroll.autohidesScrollers = true
                    content.setFrameSize(ideal)
                    scroll.documentView = content
                    window.contentView = scroll
                }
                window.setContentSize(size)
            }
        }
    }

    private func show(_ window: NSWindow?) {
        resizeToFit(window)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class RegionSelectionView: NSView {
    private let display: CaptureDisplaySnapshot
    private let selected: @MainActor (CaptureSelection) -> Void
    private let cancelled: @MainActor () -> Void
    private var dragStart: CGPoint?
    private var selection: CaptureSelection?
    private var dragPreview: CGRect?
    private var hint: String
    private let expandedHelp: Bool
    private let actionLabel: String
    private let selectionTitle: String
    private var confirmed = false
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    init(display: CaptureDisplaySnapshot, expandedHelp: Bool, actionLabel: String, selectionTitle: String,
         selected: @escaping @MainActor (CaptureSelection) -> Void,
         cancelled: @escaping @MainActor () -> Void) {
        self.display = display; self.selected = selected; self.cancelled = cancelled
        self.expandedHelp = expandedHelp
        self.actionLabel = actionLabel
        self.selectionTitle = selectionTitle
        hint = "ドラッグを離すと\(actionLabel)・Escで取消・1つの画面内"
        super.init(frame: NSRect(origin: .zero, size: display.frame.size))
        setAccessibilityLabel("\(selectionTitle)の選択。確定すると\(actionLabel)します。ドラッグ、または矢印で開始。Shiftと矢印で大きさを変更、Returnで確定、Escapeで取消。")
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        guard !confirmed else { return }
        selection = nil
        dragStart = globalPoint(event)
        dragPreview = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !confirmed, let start = dragStart else { return }
        dragPreview = try? RegionGeometry.dragRect(display: display, start: start, current: globalPoint(event))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !confirmed, let start = dragStart else { return }
        dragStart = nil
        do {
            let value = try RegionGeometry.finishDrag(display: display, start: start, end: globalPoint(event))
            selection = value
            confirmed = true
            selected(value)
        } catch {
            selection = nil; dragPreview = nil
            hint = "\(actionLabel)していません。画面の内側で、1ピクセル以上の範囲を選び直してください"
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        guard !confirmed else { return }
        if event.keyCode == UInt16(kVK_Escape) { confirmed = true; cancelled(); return }
        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            guard let selection, dragStart == nil else { return }
            confirmed = true; selected(selection); return
        }
        let direction: RegionArrowDirection?
        switch Int(event.keyCode) {
        case kVK_LeftArrow: direction = .left
        case kVK_RightArrow: direction = .right
        case kVK_UpArrow: direction = .up
        case kVK_DownArrow: direction = .down
        default: direction = nil
        }
        guard let direction, dragStart == nil else { super.keyDown(with: event); return }
        do {
            selection = try RegionGeometry.adjusting(selection: selection, display: display, direction: direction,
                                                      resize: event.modifierFlags.contains(.shift),
                                                      accelerated: event.modifierFlags.contains(.option))
            dragPreview = nil
            hint = "矢印で移動・Shift+矢印で大きさ・Option併用で10pt・Enterで\(actionLabel)・Escで取消"
            needsDisplay = true
        } catch { hint = "範囲を確認できません。Escで取り消し、もう一度選んでください"; needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        let globalRect = selection?.rect ?? dragPreview
        let rect = globalRect.map { NSRect(x: $0.minX - display.frame.minX, y: $0.minY - display.frame.minY,
                                          width: $0.width, height: $0.height) }
        NSColor.black.withAlphaComponent(0.35).setFill()
        let dim = NSBezierPath(rect: bounds)
        if let rect { dim.appendRect(rect) }
        dim.windingRule = .evenOdd
        dim.fill()
        if let rect {
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: rect); path.lineWidth = 1 / display.scale; path.stroke()
            let width = Int((rect.width * display.scale).rounded())
            let height = Int((rect.height * display.scale).rounded())
            drawLabel("\(width) × \(height) px", at: NSPoint(x: min(max(rect.minX, 12), bounds.width - 200),
                                                                 y: max(12, rect.minY - 32)))
        }
        drawLabel("\(selectionTitle)・\(hint)", at: NSPoint(x: 24, y: bounds.height - 58))
        if expandedHelp && selection == nil && dragStart == nil {
            drawLabel("キーボード: 矢印で範囲を作成 → 移動/大きさ調整 → Enterで\(actionLabel)", at: NSPoint(x: 24, y: bounds.height - 96))
        }
    }

    private func drawLabel(_ text: String, at point: NSPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium),
                                                       .foregroundColor: NSColor.white]
        let text = NSAttributedString(string: text, attributes: attributes)
        let size = text.size()
        let rect = NSRect(origin: point, size: NSSize(width: min(size.width + 20, bounds.width - point.x - 12), height: size.height + 12))
        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        text.draw(at: NSPoint(x: rect.minX + 10, y: rect.minY + 6))
    }

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: display.frame.minX + point.x, y: display.frame.minY + point.y)
    }
}

private struct CapturePermissionView: View {
    @ObservedObject var coordinator: SingleCaptureCoordinator
    let contentSizeChanged: () -> Void
    @State private var showsHelp: Bool

    init(coordinator: SingleCaptureCoordinator, contentSizeChanged: @escaping () -> Void) {
        self.coordinator = coordinator
        self.contentSizeChanged = contentSizeChanged
        _showsHelp = State(initialValue: coordinator.permissionStatus == .requestUnconfirmed
                           || coordinator.permissionStatus == .noLongerAvailable)
    }

    private var needsSettings: Bool {
        coordinator.permissionStatus == .requestUnconfirmed || coordinator.permissionStatus == .noLongerAvailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("画面収録の許可").font(.title3.bold())
                Text(coordinator.permissionMessage)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                Text("画像の保存・送信は行いません。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            DisclosureGroup("許可済み・許可できない場合", isExpanded: $showsHelp) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("システム設定 → プライバシーとセキュリティ → 画面収録で、OneClipをオンにします。")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("OSが再起動を求めた場合は、その案内に従ってください。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if needsSettings {
                        Button("もう一度許可を求める") { coordinator.requestPermission() }
                    } else {
                        Button("システム設定を開く", action: openSettings)
                    }
                    if coordinator.permissionStatus != .granted {
                        Text("設定後、この画面から範囲選択へ進めます。")
                            .foregroundStyle(.secondary)
                        Button("許可を確認して続ける") { coordinator.retryPermission() }
                    }
                }
                .font(.callout).lineSpacing(3).padding(.top, 10)
            }
            .font(.callout)
            HStack {
                Button("キャンセル") { coordinator.cancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                if coordinator.permissionStatus == .granted {
                    Button("範囲を選ぶ") { coordinator.retryPermission() }.buttonStyle(.borderedProminent)
                } else if needsSettings {
                    Button("システム設定を開く", action: openSettings).buttonStyle(.borderedProminent)
                } else {
                    Button("許可を求める") { coordinator.requestPermission() }.buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
        }
        .padding(24).frame(width: 420, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: showsHelp) { _, _ in contentSizeChanged() }
        .onChange(of: coordinator.permissionMessage) { _, _ in contentSizeChanged() }
        .onChange(of: coordinator.permissionStatus) { _, status in
            if status == .requestUnconfirmed || status == .noLongerAvailable { showsHelp = true }
            if status == .granted { showsHelp = false }
            contentSizeChanged()
        }
    }

    private func openSettings() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}

private struct CaptureProblemView: View {
    @ObservedObject var coordinator: SingleCaptureCoordinator
    let interface: NativeCaptureInterface
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(coordinator.problem?.title ?? "処理を完了できませんでした").font(.title3.bold())
            Text(coordinator.problem?.message ?? "").fixedSize(horizontal: false, vertical: true)
            if coordinator.hasRetainedImage {
                Text("取得した画像をメモリに保持しています。「再コピー」は同じ画像を使い、撮り直しません。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if coordinator.problem?.clipboardMayHaveChanged == true {
                Text("書込み準備後に失敗したため、以前のクリップボード内容は残っていない場合があります。")
                    .font(.callout)
            }
            HStack {
                if coordinator.hasRetainedImage {
                    Button("再コピー") { coordinator.retryCopy() }.disabled(coordinator.isWorking)
                    Button("破棄…") { interface.closeProblem() }.disabled(coordinator.isWorking)
                } else {
                    Button("もう一度選択") { coordinator.retrySelection() }.disabled(coordinator.isWorking)
                    Button("閉じる") { coordinator.cancel() }
                }
            }
        }.padding(24).frame(width: 470, alignment: .leading)
            .onExitCommand { interface.closeProblem() }
    }
}
