import Foundation

/// Fake notify/session services only. No OS transition, real subscription, screen or pasteboard.
@main
struct CaptureSessionMonitorTests {
    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor
    static func main() throws {
        let groups: [(String, @MainActor () throws -> Void)] = [
            ("D06-SESSION-01 explicit start primes separate check token", testStart),
            ("D06-SESSION-02 dispatch consumes one change and requires explicit resume", testDispatch),
            ("D06-SESSION-03 validation fences leave-return before delayed dispatch", testFence),
            ("D06-SESSION-04 unchanged dispatch conservatively stops a new operation", testDuplicate),
            ("D06-SESSION-05 off-console and missing session retain subscriptions", testUnavailable),
            ("D06-SESSION-06 login and own-user eligibility fail closed", testEligibility),
            ("D06-SESSION-07 dispatch registration failure cleans partial token", testDispatchFailure),
            ("D06-SESSION-08 check registration failure cleans both tokens", testCheckFailure),
            ("D06-SESSION-09 prime failure cleans subscriptions", testPrimeFailure),
            ("D06-SESSION-10 runtime check failure prevents use and allows explicit restart", testRuntimeFailure),
            ("D06-SESSION-11 stop is idempotent and rejects old queued delivery", testStopAndRestart),
            ("D06-SESSION-12 failed cancellation stays owned until cleanup succeeds", testCleanupFailure)
        ]
        for (name, test) in groups {
            try test()
            print("PASS \(name)")
        }
        print("PASS \(groups.count) console-session groups; fake services only")
    }

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(description: message) }
    }

    @MainActor
    final class Fake {
        var dispatchRegistration = CaptureSessionMonitor.Registration(token: 11, succeeded: true)
        var checkRegistration = CaptureSessionMonitor.Registration(token: 12, succeeded: true)
        var checks: [CaptureSessionMonitor.CheckResult] = [.changed]
        var snapshot: CaptureSessionMonitor.SessionSnapshot? = .init(onConsole: true, loginDone: true, userID: 501)
        var callback: (@MainActor @Sendable () -> Void)?
        var dispatchCalls = 0
        var checkRegistrationCalls = 0
        var checkedTokens: [Int32] = []
        var cancelled: [Int32] = []
        var cancelFailures: Set<Int32> = []
        var invalidations: [CaptureSessionMonitor.Invalidation] = []

        func makeMonitor() -> CaptureSessionMonitor {
            let backend = CaptureSessionMonitor.Backend(registerDispatch: { [self] callback in
                dispatchCalls += 1
                self.callback = callback
                return dispatchRegistration
            }, registerCheck: { [self] in
                checkRegistrationCalls += 1
                return checkRegistration
            }, check: { [self] token in
                checkedTokens.append(token)
                return checks.isEmpty ? .unchanged : checks.removeFirst()
            }, cancel: { [self] token in
                cancelled.append(token)
                return !cancelFailures.contains(token)
            }, session: { [self] in snapshot }, ownUserID: { 501 })
            return CaptureSessionMonitor(backend: backend) { [self] in invalidations.append($0) }
        }

        func emit(_ result: CaptureSessionMonitor.CheckResult = .changed) {
            checks.append(result)
            callback?()
        }
    }

    @MainActor
    static func testStart() throws {
        let fake = Fake()
        let monitor = fake.makeMonitor()
        try expect(!monitor.isReady && fake.dispatchCalls == 0, "Initializer registered a notification")
        monitor.start()
        try expect(monitor.isReady && fake.invalidations.isEmpty, "Initial notify_check true was an invalidation")
        try expect(fake.checkedTokens == [12], "Polled dispatch token instead of separate check token")
        monitor.start()
        try expect(fake.dispatchCalls == 1 && fake.checkedTokens == [12], "Idempotent start reset the fence")
        try expect(monitor.validate(), "Stable console rejected")
    }

    @MainActor
    static func testDispatch() throws {
        let fake = Fake()
        let monitor = fake.makeMonitor()
        monitor.start()
        fake.emit()
        try expect(!monitor.isReady && fake.invalidations == [.consoleChanged], "Dispatch change did not invalidate")
        fake.emit(.unchanged)
        try expect(!monitor.isReady && fake.invalidations == [.consoleChanged, .consoleChanged], "Unchanged check vetoed a delivered safety signal")
        try expect(monitor.validate() && monitor.isReady, "New explicit validation did not allow resume")
    }

    @MainActor
    static func testFence() throws {
        let fake = Fake()
        let monitor = fake.makeMonitor()
        monitor.start()
        // Session has left and returned before the main-queue dispatch can be delivered.
        fake.checks.append(.changed)
        try expect(!monitor.validate(), "Current on-console snapshot bypassed the leave-return fence")
        try expect(fake.invalidations == [.consoleChanged], "Fence did not invalidate exactly once")
        fake.callback?()
        try expect(fake.invalidations == [.consoleChanged, .consoleChanged] && !monitor.isReady, "Delayed delivery was ignored or resumed")
        try expect(monitor.validate(), "Explicit new operation after fence consumption failed")
    }

    @MainActor
    static func testDuplicate() throws {
        let fake = Fake()
        let monitor = fake.makeMonitor()
        monitor.start()
        fake.checks.append(.changed)
        try expect(!monitor.validate(), "Change ignored")
        try expect(monitor.validate(), "New operation was not ready")
        let before = fake.invalidations
        fake.callback?()
        try expect(!monitor.isReady && fake.invalidations == before + [.consoleChanged], "Delayed safety signal was ignored")
        try expect(monitor.validate(), "New explicit operation could not recover from a delayed delivery")
    }

    @MainActor
    static func testUnavailable() throws {
        let fake = Fake()
        let monitor = fake.makeMonitor()
        monitor.start()
        fake.snapshot = .init(onConsole: false, loginDone: true, userID: 501)
        try expect(!monitor.validate() && fake.invalidations == [.unavailable], "Off-console use was accepted")
        fake.snapshot = nil
        try expect(!monitor.validate() && fake.invalidations == [.unavailable], "Missing session accepted or duplicate invalidation")
        try expect(fake.cancelled.isEmpty, "Temporary unavailability cancelled subscriptions")
        fake.snapshot = .init(onConsole: true, loginDone: true, userID: 501)
        fake.emit(.unchanged)
        try expect(!monitor.isReady, "Console return auto-resumed")
        try expect(monitor.validate(), "Explicit console return did not recover")
        fake.snapshot = nil
        try expect(!monitor.validate() && fake.invalidations == [.unavailable, .consoleChanged, .unavailable], "New unavailable interval was not reported")
    }

    @MainActor
    static func testEligibility() throws {
        let fake = Fake()
        fake.snapshot = .init(onConsole: true, loginDone: false, userID: 501)
        let monitor = fake.makeMonitor()
        monitor.start()
        try expect(!monitor.isReady && fake.invalidations == [.unavailable], "Incomplete login accepted at start")
        fake.snapshot = .init(onConsole: true, loginDone: true, userID: 502)
        try expect(!monitor.validate(), "Different user ID accepted")
        fake.snapshot = .init(onConsole: true, loginDone: true, userID: 501)
        try expect(monitor.validate(), "Matching user could not explicitly recover")
    }

    @MainActor
    static func testDispatchFailure() throws {
        let fake = Fake()
        fake.dispatchRegistration = .init(token: 11, succeeded: false)
        let monitor = fake.makeMonitor()
        monitor.start()
        try expect(!monitor.validate() && !monitor.isReady, "Failed registration allowed use")
        try expect(fake.cancelled == [11] && fake.checkRegistrationCalls == 0, "Partial dispatch registration leaked")
        try expect(fake.invalidations == [.unavailable], "Setup failure did not report unavailable")
        let missing = Fake()
        missing.dispatchRegistration = .init(token: nil, succeeded: true)
        let missingMonitor = missing.makeMonitor()
        missingMonitor.start()
        try expect(!missingMonitor.validate() && missing.checkRegistrationCalls == 0, "Success without a token accepted")
    }

    @MainActor
    static func testCheckFailure() throws {
        let fake = Fake()
        fake.checkRegistration = .init(token: 12, succeeded: false)
        let monitor = fake.makeMonitor()
        monitor.start()
        try expect(!monitor.validate() && fake.cancelled == [11, 12], "Partial check registration leaked")
        try expect(fake.checkedTokens.isEmpty, "Failed check token was polled")
        let duplicate = Fake()
        duplicate.checkRegistration = .init(token: 11, succeeded: true)
        let duplicateMonitor = duplicate.makeMonitor()
        duplicateMonitor.start()
        try expect(!duplicateMonitor.validate() && duplicate.cancelled == [11],
                   "Duplicate dispatch/check token was accepted or cancelled twice")
    }

    @MainActor
    static func testPrimeFailure() throws {
        let fake = Fake()
        fake.checks = [.failed]
        let monitor = fake.makeMonitor()
        monitor.start()
        try expect(!monitor.isReady && !monitor.validate(), "Failed initial check allowed use")
        try expect(fake.cancelled == [11, 12] && fake.invalidations == [.unavailable], "Prime failure did not clean up")
    }

    @MainActor
    static func testRuntimeFailure() throws {
        let fake = Fake()
        let monitor = fake.makeMonitor()
        monitor.start()
        fake.checks.append(.failed)
        try expect(!monitor.validate() && fake.cancelled == [11, 12], "Failed runtime check did not close subscriptions")
        fake.callback?()
        try expect(fake.invalidations == [.unavailable], "Old callback survived runtime failure")
        fake.checks = [.changed]
        monitor.start()
        try expect(monitor.isReady && fake.dispatchCalls == 2, "Explicit restart could not recover monitoring")
    }

    @MainActor
    static func testStopAndRestart() throws {
        let fake = Fake()
        let monitor = fake.makeMonitor()
        monitor.start()
        let old = fake.callback
        monitor.stop()
        monitor.stop()
        try expect(fake.cancelled == [11, 12] && !monitor.validate(), "Stop leaked, duplicated cancels, or permitted use")
        fake.dispatchRegistration = .init(token: 21, succeeded: true)
        fake.checkRegistration = .init(token: 22, succeeded: true)
        fake.checks = [.changed]
        monitor.start()
        fake.checks = [.changed]
        let before = fake.checkedTokens
        old?()
        try expect(fake.checkedTokens == before, "Previous generation consumed the new fence")
        try expect(!monitor.validate() && fake.checkedTokens.last == 22, "New generation did not see its pending change")
    }

    @MainActor
    static func testCleanupFailure() throws {
        let fake = Fake()
        let monitor = fake.makeMonitor()
        monitor.start()
        fake.cancelFailures = [11]
        monitor.stop()
        try expect(fake.cancelled == [11, 12] && !monitor.isReady, "Failed cancel lost state")
        monitor.start()
        try expect(fake.dispatchCalls == 1 && !monitor.validate(), "Restart overlapped a registration pending cleanup")
        fake.cancelFailures = []
        monitor.stop()
        try expect(fake.cancelled.last == 11, "Pending cancel was not retried")
        fake.checks = [.changed]
        monitor.start()
        try expect(monitor.isReady && fake.dispatchCalls == 2, "Cleanup recovery did not permit explicit restart")
    }
}
