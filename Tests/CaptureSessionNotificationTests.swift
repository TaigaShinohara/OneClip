import Darwin
import Dispatch
import Foundation
import notify

/// Actual libnotify mechanics under a fresh test-owned name only.
/// Never posts an OS notification name or accesses session, screen, clipboard or TCC data.
@main
struct CaptureSessionNotificationTests {
    enum Failure: Error { case api, expectation, timeout }
    enum Phase: String {
        case baseline = "D06-NOTIFY-01 baseline"
        case delivery = "D06-NOTIFY-02 repeated delivery"
        case fencePost = "D06-NOTIFY-03A post API"
        case fenceCheckAPI = "D06-NOTIFY-03B immediate check API"
        case fenceChanged = "D06-NOTIFY-03C observe immediate visibility"
        case fenceQueued = "D06-NOTIFY-03D dispatch still queued before suspension"
        case fenceDelivery = "D06-NOTIFY-03E later dispatch arrives within bound"
        case fenceCallbackAPI = "D06-NOTIFY-03F callback check API"
        case fenceDuplicate = "D06-NOTIFY-03G later dispatch agrees with immediate observation"
        case fenceFinalCheckAPI = "D06-NOTIFY-03H final check API"
        case fenceFinalUnchanged = "D06-NOTIFY-03I final fence remains unchanged"
        case confirmedSetup = "D06-NOTIFY-03J suspend test-owned dispatch before post"
        case confirmedFence = "D06-NOTIFY-03K posted change observed while dispatch is suspended"
        case confirmedResume = "D06-NOTIFY-03L resume test-owned dispatch"
        case confirmedDuplicate = "D06-NOTIFY-03M delayed dispatch observes previously consumed change"
        case restart = "D06-NOTIFY-04 cleanup and registration restart"
    }

    @MainActor
    static func main() async {
        let probe = Probe()
        var phase = Phase.baseline
        defer { _ = probe.stop() }
        do {
            try probe.start()
            try require(try probe.check() == 0)
            print("PASS \(phase.rawValue)")

            phase = .delivery
            // One bounded stage at a time. No assertion about a total number of coalesced events.
            for _ in 0..<3 {
                let before = probe.changedCallbacks
                try probe.post()
                try await waitUntil { probe.callbackFailed || probe.changedCallbacks > before }
                try require(!probe.callbackFailed)
                try require(try probe.check() == 0)
            }
            print("PASS \(phase.rawValue)")

            phase = .fencePost
            let beforeCallbacks = probe.callbackCount
            let beforeChanged = probe.changedCallbacks
            let beforeDuplicates = probe.unchangedCallbacks
            try probe.post()
            print("PASS \(phase.rawValue)")
            // No suspension between post and check: the main-queue callback cannot run first.
            // The original test failed at 03C on this Mac: post returned OK but this check was 0.
            // That assertion assumed synchronous server visibility. Apple's public notify_client.c
            // uses async MIG post_3/post_4, while a memory-token check only reads shared memory:
            // https://github.com/apple-oss-distributions/Libnotify/blob/main/notify_client.c#L1982-L1999
            // https://github.com/apple-oss-distributions/Libnotify/blob/main/notify_client.c#L3502-L3527
            // This explains why immediate 0 is possible; it does not identify the OS-transition
            // failure's cause or prove the installed library matches that source. Keep the old
            // failure recorded here. Neither possible observation provides an atomic OS fence.
            phase = .fenceCheckAPI
            let immediatelyChanged = try probe.check()
            print("PASS \(phase.rawValue)")
            phase = .fenceChanged
            print(immediatelyChanged == 0
                  ? "OBSERVED D06-NOTIFY-03C immediate unchanged"
                  : "OBSERVED D06-NOTIFY-03C immediate changed")
            phase = .fenceQueued
            try require(probe.callbackCount == beforeCallbacks)
            print("PASS \(phase.rawValue)")
            phase = .fenceDelivery
            try await waitUntil { probe.callbackFailed || probe.callbackCount > beforeCallbacks }
            print("PASS \(phase.rawValue)")
            phase = .fenceCallbackAPI
            try require(!probe.callbackFailed)
            print("PASS \(phase.rawValue)")
            phase = .fenceDuplicate
            if immediatelyChanged == 0 {
                try require(probe.changedCallbacks > beforeChanged)
            } else {
                try require(probe.changedCallbacks == beforeChanged && probe.unchangedCallbacks > beforeDuplicates)
            }
            print("PASS \(phase.rawValue)")
            phase = .fenceFinalCheckAPI
            let finalChange = try probe.check()
            print("PASS \(phase.rawValue)")
            phase = .fenceFinalUnchanged
            try require(finalChange == 0)
            print("PASS \(phase.rawValue)")

            // Separately establish a consumed fence without assuming post's return is an ack.
            // Suspending only a fresh test-owned dispatch token leaves its separate check active.
            // The wait ends on an observed check==1, not on elapsed time or an arbitrary sleep.
            let delayedProbe = Probe()
            defer { _ = delayedProbe.stop() }
            phase = .confirmedSetup
            try delayedProbe.start()
            try delayedProbe.suspendDispatch()
            let delayedBeforeCallbacks = delayedProbe.callbackCount
            let delayedBeforeChanges = delayedProbe.changedCallbacks
            let delayedBeforeDuplicates = delayedProbe.unchangedCallbacks
            try delayedProbe.post()
            print("PASS \(phase.rawValue)")
            phase = .confirmedFence
            try await waitForPostedChange(delayedProbe)
            try require(delayedProbe.callbackCount == delayedBeforeCallbacks)
            print("PASS \(phase.rawValue)")
            phase = .confirmedResume
            try delayedProbe.resumeDispatch()
            try await waitUntil { delayedProbe.callbackFailed || delayedProbe.callbackCount > delayedBeforeCallbacks }
            print("PASS \(phase.rawValue)")
            phase = .confirmedDuplicate
            try require(!delayedProbe.callbackFailed && delayedProbe.changedCallbacks == delayedBeforeChanges
                        && delayedProbe.unchangedCallbacks > delayedBeforeDuplicates)
            try require(delayedProbe.stop())
            print("PASS \(phase.rawValue)")

            phase = .restart
            try require(probe.stop())
            try require(probe.stop())
            // A post while unsubscribed must be part of the new registration's baseline only.
            try probe.post()
            try probe.start()
            try require(try probe.check() == 0)
            let beforeRestartDelivery = probe.changedCallbacks
            try probe.post()
            try await waitUntil { probe.callbackFailed || probe.changedCallbacks > beforeRestartDelivery }
            try require(!probe.callbackFailed && (try probe.check()) == 0)
            try require(probe.stop())
            print("PASS \(phase.rawValue)")
        } catch {
            // The name, registration tokens, UID and error payload never reach the output.
            print("FAIL \(phase.rawValue)")
            _ = probe.stop()
            exit(1)
        }
    }

    static func require(_ condition: Bool) throws {
        guard condition else { throw Failure.expectation }
    }

    @MainActor
    static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    static func waitForPostedChange(_ probe: Probe) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while try probe.check() == 0 {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    final class Probe {
        // This is the only name ever passed to notify_post by this executable.
        private let name = "local.OneClip.test.\(UUID().uuidString)"
        private var dispatchToken: Int32?
        private var checkToken: Int32?
        private var generation: UUID?
        private(set) var callbackCount = 0
        private(set) var changedCallbacks = 0
        private(set) var unchangedCallbacks = 0
        private(set) var callbackFailed = false

        func start() throws {
            guard dispatchToken == nil, checkToken == nil, generation == nil else { throw Failure.expectation }
            let identifier = UUID()
            generation = identifier
            var dispatch: Int32 = -1
            let dispatchStatus = name.withCString {
                notify_register_dispatch($0, &dispatch, .main) { [weak self] _ in
                    // The supplied dispatch queue is main; consume without a second enqueue.
                    MainActor.assumeIsolated {
                        guard let self, self.generation == identifier else { return }
                        self.receive()
                    }
                }
            }
            if dispatch >= 0 { dispatchToken = dispatch }
            guard dispatchStatus == UInt32(NOTIFY_STATUS_OK), dispatchToken != nil else { throw Failure.api }
            var check: Int32 = -1
            let checkStatus = name.withCString { notify_register_check($0, &check) }
            if check >= 0 { checkToken = check }
            guard checkStatus == UInt32(NOTIFY_STATUS_OK), checkToken != nil,
                  checkToken != dispatchToken else { throw Failure.api }
            // notify.h specifies true for the first notify_check of each check registration.
            try CaptureSessionNotificationTests.require(try self.check() == 1)
            callbackFailed = false
        }

        func check() throws -> Int32 {
            guard let checkToken else { throw Failure.expectation }
            var changed: Int32 = -1
            guard notify_check(checkToken, &changed) == UInt32(NOTIFY_STATUS_OK),
                  changed == 0 || changed == 1 else { throw Failure.api }
            return changed
        }

        func post() throws {
            guard name.withCString({ notify_post($0) }) == UInt32(NOTIFY_STATUS_OK) else { throw Failure.api }
        }

        func suspendDispatch() throws {
            guard let dispatchToken,
                  notify_suspend(dispatchToken) == UInt32(NOTIFY_STATUS_OK) else { throw Failure.api }
        }

        func resumeDispatch() throws {
            guard let dispatchToken,
                  notify_resume(dispatchToken) == UInt32(NOTIFY_STATUS_OK) else { throw Failure.api }
        }

        private func receive() {
            callbackCount += 1
            do {
                if try check() == 1 { changedCallbacks += 1 }
                else { unchangedCallbacks += 1 }
            } catch { callbackFailed = true }
        }

        @discardableResult
        func stop() -> Bool {
            generation = nil
            if let dispatchToken, notify_cancel(dispatchToken) == UInt32(NOTIFY_STATUS_OK) {
                self.dispatchToken = nil
            }
            if let checkToken, notify_cancel(checkToken) == UInt32(NOTIFY_STATUS_OK) {
                self.checkToken = nil
            }
            return dispatchToken == nil && checkToken == nil
        }
    }
}
