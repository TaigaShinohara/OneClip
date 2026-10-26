import Dispatch
import Foundation
import SystemConfiguration

/// Twelve fake-service groups and one real CF-context lifetime regression.
/// The lifetime fixture opens an unsubscribed store, without console-user reads or OS transitions.
@main
struct CaptureConsoleUserMonitorTests {
    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor
    static func main() throws {
        let groups: [(String, @MainActor () throws -> Void)] = [
            ("D06-CONSOLE-01 first start consumes only the initial baseline", testStart),
            ("D06-CONSOLE-02 real callback invalidates without a second polling check", testCallback),
            ("D06-CONSOLE-03 leave-return dirty key blocks adoption despite matching UID", testFence),
            ("D06-CONSOLE-04 missing or other primary UID fails closed", testEligibility),
            ("D06-CONSOLE-05 empty callback is restart, not a clean fence", testRestart),
            ("D06-CONSOLE-06 unexpected callback failure closes monitoring", testCallbackFailure),
            ("D06-CONSOLE-07 partial registration and absent token fail closed", testRegistrationFailure),
            ("D06-CONSOLE-08 failed baseline cleans the store", testBaselineFailure),
            ("D06-CONSOLE-09 runtime fence failure requires explicit restart", testRuntimeFailure),
            ("D06-CONSOLE-10 stop is idempotent and rejects previous-generation callback", testStop),
            ("D06-CONSOLE-11 failed detach stays owned and prevents overlapping registration", testDetachFailure),
            ("D06-CONSOLE-12 queued callback does not retain or dereference a destroyed monitor", testDestruction)
        ]
        for (name, test) in groups {
            try test()
            print("PASS \(name)")
        }
        try testCFContextOffMainLifetime()
        print("PASS D06-CONSOLE-13 real CF context retains/releases off main without actor checks")
        print("PASS \(groups.count) fake console-user groups and 1 real unsubscribed CF-context lifetime group")
    }

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(description: message) }
    }

    @MainActor
    final class Fake {
        let token = UUID()
        var registration: CaptureConsoleUserMonitor.Registration
        var checks: [CaptureConsoleUserMonitor.CheckResult] = [.changed]
        var userID: UInt32? = 501
        var callback: (@MainActor @Sendable (CaptureConsoleUserMonitor.Delivery) -> Void)?
        var registerCalls = 0
        var checked: [UUID] = []
        var cancelled: [UUID] = []
        var detachFails = false
        var invalidations: [CaptureConsoleUserMonitor.Invalidation] = []

        init() { registration = .init(token: token, succeeded: true) }

        func monitor() -> CaptureConsoleUserMonitor {
            let backend = CaptureConsoleUserMonitor.Backend(register: { [self] callback in
                registerCalls += 1
                self.callback = callback
                return registration
            }, check: { [self] token in
                checked.append(token)
                return checks.isEmpty ? .unchanged : checks.removeFirst()
            }, cancel: { [self] token in
                cancelled.append(token)
                return !detachFails
            }, consoleUserID: { [self] in userID }, ownUserID: { 501 })
            return CaptureConsoleUserMonitor(backend: backend) { [self] in invalidations.append($0) }
        }
    }

    @MainActor
    static func testStart() throws {
        let fake = Fake()
        let monitor = fake.monitor()
        try expect(!monitor.isReady && fake.registerCalls == 0, "Initializer subscribed to an OS store")
        monitor.start()
        try expect(monitor.isReady && fake.invalidations.isEmpty && fake.checked == [fake.token],
                   "Initial dirty baseline was not consumed before material exists")
        fake.checks.append(.changed)
        monitor.start()
        try expect(fake.registerCalls == 1 && fake.checked.count == 1, "Repeated start discarded a pending change")
        try expect(!monitor.validate() && fake.invalidations == [.changed], "Repeated start bypassed the fence")
    }

    @MainActor
    static func testCallback() throws {
        let fake = Fake()
        let monitor = fake.monitor()
        monitor.start()
        let checked = fake.checked
        fake.callback?(.changed)
        try expect(!monitor.isReady && fake.invalidations == [.changed] && fake.checked == checked,
                   "Callback re-polled the framework-consumed dirty list or failed to invalidate")
        try expect(monitor.validate(), "A new explicit operation could not recover on the same primary UID")
        fake.callback?(.changed)
        try expect(!monitor.isReady && fake.invalidations == [.changed, .changed],
                   "A later real callback was ignored because current UID matched")
    }

    @MainActor
    static func testFence() throws {
        let fake = Fake()
        let monitor = fake.monitor()
        monitor.start()
        fake.checks.append(.changed)
        try expect(!monitor.validate() && !monitor.isReady && fake.invalidations == [.changed],
                   "Returning to the original UID bypassed a pending console change")
        // The live framework skips an ordinary queued callback after this synchronous consumption
        // leaves its CopyNotifiedKeys list empty. Only a new explicit validation permits reuse.
        try expect(monitor.validate() && fake.invalidations == [.changed], "Clean explicit recovery failed")
    }

    @MainActor
    static func testEligibility() throws {
        let fake = Fake()
        fake.userID = nil
        let monitor = fake.monitor()
        monitor.start()
        try expect(!monitor.isReady && fake.invalidations == [.unavailable], "Missing primary user accepted")
        fake.userID = 502
        try expect(!monitor.validate() && fake.invalidations == [.unavailable], "Different primary user accepted")
        fake.userID = 501
        try expect(!monitor.isReady, "Snapshot recovery auto-resumed")
        try expect(monitor.validate(), "Matching primary user could not explicitly recover")
        fake.userID = 0
        try expect(!monitor.validate() && fake.invalidations == [.unavailable, .unavailable], "Login-window UID accepted")
        try expect(fake.cancelled.isEmpty, "Temporary primary-user mismatch discarded the subscription")
    }

    @MainActor
    static func testRestart() throws {
        let fake = Fake()
        let monitor = fake.monitor()
        monitor.start()
        fake.callback?(.restarted)
        try expect(!monitor.isReady && !monitor.validate() && fake.invalidations == [.unavailable]
                   && fake.cancelled == [fake.token], "Empty restart callback was treated as no change")
        fake.checks = [.unchanged]
        monitor.start()
        try expect(monitor.isReady && fake.registerCalls == 2, "Explicit restart failed after server reset")
    }

    @MainActor
    static func testCallbackFailure() throws {
        let fake = Fake()
        let monitor = fake.monitor()
        monitor.start()
        fake.callback?(.failed)
        try expect(!monitor.isReady && !monitor.validate() && fake.invalidations == [.unavailable]
                   && fake.cancelled == [fake.token], "Unexpected callback data kept the old session usable")
    }

    @MainActor
    static func testRegistrationFailure() throws {
        let fake = Fake()
        fake.registration = .init(token: fake.token, succeeded: false)
        let monitor = fake.monitor()
        monitor.start()
        try expect(!monitor.validate() && fake.cancelled == [fake.token] && fake.checked.isEmpty,
                   "Partial registration was accepted or leaked")
        try expect(fake.invalidations == [.unavailable], "Registration failure did not invalidate")
        let absent = Fake()
        absent.registration = .init(token: nil, succeeded: true)
        let absentMonitor = absent.monitor()
        absentMonitor.start()
        try expect(!absentMonitor.validate() && absent.checked.isEmpty && absent.invalidations == [.unavailable],
                   "Success without a subscription token was accepted")
    }

    @MainActor
    static func testBaselineFailure() throws {
        let fake = Fake()
        fake.checks = [.failed]
        let monitor = fake.monitor()
        monitor.start()
        try expect(!monitor.isReady && !monitor.validate() && fake.cancelled == [fake.token]
                   && fake.invalidations == [.unavailable], "Failed baseline left capture available")
    }

    @MainActor
    static func testRuntimeFailure() throws {
        let fake = Fake()
        let monitor = fake.monitor()
        monitor.start()
        let old = fake.callback
        fake.checks.append(.failed)
        try expect(!monitor.validate() && fake.cancelled == [fake.token], "Failed sync fence kept subscription usable")
        old?(.changed)
        try expect(fake.invalidations == [.unavailable], "Old callback survived runtime failure")
        fake.checks = [.unchanged]
        monitor.start()
        try expect(monitor.isReady && fake.registerCalls == 2, "Explicit start did not recover runtime failure")
    }

    @MainActor
    static func testStop() throws {
        let fake = Fake()
        let monitor = fake.monitor()
        monitor.start()
        let old = fake.callback
        monitor.stop()
        monitor.stop()
        try expect(fake.cancelled == [fake.token] && !monitor.validate(), "Stop leaked or cancelled twice")
        fake.registration = .init(token: UUID(), succeeded: true)
        fake.checks = [.unchanged]
        monitor.start()
        old?(.changed)
        try expect(monitor.isReady && fake.invalidations.isEmpty, "Previous generation invalidated a new session")
        fake.callback?(.changed)
        try expect(!monitor.isReady && fake.invalidations == [.changed], "New subscription callback was ignored")
    }

    @MainActor
    static func testDetachFailure() throws {
        let fake = Fake()
        let monitor = fake.monitor()
        monitor.start()
        let old = fake.callback
        fake.detachFails = true
        monitor.stop()
        old?(.changed)
        monitor.start()
        try expect(fake.registerCalls == 1 && !monitor.validate() && !monitor.isReady,
                   "Failed detach allowed overlapping subscriptions")
        fake.detachFails = false
        monitor.stop()
        fake.checks = [.unchanged]
        monitor.start()
        try expect(monitor.isReady && fake.registerCalls == 2, "Owned failed detach could not be retried")
    }

    @MainActor
    static func testDestruction() throws {
        let fake = Fake()
        var monitor: CaptureConsoleUserMonitor? = fake.monitor()
        weak var weakMonitor = monitor
        monitor?.start()
        let queued = fake.callback
        monitor = nil
        try expect(weakMonitor == nil, "Queued callback retained the monitor")
        queued?(.changed)
        queued?(.restarted)
        try expect(fake.invalidations.isEmpty, "Queued callback reached a destroyed monitor")
    }

    @MainActor
    static func testCFContextOffMainLifetime() throws {
        let completed = DispatchSemaphore(value: 0)
        let outcome = ConsoleContextLifetimeOutcome()
        // async is essential: a synchronous dispatch may execute inline on the calling thread.
        DispatchQueue.global(qos: .userInitiated).async {
            outcome.store(runConsoleContextLifetimeTrial())
            completed.signal()
        }
        guard completed.wait(timeout: .now() + 10) == .success else {
            throw Failure(description: "Real CF-context worker did not finish")
        }
        guard let result = outcome.load() else { throw Failure(description: "CF-context result missing") }
        try expect(result.offMain, "CF lifetime regression ran on the main thread")
        try expect(result.created, "Could not create the real unsubscribed SCDynamicStore fixture")
        try expect(result.retainedByCF, "CF did not retain the production context after local ownership ended")
        try expect(result.releasedByCF, "Off-main final CF release did not release the production context")
    }
}

private struct ConsoleContextLifetimeResult: Sendable {
    let offMain: Bool
    let created: Bool
    let retainedByCF: Bool
    let releasedByCF: Bool
}

/// Only the small fixed result crosses queues; the CF reference and weak probe stay on the worker.
private final class ConsoleContextLifetimeOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ConsoleContextLifetimeResult?

    func store(_ result: ConsoleContextLifetimeResult) {
        lock.lock()
        defer { lock.unlock() }
        self.result = result
    }

    func load() -> ConsoleContextLifetimeResult? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

private final class WeakConsoleContextProbe {
    weak var value: ConsoleUserCallbackContext?
}

private nonisolated func consoleContextLifetimeFixtureCallback(_ store: SCDynamicStore, _ keys: CFArray,
                                                              _ info: UnsafeMutableRawPointer?) {
    // No keys or queue are registered for this fixture, so no notification is expected.
}

private nonisolated func makeConsoleContextLifetimeFixture(_ probe: WeakConsoleContextProbe)
    -> Unmanaged<SCDynamicStore>? {
    let box = ConsoleUserCallbackContext(key: SCDynamicStoreKeyCreateConsoleUser(nil) as String,
                                        delivered: { _ in })
    probe.value = box
    var context = makeConsoleUserStoreContext(box)
    guard let store = SCDynamicStoreCreate(nil, "OneClip CF context lifetime regression" as CFString,
                                          consoleContextLifetimeFixtureCallback, &context) else { return nil }
    // Returning an explicit retained CF reference ends the local Swift owners in this function.
    // Its matching release in the worker must execute the real CF context-release callback there.
    return Unmanaged.passRetained(store)
}

private nonisolated func runConsoleContextLifetimeTrial() -> ConsoleContextLifetimeResult {
    let offMain = !Thread.isMainThread
    let probe = WeakConsoleContextProbe()
    guard let store = makeConsoleContextLifetimeFixture(probe) else {
        return .init(offMain: offMain, created: false, retainedByCF: false, releasedByCF: false)
    }
    let retained = probe.value != nil
    store.release()
    return .init(offMain: offMain, created: true, retainedByCF: retained, releasedByCF: probe.value == nil)
}
