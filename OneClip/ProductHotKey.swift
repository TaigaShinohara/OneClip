import Carbon
import Combine
import CoreGraphics
import Foundation

/// A physical key code and Carbon modifier flags, never text typed in another app.
struct HotKeyChord: Codable, Equatable, Hashable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let supportedModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    var displayName: String {
        var names: [String] = []
        if modifiers & UInt32(controlKey) != 0 { names.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { names.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { names.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { names.append("Command") }
        names.append(Self.keyNames[keyCode] ?? "使用できないキー")
        return names.joined(separator: " + ") + "（物理キー \(keyCode)）"
    }

    /// Visual keycaps only. Spoken labels keep the full physical-key description in displayName.
    var keycapLabels: [String] {
        var labels: [String] = []
        if modifiers & UInt32(controlKey) != 0 { labels.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { labels.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { labels.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { labels.append("⌘") }
        labels.append(Self.keyNames[keyCode] ?? "使用できないキー")
        return labels
    }

    /// This checks known conflicts only. Successful OS registration is not a conflict guarantee.
    var validationMessage: String? {
        guard modifiers & ~Self.supportedModifiers == 0,
              modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else {
            return "Control、Option、Commandのいずれかを含む組合せを選んでください。"
        }
        guard Self.keyNames[keyCode] != nil else {
            return "Enter、Esc、Tab、Delete、矢印などの操作キーは使えません。文字・数字・記号・ファンクションキーを選んでください。"
        }
        let withoutShift = modifiers & ~UInt32(shiftKey)
        if withoutShift == UInt32(cmdKey), Self.standardCommandKeys.contains(keyCode) {
            return "標準の編集・アプリ操作と重なるため、この組合せは使えません。別の修飾キーも加えてください。"
        }
        if keyCode == UInt32(kVK_Space), withoutShift == UInt32(controlKey) || modifiers & UInt32(cmdKey) != 0 {
            return "Spotlightや入力ソースの切替えと重なるため、別の組合せを選んでください。"
        }
        if [UInt32(kVK_ANSI_3), UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5)].contains(keyCode),
           modifiers & UInt32(cmdKey | shiftKey) == UInt32(cmdKey | shiftKey),
           modifiers & UInt32(optionKey) == 0 {
            return "macOSのスクリーンショット操作と重なるため、別の組合せを選んでください。"
        }
        if keyCode == UInt32(kVK_ANSI_8), modifiers == UInt32(controlKey | optionKey | cmdKey) {
            return "macOSの「色を反転」と重なるため、別の組合せを選んでください。"
        }
        if modifiers == UInt32(controlKey | cmdKey),
           [UInt32(kVK_ANSI_Q), UInt32(kVK_ANSI_F)].contains(keyCode) {
            return "macOSのロックやフルスクリーン操作と重なるため、別の組合せを選んでください。"
        }
        if withoutShift == UInt32(controlKey), Self.focusFunctionKeys.contains(keyCode) {
            return "macOSのフォーカス移動と重なるため、別の組合せを選んでください。"
        }
        return nil
    }

    private static let standardCommandKeys: Set<UInt32> = Set([
        kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z,
        kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_S,
        kVK_ANSI_O, kVK_ANSI_N, kVK_ANSI_P, kVK_ANSI_F, kVK_ANSI_Comma
    ].map(UInt32.init))

    private static let focusFunctionKeys: Set<UInt32> = Set([
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8
    ].map(UInt32.init))

    // Names intentionally identify ANSI/JIS physical positions rather than claiming to follow the input source.
    private static let keyNames: [UInt32: String] = Dictionary(uniqueKeysWithValues: [
        (kVK_ANSI_A, "A"), (kVK_ANSI_S, "S"), (kVK_ANSI_D, "D"), (kVK_ANSI_F, "F"),
        (kVK_ANSI_H, "H"), (kVK_ANSI_G, "G"), (kVK_ANSI_Z, "Z"), (kVK_ANSI_X, "X"),
        (kVK_ANSI_C, "C"), (kVK_ANSI_V, "V"), (kVK_ANSI_B, "B"), (kVK_ANSI_Q, "Q"),
        (kVK_ANSI_W, "W"), (kVK_ANSI_E, "E"), (kVK_ANSI_R, "R"), (kVK_ANSI_Y, "Y"),
        (kVK_ANSI_T, "T"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
        (kVK_ANSI_4, "4"), (kVK_ANSI_6, "6"), (kVK_ANSI_5, "5"), (kVK_ANSI_Equal, "="),
        (kVK_ANSI_9, "9"), (kVK_ANSI_7, "7"), (kVK_ANSI_Minus, "-"), (kVK_ANSI_8, "8"),
        (kVK_ANSI_0, "0"), (kVK_ANSI_RightBracket, "]"), (kVK_ANSI_O, "O"), (kVK_ANSI_U, "U"),
        (kVK_ANSI_LeftBracket, "["), (kVK_ANSI_I, "I"), (kVK_ANSI_P, "P"), (kVK_ANSI_L, "L"),
        (kVK_ANSI_J, "J"), (kVK_ANSI_Quote, "'"), (kVK_ANSI_K, "K"), (kVK_ANSI_Semicolon, ";"),
        (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Comma, ","), (kVK_ANSI_Slash, "/"), (kVK_ANSI_N, "N"),
        (kVK_ANSI_M, "M"), (kVK_ANSI_Period, "."), (kVK_ANSI_Grave, "`"), (kVK_Space, "Space"),
        (kVK_ANSI_KeypadDecimal, "テンキー ."), (kVK_ANSI_KeypadMultiply, "テンキー *"),
        (kVK_ANSI_KeypadPlus, "テンキー +"), (kVK_ANSI_KeypadDivide, "テンキー /"),
        (kVK_ANSI_KeypadMinus, "テンキー -"), (kVK_ANSI_KeypadEquals, "テンキー ="),
        (kVK_ANSI_Keypad0, "テンキー 0"), (kVK_ANSI_Keypad1, "テンキー 1"),
        (kVK_ANSI_Keypad2, "テンキー 2"), (kVK_ANSI_Keypad3, "テンキー 3"),
        (kVK_ANSI_Keypad4, "テンキー 4"), (kVK_ANSI_Keypad5, "テンキー 5"),
        (kVK_ANSI_Keypad6, "テンキー 6"), (kVK_ANSI_Keypad7, "テンキー 7"),
        (kVK_ANSI_Keypad8, "テンキー 8"), (kVK_ANSI_Keypad9, "テンキー 9"),
        (kVK_JIS_Yen, "JIS ¥"), (kVK_JIS_Underscore, "JIS _"),
        (kVK_JIS_KeypadComma, "JIS テンキー ,"),
        (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"),
        (kVK_F5, "F5"), (kVK_F6, "F6"), (kVK_F7, "F7"), (kVK_F8, "F8"),
        (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12"),
        (kVK_F13, "F13"), (kVK_F14, "F14"), (kVK_F15, "F15"), (kVK_F16, "F16"),
        (kVK_F17, "F17"), (kVK_F18, "F18"), (kVK_F19, "F19"), (kVK_F20, "F20")
    ].map { (UInt32($0.0), $0.1) })
}

@MainActor
protocol HotKeyPreferenceStoring: AnyObject {
    func loadChord() -> HotKeyChord?
    func saveChord(_ chord: HotKeyChord?)
}

enum CaptureHotKeyRole: String, CaseIterable, Identifiable, Sendable {
    case single, collection
    var id: Self { self }
    var title: String { self == .single ? "範囲をコピー" : "集めてコピー" }
    var keyName: String { self == .single ? "撮影キー" : "まとめ撮りキー" }
}

@MainActor
final class UserDefaultsHotKeyPreferenceStore: HotKeyPreferenceStoring {
    static let singleKey = "OneClip.singleCaptureHotKey.v1"
    static let collectionKey = "OneClip.collectionCaptureHotKey.v1"
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = UserDefaultsHotKeyPreferenceStore.singleKey) {
        self.defaults = defaults
        self.key = key
    }

    func loadChord() -> HotKeyChord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotKeyChord.self, from: data)
    }

    func saveChord(_ chord: HotKeyChord?) {
        guard let chord else { defaults.removeObject(forKey: key); return }
        guard let data = try? JSONEncoder().encode(chord) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
private final class MemoryHotKeyPreferenceStore: HotKeyPreferenceStoring {
    private var chord: HotKeyChord?
    func loadChord() -> HotKeyChord? { chord }
    func saveChord(_ chord: HotKeyChord?) { self.chord = chord }
}

struct HotKeyRegistration: Equatable, Hashable, Sendable {
    let identifier: UInt32
}

/// Copy the Carbon event's original time while EventRef is valid, before hopping to MainActor.
struct ProductHotKeyPress: Sendable {
    enum Kind: Sendable { case pressed, released }
    let identifier: UInt32
    let occurredAt: EventTime
    var kind: Kind = .pressed
    var isRepeat = false
}

/// Normalized before any actor hop: reordered delivery cannot make a native repeat fresh.
struct ProductHotKeyInputState: Sendable {
    private struct Edge: Sendable {
        let occurredAt: EventTime
        let isDown: Bool
    }
    private var identifiers: Set<UInt32> = []
    private var edges: [UInt32: Edge] = [:]

    mutating func register(_ identifier: UInt32, heldAt: EventTime? = nil) {
        identifiers.insert(identifier)
        if let heldAt, heldAt.isFinite, heldAt > 0 {
            edges[identifier] = Edge(occurredAt: heldAt, isDown: true)
        }
    }
    mutating func unregister(_ identifier: UInt32) {
        identifiers.remove(identifier)
        edges.removeValue(forKey: identifier)
    }

    mutating func consume(_ event: ProductHotKeyPress) -> ProductHotKeyPress? {
        guard identifiers.contains(event.identifier), event.occurredAt.isFinite, event.occurredAt > 0 else { return nil }
        let previous = edges[event.identifier]
        if let previous, event.occurredAt <= previous.occurredAt { return nil }
        let isDown = event.kind == .pressed
        edges[event.identifier] = Edge(occurredAt: event.occurredAt, isDown: isDown)
        var normalized = event
        normalized.isRepeat = isDown && previous?.isDown == true
        return normalized
    }
}

struct HotKeyBackendFailure: Error, Equatable, Sendable {
    let operation: String
    let status: Int32?

    var displayDetail: String { status.map { "（OSコード \($0)）" } ?? "" }
}

@MainActor
protocol ProductHotKeyBackend: AnyObject {
    var onPressed: (@MainActor (ProductHotKeyPress) -> Void)? { get set }
    /// A finite check of the proposed physical key, not an input monitor.
    func isKeyDown(_ keyCode: UInt32) -> Bool
    func register(_ chord: HotKeyChord) -> Result<HotKeyRegistration, HotKeyBackendFailure>
    /// A failed removal must leave the registration owned by this backend.
    func unregister(_ registration: HotKeyRegistration) -> HotKeyBackendFailure?
    /// Called only when the controller owns no registrations. Retain handler state if removal fails.
    func finish() -> HotKeyBackendFailure?
}

/// The saved preference is adopted only after a complete OS registration transaction succeeds.
@MainActor
final class ProductHotKeyController: ObservableObject {
    static let shared = ProductHotKeyController(collectionStore:
        UserDefaultsHotKeyPreferenceStore(key: UserDefaultsHotKeyPreferenceStore.collectionKey))

    @Published private(set) var desiredChord: HotKeyChord?
    @Published private(set) var activeChord: HotKeyChord?
    @Published private(set) var statusText = "撮影キーは未設定です。メニューから使えます"
    @Published private(set) var desiredCollectionChord: HotKeyChord?
    @Published private(set) var activeCollectionChord: HotKeyChord?
    @Published private(set) var collectionStatusText = "まとめ撮りキーは未設定です。メニューから使えます"
    @Published private(set) var isStarted = false
    @Published private(set) var hasPendingCleanup = false
    var onPressed: (@MainActor () -> Void)?
    var onCollectionPressed: (@MainActor () -> Void)?
    /// The application supplies its settings/sheet/capture-state gate before calling start().
    var deliveryAllowed: @MainActor () -> Bool = { false }
    var collectionDeliveryAllowed: @MainActor () -> Bool = { false }
    var reservedChords: @MainActor () -> [HotKeyChord] = { [] }
    /// Only editing/diagnostics block delivery; merely viewing settings does not.
    @Published var settingsInteractionBlocked = false {
        didSet {
            guard oldValue != settingsInteractionBlocked else { return }
            // A press generated in settings must not become a capture after its queued hop.
            discardQueuedPresses()
        }
    }

    private let backend: any ProductHotKeyBackend
    private let store: any HotKeyPreferenceStoring
    private let collectionStore: any HotKeyPreferenceStoring
    // Both roles share this controller, Carbon handler and monotonically allocated ID space.
    private var registrations: [CaptureHotKeyRole: HotKeyRegistration] = [:]
    private var pendingCleanup: [HotKeyRegistration] = []
    private var pendingHandlerCleanup = false
    private var transactionInProgress = false
    private var restoring = false
    private let eventTimeNow: @MainActor () -> EventTime
    private var deliveryNotBefore: EventTime = 0
    private struct KeyEdge {
        let occurredAt: EventTime
        let isDown: Bool
    }
    // Keep a down edge across presentation changes. A repeat is never a fresh capture request.
    private var keyEdges: [UInt32: KeyEdge] = [:]
    private struct RecordingLease {
        let identifier: UUID
        let startedAt: EventTime
        let allowed: @MainActor () -> Bool
        let candidate: @MainActor (HotKeyChord) -> Void
    }
    private var recordingLease: RecordingLease?

    init(backend: any ProductHotKeyBackend = CarbonProductHotKeyBackend(),
         store: any HotKeyPreferenceStoring = UserDefaultsHotKeyPreferenceStore(),
         collectionStore: (any HotKeyPreferenceStoring)? = nil,
         eventTimeNow: @escaping @MainActor () -> EventTime = { GetCurrentEventTime() }) {
        self.backend = backend
        self.store = store
        self.eventTimeNow = eventTimeNow
        // Injected/standalone controllers do not read a second global setting. The shared product
        // controller explicitly supplies the persistent collection store above.
        self.collectionStore = collectionStore ?? MemoryHotKeyPreferenceStore()
        desiredChord = store.loadChord()
        desiredCollectionChord = self.collectionStore.loadChord()
        backend.onPressed = { [weak self] press in self?.receive(press) }
        if desiredChord != nil { statusText = "保存した撮影キーは、まだ登録していません" }
        if desiredCollectionChord != nil { collectionStatusText = "保存したまとめ撮りキーは、まだ登録していません" }
    }

    /// No constructor registration. Startup restoration and retry are explicit lifecycle operations.
    func start() {
        isStarted = true
        restoring = true
        defer { restoring = false }
        // Preserve the existing single-key assignment if corrupted/old preferences contain a
        // duplicate. Keep the desired collection value visible, without registering it.
        _ = setChord(desiredChord, for: .single)
        guard !hasPendingCleanup else { return }
        _ = setChord(desiredCollectionChord, for: .collection)
    }

    /// Returns true only if the requested preference and the effective OS state agree.
    @discardableResult
    func setChord(_ chord: HotKeyChord?) -> Bool {
        setChord(chord, for: .single)
    }

    @discardableResult
    func setCollectionChord(_ chord: HotKeyChord?) -> Bool {
        setChord(chord, for: .collection)
    }

    func desiredChord(for role: CaptureHotKeyRole) -> HotKeyChord? {
        role == .single ? desiredChord : desiredCollectionChord
    }

    func activeChord(for role: CaptureHotKeyRole) -> HotKeyChord? {
        role == .single ? activeChord : activeCollectionChord
    }

    func statusText(for role: CaptureHotKeyRole) -> String {
        role == .single ? statusText : collectionStatusText
    }

    /// Hide only the canonical, redundant summary. Failures remain visible even if the keys agree.
    func statusDetail(for role: CaptureHotKeyRole) -> String? {
        let text = statusText(for: role)
        return text == currentStatusText(for: role) ? nil : text
    }

    /// Retry ambiguous OS cleanup without clearing either role's saved wish or healthy registration.
    @discardableResult
    func retryCleanup() -> Bool {
        guard isStarted, !transactionInProgress else { return false }
        transactionInProgress = true
        defer { transactionInProgress = false }
        cancelShortcutRecording()
        return retryPendingCleanup()
    }

    @discardableResult
    func setChord(_ chord: HotKeyChord?, for role: CaptureHotKeyRole) -> Bool {
        guard !transactionInProgress else { return false }
        guard isStarted else {
            setStatus("\(role.keyName)は停止中です。メニューから使えます", for: role)
            return false
        }
        transactionInProgress = true
        defer { transactionInProgress = false }
        cancelShortcutRecording()
        if let chord {
            if let reason = chord.validationMessage { setStatus(reason, for: role); return false }
            let other: CaptureHotKeyRole = role == .single ? .collection : .single
            let conflictingWish = !(restoring && role == .single) && desiredChord(for: other) == chord
            if reservedChords().contains(chord) || activeChord(for: other) == chord || conflictingWish {
                setStatus("OneClip内の別のキーと重なっています。別の組合せを選んでください", for: role)
                return false
            }
        }
        guard retryPendingCleanup() else { return false }
        if chord == activeChord(for: role), (chord == nil || registrations[role] != nil) {
            adoptDesired(chord, for: role)
            publishCurrentStatus(for: role)
            return true
        }
        guard let chord else {
            if let registration = registrations[role], let error = backend.unregister(registration) {
                setStatus("\(role.keyName)を解除できませんでした\(error.displayDetail)。現在のキーは登録したままです", for: role)
                return false
            }
            registrations.removeValue(forKey: role)
            setActive(nil, for: role)
            adoptDesired(nil, for: role)
            finishIfUnused()
            if !hasPendingCleanup { publishCurrentStatus(for: role) }
            return !hasPendingCleanup
        }
        // A local recorder may have selected a key that was not registered yet. Do not
        // register that chord while it is held: its next repeat could look like a new hotkey.
        guard !backend.isKeyDown(chord.keyCode) else {
            setStatus("キーを離してから、もう一度登録してください。現在の設定は変えていません", for: role)
            return false
        }
        let newRegistration: HotKeyRegistration
        switch backend.register(chord) {
        case .success(let registration): newRegistration = registration
        case .failure(let error):
            let previous = registrations[role] == nil ? "メニューから使えます" : "以前のキーは登録したままです"
            setStatus("\(role.keyName)を登録できませんでした\(error.displayDetail)。別の組合せを選んでください。\(previous)", for: role)
            finishIfUnused()
            return false
        }
        if let oldRegistration = registrations[role], let error = backend.unregister(oldRegistration) {
            if let rollbackError = backend.unregister(newRegistration) {
                // Neither reference may be forgotten. All deliveries stay disabled until both are removed.
                pendingCleanup.append(contentsOf: [oldRegistration, newRegistration])
                registrations.removeValue(forKey: role)
                setActive(nil, for: role)
                refreshCleanupState()
                setStatus("変更を完了できず、2件の登録解除が必要です\(rollbackError.displayDetail)。両方の撮影キーを停止しています。「解除」か登録の再試行を選んでください", for: role)
            } else {
                setStatus("以前のキーを解除できませんでした\(error.displayDetail)。設定を変更せず、以前のキーを使います", for: role)
            }
            return false
        }
        registrations[role] = newRegistration
        setActive(chord, for: role)
        adoptDesired(chord, for: role)
        publishCurrentStatus(for: role)
        return true
    }

    /// Revokes deliveries first, even if OS cleanup fails. The desired preference survives termination.
    func stop() {
        isStarted = false
        cancelShortcutRecording()
        pendingCleanup.append(contentsOf: registrations.values)
        registrations.removeAll()
        setActive(nil, for: .single)
        setActive(nil, for: .collection)
        refreshCleanupState()
        if retryPendingCleanup() {
            statusText = "撮影キーを停止しました"
            collectionStatusText = "まとめ撮りキーを停止しました"
        }
    }

    /// The recorder owns a short-lived lease, never a temporary OS registration. The UI gate
    /// checks its actual key window, app activation and first responder at every delivery.
    func beginShortcutRecording(allowed: @escaping @MainActor () -> Bool,
                                candidate: @escaping @MainActor (HotKeyChord) -> Void) -> UUID? {
        cancelShortcutRecording()
        let now = eventTimeNow()
        guard isStarted, settingsInteractionBlocked, !restoring, !transactionInProgress,
              !hasPendingCleanup, now.isFinite, now > 0, allowed() else { return nil }
        let identifier = UUID()
        recordingLease = RecordingLease(identifier: identifier, startedAt: now,
                                        allowed: allowed, candidate: candidate)
        return identifier
    }

    func cancelShortcutRecording(_ identifier: UUID? = nil) {
        if identifier == nil || recordingLease?.identifier == identifier { recordingLease = nil }
    }

    /// Call at both edges of a presentation gate. Original event times prevent a press made
    /// inside a confirmation from starting a capture after its MainActor hop arrives late.
    func discardQueuedPresses() {
        cancelShortcutRecording()
        let now = eventTimeNow()
        deliveryNotBefore = now.isFinite && now > 0 ? now : .infinity
    }

    /// Local input and Carbon-owned input share the same one-candidate consumption boundary.
    @discardableResult
    func submitShortcutCandidate(_ chord: HotKeyChord, occurredAt: EventTime, recording identifier: UUID) -> Bool {
        guard let lease = recordingLease, lease.identifier == identifier,
              isStarted, settingsInteractionBlocked, !restoring, !transactionInProgress,
              !hasPendingCleanup else { return false }
        guard lease.allowed() else { cancelShortcutRecording(identifier); return false }
        // SDK CarbonEventsCore.h documents both GetEventTime and GetCurrentEventTime as
        // seconds since startup. Strict > rejects pre-arm input, including equal timestamps.
        let now = eventTimeNow()
        guard occurredAt.isFinite, now.isFinite, occurredAt > lease.startedAt,
              occurredAt <= now, chord.validationMessage == nil else { return false }
        recordingLease = nil // Consume synchronously before a SwiftUI binding can update.
        lease.candidate(chord)
        return true
    }

    private func receive(_ press: ProductHotKeyPress) {
        let identifier = press.identifier
        // Observe release even when delivery is blocked. Timestamps also reject out-of-order
        // actor hops, so an old release cannot turn a still-held key into a fresh press.
        let liveIDs = Set(registrations.values.map(\.identifier))
        keyEdges = keyEdges.filter { liveIDs.contains($0.key) }
        guard liveIDs.contains(identifier) else { return }
        let now = eventTimeNow()
        guard press.occurredAt.isFinite, now.isFinite, press.occurredAt > 0,
              press.occurredAt <= now else { return }
        let previous = keyEdges[identifier]
        if let previous, press.occurredAt <= previous.occurredAt { return }
        let isDown = press.kind == .pressed
        keyEdges[identifier] = KeyEdge(occurredAt: press.occurredAt, isDown: isDown)
        guard isDown, !press.isRepeat, previous?.isDown != true,
              isStarted, !restoring, !transactionInProgress, !hasPendingCleanup else { return }
        if settingsInteractionBlocked {
            if let lease = recordingLease,
               let role = CaptureHotKeyRole.allCases.first(where: { registrations[$0]?.identifier == identifier }),
               let chord = activeChord(for: role) {
                submitShortcutCandidate(chord, occurredAt: press.occurredAt, recording: lease.identifier)
            }
            return // Editing presses never fall through to either product capture action.
        }
        guard press.occurredAt > deliveryNotBefore else { return }
        if registrations[.single]?.identifier == identifier, activeChord != nil, deliveryAllowed() {
            onPressed?()
        } else if registrations[.collection]?.identifier == identifier,
                  activeCollectionChord != nil, collectionDeliveryAllowed() {
            onCollectionPressed?()
        }
    }

    private func retryPendingCleanup() -> Bool {
        guard !pendingCleanup.isEmpty || pendingHandlerCleanup else { return true }
        var remaining: [HotKeyRegistration] = []
        for registration in pendingCleanup {
            if backend.unregister(registration) != nil { remaining.append(registration) }
        }
        pendingCleanup = remaining
        if pendingCleanup.isEmpty { finishIfUnused() }
        refreshCleanupState()
        guard !hasPendingCleanup else {
            let text = "登録解除を完了できません。両方の撮影キーは停止中です。解除か登録の再試行を選んでください"
            statusText = text
            collectionStatusText = text
            return false
        }
        if isStarted {
            for role in CaptureHotKeyRole.allCases { publishCurrentStatus(for: role) }
        }
        return true
    }

    private func finishIfUnused() {
        guard registrations.isEmpty, pendingCleanup.isEmpty else { return }
        pendingHandlerCleanup = backend.finish() != nil
        refreshCleanupState()
        if pendingHandlerCleanup {
            statusText = "キーの終了処理が完了していません。両方の撮影キーは停止中です。解除か登録の再試行を選んでください"
            collectionStatusText = statusText
        }
    }

    private func refreshCleanupState() {
        hasPendingCleanup = !pendingCleanup.isEmpty || pendingHandlerCleanup
    }

    private func publishCurrentStatus(for role: CaptureHotKeyRole) {
        setStatus(currentStatusText(for: role), for: role)
    }

    private func currentStatusText(for role: CaptureHotKeyRole) -> String {
        if activeChord(for: role) != nil {
            return "\(role.keyName)を登録しました。OSや他アプリとのすべての重複を検出できるわけではありません"
        } else if desiredChord(for: role) != nil {
            return "保存した\(role.keyName)は未登録です。メニューから使えます。再登録を試してください"
        } else {
            return "\(role.keyName)は未設定です。メニューから使えます"
        }
    }

    private func setActive(_ chord: HotKeyChord?, for role: CaptureHotKeyRole) {
        if role == .single { activeChord = chord } else { activeCollectionChord = chord }
    }

    private func adoptDesired(_ chord: HotKeyChord?, for role: CaptureHotKeyRole) {
        // Restoring an unchanged wish does not rewrite its persisted representation. A clear
        // still removes the stored value even if an unreadable value decoded as nil.
        let needsSave = chord == nil || desiredChord(for: role) != chord
        if role == .single {
            desiredChord = chord
            if needsSave { store.saveChord(chord) }
        } else {
            desiredCollectionChord = chord
            if needsSave { collectionStore.saveChord(chord) }
        }
    }

    private func setStatus(_ text: String, for role: CaptureHotKeyRole) {
        if role == .single { statusText = text } else { collectionStatusText = text }
    }
}

/// Registers only the chosen chord. It never installs a global key monitor or asks for Accessibility access.
@MainActor
final class CarbonProductHotKeyBackend: ProductHotKeyBackend {
    var onPressed: (@MainActor (ProductHotKeyPress) -> Void)?
    nonisolated private static let signature: OSType = 0x4F435032 // OCP2
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var nextIdentifier: UInt32 = 1
    private var handlerRef: EventHandlerRef?
    private var handlerContext: UnsafeMutableRawPointer?

    func isKeyDown(_ keyCode: UInt32) -> Bool {
        guard let key = CGKeyCode(exactly: keyCode) else { return true }
        return CGEventSource.keyState(.combinedSessionState, key: key)
    }

    func register(_ chord: HotKeyChord) -> Result<HotKeyRegistration, HotKeyBackendFailure> {
        if let error = installHandler() { return .failure(error) }
        guard nextIdentifier != 0 else {
            return .failure(HotKeyBackendFailure(operation: "identifierExhausted", status: nil))
        }
        let identifier = nextIdentifier
        nextIdentifier &+= 1 // Never reuse an ID after wrap, so old queued notifications cannot match.
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(chord.keyCode, chord.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: identifier),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr else {
            return .failure(HotKeyBackendFailure(operation: "register", status: status))
        }
        guard let reference else {
            return .failure(HotKeyBackendFailure(operation: "registrationReferenceMissing", status: status))
        }
        registrations[identifier] = reference
        // A key may go down during RegisterEventHotKey itself. Seed that edge before
        // publishing the registration so its repeats cannot become capture requests.
        callbackContext?.register(identifier, heldAt: isKeyDown(chord.keyCode) ? GetCurrentEventTime() : nil)
        return .success(HotKeyRegistration(identifier: identifier))
    }

    func unregister(_ registration: HotKeyRegistration) -> HotKeyBackendFailure? {
        guard let reference = registrations[registration.identifier] else { return nil }
        let status = UnregisterEventHotKey(reference)
        guard status == noErr else { return HotKeyBackendFailure(operation: "unregister", status: status) }
        registrations.removeValue(forKey: registration.identifier)
        callbackContext?.unregister(registration.identifier)
        return nil
    }

    func finish() -> HotKeyBackendFailure? {
        guard registrations.isEmpty else { return HotKeyBackendFailure(operation: "registrationsRemain", status: nil) }
        if let handlerRef {
            let status = RemoveEventHandler(handlerRef)
            guard status == noErr else { return HotKeyBackendFailure(operation: "removeHandler", status: status) }
            self.handlerRef = nil
        }
        if let handlerContext {
            Unmanaged<ProductHotKeyCallbackContext>.fromOpaque(handlerContext).release()
            self.handlerContext = nil
        }
        return nil
    }

    private func installHandler() -> HotKeyBackendFailure? {
        guard handlerRef == nil else { return nil }
        let context = ProductHotKeyCallbackContext { [weak self] press in
            Task { @MainActor [weak self] in self?.onPressed?(press) }
        }
        let opaque = Unmanaged.passRetained(context).toOpaque()
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        var reference: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), Self.eventHandler, 2, &eventTypes, opaque, &reference)
        guard status == noErr, let reference else {
            Unmanaged<ProductHotKeyCallbackContext>.fromOpaque(opaque).release()
            return HotKeyBackendFailure(operation: status == noErr ? "handlerReferenceMissing" : "installHandler", status: status)
        }
        handlerRef = reference
        handlerContext = opaque
        return nil
    }

    private var callbackContext: ProductHotKeyCallbackContext? {
        guard let handlerContext else { return nil }
        return Unmanaged<ProductHotKeyCallbackContext>.fromOpaque(handlerContext).takeUnretainedValue()
    }

    nonisolated private static let eventHandler: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                      EventParamType(typeEventHotKeyID), nil,
                                      MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        guard status == noErr else { return status }
        guard identifier.signature == signature else { return OSStatus(eventNotHandledErr) }
        let kind = GetEventKind(event)
        guard kind == UInt32(kEventHotKeyPressed) || kind == UInt32(kEventHotKeyReleased) else {
            return OSStatus(eventNotHandledErr)
        }
        let press = ProductHotKeyPress(identifier: identifier.id, occurredAt: GetEventTime(event),
                                      kind: kind == UInt32(kEventHotKeyPressed) ? .pressed : .released)
        Unmanaged<ProductHotKeyCallbackContext>.fromOpaque(context).takeUnretainedValue().didReceive(press)
        return noErr
    }
}

private final class ProductHotKeyCallbackContext: @unchecked Sendable {
    // Carbon callback and registration lifecycle serialize only this small input state.
    // No framework object, callback or MainActor hop is invoked while holding the lock.
    private let lock = NSLock()
    private var inputState = ProductHotKeyInputState()
    private let deliver: @Sendable (ProductHotKeyPress) -> Void

    init(didReceive: @escaping @Sendable (ProductHotKeyPress) -> Void) { deliver = didReceive }

    func register(_ identifier: UInt32, heldAt: EventTime?) {
        lock.lock()
        inputState.register(identifier, heldAt: heldAt)
        lock.unlock()
    }

    func unregister(_ identifier: UInt32) {
        lock.lock()
        inputState.unregister(identifier)
        lock.unlock()
    }

    func didReceive(_ event: ProductHotKeyPress) {
        lock.lock()
        let normalized = inputState.consume(event)
        lock.unlock()
        if let normalized { deliver(normalized) }
    }
}
