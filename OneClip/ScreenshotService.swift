import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Fixed codes only: framework errors and screen contents never become diagnostics.
enum ScreenshotError: String, Error, Sendable {
    case busy
    case cancelled
    case invalidated
    case permissionRequired
    case protectedDataUnavailable
    case displayChanged
    case invalidSelection
    case practiceUnavailable
    case settingsUnavailable
    case selfApplicationMissing
    case shareableContentUnavailable
    case captureFailed
    case unexpectedImageSize
    case unexpectedImageFormat
    case imageLimitExceeded
}

/// Immutable SCK metadata used to admit exactly one explicitly scoped settings window.
/// Titles and other application contents are deliberately not part of the match.
struct SettingsCaptureWindowMetadata {
    let windowID: CGWindowID
    let processID: Int32?
    let frame: CGRect
    let isOnScreen: Bool
}

struct SettingsCaptureWindowIdentity {
    let windowID: CGWindowID
    let processID: Int32
    let quartzFrame: CGRect

    func matchingIndex(in windows: [SettingsCaptureWindowMetadata]) throws -> Int {
        guard windowID > 0, processID > 0,
              quartzFrame.width > 0, quartzFrame.height > 0,
              [quartzFrame.minX, quartzFrame.minY, quartzFrame.width, quartzFrame.height].allSatisfy(\.isFinite) else {
            throw ScreenshotError.settingsUnavailable
        }
        let matches = windows.indices.filter {
            windows[$0].windowID == windowID
        }
        guard matches.count == 1, let index = matches.first,
              windows[index].processID == processID, windows[index].isOnScreen else {
            throw ScreenshotError.settingsUnavailable
        }
        let actual = windows[index].frame
        let differences = [actual.minX - quartzFrame.minX, actual.minY - quartzFrame.minY,
                           actual.width - quartzFrame.width, actual.height - quartzFrame.height]
        guard differences.allSatisfy({ $0.isFinite && abs($0) <= 0.000_001 }) else {
            throw ScreenshotError.settingsUnavailable
        }
        return index
    }
}

/// A capability for the actual settings NSWindow supplied by its owner for one selection.
/// Retaining the object does not authorize a closed/replaced window or another window with its ID.
@MainActor
struct SettingsCaptureScope {
    private let window: NSWindow
    let windowID: CGWindowID
    let frame: CGRect
    private let screen: CaptureDisplaySnapshot
    private let ownerStillValid: @MainActor () -> Bool
    private let identity: SettingsCaptureWindowIdentity

    init(window: NSWindow, validate: @escaping @MainActor () -> Bool) throws {
        guard window.windowNumber > 0, window.windowNumber <= Int(UInt32.max),
              let screen = window.screen else { throw ScreenshotError.settingsUnavailable }
        self.window = window
        self.windowID = CGWindowID(window.windowNumber)
        self.frame = window.frame
        self.screen = try ScreenshotService.snapshot(for: screen)
        self.ownerStillValid = validate
        self.identity = SettingsCaptureWindowIdentity(windowID: self.windowID,
            processID: ProcessInfo.processInfo.processIdentifier,
            quartzFrame: try ScreenshotService.quartzFrame(for: window.frame))
        guard self.validate() else { throw ScreenshotError.settingsUnavailable }
    }

    func validate() -> Bool {
        guard ownerStillValid(), window.isVisible, !window.isMiniaturized, window.isOnActiveSpace,
              window.windowNumber == Int(windowID), window.frame == frame,
              window.attachedSheet == nil, window.childWindows?.isEmpty ?? true,
              NSApp.windows.contains(where: { $0 === window }),
              ScreenshotService.currentDisplayMatches(screen),
              let currentScreen = window.screen,
              let current = try? ScreenshotService.snapshot(for: currentScreen) else { return false }
        return current.id == screen.id && current.frame == screen.frame && current.scale == screen.scale
    }

    fileprivate func matchingWindow(in windows: [SCWindow]) throws -> SCWindow {
        guard validate() else { throw ScreenshotError.settingsUnavailable }
        let metadata = windows.map {
            SettingsCaptureWindowMetadata(windowID: $0.windowID, processID: $0.owningApplication?.processID,
                                          frame: $0.frame, isOnScreen: $0.isOnScreen)
        }
        return windows[try identity.matchingIndex(in: metadata)]
    }
}

#if DEBUG
/// A capability for one explicitly displayed synthetic window, never an arbitrary window ID.
@MainActor
struct PracticeCaptureScope {
    let window: NSWindow
    let windowID: CGWindowID
    let frame: CGRect
    let display: CaptureDisplaySnapshot
    let validate: @MainActor () -> Bool

    init(window: NSWindow, display: CaptureDisplaySnapshot,
         validate: @escaping @MainActor () -> Bool) throws {
        guard window.windowNumber > 0, window.windowNumber <= Int(UInt32.max),
              window.isVisible, !window.isMiniaturized,
              window.attachedSheet == nil, window.childWindows?.isEmpty ?? true,
              display.frame.contains(window.frame),
              ScreenshotService.currentDisplayMatches(display), validate() else {
            throw ScreenshotError.practiceUnavailable
        }
        self.window = window
        self.windowID = CGWindowID(window.windowNumber)
        self.frame = window.frame
        self.display = display
        self.validate = validate
    }
}
#endif

/// Only immutable metrics cross the acquisition boundary; this context owns no image buffers.
/// Extra buffers must exclude the existing source set and candidate already counted here.
struct CaptureImageBudgetContext: Sendable {
    let existing: [M0ImageMetrics]
    let replacementIndex: Int?
    let retainingExtraBytes: Int

    init(existing: [M0ImageMetrics] = [], replacementIndex: Int? = nil, retainingExtraBytes: Int = 0) {
        self.existing = existing
        self.replacementIndex = replacementIndex
        self.retainingExtraBytes = retainingExtraBytes
    }

    func validateCandidate(_ candidate: M0ImageMetrics,
                           limits: M0ImageLimits = .init()) throws -> M0CompositionPlan {
        try M0ImageComposer.validateChange(existing: existing, replacementIndex: replacementIndex,
                                          candidate: candidate, limits: limits,
                                          retainingExtraBytes: retainingExtraBytes)
    }
}

@MainActor
struct SingleCaptureRequest {
    let selection: CaptureSelection
    let operationID: UUID
    let budget: CaptureImageBudgetContext
    let settings: SettingsCaptureScope?
    let securityTrace: CaptureSecurityTrace
    let traceMode: CaptureSecurityTrace.Mode
    #if DEBUG
    let practice: PracticeCaptureScope?

    init(selection: CaptureSelection, operationID: UUID, budget: CaptureImageBudgetContext = .init(),
         settings: SettingsCaptureScope? = nil,
         practice: PracticeCaptureScope? = nil,
         securityTrace: CaptureSecurityTrace = .disabled, traceMode: CaptureSecurityTrace.Mode = .single) {
        self.selection = selection
        self.operationID = operationID
        self.budget = budget
        self.settings = settings
        self.practice = practice
        self.securityTrace = securityTrace; self.traceMode = traceMode
    }
    #else
    init(selection: CaptureSelection, operationID: UUID, budget: CaptureImageBudgetContext = .init(),
         settings: SettingsCaptureScope? = nil,
         securityTrace: CaptureSecurityTrace = .disabled, traceMode: CaptureSecurityTrace.Mode = .single) {
        self.selection = selection
        self.operationID = operationID
        self.budget = budget
        self.settings = settings
        self.securityTrace = securityTrace; self.traceMode = traceMode
    }
    #endif
}

@MainActor
protocol ScreenshotCapturing {
    func capture(_ request: SingleCaptureRequest,
                 isCurrent: @escaping @MainActor () -> Bool) async throws -> M0ImageAsset
}

/// Selection UI visibility is the caller's responsibility; app exclusion is independent of it.
@MainActor
final class ScreenshotService: ScreenshotCapturing {
    private let limits: M0ImageLimits
    private var activeOperationID: UUID?
    #if DEBUG
    /// One in-memory successful service interval. No image, request, timestamp or history is retained.
    /// Includes metadata/safety checks, SCK waiting and await resumption; excludes selection/PNG/write.
    private(set) static var lastCaptureDurationNanoseconds: UInt64?
    #endif

    init(limits: M0ImageLimits = .init()) {
        self.limits = limits
    }

    static func snapshot(for screen: NSScreen) throws -> CaptureDisplaySnapshot {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              number.uint32Value != 0 else { throw ScreenshotError.displayChanged }
        do {
            return try CaptureDisplaySnapshot(id: number.uint32Value, frame: screen.frame,
                                              scale: screen.backingScaleFactor)
        } catch {
            throw ScreenshotError.displayChanged
        }
    }

    static func currentDisplayMatches(_ expected: CaptureDisplaySnapshot) -> Bool {
        guard CGDisplayIsActive(expected.id) != 0, CGDisplayIsOnline(expected.id) != 0,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == expected.id
              }), let current = try? snapshot(for: screen) else { return false }
        return current.id == expected.id && current.frame == expected.frame && current.scale == expected.scale
    }

    func capture(_ request: SingleCaptureRequest,
                 isCurrent: @escaping @MainActor () -> Bool) async throws -> M0ImageAsset {
        guard activeOperationID == nil else { throw ScreenshotError.busy }
        #if DEBUG
        Self.lastCaptureDurationNanoseconds = nil
        let captureStarted = DispatchTime.now().uptimeNanoseconds
        #endif
        activeOperationID = request.operationID
        // Cancellation invalidates adoption, but keeps the slot occupied until SCK really returns.
        defer { activeOperationID = nil }
        try validate(request, isCurrent: isCurrent)
        let planned = try capturePlan(selection: request.selection, scale: request.selection.display.scale)
        try validateBudget(width: planned.pixelWidth, height: planned.pixelHeight,
                           bytesPerRow: minimumStride(width: planned.pixelWidth),
                           scale: request.selection.display.scale, context: request.budget)

        let content: SCShareableContent
        do {
            // Include off-screen metadata so a hidden capture UI does not remove our application.
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            try validate(request, isCurrent: isCurrent)
            throw ScreenshotError.shareableContentUnavailable
        }
        try validate(request, isCurrent: isCurrent)
        let snapshot = request.selection.display
        guard let display = content.displays.first(where: { $0.displayID == snapshot.id }),
              Self.sameFrame(display.frame, CGDisplayBounds(snapshot.id)),
              CGFloat(display.width) == snapshot.frame.width,
              CGFloat(display.height) == snapshot.frame.height else { throw ScreenshotError.displayChanged }
        let ownApplications = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        guard ownApplications.count == 1, let ownApplication = ownApplications.first else {
            throw ScreenshotError.selfApplicationMissing
        }

        var exceptions: [SCWindow] = []
        if let scope = request.settings {
            exceptions = [try scope.matchingWindow(in: content.windows)]
        }
        #if DEBUG
        if let scope = request.practice {
            // Synthetic practice and settings scopes cannot broaden one another's allowance.
            guard request.settings == nil else { throw ScreenshotError.settingsUnavailable }
            let matches = content.windows.filter {
                $0.windowID == scope.windowID &&
                $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
            }
            guard matches.count == 1, let window = matches.first, window.isOnScreen,
                  Self.sameFrame(window.frame, try Self.quartzFrame(for: scope.frame)) else {
                throw ScreenshotError.practiceUnavailable
            }
            exceptions = [window]
        }
        #endif
        // Failures never switch to an empty excluded-app list or a different display/window.
        let filter = SCContentFilter(display: display, excludingApplications: [ownApplication],
                                     exceptingWindows: exceptions)
        let filterScale = CGFloat(filter.pointPixelScale)
        guard filterScale.isFinite, abs(filterScale - snapshot.scale) <= 0.000_001 else {
            throw ScreenshotError.displayChanged
        }
        let plan = try capturePlan(selection: request.selection, scale: filterScale)
        try validateBudget(width: plan.pixelWidth, height: plan.pixelHeight,
                           bytesPerRow: minimumStride(width: plan.pixelWidth), scale: filterScale,
                           context: request.budget)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = plan.sourceRect
        configuration.width = plan.pixelWidth
        configuration.height = plan.pixelHeight
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsDisplay = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        if request.settings != nil {
            if #available(macOS 14.2, *) { configuration.includeChildWindows = false }
        }
        #if DEBUG
        if request.practice != nil {
            if #available(macOS 14.2, *) { configuration.includeChildWindows = false }
        }
        #endif
        // New SCStreamConfiguration defaults to SDR. No HDR preset or post-14 API is needed.
        try validate(request, isCurrent: isCurrent)
        let scale = Double(filterScale)
        let asset: M0ImageAsset
        let trace = request.securityTrace
        let traceMode = request.traceMode
        do {
            asset = try await withCheckedThrowingContinuation { continuation in
                trace.record(.captureRequested, mode: traceMode, phase: .capturing)
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                    trace.record(.captureCallback, mode: traceMode, phase: .capturing,
                                 outcome: error == nil && image != nil ? .success : .failure)
                    guard error == nil, let image else {
                        continuation.resume(throwing: ScreenshotError.captureFailed)
                        return
                    }
                    // CGImage is immutable; no AppKit or mutable service state crosses this callback.
                    continuation.resume(returning: M0ImageAsset(image: image, scale: scale))
                }
            }
        } catch {
            trace.record(.captureReturned, mode: traceMode, phase: .capturing, outcome: .failure)
            try validate(request, isCurrent: isCurrent)
            throw ScreenshotError.captureFailed
        }
        trace.record(.captureReturned, mode: traceMode, phase: .capturing, outcome: .success)
        try validate(request, isCurrent: isCurrent)
        guard asset.image.width == plan.pixelWidth, asset.image.height == plan.pixelHeight else {
            throw ScreenshotError.unexpectedImageSize
        }
        guard asset.image.bitsPerComponent == 8, asset.image.bitsPerPixel == 32,
              !asset.image.bitmapInfo.contains(.floatComponents),
              asset.image.colorSpace?.model == .rgb,
              asset.image.colorSpace?.name == CGColorSpace.sRGB else {
            throw ScreenshotError.unexpectedImageFormat
        }
        try validateBudget(width: asset.image.width, height: asset.image.height,
                           bytesPerRow: asset.image.bytesPerRow, scale: filterScale, context: request.budget)
        #if DEBUG
        Self.lastCaptureDurationNanoseconds = DispatchTime.now().uptimeNanoseconds - captureStarted
        #endif
        return asset
    }

    private func validate(_ request: SingleCaptureRequest,
                          isCurrent: @MainActor () -> Bool) throws {
        guard !Task.isCancelled else { throw ScreenshotError.cancelled }
        guard isCurrent() else { throw ScreenshotError.invalidated }
        guard NSApp.isProtectedDataAvailable else { throw ScreenshotError.protectedDataUnavailable }
        guard CGPreflightScreenCaptureAccess() else { throw ScreenshotError.permissionRequired }
        guard Self.currentDisplayMatches(request.selection.display) else { throw ScreenshotError.displayChanged }
        if let scope = request.settings {
            guard scope.validate(), scope.frame.intersects(request.selection.rect) else {
                throw ScreenshotError.settingsUnavailable
            }
        }
        #if DEBUG
        if let scope = request.practice {
            guard scope.validate(), scope.window.isVisible, !scope.window.isMiniaturized,
                  scope.window.windowNumber == Int(scope.windowID), scope.window.frame == scope.frame,
                  scope.window.attachedSheet == nil, scope.window.childWindows?.isEmpty ?? true,
                  NSApp.windows.contains(where: { $0 === scope.window }),
                  scope.display.id == request.selection.display.id,
                  scope.display.frame == request.selection.display.frame,
                  scope.display.scale == request.selection.display.scale,
                  scope.frame.contains(request.selection.rect),
                  Self.currentDisplayMatches(scope.display),
                  let screen = scope.window.screen,
                  (try? Self.snapshot(for: screen).id) == scope.display.id else {
                throw ScreenshotError.practiceUnavailable
            }
        }
        #endif
    }

    private func capturePlan(selection: CaptureSelection, scale: CGFloat) throws -> RegionCapturePlan {
        do { return try RegionGeometry.plan(selection: selection, filterScale: scale) }
        catch { throw ScreenshotError.invalidSelection }
    }

    private func minimumStride(width: Int) throws -> Int {
        let value = width.multipliedReportingOverflow(by: 4)
        guard width > 0, !value.overflow else { throw ScreenshotError.imageLimitExceeded }
        return value.partialValue
    }

    private func validateBudget(width: Int, height: Int, bytesPerRow: Int, scale: CGFloat,
                                context: CaptureImageBudgetContext) throws {
        guard bytesPerRow >= (try minimumStride(width: width)) else {
            throw ScreenshotError.unexpectedImageFormat
        }
        let metrics = M0ImageMetrics(width: width, height: height, bytesPerRow: bytesPerRow,
                                     scale: Double(scale))
        do {
            // Includes existing sources, replacement's old source, caller-held completed/PNG/UI
            // buffers, and a second candidate-sized acquisition/normalization reserve.
            _ = try context.validateCandidate(metrics, limits: limits)
        } catch {
            throw ScreenshotError.imageLimitExceeded
        }
    }

    private static func sameFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let values = [lhs.minX - rhs.minX, lhs.minY - rhs.minY,
                      lhs.width - rhs.width, lhs.height - rhs.height]
        return values.allSatisfy { $0.isFinite && abs($0) <= 0.000_001 }
    }

    static func quartzFrame(for appKitFrame: CGRect) throws -> CGRect {
        guard let primary = NSScreen.screens.first else { throw ScreenshotError.displayChanged }
        return CGRect(x: appKitFrame.minX, y: primary.frame.maxY - appKitFrame.maxY,
                      width: appKitFrame.width, height: appKitFrame.height)
    }
}
