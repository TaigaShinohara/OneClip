import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class CaptureAnnotationController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = CaptureAnnotationController()
    @Published private(set) var image: M0ImageAsset?
    @Published private(set) var annotations: [CaptureAnnotation] = []
    @Published var tool: CaptureAnnotation.Kind? = .comment
    @Published private(set) var selectedID: UUID?
    @Published var commentDraft = ""
    @Published private(set) var pendingCommentPoint: CGPoint?
    @Published private(set) var isWorking = false
    @Published private(set) var isOpen = false
    @Published private(set) var statusText = ""

    var canOpen: @MainActor () -> Bool = { true }
    var externalRetainedBytes: @MainActor () -> Int = { 0 }
    var blocksCapture: Bool { isOpen || isWorking }
    var selectedAnnotation: CaptureAnnotation? { annotations.first { $0.id == selectedID } }
    var hasDraftChanges: Bool {
        if pendingCommentPoint != nil { return !commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return selectedAnnotation?.kind == .comment && commentDraft != selectedAnnotation?.text
    }
    var canUndo: Bool { !isWorking && !hasDraftChanges && !undoStack.isEmpty }
    var canRedo: Bool { !isWorking && !hasDraftChanges && !redoStack.isEmpty }
    var canExport: Bool {
        isOpen && image != nil && !isWorking
            && !results.isSaving && !results.hasPendingSave
    }
    var isDirty: Bool { annotations != savedAnnotations || hasDraftChanges }

    private let results: CaptureResultController
    private let clipboard: any CaptureClipboardWriting
    private let environmentCheck: @MainActor () -> Bool
    private let showsWindow: Bool
    private var window: NSWindow?
    private var worker: Task<Void, Never>?
    private var operationID = UUID()
    private var contentID = UUID()
    private var undoStack: [[CaptureAnnotation]] = []
    private var redoStack: [[CaptureAnnotation]] = []
    private var savedAnnotations: [CaptureAnnotation] = []
    private var moveStart: [CaptureAnnotation]?
    private var resultSubscription: AnyCancellable?

    init(results: CaptureResultController = .shared,
         clipboard: any CaptureClipboardWriting = GeneralCaptureClipboard(),
         showsWindow: Bool = true,
         environmentCheck: @escaping @MainActor () -> Bool = { NativeCaptureInterface.shared.validateCaptureEnvironment() }) {
        self.results = results
        self.clipboard = clipboard
        self.showsWindow = showsWindow
        self.environmentCheck = environmentCheck
        super.init()
        resultSubscription = results.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }

    func show() {
        guard isOpen else { return }
        guard environmentCheck() else { invalidate(); return }
        showWindow()
    }

    @discardableResult func open(_ url: URL) -> Bool {
        if isOpen {
            guard environmentCheck() else { invalidate(); return false }
            showWindow(); return true
        }
        guard !isWorking, !results.isSaving, !results.hasPendingSave, canOpen(), environmentCheck() else {
            statusText = "撮影中または未解決の画像があります。先に処理を終えてください。"
            return false
        }
        operationID = UUID()
        contentID = UUID()
        let identifier = operationID
        let extra = externalRetainedBytes()
        isOpen = true
        isWorking = true
        statusText = "画像を開いています…"
        showWindow()
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil; self.isWorking = false }
            do {
                let loading = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let asset = try CaptureAnnotationRenderer.load(from: url, retainingExtraBytes: extra)
                    try Task.checkCancellation()
                    return asset
                }
                let asset = try await withTaskCancellationHandler(operation: { try await loading.value }, onCancel: { loading.cancel() })
                guard self.isCurrent(identifier) else { return }
                _ = try CaptureAnnotationRenderer.makePlan(image: asset.image, annotations: [], retainingExtraBytes: self.externalRetainedBytes())
                self.image = asset
                self.statusText = "画像上で位置を選び、コメントを書いてください。矢印・囲み・番号も追加できます。"
            } catch {
                guard self.operationID == identifier, self.isOpen else { return }
                self.statusText = "画像を開けませんでした。\(error.localizedDescription)"
            }
        }
        return true
    }

    func gesture(from start: CGPoint, to end: CGPoint) {
        guard editable(), let tool else { return }
        guard finishDraft() else { return }
        if tool == .comment {
            selectedID = nil
            pendingCommentPoint = clamped(start)
            commentDraft = ""
            statusText = "右の欄へAIへの指示を書き、「コメントを適用」を押してください。"
            return
        }
        if tool == .arrow || tool == .rectangle {
            guard abs(start.x - end.x) + abs(start.y - end.y) > 0.005 else {
                statusText = "画像の上をドラッグして記号を描いてください。"; return
            }
        }
        let number = (annotations.filter { $0.kind == .number }.map(\.number).max() ?? 0) + 1
        var note = CaptureAnnotation(kind: tool, start: clamped(start), end: clamped(end), number: number)
        do {
            note = try canonicalized(note)
            try commit(annotations + [note])
            selectID(note.id)
        } catch { statusText = error.localizedDescription }
    }

    func applyComment() { _ = finishDraft() }
    func cancelComment() {
        pendingCommentPoint = nil
        commentDraft = selectedAnnotation?.kind == .comment ? selectedAnnotation?.text ?? "" : ""
    }

    private func finishDraft() -> Bool {
        guard editable() else { return false }
        let text = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pendingCommentPoint != nil || hasDraftChanges else { return true }
        guard !text.isEmpty else {
            if pendingCommentPoint != nil { pendingCommentPoint = nil; commentDraft = ""; return true }
            statusText = "コメントを空にする場合は「削除」を使ってください。"; return false
        }
        do {
            if let point = pendingCommentPoint {
                var note = CaptureAnnotation(kind: .comment, start: point, end: point, text: text)
                note = try canonicalized(note)
                try commit(annotations + [note])
                pendingCommentPoint = nil
                selectID(note.id)
            } else if let index = annotations.firstIndex(where: { $0.id == selectedID && $0.kind == .comment }) {
                var next = annotations
                next[index].text = text
                next[index] = try canonicalized(next[index])
                try commit(next)
                commentDraft = next[index].text
            }
            statusText = "コメントを追加しました。必要な記号を加えて「保存してコピー」できます。"
            return true
        } catch { statusText = error.localizedDescription; return false }
    }

    func select(at point: CGPoint) {
        guard editable(), finishDraft(), let image else { return }
        let size = CGSize(width: image.image.width, height: image.image.height)
        let pixel = CGPoint(x: point.x * size.width, y: point.y * size.height)
        let note = annotations.reversed().first {
            ((try? CaptureAnnotationRenderer.bounds(for: $0, imageSize: size))?.insetBy(dx: -6, dy: -6).contains(pixel)) == true
        }
        selectID(note?.id)
    }

    func beginMove() { if editable() { moveStart = annotations } }
    func moveSelected(by delta: CGPoint) {
        guard editable(), let image, let index = annotations.firstIndex(where: { $0.id == selectedID }),
              delta.x.isFinite, delta.y.isFinite else { return }
        do {
            let size = CGSize(width: image.image.width, height: image.image.height)
            let bounds = try CaptureAnnotationRenderer.bounds(for: annotations[index], imageSize: size)
            let dx = min(max(delta.x, -bounds.minX / size.width), (size.width - bounds.maxX) / size.width)
            let dy = min(max(delta.y, -bounds.minY / size.height), (size.height - bounds.maxY) / size.height)
            var next = annotations
            next[index].start.x += dx; next[index].end.x += dx
            next[index].start.y += dy; next[index].end.y += dy
            next[index] = try canonicalized(next[index])
            try validate(next)
            annotations = next
        } catch { statusText = error.localizedDescription }
    }
    func endMove() {
        defer { moveStart = nil }
        guard let before = moveStart, before != annotations else { return }
        appendUndo(before)
        redoStack.removeAll()
        contentID = UUID()
    }

    func deleteSelected() {
        guard editable(), selectedID != nil else { return }
        do {
            try commit(annotations.filter { $0.id != selectedID })
            selectID(nil)
        } catch { statusText = error.localizedDescription }
    }
    func undo() {
        guard editable(), canUndo, let previous = undoStack.popLast() else { return }
        redoStack.append(annotations); annotations = previous; contentID = UUID(); selectID(nil)
    }
    func redo() {
        guard editable(), canRedo, let next = redoStack.popLast() else { return }
        appendUndo(annotations); annotations = next; contentID = UUID(); selectID(nil)
    }

    func saveAndCopy() {
        guard canExport else { return }
        if showsWindow, let text = window?.firstResponder as? NSTextView, text.hasMarkedText() {
            statusText = "日本語の変換を確定してから「保存してコピー」を押してください。"; return
        }
        guard finishDraft(), let image, editable() else { return }
        let identifier = operationID
        let exportID = contentID
        let notes = annotations
        let extra = externalRetainedBytes()
        let expectedCount = clipboard.changeCount
        isWorking = true
        statusText = "コメント・記号を画像にまとめています…"
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil; self.isWorking = false }
            do {
                let rendering = Task.detached(priority: .userInitiated) {
                    try CaptureAnnotationRenderer.render(image: image.image, annotations: notes, retainingExtraBytes: extra)
                }
                let output = try await withTaskCancellationHandler(operation: { try await rendering.value }, onCancel: { rendering.cancel() })
                guard self.isCurrent(identifier) else { return }
                // Keep the existing conflict checks and use exactly one flattened PNG.
                let copied = self.clipboard.writePNG(output.pngData, expectedChangeCount: expectedCount)
                self.results.receive(output.pngData, copied: copied.writeAccepted, id: exportID, mode: .annotation)
                while self.results.isSaving {
                    try await Task.sleep(for: .milliseconds(5))
                    guard self.operationID == identifier, self.isOpen else { return }
                }
                guard self.isCurrent(identifier) else { return }
                let saved = !self.results.hasPendingSave && self.results.savedURL(for: exportID, mode: .annotation) != nil
                if saved { self.savedAnnotations = notes }
                switch (copied.writeAccepted, saved) {
                case (true, true): self.statusText = "注釈入り画像を保存・コピーしました。AIの入力欄に貼り付けられます。"
                case (true, false): self.statusText = "コピーしました。保存に失敗しています。メニューから保存を再試行できます。"
                case (false, true): self.statusText = "画像は保存しました。コピーできませんでした。「保存してコピー」で再試行できます。"
                case (false, false): self.statusText = "保存・コピーができませんでした。注釈を保持しています。保存の再試行か破棄をメニューから選べます。"
                }
            } catch {
                guard self.operationID == identifier, self.isOpen else { return }
                self.statusText = "画像を準備できませんでした。\(error.localizedDescription)"
            }
        }
    }

    @discardableResult func requestClose() -> Bool {
        guard !isWorking else { statusText = "処理が終わるまでお待ちください。"; return false }
        if isDirty {
            guard showsWindow else { return false }
            let alert = NSAlert()
            alert.messageText = "未出力のコメント・記号を破棄して閉じますか？"
            alert.informativeText = "撮影原本と、既に保存・コピーした画像は残ります。"
            alert.addButton(withTitle: "編集に戻る")
            alert.addButton(withTitle: "破棄して閉じる")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
        }
        invalidate()
        return true
    }

    func invalidate() {
        operationID = UUID()
        worker?.cancel()
        image = nil; annotations = []; savedAnnotations = []
        undoStack.removeAll(); redoStack.removeAll(); moveStart = nil
        selectedID = nil; pendingCommentPoint = nil; commentDraft = ""
        isOpen = false
        window?.orderOut(nil)
        window?.contentView = nil
    }
    func waitForWorker() async { await worker?.value }

    private func editable() -> Bool {
        guard isOpen, !isWorking, image != nil else { return false }
        guard environmentCheck() else { invalidate(); return false }
        return true
    }
    private func isCurrent(_ identifier: UUID) -> Bool {
        guard operationID == identifier, isOpen, !Task.isCancelled else { return false }
        guard environmentCheck() else { invalidate(); return false }
        return true
    }
    private func clamped(_ p: CGPoint) -> CGPoint { CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1)) }
    private func canonicalized(_ note: CaptureAnnotation) throws -> CaptureAnnotation {
        guard let image else { return note }
        var note = note
        let size = CGSize(width: image.image.width, height: image.image.height)
        let bounds = try CaptureAnnotationRenderer.bounds(for: note, imageSize: size)
        if note.kind == .comment { note.start = CGPoint(x: bounds.minX / size.width, y: bounds.minY / size.height) }
        if note.kind == .number { note.start = CGPoint(x: bounds.midX / size.width, y: bounds.midY / size.height) }
        return note
    }
    private func validate(_ next: [CaptureAnnotation]) throws {
        guard let image else { return }
        _ = try CaptureAnnotationRenderer.makePlan(image: image.image, annotations: next, retainingExtraBytes: externalRetainedBytes())
    }
    private func commit(_ next: [CaptureAnnotation]) throws {
        try validate(next)
        guard next != annotations else { return }
        appendUndo(annotations); redoStack.removeAll(); annotations = next; contentID = UUID()
    }
    private func appendUndo(_ previous: [CaptureAnnotation]) {
        undoStack.append(previous)
        if undoStack.count > 100 { undoStack.removeFirst(undoStack.count - 100) }
    }
    private func selectID(_ id: UUID?) {
        selectedID = id; pendingCommentPoint = nil
        commentDraft = selectedAnnotation?.kind == .comment ? selectedAnnotation?.text ?? "" : ""
    }
    private func showWindow() {
        guard showsWindow else { return }
        if window == nil {
            let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            value.title = "OneClip — 画像にコメント・記号を追加"
            value.minSize = NSSize(width: 740, height: 480)
            value.isReleasedWhenClosed = false
            value.isRestorable = false
            value.delegate = self
            value.center()
            window = value
        }
        if window?.contentView == nil {
            window?.contentView = NSHostingView(rootView: CaptureAnnotationEditorView(controller: self))
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { _ = requestClose(); return false }
}
