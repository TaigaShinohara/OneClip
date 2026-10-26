import AppKit
import CoreGraphics
import CoreText

#if !DEBUG
#error("M4Fixture requires -D DEBUG to reuse M3PracticeFixture; it is a separate executable, not product code.")
#endif

/// Standalone, fabricated capture target for another process (including normal Release OneClip).
/// All pixels are generated in memory. No screen, pasteboard, file, network or logger is used.
/// Compile with M0ImageCore.swift and M3PracticeFixture.swift, -D DEBUG, -parse-as-library.
@main
struct M4Fixture {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = FixtureDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
private final class FixtureDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let canvas = FixtureCanvas(frame: .zero)
    private let information = NSTextField(wrappingLabelWithString: "")
    private let stages = NSSegmentedControl(labels: ["U2 エラー", "U2 通信設定", "U3 変更前", "U3 変更後", "M4 画素"],
                                            trackingMode: .selectOne, target: nil, action: nil)
    private let nativePixels = NSButton(checkboxWithTitle: "100%：1画像pxを1描画pxで表示", target: nil, action: nil)
    private let scroll = NSScrollView()
    private var window: NSWindow?
    private var asset: M0ImageAsset?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "M4 Fixture を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        NSApplication.shared.mainMenu = menu

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "OneClip M4 — 外部プロセスの架空素材"
        window.minSize = NSSize(width: 780, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        stages.selectedSegment = 0
        stages.target = self
        stages.action = #selector(selectStage(_:))
        nativePixels.target = self
        nativePixels.action = #selector(changeDisplayMode(_:))
        let controls = NSStackView(views: [stages, nativePixels])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 10

        information.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        information.maximumNumberOfLines = 3
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.backgroundColor = .windowBackgroundColor
        scroll.documentView = canvas

        let note = NSTextField(wrappingLabelWithString:
            "枠の内側の画像だけが素材です。通常表示は固定640×360ptで、画面が1倍なら縮小表示です。100%は現在のbacking倍率に合わせます（パネルの物理画素の保証ではありません）。広い画像はスクロールできます。架空表示だけを行い、コピーや保存はしません。")
        note.font = .systemFont(ofSize: 12)
        let root = NSView()
        window.contentView = root
        for view in [controls, information, scroll, note] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            controls.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            information.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            information.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            information.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: information.bottomAnchor, constant: 12),
            note.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            note.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            note.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        selectStage(stages)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        updateDisplay()
    }

    @objc private func selectStage(_ sender: NSSegmentedControl) {
        do {
            let index = sender.selectedSegment
            asset = index < M3PracticeStage.allCases.count
                ? try M3PracticeFixture.make(M3PracticeStage.allCases[index])
                : try PixelTarget.make()
            canvas.image = asset?.image
            updateDisplay()
        } catch {
            let alert = NSAlert()
            alert.messageText = "架空素材を準備できませんでした"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    @objc private func changeDisplayMode(_ sender: NSButton) { updateDisplay() }

    func windowDidChangeBackingProperties(_ notification: Notification) { updateDisplay() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func updateDisplay() {
        guard let asset else { return }
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let native = nativePixels.state == .on
        let displayScale = native ? backingScale : CGFloat(asset.scale)
        let size = NSSize(width: CGFloat(asset.image.width) / displayScale,
                          height: CGFloat(asset.image.height) / displayScale)
        canvas.setFrameSize(size)
        canvas.needsDisplay = true
        // The document view is unflipped; begin with the source's top-left visible.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, size.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        let stage = stages.selectedSegment < M3PracticeStage.allCases.count
            ? M3PracticeStage.allCases[stages.selectedSegment].menuTitle : "M4 固定画素・四隅・小文字"
        information.stringValue = String(format:
            "%@ | 素材 1280×720px / sRGB / scale 2\n表示 %.0f×%.0fpt / 画面倍率 %.2f / %@",
            stage, size.width, size.height, backingScale,
            native ? "100%：1画像px＝1backing px（部分表示はスクロール）" : "固定640×360pt（backing倍率2で1画像px＝1backing px）")
    }
}

@MainActor
private final class FixtureCanvas: NSView {
    var image: CGImage?
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        guard let image else { return }
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        // The unflipped AppKit view and bitmap both have a bottom-left drawing origin.
        context.draw(image, in: bounds)
    }
}

private enum PixelTarget {
    static func make() throws -> M0ImageAsset {
        let width = 1_280
        let height = 720
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                        CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw M0ImageError.contextCreationFailed
        }
        func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ rgb: UInt32) {
            context.setFillColor(CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                                         green: CGFloat((rgb >> 8) & 255) / 255,
                                         blue: CGFloat(rgb & 255) / 255, alpha: 1))
            // All target coordinates below are integer pixels from the top-left.
            context.fill(CGRect(x: CGFloat(x), y: CGFloat(height - y - h), width: CGFloat(w), height: CGFloat(h)))
        }
        func text(_ value: String, size: CGFloat, x: CGFloat, top: CGFloat) {
            let font = CTFontCreateWithName("Menlo-Regular" as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes) as CFAttributedString)
            var ascent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, nil, nil)
            context.saveGState()
            context.setShouldAntialias(true)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: x, y: CGFloat(height) - top - ascent)
            CTLineDraw(line, context)
            context.restoreGState()
        }
        context.setShouldAntialias(false)
        fill(0, 0, width, height, 0xFFFFFF)
        fill(0, 0, width, 1, 0x000000)
        fill(0, height - 1, width, 1, 0x000000)
        fill(0, 0, 1, height, 0x000000)
        fill(width - 1, 0, 1, height, 0x000000)
        fill(0, 0, 16, 16, 0xFF0000)
        fill(width - 16, 0, 16, 16, 0x00A000)
        fill(0, height - 16, 16, 16, 0x0000FF)
        fill(width - 16, height - 16, 16, 16, 0xFFD000)
        text("TOP LEFT (0,0) / 1280 x 720 px / sRGB", size: 22, x: 32, top: 24)
        text("TOP RIGHT (1279,0)", size: 18, x: 990, top: 24)
        text("1 px black/white stripes: x32...543, y128...175", size: 16, x: 32, top: 98)
        for x in 0..<512 { fill(32 + x, 128, 1, 48, x.isMultiple(of: 2) ? 0x000000 : 0xFFFFFF) }
        text("2 px black/white stripes: x32...543, y224...271", size: 16, x: 32, top: 194)
        for x in 0..<256 { fill(32 + x * 2, 224, 2, 48, x.isMultiple(of: 2) ? 0x000000 : 0xFFFFFF) }
        for (index, rgb) in [UInt32(0xFF0000), 0x00FF00, 0x0000FF, 0x00FFFF, 0xFF00FF, 0xFFFF00, 0x808080, 0x000000].enumerated() {
            fill(640 + index * 64, 128, 64, 144, rgb)
        }
        text("8 exact sRGB blocks / 64 x 144 px each", size: 16, x: 640, top: 98)
        for (index, size) in [8, 10, 12, 18, 24].enumerated() {
            text("\(size) px: Abc 0123456789 / endpoint / timeout / retry", size: CGFloat(size),
                 x: 32, top: CGFloat(320 + index * 48))
        }
        fill(640, 336, 257, 129, 0x152840)
        fill(641, 337, 255, 127, 0xF1F5FA)
        text("257 x 129 px outer border", size: 16, x: 640, top: 488)
        text("BOTTOM LEFT (0,719)", size: 18, x: 32, top: 672)
        text("BOTTOM RIGHT (1279,719)", size: 18, x: 944, top: 672)
        guard let image = context.makeImage() else { throw M0ImageError.contextCreationFailed }
        return M0ImageAsset(image: image, scale: 2)
    }
}
