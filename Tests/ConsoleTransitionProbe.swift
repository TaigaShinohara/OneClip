import CoreGraphics
import Darwin
import Foundation
import SystemConfiguration

/// Read-only, unsandboxed CLI diagnostic. Compile with the two production monitor source files.
/// It observes only eligibility and aggregate monitor outcomes; it never captures or resumes work.
/// No names, UID values, dictionaries, sample times or transition history are recorded or printed.
@main
struct ConsoleTransitionProbe {
    @MainActor
    final class Totals {
        var finished = false
        var samples = 0
        var cgChanged = 0
        var cgUnavailable = 0
        var scChanged = 0
        var scUnavailable = 0
        var cgValidationRejected = 0
        var scValidationRejected = 0
        var sawCGMismatch = false
        var cgSnapshotUnknown = 0
        var sawOtherPrimaryUser = false
        var primaryUserUnknown = 0
        var maximumPollMilliseconds = 0.0

        func finish() { finished = true }
    }

    @MainActor
    static func main() async {
        let totals = Totals()
        let initialCG = cgSelfEligibility()
        let initialPrimary = primarySelfEligibility()
        let cg = CaptureSessionMonitor { reason in
            switch reason {
            case .consoleChanged: totals.cgChanged += 1
            case .unavailable: totals.cgUnavailable += 1
            }
        }
        let sc = CaptureConsoleUserMonitor { reason in
            switch reason {
            case .changed: totals.scChanged += 1
            case .unavailable: totals.scUnavailable += 1
            }
        }
        cg.start()
        sc.start()
        print("READY CG=\(cg.isReady ? 1 : 0) SC=\(sc.isReady ? 1 : 0)")
        print("CG_SELF_ELIGIBILITY_START \(eligibilityCode(initialCG))")
        print("PRIMARY_SELF_ELIGIBILITY_START \(eligibilityCode(initialPrimary))")
        fflush(nil)

        // The program does not print/store input. A PTY may echo the control word supplied by its caller.
        // EOF also ends the probe and closes subscriptions.
        // Blocking readLine is confined to this detached utility task, never the main queue.
        let input = Task.detached(priority: .utility) {
            while let line = readLine() {
                if line == "finish" {
                    await totals.finish()
                    return
                }
            }
            await totals.finish()
        }
        var previousPoll: ContinuousClock.Instant?
        repeat {
            let now = ContinuousClock.now
            if let previousPoll {
                let elapsed = previousPoll.duration(to: now).components
                let milliseconds = Double(elapsed.seconds) * 1_000
                    + Double(elapsed.attoseconds) / 1_000_000_000_000_000
                totals.maximumPollMilliseconds = max(totals.maximumPollMilliseconds, milliseconds)
            }
            previousPoll = now // Only one prior instant exists; no sample-time array/history.
            totals.samples += 1
            if !cg.validate() { totals.cgValidationRejected += 1 }
            if !sc.validate() { totals.scValidationRejected += 1 }
            switch cgSelfEligibility() {
            case true?: break
            case false?: totals.sawCGMismatch = true
            case nil:
                totals.cgSnapshotUnknown += 1
            }
            switch primarySelfEligibility() {
            case true?: break
            case false?: totals.sawOtherPrimaryUser = true
            case nil: totals.primaryUserUnknown += 1
            }
            if totals.finished { break }
            try? await Task.sleep(for: .milliseconds(250))
        } while !totals.finished

        // Do not auto-restart either monitor: re-priming would erase evidence of this interval.
        // A runtime monitor failure remains a rejected diagnostic check until this process exits.
        cg.stop()
        sc.stop()
        await input.value
        print("SAMPLES \(totals.samples)")
        print("CG_START_ATTEMPTS 1")
        print("SC_START_ATTEMPTS 1")
        print("CG_RESTART_ATTEMPTS 0")
        print("SC_RESTART_ATTEMPTS 0")
        print("CG_CHANGED \(totals.cgChanged)")
        print("CG_UNAVAILABLE \(totals.cgUnavailable)")
        print("SC_CHANGED \(totals.scChanged)")
        print("SC_UNAVAILABLE \(totals.scUnavailable)")
        print("CG_VALIDATION_REJECTED \(totals.cgValidationRejected)")
        print("SC_VALIDATION_REJECTED \(totals.scValidationRejected)")
        print("SAW_CG_MISMATCH \(totals.sawCGMismatch ? 1 : 0)")
        print("CG_SNAPSHOT_UNKNOWN \(totals.cgSnapshotUnknown)")
        print("SAW_OTHER_PRIMARY_USER \(totals.sawOtherPrimaryUser ? 1 : 0)")
        print("PRIMARY_USER_UNKNOWN \(totals.primaryUserUnknown)")
        print("MAX_POLL_MILLISECONDS \(Int(totals.maximumPollMilliseconds.rounded(.up)))")
        // The stop APIs return no cleanup result; do not equate isReady==false with cancellation proof.
        print("STOP_REQUESTED CG=1 SC=1")
        // Missing this marker means the final aggregate was not obtained, never "zero changes".
        // It marks completion of this diagnostic output, not a successful OS transition or D06 gate.
        print("SUMMARY_COMPLETE")
        fflush(nil)
    }

    /// A qualification flag only: -1 is unknown, 0 is not eligible, 1 is eligible.
    static func eligibilityCode(_ value: Bool?) -> Int {
        guard let value else { return -1 }
        return value ? 1 : 0
    }

    /// Read only the three published CG session fields and compare the transient UID locally.
    static func cgSelfEligibility() -> Bool? {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any],
              let onConsole = dictionary[kCGSessionOnConsoleKey as String] as? Bool,
              let loginDone = dictionary[kCGSessionLoginDoneKey as String] as? Bool,
              let userID = dictionary[kCGSessionUserIDKey as String] as? UInt32 else { return nil }
        return onConsole && loginDone && userID == getuid()
    }

    /// The returned name is checked only for presence, then immediately released without use.
    static func primarySelfEligibility() -> Bool? {
        var userID = uid_t.max
        guard SCDynamicStoreCopyConsoleUser(nil, &userID, nil) != nil else { return nil }
        return userID == getuid()
    }
}
