import Carbon
import Combine

/// M0 only: explicitly registers one chord and counts its notifications.
/// The app owner must keep this instance alive and call unregister() on termination.
/// This probe neither observes arbitrary keys nor captures/copies content.
@MainActor
final class M0HotKeyProbe: ObservableObject {
    enum Code: String, Sendable {
        case idle = "IDLE"
        case registered = "REGISTERED"
        case alreadyRegistered = "ALREADY_REGISTERED"
        case notRegistered = "NOT_REGISTERED"
        case handlerInstallationFailed = "HANDLER_INSTALLATION_FAILED"
        case handlerReferenceMissing = "HANDLER_REFERENCE_MISSING"
        case registrationFailed = "REGISTRATION_FAILED"
        case registrationReferenceMissing = "REGISTRATION_REFERENCE_MISSING"
        case unregistered = "UNREGISTERED"
        case unregistrationFailed = "UNREGISTRATION_FAILED"
        case handlerRemovalFailed = "HANDLER_REMOVAL_FAILED"
        case duplicateRejected = "DUPLICATE_REJECTED"
        case duplicateCheckFailed = "DUPLICATE_CHECK_FAILED"
        case duplicateUnexpectedlyRegistered = "DUPLICATE_UNEXPECTEDLY_REGISTERED"
        case duplicateCleanupFailed = "DUPLICATE_CLEANUP_FAILED"
    }

    struct ProbeResult: Equatable, Sendable {
        let code: Code
        let osStatus: OSStatus?
    }

    @Published private(set) var isRegistered = false
    @Published private(set) var pressCount = 0
    @Published private(set) var lastResult = ProbeResult(code: .idle, osStatus: nil)

    var onPressed: (@MainActor () -> Void)?

    var statusCode: String { lastResult.code.rawValue }
    var lastOSStatus: OSStatus? { lastResult.osStatus }

    // A physical ANSI 9 key with control + option + command; never user keystrokes.
    nonisolated private static let keyCode = UInt32(kVK_ANSI_9)
    nonisolated private static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    nonisolated private static let signature: OSType = 0x4F434D30 // OCM0

    private var hotKeyRef: EventHotKeyRef?
    private var extraRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var handlerContext: UnsafeMutableRawPointer?
    private var activeID: UInt32 = 0
    private var nextID: UInt32 = 1
    private var acceptsPresses = false

    @discardableResult
    func register() -> ProbeResult {
        guard hotKeyRef == nil, extraRefs.isEmpty else {
            return publish(.alreadyRegistered, nil)
        }
        if let failure = installHandlerIfNeeded() {
            lastResult = failure
            return failure
        }

        let identifier = nextID
        nextID &+= 2
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            Self.keyCode,
            Self.modifiers,
            EventHotKeyID(signature: Self.signature, id: identifier),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &reference
        )
        guard status == noErr else {
            return publish(.registrationFailed, status)
        }
        guard let reference else {
            return publish(.registrationReferenceMissing, status)
        }
        hotKeyRef = reference
        activeID = identifier
        acceptsPresses = true
        isRegistered = true
        return publish(.registered, status)
    }

    /// Keeps any reference whose removal failed, so a later call can retry cleanup.
    @discardableResult
    func unregister() -> ProbeResult {
        acceptsPresses = false
        activeID = 0
        var firstFailure: OSStatus?

        if let reference = hotKeyRef {
            let status = UnregisterEventHotKey(reference)
            if status == noErr {
                hotKeyRef = nil
            } else {
                firstFailure = status
            }
        }

        var remaining: [EventHotKeyRef] = []
        for reference in extraRefs {
            let status = UnregisterEventHotKey(reference)
            if status != noErr {
                remaining.append(reference)
                if firstFailure == nil { firstFailure = status }
            }
        }
        extraRefs = remaining
        isRegistered = hotKeyRef != nil || !extraRefs.isEmpty

        if let firstFailure {
            return publish(.unregistrationFailed, firstFailure)
        }
        if let reference = handlerRef {
            let status = RemoveEventHandler(reference)
            guard status == noErr else {
                return publish(.handlerRemovalFailed, status)
            }
            handlerRef = nil
        }
        if let context = handlerContext {
            Unmanaged<CallbackContext>.fromOpaque(context).release()
            handlerContext = nil
        }
        return publish(.unregistered, noErr)
    }

    @discardableResult
    func testDuplicateRegistration() -> ProbeResult {
        guard hotKeyRef != nil, acceptsPresses else {
            return publish(.notRegistered, nil)
        }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            Self.keyCode,
            Self.modifiers,
            EventHotKeyID(signature: Self.signature, id: activeID &+ 1),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &reference
        )
        if status == OSStatus(eventHotKeyExistsErr) {
            return publish(.duplicateRejected, status)
        }
        guard status == noErr else {
            return publish(.duplicateCheckFailed, status)
        }
        guard let reference else {
            return publish(.registrationReferenceMissing, status)
        }
        let cleanupStatus = UnregisterEventHotKey(reference)
        guard cleanupStatus == noErr else {
            extraRefs.append(reference)
            return publish(.duplicateCleanupFailed, cleanupStatus)
        }
        return publish(.duplicateUnexpectedlyRegistered, status)
    }

    private func publish(_ code: Code, _ osStatus: OSStatus?) -> ProbeResult {
        let result = ProbeResult(code: code, osStatus: osStatus)
        lastResult = result
        return result
    }

    private func receivePress(identifier: UInt32) {
        guard acceptsPresses, hotKeyRef != nil, identifier == activeID else { return }
        if pressCount < Int.max { pressCount += 1 }
        onPressed?()
    }

    private func installHandlerIfNeeded() -> ProbeResult? {
        guard handlerRef == nil else { return nil }
        let context = CallbackContext { [weak self] identifier in
            Task { @MainActor [weak self] in
                self?.receivePress(identifier: identifier)
            }
        }
        let opaque = Unmanaged.passRetained(context).toOpaque()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var reference: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventType,
            opaque,
            &reference
        )
        guard status == noErr, let reference else {
            Unmanaged<CallbackContext>.fromOpaque(opaque).release()
            return ProbeResult(
                code: status == noErr ? .handlerReferenceMissing : .handlerInstallationFailed,
                osStatus: status
            )
        }
        handlerRef = reference
        handlerContext = opaque
        return nil
    }

    nonisolated private static let eventHandler: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr else { return status }
        guard identifier.signature == signature else { return OSStatus(eventNotHandledErr) }
        let callback = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
        callback.didReceive(identifier.id)
        return noErr
    }
}

private final class CallbackContext: Sendable {
    let didReceive: @Sendable (UInt32) -> Void

    init(didReceive: @escaping @Sendable (UInt32) -> Void) {
        self.didReceive = didReceive
    }
}
