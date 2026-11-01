import CoreGraphics
import Darwin
import Foundation

// Temporary object-lifetime pilot only. It never reads provider bytes or writes an image.
private enum PilotFailure: String, Error, Sendable {
    case invalid_arguments, stale_generation, duplicate_hook, missing_hook
    case provider_unavailable, identity_mismatch, shape_mismatch, positive_control_failed
    case object_retained, wrapper_incomplete, trace_incomplete, gate_deadline, worker_deadline
    case unexpected_outcome, operation_failed
}
private enum PilotMode: String, CaseIterable, Sendable {
    case positive = "positive_control", success, before = "cancel_before", after = "cancel_after"
    var target: M0CompositionCheckpoint? {
        switch self { case .before: .beforeEncoding; case .after: .afterEncoding; default: nil }
    }
}
private struct WeakSnapshot: Sendable {
    var calls = 0, imageObserved = 0, providerObserved = 0
    var hookImageAlive = -1, hookProviderAlive = -1, getterStable = -1
    var imageAlive = -1, providerAlive = -1
    var reason: PilotFailure?
}

/// Typed weak CF references only. The public hook stores no strong image/provider reference.
final class M4RenderObjectObservation: @unchecked Sendable {
    static let shared = M4RenderObjectObservation()
    private final class Slot {
        weak var image: CGImage?
        weak var provider: CGDataProvider?
        var calls = 0, imageObserved = 0, providerObserved = 0
        var hookImageAlive = -1, hookProviderAlive = -1, getterStable = -1
        var reason: PilotFailure?
    }
    private let lock = NSLock()
    private var slots: [Int: Slot] = [:]
    private var active: Int?
    private var globalFault: PilotFailure?
    private init() {}
    static func record(_ image: CGImage) { shared.recordImage(image) }
    fileprivate func begin(_ generation: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard globalFault == nil, active == nil, generation == slots.count + 1,
              generation <= 4 else { throw PilotFailure.stale_generation }
        slots[generation] = Slot(); active = generation
    }
    private func recordImage(_ image: CGImage) {
        autoreleasepool {
            lock.lock(); defer { lock.unlock() }
            guard let active, let slot = slots[active] else {
                globalFault = .stale_generation; return
            }
            slot.calls += 1
            guard slot.calls == 1 else { slot.reason = .duplicate_hook; return }
            slot.image = image; slot.imageObserved = 1
            slot.hookImageAlive = slot.image === image ? 1 : 0
            guard image.width == 96, image.height == 224, image.bytesPerRow == 384,
                  image.bitsPerComponent == 8, image.bitsPerPixel == 32 else {
                slot.reason = .shape_mismatch; return
            }
            guard let provider = image.dataProvider else { slot.reason = .provider_unavailable; return }
            slot.provider = provider; slot.providerObserved = 1
            slot.hookProviderAlive = slot.provider === provider ? 1 : 0
            if let again = image.dataProvider { slot.getterStable = again === provider ? 1 : 0 }
            else { slot.getterStable = 0 }
            if slot.hookImageAlive != 1 || slot.hookProviderAlive != 1 || slot.getterStable != 1 {
                slot.reason = .identity_mismatch
            }
        }
    }
    /// Returned values are only integers/enums. Weak-load temporary strong references end here.
    fileprivate func snapshot(_ generation: Int) -> WeakSnapshot {
        autoreleasepool {
            lock.lock(); defer { lock.unlock() }
            guard active == generation, let slot = slots[generation] else {
                return WeakSnapshot(reason: .stale_generation)
            }
            return WeakSnapshot(calls: slot.calls, imageObserved: slot.imageObserved,
                providerObserved: slot.providerObserved, hookImageAlive: slot.hookImageAlive,
                hookProviderAlive: slot.hookProviderAlive, getterStable: slot.getterStable,
                imageAlive: slot.imageObserved == 1 ? (slot.image == nil ? 0 : 1) : -1,
                providerAlive: slot.providerObserved == 1 ? (slot.provider == nil ? 0 : 1) : -1,
                reason: globalFault ?? slot.reason)
        }
    }
    fileprivate func matches(_ generation: Int, image: CGImage?, provider: CGDataProvider?) -> (Int, Int) {
        autoreleasepool {
            lock.lock(); defer { lock.unlock() }
            guard active == generation, let slot = slots[generation] else { return (-1, -1) }
            return (image.map { slot.image === $0 ? 1 : 0 } ?? -1,
                    provider.map { slot.provider === $0 ? 1 : 0 } ?? -1)
        }
    }
    fileprivate func close(_ generation: Int) {
        lock.lock(); defer { lock.unlock() }
        if active == generation { active = nil } else { globalFault = .stale_generation }
    }
}

private final class CheckpointGate: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var reachedStorage = false, released = false
    var reached: Bool { lock.lock(); defer { lock.unlock() }; return reachedStorage }
    func pause() throws {
        lock.lock()
        if reachedStorage { lock.unlock(); throw PilotFailure.unexpected_outcome }
        reachedStorage = true; lock.unlock()
        guard semaphore.wait(timeout: .now() + 2) == .success else { throw PilotFailure.gate_deadline }
    }
    func release() {
        lock.lock(); let signal = !released; released = true; lock.unlock()
        if signal { semaphore.signal() }
    }
}
private struct ExecutionFlags: Sendable {
    var wrapperStarted = 0, wrapperReturned = 0, valueAwaited = 0
    var resultReturned = -1, pngBytes = -1
    var compositionEntered = 0, compositionFinished = 0, traceDropped = 0
    var gateReached = 0, cancellationRequested = 0
    var gateImageAlive = -1, gateProviderAlive = -1
    var cancellationOutcome = "not_requested"
    var heldImageAlive = -1, heldProviderAlive = -1
    var heldImageIdentity = -1, heldProviderIdentity = -1
    var providerOnlyImageAlive = -1, providerOnlyProviderAlive = -1
    var elapsed: UInt64 = 0
}
private final class ExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var flags = ExecutionFlags()
    func update(_ body: (inout ExecutionFlags) -> Void) {
        lock.lock(); defer { lock.unlock() }; body(&flags)
    }
    var snapshot: ExecutionFlags { lock.lock(); defer { lock.unlock() }; return flags }
}

@main
struct M4RenderOwnershipPilot {
    private static let deadlineNanoseconds: UInt64 = 2_000_000_000
    private static func makeSources() throws -> [M0ImageAsset] {
        try autoreleasepool {
            try (0..<2).map { index in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                        bytesPerRow: 256, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
                else { throw PilotFailure.operation_failed }
                context.setFillColor(CGColor(gray: CGFloat(index + 1) / 3, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                guard let image = context.makeImage() else { throw PilotFailure.operation_failed }
                return M0ImageAsset(image: image)
            }
        }
    }
    /// The handle is local to this function. The original wrapper awaits its real detached
    /// worker before success/throw; wrapperReturned is not labelled detached-worker entry.
    private static func execute(_ mode: PilotMode, generation: Int, state: ExecutionState) async throws -> M0CompositionResult? {
        let gate = CheckpointGate()
        let trace = CaptureSecurityTrace(enabled: true, capacity: 128, trial: UInt32(generation))
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = started + deadlineNanoseconds
        let operation = Task {
            state.update { $0.wrapperStarted += 1 }
            defer { state.update { $0.wrapperReturned += 1 } }
            let sources = try Self.makeSources()
            return try await M0ImageComposer.composeCancellable(assets: sources, securityTrace: trace,
                checkCancellation: { point in if let target = mode.target, point == target { try gate.pause() } })
        }
        defer { gate.release() }
        var cancellationRequested = false, parentInterrupted = false
        while state.snapshot.wrapperReturned == 0 && DispatchTime.now().uptimeNanoseconds < deadline {
            if mode.target != nil && gate.reached && !cancellationRequested {
                let atGate = M4RenderObjectObservation.shared.snapshot(generation)
                state.update { $0.gateImageAlive = atGate.imageAlive; $0.gateProviderAlive = atGate.providerAlive }
                cancellationRequested = true
                operation.cancel(); gate.release()
            }
            do { try await Task.sleep(nanoseconds: 1_000_000) }
            catch { parentInterrupted = true; break }
        }
        let expired = state.snapshot.wrapperReturned == 0
        if expired || parentInterrupted { operation.cancel(); gate.release() }
        var output: M0CompositionResult?
        var cancelled = false
        var failure: PilotFailure?
        do { output = try await operation.value }
        catch is CancellationError { cancelled = true }
        catch let known as PilotFailure { failure = known }
        catch { failure = .operation_failed }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let traceValue = trace.snapshot()
        state.update {
            $0.valueAwaited = 1
            $0.resultReturned = output == nil ? 0 : 1
            $0.pngBytes = output?.pngData.count ?? 0
            $0.compositionEntered = traceValue.entries.filter { $0.code == .compositionStarted }.count
            $0.compositionFinished = traceValue.entries.filter { $0.code == .compositionFinished }.count
            $0.traceDropped = traceValue.droppedCount == 0 ? 0 : 1
            $0.gateReached = gate.reached ? 1 : 0
            $0.cancellationRequested = cancellationRequested ? 1 : 0
            $0.cancellationOutcome = cancelled ? "cancelled" : "not_requested"
            $0.elapsed = elapsed
        }
        if expired || elapsed > deadlineNanoseconds { throw PilotFailure.worker_deadline }
        if parentInterrupted { throw PilotFailure.operation_failed }
        if let failure { throw failure }
        let flags = state.snapshot
        guard flags.wrapperStarted == 1, flags.wrapperReturned == 1, flags.valueAwaited == 1 else {
            throw PilotFailure.wrapper_incomplete
        }
        guard flags.compositionEntered == 1, flags.compositionFinished == 1, flags.traceDropped == 0 else {
            throw PilotFailure.trace_incomplete
        }
        if mode.target != nil {
            guard cancellationRequested, gate.reached, cancelled, output == nil,
                  flags.resultReturned == 0, flags.pngBytes == 0 else { throw PilotFailure.unexpected_outcome }
            guard flags.gateImageAlive == 1, flags.gateProviderAlive == 1 else { throw PilotFailure.identity_mismatch }
            return nil
        }
        guard !cancelled, output != nil, flags.resultReturned == 1, flags.pngBytes > 0 else {
            throw PilotFailure.unexpected_outcome
        }
        return output
    }
    /// Only this control intentionally owns the returned image/provider past the worker call.
    /// The returned value is a small scalar proof; all result/Task/image/provider locals die here.
    @inline(never)
    private static func positiveBody(generation: Int, state: ExecutionState) async throws {
        var heldImage: M0ImageAsset? = try await retainedOutput(generation: generation, state: state)
        let live = withExtendedLifetime(heldImage) { M4RenderObjectObservation.shared.snapshot(generation) }
        state.update { $0.heldImageAlive = live.imageAlive; $0.heldProviderAlive = live.providerAlive }
        guard live.imageAlive == 1, live.providerAlive == 1 else { throw PilotFailure.positive_control_failed }
        var heldProvider: CGDataProvider? = autoreleasepool { heldImage?.image.dataProvider }
        guard heldProvider != nil else { throw PilotFailure.provider_unavailable }
        let identity = withExtendedLifetime(heldImage) {
            withExtendedLifetime(heldProvider) {
                M4RenderObjectObservation.shared.matches(generation, image: heldImage?.image, provider: heldProvider)
            }
        }
        state.update { $0.heldImageIdentity = identity.0; $0.heldProviderIdentity = identity.1 }
        guard identity.0 == 1, identity.1 == 1 else { throw PilotFailure.identity_mismatch }
        heldImage = nil
        let providerOnly = withExtendedLifetime(heldProvider) { M4RenderObjectObservation.shared.snapshot(generation) }
        state.update { $0.providerOnlyImageAlive = providerOnly.imageAlive; $0.providerOnlyProviderAlive = providerOnly.providerAlive }
        // Provider->image/shared-owner references are not prohibited by the public contract.
        // imageAlive may therefore be 0 OR 1 during this explicit provider-only hold.
        guard providerOnly.providerAlive == 1 else { throw PilotFailure.positive_control_failed }
        heldProvider = nil
    }
    @inline(never)
    private static func retainedOutput(generation: Int, state: ExecutionState) async throws -> M0ImageAsset {
        guard let output = try await execute(.positive, generation: generation, state: state) else {
            throw PilotFailure.unexpected_outcome
        }
        return M0ImageAsset(image: output.image)
    }
    @inline(never)
    private static func ordinaryBody(_ mode: PilotMode, generation: Int, state: ExecutionState) async throws {
        let output = try await execute(mode, generation: generation, state: state)
        if mode == .success {
            guard let output, output.image.width == 96, output.image.height == 224 else { throw PilotFailure.unexpected_outcome }
            withExtendedLifetime(output) {}
        } else if output != nil { throw PilotFailure.unexpected_outcome }
    }
    private static func finalReason(_ value: WeakSnapshot, flags: ExecutionFlags, mode: PilotMode) -> PilotFailure? {
        if let reason = value.reason { return reason }
        guard value.calls == 1, value.imageObserved == 1 else { return .missing_hook }
        guard value.providerObserved == 1 else { return .provider_unavailable }
        guard value.hookImageAlive == 1, value.hookProviderAlive == 1, value.getterStable == 1 else { return .identity_mismatch }
        guard value.imageAlive == 0, value.providerAlive == 0 else { return .object_retained }
        if mode == .positive && (flags.heldImageAlive != 1 || flags.heldProviderAlive != 1 ||
            flags.heldImageIdentity != 1 || flags.heldProviderIdentity != 1 || flags.providerOnlyProviderAlive != 1) {
            return .positive_control_failed
        }
        return nil
    }
    private static func printArm(_ mode: PilotMode, generation: Int, value: WeakSnapshot, flags: ExecutionFlags, reason: PilotFailure?) {
        print("OC_RENDER_LIFETIME_ARM schema=1 arm=\(generation) generation=\(generation) mode=\(mode.rawValue) state=\(reason == nil ? "ESTABLISHED" : "NOT_ESTABLISHED") reason=\(reason?.rawValue ?? "none") hookCalls=\(value.calls) imageObserved=\(value.imageObserved) providerObserved=\(value.providerObserved) hookImageAlive=\(value.hookImageAlive) hookProviderAlive=\(value.hookProviderAlive) providerGetterStable=\(value.getterStable) heldImageAlive=\(flags.heldImageAlive) heldProviderAlive=\(flags.heldProviderAlive) heldImageIdentity=\(flags.heldImageIdentity) heldProviderIdentity=\(flags.heldProviderIdentity) providerOnlyImageAlive=\(flags.providerOnlyImageAlive) providerOnlyProviderAlive=\(flags.providerOnlyProviderAlive) finalImageAlive=\(value.imageAlive) finalProviderAlive=\(value.providerAlive) wrapperStarted=\(flags.wrapperStarted) valueAwaited=\(flags.valueAwaited) wrapperReturned=\(flags.wrapperReturned) resultReturned=\(flags.resultReturned) pngBytes=\(flags.pngBytes) compositionEntered=\(flags.compositionEntered) compositionFinished=\(flags.compositionFinished) traceDropped=\(flags.traceDropped) gateReached=\(flags.gateReached) gateImageAlive=\(flags.gateImageAlive) gateProviderAlive=\(flags.gateProviderAlive) cancellationRequested=\(flags.cancellationRequested) cancellationOutcome=\(flags.cancellationOutcome) elapsedNanoseconds=\(flags.elapsed)")
        fflush(nil)
    }
    static func main() async {
        print("OC_RENDER_LIFETIME_SCOPE schema=1 classification=temporary_default_render_object_pilot maximumProcesses=1 maximumArms=4 sourceCount=2 sourceWidth=64 sourceHeight=64 expectedWidth=96 expectedHeight=224 operationDeadlineNanoseconds=2000000000 workerReturnEvidence=original_wrapper_awaited sourcePayload=fictional board=not_exercised capture=0 gui=0 backingRelease=not_observed resourceAcceptance=0")
        fflush(nil)
        guard CommandLine.arguments.count == 1 else {
            print("OC_RENDER_LIFETIME_RESULT schema=1 state=NOT_ESTABLISHED reason=invalid_arguments completedArms=0 maximumArms=4 backingRelease=not_observed resourceAcceptance=0")
            exit(2)
        }
        var completed = 0
        for (index, mode) in PilotMode.allCases.enumerated() {
            let generation = index + 1, execution = ExecutionState()
            var reason: PilotFailure?
            do {
                try M4RenderObjectObservation.shared.begin(generation)
                if mode == .positive { try await positiveBody(generation: generation, state: execution) }
                else { try await ordinaryBody(mode, generation: generation, state: execution) }
            } catch let known as PilotFailure { reason = known }
            catch { reason = .operation_failed }
            // Outside every helper's result/Task/explicit strong-control scope. This snapshot
            // returns booleans only and drains weak-load/getter temporaries before printing.
            let value = M4RenderObjectObservation.shared.snapshot(generation)
            let flags = execution.snapshot
            reason = reason ?? finalReason(value, flags: flags, mode: mode)
            printArm(mode, generation: generation, value: value, flags: flags, reason: reason)
            M4RenderObjectObservation.shared.close(generation)
            if let reason {
                print("OC_RENDER_LIFETIME_RESULT schema=1 state=NOT_ESTABLISHED reason=\(reason.rawValue) completedArms=\(completed) maximumArms=4 backingRelease=not_observed resourceAcceptance=0")
                fflush(nil); exit(2)
            }
            completed += 1
        }
        print("OC_RENDER_LIFETIME_RESULT schema=1 state=ESTABLISHED reason=none completedArms=4 maximumArms=4 backingRelease=not_observed resourceAcceptance=0")
        fflush(nil)
    }
}
