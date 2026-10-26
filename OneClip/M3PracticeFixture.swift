#if DEBUG
import CoreGraphics
import CoreText
import Foundation

/// Fixed stages for a person to crop during U2/U3. These labels are not trial results.
enum M3PracticeStage: String, CaseIterable, Sendable {
    case error, settings, before, after

    var menuTitle: String {
        switch self {
        case .error: "U2 架空の接続エラー"
        case .settings: "U2 関連する通信設定"
        case .before: "U3 架空設定の変更前"
        case .after: "U3 架空設定の変更後"
        }
    }
}

/// One fixed 1280x720 sRGB buffer (3,686,400 bytes), displayed at scale 2.
/// Content is fabricated in memory. No screen, file, pasteboard or network is accessed.
enum M3PracticeFixture {
    private static let width = 1_280
    private static let height = 720

    static func make(_ stage: M3PracticeStage) throws -> M0ImageAsset {
        let rowBytes = width * 4
        let metrics = M0ImageMetrics(width: width, height: height, bytesPerRow: rowBytes, scale: 2)
        _ = try M0ImageComposer.makePlan(metrics: [metrics])
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: rowBytes, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                        CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw M0ImageError.contextCreationFailed
        }

        let ink = color(0x14253B)
        let muted = color(0x52647A)
        let blue = color(0x1759AA)
        let accent = color(stage == .error ? 0xB42335 : stage == .after ? 0x08724E : 0x1759AA)
        fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)), color: color(0xF1F5FA), in: context)
        fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: 76), color: color(0x152840), in: context)
        fill(CGRect(x: 0, y: 76, width: 216, height: 644), color: color(0xFFFFFF), in: context)
        text("EXAMPLE Console", size: 30, x: 36, top: 19, color: color(0xFFFFFF), bold: true, in: context)
        text("架空画面 / U2・U3用 / 通信なし", size: 22, x: 820, top: 24, color: color(0xDCE8F7), in: context)

        text("SUPPORT", size: 18, x: 28, top: 112, color: muted, monospaced: true, in: context)
        let selected = stage == .error ? 0 : stage == .settings ? 1 : 2
        for (index, label) in ["接続エラー", "通信設定", "変更の比較"].enumerated() {
            let top = CGFloat(163 + index * 68)
            if index == selected {
                rounded(CGRect(x: 18, y: top - 6, width: 180, height: 50), fill: color(0xE5EFFD), in: context)
                fill(CGRect(x: 18, y: top + 4, width: 4, height: 28), color: blue, in: context)
            }
            text(label, size: 24, x: 34, top: top, color: index == selected ? blue : muted,
                 bold: index == selected, in: context)
        }
        text("固定データのみ", size: 18, x: 26, top: 622, color: muted, in: context)
        text("実情報・履歴なし", size: 18, x: 26, top: 652, color: muted, in: context)

        let title: String
        let subtitle: String
        let status: String
        let note: String
        let marker: String
        switch stage {
        case .error:
            title = "接続エラー"
            subtitle = "エラーの内容と、接続先・待機時間を確認します。"
            status = "Error EXAMPLE-42"
            note = "3秒以内に応答がなかったため、接続を中止しました。"
            marker = "E"
        case .settings:
            title = "関連する通信設定"
            subtitle = "エラー画面と同じ接続先・タイムアウトです。"
            status = "通信の設定"
            note = "今回のエラーに関係する項目を表示しています。"
            marker = "S"
        case .before:
            title = "架空設定・変更前"
            subtitle = "同じ接続先のまま、二つの項目を変更します。"
            status = "BEFORE / 変更前"
            note = "変更前：待機時間は3秒、再試行は無効です。"
            marker = "B"
        case .after:
            title = "架空設定・変更後"
            subtitle = "同じ接続先のまま、待機時間と再試行を変更しました。"
            status = "AFTER / 変更後"
            note = "変更後：待機時間を10秒に延ばし、再試行を有効にしました。"
            marker = "A"
        }
        text(title, size: 38, x: 260, top: 110, color: ink, bold: true, in: context)
        text(subtitle, size: 24, x: 260, top: 166, color: muted, in: context)

        rounded(CGRect(x: 260, y: 222, width: 964, height: 366), fill: color(0xFFFFFF),
                stroke: color(0xCCD7E5), in: context)
        text(status, size: 30, x: 292, top: 246, color: accent, bold: true, in: context)
        if stage == .error {
            text("接続できません", size: 28, x: 716, top: 248, color: accent, bold: true, in: context)
        }
        rounded(CGRect(x: 1_158, y: 242, width: 42, height: 42), fill: accent, in: context)
        text(marker, size: 26, x: 1_169, top: 247, color: color(0xFFFFFF), monospaced: true, in: context)

        let labels = ["接続先 endpoint", "待機時間 timeout", "再試行 retry"]
        let values = ["local.example.test", stage == .after ? "10 s" : "3 s", stage == .after ? "ON" : "OFF"]
        for index in 0..<labels.count {
            let top = CGFloat(312 + index * 60)
            text(labels[index], size: 24, x: 292, top: top + 2, color: muted, in: context)
            text(values[index], size: 30, x: 548, top: top, color: index == 0 ? ink : accent,
                 monospaced: true, in: context)
            if index < 2 {
                fill(CGRect(x: 292, y: top + 43, width: 900, height: 1), color: color(0xE2E9F2), in: context)
            }
        }
        if stage == .before || stage == .after {
            rounded(CGRect(x: 528, y: 361, width: 238, height: 108), fill: nil, stroke: accent, in: context)
            arrow(from: CGPoint(x: 792, y: 412), to: CGPoint(x: 850, y: 412), color: accent, in: context)
            text(stage == .after ? "変更した項目" : "変更する項目", size: 23, x: 872, top: 397,
                 color: accent, bold: true, in: context)
        } else {
            arrow(from: CGPoint(x: 864, y: 402), to: CGPoint(x: 802, y: 402), color: blue, in: context)
            text("通信設定を確認", size: 22, x: 884, top: 386, color: blue, in: context)
        }
        text(note, size: 23, x: 292, top: 514, color: ink, in: context)
        text("架空データです。この表示から通信や設定変更は行いません。", size: 20,
             x: 260, top: 608, color: muted, in: context)
        rounded(CGRect(x: 260, y: 648, width: 964, height: 40), fill: color(0xE2EAF5), in: context)
        text("小文字 18px: endpoint / timeout / retry / Abc 0123456789", size: 18,
             x: 276, top: 657, color: ink, in: context)

        // Different corners and an interior stage marker expose rotation, clipping and order.
        fill(CGRect(x: 0, y: 0, width: 58, height: 8), color: color(0xF6C344), in: context)
        fill(CGRect(x: 0, y: 0, width: 8, height: 34), color: color(0xF6C344), in: context)
        fill(CGRect(x: 1_252, y: 704, width: 28, height: 16), color: color(0x08B9CF), in: context)
        fill(CGRect(x: 1_270, y: 690, width: 10, height: 14), color: color(0x08B9CF), in: context)
        guard let image = context.makeImage() else { throw M0ImageError.contextCreationFailed }
        return M0ImageAsset(image: image, scale: 2)
    }

    private static func color(_ rgb: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    /// Layout uses a top-left pixel origin; CoreGraphics keeps its normal text orientation.
    private static func rect(_ topLeft: CGRect) -> CGRect {
        CGRect(x: topLeft.minX, y: CGFloat(height) - topLeft.maxY,
               width: topLeft.width, height: topLeft.height)
    }

    private static func fill(_ frame: CGRect, color: CGColor, in context: CGContext) {
        context.setFillColor(color)
        context.fill(rect(frame))
    }

    private static func rounded(_ frame: CGRect, fill: CGColor?, stroke: CGColor? = nil, in context: CGContext) {
        let path = CGPath(roundedRect: rect(frame), cornerWidth: 12, cornerHeight: 12, transform: nil)
        context.saveGState()
        if let fill { context.setFillColor(fill); context.addPath(path); context.fillPath() }
        if let stroke { context.setStrokeColor(stroke); context.setLineWidth(2); context.addPath(path); context.strokePath() }
        context.restoreGState()
    }

    private static func arrow(from start: CGPoint, to end: CGPoint, color: CGColor, in context: CGContext) {
        let direction: CGFloat = end.x >= start.x ? 1 : -1
        context.saveGState()
        context.setStrokeColor(color); context.setLineWidth(3)
        context.move(to: CGPoint(x: start.x, y: CGFloat(height) - start.y))
        context.addLine(to: CGPoint(x: end.x, y: CGFloat(height) - end.y))
        context.move(to: CGPoint(x: end.x - 10 * direction, y: CGFloat(height) - end.y + 7))
        context.addLine(to: CGPoint(x: end.x, y: CGFloat(height) - end.y))
        context.addLine(to: CGPoint(x: end.x - 10 * direction, y: CGFloat(height) - end.y - 7))
        context.strokePath()
        context.restoreGState()
    }

    private static func text(_ value: String, size: CGFloat, x: CGFloat, top: CGFloat, color: CGColor,
                             bold: Bool = false, monospaced: Bool = false, in context: CGContext) {
        let name = monospaced ? "Menlo-Regular" : bold ? "HiraginoSans-W6" : "HiraginoSans-W3"
        let font = CTFontCreateWithName(name as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
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
}
#endif
