import CoreGraphics
import Foundation

/// One display at selection time. Its frame uses global AppKit coordinates (bottom-left origin).
struct CaptureDisplaySnapshot: Equatable, Sendable {
    let id: UInt32
    let frame: CGRect
    let scale: CGFloat

    init(id: UInt32, frame: CGRect, scale: CGFloat) throws {
        _ = try RegionGeometry.pixelExtents(frame: frame, scale: scale)
        self.id = id
        self.frame = frame
        self.scale = scale
    }
}

/// A nonempty, pixel-aligned global rectangle contained entirely in its original display.
struct CaptureSelection: Equatable, Sendable {
    let display: CaptureDisplaySnapshot
    let rect: CGRect

    init(display: CaptureDisplaySnapshot, rect: CGRect) throws {
        try RegionGeometry.validateSelection(display: display, rect: rect)
        self.display = display
        self.rect = rect
    }
}

struct RegionCapturePlan: Equatable, Sendable {
    /// Display-local points with a top-left origin, as required by ScreenCaptureKit.
    let sourceRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
}

enum RegionArrowDirection: Sendable {
    case left, right, up, down
}

enum RegionGeometryError: Error, Equatable, LocalizedError, Sendable {
    case invalidDisplay
    case invalidPoint
    case startOutsideDisplay
    case endOutsideDisplay
    case emptySelection
    case selectionOutsideDisplay
    case notPixelAligned
    case displayMismatch
    case scaleMismatch
    case unrepresentablePixelSize

    var errorDescription: String? {
        switch self {
        case .invalidDisplay: "画面の寸法または倍率を確認できません。"
        case .invalidPoint: "選択位置を確認できません。"
        case .startOutsideDisplay: "選択は一つの画面内から始めてください。"
        case .endOutsideDisplay: "一つの画面内で離してください。選び直せます。"
        case .emptySelection: "1ピクセル以上の範囲を選んでください。"
        case .selectionOutsideDisplay: "選択範囲が画面の外にあります。"
        case .notPixelAligned: "選択範囲と画像のピクセル境界が一致しません。"
        case .displayMismatch: "選択開始時の画面と一致しません。"
        case .scaleMismatch: "選択開始時と取得時の画面倍率が一致しません。"
        case .unrepresentablePixelSize: "ピクセル寸法を安全に計算できません。"
        }
    }
}

enum RegionGeometry {
    /// Only floating-point representation error is tolerated; this is not a resampling threshold.
    private static let pixelTolerance: CGFloat = 0.000_000_1

    /// Drawing may clamp to the start display; confirmation must still inspect the raw mouse-up point.
    static func dragRect(display: CaptureDisplaySnapshot, start: CGPoint, current: CGPoint) throws -> CGRect {
        try validatePoint(start)
        try validatePoint(current)
        guard containsIncludingBoundary(display.frame, point: start) else {
            throw RegionGeometryError.startOutsideDisplay
        }
        let end = CGPoint(x: min(max(current.x, display.frame.minX), display.frame.maxX),
                          y: min(max(current.y, display.frame.minY), display.frame.maxY))
        let first = try snappedPoint(start, display: display)
        let last = try snappedPoint(end, display: display)
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                      width: abs(last.x - first.x), height: abs(last.y - first.y))
    }

    static func finishDrag(display: CaptureDisplaySnapshot, start: CGPoint, end: CGPoint) throws -> CaptureSelection {
        try validatePoint(end)
        // Do not silently turn an out-of-display release into a clipped capture.
        guard containsIncludingBoundary(display.frame, point: end) else {
            throw RegionGeometryError.endOutsideDisplay
        }
        let rect = try dragRect(display: display, start: start, current: end)
        return try CaptureSelection(display: display, rect: rect)
    }

    static func plan(selection: CaptureSelection, filterScale: CGFloat) throws -> RegionCapturePlan {
        guard filterScale.isFinite, filterScale > 0,
              abs(filterScale - selection.display.scale) <= pixelTolerance else {
            throw RegionGeometryError.scaleMismatch
        }
        try validateSelection(display: selection.display, rect: selection.rect)
        let rect = selection.rect
        let frame = selection.display.frame
        let scale = selection.display.scale
        let left = try alignedPixelIndex(rect.minX - frame.minX, scale: scale)
        let right = try alignedPixelIndex(rect.maxX - frame.minX, scale: scale)
        let bottom = try alignedPixelIndex(rect.minY - frame.minY, scale: scale)
        let top = try alignedPixelIndex(rect.maxY - frame.minY, scale: scale)
        return RegionCapturePlan(sourceRect: CGRect(x: rect.minX - frame.minX,
                                                    y: frame.maxY - rect.maxY,
                                                    width: rect.width, height: rect.height),
                                 pixelWidth: right - left, pixelHeight: top - bottom)
    }

    /// The first arrow creates a centered selection; subsequent arrows adjust it.
    static func adjusting(selection: CaptureSelection?, display: CaptureDisplaySnapshot,
                          direction: RegionArrowDirection, resize: Bool = false,
                          accelerated: Bool = false) throws -> CaptureSelection {
        guard let selection else { return try initialSelection(display: display) }
        guard selection.display == display else { throw RegionGeometryError.displayMismatch }
        let extents = try pixelExtents(frame: display.frame, scale: display.scale)
        var left = try alignedPixelIndex(selection.rect.minX - display.frame.minX, scale: display.scale)
        var right = try alignedPixelIndex(selection.rect.maxX - display.frame.minX, scale: display.scale)
        var bottom = try alignedPixelIndex(selection.rect.minY - display.frame.minY, scale: display.scale)
        var top = try alignedPixelIndex(selection.rect.maxY - display.frame.minY, scale: display.scale)
        let step = pixelStep(points: accelerated ? 10 : 1, scale: display.scale,
                             maximum: max(extents.width, extents.height))
        if resize {
            // Keep the lower-left anchor. Shift-left/down shrink; Shift-right/up enlarge.
            switch direction {
            case .left: right -= min(step, right - left - 1)
            case .right: right += min(step, extents.width - right)
            case .down: top -= min(step, top - bottom - 1)
            case .up: top += min(step, extents.height - top)
            }
        } else {
            switch direction {
            case .left:
                let distance = min(step, left)
                left -= distance; right -= distance
            case .right:
                let distance = min(step, extents.width - right)
                left += distance; right += distance
            case .down:
                let distance = min(step, bottom)
                bottom -= distance; top -= distance
            case .up:
                let distance = min(step, extents.height - top)
                bottom += distance; top += distance
            }
        }
        return try selectionFromPixels(display: display, left: left, right: right, bottom: bottom, top: top)
    }

    static func initialSelection(display: CaptureDisplaySnapshot) throws -> CaptureSelection {
        let extents = try pixelExtents(frame: display.frame, scale: display.scale)
        let width = pixelStep(points: 320, scale: display.scale, maximum: extents.width)
        let height = pixelStep(points: 200, scale: display.scale, maximum: extents.height)
        let left = (extents.width - width) / 2
        let bottom = (extents.height - height) / 2
        return try selectionFromPixels(display: display, left: left, right: left + width,
                                        bottom: bottom, top: bottom + height)
    }

    fileprivate static func pixelExtents(frame: CGRect, scale: CGFloat) throws -> (width: Int, height: Int) {
        guard finiteRect(frame), frame.size.width > 0, frame.size.height > 0,
              scale.isFinite, scale > 0 else { throw RegionGeometryError.invalidDisplay }
        do {
            let width = try alignedPixelIndex(frame.size.width, scale: scale)
            let height = try alignedPixelIndex(frame.size.height, scale: scale)
            guard width > 0, height > 0 else { throw RegionGeometryError.invalidDisplay }
            return (width, height)
        } catch RegionGeometryError.notPixelAligned {
            throw RegionGeometryError.invalidDisplay
        }
    }

    fileprivate static func validateSelection(display: CaptureDisplaySnapshot, rect: CGRect) throws {
        guard finiteRect(rect) else { throw RegionGeometryError.invalidPoint }
        guard rect.size.width > 0, rect.size.height > 0 else { throw RegionGeometryError.emptySelection }
        guard rect.minX >= display.frame.minX, rect.minY >= display.frame.minY,
              rect.maxX <= display.frame.maxX, rect.maxY <= display.frame.maxY else {
            throw RegionGeometryError.selectionOutsideDisplay
        }
        let left = try alignedPixelIndex(rect.minX - display.frame.minX, scale: display.scale)
        let right = try alignedPixelIndex(rect.maxX - display.frame.minX, scale: display.scale)
        let bottom = try alignedPixelIndex(rect.minY - display.frame.minY, scale: display.scale)
        let top = try alignedPixelIndex(rect.maxY - display.frame.minY, scale: display.scale)
        guard right > left, top > bottom else { throw RegionGeometryError.emptySelection }
    }

    private static func selectionFromPixels(display: CaptureDisplaySnapshot, left: Int, right: Int,
                                            bottom: Int, top: Int) throws -> CaptureSelection {
        let x = coordinate(index: left, origin: display.frame.minX, scale: display.scale)
        let y = coordinate(index: bottom, origin: display.frame.minY, scale: display.scale)
        let maxX = coordinate(index: right, origin: display.frame.minX, scale: display.scale)
        let maxY = coordinate(index: top, origin: display.frame.minY, scale: display.scale)
        return try CaptureSelection(display: display,
                                    rect: CGRect(x: x, y: y, width: maxX - x, height: maxY - y))
    }

    private static func snappedPoint(_ point: CGPoint, display: CaptureDisplaySnapshot) throws -> CGPoint {
        let x = ((point.x - display.frame.minX) * display.scale).rounded(.toNearestOrAwayFromZero)
        let y = ((point.y - display.frame.minY) * display.scale).rounded(.toNearestOrAwayFromZero)
        guard x.isFinite, y.isFinite else { throw RegionGeometryError.unrepresentablePixelSize }
        return CGPoint(x: display.frame.minX + x / display.scale,
                       y: display.frame.minY + y / display.scale)
    }

    private static func alignedPixelIndex(_ points: CGFloat, scale: CGFloat) throws -> Int {
        let pixels = points * scale
        guard pixels.isFinite, pixels >= 0, pixels < CGFloat(Int.max) else {
            throw RegionGeometryError.unrepresentablePixelSize
        }
        let integer = pixels.rounded(.toNearestOrAwayFromZero)
        guard abs(pixels - integer) <= pixelTolerance else { throw RegionGeometryError.notPixelAligned }
        return Int(integer)
    }

    private static func pixelStep(points: CGFloat, scale: CGFloat, maximum: Int) -> Int {
        let pixels = (points * scale).rounded(.toNearestOrAwayFromZero)
        if !pixels.isFinite || pixels >= CGFloat(maximum) { return maximum }
        return max(1, Int(pixels))
    }

    private static func coordinate(index: Int, origin: CGFloat, scale: CGFloat) -> CGFloat {
        origin + CGFloat(index) / scale
    }

    private static func validatePoint(_ point: CGPoint) throws {
        guard point.x.isFinite, point.y.isFinite else { throw RegionGeometryError.invalidPoint }
    }

    private static func containsIncludingBoundary(_ rect: CGRect, point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    private static func finiteRect(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
    }
}
