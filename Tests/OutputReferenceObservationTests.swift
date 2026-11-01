/// Pure Swift class controls only: no CoreGraphics, provider, image, file, board or UI operation.
@main
struct OutputReferenceObservationTests {
    struct Failure: Error { let code: String }

    final class Counter { var releases = 0 }
    final class Object {
        let counter: Counter?
        init(counter: Counter? = nil) { self.counter = counter }
        deinit { counter?.releases += 1 }
    }
    final class WeakSlot { weak var value: Object? }

    static func require(_ value: @autoclosure () -> Bool, _ code: String) throws {
        guard value() else { throw Failure(code: code) }
    }

    static func main() throws {
        let object = Object(), slot = WeakSlot()
        slot.value = object
        try require(OutputReferenceObservation.matchesIdentity(of: object) { slot.value },
                    "IDENTITY_READBACK_NOT_CONFIRMED")
        print("PASS OUTPUT-REFERENCE-01 actual registered identity is confirmed")

        let absent = WeakSlot()
        try require(!OutputReferenceObservation.matchesIdentity(of: object) { absent.value },
                    "ABSENT_REGISTRATION_ACCEPTED")
        print("PASS OUTPUT-REFERENCE-02 absent weak registration stays unobserved")

        let other = Object(), wrong = WeakSlot()
        wrong.value = other
        try require(!OutputReferenceObservation.matchesIdentity(of: object) { wrong.value },
                    "WRONG_IDENTITY_ACCEPTED")
        let stale = WeakSlot()
        registerExpiredObject(in: stale)
        try require(stale.value == nil, "STALE_CONTROL_STILL_RETAINED")
        try require(!OutputReferenceObservation.matchesIdentity(of: object) { stale.value },
                    "STALE_IDENTITY_ACCEPTED")
        print("PASS OUTPUT-REFERENCE-03 different and expired references are rejected")

        let counter = Counter(), fenced = WeakSlot()
        let inside = confirmWhileDroppingCallerReference(slot: fenced, counter: counter)
        try require(inside.confirmed && inside.aliveDuringReadback, "STRONG_FENCE_MISSING")
        try require(fenced.value == nil && counter.releases == 1, "HELPER_RETAINED_OBJECT")
        print("PASS OUTPUT-REFERENCE-04 strong fence survives caller release and ends with the call scope")

        var observed = OutputReferenceObservation.matchesIdentity(of: object) { slot.value }
        try require(observed, "REPEATED_INITIAL_CONFIRMATION_FAILED")
        slot.value = nil
        observed = OutputReferenceObservation.matchesIdentity(of: object) { slot.value }
        try require(!observed, "ABSENT_READBACK_REUSED_PRIOR_SUCCESS")
        slot.value = other
        observed = OutputReferenceObservation.matchesIdentity(of: object) { slot.value }
        try require(!observed, "WRONG_READBACK_REUSED_PRIOR_SUCCESS")
        slot.value = object
        observed = OutputReferenceObservation.matchesIdentity(of: object) { slot.value }
        try require(observed, "NEW_IDENTITY_CONFIRMATION_FAILED")
        print("PASS OUTPUT-REFERENCE-05 every observation performs its own identity readback")
        print("PASS 5 output reference observation groups; pure Swift objects only")
    }

    static func registerExpiredObject(in slot: WeakSlot) {
        let temporary = Object()
        slot.value = temporary
        withExtendedLifetime(temporary) {}
    }

    static func confirmWhileDroppingCallerReference(slot: WeakSlot, counter: Counter)
        -> (confirmed: Bool, aliveDuringReadback: Bool) {
        var caller: Object? = Object(counter: counter)
        slot.value = caller
        var aliveDuringReadback = false
        let confirmed = OutputReferenceObservation.matchesIdentity(of: caller!) {
            caller = nil
            aliveDuringReadback = slot.value != nil && counter.releases == 0
            return slot.value
        }
        return (confirmed, aliveDuringReadback)
    }
}
