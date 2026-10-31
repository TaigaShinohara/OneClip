import AppKit
import SwiftUI

/// A single annotation document; the canvas and export share the pixel renderer.
struct CaptureAnnotationEditorView: View {
    @ObservedObject var controller: CaptureAnnotationController
    @State private var actualPixels = false
    @FocusState private var commentFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            heading
            Divider()
            toolbar
            Divider()
            workspace
            Divider()
            footer
        }
        .frame(minWidth: 740, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: controller.pendingCommentPoint) { _, point in
            if point != nil { commentFocused = true }
        }
        .onChange(of: controller.isOpen) { _, open in
            if !open { commentFocused = false }
        }
    }

    private var heading: some View {
        HStack(spacing: 12) {
            OneClipBadge(systemName: "pencil.tip.crop.circle", tone: .single, size: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text("画像に注釈").font(.title3.bold())
                Text("矢印やコメントで、伝えたい箇所を示せます。原本はそのまま残ります。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            toolButton(nil, title: "選択", symbol: "cursorarrow")
            toolButton(.comment, title: "コメント", symbol: "text.bubble")
            toolButton(.arrow, title: "矢印", symbol: "arrow.up.right")
            toolButton(.rectangle, title: "囲み", symbol: "rectangle")
            toolButton(.number, title: "番号", symbol: "number.circle")
            Spacer(minLength: 12)
            Button { controller.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!controller.canUndo || controller.isWorking)
                .help("元に戻す").accessibilityLabel("元に戻す")
            Button { controller.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!controller.canRedo || controller.isWorking)
                .help("やり直す").accessibilityLabel("やり直す")
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private func toolButton(_ kind: CaptureAnnotation.Kind?, title: String, symbol: String) -> some View {
        Button {
            controller.tool = kind
            commentFocused = false
        } label: {
            Label(title, systemImage: symbol).font(.callout)
        }
        .background {
            if controller.tool == kind {
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.16))
            }
        }
        .disabled(controller.isWorking || controller.image == nil)
        .accessibilityValue(controller.tool == kind ? "選択中" : "")
    }

    private var workspace: some View {
        HStack(alignment: .top, spacing: 0) {
            ZStack {
                if controller.image != nil {
                    CaptureAnnotationCanvas(controller: controller, actualPixels: actualPixels)
                } else {
                    VStack(spacing: 12) {
                        if controller.isWorking || controller.isOpen { ProgressView() }
                        Text(controller.isOpen ? "画像を準備しています…" : "編集する画像はありません")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            inspector.frame(width: 232).padding(16)
        }
    }

    private var canEditComment: Bool {
        controller.pendingCommentPoint != nil || controller.selectedAnnotation?.kind == .comment
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("コメント").font(.headline)
                    Text(commentHelp).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextEditor(text: $controller.commentDraft)
                    .font(.body).focused($commentFocused)
                    .frame(minHeight: 136, maxHeight: 180).padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.16)))
                    .disabled(!canEditComment || controller.isWorking)
                    .accessibilityLabel("画像に付けるコメント")
                VStack(alignment: .leading, spacing: 8) {
                    Button("コメントを適用") { controller.applyComment() }
                        .disabled(!canEditComment || controller.isWorking
                                  || controller.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("入力を取り消す") {
                        controller.cancelComment()
                        commentFocused = false
                    }
                    .disabled(!canEditComment || controller.isWorking)
                }
                Divider()
                if let selected = controller.selectedAnnotation {
                    Label(kindTitle(selected.kind) + "を選択中", systemImage: "checkmark.circle")
                        .font(.callout.weight(.medium))
                    Text("「選択」でドラッグすると移動できます。画像を選択中はDeleteで削除、⌘Zで元に戻せます。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("選択した注釈を削除", role: .destructive) { controller.deleteSelected() }
                        .disabled(controller.isWorking)
                } else {
                    Text(toolHelp).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let image = controller.image {
                    Divider()
                    Text("\(image.image.width) × \(image.image.height) px")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }

    private var commentHelp: String {
        if controller.pendingCommentPoint != nil { return "この位置に付ける文を入力してください。" }
        if controller.selectedAnnotation?.kind == .comment { return "選択したコメントを書き換えられます。" }
        return "「コメント」を選び、画像上をクリックして入力位置を決めます。"
    }

    private var toolHelp: String {
        switch controller.tool {
        case .comment: return "画像上をクリックしてコメントを置きます。"
        case .arrow: return "矢印の始点から、指したい箇所までドラッグします。"
        case .rectangle: return "囲みたい範囲の対角線をドラッグします。"
        case .number: return "画像上をクリックして番号を置きます。"
        case nil: return "注釈をクリックして選び、ドラッグで移動します。"
        }
    }

    private func kindTitle(_ kind: CaptureAnnotation.Kind) -> String {
        switch kind {
        case .comment: return "コメント"
        case .arrow: return "矢印"
        case .rectangle: return "囲み"
        case .number: return "番号"
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Picker("表示倍率", selection: $actualPixels) {
                Text("全体").tag(false)
                Text("100%").tag(true)
            }
            .pickerStyle(.segmented).frame(width: 150)
            .disabled(controller.image == nil || controller.isWorking)
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.statusText).font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("注釈を画像に焼き込み、別のPNGとして保存します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if controller.isWorking { ProgressView().controlSize(.small) }
            Button("閉じる") { _ = controller.requestClose() }.disabled(controller.isWorking)
            Button("保存してコピー") { controller.saveAndCopy() }
                .buttonStyle(.borderedProminent).disabled(!controller.canExport || controller.isWorking)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}

@MainActor
private struct CaptureAnnotationCanvas: NSViewRepresentable {
    @ObservedObject var controller: CaptureAnnotationController
    let actualPixels: Bool

    func makeNSView(context: Context) -> AnnotationScrollView {
        let scroll = AnnotationScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        let canvas = AnnotationCanvasView()
        canvas.controller = controller
        canvas.setAccessibilityElement(true)
        canvas.setAccessibilityRole(.image)
        canvas.setAccessibilityLabel("注釈を付ける画像")
        scroll.documentView = canvas
        return scroll
    }

    func updateNSView(_ scroll: AnnotationScrollView, context: Context) {
        guard let canvas = scroll.documentView as? AnnotationCanvasView else { return }
        canvas.controller = controller
        if canvas.actualPixels != actualPixels {
            canvas.actualPixels = actualPixels
            scroll.contentView.scroll(to: .zero)
        }
        canvas.cancelGestureIfUnavailable()
        scroll.needsLayout = true
        scroll.layoutSubtreeIfNeeded()
        canvas.needsDisplay = true
        canvas.window?.invalidateCursorRects(for: canvas)
    }

    static func dismantleNSView(_ scroll: AnnotationScrollView, coordinator: ()) {
        (scroll.documentView as? AnnotationCanvasView)?.finishGesture()
        (scroll.documentView as? AnnotationCanvasView)?.controller = nil
        scroll.documentView = nil
    }
}

@MainActor
private final class AnnotationScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let canvas = documentView as? AnnotationCanvasView else { return }
        canvas.viewportSize = contentView.bounds.size
        canvas.resizeCanvas()
    }
}

/// A flipped, top-left canvas that never owns an image outside its controller.
@MainActor
private final class AnnotationCanvasView: NSView {
    weak var controller: CaptureAnnotationController?
    var actualPixels = false
    var viewportSize = CGSize(width: 480, height: 360)
    private var zoom: CGFloat = 1
    private var gestureStart: CGPoint?
    private var gestureEnd: CGPoint?
    private var previousPoint: CGPoint?
    private var gestureTool: CaptureAnnotation.Kind?
    private var moving = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var imageSize: CGSize? {
        guard let image = controller?.image?.image else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    private var imageRect: CGRect {
        guard let imageSize else { return .zero }
        let size = CGSize(width: imageSize.width * zoom, height: imageSize.height * zoom)
        let backing = window?.backingScaleFactor ?? 1
        return CGRect(x: (max(0, (bounds.width - size.width) / 2) * backing).rounded() / backing,
                      y: (max(0, (bounds.height - size.height) / 2) * backing).rounded() / backing,
                      width: size.width, height: size.height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resizeCanvas()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resizeCanvas()
    }

    func resizeCanvas() {
        guard let imageSize else { needsDisplay = true; return }
        let backing = window?.backingScaleFactor ?? 1
        zoom = actualPixels ? 1 / backing
            : min(1 / backing, max(1, viewportSize.width - 48) / imageSize.width,
                  max(1, viewportSize.height - 48) / imageSize.height)
        let size = CGSize(width: max(viewportSize.width, imageSize.width * zoom + 48),
                          height: max(viewportSize.height, imageSize.height * zoom + 48))
        if frame.size != size { setFrameSize(size) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller, let image = controller.image?.image, let imageSize,
              let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: imageRect.minX, y: imageRect.minY)
        context.scaleBy(x: zoom, y: zoom)
        context.saveGState()
        context.translateBy(x: 0, y: imageSize.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = actualPixels ? .none : .high
        context.draw(image, in: CGRect(origin: .zero, size: imageSize))
        context.restoreGState()
        try? CaptureAnnotationRenderer.draw(controller.annotations, in: context, imageSize: imageSize)
        controller.recordImageDraw()

        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5 / zoom)
        context.setLineDash(phase: 0, lengths: [5 / zoom, 3 / zoom])
        if let selected = controller.selectedAnnotation,
           let rect = try? CaptureAnnotationRenderer.bounds(for: selected, imageSize: imageSize) {
            context.stroke(rect.insetBy(dx: -3 / zoom, dy: -3 / zoom))
        }
        if let point = controller.pendingCommentPoint {
            let point = pixelPoint(point, size: imageSize)
            context.setLineDash(phase: 0, lengths: [])
            context.strokeEllipse(in: CGRect(x: point.x - 5 / zoom, y: point.y - 5 / zoom,
                                             width: 10 / zoom, height: 10 / zoom))
        }
        guard let start = gestureStart, let end = gestureEnd else { return }
        let a = pixelPoint(start, size: imageSize), b = pixelPoint(end, size: imageSize)
        if gestureTool == .rectangle {
            context.stroke(CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                  width: abs(b.x - a.x), height: abs(b.y - a.y)))
        } else if gestureTool == .arrow {
            context.move(to: a)
            context.addLine(to: b)
            context.strokePath()
        }
    }

    override func resetCursorRects() {
        guard controller?.isWorking == false, controller?.isOpen == true else { return }
        addCursorRect(imageRect, cursor: controller?.tool == nil ? .arrow : .crosshair)
    }

    private func normalizedPoint(_ event: NSEvent, clamped: Bool) -> CGPoint? {
        let point = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        guard rect.width > 0, rect.height > 0, clamped || rect.contains(point) else { return nil }
        return CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)),
                       y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }

    private func pixelPoint(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller, controller.isOpen, !controller.isWorking,
              let point = normalizedPoint(event, clamped: false) else { return }
        window?.makeFirstResponder(self)
        gestureStart = point
        gestureEnd = point
        previousPoint = point
        gestureTool = controller.tool
        if controller.tool == nil {
            controller.select(at: point)
            controller.beginMove()
            moving = true
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller, controller.isOpen, !controller.isWorking,
              gestureStart != nil, let point = normalizedPoint(event, clamped: true) else { return }
        if moving, let previousPoint {
            controller.moveSelected(by: CGPoint(x: point.x - previousPoint.x, y: point.y - previousPoint.y))
        }
        previousPoint = point
        gestureEnd = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller, controller.isOpen, !controller.isWorking,
              let start = gestureStart, controller.tool == gestureTool else {
            finishGesture()
            return
        }
        if !moving, let end = normalizedPoint(event, clamped: true) {
            controller.gesture(from: start, to: end)
        }
        finishGesture()
    }

    func finishGesture() {
        if moving { controller?.endMove() }
        moving = false
        gestureStart = nil
        gestureEnd = nil
        previousPoint = nil
        gestureTool = nil
        needsDisplay = true
    }

    func cancelGestureIfUnavailable() {
        if controller?.isOpen != true || controller?.isWorking != false { finishGesture() }
    }

    override func keyDown(with event: NSEvent) {
        guard let controller, controller.isOpen, !controller.isWorking else { super.keyDown(with: event); return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            if modifiers.contains(.shift) { controller.redo() } else { controller.undo() }
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            controller.deleteSelected()
            return
        }
        if event.keyCode == 53 {
            controller.cancelComment()
            return
        }
        if let imageSize, controller.selectedID != nil, !modifiers.contains(.command),
           [UInt16(123), 124, 125, 126].contains(event.keyCode) {
            let step: CGFloat = modifiers.contains(.shift) ? 10 : 1
            var delta = CGPoint.zero
            switch event.keyCode {
            case 123: delta.x = -step / imageSize.width
            case 124: delta.x = step / imageSize.width
            case 125: delta.y = step / imageSize.height
            case 126: delta.y = -step / imageSize.height
            default: break
            }
            controller.beginMove()
            controller.moveSelected(by: delta)
            controller.endMove()
            return
        }
        super.keyDown(with: event)
    }
}
