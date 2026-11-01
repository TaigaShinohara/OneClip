/// Test-only confirmation of a reference readback. A nil or different object is unobserved;
/// a later nil is release evidence only if this confirmation previously succeeded.
enum OutputReferenceObservation {
    static func matchesIdentity<Object: AnyObject>(of object: Object,
                                                   readback: () -> Object?) -> Bool {
        withExtendedLifetime(object) {
            guard let observed = readback() else { return false }
            return observed === object
        }
    }
}
