import AppKit
import CoreGraphics
import CryptoKit
import Foundation

/// Opt-in test executable only. Help, argument guards and self-tests never initialize NSApp,
/// query permission, subscribe, capture, create a board or write a report. OS operations are manual.
@main
struct SecurityRuntimeTrial {
    @MainActor
    static func main() {
        do {
            switch try RuntimeTrialArguments.parse(Array(CommandLine.arguments.dropFirst())) {
            case .help: print(RuntimeTrialArguments.help)
            case .selfTest:
                try RuntimeTrialPolicy.selfTest()
                print("PASS RUNTIME-POLICY CLI_AND_DECISION_SYNTHETIC_ONLY EXPLICIT_RECOVERY_TRACE_REQUIRED")
            case .run(let config):
                guard CGPreflightScreenCaptureAccess() else { print("BLOCKED PERMISSION_NOT_CONFIRMED NO_REQUEST"); exit(2) }
                let fixture = try RuntimeFixtureBinding(config: config)
                try config.createFreshOutputDirectory()
                let application = NSApplication.shared
                guard application.setActivationPolicy(.accessory) else { throw RuntimeTrialFailure.blocked }
                let controller = RuntimeTrialController(config: config, fixture: fixture)
                application.delegate = controller
                withExtendedLifetime(controller) { application.run() }
                exit(controller.exitCode)
            }
        } catch {
            // Never print associated values, paths, process names, OS errors or arguments.
            print("BLOCKED RUNTIME_ARGUMENTS_OR_PREREQUISITE")
            exit(2)
        }
    }
}

private enum RuntimeTrialFailure: Error { case arguments, blocked, policy }

private struct RuntimeTrialArguments {
    enum Command { case help, selfTest, run(Configuration) }
    enum Mode: String, CaseIterable { case single, collection }
    enum Stage: String, CaseIterable { case selecting, sck, encoding, retained }
    enum Transition: String, CaseIterable { case menuLock = "menu-lock", keyLock = "key-lock", systemSleep = "system-sleep", displaySleep = "display-sleep" }
    struct Configuration {
        let mode: Mode
        let stage: Stage
        let transition: Transition
        let output: URL
        let fixturePID: Int32
        let fixtureExecutable: URL
        let fixtureSHA256: String
        var traceMode: CaptureSecurityTrace.Mode { mode == .single ? .single : .collection }
        func createFreshOutputDirectory() throws {
            guard !FileManager.default.fileExists(atPath: output.path),
                  !output.lastPathComponent.isEmpty, output.lastPathComponent != ".", output.lastPathComponent != ".." else {
                throw RuntimeTrialFailure.blocked
            }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
    }
    static let help = """
    SecurityRuntimeTrial: opt-in synthetic-fixture OS-transition trial; default does nothing.
      --help
      --self-test                 pure CLI/decision tests; no OS, board or files
      --run --mode single|collection --stage selecting|sck|encoding|retained
        --transition menu-lock|key-lock|system-sleep|display-sleep
        --output-dir NEW_ABSOLUTE_DIRECTORY
        --fixture-pid PARENT_LAUNCHED_M4FIXTURE_PID
        --fixture-executable ABSOLUTE_M4FIXTURE_EXECUTABLE
        --fixture-sha256 APPROVED_EXECUTABLE_SHA256
        --parent-fresh-fixture yes
    Parent must freshly launch the existing M4Fixture and supply its exact PID/path/hash.
    No process-name search, TCC request/change, lock/sleep command, general board or image file.
    One trial/one manual OS operation; 15-minute total bound. Parent owns the cumulative ledger
    (3 operations/15-minute session; at most 5 trials per cell).
    Invalidation alone remains NOT_ESTABLISHED. A second explicit HUD action must establish
    fresh SCK/PNG/named-board success and actual worker return before a full-cell limited PASS.
    Archive and product image-view paths are not exercised by this executable.
    Named board only. Single retained is real SCK/PNG plus forced writer rejection (mixed test).
    SCK/encoding use actual intervals without artificial holds; no overlap = NOT_ESTABLISHED.
    """

    static func parse(_ arguments: [String]) throws -> Command {
        if arguments.isEmpty || arguments == ["--help"] { return .help }
        if arguments == ["--self-test"] { return .selfTest }
        guard arguments.first == "--run", arguments.count == 17 else { throw RuntimeTrialFailure.arguments }
        let allowed: Set<String> = ["--mode", "--stage", "--transition", "--output-dir", "--fixture-pid", "--fixture-executable", "--fixture-sha256", "--parent-fresh-fixture"]
        var values: [String: String] = [:]
        for index in stride(from: 1, to: arguments.count, by: 2) {
            let key = arguments[index]
            guard allowed.contains(key), values[key] == nil else { throw RuntimeTrialFailure.arguments }
            values[key] = arguments[index + 1]
        }
        guard let mode = values["--mode"].flatMap(Mode.init(rawValue:)),
              let stage = values["--stage"].flatMap(Stage.init(rawValue:)),
              let transition = values["--transition"].flatMap(Transition.init(rawValue:)),
              let output = values["--output-dir"], output.hasPrefix("/"),
              let executable = values["--fixture-executable"], executable.hasPrefix("/"),
              let pidText = values["--fixture-pid"], let pid = Int32(pidText), pid > 0,
              let hash = values["--fixture-sha256"], hash.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              values["--parent-fresh-fixture"] == "yes" else { throw RuntimeTrialFailure.arguments }
        return .run(Configuration(mode: mode, stage: stage, transition: transition,
            output: URL(fileURLWithPath: output), fixturePID: pid,
            fixtureExecutable: URL(fileURLWithPath: executable), fixtureSHA256: hash))
    }
}

/// Values only, also used by pure policy tests. Runtime window titles are never accessed.
private struct RuntimeFixtureWindow: Equatable {
    let id: UInt32
    let pid: Int32
    let frame: CGRect
    let onScreen: Bool
    let opaque: Bool
    let layer: Int
    func admits(_ current: RuntimeFixtureWindow, rect: CGRect) -> Bool {
        id > 0 && pid > 0 && self == current && onScreen && opaque && layer == 0
            && frame.width > 0 && frame.height > 0
            && [frame.minX, frame.minY, frame.width, frame.height, rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0 && frame.contains(rect)
    }
}

private enum RuntimeFixtureSelectionPolicy {
    static func admits(expected: CaptureSelection, requested: CaptureSelection,
                       currentDisplay: CaptureDisplaySnapshot, foreignOccludes: Bool) -> Bool {
        expected.display == currentDisplay && requested.display == expected.display
            && requested.rect == expected.rect && !foreignOccludes
    }
}

@MainActor
private final class RuntimeFixtureBinding {
    private let application: NSRunningApplication
    private let executable: URL
    private let window: RuntimeFixtureWindow
    let selection: CaptureSelection

    init(config: RuntimeTrialArguments.Configuration) throws {
        let executable = config.fixtureExecutable.standardizedFileURL.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
        guard config.fixturePID != ProcessInfo.processInfo.processIdentifier,
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 128 * 1_024 * 1_024,
              executable.lastPathComponent == "M4Fixture",
              let application = NSRunningApplication(processIdentifier: config.fixturePID), !application.isTerminated,
              application.executableURL?.standardizedFileURL.resolvingSymlinksInPath() == executable else {
            throw RuntimeTrialFailure.blocked
        }
        let data = try Data(contentsOf: executable, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == config.fixtureSHA256 else { throw RuntimeTrialFailure.blocked }
        let windows = try Self.windows()
        let matches = windows.filter { $0.pid == config.fixturePID && $0.layer == 0 }
        guard matches.count == 1, let window = matches.first, window.onScreen, window.opaque,
              let primary = NSScreen.screens.first else { throw RuntimeTrialFailure.blocked }
        let appKitFrame = CGRect(x: window.frame.minX, y: primary.frame.maxY - window.frame.maxY,
                                 width: window.frame.width, height: window.frame.height)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitFrame) }) else { throw RuntimeTrialFailure.blocked }
        let display = try ScreenshotService.snapshot(for: screen)
        let rect = appKitFrame.insetBy(dx: 64, dy: 96)
        selection = try CaptureSelection(display: display, rect: rect)
        self.application = application; self.executable = executable; self.window = window
        guard validate(selection) else { throw RuntimeTrialFailure.blocked }
    }

    func validate(_ selection: CaptureSelection) -> Bool {
        guard !application.isTerminated,
              application.executableURL?.standardizedFileURL.resolvingSymlinksInPath() == executable,
              ScreenshotService.currentDisplayMatches(self.selection.display),
              selection.display == self.selection.display, selection.rect == self.selection.rect,
              let rect = try? ScreenshotService.quartzFrame(for: selection.rect),
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == self.selection.display.id
              }), let currentDisplay = try? ScreenshotService.snapshot(for: screen),
              let windows = try? Self.windows(), let index = windows.firstIndex(where: { $0.id == window.id }),
              window.admits(windows[index], rect: rect) else { return false }
        // CGWindowList is front-to-back. Our own UI is excluded by ScreenshotService's filter.
        // Any observed foreign window above the fixture intersecting this crop blocks acquisition.
        let occluded = windows[..<index].contains { $0.pid != ProcessInfo.processInfo.processIdentifier && $0.frame.intersects(rect) }
        return RuntimeFixtureSelectionPolicy.admits(expected: self.selection, requested: selection,
            currentDisplay: currentDisplay, foreignOccludes: occluded)
    }

    private static func windows() throws -> [RuntimeFixtureWindow] {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw RuntimeTrialFailure.blocked
        }
        return try rows.map { row in
            guard let id = row[kCGWindowNumber as String] as? NSNumber,
                  let pid = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  let alpha = row[kCGWindowAlpha as String] as? NSNumber,
                  let layer = row[kCGWindowLayer as String] as? NSNumber,
                  let onScreen = row[kCGWindowIsOnscreen as String] as? Bool,
                  id.int64Value > 0, id.int64Value <= Int64(UInt32.max),
                  pid.int64Value > 0, pid.int64Value <= Int64(Int32.max),
                  [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
                  frame.width > 0, frame.height > 0, alpha.doubleValue.isFinite,
                  (0...1).contains(alpha.doubleValue) else { throw RuntimeTrialFailure.blocked }
            return RuntimeFixtureWindow(id: id.uint32Value, pid: pid.int32Value, frame: frame,
                onScreen: onScreen, opaque: alpha.doubleValue == 1, layer: layer.intValue)
        }
    }
}

@MainActor
private final class RuntimeFixtureCapturer: ScreenshotCapturing {
    private let fixture: RuntimeFixtureBinding
    private let service = ScreenshotService()
    init(fixture: RuntimeFixtureBinding) { self.fixture = fixture }
    func capture(_ request: SingleCaptureRequest, isCurrent: @escaping @MainActor () -> Bool) async throws -> M0ImageAsset {
        guard fixture.validate(request.selection), request.settings == nil else { throw ScreenshotError.invalidSelection }
        let result = try await service.capture(request) { [fixture] in fixture.validate(request.selection) && isCurrent() }
        guard fixture.validate(request.selection), isCurrent() else { throw ScreenshotError.invalidated }
        return result
    }
}

@MainActor
private final class RuntimeNamedWriter: CaptureClipboardWriting, M0ClipboardProbeDestination {
    private let board = NSPasteboard(name: .init("local.OneClip.SecurityRuntimeTrial.\(UUID().uuidString)"))
    private let trace: CaptureSecurityTrace
    private let mode: CaptureSecurityTrace.Mode
    private var forcedReject: Bool
    var changeCount: Int { board.changeCount }
    init(trace: CaptureSecurityTrace, mode: CaptureSecurityTrace.Mode, forcedReject: Bool) {
        self.trace = trace; self.mode = mode; self.forcedReject = forcedReject
    }
    func writePNG(_ data: Data, expectedChangeCount: Int) -> M0ClipboardProbe.Outcome {
        M0ClipboardProbe.writePNG(data, to: self, expectedChangeCount: expectedChangeCount,
            securityTrace: trace, traceMode: mode, itemFactory: M0ClipboardProbe.makePNGItem)
    }
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int { board.prepareForNewContents(with: options) }
    func write(_ item: NSPasteboardItem) -> Bool { forcedReject ? false : board.writeObjects([item]) }
    func allowRecoveryWrite() { forcedReject = false }
    func close() { board.clearContents(); board.releaseGlobally() }
}

@MainActor
private final class RuntimeTrialInterface: CollectionCaptureInterface {
    let native: NativeCaptureInterface
    let trace: CaptureSecurityTrace
    let mode: CaptureSecurityTrace.Mode
    var selected: (@MainActor (CaptureSelection) -> Void)?
    var isOneClipActive: Bool { false }
    var captureEntryBlocked = false
    var captureEnvironmentStatus: String { native.captureEnvironmentStatus }
    init(native: NativeCaptureInterface, trace: CaptureSecurityTrace, mode: CaptureSecurityTrace.Mode) {
        self.native = native; self.trace = trace; self.mode = mode
    }
    func prepareCaptureEnvironment() -> Bool { native.prepareCaptureEnvironment() }
    func validateCaptureEnvironment() -> Bool { native.validateCaptureEnvironment() }
    func prepareForSelection() -> Bool { true }
    func showSelection(on display: CaptureDisplaySnapshot, selected: @escaping @MainActor (CaptureSelection) -> Void,
                       cancelled: @escaping @MainActor () -> Void) { self.selected = selected }
    func hideSelection() -> Bool { selected = nil; return true }
    func showCollection(activate: Bool) { trace.record(.viewShown, mode: mode) }
    func hideCollection() { trace.record(.viewHidden, mode: mode) }
    func showCollectionGuide(started: @escaping @MainActor () -> Void, cancelled: @escaping @MainActor () -> Void) { started() }
    func showCollectionPermission() { trace.record(.permissionChecked, mode: mode, outcome: .rejected) }
    func showPermission() { trace.record(.permissionChecked, mode: mode, outcome: .rejected) }
    func hidePermission() {}
    func showProblem(activate: Bool) { trace.record(.viewShown, mode: mode) }
    func hideProblem() { trace.record(.viewHidden, mode: mode) }
    func showFeedback(_ message: String) {}
    func dismissAll() { selected = nil; trace.record(.viewHidden, mode: mode) }
    func rememberExternalApplication() {}
    func returnToExternalApplication() {}
}

private enum RuntimeTrialPolicy {
    enum Status: String { case passed = "PASS_LIMITED_OBSERVATION", notEstablished = "NOT_ESTABLISHED", failed = "FAIL", cancelled = "CANCELLED", blocked = "BLOCKED" }
    struct Decision {
        let status: Status
        let reason: String
        var invalidationObservationEstablished = false
        var explicitRecoveryExercised = false
        var fullCellAccepted = false
    }
    static let environmentCodes: Set<CaptureSecurityTrace.Code> = [.systemSleep, .displaySleep, .sessionResigned,
        .displayChanged, .protectedDataUnavailable, .consoleSessionChanged, .consoleSessionUnavailable,
        .consoleUserChanged, .consoleUserUnavailable]

    static func slotIntegrity(_ entries: [CaptureSecurityTrace.Entry], mode: CaptureSecurityTrace.Mode,
                              balanced: Bool = false) -> Bool {
        var acquired = false, working = false
        for entry in entries where entry.mode == mode {
            switch entry.code {
            case .slotAcquired: if acquired { return false }; acquired = true
            case .workerStarted: if !acquired || working { return false }; working = true
            case .workerReturned: if !working { return false }; working = false
            case .slotReleased: if !acquired || working { return false }; acquired = false
            default: break
            }
        }
        return !balanced || (!acquired && !working)
    }

    static func leakage(_ entries: [CaptureSecurityTrace.Entry], mode: CaptureSecurityTrace.Mode, after ready: UInt64,
                        authorizedRecoveryStart: UInt64 = 0) -> Bool {
        if entries.contains(where: { $0.mode == .annotation }) { return true }
        if !slotIntegrity(entries, mode: mode) { return true }
        if entries.contains(where: { recoveryCodes.contains($0.code) && $0.mode != mode }) { return true }
        if entries.contains(where: { [.archiveQueued, .archiveStarted, .editCopyStarted,
            .resultPreviewShown, .resultPreviewDraw, .permissionRequested].contains($0.code) }) { return true }
        if let finished = entries.first(where: { $0.code == .trialRecoveryFinished }),
           entries.contains(where: { $0.sequence > finished.sequence && (recoveryCodes.contains($0.code) || $0.code == .viewDraw) }) {
            return true
        }
        for invalidation in entries where invalidation.sequence > ready && invalidation.mode == mode && invalidation.code == .operationInvalidated {
            let upper = authorizedRecoveryStart > invalidation.sequence ? authorizedRecoveryStart : UInt64.max
            if entries.contains(where: {
                $0.sequence > invalidation.sequence && $0.sequence < upper
                    && ([.operationStarted, .captureRequested, .permissionRequested].contains($0.code)
                        || ($0.mode == mode && ([.resultAdopted, .viewDraw, .clipboardPrepared, .clipboardWrite].contains($0.code)
                            || ($0.code == .clipboardOutcome && $0.outcome == .accepted))))
            }) { return true }
        }
        return false
    }

    static let recoveryCodes: Set<CaptureSecurityTrace.Code> = [.operationStarted, .slotAcquired, .workerStarted,
        .captureRequested, .captureCallback, .captureReturned, .resultAdopted, .compositionStarted,
        .compositionFinished, .clipboardPrepared, .clipboardWrite, .clipboardOutcome, .workerReturned, .slotReleased]

    static func recoveryProjection(mode: CaptureSecurityTrace.Mode) -> [CaptureSecurityTrace.Code] {
        let capture: [CaptureSecurityTrace.Code] = [.operationStarted, .slotAcquired, .workerStarted,
            .captureRequested, .captureCallback, .captureReturned, .resultAdopted]
        let composition: [CaptureSecurityTrace.Code] = [.compositionStarted, .compositionFinished, .resultAdopted,
            .clipboardPrepared, .clipboardWrite, .clipboardOutcome, .workerReturned, .slotReleased]
        return mode == .single ? capture + composition
            : capture + [.workerReturned, .slotReleased, .slotAcquired, .workerStarted] + composition
    }

    static func recoveryEstablished(_ entries: [CaptureSecurityTrace.Entry], mode: CaptureSecurityTrace.Mode,
                                    start: UInt64, end: UInt64, requireFinished: Bool = true) -> Bool {
        guard start > 0, end > start,
              entries.filter({ $0.code == .trialRecoveryStarted }).count == 1,
              entries.contains(where: { $0.sequence == start && $0.code == .trialRecoveryStarted && $0.mode == mode }) else { return false }
        if requireFinished {
            guard entries.filter({ $0.code == .trialRecoveryFinished }).count == 1,
                  entries.contains(where: { $0.sequence == end && $0.code == .trialRecoveryFinished && $0.mode == mode && $0.outcome == .accepted }) else { return false }
        }
        let segment = entries.filter { $0.sequence > start && $0.sequence < end }
        guard !segment.contains(where: { environmentCodes.contains($0.code) || $0.code == .operationInvalidated || $0.code == .permissionRequested }),
              !segment.contains(where: { recoveryCodes.contains($0.code) && $0.mode != mode }),
              segment.filter({ recoveryCodes.contains($0.code) }).map(\.code) == recoveryProjection(mode: mode),
              slotIntegrity(segment, mode: mode, balanced: true),
              segment.contains(where: { $0.code == .captureCallback && $0.outcome == .success }),
              segment.contains(where: { $0.code == .captureReturned && $0.outcome == .success }),
              segment.contains(where: { $0.code == .resultAdopted && $0.phase == .capturing }),
              segment.contains(where: { $0.code == .resultAdopted && $0.phase == .encoding }),
              segment.contains(where: { $0.code == .clipboardWrite && $0.outcome == .none }),
              segment.contains(where: { $0.code == .clipboardOutcome && $0.outcome == .accepted }) else { return false }
        return true
    }

    static func decideWithRecovery(_ entries: [CaptureSecurityTrace.Entry], dropped: UInt64, mode: CaptureSecurityTrace.Mode,
        stage: RuntimeTrialArguments.Stage, transition: RuntimeTrialArguments.Transition, ready: UInt64,
        observationEnd: UInt64, manualConfirmed: Bool, workerEnded: Bool, imagesCleared: Bool, slotFree: Bool,
        recoveryClicked: Bool, recoveryStart: UInt64, recoveryEnd: UInt64,
        recoveryWorkerEnded: Bool, recoverySlotFree: Bool) -> Decision {
        let old = entries.filter { $0.sequence <= observationEnd }
        let observation = decide(old, dropped: dropped, mode: mode, stage: stage, transition: transition,
            ready: ready, manualConfirmed: manualConfirmed, workerEnded: workerEnded, imagesCleared: imagesCleared, slotFree: slotFree)
        let authorized = observation.invalidationObservationEstablished && recoveryClicked && recoveryStart > observationEnd
            && entries.contains { $0.sequence == recoveryStart && $0.code == .trialRecoveryStarted && $0.mode == mode }
            && slotIntegrity(entries.filter { $0.sequence < recoveryStart }, mode: mode, balanced: true)
        if leakage(entries, mode: mode, after: ready, authorizedRecoveryStart: authorized ? recoveryStart : 0) {
            return Decision(status: .failed, reason: "POST_INVALIDATION_CONSUMER_OR_EARLY_SLOT_RELEASE")
        }
        guard observation.invalidationObservationEstablished else { return observation }
        guard authorized && dropped == 0 && recoveryWorkerEnded && recoverySlotFree
            && recoveryEstablished(entries, mode: mode, start: recoveryStart, end: recoveryEnd) else { return observation }
        return Decision(status: .passed, reason: "OBSERVED_INVALIDATION_AND_EXPLICIT_RECOVERY",
            invalidationObservationEstablished: true, explicitRecoveryExercised: true, fullCellAccepted: true)
    }

    static func decide(_ entries: [CaptureSecurityTrace.Entry], dropped: UInt64, mode: CaptureSecurityTrace.Mode,
                       stage: RuntimeTrialArguments.Stage, transition: RuntimeTrialArguments.Transition,
                       ready: UInt64, manualConfirmed: Bool, workerEnded: Bool, imagesCleared: Bool, slotFree: Bool) -> Decision {
        if leakage(entries, mode: mode, after: ready) { return Decision(status: .failed, reason: "POST_INVALIDATION_CONSUMER_OR_EARLY_SLOT_RELEASE") }
        guard dropped == 0 else { return Decision(status: .notEstablished, reason: "TRACE_OVERFLOW") }
        guard manualConfirmed, entries.contains(where: { $0.sequence > ready && $0.mode == mode && $0.code == .manualTransitionConfirmed }) else {
            return Decision(status: .notEstablished, reason: "MANUAL_TRANSITION_NOT_CONFIRMED")
        }
        let candidates = entries.filter { entry in
            guard entry.sequence > ready else { return false }
            switch transition {
            case .systemSleep: return entry.code == .systemSleep
            case .displaySleep: return entry.code == .displaySleep
            case .menuLock, .keyLock:
                return [.displaySleep, .sessionResigned, .protectedDataUnavailable, .consoleSessionChanged, .consoleUserChanged].contains(entry.code)
            }
        }
        guard let event = candidates.first,
              let invalidation = entries.first(where: { $0.sequence > event.sequence && $0.mode == mode && $0.code == .operationInvalidated }) else {
            return Decision(status: .notEstablished, reason: "TRANSITION_OR_INVALIDATION_UNOBSERVED")
        }
        let overlaps: Bool
        switch stage {
        case .selecting: overlaps = invalidation.phase == .selecting
        case .retained: overlaps = entries.contains { $0.sequence == ready && $0.code == .trialReady }
        case .sck, .encoding:
            let begin: CaptureSecurityTrace.Code = stage == .sck ? .captureRequested : .compositionStarted
            let end: CaptureSecurityTrace.Code = stage == .sck ? .captureCallback : .compositionFinished
            overlaps = entries.contains { start in
                start.mode == mode && start.code == begin && start.sequence > ready && start.sequence < event.sequence
                    && entries.contains { $0.mode == mode && $0.code == end && $0.sequence > event.sequence }
            }
        }
        guard overlaps else { return Decision(status: .notEstablished, reason: "REQUESTED_STAGE_OVERLAP_NOT_ESTABLISHED") }
        guard workerEnded && imagesCleared && slotFree && slotIntegrity(entries, mode: mode, balanced: true) else { return Decision(status: .notEstablished, reason: "RETURN_OR_IMAGE_RELEASE_NOT_ESTABLISHED") }
        // Invalidation alone is only one part of a complete cell. The separate explicit
        // recovery boundary must also be established before this observation can count.
        return Decision(status: .notEstablished, reason: "EXPLICIT_RECOVERY_NOT_ESTABLISHED",
                        invalidationObservationEstablished: true)
    }

    @MainActor
    final class SyntheticClipboardDestination: M0ClipboardProbeDestination {
        var changeCount = 0
        func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int { changeCount += 1; return changeCount }
        func write(_ item: NSPasteboardItem) -> Bool { true }
    }

    @MainActor
    static func selfTest() throws {
        func require(_ value: Bool) throws { if !value { throw RuntimeTrialFailure.policy } }
        _ = try RuntimeTrialArguments.parse([]); _ = try RuntimeTrialArguments.parse(["--help"])
        for args in [["--run"], ["--mode", "single"], ["--help", "--run"], ["--self-test", "--run"]] {
            do { _ = try RuntimeTrialArguments.parse(args); throw RuntimeTrialFailure.policy } catch RuntimeTrialFailure.arguments {}
        }
        for mode in RuntimeTrialArguments.Mode.allCases {
            for stage in RuntimeTrialArguments.Stage.allCases {
                for transition in RuntimeTrialArguments.Transition.allCases {
                    let arguments = ["--run", "--mode", mode.rawValue, "--stage", stage.rawValue,
                        "--transition", transition.rawValue, "--output-dir", "/synthetic-new-output",
                        "--fixture-pid", "44", "--fixture-executable", "/synthetic/M4Fixture",
                        "--fixture-sha256", String(repeating: "a", count: 64), "--parent-fresh-fixture", "yes"]
                    guard case .run(let config) = try RuntimeTrialArguments.parse(arguments),
                          config.mode == mode, config.stage == stage, config.transition == transition else { throw RuntimeTrialFailure.policy }
                }
            }
        }
        let base = RuntimeFixtureWindow(id: 7, pid: 44, frame: CGRect(x: 0, y: 0, width: 100, height: 100), onScreen: true, opaque: true, layer: 0)
        let crop = CGRect(x: 10, y: 10, width: 20, height: 20)
        try require(base.admits(base, rect: crop))
        for wrong in [RuntimeFixtureWindow(id: 8, pid: 44, frame: base.frame, onScreen: true, opaque: true, layer: 0),
                      RuntimeFixtureWindow(id: 7, pid: 45, frame: base.frame, onScreen: true, opaque: true, layer: 0),
                      RuntimeFixtureWindow(id: 7, pid: 44, frame: base.frame.offsetBy(dx: 1, dy: 0), onScreen: true, opaque: true, layer: 0),
                      RuntimeFixtureWindow(id: 7, pid: 44, frame: base.frame, onScreen: false, opaque: true, layer: 0),
                      RuntimeFixtureWindow(id: 7, pid: 44, frame: base.frame, onScreen: true, opaque: false, layer: 0),
                      RuntimeFixtureWindow(id: 7, pid: 44, frame: base.frame, onScreen: true, opaque: true, layer: 1)] {
            try require(!base.admits(wrong, rect: crop))
        }
        try require(!base.admits(base, rect: crop.offsetBy(dx: 100, dy: 0)))
        let display = try CaptureDisplaySnapshot(id: 41, frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 1)
        let selection = try CaptureSelection(display: display, rect: crop)
        try require(RuntimeFixtureSelectionPolicy.admits(expected: selection, requested: selection, currentDisplay: display, foreignOccludes: false))
        try require(!RuntimeFixtureSelectionPolicy.admits(expected: selection, requested: selection, currentDisplay: display, foreignOccludes: true))
        for changed in [try CaptureDisplaySnapshot(id: 42, frame: display.frame, scale: 1),
                        try CaptureDisplaySnapshot(id: 41, frame: display.frame.offsetBy(dx: 1, dy: 0), scale: 1),
                        try CaptureDisplaySnapshot(id: 41, frame: display.frame, scale: 2)] {
            try require(!RuntimeFixtureSelectionPolicy.admits(expected: selection, requested: selection, currentDisplay: changed, foreignOccludes: false))
        }
        let changedSelection = try CaptureSelection(display: display, rect: crop.offsetBy(dx: 1, dy: 0))
        try require(!RuntimeFixtureSelectionPolicy.admits(expected: selection, requested: changedSelection, currentDisplay: display, foreignOccludes: false))
        func entry(_ n: UInt64, _ code: CaptureSecurityTrace.Code, phase: CaptureSecurityTrace.Phase = .none,
                   outcome: CaptureSecurityTrace.Outcome = .none, mode: CaptureSecurityTrace.Mode = .collection) -> CaptureSecurityTrace.Entry {
            .init(trial: 1, sequence: n, relativeNanos: n, code: code, mode: mode, phase: phase, outcome: outcome)
        }
        let good = [entry(1, .trialReady), entry(2, .systemSleep, mode: .none), entry(3, .operationInvalidated), entry(4, .manualTransitionConfirmed)]
        func decision(_ rows: [CaptureSecurityTrace.Entry], dropped: UInt64 = 0, confirmed: Bool = true) -> Decision {
            decide(rows, dropped: dropped, mode: .collection, stage: .retained, transition: .systemSleep,
                   ready: 1, manualConfirmed: confirmed, workerEnded: true, imagesCleared: true, slotFree: true)
        }
        try require(decision(good).status == .notEstablished)
        try require(decision(good).reason == "EXPLICIT_RECOVERY_NOT_ESTABLISHED")
        try require(decision(good).invalidationObservationEstablished)
        try require(!decision(good, confirmed: false).invalidationObservationEstablished)
        try require(decision(good, dropped: 1).status == .notEstablished)
        try require(decision(good, confirmed: false).status == .notEstablished)
        try require(decision([good[0], good[2]]).status == .notEstablished)
        for code in [CaptureSecurityTrace.Code.resultAdopted, .viewDraw, .clipboardPrepared, .clipboardWrite,
                     .operationStarted, .captureRequested, .permissionRequested] {
            try require(decision(good + [entry(5, code)]).status == .failed)
        }
        for code in [CaptureSecurityTrace.Code.operationStarted, .captureRequested, .permissionRequested] {
            try require(decision(good + [entry(5, code, mode: .single)]).status == .failed)
        }
        for code in [CaptureSecurityTrace.Code.captureCallback, .captureReturned] {
            try require(decision(good + [entry(5, code)]).invalidationObservationEstablished)
        }
        let sck = [entry(1, .trialReady), entry(2, .captureRequested), entry(3, .systemSleep, mode: .none),
                   entry(4, .operationInvalidated), entry(5, .captureCallback), entry(6, .manualTransitionConfirmed)]
        try require(decide(sck, dropped: 0, mode: .collection, stage: .sck, transition: .systemSleep,
            ready: 1, manualConfirmed: true, workerEnded: true, imagesCleared: true, slotFree: true).invalidationObservationEstablished)
        let lateReturn = [entry(1, .trialReady), entry(2, .slotAcquired), entry(3, .workerStarted),
            entry(4, .captureRequested), entry(5, .systemSleep, mode: .none), entry(6, .operationInvalidated),
            entry(7, .captureCallback), entry(8, .captureReturned), entry(9, .workerReturned),
            entry(10, .slotReleased), entry(11, .manualTransitionConfirmed)]
        try require(decide(lateReturn, dropped: 0, mode: .collection, stage: .sck, transition: .systemSleep,
            ready: 1, manualConfirmed: true, workerEnded: true, imagesCleared: true, slotFree: true).invalidationObservationEstablished)
        let postReturn = [entry(1, .trialReady), entry(2, .captureRequested), entry(3, .captureCallback),
                          entry(4, .systemSleep, mode: .none), entry(5, .operationInvalidated), entry(6, .manualTransitionConfirmed)]
        try require(decide(postReturn, dropped: 0, mode: .collection, stage: .sck, transition: .systemSleep,
            ready: 1, manualConfirmed: true, workerEnded: true, imagesCleared: true, slotFree: true).status == .notEstablished)
        let earlyRelease = [entry(1, .trialReady), entry(2, .workerStarted), entry(3, .systemSleep, mode: .none),
                            entry(4, .operationInvalidated), entry(5, .slotReleased), entry(6, .workerReturned)]
        try require(decision(earlyRelease).status == .failed)
        try require(decision(good + [entry(5, .clipboardOutcome, outcome: .accepted)]).status == .failed)
        // Every requested mode/stage/transition has a decision path. These are fabricated trace
        // rows, never evidence that the corresponding real OS overlap can be made to occur.
        for mode in [CaptureSecurityTrace.Mode.single, .collection] {
            for stage in RuntimeTrialArguments.Stage.allCases {
                for transition in RuntimeTrialArguments.Transition.allCases {
                    let signal: CaptureSecurityTrace.Code = transition == .systemSleep ? .systemSleep
                        : (transition == .displaySleep ? .displaySleep : .protectedDataUnavailable)
                    var rows = [entry(1, .trialReady, mode: mode)]
                    if stage == .sck || stage == .encoding {
                        rows.append(entry(2, stage == .sck ? .captureRequested : .compositionStarted, mode: mode))
                    }
                    rows.append(entry(3, signal, mode: .none))
                    rows.append(entry(4, .operationInvalidated, phase: stage == .selecting ? .selecting : .none, mode: mode))
                    if stage == .sck || stage == .encoding {
                        rows.append(entry(5, stage == .sck ? .captureCallback : .compositionFinished, mode: mode))
                    }
                    rows = rows.enumerated().map { index, row in
                        entry(UInt64(index + 1), row.code, phase: row.phase, outcome: row.outcome, mode: row.mode)
                    }
                    rows.append(entry(UInt64(rows.count + 1), .manualTransitionConfirmed, mode: mode))
                    let observation = decide(rows, dropped: 0, mode: mode, stage: stage, transition: transition,
                        ready: 1, manualConfirmed: true, workerEnded: true, imagesCleared: true, slotFree: true)
                    try require(observation.status == .notEstablished && observation.invalidationObservationEstablished
                        && observation.reason == "EXPLICIT_RECOVERY_NOT_ESTABLISHED")
                    try require(decide(rows, dropped: 0, mode: mode, stage: stage, transition: transition,
                        ready: 1, manualConfirmed: true, workerEnded: false, imagesCleared: true, slotFree: false).status == .notEstablished)
                    let oldEnd = UInt64(rows.count)
                    let recoveryStart = oldEnd + 1
                    rows.append(entry(recoveryStart, .trialRecoveryStarted, mode: mode))
                    // Generate the prepare/write rows at the real synchronous probe boundary.
                    // The destination and item are local objects; no OS pasteboard is created.
                    let boundaryTrace = CaptureSecurityTrace(enabled: true, trial: 1)
                    let clipboardOutcome = M0ClipboardProbe.writePNG(Data([1]), to: SyntheticClipboardDestination(),
                        expectedChangeCount: 0, securityTrace: boundaryTrace, traceMode: mode,
                        itemFactory: { _ in NSPasteboardItem() })
                    let boundaryRows = boundaryTrace.snapshot().entries
                    try require(clipboardOutcome.writeAccepted && boundaryRows.map(\.code) == [.clipboardPrepared, .clipboardWrite]
                        && boundaryRows.allSatisfy { $0.outcome == .none })
                    var adoption = 0
                    for code in recoveryProjection(mode: mode) {
                        if code == .resultAdopted { adoption += 1 }
                        let captureSucceeded = code == .captureCallback || code == .captureReturned
                        rows.append(entry(UInt64(rows.count + 1), code,
                            phase: boundaryRows.first(where: { $0.code == code })?.phase
                                ?? (code == .resultAdopted ? (adoption == 1 ? .capturing : .encoding) : .none),
                            outcome: boundaryRows.first(where: { $0.code == code })?.outcome
                                ?? (captureSucceeded ? .success
                                    : (code == .clipboardOutcome && clipboardOutcome.writeAccepted ? .accepted : .none)), mode: mode))
                    }
                    rows.append(entry(UInt64(rows.count + 1), .trialRecoveryFinished, outcome: .accepted, mode: mode))
                    let recoveryEnd = UInt64(rows.count)
                    func full(_ candidate: [CaptureSecurityTrace.Entry], clicked: Bool = true,
                              oldEnded: Bool = true, returned: Bool = true) -> Decision {
                        decideWithRecovery(candidate, dropped: 0, mode: mode, stage: stage, transition: transition,
                            ready: 1, observationEnd: oldEnd, manualConfirmed: true, workerEnded: oldEnded,
                            imagesCleared: true, slotFree: true, recoveryClicked: clicked,
                            recoveryStart: recoveryStart, recoveryEnd: recoveryEnd,
                            recoveryWorkerEnded: returned, recoverySlotFree: returned)
                    }
                    let accepted = full(rows)
                    try require(accepted.status == .passed && accepted.invalidationObservationEstablished
                        && accepted.explicitRecoveryExercised && accepted.fullCellAccepted)
                    try require(full(rows, clicked: false).status != .passed)
                    try require(full(rows, oldEnded: false).status != .passed)
                    try require(full(rows, returned: false).status != .passed)
                    for missing in [CaptureSecurityTrace.Code.captureRequested, .captureCallback, .captureReturned,
                                    .compositionFinished, .clipboardWrite, .workerReturned] {
                        try require(full(rows.filter { $0.sequence <= oldEnd || $0.code != missing }).status != .passed)
                    }
                    for contradictory in [CaptureSecurityTrace.Code.captureCallback, .captureReturned] {
                        let failedCapture = rows.map { row in
                            row.sequence > recoveryStart && row.code == contradictory
                                ? entry(row.sequence, row.code, phase: row.phase, outcome: .failure, mode: row.mode) : row
                        }
                        try require(full(failedCapture).status != .passed)
                    }
                    let duplicateMarker = rows + [entry(recoveryEnd + 1, .trialRecoveryStarted, mode: mode)]
                    try require(full(duplicateMarker).status != .passed)
                    let restarted = rows.map { row in
                        row.code == .clipboardPrepared ? entry(row.sequence, .operationInvalidated, mode: mode) : row
                    }
                    try require(full(restarted).status == .failed)

                }
            }
        }
    }
}

@MainActor
private final class RuntimeTrialController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let config: RuntimeTrialArguments.Configuration
    private let fixture: RuntimeFixtureBinding
    private let trace = CaptureSecurityTrace(enabled: true, trial: 1)
    private let started = DispatchTime.now().uptimeNanoseconds
    private var native: NativeCaptureInterface!
    private var interface: RuntimeTrialInterface!
    private var writer: RuntimeNamedWriter!
    private let slot = CaptureWorkerSlot()
    private var single: SingleCaptureCoordinator!
    private var collection: CollectionCaptureCoordinator!
    private var window: NSWindow!
    private let information = NSTextField(wrappingLabelWithString: "")
    private var startButton: NSButton!, confirmButton: NSButton!, recoveryButton: NSButton!
    private var timer: Timer?
    private var didStart = false, finishing = false, confirmed = false
    private var ready: UInt64 = 0
    private var observationEnd: UInt64 = 0
    private var observationAccepted = false
    private var oldWorkerEnded = false, oldImagesCleared = false, oldSlotFree = false
    private var recoveryClicked = false
    private var recoveryStart: UInt64 = 0, recoveryEnd: UInt64 = 0
    private var observationTask: Task<Void, Never>?
    private var setup: Task<Void, Never>?
    private(set) var exitCode: Int32 = 2

    init(config: RuntimeTrialArguments.Configuration, fixture: RuntimeFixtureBinding) {
        self.config = config; self.fixture = fixture
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        native = NativeCaptureInterface(environmentSources: .live, sessionBackend: .live, consoleBackend: .live, securityTrace: trace)
        interface = RuntimeTrialInterface(native: native, trace: trace, mode: config.traceMode)
        writer = RuntimeNamedWriter(trace: trace, mode: config.traceMode, forcedReject: config.mode == .single && config.stage == .retained)
        let preferences = CapturePreferences(defaults: nil, hasSeenCaptureGuide: true, hasSeenPasteHint: true, hasSeenCollectionGuide: true)
        let capturer = RuntimeFixtureCapturer(fixture: fixture)
        single = SingleCaptureCoordinator(capturer: capturer, interface: interface, clipboard: writer, workSlot: slot,
            permissionCheck: { CGPreflightScreenCaptureAccess() }, permissionRequest: { [trace] in
                trace.record(.permissionRequested, mode: .single); return false
            },
            protectedDataCheck: { NSApp.isProtectedDataAvailable }, displayAtPointer: { [fixture] in fixture.selection.display },
            preferences: preferences, securityTrace: trace)
        collection = CollectionCaptureCoordinator(capturer: capturer, interface: interface, clipboard: writer, workSlot: slot,
            preferences: preferences, securityTrace: trace, permissionCheck: { CGPreflightScreenCaptureAccess() },
            permissionRequest: { [trace] in
                trace.record(.permissionRequested, mode: .collection); return false
            }, protectedDataCheck: { NSApp.isProtectedDataAvailable },
            displayAtPointer: { [fixture] in fixture.selection.display })
        native.coordinator = single; native.collectionCoordinator = collection
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 340),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "OneClip — OS遷移の限定試験"
        window.isReleasedWhenClosed = false; window.isRestorable = false; window.delegate = self
        information.stringValue = "架空fixtureのみ・専用pasteboardのみ。OS操作は自動実行しません。開始後、READYを確認して指定のlock／sleepを1回だけ行い、復帰後に実施確認してください。15分で停止します。失効確認後の新しい撮影は、復旧確認ボタンを押した場合だけ開始します。"
        startButton = NSButton(title: "架空範囲で試験を開始", target: self, action: #selector(startTrial))
        confirmButton = NSButton(title: "指定のOS操作を実施した・失効を確認", target: self, action: #selector(confirmTransition))
        confirmButton.isEnabled = false
        recoveryButton = NSButton(title: "新しい撮影を開始して復旧を確認", target: self, action: #selector(startRecovery))
        recoveryButton.isEnabled = false
        let cancel = NSButton(title: "中止して終了", target: self, action: #selector(cancelTrial))
        let stack = NSStackView(views: [information, startButton, confirmButton, recoveryButton, cancel])
        stack.orientation = .vertical; stack.spacing = 14; stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = stack; window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    func applicationProtectedDataWillBecomeUnavailable(_ notification: Notification) { native?.protectedDataWillBecomeUnavailable() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancelTrial(); return false }

    private var withinSession: Bool { DispatchTime.now().uptimeNanoseconds - started < 900_000_000_000 }

    @objc private func startTrial() {
        guard withinSession else { finish(override: .init(status: .notEstablished, reason: "SESSION_15_MINUTE_LIMIT")); return }
        guard !didStart, !finishing, fixture.validate(fixture.selection), native.prepareCaptureEnvironment(), CGPreflightScreenCaptureAccess() else {
            finish(override: .init(status: .blocked, reason: "START_PREREQUISITE_UNAVAILABLE")); return
        }
        didStart = true; startButton.isEnabled = false
        setup = Task { [weak self] in
            guard let self else { return }
            if self.config.mode == .single { self.single.begin() } else { self.collection.beginOrAdd() }
            if self.config.stage == .selecting { self.markReady(); return }
            if self.config.stage == .sck || (self.config.mode == .single && self.config.stage == .encoding) { self.markReady() }
            guard let select = self.interface.selected else { self.finish(override: .init(status: .blocked, reason: "SELECTION_NOT_AVAILABLE")); return }
            select(self.fixture.selection)
            if self.config.mode == .single { await self.single.waitForWorker() }
            else { await self.collection.waitForWorker() }
            guard !self.finishing else { return }
            if self.config.mode == .collection && (self.config.stage == .encoding || self.config.stage == .retained) {
                guard !self.collection.assets.isEmpty else { self.finish(override: .init(status: .blocked, reason: "FIXTURE_ACQUISITION_NOT_ESTABLISHED")); return }
                if self.config.stage == .encoding { self.markReady() }
                self.collection.copy(); await self.collection.waitForWorker()
            }
            if self.config.stage == .retained {
                let retained = self.config.mode == .single ? self.single.hasRetainedImage : !self.collection.assets.isEmpty
                guard retained else { self.finish(override: .init(status: .blocked, reason: "RETAINED_STAGE_NOT_ESTABLISHED")); return }
                self.markReady()
            }
        }
    }

    private func markReady() {
        guard !finishing, ready == 0 else { return }
        let phase: CaptureSecurityTrace.Phase
        switch config.stage { case .selecting: phase = .selecting; case .sck: phase = .capturing; case .encoding: phase = .encoding; case .retained: phase = .ready }
        trace.record(.trialReady, mode: config.traceMode, phase: phase)
        ready = trace.snapshot().entries.last?.sequence ?? 0
        confirmButton.isEnabled = true
        information.stringValue = "READY: \(config.mode.rawValue) / \(config.stage.rawValue) / \(config.transition.rawValue)。指定のOS操作を1回だけ実施してください。取得・合成の実区間と重ならなければ未実証です。"
        print("READY RUNTIME_ONE_MANUAL_OPERATION mode=\(config.mode.rawValue) stage=\(config.stage.rawValue) transition=\(config.transition.rawValue)")
        fflush(nil)
    }
    @objc private func confirmTransition() {
        guard withinSession else { finish(override: .init(status: .notEstablished, reason: "SESSION_15_MINUTE_LIMIT")); return }
        guard ready > 0, !confirmed, !finishing else { return }
        confirmed = true; trace.record(.manualTransitionConfirmed, mode: config.traceMode)
        confirmButton.isEnabled = false
        observationTask = Task { [weak self] in
            guard let self else { return }
            let deadline = min(self.started + 900_000_000_000, DispatchTime.now().uptimeNanoseconds + 30_000_000_000)
            while (self.single.isWorking || self.collection.isWorking || self.slot.isOccupied), !self.finishing,
                  DispatchTime.now().uptimeNanoseconds < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !self.finishing else { return }
            let evidence = self.trace.snapshot()
            let workerEnded = !self.single.isWorking && !self.collection.isWorking
            let imagesCleared = !self.single.hasRetainedImage && !self.collection.hasRetainedImages
            let slotFree = !self.slot.isOccupied
            let decision = RuntimeTrialPolicy.decide(evidence.entries, dropped: evidence.droppedCount,
                mode: self.config.traceMode, stage: self.config.stage, transition: self.config.transition,
                ready: self.ready, manualConfirmed: self.confirmed, workerEnded: workerEnded,
                imagesCleared: imagesCleared, slotFree: slotFree)
            guard decision.invalidationObservationEstablished else { self.finish(override: decision); return }
            self.oldWorkerEnded = workerEnded; self.oldImagesCleared = imagesCleared; self.oldSlotFree = slotFree
            self.observationEnd = evidence.entries.last?.sequence ?? 0
            self.observationAccepted = true
            self.recoveryButton.isEnabled = true
            self.information.stringValue = "失効と旧workerの返却・画像解放を確認しました。復帰だけでは再開しません。復旧も確かめる場合は、新しい撮影を開始するボタンを押してください。"
            print("READY RUNTIME_EXPLICIT_RECOVERY_REQUIRED")
            fflush(nil)
        }
    }

    @objc private func startRecovery() {
        guard withinSession else { finish(override: .init(status: .notEstablished, reason: "SESSION_15_MINUTE_LIMIT")); return }
        guard observationAccepted, !recoveryClicked, !finishing,
              !single.isWorking, !collection.isWorking, !slot.isOccupied,
              !single.hasRetainedImage, !collection.hasRetainedImages else { return }
        if RuntimeTrialPolicy.leakage(trace.snapshot().entries, mode: config.traceMode, after: ready,
            authorizedRecoveryStart: observationAccepted ? recoveryStart : 0) {
            finish(override: .init(status: .failed, reason: "POST_INVALIDATION_CONSUMER_OR_EARLY_SLOT_RELEASE")); return
        }
        recoveryClicked = true
        recoveryButton.isEnabled = false
        trace.record(.trialRecoveryStarted, mode: config.traceMode)
        recoveryStart = trace.snapshot().entries.last?.sequence ?? 0
        writer.allowRecoveryWrite()
        information.stringValue = "本人の新しい操作で、同じ架空範囲の実撮影・PNG生成・専用pasteboardへのコピーを確認しています。"
        setup = Task { [weak self] in
            guard let self, !self.finishing else { return }
            if self.config.mode == .single { self.single.begin() }
            else { self.collection.beginNewSession() }
            guard let selected = self.interface.selected else { self.finish(override: nil); return }
            selected(self.fixture.selection)
            if self.config.mode == .single { await self.single.waitForWorker() }
            else {
                await self.collection.waitForWorker()
                guard !self.finishing else { return }
                self.collection.copy()
                await self.collection.waitForWorker()
            }
            guard !self.finishing else { return }
            let evidence = self.trace.snapshot()
            let proposedEnd = (evidence.entries.last?.sequence ?? 0) + 1
            let passed = evidence.droppedCount == 0 && !self.single.isWorking && !self.collection.isWorking
                && !self.slot.isOccupied && RuntimeTrialPolicy.recoveryEstablished(evidence.entries,
                    mode: self.config.traceMode, start: self.recoveryStart, end: proposedEnd, requireFinished: false)
            self.trace.record(.trialRecoveryFinished, mode: self.config.traceMode, outcome: passed ? .accepted : .rejected)
            self.recoveryEnd = self.trace.snapshot().entries.last?.sequence ?? 0
            self.finish(override: nil)
        }
    }

    @objc private func cancelTrial() { finish(override: .init(status: .notEstablished, reason: "PERSON_CANCELLED")) }
    private func tick() {
        guard !finishing else { return }
        if RuntimeTrialPolicy.leakage(trace.snapshot().entries, mode: config.traceMode, after: ready,
            authorizedRecoveryStart: observationAccepted ? recoveryStart : 0) {
            finish(override: .init(status: .failed, reason: "POST_INVALIDATION_CONSUMER_OR_EARLY_SLOT_RELEASE")); return
        }
        if DispatchTime.now().uptimeNanoseconds - started >= 900_000_000_000 {
            finish(override: .init(status: .notEstablished, reason: "SESSION_15_MINUTE_LIMIT"))
        }
    }

    private func finish(override decisionOverride: RuntimeTrialPolicy.Decision?) {
        guard !finishing else { return }
        finishing = true; timer?.invalidate(); observationTask?.cancel()
        confirmButton?.isEnabled = false; startButton?.isEnabled = false; recoveryButton?.isEnabled = false
        Task { [self] in
            // A finite return observation, never a forced release of the product worker permit.
            let deadline = min(started + 900_000_000_000, DispatchTime.now().uptimeNanoseconds + 30_000_000_000)
            if decisionOverride == nil {
                while (single?.isWorking == true || collection?.isWorking == true), DispatchTime.now().uptimeNanoseconds < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            let evidence = trace.snapshot()
            let end = evidence.entries.last?.sequence ?? 0
            let recoveryWorkerEnded = single?.isWorking != true && collection?.isWorking != true
            let recoverySlotFree = !slot.isOccupied
            let workerEnded = observationAccepted ? oldWorkerEnded : recoveryWorkerEnded
            let imagesCleared = observationAccepted ? oldImagesCleared : (single?.hasRetainedImage != true && collection?.hasRetainedImages != true)
            let slotFree = observationAccepted ? oldSlotFree : recoverySlotFree
            let oldEnd = observationAccepted ? observationEnd : end
            let decision: RuntimeTrialPolicy.Decision
            if RuntimeTrialPolicy.leakage(evidence.entries, mode: config.traceMode, after: ready,
                authorizedRecoveryStart: observationAccepted ? recoveryStart : 0) {
                // A person cancellation/timeout must never overwrite an already observed failure.
                decision = .init(status: .failed, reason: "POST_INVALIDATION_CONSUMER_OR_EARLY_SLOT_RELEASE")
            } else {
                decision = decisionOverride ?? RuntimeTrialPolicy.decideWithRecovery(evidence.entries, dropped: evidence.droppedCount,
                    mode: config.traceMode, stage: config.stage, transition: config.transition, ready: ready,
                    observationEnd: oldEnd, manualConfirmed: confirmed, workerEnded: workerEnded, imagesCleared: imagesCleared,
                    slotFree: slotFree, recoveryClicked: recoveryClicked, recoveryStart: recoveryStart, recoveryEnd: recoveryEnd,
                    recoveryWorkerEnded: recoveryWorkerEnded, recoverySlotFree: recoverySlotFree)
            }
            setup?.cancel(); single?.stop(); collection?.stop(); native?.stopEnvironmentMonitoring(); writer?.close()
            trace.record(.trialFinished, mode: config.traceMode)
            let finalTrace = trace.snapshot()
            let finalDecision: RuntimeTrialPolicy.Decision
            if RuntimeTrialPolicy.leakage(finalTrace.entries, mode: config.traceMode, after: ready,
                authorizedRecoveryStart: observationAccepted ? recoveryStart : 0) {
                finalDecision = .init(status: .failed, reason: "POST_INVALIDATION_CONSUMER_OR_EARLY_SLOT_RELEASE")
            } else if decision.status != .failed && finalTrace.droppedCount > 0 {
                finalDecision = .init(status: .notEstablished, reason: "TRACE_OVERFLOW")
            } else { finalDecision = decision }
            do {
                let metadata: [String: Any] = [
                    "schema": "oneclip-runtime-trial-v1", "source_baseline": "062f1bd1129d0286f4696fec612db5f6d6593050",
                    "status": finalDecision.status.rawValue, "reason": finalDecision.reason, "mode": config.mode.rawValue,
                    "stage": config.stage.rawValue, "transition": config.transition.rawValue,
                    "ready_sequence": ready, "evidence_end_sequence": end, "manual_transition_confirmed": confirmed,
                    "worker_ended": workerEnded, "images_cleared": imagesCleared, "slot_free": slotFree,
                    "invalidation_observation_established": finalDecision.invalidationObservationEstablished,
                    "explicit_recovery_exercised": finalDecision.explicitRecoveryExercised,
                    "full_cell_accepted": finalDecision.fullCellAccepted,
                    "invalidation_evidence_end_sequence": oldEnd,
                    "recovery_start_sequence": recoveryStart, "recovery_end_sequence": recoveryEnd,
                    "recovery_manual_start_confirmed": recoveryClicked,
                    "recovery_worker_ended": recoveryWorkerEnded, "recovery_slot_free": recoverySlotFree,
                    "archive_exercised": false, "annotation_exercised": false,
                    "fixture_executable_sha256": config.fixtureSHA256, "fixture_binding": "parent_fresh_pid_path_sha256",
                    "single_retained_forced_writer_rejection": config.mode == .single && config.stage == .retained,
                    "selection_ui": "harness_fixed_fixture_crop", "product_image_view_exercised": false,
                    "board": "private_named", "general_board_access": false, "permission_requested": false,
                    "automatic_os_operations": 0, "manual_operations_requested": ready > 0 ? 1 : 0,
                    "session_limit_seconds": 900, "parent_ledger_required": true, "dropped_count": finalTrace.droppedCount,
                    "evidence_dropped_count": evidence.droppedCount,
                    "full_os_matrix_complete": false, "m4_acceptance_complete": false, "voiceover_verified": false,
                    "os_atomicity_guaranteed": false
                ]
                let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try data.write(to: config.output.appendingPathComponent("metadata.json"), options: .withoutOverwriting)
                try encoder.encode(finalTrace.entries).write(to: config.output.appendingPathComponent("trace.json"), options: .withoutOverwriting)
                exitCode = finalDecision.status == .passed ? 0 : (finalDecision.status == .failed ? 1 : 2)
                print("\(finalDecision.status.rawValue) RUNTIME_TRIAL \(finalDecision.reason)")
            } catch { exitCode = 1; print("FAIL RUNTIME_REPORT_WRITE") }
            window?.orderOut(nil)
            NSApp.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }
}
