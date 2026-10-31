import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
private final class AnnotationImageBorrow {
    weak var image: CGImage?
    init(_ image: CGImage) { self.image = image }
}

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
    var externalRetainedBytes: @MainActor () throws -> Int = { 0 }
    var blocksCapture: Bool { isOpen || isWorking }
    let securityTrace: CaptureSecurityTrace
    private let limits: M0ImageLimits
    private let loader: @Sendable (URL, M0ImageLimits, Int) throws -> M0ImageAsset
    private let renderer: @Sendable (M0ImageAsset, [CaptureAnnotation], M0ImageLimits, Int) throws -> M0CompositionResult
    private var workerImageBytes = 0
    private var retiredImages: [AnnotationImageBorrow] = []
    private var retiredImageBytes: Int {
        (try? CaptureRetainedImageBudget.images(retiredImages.compactMap(\.image))) ?? Int.max
    }
    var retainedImageBytes: Int {
        do {
            let current = try image.map { try Self.ownerBytes($0) } ?? 0
            return try CaptureRetainedImageBudget.sum(retiredImageBytes, max(current, workerImageBytes))
        } catch { return Int.max }
    }
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
         environmentCheck: @escaping @MainActor () -> Bool = { NativeCaptureInterface.shared.validateCaptureEnvironment() },
         securityTrace: CaptureSecurityTrace = .disabled, limits: M0ImageLimits = .init(),
         loader: (@Sendable (URL, M0ImageLimits, Int) throws -> M0ImageAsset)? = nil,
         renderer: (@Sendable (M0ImageAsset, [CaptureAnnotation], M0ImageLimits, Int) throws -> M0CompositionResult)? = nil) {
        self.results = results
        self.clipboard = clipboard
        self.showsWindow = showsWindow
        self.environmentCheck = environmentCheck
        self.securityTrace = securityTrace
        self.limits = limits
        self.loader = loader ?? { try CaptureAnnotationRenderer.load(from: $0, limits: $1, retainingExtraBytes: $2) }
        self.renderer = renderer ?? { try CaptureAnnotationRenderer.render(image: $0.image, annotations: $1, limits: $2, retainingExtraBytes: $3) }
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
        let extra: Int
        do {
            extra = try additionalRetainedBytes()
            guard limits.maximumImageBytes > 0, extra < limits.maximumImageBytes else { throw M0ImageError.memoryLimit }
            // The PNG's dimensions/stride are not known before the safe metadata read. Reserve
            // the available finite capacity; the loader checks each allocation against it.
            workerImageBytes = limits.maximumImageBytes - extra
        } catch {
            statusText = "画像を開く作業領域を確保できませんでした。ほかの処理が終わってから再試行してください。"
            return false
        }
        let loadingOperation = loader
        let workerLimits = limits
        let trace = securityTrace
        trace.record(.annotationOpened, mode: .annotation, phase: .capturing)
        isOpen = true
        isWorking = true
        statusText = "画像を開いています…"
        showWindow()
        worker = Task { [weak self] in
            guard let self else { return }
            trace.record(.workerStarted, mode: .annotation, phase: .capturing)
            defer { self.finishWorker(phase: .capturing) }
            do {
                guard self.isCurrent(identifier) else { return }
                let loading = Task.detached(priority: .userInitiated) {
                    do {
                        try Task.checkCancellation()
                        let asset = try loadingOperation(url, workerLimits, extra)
                        try Task.checkCancellation()
                        trace.record(.annotationLoaded, mode: .annotation, phase: .capturing, outcome: .success)
                        return asset
                    } catch {
                        trace.record(.annotationLoaded, mode: .annotation, phase: .capturing, outcome: .failure)
                        throw error
                    }
                }
                let asset = try await withTaskCancellationHandler(operation: { try await loading.value }, onCancel: { loading.cancel() })
                self.workerImageBytes = (try? Self.ownerBytes(asset)) ?? Int.max
                guard self.isCurrent(identifier) else { return }
                _ = try CaptureAnnotationRenderer.makePlan(image: asset.image, annotations: [], limits: self.limits,
                    retainingExtraBytes: self.additionalRetainedBytes())
                self.image = asset
                trace.record(.annotationResultAdopted, mode: .annotation, phase: .capturing)
                self.statusText = "画像上で位置を選び、コメントを書いてください。矢印・囲み・番号も追加できます。"
            } catch {
                guard self.operationID == identifier, self.isOpen else { return }
                self.statusText = "画像を開けませんでした。" + Self.failureText(error)
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
        } catch { statusText = Self.failureText(error) }
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
        } catch { statusText = Self.failureText(error); return false }
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
        } catch { statusText = Self.failureText(error) }
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
        } catch { statusText = Self.failureText(error) }
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
        let extra: Int
        do {
            extra = try additionalRetainedBytes()
            let plan = try CaptureAnnotationRenderer.makePlan(image: image.image, annotations: notes,
                limits: limits, retainingExtraBytes: extra)
            workerImageBytes = plan.estimatedPeakBytes - extra
        } catch { statusText = "画像を準備できませんでした。" + Self.failureText(error); return }
        let renderingOperation = renderer
        let workerLimits = limits
        let trace = securityTrace
        let expectedCount = clipboard.changeCount
        isWorking = true
        statusText = "コメント・記号を画像にまとめています…"
        worker = Task { [weak self] in
            guard let self else { return }
            trace.record(.workerStarted, mode: .annotation, phase: .encoding)
            defer { self.finishWorker(phase: .encoding) }
            do {
                guard self.isCurrent(identifier) else { return }
                let rendering = Task.detached(priority: .userInitiated) {
                    trace.record(.annotationExportStarted, mode: .annotation, phase: .encoding)
                    do {
                        try Task.checkCancellation()
                        let output = try renderingOperation(image, notes, workerLimits, extra)
                        try Task.checkCancellation()
                        trace.record(.annotationExportReturned, mode: .annotation, phase: .encoding, outcome: .success)
                        return output
                    } catch {
                        trace.record(.annotationExportReturned, mode: .annotation, phase: .encoding, outcome: .failure)
                        throw error
                    }
                }
                let output = try await withTaskCancellationHandler(operation: { try await rendering.value }, onCancel: { rendering.cancel() })
                self.workerImageBytes = (try? Self.ownerBytes(image, output: output)) ?? Int.max
                guard self.isCurrent(identifier) else { return }
                let freshExtra = try self.additionalRetainedBytes()
                let plan = try CaptureAnnotationRenderer.makePlan(image: image.image, annotations: notes, limits: self.limits,
                    retainingExtraBytes: freshExtra)
                guard output.image.width == image.image.width, output.image.height == image.image.height,
                      output.image.bitsPerComponent == 8, output.image.bitsPerPixel == 32,
                      output.image.bytesPerRow >= output.image.width * 4,
                      try CaptureRetainedImageBudget.sum(self.workerImageBytes, freshExtra) <= self.limits.maximumImageBytes else {
                    throw M0ImageError.memoryLimit
                }
                _ = try M0ImageComposer.validateEncodedBytes(plan: plan, pngByteCount: output.pngData.count,
                    isSingleImage: true, limits: self.limits)
                trace.record(.annotationResultAdopted, mode: .annotation, phase: .encoding)
                // Keep the existing conflict checks and use exactly one flattened PNG.
                let copied = self.clipboard.writePNG(output.pngData, expectedChangeCount: expectedCount,
                    securityTrace: trace, mode: .annotation)
                trace.record(.clipboardOutcome, mode: .annotation, phase: .writing, outcome: copied.writeAccepted ? .accepted : .rejected)
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
                self.statusText = "画像を準備できませんでした。" + Self.failureText(error)
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
        securityTrace.record(.annotationInvalidated, mode: .annotation, outcome: .cancelled)
        operationID = UUID()
        worker?.cancel()
        retiredImages.removeAll { $0.image == nil }
        if let image = image?.image, !retiredImages.contains(where: { $0.image === image }) { retiredImages.append(AnnotationImageBorrow(image)) }
        image = nil; annotations = []; savedAnnotations = []
        undoStack.removeAll(); redoStack.removeAll(); moveStart = nil
        selectedID = nil; pendingCommentPoint = nil; commentDraft = ""
        isOpen = false
        let wasVisible = window?.isVisible == true
        window?.orderOut(nil)
        window?.contentView = nil
        if wasVisible { securityTrace.record(.annotationViewHidden, mode: .annotation) }
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
        _ = try CaptureAnnotationRenderer.makePlan(image: image.image, annotations: next, limits: limits,
            retainingExtraBytes: additionalRetainedBytes())
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
        if window?.isVisible == true { securityTrace.record(.annotationViewShown, mode: .annotation) }
        NSApp.activate(ignoringOtherApps: true)
    }
    /// Called only after the real canvas painted its current image; never by headless probes.
    func recordImageDraw() {
        if isOpen, image != nil { securityTrace.record(.annotationViewDraw, mode: .annotation) }
    }
    private func additionalRetainedBytes() throws -> Int {
        try CaptureRetainedImageBudget.sum(retiredImageBytes, externalRetainedBytes())
    }
    private static func ownerBytes(_ image: M0ImageAsset, output: M0CompositionResult? = nil) throws -> Int {
        let preview = min(image.image.width, 1_024) * min(image.image.height, 1_024) * 4
        return try CaptureRetainedImageBudget.sum(CaptureRetainedImageBudget.images(
            [image.image] + (output.map { [$0.image] } ?? [])), output?.pngData.count ?? 0, preview)
    }
    private func finishWorker(phase: CaptureSecurityTrace.Phase) {
        securityTrace.record(.workerReturned, mode: .annotation, phase: phase)
        workerImageBytes = 0; worker = nil; isWorking = false
    }
    private static func failureText(_ error: any Error) -> String {
        if let known = error as? CaptureAnnotationError { return known.errorDescription ?? "画像の内容を確認してください。" }
        if let known = error as? M0ImageError { return known.errorDescription ?? "画像の上限を確認してください。" }
        return "画像の形式、保存先と空き容量を確認してください。"
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { _ = requestClose(); return false }
}
