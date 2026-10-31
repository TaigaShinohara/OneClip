import Dispatch
import Foundation

/// Optional, process-local evidence for one explicit diagnostic trial. No image, window identity,
/// user identity, error text or arbitrary string can enter an entry. The production default is off.
/// The lock orders callbacks from different executors; it does not make OS transitions atomic.
final class CaptureSecurityTrace: @unchecked Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable { case none, single, collection, annotation }
    enum Phase: String, Codable, CaseIterable, Sendable {
        case none, idle, onboarding, permission, selecting, capturing, encoding, writing
        case failure, cancelling, ready, reviewingReplacement
    }
    enum Outcome: String, Codable, CaseIterable, Sendable {
        case none, accepted, rejected, changed, unchanged, unavailable, cancelled
        case success, failure, stale, restarted
    }
    enum Code: String, Codable, CaseIterable, Sendable {
        case systemSleep, displaySleep, sessionResigned, displayChanged, protectedDataUnavailable
        case consoleSessionChanged, consoleSessionUnavailable, consoleUserChanged, consoleUserUnavailable
        case cgDispatch, cgCheck, cgRegister, cgRegisterDispatch, cgRegisterCheck, cgCancel
        case scDelivery, scCheck, scRegister, scCancel, environmentValidated
        case operationStarted, operationInvalidated, captureRequested, captureCallback, captureReturned
        case compositionStarted, compositionCheckpoint, compositionFinished
        case allocationCheckpoint, sourceCheckpoint, beforeEncoding, afterEncoding, beforeResult
        case cancellationRequested, workerStarted, workerReturned, slotAcquired, slotReleased, resultAdopted
        case viewShown, viewHidden, viewDraw, clipboardPrepared, clipboardWrite, clipboardOutcome
        case permissionChecked, permissionRequested
        case resultReceived, resultInvalidated, resultInvalidationDelivered
        case archiveQueued, archiveStarted, archiveReturned, archiveOutcome
        case resultPreviewShown, resultPreviewHidden, resultPreviewDraw, editCopyStarted, editCopyReturned
        case annotationOpened, annotationLoaded, annotationExportStarted, annotationExportReturned
        case annotationInvalidated, annotationResultAdopted, annotationViewShown, annotationViewHidden, annotationViewDraw
        case annotationInvalidationDelivered
        case trialReady, manualTransitionConfirmed, trialRecoveryStarted, trialRecoveryFinished, trialFinished
    }

    struct Entry: Codable, Equatable, Sendable {
        let trial: UInt32
        let sequence: UInt64
        let relativeNanos: UInt64
        let code: Code
        let mode: Mode
        let phase: Phase
        let outcome: Outcome
    }

    struct Snapshot: Sendable {
        let entries: [Entry]
        let droppedCount: UInt64
        let capacity: Int
        let isEnabled: Bool
    }

    static let maximumCapacity = 8_192
    static let disabled = CaptureSecurityTrace()
    let isEnabled: Bool
    private let capacity: Int
    private let trial: UInt32
    private let started: UInt64
    // All mutable storage below is accessed under lock, including snapshot's value copy.
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var droppedCount: UInt64 = 0

    init(enabled: Bool = false, capacity: Int = maximumCapacity, trial: UInt32 = 0) {
        isEnabled = enabled
        self.capacity = min(max(capacity, 1), Self.maximumCapacity)
        self.trial = trial
        started = enabled ? DispatchTime.now().uptimeNanoseconds : 0
        if enabled { entries.reserveCapacity(self.capacity) }
    }

    /// Synchronous and non-reentrant: no callback, I/O, actor hop or wait for another executor.
    /// Once full, preserve the original evidence and count dropped entries. A dropped trial is
    /// incomplete evidence; wrapping over the earliest invalidation would hide that fact.
    func record(_ code: Code, mode: Mode = .none, phase: Phase = .none, outcome: Outcome = .none) {
        guard isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard entries.count < capacity else {
            if droppedCount < UInt64.max { droppedCount += 1 }
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        entries.append(Entry(trial: trial, sequence: UInt64(entries.count) + 1,
                             relativeNanos: now >= started ? now - started : 0,
                             code: code, mode: mode, phase: phase, outcome: outcome))
    }

    func snapshot() -> Snapshot {
        guard isEnabled else { return Snapshot(entries: [], droppedCount: 0, capacity: capacity, isEnabled: false) }
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(entries: entries, droppedCount: droppedCount, capacity: capacity, isEnabled: true)
    }
}
