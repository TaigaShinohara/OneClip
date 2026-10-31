import AppKit
import Combine
import ImageIO
import SwiftUI

enum CaptureResultMode: Hashable { case single, collection, annotation }

/// A detached worker publishes only an independent, immutable bitmap, never an ImageIO source.
private struct ResultThumbnailBitmap: @unchecked Sendable {
    let image: CGImage
    let bytes: Int
}

@MainActor
private final class ResultThumbnail {
    let image: NSImage
    let bytes: Int
    init(_ bitmap: ResultThumbnailBitmap) {
        image = NSImage(cgImage: bitmap.image, size: NSSize(width: bitmap.image.width, height: bitmap.image.height))
        bytes = bitmap.bytes
    }
}

@MainActor
private final class ResultThumbnailBorrow {
    weak var thumbnail: ResultThumbnail?
    init(_ thumbnail: ResultThumbnail) { self.thumbnail = thumbnail }
}

private struct ResultSaveOutput: Sendable {
    let url: URL?
    let thumbnail: ResultThumbnailBitmap?
    let reused: Bool
}

/// A single pending PNG is owned until its worker finishes or a failed save is resolved.
/// The thumbnail owns only a downsampled image; saved images are represented by URLs.
@MainActor
final class CaptureResultController: ObservableObject {
    /// Internal test dependencies only. Normal initialization always uses the fixed trusted
    /// Preview resolver and Launch Services; no preference or launch argument selects a backend.
    struct PreviewServices: Sendable {
        typealias Completion = @MainActor @Sendable (Bool) -> Void
        let resolveApplication: @Sendable () -> URL?
        let launch: @MainActor @Sendable (URL, URL, @escaping Completion) -> Void
        let errorPresenter: (@MainActor @Sendable () -> Void)?

        static var live: PreviewServices {
            PreviewServices(resolveApplication: { TrustedPreviewApplication.verifiedURL() },
                launch: { target, application, completion in
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    NSWorkspace.shared.open([target], withApplicationAt: application, configuration: configuration) { _, error in
                        let failed = error != nil
                        // Only a fixed success/failure crosses back from the OS callback.
                        Task { @MainActor in completion(failed) }
                    }
                }, errorPresenter: nil)
        }
    }

    static let shared = CaptureResultController()

    @Published private(set) var latestURL: URL?
    @Published private(set) var hasPendingSave = false
    @Published private(set) var isSaving = false
    @Published private(set) var message = ""
    var isPreviewVisible: Bool { panel?.isVisible == true }
    private let archive: CaptureArchive
    private let previewsEnabled: Bool
    private let limits: M0ImageLimits
    private let save: @Sendable (Data) throws -> URL
    private let opener: (@MainActor (URL) -> Void)?
    private let previewServices: PreviewServices
    let securityTrace: CaptureSecurityTrace
    var externalRetainedBytes: @MainActor () throws -> Int = { 0 }
    nonisolated static let maximumThumbnailDimension = 480
    nonisolated static let maximumThumbnailBitmapBytes = 480 * 480 * 4
    // Decoder bitmap, drawing context and makeImage output may all own distinct stores.
    nonisolated static let thumbnailWorkspaceReserveBytes = 3 * 480 * 480 * 4
    nonisolated static let editWorkspaceReserveBytes = 65_536
    private(set) var saveWorkerPNGBytes = 0
    private(set) var workerThumbnailReserveBytes = 0
    private(set) var editWorkerReserveBytes = 0
    private var pendingPNG: Data?
    private var copied = false
    private var thumbnail: ResultThumbnail?
    private var retiredThumbnails: [ResultThumbnailBorrow] = []
    var thumbnailHeldBytes: Int { thumbnail?.bytes ?? 0 }
    var retiredThumbnailBytes: Int {
        retiredThumbnails.reduce(0) { Self.saturatingSum($0, $1.thumbnail?.bytes ?? 0) }
    }
    /// Conservative owner estimate, including PNG aliases and UI borrows until actual release.
    /// Two worker PNG stores cover the immutable input and an ImageIO/CFData bridge reserve.
    var retainedImageBytes: Int {
        [pendingPNG?.count ?? 0, saveWorkerPNGBytes, workerThumbnailReserveBytes, editWorkerReserveBytes,
         thumbnailHeldBytes, retiredThumbnailBytes].reduce(0, Self.saturatingSum)
    }
    private var editingURL: URL?
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?
    private var revision = UUID()
    private var recordID = UUID()
    private var captureID = UUID()
    private var mode = CaptureResultMode.single
    private var previewDismissed = false
    private struct SavedResult: Sendable {
        let id: UUID
        let url: URL
        var editingURL: URL?
    }
    // At most one URL record per capture mode, never an image history.
    private var savedResults: [CaptureResultMode: SavedResult] = [:]
    private var pendingExistingResult: SavedResult?
    private var traceMode: CaptureSecurityTrace.Mode {
        switch mode { case .single: return .single; case .collection: return .collection; case .annotation: return .annotation }
    }

    init(archive: CaptureArchive = CaptureArchive(), previewsEnabled: Bool = true,
         securityTrace: CaptureSecurityTrace = .disabled, limits: M0ImageLimits = .init(),
         saver: (@Sendable (Data) throws -> URL)? = nil,
         opener: (@MainActor (URL) -> Void)? = nil,
         previewServices: PreviewServices = .live) {
        self.archive = archive
        self.previewsEnabled = previewsEnabled
        self.securityTrace = securityTrace
        self.limits = limits
        self.opener = opener
        self.previewServices = previewServices
        save = saver ?? { try archive.save($0) }
    }

    private static func saturatingSum(_ left: Int, _ right: Int) -> Int {
        guard left >= 0, right >= 0 else { return Int.max }
        let result = left.addingReportingOverflow(right)
        return result.overflow ? Int.max : result.partialValue
    }

    private func retireThumbnail() {
        retiredThumbnails.removeAll { $0.thumbnail == nil }
        if let thumbnail, !retiredThumbnails.contains(where: { $0.thumbnail === thumbnail }) {
            retiredThumbnails.append(ResultThumbnailBorrow(thumbnail))
        }
        thumbnail = nil
    }

    func receive(_ png: Data, copied: Bool, id: UUID = UUID(), mode: CaptureResultMode = .single) {
        let incomingMode: CaptureSecurityTrace.Mode
        switch mode { case .single: incomingMode = .single; case .collection: incomingMode = .collection; case .annotation: incomingMode = .annotation }
        guard !isSaving, !hasPendingSave else {
            securityTrace.record(.resultReceived, mode: incomingMode, outcome: .rejected)
            return
        }
        securityTrace.record(.resultReceived, mode: incomingMode, outcome: .accepted)
        recordID = UUID()
        captureID = id
        self.mode = mode
        dismissPreview()
        previewDismissed = false
        self.copied = copied
        pendingExistingResult = savedResults[mode].flatMap { $0.id == id ? $0 : nil }
        // A previously saved path is only a candidate until the worker verifies its current
        // owned regular file and exact PNG bytes. Never claim success from fileExists alone.
        latestURL = nil
        editingURL = nil
        // Data is an immutable alias of the already produced PNG; this handoff does not copy it.
        pendingPNG = png
        hasPendingSave = true
        retrySave()
    }

    func retrySave() {
        guard let png = pendingPNG, !isSaving else { return }
        let workerBytes = png.count.multipliedReportingOverflow(by: 2)
        let total: Int
        do {
            let external = try externalRetainedBytes()
            guard external >= 0, !workerBytes.overflow else { throw M0ImageError.memoryLimit }
            total = try CaptureRetainedImageBudget.sum(retainedImageBytes, workerBytes.partialValue,
                     Self.thumbnailWorkspaceReserveBytes, external)
            guard limits.maximumImageBytes > 0, total <= limits.maximumImageBytes else { throw M0ImageError.memoryLimit }
        } catch {
            message = copied
                ? "コピーしました。保存の作業領域を確保できませんでした。ほかの処理が終わってから再試行してください"
                : "コピーできませんでした。保存の作業領域を確保できませんでした。ほかの処理が終わってから再試行してください"
            securityTrace.record(.archiveOutcome, mode: traceMode, phase: .writing, outcome: .rejected)
            showPreview()
            return
        }
        let identifier = recordID
        let existing = pendingExistingResult
        let workerSave = save
        let workerArchive = archive
        let trace = securityTrace
        let workerMode = traceMode
        previewDismissed = false
        saveWorkerPNGBytes = workerBytes.partialValue
        workerThumbnailReserveBytes = Self.thumbnailWorkspaceReserveBytes
        isSaving = true
        message = copied ? "コピーしました。保存中…" : "コピーできませんでした。保存中…"
        trace.record(.archiveQueued, mode: workerMode, phase: .writing)
        showPreview()
        Task { @MainActor [weak self] in
            let output = await Task.detached(priority: .userInitiated) {
                trace.record(.archiveStarted, mode: workerMode, phase: .writing)
                let output = autoreleasepool {
                    let url: URL?
                    let reused: Bool
                    if let existing, (try? workerArchive.matchesSavedCapture(existing.url, png: png)) == true {
                        url = existing.url
                        reused = true
                    } else {
                        url = try? workerSave(png)
                        reused = false
                    }
                    return ResultSaveOutput(url: url, thumbnail: Self.makeThumbnailBitmap(png), reused: reused)
                }
                // The input and ImageIO temporaries are no longer used after this actual worker return.
                trace.record(.archiveReturned, mode: workerMode, phase: .writing,
                             outcome: output.url == nil ? .failure : (output.reused ? .unchanged : .success))
                return output
            }.value
            guard let self else { return }
            var reservationsHeld = true
            defer {
                // Invalidation may have dropped pendingPNG much earlier; keep these reservations
                // until the real detached worker has returned and its output has been handled.
                if reservationsHeld {
                    self.saveWorkerPNGBytes = 0
                    self.workerThumbnailReserveBytes = 0
                    self.isSaving = false
                }
            }
            guard self.recordID == identifier else {
                trace.record(.archiveOutcome, mode: workerMode, phase: .writing, outcome: .stale)
                return
            }
            if !self.previewDismissed, let bitmap = output.thumbnail {
                self.retireThumbnail()
                self.thumbnail = ResultThumbnail(bitmap)
            }
            if let url = output.url {
                self.latestURL = url
                if output.reused {
                    self.editingURL = existing?.editingURL
                } else {
                    self.editingURL = nil
                    self.savedResults[self.mode] = SavedResult(id: self.captureID, url: url)
                }
                self.pendingExistingResult = nil
                self.pendingPNG = nil
                self.hasPendingSave = false
                self.message = self.copied ? "コピー・保存しました" : "保存しました。コピーはできませんでした"
                trace.record(.archiveOutcome, mode: workerMode, phase: .writing, outcome: .accepted)
            } else {
                self.message = self.copied ? "コピーしました。保存できませんでした" : "コピー・保存ができませんでした"
                trace.record(.archiveOutcome, mode: workerMode, phase: .writing, outcome: .rejected)
            }
            reservationsHeld = false
            self.saveWorkerPNGBytes = 0
            self.workerThumbnailReserveBytes = 0
            self.isSaving = false
            // Root view values are immutable snapshots; rebuild only after the saving gate is
            // released so a failed save exposes enabled explicit retry/discard controls.
            self.showPreview()
        }
    }

    func prepareToQuit() -> Bool {
        guard hasPendingSave || isSaving else { return true }
        let alert = NSAlert()
        alert.messageText = isSaving ? "画像を保存しています" : "まだ保存されていない画像があります"
        alert.informativeText = isSaving ? "保存が完了してから終了してください。" : "保存を再試行するか、保存せずに終了できます。"
        alert.addButton(withTitle: isSaving ? "戻る" : "保存を再試行")
        if !isSaving {
            alert.addButton(withTitle: "キャンセル")
            alert.addButton(withTitle: "保存せずに終了")
        }
        NSApp.activate(ignoringOtherApps: true)
        let choice = alert.runModal()
        if !isSaving, choice == .alertThirdButtonReturn { discardUnsaved(); return true }
        if !isSaving, choice == .alertFirstButtonReturn { retrySave() }
        return false
    }

    func discardUnsaved() {
        securityTrace.record(.resultInvalidated, mode: traceMode, outcome: .cancelled)
        recordID = UUID()
        // An invalidated disk worker still owns its PNG until actual completion.
        pendingPNG = nil
        pendingExistingResult = nil
        hasPendingSave = false
        dismissPreview()
    }

    func dismissPreview() {
        previewDismissed = true
        revision = UUID()
        dismissal?.cancel()
        dismissal = nil
        let wasVisible = panel?.isVisible == true
        panel?.orderOut(nil)
        panel?.contentView = nil
        if wasVisible { securityTrace.record(.resultPreviewHidden, mode: traceMode) }
        retireThumbnail()
    }

    func environmentDidChange() {
        // Saved files intentionally persist; in-memory screen content does not.
        discardUnsaved()
    }

    func openFolder() {
        do {
            try archive.createDirectory()
            NSWorkspace.shared.open(archive.directory)
        } catch {
            showError("保存フォルダを開けませんでした", detail: "空き容量とフォルダへのアクセスを確認してください。")
        }
    }

    func savedURL(for id: UUID, mode: CaptureResultMode) -> URL? {
        guard let record = savedResults[mode], record.id == id,
              FileManager.default.fileExists(atPath: record.url.path) else { return nil }
        return record.url
    }

    func annotateLatest() {
        guard let url = latestURL else { return }
        let editor = CaptureAnnotationController.shared
        if editor.open(url) { dismissPreview() }
        else { showError("注釈画面を開けませんでした", detail: editor.statusText) }
    }

    func editLatest() {
        guard let original = latestURL, !isSaving, !hasPendingSave else { return }
        // This method is a fresh explicit edit action, including the menu after auto-hide.
        // Stale view callbacks are separately fenced by their captured revision token.
        previewDismissed = false
        do {
            let total = try CaptureRetainedImageBudget.sum(retainedImageBytes,
                Self.editWorkspaceReserveBytes, externalRetainedBytes())
            guard limits.maximumImageBytes > 0, total <= limits.maximumImageBytes else { throw M0ImageError.memoryLimit }
        } catch {
            message = "編集用の作業領域を確保できませんでした。ほかの処理が終わってから再試行してください"
            showPreview()
            return
        }
        let identifier = recordID
        let existingEditingURL = editingURL
        let workerArchive = archive
        let trace = securityTrace
        let workerMode = traceMode
        editWorkerReserveBytes = Self.editWorkspaceReserveBytes
        isSaving = true // The same admission and quit fence covers this real disk worker.
        message = "編集用の画像を準備しています…原本は保存されています"
        showPreview()
        Task { @MainActor [weak self] in
            let target = await Task.detached(priority: .userInitiated) { () -> URL? in
                trace.record(.editCopyStarted, mode: workerMode, phase: .writing)
                let result: URL? = autoreleasepool {
                    do {
                        try workerArchive.validateSavedFile(original)
                        if let existingEditingURL {
                            try workerArchive.validateSavedFile(existingEditingURL)
                            return existingEditingURL
                        }
                        return try workerArchive.makeEditingCopy(of: original)
                    } catch { return nil }
                }
                trace.record(.editCopyReturned, mode: workerMode, phase: .writing,
                             outcome: result == nil ? .failure : .success)
                return result
            }.value
            guard let self else { return }
            var reservationHeld = true
            defer {
                if reservationHeld { self.editWorkerReserveBytes = 0; self.isSaving = false }
            }
            // An invalidation or a close never permits a late Preview launch or error dialog.
            guard self.recordID == identifier, !self.previewDismissed else { return }
            if let target {
                self.editingURL = target
                self.savedResults[self.mode]?.editingURL = target
            }
            reservationHeld = false
            self.editWorkerReserveBytes = 0
            self.isSaving = false
            guard self.recordID == identifier, !self.previewDismissed else { return }
            guard let target else {
                self.message = "編集用の画像を作れませんでした。原本は保存されています。空き容量を確認して、もう一度お試しください"
                self.showPreview()
                return
            }
            if let opener = self.opener {
                self.dismissPreview()
                guard self.recordID == identifier else { return }
                opener(target)
            } else {
                self.openInPreview(target, identifier: identifier)
            }
        }
    }

    private func openInPreview(_ target: URL, identifier: UUID) {
        guard recordID == identifier, !previewDismissed else { return }
        let presentation = revision
        // Verification owns only the fixed application URL and policy. Keep disk/code-signature
        // work off MainActor; a close, another capture or a newer action cancels this open intent.
        let services = previewServices
        Task { @MainActor [weak self] in
            let application = await Task.detached(priority: .userInitiated) {
                services.resolveApplication()
            }.value
            guard let self, self.recordID == identifier, !self.previewDismissed,
                  self.revision == presentation else { return }
            guard let application else {
                self.presentPreviewOpenError()
                return
            }
            guard self.recordID == identifier, !self.previewDismissed, self.revision == presentation else { return }
            // Hiding for this open belongs to the same intent. Capture its resulting generation
            // before launch so every subsequent close, edit, receipt or invalidation fences the
            // delayed completion too, even when the saved capture's record ID is unchanged.
            self.dismissPreview()
            let completionPresentation = self.revision
            services.launch(target, application) { [weak self] failed in
                guard failed, let self, self.recordID == identifier,
                      self.revision == completionPresentation else { return }
                self.presentPreviewOpenError(editing: true)
            }
        }
    }

    private func presentPreviewOpenError(editing: Bool = false) {
        if let present = previewServices.errorPresenter { present() }
        else {
            showError("プレビューを開けませんでした", detail: editing
                ? "保存フォルダから編集用の画像を開いてください。原本は保存されています。"
                : "保存フォルダから画像を開いてください。原本は保存されています。")
        }
    }

    private func showPreview() {
        dismissal?.cancel()
        revision = UUID()
        let token = revision
        guard previewsEnabled, !previewDismissed else { return }
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 284, height: 224),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.isRestorable = false
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = window
        }
        panel?.contentView = NSHostingView(rootView: CaptureResultView(
            image: thumbnail, securityTrace: securityTrace, mode: traceMode,
            isCurrent: { [weak self] in self?.revision == token && self?.previewDismissed == false },
            message: message, failed: hasPendingSave, saving: isSaving,
            edit: { [weak self] in guard self?.revision == token else { return }; self?.annotateLatest() },
            close: { [weak self] in guard self?.revision == token else { return }; self?.dismissPreview() },
            retry: { [weak self] in guard self?.revision == token else { return }; self?.retrySave() },
            discard: { [weak self] in guard self?.revision == token else { return }; self?.discardUnsaved() }))
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main,
           let panel {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 20, y: frame.minY + 20))
        }
        panel?.orderFrontRegardless()
        if panel?.isVisible == true { securityTrace.record(.resultPreviewShown, mode: traceMode) }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        if !hasPendingSave && !isSaving {
            dismissal = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                guard self?.revision == token else { return }
                self?.dismissPreview()
            }
        }
    }

    private func showError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "閉じる")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    nonisolated private static func makeThumbnailBitmap(_ png: Data) -> ResultThumbnailBitmap? {
        guard let source = CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumThumbnailDimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), decoded.width > 0, decoded.height > 0,
              decoded.width <= maximumThumbnailDimension, decoded.height <= maximumThumbnailDimension,
              decoded.bitsPerComponent == 8, decoded.bitsPerPixel == 32,
              !decoded.bitmapInfo.contains(.floatComponents),
              decoded.bytesPerRow >= decoded.width * 4,
              decoded.bytesPerRow <= maximumThumbnailDimension * 4,
              decoded.bytesPerRow * decoded.height <= maximumThumbnailBitmapBytes,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: decoded.width, height: decoded.height,
                bitsPerComponent: 8, bytesPerRow: decoded.width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        guard context.bitsPerComponent == 8, context.bitsPerPixel == 32,
              context.bytesPerRow >= decoded.width * 4,
              context.bytesPerRow <= maximumThumbnailDimension * 4,
              context.bytesPerRow * context.height <= maximumThumbnailBitmapBytes else { return nil }
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        guard let independent = context.makeImage(), independent.width == decoded.width,
              independent.height == decoded.height, independent.bitsPerComponent == 8, independent.bitsPerPixel == 32,
              !independent.bitmapInfo.contains(.floatComponents), independent.bytesPerRow >= independent.width * 4,
              independent.bytesPerRow <= maximumThumbnailDimension * 4,
              independent.bytesPerRow * independent.height <= maximumThumbnailBitmapBytes else { return nil }
        // This bitmap's owned storage is independent of the PNG, ImageIO source and decoder.
        return ResultThumbnailBitmap(image: independent, bytes: independent.bytesPerRow * independent.height)
    }

}

private struct CaptureResultView: View {
    let image: ResultThumbnail?
    let securityTrace: CaptureSecurityTrace
    let mode: CaptureSecurityTrace.Mode
    let isCurrent: @MainActor () -> Bool
    let message: String
    let failed: Bool
    let saving: Bool
    let edit: () -> Void
    let close: () -> Void
    let retry: () -> Void
    let discard: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(message).font(.caption).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(action: close) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).help("プレビューを閉じる。保存した画像は残ります")
                    .accessibilityLabel("プレビューを閉じる")
            }
            Button(action: edit) {
                Group {
                    if let image { ResultThumbnailView(thumbnail: image, trace: securityTrace, mode: mode, isCurrent: isCurrent) }
                    else { Image(systemName: "photo").font(.largeTitle) }
                }
                .frame(maxWidth: .infinity).frame(height: 120)
                .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain).disabled(failed || saving)
            .accessibilityLabel("撮影画像にコメント・記号を追加")
            if failed {
                HStack {
                    Button(saving ? "保存中…" : "保存を再試行", action: retry).disabled(saving)
                    Button("保存せずに続ける", action: discard).disabled(saving)
                }.font(.caption)
            } else {
                Button("コメント・記号を追加", systemImage: "text.bubble", action: edit)
                    .font(.callout).disabled(saving)
            }
        }
        .padding(12).frame(width: 284, height: 224)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.12)))
    }
}


/// The actual AppKit paint boundary; onAppear is not evidence that an image was drawn.
private struct ResultThumbnailView: NSViewRepresentable {
    let thumbnail: ResultThumbnail
    let trace: CaptureSecurityTrace
    let mode: CaptureSecurityTrace.Mode
    let isCurrent: @MainActor () -> Bool
    func makeNSView(context: Context) -> ResultThumbnailDrawView { ResultThumbnailDrawView() }
    func updateNSView(_ view: ResultThumbnailDrawView, context: Context) {
        view.thumbnail = thumbnail; view.trace = trace; view.mode = mode; view.isCurrent = isCurrent
        view.needsDisplay = true
    }
}

@MainActor
private final class ResultThumbnailDrawView: NSView {
    var thumbnail: ResultThumbnail?
    var trace = CaptureSecurityTrace.disabled
    var mode = CaptureSecurityTrace.Mode.none
    var isCurrent: @MainActor () -> Bool = { false }
    override func draw(_ dirtyRect: NSRect) {
        guard isCurrent(), let thumbnail, NSGraphicsContext.current != nil,
              bounds.width > 0, bounds.height > 0,
              thumbnail.image.size.width > 0, thumbnail.image.size.height > 0 else { return }
        let factor = min(bounds.width / thumbnail.image.size.width, bounds.height / thumbnail.image.size.height)
        let size = NSSize(width: thumbnail.image.size.width * factor, height: thumbnail.image.size.height * factor)
        let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                          width: size.width, height: size.height)
        thumbnail.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        trace.record(.resultPreviewDraw, mode: mode)
    }
}
