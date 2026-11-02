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
        .disabled(controller.interactionBlocked())
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
                Text("吹き出しや囲みで、伝えたい箇所を示せます。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("原本は残ります。コメントや囲みで、写った機密情報を隠すことはできません。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            toolButton(nil, title: "選択", symbol: "cursorarrow")
            toolButton(.comment, title: "コメント", symbol: "text.bubble")
            toolButton(.rectangle, title: "四角囲み", symbol: "rectangle")
            toolButton(.freehand, title: "手書き囲み", symbol: "scribble")
            toolButton(.number, title: "番号", symbol: "number.circle")
            Divider().frame(height: 20).padding(.horizontal, 4)
            colorPalette
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

    private var colorPalette: some View {
        HStack(spacing: 6) {
            ForEach(AnnotationColor.allCases, id: \.self) { color in
                Button {
                    controller.setColor(color)
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color(cgColor: color.cgColor))
                            .frame(width: 18, height: 18)
                        Circle()
                            .strokeBorder(color == .white ? Color.gray.opacity(0.4) : Color.white.opacity(0.6), lineWidth: 1)
                            .frame(width: 18, height: 18)
                        if controller.selectedColor == color {
                            Circle()
                                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                                .frame(width: 24, height: 24)
                        }
                    }
                    .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(color.displayName)
                .accessibilityLabel(color.displayName)
            }
        }
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
        if controller.pendingCommentPoint != nil { return "指し示す位置に付ける吹き出しの文を入力してください。" }
        if controller.selectedAnnotation?.kind == .comment { return "選択した吹き出しのコメントを書き換えられます。" }
        return "「コメント」を選び、画像上をクリックして吹き出しを置きます。"
    }

    private var toolHelp: String {
        switch controller.tool {
        case .comment: return "画像上をクリックして吹き出しコメントを置きます。"
        case .rectangle: return "囲みたい範囲の対角線をドラッグします。"
        case .freehand: return "画像の上をドラッグして手書きで囲みます。"
        case .number: return "画像上をクリックして番号を置きます。"
        case nil: return "注釈をクリックして選び、ドラッグで移動します。吹き出しの先端も動かせます。"
        }
    }

    private func kindTitle(_ kind: CaptureAnnotation.Kind) -> String {
        switch kind {
        case .comment: return "吹き出しコメント"
        case .rectangle: return "四角囲み"
        case .freehand: return "手書き囲み"
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
        updateCanvasLayout()
    }

    override func tile() {
        super.tile()
        updateCanvasLayout()
    }

    override func reflectScrolledClipView(_ cView: NSClipView) {
        super.reflectScrolledClipView(cView)
        updateCanvasLayout()
    }

    private func updateCanvasLayout() {
        guard let canvas = documentView as? AnnotationCanvasView else { return }
        let size = contentView.bounds.size
        if size.width > 0 && size.height > 0 {
            canvas.viewportSize = size
            canvas.resizeCanvas()
        }
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
    private var movingTail = false
    private var freehandPoints: [CGPoint] = []

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
            if selected.kind == .comment {
                let tail = pixelPoint(selected.start, size: imageSize)
                context.setLineDash(phase: 0, lengths: [])
                context.setFillColor(NSColor.white.cgColor)
                context.fillEllipse(in: CGRect(x: tail.x - 6 / zoom, y: tail.y - 6 / zoom, width: 12 / zoom, height: 12 / zoom))
                context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                context.setLineWidth(2 / zoom)
                context.strokeEllipse(in: CGRect(x: tail.x - 6 / zoom, y: tail.y - 6 / zoom, width: 12 / zoom, height: 12 / zoom))
            }
        }
        if let point = controller.pendingCommentPoint {
            let point = pixelPoint(point, size: imageSize)
            context.setLineDash(phase: 0, lengths: [])
            context.strokeEllipse(in: CGRect(x: point.x - 5 / zoom, y: point.y - 5 / zoom,
                                             width: 10 / zoom, height: 10 / zoom))
        }
        if gestureTool == .freehand, freehandPoints.count >= 2 {
            context.setLineDash(phase: 0, lengths: [])
            let path = CGMutablePath()
            let first = pixelPoint(freehandPoints[0], size: imageSize)
            path.move(to: first)
            for pt in freehandPoints.dropFirst() {
                path.addLine(to: pixelPoint(pt, size: imageSize))
            }
            context.addPath(path)
            context.setStrokeColor(controller.selectedColor.contrastColor)
            context.setLineWidth(4 / zoom)
            context.strokePath()
            context.addPath(path)
            context.setStrokeColor(controller.selectedColor.cgColor)
            context.setLineWidth(2 / zoom)
            context.strokePath()
        }
        guard let start = gestureStart, let end = gestureEnd else { return }
        let a = pixelPoint(start, size: imageSize), b = pixelPoint(end, size: imageSize)
        if gestureTool == .rectangle {
            context.setLineDash(phase: 0, lengths: [4 / zoom, 2 / zoom])
            context.setStrokeColor(controller.selectedColor.cgColor)
            context.stroke(CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                  width: abs(b.x - a.x), height: abs(b.y - a.y)))
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
            if let selected = controller.selectedAnnotation, selected.kind == .comment, let imageSize {
                let tailPixel = pixelPoint(selected.start, size: imageSize)
                let clickPixel = pixelPoint(point, size: imageSize)
                let dist = hypot((clickPixel.x - tailPixel.x) * zoom, (clickPixel.y - tailPixel.y) * zoom)
                if dist <= 14 {
                    movingTail = true
                    controller.beginMove()
                    needsDisplay = true
                    return
                }
            }
            controller.select(at: point)
            if let selected = controller.selectedAnnotation, selected.kind == .comment, let imageSize {
                let tailPixel = pixelPoint(selected.start, size: imageSize)
                let clickPixel = pixelPoint(point, size: imageSize)
                let dist = hypot((clickPixel.x - tailPixel.x) * zoom, (clickPixel.y - tailPixel.y) * zoom)
                if dist <= 14 {
                    movingTail = true
                    controller.beginMove()
                    needsDisplay = true
                    return
                }
            }
            controller.beginMove()
            moving = true
        } else if controller.tool == .freehand {
            freehandPoints = [point]
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller, controller.isOpen, !controller.isWorking,
              gestureStart != nil, let point = normalizedPoint(event, clamped: true) else { return }
        if movingTail, let previousPoint {
            controller.moveSelectedTail(by: CGPoint(x: point.x - previousPoint.x, y: point.y - previousPoint.y))
        } else if moving, let previousPoint {
            controller.moveSelected(by: CGPoint(x: point.x - previousPoint.x, y: point.y - previousPoint.y))
        } else if gestureTool == .freehand {
            freehandPoints.append(point)
        }
        previousPoint = point
        gestureEnd = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller, controller.isOpen, !controller.isWorking else {
            finishGesture()
            return
        }
        if movingTail {
            controller.endMove()
            movingTail = false
        } else if !moving, gestureTool == .freehand {
            if freehandPoints.count >= 2 {
                controller.addFreehand(points: freehandPoints)
            }
            freehandPoints.removeAll()
        } else if !moving, let start = gestureStart, controller.tool == gestureTool,
                  let end = normalizedPoint(event, clamped: true) {
            controller.gesture(from: start, to: end)
        }
        finishGesture()
    }

    func finishGesture() {
        if moving || movingTail { controller?.endMove() }
        moving = false
        movingTail = false
        gestureStart = nil
        gestureEnd = nil
        previousPoint = nil
        gestureTool = nil
        freehandPoints.removeAll()
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
