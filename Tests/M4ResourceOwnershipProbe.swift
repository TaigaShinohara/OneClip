import CoreGraphics
import Darwin
import Foundation
#if ONECLIP_RESOURCE_PRODUCT_STATES
import AppKit
#endif

/// Opt-in, finite, fresh-process diagnostic. Never captures a screen, accesses a pasteboard,
/// writes an image, or contacts a service. The runner supplies acceptance policy separately.
/// Compile with M0ImageCore.swift and CaptureSecurityTrace.swift; product-state coverage also
/// requires the product sources (without OneClipApp's @main) and the explicit compilation flag.
@main
struct M4ResourceOwnershipProbe {
    enum ProbeFailure: Error { case allocation, missingOutput, invalidArguments, invariant }
    enum Mode: String, Sendable {
        case control, sourceOnly = "source-only", renderOnly = "render-before-encode", sync, async
        case cancelBefore = "async-cancel-before-encode", cancelAfter = "async-cancel-after-encode"
        case product = "product-states", productControl = "product-control"
        case productSingle = "product-single", productCollection = "product-collection"
        case singleCancelBefore = "product-single-cancel-before-encode"
        case singleCancelAfter = "product-single-cancel-after-encode"
        case collectionCancelBefore = "product-collection-cancel-before-encode"
        case collectionCancelAfter = "product-collection-cancel-after-encode"
        var isSingleOwner: Bool { [.productSingle, .singleCancelBefore, .singleCancelAfter].contains(self) }
        var isOwnerCancellation: Bool {
            [.singleCancelBefore, .singleCancelAfter, .collectionCancelBefore, .collectionCancelAfter].contains(self)
        }
        var isOwner: Bool { isSingleOwner || [.productCollection, .collectionCancelBefore, .collectionCancelAfter].contains(self) }
        var requiresProduct: Bool { isOwner || self == .product || self == .productControl }
        var recoveryScope: String {
            if isOwnerCancellation { return "coordinator_worker_slot" }
            if self == .cancelBefore || self == .cancelAfter { return "m0_wrapper_only" }
            return "not_applicable"
        }
    }
    enum Workload: String, Sendable {
        case small, standard, large
        var dimensions: [(Int, Int)] {
            switch self {
            case .small: return [(720, 480), (640, 360)]
            case .standard: return Array(repeating: (900, 600), count: 4)
            case .large: return [(6_000, 3_400), (4_000, 100), (4_000, 100), (4_000, 100)]
            }
        }
    }
    struct Configuration: Sendable {
        var mode = Mode.sync
        var workload = Workload.standard
        var cycles = 30
        var extendedIdle = false
        var peakBytes = UInt64.max
        var trial: UInt32 = 1
        var idleTargets: [UInt64] { cycles == 10 ? [] : extendedIdle ? [5, 15, 30, 60, 120] : [5, 15, 30] }

        init(arguments: [String]) throws {
            var index = 0
            while index < arguments.count {
                let key = arguments[index]
                if key == "--extended-idle" { extendedIdle = true; index += 1; continue }
                guard index + 1 < arguments.count else { throw ProbeFailure.invalidArguments }
                let value = arguments[index + 1]
                switch key {
                case "--mode": guard let parsed = Mode(rawValue: value) else { throw ProbeFailure.invalidArguments }; mode = parsed
                case "--workload": guard let parsed = Workload(rawValue: value) else { throw ProbeFailure.invalidArguments }; workload = parsed
                case "--cycles": guard let parsed = Int(value), [10, 30, 60, 90].contains(parsed) else { throw ProbeFailure.invalidArguments }; cycles = parsed
                case "--peak-bytes": guard let parsed = UInt64(value), parsed > 0 else { throw ProbeFailure.invalidArguments }; peakBytes = parsed
                case "--trial": guard let parsed = UInt32(value), parsed > 0 else { throw ProbeFailure.invalidArguments }; trial = parsed
                default: throw ProbeFailure.invalidArguments
                }
                index += 2
            }
            guard !extendedIdle || cycles != 10 else { throw ProbeFailure.invalidArguments }
            #if !ONECLIP_RESOURCE_PRODUCT_STATES
            guard !mode.requiresProduct else { throw ProbeFailure.invalidArguments }
            #endif
        }
    }

    final class SourceTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var live = 0, created = 0, released = 0
        func allocate(_ bytes: Int) { lock.lock(); defer { lock.unlock() }; live += bytes; created += 1 }
        func release(_ bytes: Int) { lock.lock(); defer { lock.unlock() }; live -= bytes; released += 1 }
        var snapshot: (live: Int, created: Int, released: Int) {
            lock.lock(); defer { lock.unlock() }; return (live, created, released)
        }
    }
    final class PixelStorage: @unchecked Sendable {
        let pixels: UnsafeMutablePointer<UInt32>
        let byteCount: Int
        let tracker: SourceTracker
        init(width: Int, height: Int, tracker: SourceTracker) {
            let pixelCount = width * height // Only the bounded predefined dimensions reach here.
            pixels = .allocate(capacity: pixelCount); byteCount = pixelCount * 4
            self.tracker = tracker; tracker.allocate(byteCount)
        }
        deinit { pixels.deallocate(); tracker.release(byteCount) }
    }
    final class OwnedBatch {
        var sources: [M0ImageAsset] = []
        var completed: M0CompositionResult?
    }
    final class WeakOwners {
        weak var batch: OwnedBatch?
        weak var output: CGImage?
        var outputWasObserved = false
    }
    /// Only synthetic cancellation trials wait here. The bounded worker wait ensures the parent
    /// cancellation reaches the real async wrapper before the worker leaves the chosen boundary.
    final class CancellationGate: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var arrived = false, finished = false
        var reached: Bool { lock.lock(); defer { lock.unlock() }; return arrived }
        var returned: Bool { lock.lock(); defer { lock.unlock() }; return finished }
        func finish() { lock.lock(); finished = true; lock.unlock() }
        func pause() throws {
            lock.lock(); arrived = true; lock.unlock()
            guard semaphore.wait(timeout: .now() + 2) == .success else { throw ProbeFailure.invariant }
        }
        func release() { semaphore.signal() }
    }
    struct Observation: Sendable {
        let rss: Int64, processHighWater: Int64, physicalFootprint: Int64
        let internalBytes: Int64, reusableBytes: Int64, compressedBytes: Int64
        let mallocBlocksInUse: UInt32
        let mallocSizeInUse: Int, mallocSizeAllocated: Int
    }
    struct PhaseSample: Sendable { let phase: String; let elapsed: UInt64; let memory: Observation }
    /// A bounded numeric-only buffer crosses the detached worker boundary. It never owns an image.
    final class Measurements: @unchecked Sendable {
        private let lock = NSLock()
        private let started = DispatchTime.now().uptimeNanoseconds
        private var samples: [PhaseSample] = []
        private var didReachEncode = false
        private var peakExceeded = false
        private let peakBytes: UInt64
        init(peakBytes: UInt64) { self.peakBytes = peakBytes; samples.reserveCapacity(256) }
        func take(_ phase: String) {
            let memory = M4ResourceOwnershipProbe.observe()
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            lock.lock(); defer { lock.unlock() }
            if phase == "before_encoding" { didReachEncode = true }
            if memory.rss >= 0 && UInt64(memory.rss) > peakBytes { peakExceeded = true }
            if memory.physicalFootprint >= 0 && UInt64(memory.physicalFootprint) > peakBytes { peakExceeded = true }
            if memory.processHighWater >= 0 && UInt64(memory.processHighWater) > peakBytes { peakExceeded = true }
            if memory.rss < 0 || memory.physicalFootprint < 0 || memory.processHighWater < 0 { peakExceeded = true }
            // Explicitly bounded; the expected composer path uses fewer than 16 samples.
            if samples.count < 256 { samples.append(.init(phase: phase, elapsed: elapsed, memory: memory)) }
            else { peakExceeded = true } // A truncated observation is never a passing trial.
        }
        func checkpoint(_ point: M0CompositionCheckpoint) {
            switch point {
            case .beforeAllocation: take("before_allocation")
            case .beforeSource(let index): take("source_\(index)")
            case .beforeEncoding: take("before_encoding")
            case .afterEncoding: take("after_encoding")
            case .beforeResult: take("before_result")
            }
        }
        var snapshot: (samples: [PhaseSample], reachedEncode: Bool, exceeded: Bool) {
            lock.lock(); defer { lock.unlock() }; return (samples, didReachEncode, peakExceeded)
        }
    }
    @MainActor
    final class Heartbeat {
        private var task: Task<Void, Never>?
        private var last: UInt64 = 0
        private(set) var count = 0
        private(set) var maximumGap: UInt64 = 0
        enum Series: String, CaseIterable { case warmup, measured }
        struct SeriesObservation { var count = 0; var maximumGap: UInt64 = 0 }
        private var activeSeries = Series.warmup
        private var intervalSeries: Set<Series> = [.warmup]
        private var observations: [Series: SeriesObservation] = [:]
        func start() {
            last = DispatchTime.now().uptimeNanoseconds
            task = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                    guard let self, !Task.isCancelled else { return }
                    self.tick()
                }
            }
        }
        func beginMeasuredSeries() {
            // Do not insert an artificial callback or a scheduling delay at this boundary.
            activeSeries = .measured; intervalSeries.insert(.measured)
        }
        private func observeInterval(until now: UInt64, callback: Bool) {
            let gap = now - last
            maximumGap = max(maximumGap, gap)
            // A real callback interval crossing the boundary belongs conservatively to BOTH
            // series. This diagnostic never trims the cold interval out of the aggregate gate.
            for series in intervalSeries {
                var value = observations[series] ?? SeriesObservation()
                value.maximumGap = max(value.maximumGap, gap)
                if callback { value.count += 1 }
                observations[series] = value
            }
            if callback { last = now; count += 1; intervalSeries = [activeSeries] }
        }
        private func tick() { observeInterval(until: DispatchTime.now().uptimeNanoseconds, callback: true) }
        func finish() async {
            // Account for starvation even when a cycle finishes before the next callback.
            observeInterval(until: DispatchTime.now().uptimeNanoseconds, callback: false)
            task?.cancel(); await task?.value; task = nil
        }
        func reportSeries(required: Bool) {
            for series in Series.allCases {
                let value = observations[series] ?? SeriesObservation()
                print("M4_OWNER_HEARTBEAT_SERIES series=\(series.rawValue) required=\(required ? 1 : 0) count=\(value.count) maximumGapNanoseconds=\(value.maximumGap) wholeCrossingIntervalIncluded=1 acceptanceGate=aggregate")
            }
        }
    }

    @MainActor
    static func main() async {
        let config: Configuration
        do { config = try Configuration(arguments: Array(CommandLine.arguments.dropFirst())) }
        catch { print("M4_OWNER_ABORT reason=invalid_arguments"); exit(2) }
        let sourceCount = [.control, .productControl].contains(config.mode) ? 0 : config.mode.isSingleOwner ? 1 : config.workload.dimensions.count
        print("M4_OWNER_SCOPE schema=2 synthetic=1 freshProcess=1 mode=\(config.mode.rawValue) workload=\(config.workload.rawValue) sourceCount=\(sourceCount) board=not_exercised heartbeatSeries=2 warmupCycles=2 measuredCycles=\(config.cycles) idleTargetsSeconds=\(([UInt64(0)] + config.idleTargets).map(String.init).joined(separator: "_")) trial=\(config.trial) recoveryScope=\(config.mode.recoveryScope)")
        print("M4_OWNER_LIMITS sourceProviderRelease=tracked batchRelease=weak_observation outputReferenceRelease=weak_observation PNGBackingRelease=unobserved ImageIOCaches=unobserved physicalErasure=not_claimed imageBudgetBytes=\(M0ImageLimits().maximumImageBytes) processPeakCapBytes=\(config.peakBytes) memoryAPIs=sequential_snapshots allocatorStatistics=all_zones ownProcessOnly=1")
        print("M4_OWNER_IDLE_POLICY explicitRunLoopPump=0 externalInspection=0 pressureRelief=0 forcedCollection=0 backgroundLoad=uncontrolled observationAndReportingMayAffectProcessMemory=1")
        reportMemory(phase: "baseline", series: "baseline", iteration: 0, elapsedNanoseconds: 0, value: observe())
        let heartbeat = Heartbeat()
        let heartbeatRequired = config.mode.requiresProduct || [.async, .cancelBefore, .cancelAfter].contains(config.mode)
        if heartbeatRequired { heartbeat.start() }
        var warmupFailures = 0, measuredFailures = 0, completed = 0
        for iteration in 1...2 {
            if !(await cycle(config, series: "warmup", iteration: iteration)) { warmupFailures += 1; break }
        }
        if warmupFailures == 0 {
            if heartbeatRequired { heartbeat.beginMeasuredSeries() }
            for iteration in 1...config.cycles {
                completed = iteration
                if !(await cycle(config, series: "measured", iteration: iteration)) { measuredFailures += 1; break }
            }
        }
        if heartbeatRequired { await heartbeat.finish() }
        print("M4_OWNER_HEARTBEAT required=\(heartbeatRequired ? 1 : 0) periodNanoseconds=50000000 count=\(heartbeat.count) maximumGapNanoseconds=\(heartbeat.maximumGap) mainActorOnly=1 interactiveUIClaim=0")
        heartbeat.reportSeries(required: heartbeatRequired)
        let idleStarted = DispatchTime.now().uptimeNanoseconds
        reportMemory(phase: "idle", series: "idle", iteration: 0, elapsedNanoseconds: 0, value: observe())
        var idleObservations = 0, idleInterrupted = false
        if warmupFailures == 0 && measuredFailures == 0 {
            for seconds in config.idleTargets {
                let target = idleStarted + seconds * 1_000_000_000
                let now = DispatchTime.now().uptimeNanoseconds
                do { if now < target { try await Task.sleep(nanoseconds: target - now) } }
                catch { idleInterrupted = true; break }
                let elapsed = DispatchTime.now().uptimeNanoseconds - idleStarted
                reportMemory(phase: "idle", series: "idle", iteration: Int(seconds), elapsedNanoseconds: elapsed, value: observe())
                idleObservations += 1
            }
        }
        print("M4_OWNER_RESULT warmupCycles=2 warmupFailures=\(warmupFailures) measuredCycles=\(completed) measuredFailures=\(measuredFailures) idleObservations=\(idleObservations) idleInterrupted=\(idleInterrupted ? 1 : 0) finiteObservationOnly=1 cacheOrLeakConclusion=not_automatic memoryStabilityPass=not_automatic")
        if warmupFailures != 0 || measuredFailures != 0 || idleInterrupted || idleObservations != config.idleTargets.count { exit(1) }
    }

    /// The synchronous and asynchronous paths return only numbers/weak references. The worker
    /// has actually returned before the final ownership and memory observation is made.
    @MainActor
    static func cycle(_ config: Configuration, series: String, iteration: Int) async -> Bool {
        let tracker = SourceTracker(), owners = WeakOwners(), measurements = Measurements(peakBytes: config.peakBytes)
        let started = DispatchTime.now().uptimeNanoseconds
        var succeeded = false, expectedCancellation = false, pngBytes = 0, imageBytes = 0
        var recoveryNanoseconds: Int64 = -1
        var productPassed = true
        do {
            if config.mode.isOwner {
                #if ONECLIP_RESOURCE_PRODUCT_STATES
                let result = try await ownerCycle(config, series: series, iteration: iteration, tracker: tracker,
                                                 measurements: measurements)
                productPassed = result.released
                recoveryNanoseconds = result.recovery
                pngBytes = result.pngBytes
                expectedCancellation = config.mode.isOwnerCancellation
                succeeded = !expectedCancellation && productPassed
                #else
                throw ProbeFailure.invalidArguments
                #endif
            } else if config.mode == .product || config.mode == .productControl {
                #if ONECLIP_RESOURCE_PRODUCT_STATES
                productPassed = try await productCycle(config, series: series, iteration: iteration, tracker: tracker,
                                                      measurements: measurements)
                succeeded = productPassed
                #else
                throw ProbeFailure.invalidArguments
                #endif
            } else if config.mode == .cancelBefore || config.mode == .cancelAfter {
                recoveryNanoseconds = try await cancellationScope(config, tracker: tracker, owners: owners, measurements: measurements)
                expectedCancellation = true
            } else if config.mode == .async {
                let result = try await asyncScope(config, tracker: tracker, owners: owners, measurements: measurements)
                pngBytes = result.png; imageBytes = result.image; succeeded = true
            } else {
                try autoreleasepool {
                    let batch = OwnedBatch(); owners.batch = batch
                    measurements.take("generation_pre")
                    if config.mode != .control { batch.sources = try makeSources(config.workload, tracker: tracker) }
                    measurements.take("sources_ready")
                    if config.mode == .control {
                        // Match the observation/reporting overhead, without allocating an image.
                        measurements.take("before_allocation")
                        for index in config.workload.dimensions.indices { measurements.take("source_\(index)") }
                        for phase in ["before_encoding", "after_encoding", "before_result"] { measurements.take(phase) }
                        succeeded = true
                    } else if config.mode == .sourceOnly {
                        succeeded = true
                    } else {
                        do {
                            batch.completed = try M0ImageComposer.compose(assets: batch.sources, checkCancellation: { point in
                                measurements.checkpoint(point)
                                if config.mode == .renderOnly && point == .beforeEncoding { throw CancellationError() }
                            })
                        } catch is CancellationError where config.mode == .renderOnly {
                            expectedCancellation = true
                        }
                        if let result = batch.completed {
                            owners.output = result.image; owners.outputWasObserved = true
                            pngBytes = result.pngData.count; imageBytes = result.actualImageBytes
                            succeeded = true
                        }
                    }
                }
            }
        } catch { /* Fixed failure classifications only; framework descriptions are never logged. */ }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let allocation = tracker.snapshot
        let phases = measurements.snapshot
        let memory = observe() // Before interpolation/printing perturbs this process.
        let noImages = config.mode == .control || config.mode == .productControl
        let expectedCount = noImages ? 0 : config.mode == .product ? allocation.created : config.mode.isSingleOwner ? 1 : config.workload.dimensions.count
        let cancellationMode = config.mode.isOwnerCancellation || [.renderOnly, .cancelBefore, .cancelAfter].contains(config.mode)
        let expectedSuccess = cancellationMode ? expectedCancellation && !succeeded && phases.reachedEncode : succeeded
        let released = owners.batch == nil && owners.output == nil
        let passed = expectedSuccess && productPassed && released && allocation.live == 0
            && allocation.created == expectedCount && allocation.released == expectedCount
            && imageBytes <= M0ImageLimits().maximumImageBytes && !phases.exceeded
        print("M4_OWNER_OWNERSHIP series=\(series) iteration=\(iteration) compositionSucceeded=\(succeeded ? 1 : 0) expectedCancellation=\(expectedCancellation ? 1 : 0) batchOwnerReleased=\(owners.batch == nil ? 1 : 0) outputReferenceReleased=\(owners.output == nil ? 1 : 0) outputWasObserved=\(owners.outputWasObserved ? 1 : 0) sourceLiveBytes=\(allocation.live) sourceCreated=\(allocation.created) sourceReleased=\(allocation.released) pngBytes=\(pngBytes) actualImageBytes=\(imageBytes) peakCapExceeded=\(phases.exceeded ? 1 : 0) elapsedNanoseconds=\(elapsed) recoveryNanoseconds=\(recoveryNanoseconds) passed=\(passed ? 1 : 0)")
        for sample in phases.samples { reportMemory(phase: sample.phase, series: series, iteration: iteration, elapsedNanoseconds: sample.elapsed, value: sample.memory) }
        reportMemory(phase: "scope_released", series: series, iteration: iteration, elapsedNanoseconds: elapsed, value: memory)
        return passed
    }

    @MainActor
    static func asyncScope(_ config: Configuration, tracker: SourceTracker, owners: WeakOwners,
                           measurements: Measurements) async throws -> (png: Int, image: Int) {
        let batch = OwnedBatch(); owners.batch = batch
        measurements.take("generation_pre")
        batch.sources = try autoreleasepool { try makeSources(config.workload, tracker: tracker) }
        measurements.take("sources_ready")
        batch.completed = try await M0ImageComposer.composeCancellable(assets: batch.sources,
            checkCancellation: { measurements.checkpoint($0) })
        guard let result = batch.completed else { throw ProbeFailure.missingOutput }
        owners.output = result.image; owners.outputWasObserved = true
        return (result.pngData.count, result.actualImageBytes)
    }

    @MainActor
    static func cancellationScope(_ config: Configuration, tracker: SourceTracker, owners: WeakOwners,
                                  measurements: Measurements) async throws -> Int64 {
        let batch = OwnedBatch(); owners.batch = batch
        measurements.take("generation_pre")
        batch.sources = try autoreleasepool { try makeSources(config.workload, tracker: tracker) }
        measurements.take("sources_ready")
        let gate = CancellationGate(), sources = batch.sources
        let target: M0CompositionCheckpoint = config.mode == .cancelBefore ? .beforeEncoding : .afterEncoding
        let operation = Task {
            defer { gate.finish() }
            return try await M0ImageComposer.composeCancellable(assets: sources, checkCancellation: { point in
                measurements.checkpoint(point)
                if point == target { try gate.pause() }
            })
        }
        // Bounded readiness wait; independent from the worker's own two-second gate timeout.
        let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        while !gate.reached && !gate.returned && DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let reached = gate.reached
        let cancelledAt = DispatchTime.now().uptimeNanoseconds
        operation.cancel(); gate.release()
        do {
            _ = try await operation.value
            throw ProbeFailure.invariant // A cancellation must never yield an adopted PNG.
        } catch is CancellationError {
            guard reached else { throw ProbeFailure.invariant }
        }
        return Int64(DispatchTime.now().uptimeNanoseconds - cancelledAt)
    }

    static func makeSources(_ workload: Workload, tracker: SourceTracker) throws -> [M0ImageAsset] {
        let metrics = workload.dimensions.map { M0ImageMetrics(width: $0.0, height: $0.1, bytesPerRow: $0.0 * 4) }
        // Validate the full predefined workload against the unchanged 384 MiB image estimate first.
        _ = try M0ImageComposer.makePlan(metrics: metrics)
        return try workload.dimensions.enumerated().map { index, dimensions in
            try highEntropy(seed: UInt64(index + 21), width: dimensions.0, height: dimensions.1, tracker: tracker)
        }
    }
    static func highEntropy(seed: UInt64, width: Int, height: Int, tracker: SourceTracker) throws -> M0ImageAsset {
        let storage = PixelStorage(width: width, height: height, tracker: tracker)
        var state = seed &+ 0x9E3779B97F4A7C15
        for index in 0..<(width * height) {
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            let random = state &* 2_685_821_657_736_338_717
            storage.pixels[index] = ((UInt32(truncatingIfNeeded: random) << 8) | 0xFF).bigEndian
        }
        let retained = Unmanaged.passRetained(storage)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: storage.pixels,
            size: storage.byteCount, releaseData: { info, _, _ in
                if let info { Unmanaged<PixelStorage>.fromOpaque(info).release() }
            }) else { retained.release(); throw ProbeFailure.allocation }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw ProbeFailure.allocation }
        return M0ImageAsset(image: image)
    }

    static func observe() -> Observation {
        var statistics = malloc_statistics_t(); malloc_zone_statistics(nil, &statistics)
        var usage = rusage()
        let highWater = getrusage(RUSAGE_SELF, &usage) == 0 ? Int64(usage.ru_maxrss) : -1
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        var vmInfo = task_vm_info()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size / MemoryLayout<integer_t>.size)
        let vmCapacity = Int(vmCount)
        let vmStatus = withUnsafeMutablePointer(to: &vmInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: vmCapacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        let footprintEnd = MemoryLayout<task_vm_info>.offset(of: \.phys_footprint).map { $0 + MemoryLayout<mach_vm_size_t>.size }
        let hasVMFields = vmStatus == KERN_SUCCESS && footprintEnd.map { Int(vmCount) * MemoryLayout<integer_t>.size >= $0 } == true
        return Observation(rss: status == KERN_SUCCESS ? (Int64(exactly: info.resident_size) ?? -1) : -1,
            processHighWater: highWater,
            physicalFootprint: hasVMFields ? (Int64(exactly: vmInfo.phys_footprint) ?? -1) : -1,
            internalBytes: hasVMFields ? (Int64(exactly: vmInfo.internal) ?? -1) : -1,
            reusableBytes: hasVMFields ? (Int64(exactly: vmInfo.reusable) ?? -1) : -1,
            compressedBytes: hasVMFields ? (Int64(exactly: vmInfo.compressed) ?? -1) : -1,
            mallocBlocksInUse: statistics.blocks_in_use, mallocSizeInUse: statistics.size_in_use,
            mallocSizeAllocated: statistics.size_allocated)
    }
    static func reportMemory(phase: String, series: String, iteration: Int, elapsedNanoseconds: UInt64, value: Observation) {
        print("M4_OWNER_MEMORY phase=\(phase) series=\(series) iteration=\(iteration) elapsedNanoseconds=\(elapsedNanoseconds) unit=bytes rss=\(value.rss) processHighWater=\(value.processHighWater) physicalFootprint=\(value.physicalFootprint) internalBytes=\(value.internalBytes) reusableBytes=\(value.reusableBytes) compressedBytes=\(value.compressedBytes) mallocBlocksInUse=\(value.mallocBlocksInUse) mallocSizeInUse=\(value.mallocSizeInUse) mallocSizeAllocated=\(value.mallocSizeAllocated)")
    }
}

#if ONECLIP_RESOURCE_PRODUCT_STATES
extension M4ResourceOwnershipProbe {
    @MainActor
    final class ProbeInterface: CollectionCaptureInterface {
        var isOneClipActive = false
        var selected: (@MainActor (CaptureSelection) -> Void)?
        var cancelled: (@MainActor () -> Void)?
        func prepareForSelection() -> Bool { true }
        func showSelection(on display: CaptureDisplaySnapshot,
                           selected: @escaping @MainActor (CaptureSelection) -> Void,
                           cancelled: @escaping @MainActor () -> Void) {
            self.selected = selected; self.cancelled = cancelled
        }
        func hideSelection() -> Bool { selected = nil; cancelled = nil; return true }
        func showCollection(activate: Bool) {}
        func hideCollection() {}
        func showCollectionGuide(started: @escaping @MainActor () -> Void,
                                 cancelled: @escaping @MainActor () -> Void) { started() }
        func showCollectionPermission() {}
        func showPermission() {}
        func hidePermission() {}
        func showProblem(activate: Bool) {}
        func hideProblem() {}
        func showFeedback(_ message: String) {}
        func dismissAll() { selected = nil; cancelled = nil }
        func rememberExternalApplication() {}
        func returnToExternalApplication() {}
    }
    @MainActor
    final class ProbeWriter: CaptureClipboardWriting {
        var changeCount = 1
        var accept = true
        var calls = 0
        var lastPNGByteCount = 0
        func writePNG(_ data: Data, expectedChangeCount: Int) -> M0ClipboardProbe.Outcome {
            calls += 1; lastPNGByteCount = data.count
            guard accept else {
                return .init(code: .itemPreparationFailed, expectedChangeCount: expectedChangeCount,
                             observedChangeCount: changeCount, preparedChangeCount: nil)
            }
            changeCount += 1
            return .init(code: .writeAccepted, expectedChangeCount: expectedChangeCount,
                         observedChangeCount: changeCount, preparedChangeCount: changeCount)
        }
    }
    @MainActor
    final class ProbeCapturer: ScreenshotCapturing {
        let tracker: SourceTracker
        var measurements: Measurements?
        var width = 900, height = 600
        var seed: UInt64 = 21
        init(tracker: SourceTracker) { self.tracker = tracker }
        func capture(_ request: SingleCaptureRequest,
                     isCurrent: @escaping @MainActor () -> Bool) async throws -> M0ImageAsset {
            guard isCurrent() else { throw ScreenshotError.cancelled }
            let asset = try autoreleasepool { try highEntropy(seed: seed, width: width, height: height, tracker: tracker) }
            measurements?.take("sources_ready")
            return asset
        }
    }
    @MainActor
    final class ProductOwners {
        weak var coordinator: CollectionCaptureCoordinator?
        weak var single: SingleCaptureCoordinator?
        weak var native: NativeCaptureInterface?
        weak var view: NSView?
    }
    struct OwnerCycleResult {
        let released: Bool
        let recovery: Int64
        let pngBytes: Int
    }
    @MainActor
    static func ownerCycle(_ config: Configuration, series: String, iteration: Int,
                           tracker: SourceTracker, measurements: Measurements) async throws -> OwnerCycleResult {
        let owners = ProductOwners()
        let result = try await ownerScope(config, series: series, iteration: iteration,
                                          tracker: tracker, measurements: measurements, owners: owners)
        await Task.yield()
        let released = owners.single == nil && owners.coordinator == nil
        print("M4_OWNER_COORDINATOR_RELEASE series=\(series) iteration=\(iteration) singleReleased=\(owners.single == nil ? 1 : 0) collectionReleased=\(owners.coordinator == nil ? 1 : 0) passed=\(released ? 1 : 0)")
        return .init(released: released, recovery: result.recovery, pngBytes: result.pngBytes)
    }
    /// Dedicated normal/cancellation owners, without product UI. Single uses one predefined
    /// source; collection uses the full source set. Neither baseline borrows product-states' T.
    @MainActor
    static func ownerScope(_ config: Configuration, series: String, iteration: Int,
                           tracker: SourceTracker, measurements: Measurements, owners: ProductOwners)
        async throws -> (recovery: Int64, pngBytes: Int) {
        let trace = CaptureSecurityTrace(enabled: true, trial: config.trial), gate = CancellationGate()
        let interface = ProbeInterface(), writer = ProbeWriter(), capturer = ProbeCapturer(tracker: tracker)
        capturer.measurements = measurements
        let preferences = CapturePreferences(defaults: nil, hasSeenCaptureGuide: true, hasSeenPasteHint: true,
                                             hasSeenCollectionGuide: true, hasSeenWelcome: true)
        let slot = CaptureWorkerSlot()
        let display = try CaptureDisplaySnapshot(id: 99, frame: CGRect(x: 0, y: 0, width: 10_000, height: 8_000), scale: 1)
        let afterEncoding = [.singleCancelAfter, .collectionCancelAfter].contains(config.mode)
        let target: M0CompositionCheckpoint = afterEncoding ? .afterEncoding : .beforeEncoding
        let check: @Sendable (M0CompositionCheckpoint) throws -> Void = { point in
            measurements.checkpoint(point)
            if config.mode.isOwnerCancellation && point == target { try gate.pause() }
        }
        let single: SingleCaptureCoordinator?
        let collection: CollectionCaptureCoordinator?
        if config.mode.isSingleOwner {
            single = SingleCaptureCoordinator(capturer: capturer, interface: interface, clipboard: writer,
                workSlot: slot, permissionCheck: { true }, permissionRequest: { false }, protectedDataCheck: { true },
                displayAtPointer: { display }, preferences: preferences, securityTrace: trace,
                encode: { asset in
                    try await M0ImageComposer.composeCancellable(assets: [asset], securityTrace: trace,
                                                               mode: .single, checkCancellation: check)
                })
            collection = nil; owners.single = single
        } else {
            single = nil
            collection = CollectionCaptureCoordinator(capturer: capturer, interface: interface, clipboard: writer,
                workSlot: slot, preferences: preferences, securityTrace: trace,
                permissionCheck: { true }, permissionRequest: { false }, protectedDataCheck: { true },
                displayAtPointer: { display }, compose: { assets, limits in
                    try await M0ImageComposer.composeCancellable(assets: assets, limits: limits, securityTrace: trace,
                                                               mode: .collection, checkCancellation: check)
                })
            owners.coordinator = collection
        }
        defer { gate.release(); single?.stop(); collection?.stop() }
        func isWorking() -> Bool { single?.isWorking ?? collection?.isWorking ?? false }
        func waitForWorker() async {
            if let single { await single.waitForWorker() }
            if let collection { await collection.waitForWorker() }
        }
        let dimensions = config.mode.isSingleOwner ? [config.workload.dimensions[0]] : config.workload.dimensions
        _ = try M0ImageComposer.makePlan(metrics: dimensions.map {
            M0ImageMetrics(width: $0.0, height: $0.1, bytesPerRow: $0.0 * 4)
        })
        measurements.take("generation_pre")
        for (index, size) in dimensions.enumerated() {
            capturer.width = size.0; capturer.height = size.1; capturer.seed = UInt64(index + 21)
            if let single { single.begin() }
            if let collection { collection.beginOrAdd() }
            guard let selected = interface.selected else { throw ProbeFailure.invariant }
            selected(try CaptureSelection(display: display,
                rect: CGRect(x: 20, y: 20, width: CGFloat(size.0), height: CGFloat(size.1))))
            // A single operation includes encoding. A collection first acquires every source,
            // then starts one real copy worker whose cancellation/return owns the shared permit.
            if collection != nil { await waitForWorker() }
        }
        if let collection { collection.copy() }
        var recovery: Int64 = -1
        var busyAtCancellation = false, slotAtCancellation = false
        var afterCancellationAdoptions = 0
        if config.mode.isOwnerCancellation {
            let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
            while !gate.reached && isWorking() && DispatchTime.now().uptimeNanoseconds < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard gate.reached else {
                single?.stop(); collection?.stop(); gate.release(); await waitForWorker()
                throw ProbeFailure.invariant
            }
            busyAtCancellation = isWorking(); slotAtCancellation = slot.isOccupied
            let sequenceBeforeCancellation = trace.snapshot().entries.last?.sequence ?? 0
            let requested = DispatchTime.now().uptimeNanoseconds
            if afterEncoding { single?.stop(); collection?.stop() }
            else { single?.invalidate(message: "synthetic"); collection?.invalidate(message: "synthetic") }
            gate.release()
            await waitForWorker()
            // End T only after the real coordinator's worker, cleanup and permit release finish.
            guard !isWorking(), !slot.isOccupied else { throw ProbeFailure.invariant }
            recovery = Int64(DispatchTime.now().uptimeNanoseconds - requested)
            afterCancellationAdoptions = trace.snapshot().entries.filter {
                $0.sequence > sequenceBeforeCancellation && $0.code == .resultAdopted
            }.count
            guard busyAtCancellation, slotAtCancellation, writer.calls == 0,
                  afterCancellationAdoptions == 0 else { throw ProbeFailure.invariant }
        } else {
            await waitForWorker()
            guard !isWorking(), !slot.isOccupied, writer.calls == 1, writer.lastPNGByteCount > 0 else {
                throw ProbeFailure.invariant
            }
            if let collection {
                guard collection.assets.count == dimensions.count, collection.isCopiedCurrent else { throw ProbeFailure.invariant }
                collection.discard(); await collection.waitForWorker()
            }
        }
        guard single?.hasRetainedImage != true, collection?.hasRetainedImages != true,
              collection?.completed == nil, collection?.pendingReplacement == nil else { throw ProbeFailure.invariant }
        let snapshot = trace.snapshot()
        func count(_ code: CaptureSecurityTrace.Code) -> Int { snapshot.entries.filter { $0.code == code }.count }
        guard snapshot.droppedCount == 0, count(.workerStarted) == count(.workerReturned),
              count(.workerStarted) > 0, count(.slotAcquired) == count(.slotReleased),
              count(.slotAcquired) > 0 else { throw ProbeFailure.invariant }
        measurements.take("coordinator_worker_slot_released")
        let method = config.mode.isOwnerCancellation ? (afterEncoding ? "stop" : "invalidate") : "none"
        print("M4_OWNER_COORDINATOR series=\(series) iteration=\(iteration) owner=\(config.mode.isSingleOwner ? "single" : "collection") cancellationRequested=\(config.mode.isOwnerCancellation ? 1 : 0) cancellationMethod=\(method) busyAtCancellation=\(busyAtCancellation ? 1 : 0) slotAtCancellation=\(slotAtCancellation ? 1 : 0) workerIsWorking=\(isWorking() ? 1 : 0) slotOccupied=\(slot.isOccupied ? 1 : 0) afterCancellationAdoptions=\(afterCancellationAdoptions) writerCalls=\(writer.calls) recoveryNanoseconds=\(recovery) workersStarted=\(count(.workerStarted)) workersReturned=\(count(.workerReturned)) slotsAcquired=\(count(.slotAcquired)) slotsReleased=\(count(.slotReleased)) traceDropped=\(snapshot.droppedCount) passed=1")
        return (recovery, config.mode.isOwnerCancellation ? 0 : writer.lastPNGByteCount)
    }
    @MainActor
    static func diagnosticNative(trace: CaptureSecurityTrace) -> NativeCaptureInterface {
        // No live .shared, OS notifications, console IDs, global hotkeys, preferences or TCC.
        NativeCaptureInterface(environmentSources: .init(workspace: NotificationCenter(), application: NotificationCenter()),
            sessionBackend: .init(registerDispatch: { _ in .init(token: nil, succeeded: false) },
                registerCheck: { .init(token: nil, succeeded: false) }, check: { _ in .failed },
                cancel: { _ in true }, session: { nil }, ownUserID: { 0 }),
            consoleBackend: .init(register: { _ in .init(token: nil, succeeded: false) }, check: { _ in .failed },
                cancel: { _ in true }, consoleUserID: { nil }, ownUserID: { 0 }),
            securityTrace: trace, startMonitoring: false)
    }
    @MainActor
    static func productCycle(_ config: Configuration, series: String, iteration: Int,
                             tracker: SourceTracker, measurements: Measurements) async throws -> Bool {
        let owners = ProductOwners()
        try await productScope(config, series: series, iteration: iteration, tracker: tracker,
                               measurements: measurements, owners: owners)
        // Allow queued actor cleanup, without pumping a run loop or forcing framework collection.
        await Task.yield()
        let passed = owners.coordinator == nil && owners.single == nil && owners.native == nil && owners.view == nil
        print("M4_OWNER_PRODUCT_RELEASE series=\(series) iteration=\(iteration) coordinatorReleased=\(owners.coordinator == nil ? 1 : 0) singleReleased=\(owners.single == nil ? 1 : 0) nativeReleased=\(owners.native == nil ? 1 : 0) viewReleased=\(owners.view == nil ? 1 : 0) actorCleanupYield=1 passed=\(passed ? 1 : 0)")
        return passed
    }
    @MainActor
    static func productScope(_ config: Configuration, series: String, iteration: Int,
                             tracker: SourceTracker, measurements: Measurements, owners: ProductOwners) async throws {
        measurements.take("owner_setup_pre")
        let trace = CaptureSecurityTrace(enabled: true, trial: config.trial)
        let interface = ProbeInterface(), writer = ProbeWriter(), capturer = ProbeCapturer(tracker: tracker)
        let preferences = CapturePreferences(defaults: nil, hasSeenCaptureGuide: true, hasSeenPasteHint: true,
                                             hasSeenCollectionGuide: true, hasSeenWelcome: true)
        let slot = CaptureWorkerSlot()
        let display = try CaptureDisplaySnapshot(id: 99, frame: CGRect(x: 0, y: 0, width: 10_000, height: 8_000), scale: 1)
        let coordinator = CollectionCaptureCoordinator(capturer: capturer, interface: interface, clipboard: writer,
            workSlot: slot, preferences: preferences, securityTrace: trace,
            permissionCheck: { true }, permissionRequest: { false }, protectedDataCheck: { true },
            displayAtPointer: { display }, compose: { assets, limits in
                try await M0ImageComposer.composeCancellable(assets: assets, limits: limits,
                    securityTrace: trace, mode: .collection, checkCancellation: { measurements.checkpoint($0) })
            })
        owners.coordinator = coordinator
        measurements.take("owner_setup_post")
        measurements.take("native_init_pre")
        let native = diagnosticNative(trace: trace); owners.native = native
        measurements.take("native_init_post")
        native.collectionCoordinator = coordinator
        var view: NSView?
        defer { view?.removeFromSuperview(); view = nil; coordinator.stop() }
        func refreshView(_ phase: String) {
            autoreleasepool {
                if view == nil {
                    measurements.take("view_create_pre")
                    view = CollectionPanelController.makeDiagnosticContent(coordinator: coordinator, interface: native)
                    view?.frame = NSRect(x: 0, y: 0, width: 520, height: 640)
                    owners.view = view
                    measurements.take("view_create_post")
                }
                measurements.take("view_layout_pre")
                view?.layoutSubtreeIfNeeded()
                measurements.take("view_layout_post")
                measurements.take("view_display_pre")
                view?.displayIfNeeded()
                measurements.take("view_display_post")
            }
            measurements.take(phase)
        }
        func state(_ phase: String, expectedSources: Int, png: Bool, candidate: Bool, single: Bool = false) throws {
            let passed = coordinator.assets.count == expectedSources && (coordinator.completed != nil) == png
                && (coordinator.pendingReplacement != nil) == candidate && !slot.isOccupied
            let drawCalls = trace.snapshot().entries.filter { $0.code == .viewDraw }.count
            print("M4_OWNER_PRODUCT_STATE series=\(series) iteration=\(iteration) phase=\(phase) assets=\(coordinator.assets.count) completedPNG=\(coordinator.completed == nil ? 0 : 1) candidate=\(coordinator.pendingReplacement == nil ? 0 : 1) workerOccupied=\(slot.isOccupied ? 1 : 0) singleImage=\(single ? 1 : 0) lastWritePNGBytes=\(writer.lastPNGByteCount) sourceLiveBytes=\(tracker.snapshot.live) retainedEstimateBytes=\(coordinator.retainedImageBytes) offscreenActualProductView=1 actualProductDrawCalls=\(drawCalls) productWindowDisplayed=0 passed=\(passed ? 1 : 0)")
            guard passed else { throw ProbeFailure.invariant }
        }
        if config.mode == .productControl {
            refreshView("empty_view")
            try state("empty", expectedSources: 0, png: false, candidate: false)
        } else {
            _ = try M0ImageComposer.makePlan(metrics: config.workload.dimensions.map {
                M0ImageMetrics(width: $0.0, height: $0.1, bytesPerRow: $0.0 * 4)
            })
            for (index, dimensions) in config.workload.dimensions.enumerated() {
                capturer.width = dimensions.0; capturer.height = dimensions.1; capturer.seed = UInt64(index + 21)
                coordinator.beginOrAdd()
                guard let selected = interface.selected else { throw ProbeFailure.invariant }
                selected(try CaptureSelection(display: display, rect: CGRect(x: 20, y: 20, width: CGFloat(dimensions.0), height: CGFloat(dimensions.1))))
                await coordinator.waitForWorker()
            }
            let count = config.workload.dimensions.count
            refreshView("collection_ready")
            try state("ready", expectedSources: count, png: false, candidate: false)
            coordinator.preparePreview(); await coordinator.waitForWorker()
            refreshView("collection_preview")
            try state("preview", expectedSources: count, png: true, candidate: false)
            coordinator.copy(); await coordinator.waitForWorker()
            refreshView("copied_sources_retained")
            try state("copied_kept", expectedSources: count, png: false, candidate: false)
            guard coordinator.isCopiedCurrent, writer.calls == 1 else { throw ProbeFailure.invariant }
            // Hide/Esc is represented by view teardown; it must retain the editing sources.
            view?.removeFromSuperview(); view = nil
            try state("hidden_kept", expectedSources: count, png: false, candidate: false)
            for accept in [false, true] {
                let replaceIndex = config.workload == .large ? count - 1 : 0
                let dimensions = config.workload.dimensions[replaceIndex]
                capturer.width = dimensions.0; capturer.height = dimensions.1; capturer.seed += 100
                coordinator.replace(at: replaceIndex)
                guard let selected = interface.selected else { throw ProbeFailure.invariant }
                selected(try CaptureSelection(display: display, rect: CGRect(x: 20, y: 20, width: CGFloat(dimensions.0), height: CGFloat(dimensions.1))))
                await coordinator.waitForWorker()
                refreshView(accept ? "replacement_accept_pending" : "replacement_keep_pending")
                try state(accept ? "candidate_accept" : "candidate_keep", expectedSources: count, png: false, candidate: true)
                guard let id = coordinator.pendingReplacement?.id else { throw ProbeFailure.invariant }
                if accept { coordinator.acceptReplacement(id: id) } else { coordinator.keepOriginalReplacement(id: id) }
                refreshView(accept ? "replacement_accepted" : "original_kept")
                try state(accept ? "accepted" : "kept_original", expectedSources: count, png: false, candidate: false)
            }
            // A rejected fabricated write retains the single image/PNG while collection sources
            // remain. No NSPasteboard instance is constructed, and no PNG data is retained by writer.
            let singleInterface = ProbeInterface()
            let single = SingleCaptureCoordinator(capturer: capturer, interface: singleInterface, clipboard: writer,
                workSlot: slot, permissionCheck: { true }, permissionRequest: { false }, protectedDataCheck: { true },
                displayAtPointer: { display }, preferences: preferences, securityTrace: trace)
            owners.single = single
            single.prepareExternalCapture = { [weak coordinator] in coordinator?.prepareForSingleCapture() ?? false }
            single.externalRetainedBytes = { [weak coordinator] in coordinator?.retainedImageBytes ?? 0 }
            // Keep this independent single workload small even when the collection is near budget.
            capturer.width = 240; capturer.height = 180; writer.accept = false
            single.begin()
            guard let selected = singleInterface.selected else { throw ProbeFailure.invariant }
            selected(try CaptureSelection(display: display, rect: CGRect(x: 20, y: 20, width: 240, height: 180)))
            await single.waitForWorker()
            guard single.hasRetainedImage, single.phase == .failure, writer.lastPNGByteCount > 0 else { throw ProbeFailure.invariant }
            refreshView("single_failure_collection_retained")
            try state("single_copy_failure", expectedSources: count, png: false, candidate: false, single: true)
            single.discard(); await single.waitForWorker()
            guard !single.hasRetainedImage else { throw ProbeFailure.invariant }
            coordinator.discard(); await coordinator.waitForWorker()
            refreshView("editing_ended")
            try state("ended", expectedSources: 0, png: false, candidate: false)
            coordinator.invalidate(message: "synthetic")
        }
        view?.removeFromSuperview(); view = nil
        measurements.take("view_torn_down")
        native.collectionCoordinator = nil
        coordinator.stop(); await coordinator.waitForWorker()
        let snapshot = trace.snapshot()
        func count(_ code: CaptureSecurityTrace.Code) -> Int { snapshot.entries.filter { $0.code == code }.count }
        let started = count(.workerStarted), returned = count(.workerReturned)
        let acquired = count(.slotAcquired), released = count(.slotReleased)
        print("M4_OWNER_TRACE series=\(series) iteration=\(iteration) entries=\(snapshot.entries.count) dropped=\(snapshot.droppedCount) capacity=\(snapshot.capacity) enabled=\(snapshot.isEnabled ? 1 : 0) workersStarted=\(started) workersReturned=\(returned) slotsAcquired=\(acquired) slotsReleased=\(released)")
        guard snapshot.droppedCount == 0, !slot.isOccupied, started == returned, acquired == released,
              (config.mode == .productControl ? started == 0 : started > 0) else { throw ProbeFailure.invariant }
    }
}
#endif
