import AppKit
import SwiftUI
import CoreText

/// Only the active presentation may answer or consume a sheet response.
/// No source image or completed output is part of this state.
struct CollectionDecisionState {
    private(set) var identifier: UUID?
    private var answered = false

    mutating func begin() -> UUID? {
        guard identifier == nil else { return nil }
        let value = UUID()
        identifier = value; answered = false
        return value
    }

    mutating func answer(_ value: UUID) -> Bool {
        guard identifier == value, !answered else { return false }
        answered = true
        return true
    }

    mutating func consume(_ value: UUID) -> Bool {
        guard identifier == value else { return false }
        invalidate()
        return true
    }

    mutating func invalidate() { identifier = nil; answered = false }
}

@MainActor
final class CollectionPanelController: NSObject, NSWindowDelegate {
    static let shared = CollectionPanelController()
    private var window: NSWindow?
    private var sheet: NSWindow?
    private weak var coordinator: CollectionCaptureCoordinator?
    private weak var interface: NativeCaptureInterface?
    private var decisionState = CollectionDecisionState()
    private var decisionCompletion: (@MainActor (Bool) -> Void)?

    func show(coordinator: CollectionCaptureCoordinator, interface: NativeCaptureInterface, activate: Bool) {
        self.coordinator = coordinator; self.interface = interface
        if window == nil {
            let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 900, height: 700)
            let initialSize = NSSize(width: min(520, available.width - 40),
                                     height: min(640, available.height - 60))
            let window = NSPanel(contentRect: NSRect(origin: .zero, size: initialSize),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "OneClip — 集めてコピー"
            window.isRestorable = false; window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.minSize = NSSize(width: min(460, initialSize.width), height: min(420, initialSize.height))
            window.contentView = nil
            window.delegate = self; window.center()
            self.window = window
        }
        if window?.contentView == nil {
            window?.contentView = NSHostingView(rootView: CollectionPanelView(coordinator: coordinator, interface: interface))
        }
        if activate { NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
        else { window?.orderFront(nil) }
    }

    func hide() {
        decisionState.invalidate()
        let completion = decisionCompletion; decisionCompletion = nil
        if let sheet { window?.endSheet(sheet, returnCode: .cancel) }
        sheet = nil
        window?.orderOut(nil)
        window?.contentView = nil
        interface?.collectionExpanded = false
        interface?.collectionConfirmationPending = false
        completion?(false)
    }

    func requestClose(completion: (@MainActor (Bool) -> Void)? = nil) {
        guard sheet == nil, let coordinator else { completion?(false); return }
        guard coordinator.phase != .writing else { completion?(false); return }
        coordinator.prepareToQuit()
        guard coordinator.hasRetainedImages else {
            coordinator.discard(); completion?(true); return
        }
        // Adding/replacing hides the panel. An explicit close/quit must still present its decision.
        if window?.isVisible != true { coordinator.showPanel() }
        guard coordinator.hasRetainedImages else {
            coordinator.discard(); completion?(true); return
        }
        let session = coordinator.sessionID
        let revision = coordinator.revision
        presentConfirmation(title: "集めた素材をすべて破棄しますか？",
                            message: "破棄すると元に戻せません。まだコピーしていません。",
                            keepTitle: "続ける", deleteTitle: "すべて破棄") { [weak coordinator] answer in
            let confirmed = answer && session != nil && coordinator?.sessionID == session
                && coordinator?.revision == revision
            if confirmed { coordinator?.discard() }
            completion?(confirmed)
        }
    }

    func requestDelete(at index: Int, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard sheet == nil, let coordinator, window?.isVisible == true,
              let target = coordinator.deletionTarget(at: index) else { return }
        presentConfirmation(title: "素材\(index + 1)を削除しますか？",
                            message: "削除した素材は元に戻せません。撮り直せない場合があります。他の素材は残ります。",
                            keepTitle: "残す", deleteTitle: "素材\(index + 1)を削除") { [weak self, weak coordinator] answer in
            guard let self, let coordinator, self.window?.isVisible == true,
                  coordinator.sessionID == target.sessionID, coordinator.revision == target.revision else { return }
            let deleted = answer && coordinator.delete(target)
            guard self.window?.isVisible == true, coordinator.sessionID == target.sessionID else { return }
            completion?(deleted)
        }
    }

    private func presentConfirmation(title: String, message: String, keepTitle: String, deleteTitle: String,
                                     completion: @escaping @MainActor (Bool) -> Void) {
        guard sheet == nil, let window, window.isVisible, let decision = decisionState.begin() else {
            completion(false)
            return
        }
        decisionCompletion = completion
        interface?.collectionConfirmationPending = true
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 210), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isRestorable = false; sheet.isReleasedWhenClosed = false
        sheet.contentView = NSHostingView(rootView: CollectionConfirmationView(
            title: title, message: message, keepTitle: keepTitle, deleteTitle: deleteTitle,
            onKeep: { [weak self] in self?.answer(false, decision: decision) },
            onDelete: { [weak self] in self?.answer(true, decision: decision) }))
        if let content = sheet.contentView { sheet.setContentSize(content.fittingSize) }
        self.sheet = sheet
        window.beginSheet(sheet) { [weak self] response in
            Task { @MainActor in
                guard let self, self.decisionState.consume(decision) else { return }
                self.sheet = nil
                self.interface?.collectionConfirmationPending = false
                let completion = self.decisionCompletion; self.decisionCompletion = nil
                completion?(response == .OK)
            }
        }
    }
    private func answer(_ confirmed: Bool, decision: UUID) {
        guard let sheet, decisionState.answer(decision) else { return }
        window?.endSheet(sheet, returnCode: confirmed ? .OK : .cancel)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { requestClose(); return false }
}

struct CollectionConfirmationView: View {
    let title: String
    let message: String
    let keepTitle: String
    let deleteTitle: String
    let onKeep: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            OneClipHeading(title: title, systemName: "trash", tone: .warning)
            Text(message).font(.callout).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .oneClipCard(padding: 16)
            HStack(spacing: 12) {
                Button(keepTitle, action: onKeep)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                Button(deleteTitle, action: onDelete)
                    .onKeyPress(.return) { onKeep(); return .handled }
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
        }
        .oneClipWindow().frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand(perform: onKeep)
        .onKeyPress(.return) { onKeep(); return .handled }
    }
}

private struct CollectionStatusHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct CollectionPanelView: View {
    @ObservedObject var coordinator: CollectionCaptureCoordinator
    let interface: NativeCaptureInterface
    @Environment(\.colorScheme) private var colorScheme
    @State private var expanded = false
    @State private var actualPixels = false
    @State private var statusHeight: CGFloat = 44
    @StateObject private var previewActions = CollectionPreviewActions()
    @FocusState private var focusedAction: String?

    private var hasStatus: Bool {
        coordinator.statusText != "\(coordinator.assets.count)/4枚・未コピー"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                OneClipHeading(title: "集めてコピー", subtitle: "\(coordinator.assets.count)/4枚・未コピー",
                               systemName: "square.stack", tone: .collection)
                Spacer(minLength: 0)
                if expanded {
                    Button("パネルへ戻る") { collapse() }.focused($focusedAction, equals: "back")
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if expanded {
                if hasStatus {
                    ScrollView {
                        statusNotice.background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: CollectionStatusHeightKey.self,
                                                       value: geometry.size.height)
                            }
                        }
                    }
                    .frame(height: min(88, max(1, statusHeight)))
                    .onPreferenceChange(CollectionStatusHeightKey.self) { [height = $statusHeight] value in
                        height.wrappedValue = value
                    }
                }
                if let plan = coordinator.plan { previewCard(plan: plan) }
            } else {
                // Keep the actions visible even with four items or a long failure message.
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if hasStatus { statusNotice }
                        if let plan = coordinator.plan { previewCard(plan: plan) }
                        assetList
                    }
                    .padding(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                actionFooter
            }
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule)
        .oneClipWindow(padding: 24).frame(minWidth: 440, minHeight: 320)
        .focusable()
        .focused($focusedAction, equals: "panel")
        .onAppear { focusedAction = "panel" }
        .onExitCommand {
            if expanded { collapse() } else { CollectionPanelController.shared.requestClose() }
        }
        .onKeyPress(.return) {
            guard !expanded, focusedAction == "panel" || focusedAction == "copy", coordinator.canCopy else { return .ignored }
            coordinator.copy(); return .handled
        }
        .onDisappear { interface.collectionExpanded = false }
    }

    private var statusNotice: some View {
        Label(coordinator.statusText, systemImage: "info.circle")
            .font(.callout).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.updatesFrequently)
            .oneClipCard(padding: 14)
    }

    private var assetList: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(coordinator.items) { item in
                let index = item.id
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(OneClipTone.collection.color(for: colorScheme))
                        .frame(width: 28, height: 28)
                        .background(OneClipTone.collection.color(for: colorScheme).opacity(0.10), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("素材\(index + 1)").font(.body.weight(.semibold))
                        Text("\(item.width) × \(item.height) px")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(Double(item.width) / item.scale, specifier: "%g") × \(Double(item.height) / item.scale, specifier: "%g") pt・\(item.scale, specifier: "%g")倍")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("取り直し") { coordinator.replace(at: index) }
                        .focused($focusedAction, equals: "replace\(index)")
                        .accessibilityLabel("素材\(index + 1)を取り直す")
                    Button("削除…") {
                        CollectionPanelController.shared.requestDelete(at: index) { deleted in
                            focusedAction = deleted ? "add" : "delete\(index)"
                        }
                    }
                    .focused($focusedAction, equals: "delete\(index)")
                    .accessibilityLabel("素材\(index + 1)の削除を確認。元に戻せません")
                }
                .disabled(!coordinator.canEdit)
                if index < coordinator.assets.count - 1 { Divider() }
            }
            if coordinator.assets.isEmpty {
                HStack(spacing: 14) {
                    OneClipBadge(systemName: "plus.viewfinder", tone: .collection, size: 40)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("最初の素材を追加").font(.headline)
                        Text("「追加」で、まとめたい範囲を選べます。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .oneClipCard(padding: 16)
    }

    private func previewCard(plan: M0CompositionPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("完成プレビュー").font(.callout.weight(.semibold))
                    Text("\(plan.width) × \(plan.height) px").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if expanded {
                    Picker("表示", selection: $actualPixels) {
                        Text("全体").tag(false)
                        Text("100%").tag(true)
                    }.pickerStyle(.segmented).frame(width: 150)
                    .focused($focusedAction, equals: "zoom")
                } else {
                    Button("完成を大きく確認") {
                        coordinator.preparePreview()
                        expanded = true; actualPixels = false
                        interface.collectionExpanded = true
                        focusedAction = "back"
                    }.focused($focusedAction, equals: "expand")
                }
            }
            CollectionPreview(coordinator: coordinator, plan: plan, actualPixels: expanded && actualPixels,
                              actions: previewActions)
                .frame(minHeight: expanded ? 72 : 180, maxHeight: expanded ? .infinity : 180)
                .focusable(expanded && actualPixels)
                .focused($focusedAction, equals: "preview")
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(focusedAction == "preview" ? Color.accentColor : .clear, lineWidth: 2)
                        .allowsHitTesting(false)
                }
                .accessibilityLabel("撮影順の完成画像。\(plan.width)かける\(plan.height)ピクセル")
                .accessibilityHint("100%では矢印で移動、Homeで先頭、Tabで画像から移動できます")
                .onKeyPress(keys: CollectionPreviewNavigation.keys) { press in
                    guard let command = CollectionPreviewNavigation.command(
                        for: press.key, modifiers: press.modifiers, expanded: expanded,
                        actualPixels: actualPixels, focused: focusedAction == "preview",
                        confirmationPending: interface.collectionConfirmationPending) else { return .ignored }
                    return previewActions.pan(command) ? .handled : .ignored
                }
            if expanded {
                Text(actualPixels ? "100%：画像1pxを画面1pxで表示。Tabで画像へ、矢印で移動、Homeで先頭" : "全体：表示だけを縮小。コピーする画素数は変わりません")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Keep every source pixel visible; only the surrounding surface has rounded corners.
        .oneClipCard(padding: 14)
    }

    private var actionFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            if coordinator.assets.count == 4 {
                Text("4枚までです。追加するには素材を削除するか、取り直してください。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button("追加…") { coordinator.beginOrAdd() }.disabled(!coordinator.canAdd)
                    .focused($focusedAction, equals: "add")
                Button("コピー") { coordinator.copy() }.disabled(!coordinator.canCopy)
                    .buttonStyle(.borderedProminent)
                    .focused($focusedAction, equals: "copy")
                Spacer(minLength: 0)
                Button("全体を破棄…") { CollectionPanelController.shared.requestClose() }
                    .disabled(coordinator.phase == .writing)
                    .focused($focusedAction, equals: "discard")
            }
            .controlSize(.large)
            if coordinator.isWorking {
                Button("処理を取り消す・素材は残す") { coordinator.cancelOperation() }
                    .disabled(coordinator.phase == .writing).focused($focusedAction, equals: "cancel")
            }
            Text("収集中はクリップボードを変更しません。コピー後は素材を解放します。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func collapse() {
        expanded = false; actualPixels = false
        interface.collectionExpanded = false
        focusedAction = "expand"
    }
}

struct CollectionPermissionView: View {
    @ObservedObject var coordinator: CollectionCaptureCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            OneClipHeading(title: "画面収録の許可", subtitle: "集めてコピー",
                           systemName: "rectangle.inset.filled.and.person.filled", tone: .collection)
            Text(coordinator.permissionMessage).font(.callout).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .oneClipCard(padding: 16)
            VStack(alignment: .leading, spacing: 12) {
                Button("macOSに許可を要求") { coordinator.requestPermission() }
                #if DEBUG
                if M3FailureLab.isEnabled {
                    Text("安全な試験：許可要求と再試行は模擬です。macOSの設定は変更しません。")
                        .font(.callout).foregroundStyle(.secondary)
                } else { systemSettingsButton }
                #else
                systemSettingsButton
                #endif
            }
            HStack {
                Button("もう一度試す") { coordinator.retryPermission() }
                Spacer()
                Button("取消") { coordinator.cancelOperation() }.keyboardShortcut(.cancelAction)
            }
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
        .oneClipWindow().frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
    private var systemSettingsButton: some View {
        Button("システム設定を開く") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

/// Draw immutable source aliases directly. No NSImage thumbnails or retained raster preview copy.
private struct CollectionPreview: NSViewRepresentable {
    let coordinator: CollectionCaptureCoordinator
    let plan: M0CompositionPlan
    let actualPixels: Bool
    let actions: CollectionPreviewActions
    func makeCoordinator() -> CollectionPreviewActions { actions }
    func makeNSView(context: Context) -> CollectionScrollView {
        let scroll = CollectionScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true; scroll.backgroundColor = .windowBackgroundColor
        let canvas = CollectionCanvas()
        canvas.setAccessibilityElement(true)
        canvas.setAccessibilityRole(.image)
        scroll.documentView = canvas
        context.coordinator.attach(scroll)
        return scroll
    }
    func updateNSView(_ scroll: CollectionScrollView, context: Context) {
        guard let canvas = scroll.documentView as? CollectionCanvas else { return }
        canvas.coordinator = coordinator; canvas.actualPixels = actualPixels
        canvas.setAccessibilityLabel("完成画像、\(plan.width) × \(plan.height)ピクセル。撮影順の\(coordinator.assets.count)枚")
        scroll.setActualPixels(actualPixels)
        scroll.needsLayout = true
        scroll.layoutSubtreeIfNeeded()
    }
    static func dismantleNSView(_ scroll: CollectionScrollView, coordinator: CollectionPreviewActions) {
        coordinator.detach(scroll)
        (scroll.documentView as? CollectionCanvas)?.coordinator = nil
        scroll.documentView = nil
    }
}

private final class CollectionCanvas: NSView {
    weak var coordinator: CollectionCaptureCoordinator?
    var actualPixels = false
    var fitSize = NSSize(width: 380, height: 200)
    private var zoom: CGFloat = 1
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); resizeCanvas() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); resizeCanvas() }
    func resizeCanvas() {
        guard let plan = coordinator?.plan else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        zoom = actualPixels ? 1 / scale : min(1 / scale, max(1, fitSize.width - 8) / CGFloat(plan.width), max(1, fitSize.height - 8) / CGFloat(plan.height))
        let size = NSSize(width: max(fitSize.width, CGFloat(plan.width) * zoom),
                          height: max(fitSize.height, CGFloat(plan.height) * zoom))
        if frame.size != size { setFrameSize(size) }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let coordinator, let plan = coordinator.plan, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: max(0, (bounds.width - CGFloat(plan.width) * zoom) / 2),
                            y: max(0, (bounds.height - CGFloat(plan.height) * zoom) / 2))
        context.scaleBy(x: zoom, y: zoom)
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: plan.width, height: plan.height))
        if let completed = coordinator.completed {
            context.draw(completed.image, in: CGRect(x: 0, y: 0, width: plan.width, height: plan.height))
            return
        }
        for (asset, placement) in zip(coordinator.assets, plan.placements) {
            context.draw(asset.image, in: CGRect(x: placement.x, y: plan.height - placement.y - placement.height,
                                               width: placement.width, height: placement.height))
            if let top = placement.numberTop {
                let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(placement.index + 1)", attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
                ]) as CFAttributedString)
                context.saveGState(); context.setShouldAntialias(true); context.textMatrix = .identity
                context.textPosition = CGPoint(x: placement.x, y: plan.height - top - 18)
                CTLineDraw(line, context); context.restoreGState()
            }
        }
    }
}

/// Image-free keyboard policy and geometry. The canvas remains unflipped: positive y moves up.
enum CollectionPreviewNavigation {
    enum Command: Equatable, Sendable { case left, right, up, down, home, end, pageUp, pageDown }
    static let keys: Set<KeyEquivalent> = [.leftArrow, .rightArrow, .upArrow, .downArrow,
                                          .home, .end, .pageUp, .pageDown]

    static func command(for key: KeyEquivalent, modifiers: EventModifiers, expanded: Bool,
                        actualPixels: Bool, focused: Bool, confirmationPending: Bool) -> Command? {
        // Caps Lock / numeric-pad metadata do not turn an arrow into an app shortcut.
        // Command/Control/Option/Shift, including VoiceOver input, continue through the existing path.
        guard expanded, actualPixels, focused, !confirmationPending,
              modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        switch key {
        case .leftArrow: return .left
        case .rightArrow: return .right
        case .upArrow: return .up
        case .downArrow: return .down
        case .home: return .home
        case .end: return .end
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        default: return nil
        }
    }

    static func clamped(_ point: CGPoint, document: CGSize, viewport: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, point.x), max(0, document.width - viewport.width)),
                y: min(max(0, point.y), max(0, document.height - viewport.height)))
    }

    static func topLeft(document: CGSize, viewport: CGSize) -> CGPoint {
        clamped(CGPoint(x: 0, y: document.height), document: document, viewport: viewport)
    }

    static func origin(after command: Command, current: CGPoint, document: CGSize, viewport: CGSize) -> CGPoint {
        var point = clamped(current, document: document, viewport: viewport)
        // Scroll distances use window points. 100% image scaling is still determined by the backing scale.
        let line: CGFloat = 40
        let page = max(line, viewport.height * 0.9)
        switch command {
        case .left: point.x -= line
        case .right: point.x += line
        case .up: point.y += line
        case .down: point.y -= line
        case .home: return topLeft(document: document, viewport: viewport)
        case .end: point = CGPoint(x: document.width, y: 0)
        case .pageUp: point.y += page
        case .pageDown: point.y -= page
        }
        return clamped(point, document: document, viewport: viewport)
    }
}

/// A mode transition requests one reset. Ordinary layouts only constrain the current position.
struct CollectionPreviewViewport {
    private(set) var actualPixels = false
    private var resetToTop = false

    mutating func setActualPixels(_ value: Bool) {
        if value != actualPixels { resetToTop = value }
        actualPixels = value
    }

    mutating func originAfterLayout(current: CGPoint, document: CGSize, viewport: CGSize) -> CGPoint {
        if resetToTop {
            resetToTop = false
            return CollectionPreviewNavigation.topLeft(document: document, viewport: viewport)
        }
        return CollectionPreviewNavigation.clamped(current, document: document, viewport: viewport)
    }
}

/// A synchronous weak bridge avoids coalescing repeated key presses into one SwiftUI state update.
/// It never owns a canvas, a source asset or a completed image.
@MainActor
final class CollectionPreviewActions: ObservableObject {
    private weak var scroll: CollectionScrollView?
    func attach(_ value: CollectionScrollView) { scroll = value }
    func detach(_ value: CollectionScrollView) { if scroll === value { scroll = nil } }
    func pan(_ command: CollectionPreviewNavigation.Command) -> Bool { scroll?.pan(command) ?? false }
}

final class CollectionScrollView: NSScrollView {
    private var viewport = CollectionPreviewViewport()

    func setActualPixels(_ value: Bool) { viewport.setActualPixels(value) }

    func pan(_ command: CollectionPreviewNavigation.Command) -> Bool {
        guard viewport.actualPixels, documentView != nil, window?.attachedSheet == nil else { return false }
        layoutSubtreeIfNeeded()
        guard let documentView else { return false }
        let point = CollectionPreviewNavigation.origin(after: command, current: contentView.bounds.origin,
                                                       document: documentView.bounds.size, viewport: contentView.bounds.size)
        contentView.scroll(to: point)
        reflectScrolledClipView(contentView)
        return true
    }

    override func layout() {
        let origin = contentView.bounds.origin
        super.layout()
        if let canvas = documentView as? CollectionCanvas {
            canvas.fitSize = contentSize
            canvas.resizeCanvas()
        }
        guard let documentView else { return }
        let point = viewport.originAfterLayout(current: origin, document: documentView.bounds.size,
                                               viewport: contentView.bounds.size)
        contentView.scroll(to: point)
        reflectScrolledClipView(contentView)
    }
}
