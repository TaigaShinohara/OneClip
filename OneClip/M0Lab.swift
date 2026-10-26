#if DEBUG
import AppKit
import Combine
import Darwin
import ScreenCaptureKit
import SwiftUI

enum M0ProbeError: String, Error {
    case permissionRequired = "PERMISSION_REQUIRED"
    case fixtureMissing = "FIXTURE_MISSING"
    case fixtureChanged = "FIXTURE_CHANGED"
    case fixtureIdentityMissing = "FIXTURE_IDENTITY_NOT_IN_SHAREABLE_CONTENT"
    case fixtureScreenMissing = "FIXTURE_SCREEN_MISSING"
    case invalidRegion = "INVALID_REGION"
    case captureFailed = "CAPTURE_FAILED"
    case noImage = "NO_IMAGE"
    case invalidated = "INVALIDATED"
}

/// Top-left point coordinates within a fixture, never an arbitrary desktop rectangle.
enum M0RegionGeometry {
    static func sourceRect(fixture: CGRect, screen: CGRect, region: CGRect) throws -> CGRect {
        let values = [fixture.minX, fixture.minY, fixture.width, fixture.height,
                      screen.minX, screen.minY, screen.width, screen.height,
                      region.minX, region.minY, region.width, region.height]
        guard values.allSatisfy(\.isFinite), fixture.width > 0, fixture.height > 0,
              screen.width > 0, screen.height > 0, screen.contains(fixture),
              region.width > 0, region.height > 0,
              CGRect(origin: .zero, size: fixture.size).contains(region) else {
            throw M0ProbeError.invalidRegion
        }
        return CGRect(x: fixture.minX - screen.minX + region.minX,
                      y: screen.maxY - fixture.maxY + region.minY,
                      width: region.width, height: region.height)
    }
}

@MainActor
final class M0LabController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = M0LabController()
    let hotKey = M0HotKeyProbe()
    @Published private(set) var status = "IDLE"
    @Published private(set) var permission = "NOT_CHECKED"
    @Published private(set) var preview: NSImage?
    @Published private(set) var metrics = ""
    @Published private(set) var busy = false
    @Published private(set) var invalidationCount = 0
    @Published private(set) var startedOperationCount = 0
    @Published var sampleCount = 2
    @Published var regionX: Double = 0
    @Published var regionY: Double = 0
    @Published var regionWidth: Double = 320
    @Published var regionHeight: Double = 180
    private var labWindow: NSWindow?
    private var fixtureWindow: NSWindow?
    private var fixtureView: NSImageView?
    private var fixtureGeneration = 1
    private var operation: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var result: M0CompositionResult?
    private var workspaceObservers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.invalidate(hide: true) }
            })
        }
    }

    func show() {
        guard !NativeCaptureInterface.shared.hasDiscardConfirmation else { return }
        // Refresh the read-only service timing when reopening this persistent hosting view.
        objectWillChange.send()
        if labWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 790),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "OneClip — M0限定試作"
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: M0LabView(model: self, hotKey: hotKey))
            window.center()
            labWindow = window
        }
        labWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.isProtectedDataAvailable { invalidate(hide: true) }
    }

    func windowWillClose(_ notification: Notification) {
        invalidate(hide: false)
        fixtureWindow?.orderOut(nil)
    }

    func checkPermission() {
        permission = CGPreflightScreenCaptureAccess() ? "GRANTED" : "NOT_AUTHORIZED"
    }

    func requestPermission() {
        // Only this explicit UI action can request access. Never invoked by self-tests.
        permission = CGRequestScreenCaptureAccess() ? "GRANTED" : "NOT_AUTHORIZED_OR_RESTART_REQUIRED"
    }

    func showFixture() {
        do {
            let asset = try M0ImageFixture.make(index: fixtureGeneration, width: 640, height: 360, scale: 1)
            if fixtureWindow == nil {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.title = "OneClip M0 Fixture"
                window.isReleasedWhenClosed = false
                window.isRestorable = false
                window.isMovableByWindowBackground = true
                let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
                view.imageScaling = .scaleAxesIndependently
                window.contentView = view
                window.center()
                fixtureView = view
                fixtureWindow = window
            }
            fixtureView?.image = NSImage(cgImage: asset.image, size: NSSize(width: 640, height: 360))
            fixtureWindow?.orderFront(nil)
            fixtureWindow?.displayIfNeeded()
            status = "FIXTURE_READY"
        } catch { status = Self.code(error) }
    }

    func updateFixture() {
        fixtureGeneration = fixtureGeneration % 4 + 1
        showFixture()
    }

    func makeSyntheticComposition() {
        guard !busy else { return }
        start { [sampleCount] in
            let assets = try M0ImageFixture.makeSamples(count: sampleCount)
            return try M0ImageComposer.compose(assets: assets)
        }
    }

    private func start(_ work: @escaping @Sendable () throws -> M0CompositionResult) {
        revision &+= 1
        let current = revision
        busy = true
        startedOperationCount += 1
        status = "COMPOSING"
        operation = Task { [weak self] in
            defer { self?.finishOperation() }
            let start = DispatchTime.now().uptimeNanoseconds
            do {
                let value = try await Task.detached(priority: .userInitiated, operation: work).value
                guard let self, self.revision == current, !Task.isCancelled else { return }
                self.adopt(value, started: start)
            } catch {
                guard let self, self.revision == current else { return }
                self.busy = false
                self.status = Self.code(error)
            }
        }
    }

    func captureFixture(displayRegion: Bool) {
        guard !busy else { return }
        guard CGPreflightScreenCaptureAccess() else { permission = "NOT_AUTHORIZED"; status = "PERMISSION_REQUIRED"; return }
        guard let fixture = fixtureWindow, fixture.isVisible else { status = "FIXTURE_MISSING"; return }
        let region = CGRect(x: regionX, y: regionY, width: regionWidth, height: regionHeight)
        revision &+= 1
        let current = revision
        busy = true
        startedOperationCount += 1
        status = "CAPTURING_FIXTURE_ONLY"
        operation = Task { [weak self] in
            defer { self?.finishOperation() }
            let start = DispatchTime.now().uptimeNanoseconds
            do {
                guard let self else { return }
                let asset = try await Self.captureAllowedFixture(fixture, region: displayRegion ? region : nil)
                guard self.revision == current, !Task.isCancelled else { return }
                let value = try await Task.detached { try M0ImageComposer.compose(assets: [asset]) }.value
                guard self.revision == current, !Task.isCancelled else { return }
                self.adopt(value, started: start)
            } catch {
                guard let self, self.revision == current else { return }
                self.busy = false
                self.status = Self.code(error)
            }
        }
    }

    /// No fallback to a display-wide/excluding-empty filter is permitted here.
    static func captureAllowedFixture(_ fixture: NSWindow, region: CGRect?) async throws -> M0ImageAsset {
        guard CGPreflightScreenCaptureAccess() else { throw M0ProbeError.permissionRequired }
        guard NSApp.isProtectedDataAvailable else { throw M0ProbeError.invalidated }
        try Task.checkCancellation()
        guard fixture.isVisible, fixture.windowNumber > 0 else { throw M0ProbeError.fixtureMissing }
        let number = CGWindowID(fixture.windowNumber)
        let frame = fixture.frame
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard fixture.isVisible, fixture.windowNumber == Int(number), fixture.frame == frame else {
            throw M0ProbeError.fixtureChanged
        }
        guard let window = content.windows.first(where: {
                  $0.windowID == number && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
              }) else { throw M0ProbeError.fixtureIdentityMissing }
        let filter: SCContentFilter
        let configuration = SCStreamConfiguration()
        if let region {
            guard let screen = fixture.screen,
                  let identifier = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == identifier.uint32Value }) else {
                throw M0ProbeError.fixtureScreenMissing
            }
            configuration.sourceRect = try M0RegionGeometry.sourceRect(fixture: frame, screen: screen.frame, region: region)
            filter = SCContentFilter(display: display, including: [window])
        } else {
            filter = SCContentFilter(desktopIndependentWindow: window)
        }
        let scale = Double(filter.pointPixelScale)
        let size = region?.size ?? frame.size
        let width = ceil(size.width * scale)
        let height = ceil(size.height * scale)
        guard scale.isFinite, scale > 0, width > 0, height > 0,
              width <= 16_384, height <= 16_384 else { throw M0ProbeError.invalidRegion }
        let metrics = M0ImageMetrics(width: Int(width), height: Int(height), bytesPerRow: Int(width) * 4, scale: scale)
        _ = try M0ImageComposer.makePlan(metrics: [metrics])
        configuration.width = Int(width)
        configuration.height = Int(height)
        configuration.showsCursor = false
        configuration.ignoreShadowsDisplay = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        try Task.checkCancellation()
        // Window allowlisting excludes the lab and all unrelated windows, even if overlapping.
        let asset: M0ImageAsset = try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, _ in
                if let image { continuation.resume(returning: M0ImageAsset(image: image, scale: scale)) }
                else { continuation.resume(throwing: M0ProbeError.captureFailed) }
            }
        }
        try Task.checkCancellation()
        guard fixture.isVisible, fixture.windowNumber == Int(number), fixture.frame == frame,
              NSApp.isProtectedDataAvailable else { throw M0ProbeError.fixtureMissing }
        return asset
    }

    func copySyntheticToGeneral() {
        guard !busy, let result else { status = "NO_IMAGE"; return }
        let board = NSPasteboard.general
        let outcome = M0ClipboardProbe.writePNG(result.pngData, to: board, expectedChangeCount: board.changeCount)
        status = outcome.code.rawValue
    }

    func invalidate(hide: Bool) {
        revision &+= 1
        operation?.cancel()
        result = nil
        preview = nil
        metrics = ""
        busy = operation != nil
        invalidationCount += 1
        status = busy ? "INVALIDATED_WAITING_FOR_WORKER" : "INVALIDATED"
        hotKey.unregister()
        if hide { labWindow?.orderOut(nil); fixtureWindow?.orderOut(nil) }
    }

    func stop() { invalidate(hide: true) }

    func waitForWorkToFinish() async { await operation?.value }

    private func finishOperation() {
        operation = nil
        busy = false
        if status == "INVALIDATED_WAITING_FOR_WORKER" { status = "INVALIDATED" }
    }

    func captureFixtureForCheck(region: CGRect?, coveredByLab: Bool = false) async throws -> M0ImageAsset {
        showFixture()
        // Both windows are ours and contain only the fabricated test UI.
        // A foreground lab covers the smaller fixture to exercise filter exclusion.
        if coveredByLab { show() }
        await Task.yield()
        guard let fixtureWindow else { throw M0ProbeError.fixtureMissing }
        if coveredByLab {
            guard let labWindow, labWindow.isVisible, labWindow.frame.contains(fixtureWindow.frame) else {
                throw M0ProbeError.fixtureMissing
            }
        }
        return try await Self.captureAllowedFixture(fixtureWindow, region: region)
    }

    private func adopt(_ value: M0CompositionResult, started: UInt64) {
        result = value
        preview = NSImage(cgImage: value.image, size: NSSize(width: value.image.width, height: value.image.height))
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        metrics = "\(value.plan.width)×\(value.plan.height) px / PNG \(value.pngData.count) B / estimated peak \(value.plan.estimatedPeakBytes) B / \(Int(ms)) ms"
        busy = false
        status = "IMAGE_READY_NOT_COPIED"
    }

    static func code(_ error: any Error) -> String {
        if let error = error as? M0ProbeError { return error.rawValue }
        if let error = error as? M0ImageError { return String(describing: error) }
        return "PROBE_FAILED"
    }
}

private struct M0LabView: View {
    @ObservedObject var model: M0LabController
    @ObservedObject var hotKey: M0HotKeyProbe
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("M0 限定試作").font(.title2.bold())
                    Spacer()
                    Button("OneClipを終了") { NSApplication.shared.terminate(nil) }
                }
                Text("製品の撮影機能はまだ未完成です。このパネルは架空素材と専用テスト画面だけを扱います。画像保存・外部送信はしません。")
                GroupBox("1. メモリ上の画像結合") {
                    HStack {
                        Picker("素材", selection: $model.sampleCount) {
                            ForEach([1, 2, 4], id: \.self) { Text("\($0)枚").tag($0) }
                        }.frame(width: 170)
                        Button("合成素材で結合") { model.makeSyntheticComposition() }.disabled(model.busy)
                        Button("取消・破棄") { model.invalidate(hide: false) }
                    }.padding(6)
                }
                GroupBox("2. 権限と専用テスト画面の取得") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button("権限状態を確認") { model.checkPermission() }
                            Button("画面収録の許可を要求") { model.requestPermission() }
                            Text(model.permission).font(.caption.monospaced())
                        }
                        Text("未許可と拒否は自動判別しません。OSの本人許可後、明示的に再試行してください。")
                            .font(.caption)
                        HStack {
                            Button("テスト画面を表示") { model.showFixture() }
                            Button("架空の内容を更新") { model.updateFixture() }
                            Button("このテスト画面だけ取得") { model.captureFixture(displayRegion: false) }.disabled(model.busy)
                        }
                        HStack {
                            regionField("X", value: $model.regionX)
                            regionField("Y", value: $model.regionY)
                            regionField("幅", value: $model.regionWidth)
                            regionField("高さ", value: $model.regionHeight)
                        }
                        Button("テスト画面内の領域だけ取得（単位:ポイント）") { model.captureFixture(displayRegion: true) }
                            .disabled(model.busy)
                    }.padding(6)
                }
                GroupBox("3. 登録型ホットキー（撮影・コピーはしません）") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("試験キー: Control + Option + Command + 9（⌃⌥⌘9）。登録はこのパネルの間だけです。")
                        HStack {
                            Button("試験キーを登録") { hotKey.register() }
                            Button("重複登録を検査") { hotKey.testDuplicateRegistration() }
                            Button("登録解除") { hotKey.unregister() }
                        }
                        Text("\(hotKey.statusCode) / status \(hotKey.lastOSStatus.map(String.init) ?? "—") / 検出 \(hotKey.pressCount)")
                            .font(.caption.monospaced())
                    }.padding(6)
                }
                Text("状態: \(model.status) / 失効 \(model.invalidationCount)").font(.callout.monospaced())
                Text(model.metrics).font(.caption.monospaced()).textSelection(.enabled)
                Text("T09 実取得Service（直近成功）: \(ScreenshotService.lastCaptureDurationNanoseconds.map { "\($0) ns" } ?? "未測定")")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text("画面情報・安全検査・実SCK待機・await復帰を含み、範囲選択・PNG合成・書込みは含みません。M0固有の取得＋PNG合算とは別の値です。M0取得とSafeLabの架空取得は更新せず、SafeLabの新processでは未測定です。")
                    .font(.caption)
                if let preview = model.preview {
                    Image(nsImage: preview).resizable().interpolation(.none).scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 260).border(.secondary)
                    Button("表示した架空画像を一般クリップボードへコピー") { model.copySyntheticToGeneral() }
                        .disabled(model.busy)
                    Text("このボタンだけが現在のクリップボードを置き換えます。画像はこのMac限定で渡します。")
                        .font(.caption)
                }
                Text("スリープ等の通知は失効処理へ接続しています。すべての画面ロックを検出済みとは扱いません。")
                    .font(.caption)
            }.padding(18)
        }.frame(minWidth: 700, minHeight: 700)
    }
    private func regionField(_ title: String, value: Binding<Double>) -> some View {
        HStack { Text(title); TextField(title, value: value, format: .number).frame(width: 72) }
    }
}

#endif
