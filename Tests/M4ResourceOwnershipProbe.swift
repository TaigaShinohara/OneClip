import CoreGraphics
import Darwin
import Foundation

/// Opt-in fresh-process ownership diagnostic, not an application target or speed benchmark.
/// Compile with M0ImageCore.swift only. Images stay in memory; no screen, board, image file
/// or network is accessed. Reports contain fixed classifications and numeric observations.
@main
struct M4ResourceOwnershipProbe {
    enum ProbeFailure: Error { case allocation, missingOutput }

    final class SourceTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var live = 0
        private var created = 0
        private var released = 0

        func allocate(_ bytes: Int) {
            lock.lock(); defer { lock.unlock() }
            live += bytes; created += 1
        }

        func release(_ bytes: Int) {
            lock.lock(); defer { lock.unlock() }
            live -= bytes; released += 1
        }

        var snapshot: (live: Int, created: Int, released: Int) {
            lock.lock(); defer { lock.unlock() }
            return (live, created, released)
        }
    }

    final class PixelStorage: @unchecked Sendable {
        let pixels: UnsafeMutablePointer<UInt32>
        let byteCount: Int
        let tracker: SourceTracker

        init(tracker: SourceTracker) {
            let pixelCount = 900 * 600
            pixels = .allocate(capacity: pixelCount)
            byteCount = pixelCount * MemoryLayout<UInt32>.size
            self.tracker = tracker
            tracker.allocate(byteCount)
        }

        deinit { pixels.deallocate(); tracker.release(byteCount) }
    }

    final class OwnedBatch {
        var sources: [M0ImageAsset] = []
        var completed: M0CompositionResult?
    }

    struct Observation {
        let rss: Int64
        let processHighWater: Int64
        let physicalFootprint: Int64
        let internalBytes: Int64
        let reusableBytes: Int64
        let compressedBytes: Int64
        let mallocBlocksInUse: UInt32
        let mallocSizeInUse: Int
        let mallocSizeAllocated: Int
    }

    struct RangeSummary {
        private var count = 0
        private var first: Int64 = -1
        private var last: Int64 = -1
        private var minimum = Int64.max
        private var maximum: Int64 = -1

        mutating func observe(_ value: Int64) {
            guard value >= 0 else { return }
            if count == 0 { first = value }
            count += 1; last = value
            minimum = min(minimum, value); maximum = max(maximum, value)
        }

        func report(metric: String) {
            print("M4_OWNER_RANGE series=measured metric=\(metric) unit=bytes n=\(count) first=\(first) last=\(last) min=\(count == 0 ? -1 : minimum) max=\(maximum) observedGrowth=\(count == 0 ? -1 : last - first)")
        }
    }

    @MainActor
    static func main() async {
        print("M4_OWNER_SCOPE synthetic=1 freshProcess=1 sourceCount=4 sourceWidth=900 sourceHeight=600 seeds=21_22_23_24 board=not_exercised warmupCycles=2 measuredCycles=30 idleTargetsSeconds=5_15_30")
        print("M4_OWNER_LIMITS sourceProviderRelease=tracked batchRelease=weak_observation outputReferenceRelease=weak_observation PNGBackingRelease=unobserved ImageIOCaches=unobserved productWorkerCache=not_exercised memoryAPIs=sequential_snapshots allocatorStatistics=all_zones ownProcessOnly=1 speedBenchmark=0")
        print("M4_OWNER_IDLE_POLICY explicitRunLoopPump=0 externalInspection=0 pressureRelief=0 forcedCollection=0 backgroundLoad=uncontrolled observationAndReportingMayAffectProcessMemory=1")
        reportMemory(phase: "baseline", series: "baseline", iteration: 0, elapsedNanoseconds: 0, value: observe())

        var warmupFailures = 0, measuredFailures = 0
        var rss = RangeSummary(), footprint = RangeSummary(), mallocInUse = RangeSummary()
        for iteration in 1...2 {
            if !cycle(series: "warmup", iteration: iteration).passed { warmupFailures += 1 }
        }
        for iteration in 1...30 {
            let sample = cycle(series: "measured", iteration: iteration)
            if !sample.passed { measuredFailures += 1 }
            rss.observe(sample.memory.rss)
            footprint.observe(sample.memory.physicalFootprint)
            mallocInUse.observe(Int64(sample.memory.mallocSizeInUse))
        }
        rss.report(metric: "rssReleased")
        footprint.report(metric: "physicalFootprintReleased")
        mallocInUse.report(metric: "mallocSizeInUseReleased")

        // All image scopes have ended. Sleeping suspends this task without pumping a run loop
        // explicitly or asking the allocator/kernel to reclaim pages. Small observations and
        // stdout reporting still perturb this process; elapsed time is reported, not assumed.
        let idleStarted = DispatchTime.now().uptimeNanoseconds
        reportMemory(phase: "idle", series: "idle", iteration: 0, elapsedNanoseconds: 0, value: observe())
        var idleObservations = 0
        var idleInterrupted = false
        for seconds in [UInt64(5), 15, 30] {
            let target = idleStarted + seconds * 1_000_000_000
            let now = DispatchTime.now().uptimeNanoseconds
            do {
                if now < target { try await Task.sleep(nanoseconds: target - now) }
            } catch {
                idleInterrupted = true
                break
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - idleStarted
            let memory = observe()
            reportMemory(phase: "idle", series: "idle", iteration: Int(seconds), elapsedNanoseconds: elapsed, value: memory)
            idleObservations += 1
        }
        print("M4_OWNER_RESULT warmupCycles=2 warmupFailures=\(warmupFailures) measuredCycles=30 measuredFailures=\(measuredFailures) idleObservations=\(idleObservations) idleInterrupted=\(idleInterrupted ? 1 : 0) finiteObservationOnly=1 cacheOrLeakConclusion=not_automatic memoryStabilityPass=not_automatic")
        if warmupFailures != 0 || measuredFailures != 0 || idleInterrupted || idleObservations != 3 { exit(1) }
    }

    /// Ownership and memory are observed only after both the autorelease pool and Swift value
    /// scope end. Returned values contain no image or PNG and no per-cycle history is retained.
    @MainActor
    static func cycle(series: String, iteration: Int) -> (passed: Bool, memory: Observation) {
        let tracker = SourceTracker()
        weak var weakBatch: OwnedBatch?
        weak var weakOutput: AnyObject?
        var width = 0, height = 0, pngBytes = 0
        var compositionSucceeded = false
        do {
            try autoreleasepool {
                let batch = OwnedBatch()
                weakBatch = batch
                batch.sources = try (21...24).map { try highEntropy(seed: UInt64($0), tracker: tracker) }
                batch.completed = try M0ImageComposer.compose(assets: batch.sources)
                guard let result = batch.completed else { throw ProbeFailure.missingOutput }
                weakOutput = result.image
                width = result.image.width; height = result.image.height; pngBytes = result.pngData.count
                compositionSucceeded = true
            }
        } catch {
            // Error descriptions and framework strings are deliberately not emitted.
        }
        let allocation = tracker.snapshot
        let batchReleased = weakBatch == nil
        let outputReleased = weakOutput == nil
        let passed = compositionSucceeded && batchReleased && outputReleased
            && allocation.live == 0 && allocation.created == 4 && allocation.released == 4
        // Sample before string interpolation/reporting allocates temporary storage.
        let memory = observe()
        print("M4_OWNER_OWNERSHIP series=\(series) iteration=\(iteration) compositionSucceeded=\(compositionSucceeded ? 1 : 0) batchOwnerReleased=\(batchReleased ? 1 : 0) outputReferenceReleased=\(outputReleased ? 1 : 0) sourceLiveBytes=\(allocation.live) sourceCreated=\(allocation.created) sourceReleased=\(allocation.released) outputWidth=\(width) outputHeight=\(height) pngBytes=\(pngBytes) passed=\(passed ? 1 : 0)")
        reportMemory(phase: "scope_released", series: series, iteration: iteration, elapsedNanoseconds: 0, value: memory)
        return (passed, memory)
    }

    /// Same deterministic opaque high-entropy RGBA generator as the retained six-cycle probe.
    static func highEntropy(seed: UInt64, tracker: SourceTracker) throws -> M0ImageAsset {
        let width = 900, height = 600, pixelCount = width * height
        let storage = PixelStorage(tracker: tracker)
        var state = seed &+ 0x9E3779B97F4A7C15
        for index in 0..<pixelCount {
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            let random = state &* 2_685_821_657_736_338_717
            let rgba = (UInt32(truncatingIfNeeded: random) << 8) | 0xFF
            storage.pixels[index] = rgba.bigEndian
        }
        let retained = Unmanaged.passRetained(storage)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: storage.pixels,
                                            size: storage.byteCount, releaseData: { info, _, _ in
            if let info { Unmanaged<PixelStorage>.fromOpaque(info).release() }
        }) else {
            retained.release()
            throw ProbeFailure.allocation
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                    | CGBitmapInfo.byteOrder32Big.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ProbeFailure.allocation
        }
        return M0ImageAsset(image: image)
    }

    static func observe() -> Observation {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
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
        // Older returned prefixes may not contain physical footprint or all requested fields.
        let footprintEnd = MemoryLayout<task_vm_info>.offset(of: \.phys_footprint)
            .map { $0 + MemoryLayout<mach_vm_size_t>.size }
        let hasVMFields = vmStatus == KERN_SUCCESS && footprintEnd.map {
            Int(vmCount) * MemoryLayout<integer_t>.size >= $0
        } == true
        return Observation(rss: status == KERN_SUCCESS ? (Int64(exactly: info.resident_size) ?? -1) : -1,
                           processHighWater: highWater,
                           physicalFootprint: hasVMFields ? (Int64(exactly: vmInfo.phys_footprint) ?? -1) : -1,
                           internalBytes: hasVMFields ? (Int64(exactly: vmInfo.internal) ?? -1) : -1,
                           reusableBytes: hasVMFields ? (Int64(exactly: vmInfo.reusable) ?? -1) : -1,
                           compressedBytes: hasVMFields ? (Int64(exactly: vmInfo.compressed) ?? -1) : -1,
                           mallocBlocksInUse: statistics.blocks_in_use,
                           mallocSizeInUse: statistics.size_in_use,
                           mallocSizeAllocated: statistics.size_allocated)
    }

    static func reportMemory(phase: String, series: String, iteration: Int, elapsedNanoseconds: UInt64, value: Observation) {
        print("M4_OWNER_MEMORY phase=\(phase) series=\(series) iteration=\(iteration) elapsedNanoseconds=\(elapsedNanoseconds) unit=bytes rss=\(value.rss) processHighWater=\(value.processHighWater) physicalFootprint=\(value.physicalFootprint) internalBytes=\(value.internalBytes) reusableBytes=\(value.reusableBytes) compressedBytes=\(value.compressedBytes) mallocBlocksInUse=\(value.mallocBlocksInUse) mallocSizeInUse=\(value.mallocSizeInUse) mallocSizeAllocated=\(value.mallocSizeAllocated)")
    }
}
