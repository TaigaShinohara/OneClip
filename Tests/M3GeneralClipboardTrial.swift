import AppKit
import Darwin
import Foundation

/// Compile with M0ClipboardProbe.swift and M0ImageCore.swift. Compilation is not permission to run.
/// Root runs the opt-in mode only after the person explicitly agrees to replace the general board
/// with disposable fabricated content. Default/help/invalid arguments never obtain that board.
/// No clipboard payload is read, backed up, logged, restored or saved to disk.
@main
@MainActor
struct M3GeneralClipboardTrial {
    private static let runFlag = "--run-general-disposable-fixture"
    private static let onceFlag = "--competitor-once"
    private static let burstFlag = "--competitor-burst"
    private static let competitorWrites = 64
    private static let parentAttempts = 128
    private static let fixedText = "OneClip disposable fabricated competitor EXAMPLE-01"

    private enum Failure: String, Error {
        case fixture = "FIXTURE"
        case seed = "SEED"
        case childLaunch = "CHILD_LAUNCH"
        case childTimeout = "CHILD_TIMEOUT"
        case childExit = "CHILD_EXIT"
        case childProtocol = "CHILD_PROTOCOL"
        case beforePrepare = "BEFORE_PREPARE"
        case afterPrepare = "AFTER_PREPARE"
        case simulatedRejection = "SIMULATED_REJECTION"
        case freerunOutcome = "FREERUN_OUTCOME"
        case freerunNoOverlap = "FREERUN_NO_OVERLAP"
        case accepted = "NORMAL_ACCEPTANCE"
    }

    /// A real destination with one narrowly scoped synchronous test hook. It never reads contents.
    /// forceRejection models write(false); it is deliberately not an actual pasteboard-server fault.
    private final class Destination: M0ClipboardProbeDestination {
        let pasteboard: NSPasteboard
        var afterPrepare: (@MainActor () throws -> Void)?
        var forceRejection = false
        private(set) var hookFailed = false
        private(set) var prepareCalls = 0
        private(set) var writeCalls = 0
        private(set) var actualWriteCalls = 0

        init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

        var changeCount: Int { pasteboard.changeCount }

        func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
            prepareCalls += 1
            let count = pasteboard.prepareForNewContents(with: options)
            do { try afterPrepare?() } catch { hookFailed = true }
            return count
        }

        func write(_ item: NSPasteboardItem) -> Bool {
            writeCalls += 1
            guard !forceRejection, !hookFailed else { return false }
            actualWriteCalls += 1
            return pasteboard.writeObjects([item])
        }
    }

    static func main() {
        // Parse before any NSPasteboard access, including in child modes. Do not accept payload args.
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
            help()
            return
        }
        let flags = Set(arguments)
        guard flags.count == arguments.count, flags.contains(runFlag),
              flags.isSubset(of: [runFlag, onceFlag, burstFlag]),
              !(flags.contains(onceFlag) && flags.contains(burstFlag)) else {
            print("FAIL ARGUMENTS GENERAL_CLIPBOARD_UNTOUCHED")
            exit(2)
        }

        if flags.contains(onceFlag) {
            exit(writeFixedText(to: .general) ? 0 : 1)
        }
        if flags.contains(burstFlag) {
            exit(runCompetitorBurst() ? 0 : 1)
        }

        do {
            try autoreleasepool { try runParent() }
        } catch let failure as Failure {
            print("FAIL M3-GENERAL code=\(failure.rawValue)")
            exit(1)
        } catch {
            // Framework error descriptions may contain paths or other context; never print them.
            print("FAIL M3-GENERAL code=UNEXPECTED")
            exit(1)
        }
    }

    private static func help() {
        print("NOT_RUN GENERAL_CLIPBOARD_UNTOUCHED")
        print("USAGE --run-general-disposable-fixture")
        print("REQUIRES_EXPLICIT_PERSON_START REPLACES_GENERAL_CLIPBOARD_WITH_DISPOSABLE_FIXTURE")
    }

    private static func runParent() throws {
        // This is the first general-board access in the parent. The caller already opted in.
        let pasteboard = NSPasteboard.general
        let png: Data
        do {
            let source = try M0ImageFixture.make(index: 1, width: 400, height: 220)
            png = try M0ImageComposer.compose(assets: [source]).pngData
        } catch { throw Failure.fixture }
        guard writeFixedText(to: pasteboard) else { throw Failure.seed }
        print("START M3-GENERAL DISPOSABLE_FIXTURE_ONLY")

        try beforePrepare(png, pasteboard: pasteboard)
        try afterPrepare(png, pasteboard: pasteboard)
        try simulatedWriteFalse(png, pasteboard: pasteboard)
        try freerunning(png, pasteboard: pasteboard)

        // All our competitor processes have exited. Leave only the fabricated PNG on success.
        // API acceptance does not establish fresh paste, ownership after return, or atomic exclusion.
        let destination = Destination(pasteboard)
        let result = write(png, to: destination, expected: pasteboard.changeCount)
        guard result.code == .writeAccepted, result.prepared,
              destination.prepareCalls == 1, destination.actualWriteCalls == 1 else {
            throw Failure.accepted
        }
        print("PASS NORMAL code=\(result.code.rawValue) prepareCalls=1 actualWriteCalls=1")
        print("LIMIT API_ACCEPTANCE_IS_NOT_FRESH_PASTE_OR_ATOMIC_PROTECTION")
        print("LIMIT FORCED_INTERLEAVE_AND_SIMULATED_FALSE_ARE_SEPARATE_FROM_FREERUNNING")
        print("LIMIT PREPARE_CAN_LOSE_OLD_CONTENT_NO_RESTORE_ATTEMPTED")
        print("LIMIT STANDALONE_BOUNDARY_NOT_COLLECTION_RETENTION_OR_SESSION_UI")
        print("PASS M3-GENERAL COMPLETE")
    }

    private static func beforePrepare(_ png: Data, pasteboard: NSPasteboard) throws {
        let expected = pasteboard.changeCount
        try competitorOnce()
        let destination = Destination(pasteboard)
        let result = write(png, to: destination, expected: expected)
        guard result.code == .conflictBeforePrepare, !result.prepared,
              destination.prepareCalls == 0, destination.writeCalls == 0 else {
            throw Failure.beforePrepare
        }
        print("PASS ACTUAL_PROCESS_BEFORE code=\(result.code.rawValue) childWrites=1 prepareCalls=0 actualWriteCalls=0")
    }

    private static func afterPrepare(_ png: Data, pasteboard: NSPasteboard) throws {
        let destination = Destination(pasteboard)
        // This child really writes NSPasteboard.general. Only its placement in the call is forced.
        // Blocking this small CLI hook is intentional; it is not a change to the production boundary.
        destination.afterPrepare = { try competitorOnce() }
        let result = write(png, to: destination, expected: pasteboard.changeCount)
        guard !destination.hookFailed, result.code == .conflictAfterPrepare, result.prepared,
              destination.prepareCalls == 1, destination.writeCalls == 0 else {
            throw Failure.afterPrepare
        }
        print("PASS ACTUAL_PROCESS_FORCED_AFTER_PREPARE code=\(result.code.rawValue) childWrites=1 prepareCalls=1 actualWriteCalls=0")
    }

    private static func simulatedWriteFalse(_ png: Data, pasteboard: NSPasteboard) throws {
        let destination = Destination(pasteboard)
        destination.forceRejection = true
        let result = write(png, to: destination, expected: pasteboard.changeCount)
        guard result.code == .writeRejected, result.prepared,
              destination.prepareCalls == 1, destination.writeCalls == 1,
              destination.actualWriteCalls == 0 else { throw Failure.simulatedRejection }
        print("PASS SIMULATED_FALSE_AFTER_REAL_PREPARE code=\(result.code.rawValue) prepareCalls=1 writeCalls=1 actualWriteCalls=0")
    }

    private static func freerunning(_ png: Data, pasteboard: NSPasteboard) throws {
        let input = Pipe()
        let output = Pipe()
        let child = makeChild(role: burstFlag)
        child.standardInput = input
        child.standardOutput = output
        do { try child.run() } catch { throw Failure.childLaunch }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        defer {
            stopOwnedChild(child)
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        try receive("READY\n", from: output.fileHandleForReading)
        do { try input.fileHandleForWriting.write(contentsOf: Data("START\n".utf8)) }
        catch { throw Failure.childProtocol }
        try receive("RUNNING\n", from: output.fileHandleForReading)

        let destination = Destination(pasteboard)
        var accepted = 0
        var before = 0
        var after = 0
        var rejected = 0
        var attemptsWhileChildRunning = 0
        for _ in 0..<parentAttempts {
            if child.isRunning { attemptsWhileChildRunning += 1 }
            let result = write(png, to: destination, expected: pasteboard.changeCount)
            switch result.code {
            case .writeAccepted: accepted += 1
            case .conflictBeforePrepare: before += 1
            case .conflictAfterPrepare: after += 1
            case .writeRejected: rejected += 1
            default: throw Failure.freerunOutcome
            }
            usleep(2_000)
        }
        try waitForOwnedChild(child)
        guard attemptsWhileChildRunning > 0 else { throw Failure.freerunNoOverlap }
        // Scheduling is uncontrolled. Zero detected conflicts is a valid observation, not proof
        // that a writer cannot win after a check or after writeObjects has returned true.
        print("PASS ACTUAL_PROCESS_FREERUN childWrites=\(competitorWrites) parentAttempts=\(parentAttempts) attemptsWhileChildRunning=\(attemptsWhileChildRunning) accepted=\(accepted) before=\(before) after=\(after) rejected=\(rejected) prepareCalls=\(destination.prepareCalls) actualWriteCalls=\(destination.actualWriteCalls)")
    }

    private static func write(_ png: Data, to destination: Destination,
                              expected: Int) -> M0ClipboardProbe.Outcome {
        M0ClipboardProbe.writePNG(png, to: destination, expectedChangeCount: expected,
                                  itemFactory: M0ClipboardProbe.makePNGItem)
    }

    private static func writeFixedText(to pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(fixedText, forType: .string) else { return false }
        _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
        return pasteboard.writeObjects([item])
    }

    private static func makeChild(role: String) -> Process {
        let child = Process()
        child.executableURL = Bundle.main.executableURL ??
            URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = [runFlag, role]
        child.standardError = FileHandle.nullDevice
        return child
    }

    private static func competitorOnce() throws {
        let child = makeChild(role: onceFlag)
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        do { try child.run() } catch { throw Failure.childLaunch }
        defer { stopOwnedChild(child) }
        try waitForOwnedChild(child)
    }

    private static func runCompetitorBurst() -> Bool {
        // Only fixed protocol markers are read. No external text becomes a clipboard payload.
        do {
            try FileHandle.standardOutput.write(contentsOf: Data("READY\n".utf8))
            try receive("START\n", from: .standardInput)
            let pasteboard = NSPasteboard.general
            guard writeFixedText(to: pasteboard) else { return false }
            try FileHandle.standardOutput.write(contentsOf: Data("RUNNING\n".utf8))
            for _ in 1..<competitorWrites {
                usleep(8_000)
                guard writeFixedText(to: pasteboard) else { return false }
            }
            return true
        } catch { return false }
    }

    /// The pipe contains our own fixed protocol, never clipboard contents. Bound both endpoints.
    private static func receive(_ marker: String, from handle: FileHandle) throws {
        let expected = Data(marker.utf8)
        var received = Data()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while received.count < expected.count {
            guard ContinuousClock.now < deadline else { throw Failure.childTimeout }
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&descriptor, 1, 100)
            if result < 0 {
                if errno == EINTR { continue }
                throw Failure.childProtocol
            }
            if result == 0 { continue }
            guard descriptor.revents & Int16(POLLERR | POLLNVAL) == 0 else {
                throw Failure.childProtocol
            }
            let part: Data
            do {
                guard let read = try handle.read(upToCount: expected.count - received.count),
                      !read.isEmpty else { throw Failure.childProtocol }
                part = read
            } catch { throw Failure.childProtocol }
            received.append(part)
        }
        guard received == expected else { throw Failure.childProtocol }
    }

    private static func waitForOwnedChild(_ child: Process) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while child.isRunning, ContinuousClock.now < deadline { usleep(10_000) }
        guard !child.isRunning else { throw Failure.childTimeout }
        guard child.terminationReason == .exit, child.terminationStatus == 0 else {
            throw Failure.childExit
        }
    }

    private static func stopOwnedChild(_ child: Process) {
        guard child.isRunning else { return }
        child.terminate()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while child.isRunning, ContinuousClock.now < deadline { usleep(10_000) }
        // Only the exact child Process launched above can reach this cleanup path.
        var killFailed = false
        if child.isRunning {
            let result = Darwin.kill(child.processIdentifier, SIGKILL)
            killFailed = result != 0 && errno != ESRCH
            let killedDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while child.isRunning, ContinuousClock.now < killedDeadline { usleep(10_000) }
        }
        guard !child.isRunning, !killFailed else {
            print("FAIL M3-GENERAL code=CHILD_CLEANUP_UNCONFIRMED")
            exit(1)
        }
    }
}
