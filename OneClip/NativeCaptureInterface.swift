import AppKit
import Carbon
import SwiftUI

enum CaptureUIOwner: Equatable { case single, collection }

@MainActor
private final class CaptureReturnOrigin {
    var application: NSRunningApplication?
    weak var settingsWindow: NSWindow?
    var usesSettings = false
}

@MainActor
final class NativeCaptureInterface: NSObject, SingleCaptureInterface, NSWindowDelegate, CollectionCaptureInterface {
    static let shared = NativeCaptureInterface()

    /// Result ownership participates in the same synchronous invalidation route as capture.
    /// Only production uses the shared result controller; test instances default to no services.
    struct ResultServices {
        let blocksCapture: @MainActor () -> Bool
        let invalidate: @MainActor (CaptureEnvironmentEvent) -> Void
        let dismissPreview: @MainActor () -> Void

        static var live: ResultServices {
            ResultServices(blocksCapture: {
                CaptureResultController.shared.hasPendingSave || CaptureResultController.shared.isSaving
            }, invalidate: { _ in CaptureResultController.shared.environmentDidChange() },
               dismissPreview: { CaptureResultController.shared.dismissPreview() })
        }
        static var isolated: ResultServices {
            ResultServices(blocksCapture: { false }, invalidate: { _ in }, dismissPreview: {})
        }
    }
    /// Annotation is a separate image owner; diagnostics never resolve its live singleton.
    struct AnnotationServices {
        let blocksCapture: @MainActor () -> Bool
        let invalidate: @MainActor (CaptureEnvironmentEvent) -> Void
        static var live: AnnotationServices {
            AnnotationServices(blocksCapture: { CaptureAnnotationController.shared.blocksCapture },
                invalidate: { _ in CaptureAnnotationController.shared.invalidate() })
        }
        static var isolated: AnnotationServices {
            AnnotationServices(blocksCapture: { false }, invalidate: { _ in })
        }
    }

    weak var coordinator: SingleCaptureCoordinator?
    weak var collectionCoordinator: CollectionCaptureCoordinator?
    var collectionExpanded = false {
        didSet {
            if oldValue != collectionExpanded {
                if usesLiveApplicationServices { ProductHotKeyController.shared.discardQueuedPresses() }
                collectionCoordinator?.objectWillChange.send()
            }
        }
    }
    var collectionConfirmationPending = false {
        didSet {
            if oldValue != collectionConfirmationPending {
                if usesLiveApplicationServices { ProductHotKeyController.shared.discardQueuedPresses() }
                collectionCoordinator?.objectWillChange.send()
            }
        }
    }
    var collectionPresentationBlocksEntry: Bool { collectionExpanded || collectionConfirmationPending }
    var isOneClipActive: Bool { NSApp.isActive }
    var settingsBlockCapture: (@MainActor () -> Bool)?
    var updateBlocksCapture: (@MainActor () -> Bool)?
    var hasDiscardConfirmation: Bool { discardWindow != nil || !discardHandlers.isEmpty || endAllWindow != nil }
    var collectionCopyBlocked: Bool {
        updateBlocksCapture?() == true || annotationServices.blocksCapture() || resultServices.blocksCapture() || settingsBlockCapture?() == true || collectionConfirmationPending || captureGuideWindow?.isVisible == true
            || usageGuideWindow?.isVisible == true || onboardingWindow?.isVisible == true || hasDiscardConfirmation
    }
    var captureEntryBlocked: Bool {
        updateBlocksCapture?() == true || annotationServices.blocksCapture() || resultServices.blocksCapture() || settingsBlockCapture?() == true || collectionPresentationBlocksEntry || captureGuideWindow?.isVisible == true
            || usageGuideWindow?.isVisible == true || onboardingWindow?.isVisible == true || hasDiscardConfirmation
    }
    private var selectionWindow: SelectionWindow?
    private var selectionOwner: CaptureUIOwner?
    private var selectionSettingsFrame: CGRect?
    private var selectionSettingsScope: SettingsCaptureScope?
    private var captureGuideWindow: NSWindow?
    private var captureGuideOwner: CaptureUIOwner?
    private var captureGuideCancelled: (@MainActor () -> Void)?
    private var usageGuideWindow: NSWindow?
    private weak var usageReturnWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private weak var onboardingReturnWindow: NSWindow?
    private var onboardingActivePage = 0
    private var expandedSelectionHelp = false
    private var permissionOwner: CaptureUIOwner?
    private var permissionWindow: NSWindow?
    private var problemWindow: NSWindow?
    private var discardWindow: NSWindow?
    private var endAllWindow: NSWindow?
    private var endAllCompletion: (@MainActor (Bool) -> Void)?
    private var feedbackWindow: NSPanel?
    private var feedbackRevision = 0
    private var lastExternalApplication: NSRunningApplication?
    private let singleOrigin = CaptureReturnOrigin()
    private let collectionOrigin = CaptureReturnOrigin()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var environmentRouter: CaptureEnvironmentRouter!
    private let usesLiveApplicationServices: Bool
    private let resultServices: ResultServices
    private let annotationServices: AnnotationServices
    let securityTrace: CaptureSecurityTrace
    var captureEnvironmentStatus: String { environmentRouter.statusText }
    #if DEBUG
    var captureSessionDiagnostics: String {
        environmentRouter.diagnosticText
    }
    #endif
    func prepareCaptureEnvironment() -> Bool {
        environmentRouter.prepare()
    }
    func validateCaptureEnvironment() -> Bool {
        environmentRouter.validate()
    }
    func stopEnvironmentMonitoring() {
        environmentRouter.stop()
    }
    private var discardHandlers: [@MainActor (Bool) -> Void] = []
    #if DEBUG
    private var welcomeWindow: NSWindow?
    private var practiceWindow: NSWindow?
    private var practiceGeneration: UInt64 = 0
    #endif

    override init() {
        usesLiveApplicationServices = true
        resultServices = .live
        annotationServices = .live
        securityTrace = .disabled
        super.init()
        installEnvironment(sources: .live, sessionBackend: .live, consoleBackend: .live)
        environmentRouter.start()
        rememberExternalApplication()
        let workspace = NSWorkspace.shared.notificationCenter
        let activation = workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                               object: nil, queue: .main) { [weak self] notification in
            let processID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let processID, processID != ProcessInfo.processInfo.processIdentifier,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
                      let application = NSRunningApplication(processIdentifier: processID) else { return }
                let isPermissionSettingsVisit = self.permissionOwner != nil
                    && application.bundleIdentifier == "com.apple.systempreferences"
                if !isPermissionSettingsVisit { self.lastExternalApplication = application }
                // A permission-settings visit must not replace either operation's return target.
                if self.coordinator?.phase == .selecting { self.coordinator?.cancel() }
                if self.collectionCoordinator?.phase == .selecting { self.collectionCoordinator?.cancelOperation() }
            }
        }
        observers.append((workspace, activation))
    }

    /// Explicit test dependencies. This initializer never reads foreground application state,
    /// starts global hotkey services or installs the application-activation observer.
    init(environmentSources: CaptureEnvironmentRouter.NotificationSources,
         sessionBackend: CaptureSessionMonitor.Backend,
         consoleBackend: CaptureConsoleUserMonitor.Backend,
         securityTrace: CaptureSecurityTrace = .disabled, startMonitoring: Bool = true,
         resultServices: ResultServices = .isolated, annotationServices: AnnotationServices = .isolated) {
        usesLiveApplicationServices = false
        self.resultServices = resultServices
        self.annotationServices = annotationServices
        self.securityTrace = securityTrace
        super.init()
        installEnvironment(sources: environmentSources, sessionBackend: sessionBackend, consoleBackend: consoleBackend)
        if startMonitoring { environmentRouter.start() }
    }

    private func installEnvironment(sources: CaptureEnvironmentRouter.NotificationSources,
                                    sessionBackend: CaptureSessionMonitor.Backend,
                                    consoleBackend: CaptureConsoleUserMonitor.Backend) {
        environmentRouter = CaptureEnvironmentRouter(sources: sources, sessionBackend: sessionBackend,
            consoleBackend: consoleBackend, securityTrace: securityTrace) { [weak self] event in
                self?.invalidateEnvironmentConsumers(event)
            }
    }

    func protectedDataWillBecomeUnavailable() {
        environmentDidChange(.protectedDataUnavailable)
    }

    func environmentDidChange(_ event: CaptureEnvironmentEvent) {
        environmentRouter.receive(event)
    }

    private func invalidateEnvironmentConsumers(_ event: CaptureEnvironmentEvent) {
        // The router has already recorded the source event. Clear editor/result ownership
        // before either capture owner can adopt a queued image. Delivery codes prove routing,
        // not that a disabled/isolated consumer had an image or a real window.
        securityTrace.record(.annotationInvalidationDelivered)
        annotationServices.invalidate(event)
        securityTrace.record(.resultInvalidationDelivered)
        resultServices.invalidate(event)
        coordinator?.environmentDidChange(event)
        collectionCoordinator?.environmentDidChange(event)
    }

    func showCollection(activate: Bool) {
        resultServices.dismissPreview()
        guard let collectionCoordinator else { return }
        collectionCoordinator.objectWillChange.send()
        CollectionPanelController.shared.show(coordinator: collectionCoordinator, interface: self, activate: activate)
    }
    func hideCollection() { CollectionPanelController.shared.hide() }
    func showCollectionGuide(started: @escaping @MainActor () -> Void,
                             cancelled: @escaping @MainActor () -> Void) {
        captureGuideOwner = .collection
        captureGuideCancelled = cancelled
        if captureGuideWindow == nil {
            captureGuideWindow = makeWindow(title: "OneClip — 集めてコピー", size: NSSize(width: 480, height: 390))
        }
        captureGuideWindow?.title = "OneClip — 集めてコピー"
        captureGuideWindow?.contentView = NSHostingView(rootView:
            CaptureGuideView(collection: true, started: { [weak self] in
                self?.expandedSelectionHelp = true
                started()
            }, cancelled: cancelled))
        show(captureGuideWindow)
    }
    func showCollectionPermission() {
        permissionOwner = .collection
        guard let collectionCoordinator else { return }
        if permissionWindow == nil {
            permissionWindow = makeWindow(title: "OneClip — 画面収録の許可", size: NSSize(width: 460, height: 340))
        }
        permissionWindow?.contentView = NSHostingView(rootView: CollectionPermissionView(coordinator: collectionCoordinator,
            contentSizeChanged: { [weak self] in self?.permissionContentSizeChanged(owner: .collection) }))
        show(permissionWindow)
    }

    func rememberExternalApplication() {
        guard usesLiveApplicationServices else { return }
        rememberOrigin(singleOrigin)
    }

    func rememberCollectionOrigin() {
        guard usesLiveApplicationServices else { return }
        rememberOrigin(collectionOrigin)
    }

    private func rememberOrigin(_ origin: CaptureReturnOrigin) {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApplication = app
            origin.application = app
            origin.usesSettings = false
            origin.settingsWindow = nil
        } else if NSApp.isActive, let window = CaptureSettingsController.shared.captureWindow, window.isKeyWindow {
            origin.usesSettings = true
            origin.settingsWindow = window
        } else {
            // This method marks a new, explicit operation. A panel button can follow work in a
            // different external app, so use the latest target rather than an earlier operation's.
            origin.application = lastExternalApplication
            origin.usesSettings = false
            origin.settingsWindow = nil
        }
    }

    func rememberSettingsWindow(_ window: NSWindow?) {
        guard NSApp.isActive, let window, window.isVisible, window.isKeyWindow else { return }
        singleOrigin.usesSettings = true
        singleOrigin.settingsWindow = window
    }

    func returnToExternalApplication() {
        returnToOrigin(singleOrigin)
    }

    func returnToCollectionOrigin() {
        returnToOrigin(collectionOrigin)
    }

    private func returnToOrigin(_ origin: CaptureReturnOrigin) {
        guard NSApp.isActive else { return }
        if origin.usesSettings {
            // A closed settings window is never reopened, nor replaced by an old external target.
            if let window = origin.settingsWindow, CaptureSettingsController.shared.captureWindow === window {
                window.makeKeyAndOrderFront(nil)
            }
            return
        }
        guard let app = origin.application, !app.isTerminated else { return }
        _ = app.activate(options: [])
    }

    func prepareForSelection() -> Bool {
        prepareForSelection(owner: .single)
    }

    func prepareForCollectionSelection() -> Bool {
        prepareForSelection(owner: .collection)
    }

    private func prepareForSelection(owner: CaptureUIOwner) -> Bool {
        guard !captureEntryBlocked else { return false }
        resultServices.dismissPreview()
        #if DEBUG
        guard !M0LabController.shared.busy else { return false }
        M0LabController.shared.invalidate(hide: true)
        welcomeWindow?.orderOut(nil)
        #endif
        hidePermission(owner: owner)
        if owner == .single { hideProblem() }
        feedbackWindow?.orderOut(nil)
        return true
    }

    func showCaptureGuide(started: @escaping @MainActor () -> Void,
                          cancelled: @escaping @MainActor () -> Void) {
        captureGuideOwner = .single
        captureGuideCancelled = cancelled
        if captureGuideWindow == nil {
            captureGuideWindow = makeWindow(title: "OneClip — はじめての範囲コピー", size: NSSize(width: 480, height: 390))
        }
        captureGuideWindow?.title = "OneClip — はじめての範囲コピー"
        captureGuideWindow?.contentView = NSHostingView(rootView:
            CaptureGuideView(collection: false, started: { [weak self] in
                self?.expandedSelectionHelp = true
                started()
            }, cancelled: cancelled))
        show(captureGuideWindow)
    }

    func hideCaptureGuide() { hideCaptureGuide(owner: .single) }
    func hideCollectionGuide() { hideCaptureGuide(owner: .collection) }
    private func hideCaptureGuide(owner: CaptureUIOwner) {
        guard captureGuideOwner == owner else { return }
        captureGuideCancelled = nil
        captureGuideOwner = nil
        captureGuideWindow?.orderOut(nil)
    }

    func showSelection(on display: CaptureDisplaySnapshot,
                       selected: @escaping @MainActor (CaptureSelection) -> Void,
                       cancelled: @escaping @MainActor () -> Void) {
        _ = hideSelection(owner: selectionOwner)
        let settings = CaptureSettingsController.shared
        if let window = settings.captureWindow {
            selectionSettingsFrame = window.frame
            let generation = settings.captureGeneration
            selectionSettingsScope = try? SettingsCaptureScope(window: window, validate: { [weak settings, weak window] in
                guard let settings, let window else { return false }
                return settings.captureGeneration == generation && settings.captureWindow === window
                    && !settings.blocksCapture
            })
        }
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
        selectionOwner = collection ? .collection : .single
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

    func hideSelection() -> Bool { hideSelection(owner: .single) }
    func hideCollectionSelection() -> Bool { hideSelection(owner: .collection) }
    private func hideSelection(owner: CaptureUIOwner?) -> Bool {
        guard selectionOwner == owner else { return true }
        selectionSettingsFrame = nil
        selectionSettingsScope = nil
        guard let window = selectionWindow else { return true }
        window.orderOut(nil)
        let hidden = !window.isVisible
        if hidden { selectionWindow = nil; selectionOwner = nil }
        return hidden
    }

    func settingsCaptureScope(for selection: CaptureSelection) throws -> SettingsCaptureScope? {
        let current = CaptureSettingsController.shared.captureWindow?.frame
        let overlapsOriginal = selectionSettingsFrame?.intersects(selection.rect) == true
        let overlapsCurrent = current?.intersects(selection.rect) == true
        guard overlapsOriginal || overlapsCurrent else { return nil }
        guard let scope = selectionSettingsScope, scope.validate() else { throw ScreenshotError.settingsUnavailable }
        return scope
    }

    func showPermission() {
        permissionOwner = .single
        guard let coordinator else { return }
        if permissionWindow == nil {
            permissionWindow = makeWindow(title: "OneClip — 画面収録の許可", size: NSSize(width: 460, height: 340))
        }
        permissionWindow?.contentView = NSHostingView(rootView: CapturePermissionView(coordinator: coordinator,
            contentSizeChanged: { [weak self] in self?.permissionContentSizeChanged(owner: .single) }))
        show(permissionWindow)
    }

    private func permissionContentSizeChanged(owner: CaptureUIOwner) {
        // Wait for layout, and never activate over System Settings when a status changes.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.permissionOwner == owner,
                  let window = self.permissionWindow, window.isVisible else { return }
            if let scroll = window.contentView as? NSScrollView, let content = scroll.documentView {
                scroll.documentView = nil
                window.contentView = content
            }
            window.contentView?.layoutSubtreeIfNeeded()
            self.resizeToFit(window)
        }
    }

    func hidePermission() { hidePermission(owner: .single) }
    func hideCollectionPermission() { hidePermission(owner: .collection) }
    private func hidePermission(owner: CaptureUIOwner) {
        guard permissionOwner == owner else { return }
        permissionOwner = nil
        permissionWindow?.orderOut(nil)
    }

    func showWelcomeIfNeeded() {
        guard CapturePreferences.shared.shouldPresentOnboardingOnLaunch else { return }
        showOnboarding()
    }

    /// Presents a compact introduction using synthetic examples, without capture or permission requests.
    func showOnboarding() {
        if onboardingWindow?.isVisible == true { show(onboardingWindow); return }
        let replacingUsageGuide = usageGuideWindow?.isVisible == true
        guard !captureEntryBlocked || replacingUsageGuide,
              coordinator?.isWorking != true, collectionCoordinator?.isWorking != true,
              coordinator?.phase != .selecting, coordinator?.phase != .permission,
              collectionCoordinator?.phase != .selecting, collectionCoordinator?.phase != .permission else { return }
        if replacingUsageGuide {
            onboardingReturnWindow = usageReturnWindow
            usageReturnWindow = nil
            usageGuideWindow?.orderOut(nil)
        } else {
            onboardingReturnWindow = NSApp.keyWindow
        }
        onboardingActivePage = 0
        if onboardingWindow == nil {
            onboardingWindow = makeWindow(title: "OneClip — はじめての案内", size: NSSize(width: 520, height: 610))
        }
        onboardingWindow?.contentView = NSHostingView(rootView: OneClipOnboardingView(
            preferences: .shared,
            pageChanged: { [weak self] page in self?.onboardingActivePage = page },
            completed: { [weak self] concern, sample in
                self?.completeOnboarding(concern: concern, sample: sample)
            },
            skipped: { [weak self] page in
                self?.skipOnboarding(fromPage: page)
            },
            contentSizeChanged: { [weak self] in self?.onboardingContentSizeChanged() }
        ))
        show(onboardingWindow)
        notifyEntryGateChanged()
    }

    private func completeOnboarding(concern: OnboardingConcern, sample: OnboardingTrialSample) {
        CapturePreferences.shared.recordOnboardingCompletion(concern: concern, trialSample: sample)
        let savedReturnWindow = onboardingReturnWindow
        onboardingReturnWindow = nil
        onboardingWindow?.orderOut(nil)
        notifyEntryGateChanged()
        usageReturnWindow = savedReturnWindow
        showUsageGuide(initialCollection: concern.prefersCollection, fromOnboarding: true)
    }

    private func skipOnboarding(fromPage page: Int) {
        CapturePreferences.shared.recordOnboardingSkip(fromPage: page)
        onboardingWindow?.orderOut(nil)
        if NSApp.isActive, let window = onboardingReturnWindow, window.isVisible { window.makeKeyAndOrderFront(nil) }
        onboardingReturnWindow = nil
        notifyEntryGateChanged()
    }

    private func onboardingContentSizeChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.onboardingWindow, window.isVisible else { return }
            if let scroll = window.contentView as? NSScrollView, let content = scroll.documentView {
                scroll.documentView = nil
                window.contentView = content
            }
            window.contentView?.layoutSubtreeIfNeeded()
            self.resizeToFit(window)
        }
    }

    /// Reading this guide never starts an operation or changes either retained-image owner.
    func showUsageGuide(initialCollection: Bool? = nil, fromOnboarding: Bool = false) {
        if usageGuideWindow?.isVisible == true && initialCollection == nil && !fromOnboarding {
            show(usageGuideWindow)
            return
        }
        let replacingOnboarding = onboardingWindow?.isVisible == true
        guard !captureEntryBlocked || usageGuideWindow?.isVisible == true || replacingOnboarding,
              coordinator?.isWorking != true, collectionCoordinator?.isWorking != true,
              coordinator?.phase != .selecting, coordinator?.phase != .permission,
              collectionCoordinator?.phase != .selecting, collectionCoordinator?.phase != .permission else { return }
        if replacingOnboarding {
            CapturePreferences.shared.recordOnboardingSkip(fromPage: onboardingActivePage)
            if usageReturnWindow == nil {
                usageReturnWindow = onboardingReturnWindow
            }
            onboardingReturnWindow = nil
            onboardingWindow?.orderOut(nil)
        } else if usageReturnWindow == nil {
            usageReturnWindow = NSApp.keyWindow
        }
        if usageGuideWindow == nil {
            usageGuideWindow = makeWindow(title: "OneClip — 使い方", size: NSSize(width: 500, height: 560))
        }
        let preferredMode = initialCollection ?? CapturePreferences.shared.preferredInitialCollectionMode
        usageGuideWindow?.contentView = NSHostingView(rootView: CaptureUsageGuideView(
            collection: preferredMode,
            reopenOnboarding: { [weak self] in self?.showOnboarding() },
            closed: { [weak self] modes in self?.closeUsageGuide(seenModes: modes) },
            contentSizeChanged: { [weak self] in self?.usageContentSizeChanged() }))
        show(usageGuideWindow)
        notifyEntryGateChanged()
    }

    private func closeUsageGuide(seenModes: Set<Bool> = []) {
        CapturePreferences.shared.hasSeenWelcome = true
        if seenModes.contains(false) { CapturePreferences.shared.hasSeenCaptureGuide = true }
        if seenModes.contains(true) { CapturePreferences.shared.hasSeenCollectionGuide = true }
        usageGuideWindow?.orderOut(nil)
        if NSApp.isActive, let window = usageReturnWindow, window.isVisible { window.makeKeyAndOrderFront(nil) }
        usageReturnWindow = nil
        notifyEntryGateChanged()
    }

    private func usageContentSizeChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.usageGuideWindow, window.isVisible else { return }
            if let scroll = window.contentView as? NSScrollView, let content = scroll.documentView {
                scroll.documentView = nil
                window.contentView = content
            }
            window.contentView?.layoutSubtreeIfNeeded()
            self.resizeToFit(window)
        }
    }

    private func notifyEntryGateChanged() {
        ProductHotKeyController.shared.discardQueuedPresses()
        coordinator?.objectWillChange.send()
        collectionCoordinator?.objectWillChange.send()
    }

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
        feedbackWindow?.contentView = NSHostingView(rootView: CaptureFeedbackView(message: message))
        if let content = feedbackWindow?.contentView { feedbackWindow?.setContentSize(content.fittingSize) }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main,
           let window = feedbackWindow {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2,
                                          y: frame.maxY - window.frame.height - 32))
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
        _ = hideSelection()
        hideCaptureGuide()
        if let sheet = discardWindow { problemWindow?.endSheet(sheet, returnCode: .cancel) }
        hidePermission()
        hideProblem()
        feedbackRevision &+= 1
        feedbackWindow?.orderOut(nil)
    }

    func dismissCollectionUI() {
        hideCollection()
        _ = hideCollectionSelection()
        hideCollectionGuide()
        hideCollectionPermission()
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
            CaptureDiscardConfirmationView(kept: { [weak self] in self?.answerDiscard(false) },
                                           discarded: { [weak self] in self?.answerDiscard(true) }))
        resizeToFit(sheet)
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

    func confirmEndAll(singleImage: Bool, collectionCount: Int, hasCandidate: Bool,
                       completion: @escaping @MainActor (Bool) -> Void) {
        guard !hasDiscardConfirmation else { completion(false); return }
        let window = makeWindow(title: "OneClip — 終了の確認", size: NSSize(width: 440, height: 300))
        endAllWindow = window
        endAllCompletion = completion
        window.contentView = NSHostingView(rootView: CaptureEndAllConfirmationView(
            singleImage: singleImage, collectionCount: collectionCount, hasCandidate: hasCandidate,
            kept: { [weak self] in self?.answerEndAll(false) },
            discarded: { [weak self] in self?.answerEndAll(true) }))
        show(window)
        notifyEntryGateChanged()
    }

    private func answerEndAll(_ confirmed: Bool) {
        let completion = endAllCompletion
        endAllCompletion = nil
        endAllWindow?.orderOut(nil)
        endAllWindow = nil
        notifyEntryGateChanged()
        completion?(confirmed)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === problemWindow, coordinator?.hasRetainedImage == true { closeProblem(); return false }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === endAllWindow {
            answerEndAll(false)
        } else if window === onboardingWindow {
            CapturePreferences.shared.recordOnboardingEvent(.closed(fromPageIndex: onboardingActivePage))
            CapturePreferences.shared.completedOnboardingVersion = CapturePreferences.currentOnboardingVersion
            CapturePreferences.shared.hasSeenWelcome = true
            if NSApp.isActive, let returnWindow = onboardingReturnWindow, returnWindow.isVisible {
                returnWindow.makeKeyAndOrderFront(nil)
            }
            onboardingReturnWindow = nil
            notifyEntryGateChanged()
        } else if window === usageGuideWindow {
            closeUsageGuide()
        } else if window === captureGuideWindow {
            let cancelled = captureGuideCancelled
            captureGuideCancelled = nil
            captureGuideOwner = nil
            cancelled?()
        } else if window === permissionWindow {
            let owner = permissionOwner
            permissionOwner = nil
            if owner == .collection { collectionCoordinator?.cancelOperation() }
            else if owner == .single { coordinator?.cancel() }
        } else if window === problemWindow {
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
        hint = "ドラッグを離すと\(actionLabel)・矢印でも選択・Escで取消・1つの画面内"
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
                                                                 y: rect.minY - 8), topAligned: true, avoiding: rect)
        }
        let instruction = drawLabel("\(selectionTitle)・\(hint)",
                                    at: NSPoint(x: 24, y: bounds.height - 24), topAligned: true)
        if expandedHelp && selection == nil && dragStart == nil {
            drawLabel("キーボード: 矢印で範囲を作成 → 移動/大きさ調整 → Enterで\(actionLabel)",
                      at: NSPoint(x: 24, y: instruction.minY - 10), topAligned: true)
        }
    }

    @discardableResult
    private func drawLabel(_ value: String, at point: NSPoint, topAligned: Bool = false,
                           avoiding selection: NSRect? = nil) -> NSRect {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let text = NSAttributedString(string: value, attributes: attributes)
        var x = min(max(12, point.x), max(12, bounds.width - 40))
        let availableWidth = max(1, bounds.width - x - 12)
        let textWidth = max(1, availableWidth - 28)
        let measured = text.boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        let width = min(availableWidth, ceil(measured.width) + 28)
        let height = ceil(measured.height) + 20
        var desiredY = topAligned ? point.y - height : point.y
        if let selection, desiredY < 12 {
            // Keep dimensions outside the selection when there is room on another side.
            if selection.maxY + 8 + height <= bounds.height - 12 {
                desiredY = selection.maxY + 8
            } else if selection.maxX + 8 + width <= bounds.width - 12 {
                x = selection.maxX + 8
                desiredY = selection.minY
            } else if selection.minX - 8 - width >= 12 {
                x = selection.minX - 8 - width
                desiredY = selection.minY
            }
        }
        let y = max(12, min(desiredY, bounds.height - height - 12))
        let rect = NSRect(x: x, y: y, width: width, height: height)
        let bubble = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.20, alpha: 0.96).setFill()
        bubble.fill()
        NSColor.white.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.6 : 0.16).setStroke()
        bubble.lineWidth = 1
        bubble.stroke()
        text.draw(with: rect.insetBy(dx: 14, dy: 10), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return rect
    }

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: display.frame.minX + point.x, y: display.frame.minY + point.y)
    }
}

/// First-use instructions retain the consequences of the next capture action.
private struct CaptureGuideInstructions: View {
    let collection: Bool
    @Environment(\.colorScheme) private var colorScheme
    private var tone: OneClipTone { collection ? .collection : .single }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            guideStep(symbol: collection ? "1.circle" : "cursorarrow", title: collection ? "必要な箇所を、最大4枚" : "ドラッグで範囲を選択",
                      message: collection
                        ? "範囲を選ぶと素材が追加されます。別のアプリを操作しながら集められます。"
                        : "1つの画面内でドラッグし、離すとコピー・保存します。")
            Divider()
            guideStep(symbol: collection ? "doc.on.clipboard" : "keyboard", title: collection ? "完成画像を確認してコピー" : "矢印でも選べます",
                      message: collection
                        ? "収集中はクリップボードを変更しません。撮影順に並ぶ完成画像を確認し、最後に「コピー」でコピー・保存します。"
                        : "矢印で範囲を作成・移動し、Shift + 矢印で大きさを変えます。Enterで確定、Escapeで取り消せます。")
        }
        .oneClipCard()
        VStack(alignment: .leading, spacing: 8) {
            if collection {
                Label("取り直しは新旧を確認してから差し替えます。取消なら元の素材を残します。", systemImage: "arrow.uturn.backward")
                Text("パネルを閉じても素材は残ります。未コピーの素材や変更の破棄は確認します。スリープ・ロック・ユーザー切替・画面構成変更では破棄します。")
                    .foregroundStyle(.secondary)
            } else {
                Label("確定すると、今のクリップボードを置き換えます。", systemImage: "doc.on.clipboard")
                Text("撮影に必要な場合だけ画面収録の許可を案内します。")
                    .foregroundStyle(.secondary)
            }
            Text("完成画像はこのMacに自動保存し、終了やロック後も残ります。保存期限はありません。")
                .foregroundStyle(.secondary)
        }
        .font(.callout).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }

    private func guideStep(symbol: String, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                .foregroundStyle(tone.color(for: colorScheme)).frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Shared, optional detail for settings and the first-use/reviewable guide.
/// Expanding this explanation does not change capture, save, or acknowledgement policy.
struct CaptureDataNotice: View {
    var isActionDisabled = false
    var title = "保存とデータの扱い"
    var includesPermissionNotice = false
    var contentSizeChanged: () -> Void = {}
    @State private var showsDetails = false

    var body: some View {
        DisclosureGroup(title, isExpanded: $showsDetails) {
            VStack(alignment: .leading, spacing: 10) {
                if includesPermissionNotice {
                    Text("撮影に必要な場合だけ画面収録の許可を案内します。")
                }
                Text("撮影原本・注釈入りPNG・標準「プレビュー」用の編集コピーは、終了・ロック・素材の破棄後も残ります。自動削除は行いません。")
                Text("保存先はこのアプリ専用のフォルダです。不要な画像は保存フォルダで管理してください。")
                Button("保存フォルダを開く") { CaptureResultController.shared.openFolder() }
                    .disabled(isActionDisabled)
                Text("コメントや囲みは画像を説明するための機能です。写った機密情報を隠すことはできず、原本も残ります。")
                Text("画像やコメントを外部送信せず、選択範囲や収集セッションも保存しません。コピー後の画像や、標準「プレビュー」・貼り付け先での扱いは、各アプリとOSに従います。")
                Link("プライバシーポリシー", destination: URL(string: "https://github.com/TaigaShinohara/OneClip/blob/main/PRIVACY.md")!)
                    .disabled(isActionDisabled)
            }
            .foregroundStyle(.secondary).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
        }
        .font(.callout)
        .onChange(of: showsDetails) { _, _ in contentSizeChanged() }
    }
}

struct CaptureGuideView: View {
    let collection: Bool
    let started: () -> Void
    let cancelled: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    private var tone: OneClipTone { collection ? .collection : .single }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            OneClipHeading(title: collection ? "集めてコピー" : "範囲をコピー",
                           systemName: collection ? "square.stack" : "viewfinder", tone: tone)
            CaptureGuideInstructions(collection: collection)
            HStack {
                Button("取消", action: cancelled).keyboardShortcut(.cancelAction)
                Spacer()
                Button(collection ? "最初の範囲を選ぶ" : "範囲選択を始める", action: started)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .buttonBorderShape(.capsule).controlSize(.large).tint(tone.color(for: colorScheme))
        }
        .oneClipWindow().frame(width: 500, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct CaptureUsageGuideView: View {
    let reopenOnboarding: () -> Void
    let closed: (Set<Bool>) -> Void
    let contentSizeChanged: () -> Void
    @State private var collection: Bool
    @State private var viewedModes: Set<Bool>
    @State private var showsOperationDetails = false
    @Environment(\.colorScheme) private var colorScheme

    init(collection: Bool = false,
         reopenOnboarding: @escaping () -> Void = {},
         closed: @escaping (Set<Bool>) -> Void,
         contentSizeChanged: @escaping () -> Void = {}) {
        self.reopenOnboarding = reopenOnboarding
        self.closed = closed
        self.contentSizeChanged = contentSizeChanged
        _collection = State(initialValue: collection)
        _viewedModes = State(initialValue: [collection])
    }

    private var activeTone: OneClipTone {
        collection ? .collection : .single
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            OneClipHeading(title: "OneClipの使い方",
                           systemName: collection ? "square.stack" : "viewfinder",
                           tone: activeTone)

            VStack(alignment: .leading, spacing: 10) {
                Picker("撮影の使い方", selection: $collection) {
                    Text("範囲をコピー").tag(false)
                    Text("集めてコピー").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    Text(collection ? "集めて、一枚に" : "ドラッグして、離すだけ")
                        .font(.title3.weight(.semibold))
                    Text(collection
                         ? "1つの画面内で範囲を選び、最大4枚を追加します。"
                         : "1つの画面内で範囲を選択。離すとコピー・保存します。")
                    CaptureUsageDiagram(collection: collection)
                        .frame(height: 82)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                    if collection {
                        Text("撮影順に並ぶ完成画像を確認し、最後に「コピー」でコピー・保存します。")
                    }
                    Label("撮影後の小画像から注釈を追加できます。", systemImage: "text.bubble")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .oneClipCard(padding: 18)
            }

            VStack(alignment: .leading, spacing: 10) {
                noticeRow(systemName: "menubar.rectangle",
                          text: "メニューバーから撮影。キーの変更は「設定…」へ。")
                noticeRow(systemName: "doc.on.clipboard",
                          text: collection
                          ? "収集中はクリップボードを変更しません。最後の「コピー」で置き換えます。"
                          : "確定すると、今のクリップボードを置き換えます。")
                noticeRow(systemName: "internaldrive",
                          text: "画像はこのMacに自動保存され、終了・ロック後も残ります。保存期限はありません。")
            }

            VStack(alignment: .leading, spacing: 10) {
                Divider()
                DisclosureGroup(collection ? "操作と素材の扱い" : "キーボードでの操作",
                                isExpanded: $showsOperationDetails) {
                    operationDetails.padding(.top, 8)
                }
                Divider()
                CaptureDataNotice(title: "保存・権限の詳細", includesPermissionNotice: true,
                                  contentSizeChanged: contentSizeChanged)
            }
            .font(.callout)

            Divider()

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Button("初回ガイドをもう一度見る…", action: reopenOnboarding)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                Spacer(minLength: 0)
                Button("わかりました") { closed(viewedModes.union([collection])) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(activeTone.color(for: colorScheme))
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .oneClipWindow().frame(width: 500, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: collection) { _, value in
            viewedModes.insert(value)
            contentSizeChanged()
        }
        .onChange(of: showsOperationDetails) { _, _ in contentSizeChanged() }
    }

    private func noticeRow(systemName: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemName)
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .center)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var operationDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("矢印で範囲を作成・移動し、Shift + 矢印で大きさを変えます。Enterで確定、Escapeで取り消せます。")
            if collection {
                Text("範囲を選ぶと素材が追加されます。別のアプリを操作しながら集められます。")
                Text("取り直しは、新しい範囲を確認してから差し替えます。途中で取り消すと旧素材を残します。")
                Text("収集パネルを閉じても素材は残ります。未コピーの素材・変更の破棄や、未コピー画像を残して終了する時は確認します。")
                Text("スリープ・ロック・ユーザー切替・画面構成変更では素材を破棄します。保存済みの完成画像は残ります。")
            }
        }
        .font(.callout).foregroundStyle(.secondary).lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A schematic made entirely from shapes; it never reads a screen or a captured image.
private struct CaptureUsageDiagram: View {
    let collection: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var accent: Color { (collection ? OneClipTone.collection : .single).color(for: colorScheme) }
    private var outline: Color { .primary.opacity(contrast == .increased ? 0.65 : 0.25) }

    var body: some View {
        HStack(spacing: 20) {
            if collection {
                HStack(alignment: .center, spacing: 6) {
                    ForEach(1..<4) { number in
                        VStack(spacing: 5) {
                            Text("\(number)").font(.caption2.monospacedDigit())
                            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(accent.opacity(0.35))
                                .frame(width: 21, height: CGFloat(12 + number * 4))
                        }
                        .padding(7)
                        .frame(width: 38, height: 60)
                        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(outline))
                    }
                }
            } else {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.035))
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(0..<3) { index in
                            Capsule().fill(Color.primary.opacity(0.14))
                                .frame(width: CGFloat(95 - index * 12), height: 5)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(14)
                    Rectangle().fill(accent.opacity(0.12))
                        .frame(width: 83, height: 46)
                        .overlay(Rectangle().stroke(accent, style: StrokeStyle(lineWidth: 2, dash: [5, 4])))
                        .padding(.trailing, 15).padding(.bottom, 12)
                    Image(systemName: "cursorarrow").font(.system(size: 20))
                        .foregroundStyle(Color.primary).padding(.trailing, 4).padding(.bottom, 1)
                }
                .frame(width: 146, height: 78)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(outline))
            }

            Image(systemName: "arrow.right").font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)

            ZStack {
                Image(systemName: "clipboard").font(.system(size: 66, weight: .ultraLight))
                    .foregroundStyle(outline)
                VStack(spacing: 3) {
                    ForEach(0..<(collection ? 3 : 1), id: \.self) { _ in
                        Rectangle().fill(accent.opacity(0.25))
                            .frame(width: 25, height: collection ? 11 : 30)
                    }
                }
                .padding(.top, 7)
            }
            .frame(width: 64, height: 78)
        }
    }
}

struct CaptureFeedbackView: View {
    let message: String
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 12) {
            OneClipBadge(systemName: "info", tone: .neutral, size: 30)
            Text(message).font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minHeight: 58).frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.45 : 0.08))
        }
    }
}

struct CaptureDiscardConfirmationView: View {
    let kept: () -> Void
    let discarded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            OneClipHeading(title: "未コピーの画像を破棄しますか？", systemName: "trash", tone: .warning)
            Text("破棄すると、この画像は再コピーできません。")
                .font(.callout).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("画像を残す", action: kept).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("破棄する", action: discarded)
            }
            .buttonBorderShape(.capsule).controlSize(.large)
        }
        .oneClipWindow().frame(width: 440, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand(perform: kept)
    }
}

private struct CaptureEndAllConfirmationView: View {
    let singleImage: Bool
    let collectionCount: Int
    let hasCandidate: Bool
    let kept: () -> Void
    let discarded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            OneClipHeading(title: "保持している画像と素材を破棄して終了しますか？",
                           systemName: "exclamationmark", tone: .warning)
            VStack(alignment: .leading, spacing: 8) {
                if singleImage { Text("範囲をコピー：未コピーの画像 1枚") }
                if collectionCount > 0 { Text("集めてコピー：収集中の素材 \(collectionCount)枚") }
                if hasCandidate { Text("取り直し：確認中の候補 1枚") }
                Text("終了後はこれらの画像を復元できません。クリップボードは変更しません。")
                    .foregroundStyle(.secondary)
            }
            .font(.callout).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("戻る", action: kept).keyboardShortcut(.cancelAction)
                Spacer()
                Button("すべて破棄して終了", role: .destructive, action: discarded)
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
        }
        .oneClipWindow().frame(width: 440, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct CapturePermissionView: View {
    @ObservedObject var coordinator: SingleCaptureCoordinator
    let contentSizeChanged: () -> Void
    var body: some View {
        CapturePermissionContent(status: coordinator.permissionStatus, message: coordinator.permissionMessage,
                                 tone: .single, simulated: simulated,
                                 requested: { coordinator.requestPermission() },
                                 selected: { coordinator.retryPermission() },
                                 cancelled: { coordinator.cancel() }, contentSizeChanged: contentSizeChanged,
                                 checked: { coordinator.refreshPermissionStatus() })
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                coordinator.refreshPermissionStatus()
            }
    }
    private var simulated: Bool {
        #if DEBUG
        M2FailureLab.isEnabled || M3FailureLab.isEnabled
        #else
        false
        #endif
    }
}

struct CollectionPermissionView: View {
    @ObservedObject var coordinator: CollectionCaptureCoordinator
    let contentSizeChanged: () -> Void
    var body: some View {
        CapturePermissionContent(status: coordinator.permissionStatus, message: coordinator.permissionMessage,
                                 tone: .collection, simulated: simulated,
                                 requested: { coordinator.requestPermission() },
                                 selected: { coordinator.retryPermission() },
                                 cancelled: { coordinator.cancelOperation() }, contentSizeChanged: contentSizeChanged,
                                 checked: { coordinator.refreshPermissionStatus() })
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                coordinator.refreshPermissionStatus()
            }
    }
    private var simulated: Bool {
        #if DEBUG
        M3FailureLab.isEnabled
        #else
        false
        #endif
    }
}

/// Shared presentation never interprets an unconfirmed preflight as a denied request.
private struct CapturePermissionContent: View {
    let status: CapturePermissionStatus
    let message: String
    let tone: OneClipTone
    let simulated: Bool
    let requested: () -> Void
    let selected: () -> Void
    let cancelled: () -> Void
    let contentSizeChanged: () -> Void
    let checked: () -> Void
    @State private var showsHelp = false
    @Environment(\.colorScheme) private var colorScheme

    init(status: CapturePermissionStatus, message: String, tone: OneClipTone, simulated: Bool,
         requested: @escaping () -> Void, selected: @escaping () -> Void, cancelled: @escaping () -> Void,
         contentSizeChanged: @escaping () -> Void, checked: @escaping () -> Void = {}) {
        self.status = status; self.message = message; self.tone = tone; self.simulated = simulated
        self.requested = requested; self.selected = selected; self.cancelled = cancelled
        self.contentSizeChanged = contentSizeChanged; self.checked = checked
    }

    private var needsSettings: Bool { status == .requestUnconfirmed || status == .noLongerAvailable }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            OneClipHeading(title: "画面収録の許可", subtitle: tone == .collection ? "集めてコピー" : "範囲をコピー",
                           systemName: "rectangle.on.rectangle", tone: tone)
            VStack(alignment: .leading, spacing: 12) {
                Text(message).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                Label("撮影した画像はこのMacに保存します。外部送信は行いません。", systemImage: "lock")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .oneClipCard()
            if simulated {
                Text("安全な試験：許可要求と確認は模擬です。macOSの設定は変更しません。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("許可済み・許可を確認できない場合", isExpanded: $showsHelp) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("システム設定 → プライバシーとセキュリティ → 画面収録（画面とシステムオーディオの収録）で、OneClipを確認します。")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("目的の画面が開かなければ、上の順に開いてください。OSがアプリの終了や再起動を求めた時だけ、その案内に従ってください。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !simulated && !needsSettings {
                        Button("画面収録の設定を開く", action: openSettings)
                    }
                    if needsSettings { Button("もう一度許可を求める", action: requested) }
                    Button("許可を確認", action: checked)
                    Text("設定から戻っても撮影は始まりません。「許可を確認」で状態を確かめ、許可を確認できたら「範囲を選ぶ」で進みます。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout).lineSpacing(3).padding(.top, 10)
            }
            .font(.callout)
            HStack {
                Button("キャンセル", action: cancelled).keyboardShortcut(.cancelAction)
                Spacer()
                if status == .granted {
                    Button("範囲を選ぶ", action: selected).buttonStyle(.borderedProminent)
                } else if needsSettings {
                    Button("画面収録の設定を開く", action: openSettings).buttonStyle(.borderedProminent)
                        .disabled(simulated)
                } else {
                    Button("許可を求める", action: requested).buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large).buttonBorderShape(.capsule).tint(tone.color(for: colorScheme))
        }
        .oneClipWindow().frame(width: 460, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { showsHelp = needsSettings }
        .onChange(of: showsHelp) { _, _ in contentSizeChanged() }
        .onChange(of: message) { _, _ in contentSizeChanged() }
        .onChange(of: status) { _, newStatus in
            showsHelp = newStatus == .requestUnconfirmed || newStatus == .noLongerAvailable
            contentSizeChanged()
        }
    }

    private func openSettings() {
        guard !simulated else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
           NSWorkspace.shared.open(url) { return }
        // If this OS does not accept the destination URL, keep the written route available.
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}

struct CaptureProblemView: View {
    @ObservedObject var coordinator: SingleCaptureCoordinator
    let interface: NativeCaptureInterface
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            OneClipHeading(title: coordinator.problem?.title ?? "処理を完了できませんでした",
                           systemName: "exclamationmark", tone: .warning)
            VStack(alignment: .leading, spacing: 14) {
                Text(coordinator.problem?.message ?? "")
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                if coordinator.hasRetainedImage {
                    Label("取得した画像をメモリに保持しています。「再コピー」は同じ画像を使い、撮り直しません。", systemImage: "photo")
                        .font(.callout).foregroundStyle(.secondary)
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                if coordinator.problem?.clipboardMayHaveChanged == true {
                    Label("書込み準備後に失敗したため、以前のクリップボード内容は残っていない場合があります。", systemImage: "exclamationmark.circle")
                        .font(.callout).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .oneClipCard()
            HStack {
                if coordinator.hasRetainedImage {
                    Button("再コピー") { coordinator.retryCopy() }
                        .buttonStyle(.borderedProminent).disabled(coordinator.isWorking)
                    Spacer()
                    Button("破棄…") { interface.closeProblem() }.disabled(coordinator.isWorking)
                } else {
                    Button("もう一度選択") { coordinator.retrySelection() }
                        .buttonStyle(.borderedProminent).disabled(coordinator.isWorking)
                    Spacer()
                    Button("閉じる") { coordinator.cancel() }
                }
            }
            .buttonBorderShape(.capsule).controlSize(.large)
        }
        .oneClipWindow().frame(width: 480, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
            .onExitCommand { interface.closeProblem() }
    }
}

// MARK: - Compact onboarding (one task per page)

enum OnboardingPageRole: String, Equatable, Sendable {
    case identity, selection, interaction, match, connection
}

struct OnboardingWindowDots: Equatable, Sendable {
    enum ScaleKind: Equatable, Sendable {
        case current
        case neighbor
        case edgeCompressed
    }

    struct DotItem: Equatable, Sendable, Identifiable {
        let pageIndex: Int
        let isCurrent: Bool
        let scaleKind: ScaleKind
        var id: Int { pageIndex }
    }

    /// Computes at most 5 visible dots centered around `currentPage`:
    /// `window = min(5, totalPages)`, `start = clamp(currentPage - 2, 0, totalPages - window)`.
    static func compute(currentPage: Int, totalPages: Int) -> [DotItem] {
        guard totalPages > 0 else { return [] }
        let windowSize = min(5, totalPages)
        let clampedCurrent = min(max(0, currentPage), totalPages - 1)
        let start = min(max(0, clampedCurrent - 2), max(0, totalPages - windowSize))
        let end = start + windowSize - 1
        return (start...end).map { page in
            let isCurrent = page == clampedCurrent
            let isCompressedLeft = page == start && start > 0 && !isCurrent
            let isCompressedRight = page == end && end < totalPages - 1 && !isCurrent
            let kind: ScaleKind = isCurrent ? .current : ((isCompressedLeft || isCompressedRight) ? .edgeCompressed : .neighbor)
            return DotItem(pageIndex: page, isCurrent: isCurrent, scaleKind: kind)
        }
    }
}

struct OnboardingPageSpec: Equatable, Sendable, Identifiable {
    let index: Int
    let role: OnboardingPageRole
    let headline: String
    let subtitle: String
    let tone: OneClipTone
    let heroDescription: String
    var id: Int { index }
    var pageNumber: Int { index + 1 }
    var requiresChoiceToAdvance: Bool { role == .selection || role == .interaction }
}

enum OnboardingPageCatalog {
    static let totalPageCount = 5

    static func pages(for concern: OnboardingConcern, trialSample: OnboardingTrialSample) -> [OnboardingPageSpec] {
        let tone: OneClipTone = concern.prefersCollection ? .collection : .single
        return [
            .init(index: 0, role: .identity, headline: "必要なところを、ひと貼り",
                  subtitle: "画面上部のOneClipメニューから撮り方を選びます。", tone: .single,
                  heroDescription: "OneClipメニュー。範囲をコピーは1箇所、集めてコピーは最大4枚を1枚にまとめます。"),
            .init(index: 1, role: .selection, headline: "何を伝えたいですか？",
                  subtitle: "使い始める撮り方を選びます。あとから変更できます。", tone: .single,
                  heroDescription: "用途を選ぶ4つのボタン。選ぶと範囲選択の練習へ進みます。"),
            .init(index: 2, role: .interaction, headline: "試しに範囲を選ぶ",
                  subtitle: "枠をクリック、またはドラッグします。実際の画面の撮影・コピー・保存は行いません。", tone: tone,
                  heroDescription: "架空の画面にある3つの範囲。ドラッグまたはボタンで選べます。"),
            .init(index: 3, role: .match, headline: "撮影後は、ここから注釈",
                  subtitle: "本番では右下の小画像からコメントや記号を追加できます。", tone: tone,
                  heroDescription: "選んだ「\(trialSample.title)」の見本。小画像にコメント・記号を追加する入口があります。"),
            .init(index: 4, role: .connection, headline: "メニューから始めましょう",
                  subtitle: "撮影画像はこのMacへ自動保存されます。必要なときだけ画面収録の許可を案内します。", tone: tone,
                  heroDescription: concern.connectionButtonTitle)
        ]
    }
}

struct OneClipOnboardingView: View {
    let preferences: CapturePreferences
    var pageChanged: (Int) -> Void = { _ in }
    let completed: (OnboardingConcern, OnboardingTrialSample) -> Void
    let skipped: (Int) -> Void
    var contentSizeChanged: () -> Void = {}

    @State private var currentPage = 0
    @State private var selectedConcern: OnboardingConcern
    @State private var selectedTrialSample: OnboardingTrialSample
    @State private var heroEntered = false
    @State private var mockDragStart: CGPoint?
    @State private var mockDragCurrent: CGPoint?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(preferences: CapturePreferences = .shared,
         pageChanged: @escaping (Int) -> Void = { _ in },
         completed: @escaping (OnboardingConcern, OnboardingTrialSample) -> Void,
         skipped: @escaping (Int) -> Void,
         contentSizeChanged: @escaping () -> Void = {}) {
        self.preferences = preferences
        self.pageChanged = pageChanged
        self.completed = completed
        self.skipped = skipped
        self.contentSizeChanged = contentSizeChanged
        _selectedConcern = State(initialValue: preferences.selectedOnboardingConcern ?? .multi)
        _selectedTrialSample = State(initialValue: preferences.completedOnboardingTrial ?? .issueArea)
    }

    private var pages: [OnboardingPageSpec] {
        OnboardingPageCatalog.pages(for: selectedConcern, trialSample: selectedTrialSample)
    }

    private var page: OnboardingPageSpec {
        let all = pages
        return all[min(max(0, currentPage), all.count - 1)]
    }

    private var accentColor: Color {
        page.tone.color(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            topNavigationBar
            headlineAndSubtitleSection
            heroStageView
                .frame(height: 224)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: page.requiresChoiceToAdvance ? .contain : .ignore)
                .accessibilityLabel(page.heroDescription)
            bottomActionSection
        }
        .oneClipWindow(padding: 26)
        .frame(width: 520, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            recordView(for: 0)
            triggerPageAnimations()
        }
        .onChange(of: currentPage) { _, newPage in
            pageChanged(newPage)
            recordView(for: newPage)
            triggerPageAnimations()
            contentSizeChanged()
        }
        .onExitCommand { skipped(currentPage) }
    }

    // MARK: Navigation

    private var topNavigationBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: goBackNeutral) {
                Label("戻る", systemImage: "chevron.left")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.borderless)
            .opacity(currentPage > 0 ? 1 : 0)
            .disabled(currentPage == 0)
            .accessibilityHidden(currentPage == 0)

            Spacer(minLength: 0)

            OnboardingWindowDotsView(
                currentPage: currentPage,
                totalPages: pages.count,
                accentColor: accentColor
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("全\(pages.count)ページ中\(currentPage + 1)ページ")

            Spacer(minLength: 0)

            Button("スキップ") {
                skipped(currentPage)
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var headlineAndSubtitleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(page.headline)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            Text(page.subtitle)
                .font(.body).foregroundStyle(.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 88, alignment: .topLeading)
    }

    // MARK: Synthetic illustrations and practice

    private var heroStageView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.045) : Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.07 : 0.035), radius: 10, y: 3)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.45 : 0.05))

            stageContent(for: page)
                .padding(18)
                .opacity(heroEntered ? 1.0 : 0.0)
                .offset(y: heroEntered || reduceMotion ? 0 : 8)
        }
        .clipped()
    }

    @ViewBuilder
    private func stageContent(for spec: OnboardingPageSpec) -> some View {
        switch spec.role {
        case .identity: identityStageView
        case .selection: concernSelectionStageView
        case .interaction: interactionTrialStageView
        case .match: trialResultStageView
        case .connection: connectionStageView
        }
    }

    // Choosing a use case advances directly to the synthetic practice.
    private var concernSelectionStageView: some View {
        VStack(spacing: 8) {
            ForEach(OnboardingConcern.allCases) { option in
                let isSelected = selectedConcern == option
                Button {
                    chooseConcern(option)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: option.optionSymbol)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(selectedConcern == option ? accentColor : .secondary)
                            .frame(width: 28, height: 28)
                            .background(
                                Circle().fill((selectedConcern == option ? accentColor : Color.primary).opacity(0.10))
                            )
                        Text(option.optionTitle)
                            .font(.callout.weight(selectedConcern == option ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isSelected ? accentColor : .secondary.opacity(0.6))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(isSelected ? accentColor.opacity(0.14) : Color.primary.opacity(0.035))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(isSelected ? accentColor : Color.primary.opacity(contrast == .increased ? 0.35 : 0.08),
                                          lineWidth: isSelected ? 1.5 : 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.optionTitle)。押すと自動で次のページへ進みます")
            }
        }
    }

    // The two capture modes share the existing menu labels.
    private var identityStageView: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(accentColor, in: Capsule())
                Text("OneClip")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("14:20")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Image(systemName: "viewfinder")
                        .foregroundStyle(OneClipTone.single.color(for: colorScheme))
                    Text("範囲をコピー")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text("1箇所をすぐ貼る")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(OneClipTone.single.color(for: colorScheme).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack(spacing: 10) {
                    Image(systemName: "square.stack")
                        .foregroundStyle(OneClipTone.collection.color(for: colorScheme))
                    Text("集めてコピー…")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text("最大4枚を1枚に")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(OneClipTone.collection.color(for: colorScheme).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(10)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.12)))
            .scaleEffect(heroEntered || reduceMotion ? 1.0 : 0.92, anchor: .top)
        }
        .frame(maxWidth: 360)
    }

    // The practice uses shapes only and never captures, saves or copies.
    private var interactionTrialStageView: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    )

                HStack(spacing: 10) {
                    ForEach(OnboardingTrialSample.allCases) { sample in
                        Button {
                            completeMiniTrial(with: sample)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: sample.symbol)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(accentColor)
                                    Spacer()
                                    Text(sample.dimensionsLabel)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text(sample.title)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.primary)
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(accentColor.opacity(0.14))
                                    .frame(height: 28)
                                    .overlay(
                                        HStack(spacing: 4) {
                                            Image(systemName: "viewfinder")
                                                .font(.caption2)
                                            Text("ここを選ぶ")
                                                .font(.caption2.weight(.medium))
                                        }
                                        .foregroundStyle(accentColor)
                                    )
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(nsColor: .windowBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(accentColor.opacity(0.45),
                                                  style: StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(sample.title)、\(sample.dimensionsLabel)。押すと切り取って結果ページへ進みます")
                    }
                }
                .padding(12)

                if let start = mockDragStart, let current = mockDragCurrent {
                    let rect = CGRect(x: min(start.x, current.x),
                                      y: min(start.y, current.y),
                                      width: abs(current.x - start.x),
                                      height: abs(current.y - start.y))
                    Rectangle()
                        .fill(accentColor.opacity(0.18))
                        .frame(width: max(8, rect.width), height: max(8, rect.height))
                        .overlay(Rectangle().stroke(accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 4])))
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 136)
            .gesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onChanged { value in
                        mockDragStart = value.startLocation
                        mockDragCurrent = value.location
                    }
                    .onEnded { value in
                        mockDragStart = nil
                        mockDragCurrent = nil
                        let third = 440.0 / 3.0
                        let picked: OnboardingTrialSample
                        if value.location.x < third {
                            picked = .issueArea
                        } else if value.location.x < third * 2 {
                            picked = .settingsValue
                        } else {
                            picked = .afterResult
                        }
                        completeMiniTrial(with: picked)
                    }
            )
        }
    }

    // The result is explicitly a mock, with the annotation entry shown.
    private var trialResultStageView: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("切り取りの見本")
                            .font(.callout.weight(.semibold))
                        Text("\(selectedTrialSample.title)・\(selectedTrialSample.dimensionsLabel)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Label("コメント・記号を追加", systemImage: "pencil.tip.crop.circle")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(accentColor.opacity(0.14), in: Capsule())
                        .foregroundStyle(accentColor)
                }
            }
            .padding(14)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(accentColor.opacity(0.45), lineWidth: 1.5))
            .scaleEffect(heroEntered || reduceMotion ? 1.0 : 0.86)
        }
    }

    // Continue to the mode guide without starting a capture.
    private var connectionStageView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                OneClipBadge(systemName: selectedConcern.prefersCollection ? "square.stack" : "viewfinder",
                             tone: page.tone, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedConcern.prefersCollection ? "集めてコピー" : "範囲をコピー")
                        .font(.headline)
                    Text(selectedConcern.prefersCollection ? "最大4枚を選ぶ → コピー → ⌘Vで貼り付け" : "範囲を選ぶ → ⌘Vで貼り付け")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(accentColor.opacity(0.35)))
        }
    }

    private var bottomActionSection: some View {
        HStack {
            Spacer(minLength: 0)
            if page.role == .connection {
                Button(selectedConcern.connectionButtonTitle) {
                    completed(selectedConcern, selectedTrialSample)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            } else if !page.requiresChoiceToAdvance {
                Button("次へ", action: advance)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .buttonBorderShape(.capsule).controlSize(.large).tint(accentColor)
    }

    private func advance() {
        guard !page.requiresChoiceToAdvance, currentPage < pages.count - 1 else { return }
        currentPage += 1
    }

    private func goBackNeutral() {
        guard currentPage > 0 else { return }
        currentPage -= 1
    }

    private func chooseConcern(_ concern: OnboardingConcern) {
        guard page.role == .selection else { return }
        selectedConcern = concern
        preferences.recordOnboardingEvent(.concernSelected(concern))
        currentPage += 1
    }

    private func completeMiniTrial(with sample: OnboardingTrialSample) {
        guard page.role == .interaction else { return }
        selectedTrialSample = sample
        preferences.recordOnboardingEvent(.trialCompleted(sample))
        currentPage += 1
    }

    private func triggerPageAnimations() {
        heroEntered = false
        if reduceMotion {
            heroEntered = true
        } else {
            withAnimation(.easeOut(duration: 0.18)) { heroEntered = true }
        }
    }

    private func recordView(for index: Int) {
        let all = pages
        guard index >= 0 && index < all.count else { return }
        preferences.recordOnboardingEvent(.pageViewed(pageIndex: index, role: all[index].role.rawValue))
    }
}

private struct OnboardingWindowDotsView: View {
    let currentPage: Int
    let totalPages: Int
    let accentColor: Color

    var body: some View {
        let items = OnboardingWindowDots.compute(currentPage: currentPage, totalPages: totalPages)
        HStack(spacing: 6) {
            ForEach(items) { item in
                Capsule(style: .continuous)
                    .fill(dotColor(for: item))
                    .frame(width: dotWidth(for: item), height: dotHeight(for: item))
            }
        }
        .allowsHitTesting(false)
    }

    private func dotColor(for item: OnboardingWindowDots.DotItem) -> Color {
        if item.isCurrent {
            return accentColor
        }
        return Color.primary.opacity(item.scaleKind == .edgeCompressed ? 0.16 : 0.26)
    }

    private func dotWidth(for item: OnboardingWindowDots.DotItem) -> CGFloat {
        switch item.scaleKind {
        case .current: return 22
        case .neighbor: return 7
        case .edgeCompressed: return 5
        }
    }

    private func dotHeight(for item: OnboardingWindowDots.DotItem) -> CGFloat {
        switch item.scaleKind {
        case .current, .neighbor: return 7
        case .edgeCompressed: return 5
        }
    }
}
