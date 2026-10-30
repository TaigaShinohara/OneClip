import Carbon
import Foundation

/// Uses a fake registration service and test-owned preferences only. No real keys, screens, or pasteboards.
@main
struct ProductHotKeyTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static let first = HotKeyChord(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(controlKey | optionKey | cmdKey))
    static let second = HotKeyChord(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(controlKey | optionKey | cmdKey))
    static let third = HotKeyChord(keyCode: UInt32(kVK_ANSI_7), modifiers: UInt32(controlKey | optionKey | cmdKey))

    @MainActor
    static func main() throws {
        let groups: [(String, @MainActor () throws -> Void)] = [
            ("M2-KEY-01 initial unset never registers", testUnset),
            ("M2-KEY-02 preference restoration is explicit and may fail", testRestoration),
            ("M2-KEY-03 successful change adopts only the new registration", testChange),
            ("M2-KEY-04 rejected registration preserves old setting", testRegistrationFailure),
            ("M2-KEY-05 failed old removal rolls back new registration", testRollback),
            ("M2-KEY-06 failed rollback retains both references and blocks delivery", testFailedRollback),
            ("M2-KEY-07 failed clear preserves effective old key", testClear),
            ("M2-KEY-08 queued events respect current ID and UI gate", testDeliveryGate),
            ("M2-KEY-09 stop blocks events even when OS removal fails", testStop),
            ("M2-KEY-10 failed handler removal can be retried", testHandlerCleanup),
            ("M2-KEY-11 validation and app duplicate reject without OS changes", testValidation),
            ("M2-KEY-12 isolated preferences round trip only the chord", testPreferences),
            ("M3-KEY-01 shared ID space routes roles through independent current gates", testDualRouting),
            ("M3-KEY-02 duplicate wishes never displace the legacy single key", testDualDuplicates),
            ("M3-KEY-03 collection rollback and ambiguous cleanup preserve both owners", testDualRollback),
            ("M3-KEY-04 clear and restart keep the other role registered", testDualLifecycle),
            ("M3-KEY-05 failed collection restoration keeps its wish and the single key", testDualRestoration),
            ("M3-KEY-06 partial stop cleanup prevents either role restarting early", testDualStopCleanup),
            ("M3-KEY-07 independent persistence preserves the legacy single key", testDualPreferences),
            ("M3-KEY-08 transaction rejects both delivery and reentrant preference writes", testDualTransaction),
            ("M3-KEY-09 owned hotkeys become one recorder candidate without changing registrations", testRegisteredRecording),
            ("M3-KEY-10 recording rejects pre-arm, invalid, future and obsolete ID events", testRecordingFreshness),
            ("M3-KEY-11 local and registered candidates share one generation", testRecordingLocalAndGeneration),
            ("M3-KEY-12 context loss and close reject late recorder presses without capture fallthrough", testRecordingContextLoss),
            ("M3-KEY-13 stopped and ambiguous backends cannot feed a recorder", testRecordingUnavailable),
            ("M3-KEY-14 presentation boundaries reject both roles' delayed presses", testPresentationBoundary),
            ("SETTINGS-KEY-01 editing completion and cancellation require a fresh down edge", testHeldEditingBoundary),
            ("SETTINGS-KEY-02 local candidates and reordered native repeats cannot escape editing", testLocalCandidateRepeat),
            ("SETTINGS-KEY-03 a held unregistered candidate never replaces the effective key", testHeldRegistration),
            ("SETTINGS-KEY-04 native edge normalization survives stale release and registration changes", testNativeEdgeNormalization)
        ]
        for (name, body) in groups {
            try body()
            print("PASS \(name)")
        }
        print("PASS \(groups.count) hotkey groups; fake registration service only")
    }

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(description: message) }
    }

    @MainActor
    final class MemoryStore: HotKeyPreferenceStoring {
        var chord: HotKeyChord?
        var saves: [HotKeyChord?] = []
        init(_ chord: HotKeyChord? = nil) { self.chord = chord }
        func loadChord() -> HotKeyChord? { chord }
        func saveChord(_ chord: HotKeyChord?) { self.chord = chord; saves.append(chord) }
    }

    @MainActor
    final class FakeBackend: ProductHotKeyBackend {
        var onPressed: (@MainActor (ProductHotKeyPress) -> Void)?
        var currentEventTime: EventTime = 100
        var registerFailures = 0
        var registerFailuresForChord: [HotKeyChord: Int] = [:]
        var removeFailures: [UInt32: Int] = [:]
        var finishFailures = 0
        var registrations: [UInt32: HotKeyChord] = [:]
        var attemptedChords: [HotKeyChord] = []
        var removedIDs: [UInt32] = []
        var finishCalls = 0
        var duringRegister: (@MainActor (UInt32) -> Void)?
        var heldKeyCodes: Set<UInt32> = []
        private var nextID: UInt32 = 1

        func isKeyDown(_ keyCode: UInt32) -> Bool { heldKeyCodes.contains(keyCode) }

        func register(_ chord: HotKeyChord) -> Result<HotKeyRegistration, HotKeyBackendFailure> {
            attemptedChords.append(chord)
            if registerFailures > 0 {
                registerFailures -= 1
                return .failure(HotKeyBackendFailure(operation: "register", status: -9878))
            }
            if let count = registerFailuresForChord[chord], count > 0 {
                registerFailuresForChord[chord] = count - 1
                return .failure(HotKeyBackendFailure(operation: "register", status: -9878))
            }
            let id = nextID
            nextID += 1
            registrations[id] = chord
            duringRegister?(id)
            return .success(HotKeyRegistration(identifier: id))
        }

        func unregister(_ registration: HotKeyRegistration) -> HotKeyBackendFailure? {
            let id = registration.identifier
            removedIDs.append(id)
            if let count = removeFailures[id], count > 0 {
                removeFailures[id] = count - 1
                return HotKeyBackendFailure(operation: "unregister", status: -1)
            }
            registrations.removeValue(forKey: id)
            return nil
        }

        func finish() -> HotKeyBackendFailure? {
            finishCalls += 1
            if !registrations.isEmpty { return HotKeyBackendFailure(operation: "registrationsRemain", status: nil) }
            if finishFailures > 0 {
                finishFailures -= 1
                return HotKeyBackendFailure(operation: "removeHandler", status: -1)
            }
            return nil
        }

        func advance() -> EventTime { currentEventTime += 0.01; return currentEventTime }
        func press(_ id: UInt32, at time: EventTime? = nil, isRepeat: Bool = false) {
            onPressed?(ProductHotKeyPress(identifier: id, occurredAt: time ?? advance(), isRepeat: isRepeat))
        }
        func release(_ id: UInt32, at time: EventTime? = nil) {
            onPressed?(ProductHotKeyPress(identifier: id, occurredAt: time ?? advance(), kind: .released))
        }
        /// Existing scenario actions represent one physical tap, including its release.
        func emit(_ id: UInt32, at time: EventTime? = nil) {
            press(id, at: time)
            release(id)
        }
        func queued(_ id: UInt32, at time: EventTime? = nil) -> @MainActor () -> Void {
            let press = ProductHotKeyPress(identifier: id, occurredAt: time ?? advance())
            let release = ProductHotKeyPress(identifier: id, occurredAt: advance(), kind: .released)
            return { [weak self] in
                self?.onPressed?(press)
                self?.onPressed?(release)
            }
        }
    }

    @MainActor
    final class Harness {
        let backend: FakeBackend
        let store: MemoryStore
        let collectionStore: MemoryStore
        let controller: ProductHotKeyController
        var gateOpen = true
        var presses = 0
        var collectionGateOpen = true
        var collectionPresses = 0

        init(saved: HotKeyChord? = nil, savedCollection: HotKeyChord? = nil) {
            let backend = FakeBackend()
            self.backend = backend
            store = MemoryStore(saved)
            collectionStore = MemoryStore(savedCollection)
            controller = ProductHotKeyController(backend: backend, store: store, collectionStore: collectionStore,
                                                 eventTimeNow: { backend.currentEventTime })
            controller.deliveryAllowed = { [weak self] in self?.gateOpen == true }
            controller.onPressed = { [weak self] in self?.presses += 1 }
            controller.collectionDeliveryAllowed = { [weak self] in self?.collectionGateOpen == true }
            controller.onCollectionPressed = { [weak self] in self?.collectionPresses += 1 }
        }
    }

    @MainActor
    static func testUnset() throws {
        let h = Harness()
        try expect(h.backend.attemptedChords.isEmpty && !h.controller.isStarted, "Initializer registered a key")
        h.controller.start()
        h.controller.start()
        try expect(h.controller.desiredChord == nil && h.controller.activeChord == nil, "Unset state has a chord")
        try expect(h.backend.attemptedChords.isEmpty && h.backend.registrations.isEmpty, "Unset startup registered a key")
        h.backend.emit(1)
        try expect(h.presses == 0, "Unset key delivered")
        h.controller.stop()
    }

    @MainActor
    static func testRestoration() throws {
        let h = Harness(saved: first)
        try expect(h.controller.desiredChord == first && h.controller.activeChord == nil && h.backend.attemptedChords.isEmpty,
                   "Saved preference was registered by init")
        h.backend.registerFailures = 1
        h.controller.start()
        try expect(h.controller.desiredChord == first && h.controller.activeChord == nil && h.store.chord == first,
                   "Failed restoration was shown active or erased the preference")
        try expect(h.store.saves.isEmpty && !h.controller.statusText.isEmpty, "Failed restoration was persisted as a new setting")
        h.controller.start()
        try expect(h.controller.activeChord == first && h.backend.registrations.count == 1, "Explicit restoration retry failed")
        h.controller.start()
        try expect(h.backend.attemptedChords.count == 2 && h.backend.registrations.count == 1, "Repeated start duplicated registration")
        h.controller.stop()
    }

    @MainActor
    static func testChange() throws {
        let h = Harness()
        h.controller.start()
        try expect(h.controller.setChord(first), "Initial setting failed")
        let oldNotification = h.backend.queued(1)
        try expect(h.controller.setChord(second), "Change failed")
        try expect(h.controller.activeChord == second && h.controller.desiredChord == second && h.store.chord == second,
                   "Successful setting does not match the active key")
        try expect(h.controller.statusDetail(for: .single) == nil, "Successful registration retained redundant guidance")
        try expect(h.backend.registrations == [2: second] && h.backend.removedIDs == [1], "Old registration remained after adoption")
        oldNotification()
        h.backend.emit(2)
        try expect(h.presses == 1, "Old notification fired or new notification did not")
        h.controller.stop()
    }

    @MainActor
    static func testRegistrationFailure() throws {
        let h = Harness(saved: first)
        h.controller.start()
        let writes = h.store.saves.count
        h.backend.registerFailures = 1
        try expect(!h.controller.setChord(second), "Rejected registration was adopted")
        try expect(h.controller.activeChord == first && h.controller.desiredChord == first && h.store.chord == first,
                   "Rejected change altered the current setting")
        try expect(h.controller.statusDetail(for: .single) == h.controller.statusText,
                   "Matching active and saved keys hid a failed replacement")
        try expect(h.backend.registrations == [1: first] && h.backend.removedIDs.isEmpty && h.store.saves.count == writes,
                   "Rejected change removed or resaved the old key")
        h.backend.emit(1)
        try expect(h.presses == 1, "Old key stopped working after rejected replacement")
        h.controller.stop()
    }

    @MainActor
    static func testRollback() throws {
        let h = Harness(saved: first)
        h.controller.start()
        h.backend.removeFailures[1] = 1
        try expect(!h.controller.setChord(second), "Failed old removal was reported as success")
        try expect(h.controller.activeChord == first && h.controller.desiredChord == first && h.store.chord == first,
                   "Rollback did not preserve the old preference and effective key")
        try expect(h.backend.registrations == [1: first] && h.backend.removedIDs == [1, 2] && !h.controller.hasPendingCleanup,
                   "Rollback did not remove the candidate")
        h.backend.emit(2)
        h.backend.emit(1)
        try expect(h.presses == 1, "Rolled-back candidate fired or old key failed")
        h.controller.stop()
    }

    @MainActor
    static func testFailedRollback() throws {
        let h = Harness(saved: first)
        h.controller.start()
        h.backend.removeFailures = [1: 2, 2: 2]
        try expect(!h.controller.setChord(second), "Incomplete transaction was adopted")
        try expect(h.controller.hasPendingCleanup && h.controller.activeChord == nil && h.controller.desiredChord == first,
                   "Ambiguous registration state was shown as active")
        try expect(h.backend.registrations.count == 2 && h.store.chord == first, "Rollback failure lost a reference or saved candidate")
        h.backend.emit(1)
        h.backend.emit(2)
        try expect(h.presses == 0, "Uncertain registration state delivered a press")
        try expect(!h.controller.setChord(nil), "Failed cleanup was reported as a completed clear")
        try expect(h.controller.hasPendingCleanup && h.store.chord == first && h.backend.registrations.count == 2,
                   "Cleanup failure discarded pending references or preference")
        try expect(h.controller.setChord(nil), "Explicit cleanup retry failed")
        try expect(!h.controller.hasPendingCleanup && h.backend.registrations.isEmpty && h.store.chord == nil,
                   "Successful cleanup left registrations or the old preference")
        h.backend.emit(1)
        h.backend.emit(2)
        try expect(h.presses == 0, "Cleaned-up registration fired")
        h.controller.stop()
    }

    @MainActor
    static func testClear() throws {
        let h = Harness(saved: first)
        h.controller.start()
        h.backend.removeFailures[1] = 1
        try expect(!h.controller.setChord(nil), "Failed clear was reported as success")
        try expect(h.controller.activeChord == first && h.controller.desiredChord == first && h.store.chord == first,
                   "Failed clear misrepresented the remaining registration")
        try expect(h.controller.statusDetail(for: .single) == h.controller.statusText,
                   "Matching active and saved keys hid a failed clear")
        h.backend.emit(1)
        try expect(h.presses == 1, "Known remaining key was silently disabled")
        try expect(h.controller.setChord(nil), "Clear retry failed")
        try expect(h.controller.activeChord == nil && h.controller.desiredChord == nil && h.backend.registrations.isEmpty,
                   "Clear did not remove registration and preference")
        h.backend.emit(1)
        try expect(h.presses == 1, "Cleared registration delivered")
        h.controller.stop()
    }

    @MainActor
    static func testDeliveryGate() throws {
        let h = Harness(saved: first)
        h.controller.start()
        let queuedBeforeSettings = h.backend.queued(1)
        h.gateOpen = false
        queuedBeforeSettings()
        h.backend.emit(999)
        try expect(h.presses == 0, "Queued notification bypassed current UI gate")
        h.gateOpen = true
        h.backend.emit(1)
        try expect(h.presses == 1, "Gate did not recover after explicit UI closure")
        let queuedBeforeStop = h.backend.queued(1)
        h.controller.stop()
        queuedBeforeStop()
        try expect(h.presses == 1, "Queued notification fired after stop")

        let closedByDefault = ProductHotKeyController(backend: h.backend, store: MemoryStore(first))
        var defaultPresses = 0
        closedByDefault.onPressed = { defaultPresses += 1 }
        closedByDefault.start()
        h.backend.emit(2)
        try expect(defaultPresses == 0, "Unconfigured UI gate was open by default")
        closedByDefault.stop()
    }

    @MainActor
    static func testStop() throws {
        let h = Harness(saved: first)
        h.controller.start()
        h.backend.removeFailures[1] = 2
        h.controller.stop()
        try expect(!h.controller.isStarted && h.controller.activeChord == nil && h.controller.hasPendingCleanup,
                   "Stop failed to block an unremoved OS registration")
        try expect(h.backend.registrations == [1: first] && h.store.chord == first,
                   "Stop lost reference or erased saved preference")
        h.backend.emit(1)
        try expect(h.presses == 0, "Unremoved key fired after stop")
        h.controller.start()
        try expect(h.controller.activeChord == nil && h.controller.hasPendingCleanup && h.backend.attemptedChords.count == 1,
                   "Restart registered while stale registration cleanup failed")
        h.controller.start()
        try expect(h.controller.activeChord == first && !h.controller.hasPendingCleanup && h.backend.registrations == [2: first],
                   "Restart failed to clean old reference before restoring")
        h.backend.emit(1)
        h.backend.emit(2)
        try expect(h.presses == 1, "Late pre-stop key matched restored registration")
        h.controller.stop()
        try expect(h.backend.registrations.isEmpty && h.store.chord == first, "Successful stop did not release key while preserving preference")
    }

    @MainActor
    static func testHandlerCleanup() throws {
        let h = Harness(saved: first)
        h.controller.start()
        h.backend.finishFailures = 1
        h.controller.stop()
        try expect(h.controller.hasPendingCleanup && h.backend.registrations.isEmpty && h.controller.activeChord == nil,
                   "Handler removal failure was discarded")
        h.backend.emit(1)
        try expect(h.presses == 0, "Old handler delivered after stop")
        h.controller.start()
        try expect(!h.controller.hasPendingCleanup && h.controller.activeChord == first && h.backend.registrations == [2: first],
                   "Handler cleanup retry failed to restore")
        h.controller.stop()

        let cleared = Harness(saved: first)
        cleared.controller.start()
        cleared.backend.finishFailures = 1
        try expect(!cleared.controller.setChord(nil) && cleared.controller.hasPendingCleanup
                   && cleared.controller.activeChord == nil && cleared.controller.desiredChord == nil,
                   "Handler-only cleanup fixture did not keep the nil-key recovery state")
        let writes = cleared.store.saves.count
        try expect(cleared.controller.retryCleanup() && !cleared.controller.hasPendingCleanup
                   && cleared.backend.registrations.isEmpty && cleared.store.saves.count == writes,
                   "Handler-only recovery required a saved key or rewrote preferences")
        cleared.controller.stop()
    }

    @MainActor
    static func testValidation() throws {
        let invalid = [
            HotKeyChord(keyCode: UInt32(kVK_ANSI_9), modifiers: 0),
            HotKeyChord(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(shiftKey)),
            HotKeyChord(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(cmdKey | alphaLock)),
            HotKeyChord(keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey)),
            HotKeyChord(keyCode: UInt32(kVK_ANSI_KeypadEnter), modifiers: UInt32(controlKey)),
            HotKeyChord(keyCode: UInt32(kVK_Escape), modifiers: UInt32(optionKey)),
            HotKeyChord(keyCode: UInt32(kVK_Tab), modifiers: UInt32(cmdKey)),
            HotKeyChord(keyCode: UInt32(kVK_Delete), modifiers: UInt32(controlKey)),
            HotKeyChord(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(optionKey)),
            HotKeyChord(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey)),
            HotKeyChord(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(cmdKey)),
            HotKeyChord(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)),
            HotKeyChord(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey)),
            HotKeyChord(keyCode: UInt32(kVK_ANSI_8), modifiers: UInt32(controlKey | optionKey | cmdKey)),
            HotKeyChord(keyCode: UInt32(kVK_F2), modifiers: UInt32(controlKey))
        ]
        let h = Harness(saved: first)
        h.controller.start()
        for chord in invalid {
            try expect(chord.validationMessage != nil && !h.controller.setChord(chord), "Known unsafe chord was accepted")
        }
        h.controller.reservedChords = { [second] }
        try expect(!h.controller.setChord(second), "App duplicate was accepted")
        try expect(h.backend.attemptedChords == [first] && h.controller.activeChord == first && h.store.chord == first,
                   "Validation changed OS registration or persistence")
        try expect(first.validationMessage == nil && first.displayName.contains("Control") && first.displayName.contains("物理キー"),
                   "Valid physical chord has no explicit display")
        h.controller.stop()
    }

    @MainActor
    static func testPreferences() throws {
        let suite = "OneClip.ProductHotKeyTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "Cannot create isolated preference suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsHotKeyPreferenceStore(defaults: defaults, key: "testChord")
        try expect(store.loadChord() == nil, "Fresh isolated preferences are not empty")
        store.saveChord(first)
        let reloaded = UserDefaultsHotKeyPreferenceStore(defaults: defaults, key: "testChord")
        try expect(reloaded.loadChord() == first, "Saved chord did not survive store recreation")
        let backend = FakeBackend()
        let controller = ProductHotKeyController(backend: backend, store: reloaded)
        try expect(controller.desiredChord == first && controller.activeChord == nil && backend.attemptedChords.isEmpty,
                   "Preference read registered a key")
        controller.start()
        try expect(controller.activeChord == first && controller.setChord(nil) && reloaded.loadChord() == nil,
                   "Clear was not persisted")
        controller.stop()
        defaults.set(Data([0, 1, 2]), forKey: "testChord")
        try expect(reloaded.loadChord() == nil, "Corrupt preferences became an active chord")
        let invalid = HotKeyChord(keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey))
        reloaded.saveChord(invalid)
        let rejected = ProductHotKeyController(backend: backend, store: reloaded)
        rejected.start()
        try expect(rejected.activeChord == nil && rejected.desiredChord == invalid && backend.registrations.isEmpty,
                   "Invalid stored chord was registered or hidden")
        rejected.stop()
    }

    @MainActor
    static func testDualRouting() throws {
        let h = Harness(saved: first, savedCollection: second)
        try expect(h.controller.desiredCollectionChord == second && h.controller.activeCollectionChord == nil && h.backend.registrations.isEmpty,
                   "Collection preference registered in the initializer")
        h.controller.start()
        try expect(h.backend.registrations == [1: first, 2: second], "Roles did not share distinct backend IDs")
        h.backend.emit(1)
        h.backend.emit(2)
        try expect(h.presses == 1 && h.collectionPresses == 1, "Role IDs routed to the wrong action")
        h.gateOpen = false
        h.backend.emit(1)
        h.backend.emit(2)
        try expect(h.presses == 1 && h.collectionPresses == 2, "Single gate blocked or admitted the wrong role")
        h.gateOpen = true
        h.collectionGateOpen = false
        h.backend.emit(1)
        h.backend.emit(2)
        try expect(h.presses == 2 && h.collectionPresses == 2, "Collection gate blocked or admitted the wrong role")
        h.collectionGateOpen = true
        h.controller.settingsInteractionBlocked = true
        h.backend.queued(1)()
        h.backend.queued(2)()
        try expect(h.presses == 2 && h.collectionPresses == 2, "Settings/recorder suppression did not cover both roles")
        h.controller.settingsInteractionBlocked = false
        let oldCollectionEvent = h.backend.queued(2)
        try expect(h.controller.setCollectionChord(third), "Collection replacement failed")
        oldCollectionEvent()
        h.backend.emit(1)
        h.backend.emit(3)
        try expect(h.presses == 3 && h.collectionPresses == 3 && h.backend.registrations == [1: first, 3: third],
                   "Old collection ID revived or replacement displaced the single role")
        h.controller.stop()

        let backend = FakeBackend()
        let closed = ProductHotKeyController(backend: backend, store: MemoryStore(), collectionStore: MemoryStore(second))
        var deliveries = 0
        closed.onCollectionPressed = { deliveries += 1 }
        closed.start()
        backend.emit(1)
        try expect(deliveries == 0, "Collection gate was open without app integration")
        closed.stop()
    }

    @MainActor
    static func testDualDuplicates() throws {
        let h = Harness(saved: first, savedCollection: first)
        h.controller.start()
        try expect(h.backend.registrations == [1: first] && h.controller.activeChord == first && h.controller.activeCollectionChord == nil,
                   "Duplicate restoration displaced or duplicated the legacy single key")
        try expect(h.collectionStore.chord == first && h.collectionStore.saves.isEmpty && h.controller.desiredCollectionChord == first,
                   "Rejected collection restoration hid its saved wish")
        try expect(!h.controller.setCollectionChord(first) && h.controller.setCollectionChord(second),
                   "Duplicate collection key was accepted or distinct key rejected")
        let attempts = h.backend.attemptedChords.count
        try expect(!h.controller.setChord(second) && !h.controller.setCollectionChord(first), "Cross-role duplicate was accepted")
        try expect(h.backend.attemptedChords.count == attempts && h.store.chord == first && h.collectionStore.chord == second,
                   "Duplicate rejection changed OS registration or either preference")
        h.controller.stop()

        let desiredOnly = Harness(saved: first, savedCollection: second)
        desiredOnly.backend.registerFailuresForChord[second] = 1
        desiredOnly.controller.start()
        try expect(!desiredOnly.controller.setChord(second) && desiredOnly.controller.activeChord == first,
                   "Single key stole an unregistered saved collection assignment")
        desiredOnly.controller.stop()
    }

    @MainActor
    static func testDualRollback() throws {
        let h = Harness(saved: first, savedCollection: second)
        h.controller.start()
        h.backend.removeFailures[2] = 1
        try expect(!h.controller.setCollectionChord(third), "Failed collection replacement was adopted")
        try expect(h.backend.registrations == [1: first, 2: second] && h.controller.activeCollectionChord == second && h.collectionStore.chord == second,
                   "Collection rollback lost the old collection or single registration")
        h.backend.emit(1)
        h.backend.emit(2)
        h.backend.emit(3)
        try expect(h.presses == 1 && h.collectionPresses == 1, "Rollback affected routing or admitted rejected candidate")

        h.backend.removeFailures = [2: 2, 4: 2]
        try expect(!h.controller.setCollectionChord(third), "Ambiguous collection replacement succeeded")
        try expect(h.controller.hasPendingCleanup && h.controller.activeChord == first && h.controller.activeCollectionChord == nil && h.backend.registrations.count == 3,
                   "Ambiguous rollback lost pending references or unaffected role")
        h.backend.emit(1)
        h.backend.emit(2)
        h.backend.emit(4)
        try expect(h.presses == 1 && h.collectionPresses == 1, "Ambiguous collection state did not stop both roles")
        try expect(!h.controller.setCollectionChord(nil) && h.controller.hasPendingCleanup && h.collectionStore.chord == second,
                   "Failed cleanup committed a clear or lost the saved wish")
        let singleWrites = h.store.saves.count
        let collectionWrites = h.collectionStore.saves.count
        try expect(h.controller.retryCleanup() && !h.controller.hasPendingCleanup,
                   "Global cleanup did not recover the pending collection registrations")
        try expect(h.controller.activeChord == first && h.controller.desiredChord == first
                   && h.controller.desiredCollectionChord == second && h.backend.registrations == [1: first]
                   && h.store.saves.count == singleWrites && h.collectionStore.saves.count == collectionWrites,
                   "Global cleanup cleared a healthy key or changed a saved wish")
        try expect(h.controller.setCollectionChord(nil) && !h.controller.hasPendingCleanup && h.backend.registrations == [1: first],
                   "Successful cleanup did not preserve the single registration")
        try expect(h.backend.finishCalls == 0 && h.store.chord == first && h.collectionStore.chord == nil,
                   "Collection cleanup removed the shared handler or altered single preferences")
        h.backend.emit(1)
        h.backend.emit(2)
        h.backend.emit(4)
        try expect(h.presses == 2 && h.collectionPresses == 1, "Cleaned-up collection ID delivered or single key did not recover")
        h.controller.stop()
    }

    @MainActor
    static func testDualLifecycle() throws {
        let h = Harness(saved: first, savedCollection: second)
        h.controller.start()
        try expect(h.controller.setChord(nil), "Single clear failed")
        try expect(h.backend.registrations == [2: second] && h.backend.finishCalls == 0 && h.collectionStore.chord == second,
                   "Single clear removed the collection key or shared handler")
        h.backend.emit(1)
        h.backend.emit(2)
        try expect(h.presses == 0 && h.collectionPresses == 1, "Single clear invalidated the wrong role")
        try expect(h.controller.setChord(first), "Single re-registration failed")
        let oldSingle = h.backend.queued(3)
        let oldCollection = h.backend.queued(2)
        h.controller.stop()
        try expect(h.backend.registrations.isEmpty && h.backend.finishCalls == 1 && h.store.chord == first && h.collectionStore.chord == second,
                   "Stop did not release both roles while preserving independent preferences")
        h.controller.start()
        try expect(h.backend.registrations == [4: first, 5: second], "Restart reused an old ID or failed to restore both roles")
        oldSingle()
        oldCollection()
        h.backend.emit(4)
        h.backend.emit(5)
        try expect(h.presses == 1 && h.collectionPresses == 2, "Queued pre-stop ID matched restored role")
        h.controller.stop()
    }

    @MainActor
    static func testDualRestoration() throws {
        let h = Harness(saved: first, savedCollection: second)
        h.backend.registerFailuresForChord[second] = 1
        h.controller.start()
        try expect(h.controller.activeChord == first && h.controller.activeCollectionChord == nil && h.controller.desiredCollectionChord == second,
                   "Collection restoration failure changed the single role or hid the desired key")
        try expect(h.backend.registrations == [1: first] && h.backend.finishCalls == 0 && h.collectionStore.saves.isEmpty,
                   "Failed collection restore removed the shared handler or resaved a failed setting")
        try expect(h.controller.setCollectionChord(second), "Explicit collection restoration retry failed")
        h.controller.start()
        try expect(h.backend.registrations == [1: first, 2: second] && h.backend.attemptedChords.count == 3,
                   "Repeated startup duplicated a restored role")
        h.controller.stop()
    }

    @MainActor
    static func testDualStopCleanup() throws {
        let h = Harness(saved: first, savedCollection: second)
        h.controller.start()
        h.backend.removeFailures = [1: 2, 2: 1]
        h.controller.stop()
        try expect(h.controller.hasPendingCleanup && h.backend.registrations.count == 2 && h.controller.activeChord == nil && h.controller.activeCollectionChord == nil,
                   "Failed dual stop lost OS references or showed a role active")
        h.controller.start()
        try expect(h.controller.hasPendingCleanup && h.backend.registrations == [1: first] && h.backend.attemptedChords.count == 2,
                   "Partial cleanup restored a role before all stale registrations were removed")
        h.backend.emit(1)
        try expect(h.presses == 0 && h.collectionPresses == 0, "Partially stopped role delivered")
        h.controller.start()
        try expect(!h.controller.hasPendingCleanup && h.backend.registrations == [3: first, 4: second],
                   "Dual cleanup retry did not restore independent fresh IDs")
        h.backend.emit(1)
        h.backend.emit(2)
        h.backend.emit(3)
        h.backend.emit(4)
        try expect(h.presses == 1 && h.collectionPresses == 1, "Stale IDs matched restored dual registrations")
        h.controller.stop()
    }

    @MainActor
    static func testDualPreferences() throws {
        let suite = "OneClip.DualHotKeyTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "Cannot create isolated preference suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let single = UserDefaultsHotKeyPreferenceStore(defaults: defaults)
        let collection = UserDefaultsHotKeyPreferenceStore(defaults: defaults, key: UserDefaultsHotKeyPreferenceStore.collectionKey)
        single.saveChord(first)
        let legacyData = defaults.data(forKey: "OneClip.singleCaptureHotKey.v1")
        try expect(legacyData != nil && collection.loadChord() == nil, "Legacy single key changed or new collection key was not initially unset")
        let backend = FakeBackend()
        let controller = ProductHotKeyController(backend: backend, store: single, collectionStore: collection)
        controller.start()
        try expect(controller.activeChord == first && controller.activeCollectionChord == nil && controller.setCollectionChord(second),
                   "Independent collection preference could not be adopted")
        try expect(single.loadChord() == first, "Collection setting changed the decoded legacy single key")
        try expect(collection.loadChord() == second, "Collection setting was not saved independently")
        try expect(defaults.data(forKey: "OneClip.singleCaptureHotKey.v1") == legacyData,
                   "Restoration or collection setting unnecessarily rewrote the legacy single preference")
        try expect(controller.setCollectionChord(nil) && single.loadChord() == first && collection.loadChord() == nil,
                   "Collection clear erased the single preference")
        controller.stop()
        let recreated = ProductHotKeyController(backend: FakeBackend(), store: single, collectionStore: collection)
        try expect(recreated.desiredChord == first && recreated.desiredCollectionChord == nil && !recreated.isStarted,
                   "Recreated dual controller did not preserve independent unset state")
    }

    @MainActor
    static func testDualTransaction() throws {
        let h = Harness(saved: first, savedCollection: second)
        h.controller.start()
        let collectionWrites = h.collectionStore.saves.count
        var reentrantResult: Bool?
        h.backend.duringRegister = { [weak h] _ in
            guard let h else { return }
            h.backend.emit(1)
            h.backend.emit(2)
            reentrantResult = h.controller.setCollectionChord(second)
        }
        try expect(h.controller.setChord(third), "Outer replacement failed")
        try expect(reentrantResult == false && h.presses == 0 && h.collectionPresses == 0 && h.collectionStore.saves.count == collectionWrites,
                   "In-flight transaction admitted delivery or a reentrant preference write")
        try expect(h.backend.registrations == [2: second, 3: third] && h.controller.activeCollectionChord == second && h.controller.activeChord == third,
                   "Reentrant setting altered the final role ownership")
        h.backend.emit(2)
        h.backend.emit(3)
        try expect(h.presses == 1 && h.collectionPresses == 1, "Delivery did not resume after the complete transaction")
        h.backend.duringRegister = nil
        h.controller.stop()
    }

    @MainActor
    static func testRegisteredRecording() throws {
        let h = Harness(saved: first, savedCollection: second)
        h.controller.start()
        let registrations = h.backend.registrations
        let attempts = h.backend.attemptedChords
        let singleSaves = h.store.saves.count
        let collectionSaves = h.collectionStore.saves.count
        var candidates: [HotKeyChord] = []
        try expect(h.controller.beginShortcutRecording(allowed: { true }, candidate: { candidates.append($0) }) == nil,
                   "Recorder armed outside settings")
        h.controller.settingsInteractionBlocked = true
        for (id, chord) in [(UInt32(1), first), (UInt32(2), second)] {
            let token = h.controller.beginShortcutRecording(allowed: { true }, candidate: { candidates.append($0) })
            try expect(token != nil, "Focused settings recorder did not arm")
            h.backend.emit(id)
            h.backend.emit(id)
            try expect(candidates.last == chord && candidates.count == Int(id), "Owned ID was not consumed as exactly one candidate")
        }
        try expect(h.presses == 0 && h.collectionPresses == 0, "Recording invoked a capture action")
        try expect(h.backend.registrations == registrations && h.backend.attemptedChords == attempts
                   && h.backend.removedIDs.isEmpty && h.backend.finishCalls == 0,
                   "Recorder temporarily changed an OS registration or handler")
        try expect(h.store.chord == first && h.collectionStore.chord == second
                   && h.store.saves.count == singleSaves && h.collectionStore.saves.count == collectionSaves,
                   "Selecting a recorder candidate changed a saved preference")
        h.controller.stop()
    }

    @MainActor
    static func testRecordingFreshness() throws {
        let h = Harness(saved: first, savedCollection: second)
        h.controller.start()
        try expect(h.controller.setChord(third), "Cannot prepare an obsolete single ID")
        h.controller.settingsInteractionBlocked = true
        var candidates: [HotKeyChord] = []
        let started = h.backend.currentEventTime
        guard let token = h.controller.beginShortcutRecording(allowed: { true }, candidate: { candidates.append($0) }) else {
            throw Failure(description: "Cannot arm timestamp test")
        }
        for time in [started - 1, started, 0, -1, .nan, .infinity, -.infinity, started + 1] as [EventTime] {
            h.backend.emit(2, at: time)
        }
        h.backend.emit(1) // Removed ID, even though its timestamp is fresh.
        h.backend.emit(999)
        let invalid = HotKeyChord(keyCode: UInt32(kVK_Return), modifiers: UInt32(controlKey))
        try expect(!h.controller.submitShortcutCandidate(invalid, occurredAt: h.backend.advance(), recording: token),
                   "Invalid local navigation chord became a candidate")
        try expect(candidates.isEmpty && h.presses == 0 && h.collectionPresses == 0,
                   "Stale, future, invalid or unknown event reached a candidate or capture")
        h.backend.emit(2)
        try expect(candidates == [second], "A rejected event consumed the valid recording lease")
        h.controller.stop()
    }

    @MainActor
    static func testRecordingLocalAndGeneration() throws {
        let h = Harness(saved: first, savedCollection: second)
        h.controller.start()
        h.controller.settingsInteractionBlocked = true
        var candidates: [HotKeyChord] = []
        guard let old = h.controller.beginShortcutRecording(allowed: { true }, candidate: { candidates.append($0) }) else {
            throw Failure(description: "Cannot arm old recording generation")
        }
        let queuedOld = h.backend.queued(1)
        h.controller.cancelShortcutRecording(old) // Esc/Tab/cancel/role change use this same boundary.
        _ = h.backend.advance()
        guard let current = h.controller.beginShortcutRecording(allowed: { true }, candidate: { candidates.append($0) }) else {
            throw Failure(description: "Cannot rearm recording")
        }
        h.controller.cancelShortcutRecording(old) // A late old-view teardown cannot cancel its successor.
        queuedOld()
        try expect(!h.controller.submitShortcutCandidate(third, occurredAt: h.backend.advance(), recording: old),
                   "An obsolete local-view token fed the new recorder")
        try expect(candidates.isEmpty, "A queued pre-generation Carbon press fed the new recorder")
        try expect(h.controller.submitShortcutCandidate(third, occurredAt: h.backend.advance(), recording: current),
                   "Current local input did not become a candidate")
        h.backend.emit(1)
        try expect(!h.controller.submitShortcutCandidate(second, occurredAt: h.backend.advance(), recording: current)
                   && candidates == [third], "Local candidate was followed by a Carbon/local duplicate")

        guard let next = h.controller.beginShortcutRecording(allowed: { true }, candidate: { candidates.append($0) }) else {
            throw Failure(description: "Cannot arm a subsequent explicit recording")
        }
        h.backend.emit(2)
        try expect(!h.controller.submitShortcutCandidate(first, occurredAt: h.backend.advance(), recording: next)
                   && candidates == [third, second], "Carbon candidate was followed by a local duplicate")
        try expect(h.presses == 0 && h.collectionPresses == 0, "Generation change leaked a capture")
        h.controller.stop()
    }

    @MainActor
    static func testRecordingContextLoss() throws {
        let h = Harness(saved: first, savedCollection: second)
        h.controller.start()
        h.controller.settingsInteractionBlocked = true
        var context = [true, true, true, true] // UI adapter supplies key-window/app/first-responder/view checks.
        var candidates: [HotKeyChord] = []
        for lost in context.indices {
            try expect(h.controller.beginShortcutRecording(allowed: { context.allSatisfy { $0 } },
                                                           candidate: { candidates.append($0) }) != nil,
                       "Cannot arm allowed UI context")
            context[lost] = false
            h.backend.emit(1)
            context[lost] = true
            h.backend.emit(2)
            try expect(candidates.count == lost, "A lost UI context resumed without new explicit recording")
            try expect(h.controller.beginShortcutRecording(allowed: { context.allSatisfy { $0 } },
                                                           candidate: { candidates.append($0) }) != nil,
                       "Explicit recording could not resume after context recovery")
            h.backend.emit(2)
        }
        try expect(candidates == Array(repeating: second, count: 4), "Explicit context recovery failed")
        _ = h.controller.beginShortcutRecording(allowed: { true }, candidate: { candidates.append($0) })
        let duringSettings = h.backend.queued(1)
        h.controller.settingsInteractionBlocked = false // close/hide synchronously revokes the lease and fences capture.
        duringSettings()
        try expect(candidates.count == 4 && h.presses == 0 && h.collectionPresses == 0,
                   "A settings-time press fell through to capture after close")
        h.backend.emit(1)
        h.backend.emit(2)
        try expect(h.presses == 1 && h.collectionPresses == 1, "Fresh product presses did not resume after settings closed")
        h.controller.stop()
    }

    @MainActor
    static func testRecordingUnavailable() throws {
        let h = Harness(saved: first, savedCollection: second)
        h.controller.settingsInteractionBlocked = true
        var candidates: [HotKeyChord] = []
        try expect(h.controller.beginShortcutRecording(allowed: { true }, candidate: { candidates.append($0) }) == nil,
                   "Stopped controller armed a recorder")
        h.controller.start()
        guard let token = h.controller.beginShortcutRecording(allowed: { true }, candidate: { candidates.append($0) }) else {
            throw Failure(description: "Cannot arm before stop")
        }
        let queued = h.backend.queued(1)
        h.controller.stop()
        queued()
        try expect(!h.controller.submitShortcutCandidate(third, occurredAt: h.backend.advance(), recording: token),
                   "Stopped recorder accepted local input")
        h.controller.start()
        try expect(h.controller.beginShortcutRecording(allowed: { true }, candidate: { candidates.append($0) }) != nil,
                   "Explicit lifecycle restart could not record")
        try expect(h.controller.setChord(third), "Cannot change a registered key")
        h.backend.emit(3) // The transaction must have cancelled the earlier recorder.
        h.backend.emit(5)
        try expect(candidates.isEmpty, "Registration transaction left its old recorder armed")
        h.backend.currentEventTime = .nan
        try expect(h.controller.beginShortcutRecording(allowed: { true }, candidate: { candidates.append($0) }) == nil,
                   "Invalid recording clock armed a lease")
        h.backend.currentEventTime = 200
        h.controller.stop()

        let ambiguous = Harness(saved: first, savedCollection: second)
        ambiguous.controller.start()
        ambiguous.controller.settingsInteractionBlocked = true
        ambiguous.backend.removeFailures = [1: 1, 3: 1]
        try expect(!ambiguous.controller.setChord(third) && ambiguous.controller.hasPendingCleanup,
                   "Cannot prepare ambiguous registration cleanup")
        try expect(ambiguous.controller.beginShortcutRecording(allowed: { true }, candidate: { candidates.append($0) }) == nil,
                   "Ambiguous registrations armed a recorder")
        ambiguous.backend.emit(1)
        ambiguous.backend.emit(2)
        ambiguous.backend.emit(3)
        try expect(candidates.isEmpty && h.presses == 0 && h.collectionPresses == 0
                   && ambiguous.presses == 0 && ambiguous.collectionPresses == 0,
                   "Unavailable recorder delivered a candidate or capture")
        ambiguous.controller.stop()
    }

    @MainActor
    static func testPresentationBoundary() throws {
        let h = Harness(saved: first, savedCollection: second)
        h.controller.start()
        let registered = h.backend.registrations
        let attempts = h.backend.attemptedChords.count
        let beforeOpening = h.backend.queued(1)
        h.gateOpen = false; h.collectionGateOpen = false
        h.controller.discardQueuedPresses() // confirmation or expanded presentation begins
        h.backend.emit(1); h.backend.emit(2)
        let duringSingle = h.backend.queued(1), duringCollection = h.backend.queued(2)
        h.controller.discardQueuedPresses() // close fences events before reopening delivery
        h.gateOpen = true; h.collectionGateOpen = true
        beforeOpening(); duringSingle(); duringCollection()
        try expect(h.presses == 0 && h.collectionPresses == 0,
                   "A presentation-time event started capture after the gate reopened")
        h.backend.emit(1); h.backend.emit(2)
        try expect(h.presses == 1 && h.collectionPresses == 1, "Fresh explicit presses did not resume")
        h.backend.currentEventTime = .nan
        h.controller.discardQueuedPresses()
        h.backend.currentEventTime = 200
        h.backend.emit(1); h.backend.emit(2)
        try expect(h.presses == 1 && h.collectionPresses == 1, "An unknown presentation clock failed open")
        h.controller.discardQueuedPresses()
        h.backend.emit(1); h.backend.emit(2)
        try expect(h.presses == 2 && h.collectionPresses == 2, "A fresh valid boundary did not recover delivery")
        try expect(h.backend.registrations == registered && h.backend.attemptedChords.count == attempts
                   && h.backend.removedIDs.isEmpty && h.store.saves.isEmpty && h.collectionStore.saves.isEmpty
                   && h.controller.activeChord == first && h.controller.activeCollectionChord == second,
                   "A presentation boundary changed preferences or actual registrations")
        h.controller.stop()
    }

    @MainActor
    static func testHeldEditingBoundary() throws {
        for id in [UInt32(1), UInt32(2)] {
            let h = Harness(saved: first, savedCollection: second)
            h.controller.start()
            h.controller.settingsInteractionBlocked = true
            var candidates: [HotKeyChord] = []
            _ = h.controller.beginShortcutRecording(allowed: { true }, candidate: { candidates.append($0) })
            h.backend.press(id)
            try expect(candidates == [id == 1 ? first : second], "Held registered input was not one candidate")
            h.controller.settingsInteractionBlocked = false // Candidate was explicitly accepted/cancelled.
            h.backend.press(id, isRepeat: true)
            h.backend.press(id, isRepeat: true)
            try expect(h.presses == 0 && h.collectionPresses == 0, "Editing completion converted repeat into capture")
            h.backend.release(id)
            h.backend.emit(id)
            try expect(h.presses + h.collectionPresses == 1, "A new press after release did not capture")

            h.controller.settingsInteractionBlocked = true
            h.backend.press(id) // Editing loses focus/closes before a candidate is consumed.
            h.controller.cancelShortcutRecording()
            h.controller.settingsInteractionBlocked = false
            h.backend.press(id, isRepeat: true)
            h.backend.release(id)
            try expect(h.presses + h.collectionPresses == 1, "Context loss converted held input into capture")
            h.backend.emit(id)
            try expect(h.presses + h.collectionPresses == 2, "Explicit fresh press did not recover after cancellation")
            h.controller.stop()
        }
    }

    @MainActor
    static func testLocalCandidateRepeat() throws {
        let h = Harness(saved: first, savedCollection: second)
        h.controller.start()
        h.controller.settingsInteractionBlocked = true
        var candidates: [HotKeyChord] = []
        guard let token = h.controller.beginShortcutRecording(allowed: { true }, candidate: { candidates.append($0) }) else {
            throw Failure(description: "Cannot arm local candidate repeat scenario")
        }
        let downTime = h.backend.advance()
        try expect(h.controller.submitShortcutCandidate(first, occurredAt: downTime, recording: token),
                   "Local candidate was not accepted")
        h.controller.settingsInteractionBlocked = false
        // Native normalization happens before the actor hop. Even if the repeat arrives before
        // the original Carbon down event, it remains a repeat and cannot request a capture.
        h.backend.press(1, isRepeat: true)
        h.backend.press(1, at: downTime)
        h.backend.press(1, isRepeat: true)
        try expect(candidates == [first] && h.presses == 0, "Local/Carbon duplicate or reordered repeat escaped editing")
        h.backend.release(1)
        h.backend.emit(1)
        try expect(h.presses == 1, "Fresh key after local/Carbon duplicate did not resume")
        h.controller.stop()
    }

    @MainActor
    static func testHeldRegistration() throws {
        for role in CaptureHotKeyRole.allCases {
            let h = Harness(saved: first, savedCollection: second)
            h.controller.start()
            let attempts = h.backend.attemptedChords
            let registrations = h.backend.registrations
            h.controller.settingsInteractionBlocked = true
            h.backend.heldKeyCodes.insert(third.keyCode)
            try expect(!h.controller.setChord(third, for: role), "Still-held unregistered candidate was registered")
            try expect(h.backend.attemptedChords == attempts && h.backend.registrations == registrations
                       && h.store.chord == first && h.collectionStore.chord == second,
                       "Held candidate changed the effective or persisted setting")
            try expect(h.controller.statusText(for: role).contains("キーを離して"), "Held candidate did not explain recovery")
            h.backend.heldKeyCodes.remove(third.keyCode)
            try expect(h.controller.setChord(third, for: role), "Released candidate could not be explicitly registered")
            h.controller.settingsInteractionBlocked = false
            h.backend.emit(3)
            try expect(h.presses + h.collectionPresses == 1, "New registered key did not deliver its fresh tap")
            h.controller.stop()
        }
    }

    @MainActor
    static func testNativeEdgeNormalization() throws {
        var input = ProductHotKeyInputState()
        input.register(1)
        input.register(2)
        func event(_ id: UInt32, _ time: EventTime, _ kind: ProductHotKeyPress.Kind = .pressed) -> ProductHotKeyPress {
            ProductHotKeyPress(identifier: id, occurredAt: time, kind: kind)
        }
        try expect(input.consume(event(99, 1)) == nil, "Unknown native identifier was accepted")
        try expect(input.consume(event(1, 2))?.isRepeat == false, "Native first down was a repeat")
        try expect(input.consume(event(1, 3))?.isRepeat == true, "Native held repeat was not normalized")
        try expect(input.consume(event(1, 2.5, .released)) == nil, "Old release rewound native state")
        try expect(input.consume(event(1, 4))?.isRepeat == true, "Old release made held native input fresh")
        try expect(input.consume(event(2, 4))?.isRepeat == false, "One role's hold blocked the other role")
        try expect(input.consume(event(1, 5, .released))?.kind == .released, "Native release was lost")
        try expect(input.consume(event(1, 6))?.isRepeat == false, "Native release did not allow a new press")
        input.unregister(1)
        try expect(input.consume(event(1, 7)) == nil, "Removed ID survived native normalization")
        input.register(3, heldAt: 8)
        try expect(input.consume(event(3, 9))?.isRepeat == true, "Key held during registration was treated as fresh")
        _ = input.consume(event(3, 10, .released))
        try expect(input.consume(event(3, 11))?.isRepeat == false, "Registered held key did not recover on release")
        try expect(input.consume(event(3, .nan, .released)) == nil
                   && input.consume(event(3, .infinity, .released)) == nil,
                   "Invalid native clock cleared held state")
        try expect(input.consume(event(3, 12))?.isRepeat == true, "Invalid native release changed down state")
    }
}
