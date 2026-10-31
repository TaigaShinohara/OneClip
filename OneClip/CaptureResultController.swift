import AppKit
import Combine
import ImageIO
import SwiftUI

enum CaptureResultMode: Hashable { case single, collection }

/// A single pending PNG is owned until its worker finishes or a failed save is resolved.
/// The thumbnail owns only a downsampled image; saved images are represented by URLs.
@MainActor
final class CaptureResultController: ObservableObject {
    static let shared = CaptureResultController()

    @Published private(set) var latestURL: URL?
    @Published private(set) var hasPendingSave = false
    @Published private(set) var isSaving = false
    @Published private(set) var message = ""
    var isPreviewVisible: Bool { panel?.isVisible == true }
    private let archive: CaptureArchive
    private let previewsEnabled: Bool
    private var pendingPNG: Data?
    private var copied = false
    private var thumbnail: NSImage?
    private var editingURL: URL?
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?
    private var revision = UUID()
    private var recordID = UUID()
    private var captureID = UUID()
    private var mode = CaptureResultMode.single
    private var previewDismissed = false
    private struct SavedResult {
        let id: UUID
        let url: URL
        var editingURL: URL?
    }
    // At most one URL record per capture mode, never an image history.
    private var savedResults: [CaptureResultMode: SavedResult] = [:]

    init(archive: CaptureArchive = CaptureArchive(), previewsEnabled: Bool = true) {
        self.archive = archive
        self.previewsEnabled = previewsEnabled
    }

    func receive(_ png: Data, copied: Bool, id: UUID = UUID(), mode: CaptureResultMode = .single) {
        guard !isSaving, !hasPendingSave else { return }
        recordID = UUID()
        captureID = id
        self.mode = mode
        dismissPreview()
        previewDismissed = false
        self.copied = copied
        thumbnail = Self.makeThumbnail(png)
        if let saved = savedResults[mode], saved.id == id,
           FileManager.default.fileExists(atPath: saved.url.path) {
            latestURL = saved.url
            editingURL = saved.editingURL
            message = copied ? "コピー・保存しました" : "保存しました。コピーはできませんでした"
            showPreview()
            return
        }
        latestURL = nil
        editingURL = nil
        pendingPNG = png
        hasPendingSave = true
        retrySave()
    }

    func retrySave() {
        guard let png = pendingPNG, !isSaving else { return }
        let identifier = recordID
        let archive = archive
        previewDismissed = false
        if thumbnail == nil { thumbnail = Self.makeThumbnail(png) }
        isSaving = true
        message = copied ? "コピーしました。保存中…" : "コピーできませんでした。保存中…"
        showPreview()
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try archive.save(png) }
            }.value
            guard let self else { return }
            self.isSaving = false
            guard self.recordID == identifier else { return }
            switch result {
            case .success(let url):
                self.latestURL = url
                self.savedResults[self.mode] = SavedResult(id: self.captureID, url: url)
                self.pendingPNG = nil
                self.hasPendingSave = false
                self.message = self.copied ? "コピー・保存しました" : "保存しました。コピーはできませんでした"
            case .failure:
                self.message = self.copied ? "コピーしました。保存できませんでした" : "コピー・保存ができませんでした"
            }
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
        recordID = UUID()
        // An invalidated disk worker still owns its PNG until actual completion.
        pendingPNG = nil
        hasPendingSave = false
        dismissPreview()
    }

    func dismissPreview() {
        previewDismissed = true
        revision = UUID()
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        thumbnail = nil
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

    func editLatest() {
        guard let original = latestURL else { return }
        let sourceID = recordID
        do {
            let target: URL
            if let editingURL { target = editingURL }
            else {
                target = try archive.makeEditingCopy(of: original)
                editingURL = target
                savedResults[mode]?.editingURL = target
            }
            guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
                showError("プレビューを開けませんでした", detail: "保存フォルダから画像を開いてください。原本は保存されています。")
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([target], withApplicationAt: application, configuration: configuration) { [weak self] _, error in
                guard error != nil else { return }
                Task { @MainActor in
                    guard let self, self.recordID == sourceID else { return }
                    self.showError("プレビューを開けませんでした", detail: "保存フォルダから編集用の画像を開いてください。原本は保存されています。")
                }
            }
            dismissPreview()
        } catch {
            showError("編集用の画像を作れませんでした", detail: "原本は保存されています。空き容量を確認して、もう一度お試しください。")
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
            image: thumbnail, message: message, failed: hasPendingSave, saving: isSaving,
            edit: { [weak self] in guard self?.revision == token else { return }; self?.editLatest() },
            close: { [weak self] in guard self?.revision == token else { return }; self?.dismissPreview() },
            retry: { [weak self] in guard self?.revision == token else { return }; self?.retrySave() },
            discard: { [weak self] in guard self?.revision == token else { return }; self?.discardUnsaved() }))
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main,
           let panel {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 20, y: frame.minY + 20))
        }
        panel?.orderFrontRegardless()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        if !hasPendingSave {
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

    private static func makeThumbnail(_ png: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

private struct CaptureResultView: View {
    let image: NSImage?
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
                    if let image { Image(nsImage: image).resizable().scaledToFit() }
                    else { Image(systemName: "photo").font(.largeTitle) }
                }
                .frame(maxWidth: .infinity).frame(height: 120)
                .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain).disabled(failed)
            .accessibilityLabel("撮影画像をプレビューで編集")
            if failed {
                HStack {
                    Button(saving ? "保存中…" : "保存を再試行", action: retry).disabled(saving)
                    Button("保存せずに続ける", action: discard).disabled(saving)
                }.font(.caption)
            } else {
                Button("プレビューで編集", systemImage: "pencil.tip.crop.circle", action: edit)
                    .font(.callout)
            }
        }
        .padding(12).frame(width: 284, height: 224)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.12)))
    }
}
