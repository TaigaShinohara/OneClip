import AppKit
import CoreGraphics
import Darwin
import Foundation

/// Limited synthetic workload. Root checks builds/memory/disks before compiling/running it.
/// Images and encoded data stay in memory. RSS/high-water observations are not allocator limits,
/// leak proofs, process-memory guarantees or results for actual ScreenCaptureKit acquisition.
@main
struct M3ResourceWorkload {
    enum Failure: Error { case invalidSize, allocation, ownership, missingPNG, rejectionMissing, copyTiming }
    struct Size {
        let width: Int
        let height: Int
        var metrics: M0ImageMetrics { .init(width: width, height: height, bytesPerRow: width * 4) }
    }
    struct Memory {
        let resident: Int64
        let highWater: Int64
    }

    /// Tracks only our direct source allocations, not framework caches, PNG storage or RSS.
    final class AllocationTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var live = 0
        private var peak = 0
        private var created = 0
        private var released = 0
        func allocate(_ bytes: Int) {
            lock.lock(); defer { lock.unlock() }
            live += bytes; peak = max(peak, live); created += 1
        }
        func release(_ bytes: Int) {
            lock.lock(); defer { lock.unlock() }
            live -= bytes; released += 1
        }
        var snapshot: (live: Int, peak: Int, created: Int, released: Int) {
            lock.lock(); defer { lock.unlock() }
            return (live, peak, created, released)
        }
    }

    /// The CGDataProvider owns this object through its CF context, including arbitrary-thread release.
    /// There is one final-size allocation; generation never makes a giant Array or CGContext copy.
    final class PixelStorage: @unchecked Sendable {
        let pixels: UnsafeMutablePointer<UInt32>
        let byteCount: Int
        let tracker: AllocationTracker
        init(pixelCount: Int, tracker: AllocationTracker) {
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

    /// Delegates to a real named board. Only clocks and call counts are added to the shared boundary.
    @MainActor
    final class TimedPasteboardDestination: M0ClipboardProbeDestination {
        private let pasteboard: NSPasteboard
        private var prepareStarted: UInt64?
        private(set) var prepareCalls = 0
        private(set) var writeCalls = 0
        private(set) var prepareNanoseconds: UInt64?
        private(set) var writeNanoseconds: UInt64?
        private(set) var prepareThroughWriteNanoseconds: UInt64?

        init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }
        var changeCount: Int { pasteboard.changeCount }

        func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
            prepareCalls += 1
            let started = DispatchTime.now().uptimeNanoseconds
            let value = pasteboard.prepareForNewContents(with: options)
            let finished = DispatchTime.now().uptimeNanoseconds
            prepareStarted = started
            prepareNanoseconds = finished - started
            return value
        }

        func write(_ item: NSPasteboardItem) -> Bool {
            writeCalls += 1
            let started = DispatchTime.now().uptimeNanoseconds
            let accepted = pasteboard.writeObjects([item])
            let finished = DispatchTime.now().uptimeNanoseconds
            writeNanoseconds = finished - started
            if let prepareStarted { prepareThroughWriteNanoseconds = finished - prepareStarted }
            return accepted
        }
    }

    @MainActor
    static func main() {
        let copyTimingOnly = CommandLine.arguments.contains("--copy-timing-only")
        let m4Measurements = CommandLine.arguments.contains("--m4-measurements")
        do {
            if m4Measurements {
                try runM4Measurements()
                return
            }
            if copyTimingOnly {
                try runCopyTiming()
                return
            }
            let modest = [Size(width: 720, height: 480), Size(width: 640, height: 360),
                          Size(width: 800, height: 400), Size(width: 600, height: 300)]
            for count in [1, 2, 4] {
                _ = try run(label: "COUNT_\(count)", sizes: Array(modest.prefix(count)))
            }
            try runLargeReplacement()
            let repeated = Array(repeating: Size(width: 900, height: 600), count: 4)
            var firstReleasedRSS: Int64?
            var lastReleasedRSS: Int64 = -1
            var minimumReleasedRSS: Int64 = .max
            var maximumReleasedRSS: Int64 = -1
            for iteration in 1...8 {
                let memory = try run(label: "REPEAT_\(iteration)", sizes: repeated)
                if memory.resident >= 0 {
                    if firstReleasedRSS == nil { firstReleasedRSS = memory.resident }
                    lastReleasedRSS = memory.resident
                    minimumReleasedRSS = min(minimumReleasedRSS, memory.resident)
                    maximumReleasedRSS = max(maximumReleasedRSS, memory.resident)
                }
            }
            let growth = firstReleasedRSS.map { lastReleasedRSS - $0 } ?? 0
            print("REPEAT_RELEASED_RSS first=\(firstReleasedRSS ?? -1) last=\(lastReleasedRSS) min=\(minimumReleasedRSS == .max ? -1 : minimumReleasedRSS) max=\(maximumReleasedRSS) observedGrowth=\(growth)")
            print("PASS M3-RESOURCE limited synthetic workload; RSS includes framework and allocator retention")
        } catch {
            if m4Measurements { print("FAIL M4-MEASUREMENTS limited synthetic workload") }
            else {
                print(copyTimingOnly ? "FAIL M3-COPY-TIMING completed-PNG private-board write"
                                     : "FAIL M3-RESOURCE limited synthetic workload")
            }
            exit(1)
        }
    }

    enum M4Condition: String {
        case smallTwo = "SMALL_2", largeFour = "LARGE_4", replacement = "REPLACEMENT_4", load = "LOAD_4"

        var sizes: [Size] {
            switch self {
            case .smallTwo: [Size(width: 720, height: 480), Size(width: 640, height: 360)]
            case .largeFour, .replacement:
                [Size(width: 6_000, height: 3_400), Size(width: 4_000, height: 100),
                 Size(width: 4_000, height: 100), Size(width: 4_000, height: 100)]
            case .load: Array(repeating: Size(width: 900, height: 600), count: 4)
            }
        }
    }

    /// Fixed classifications only. No framework error text, image bytes or operation history.
    enum M4Stage: String { case preflight, generation, replacementPreparation, replacementBudget, composition, writer, ownership }

    struct M4Sample {
        var composeNanoseconds: UInt64?
        var writerNanoseconds: UInt64?
        var itemNanoseconds: UInt64?
        var prepareNanoseconds: UInt64?
        var writeNanoseconds: UInt64?
        var prepareThroughWriteNanoseconds: UInt64?
        var writerAccepted = false
        var failure: M4Stage?
        var sourcePeakBytes = 0
        var sourceLiveBytesAfter = -1
        var sourceAllocations = 0
        var sourceReleases = 0
        var batchOwnerReleased = false
        var pngBytes = 0
        var outputWidth = 0
        var outputHeight = 0
        var planPeakBytes = 0
        var retainedOnePNGEstimateBytes = 0
        var encodingTwoPNGPeakEstimateBytes = 0
        var oldPNGRejectionChecked = false
        var beforeRSS: Int64 = -1
        var composedRSS: Int64 = -1
        var writtenRSS: Int64 = -1
        var releasedRSS: Int64 = -1
        var processHighWater: Int64 = -1
    }

    struct M4TimingSummary {
        var values: [UInt64] = []
        var failures = 0

        mutating func observe(_ value: UInt64?) {
            if let value { values.append(value) } else { failures += 1 }
        }

        func report(condition: String, phase: String) {
            let sorted = values.sorted()
            let median: String
            if sorted.isEmpty { median = "unavailable" }
            else if sorted.count.isMultiple(of: 2) {
                let lower = sorted[sorted.count / 2 - 1], upper = sorted[sorted.count / 2]
                median = String(lower + (upper - lower) / 2)
            } else { median = String(sorted[sorted.count / 2]) }
            print("M4_SUMMARY condition=\(condition) phase=\(phase) unit=ns n=\(sorted.count) median=\(median) max=\(sorted.last.map(String.init) ?? "unavailable") failures=\(failures)")
        }
    }

    /// Explicit CLI-only measurements; this file is not part of the application target.
    /// The normal M3 entry points and their original series remain unchanged.
    @MainActor
    static func runM4Measurements() throws {
        print("M4_SCOPE synthetic=1 privateBoardOnly=1 serial=1 timingAttemptsPerCondition=10 warmupCycles=2 measuredLoadCycles=30 loadBeforeBoardTiming=1")
        print("M4_LIMITS captureService=not_exercised selectionAndPaste=not_exercised worker=not_exercised coordinatorCache=not_exercised frameworkCaches=unobserved outputAndPNGPhysicalDeallocation=unobserved imageBudgetIsProcessRSSLimit=0")
        print("M4_INTERVALS composition=compose_entry_through_return writer=existing_PNG_through_shared_writer_return item_prepare_and_write_are_subintervals preparation_and_cleanup_excluded=1")
        var failedCycles = 0
        // Run the no-pasteboard load first so earlier board allocations do not affect its
        // baseline. Warmup is labelled and excluded from the 30-cycle summary/comparison.
        for iteration in 1...2 {
            let sample = m4Sample(condition: .load, write: false)
            if sample.failure != nil { failedCycles += 1 }
            reportM4Sample(sample, condition: M4Condition.load.rawValue, series: "warmup", iteration: iteration)
        }
        var loadTiming = M4TimingSummary()
        var releasedRSS: [Int64] = []
        var observedRSS: [Int64] = []
        for iteration in 1...30 {
            let sample = m4Sample(condition: .load, write: false)
            loadTiming.observe(sample.composeNanoseconds)
            if sample.failure != nil { failedCycles += 1 }
            if sample.releasedRSS >= 0 { releasedRSS.append(sample.releasedRSS) }
            observedRSS += [sample.beforeRSS, sample.composedRSS, sample.releasedRSS].filter { $0 >= 0 }
            reportM4Sample(sample, condition: M4Condition.load.rawValue, series: "load", iteration: iteration)
        }
        loadTiming.report(condition: M4Condition.load.rawValue, phase: "compose_plus_PNG")
        let growth = releasedRSS.first.flatMap { first in releasedRSS.last.map { $0 - first } }
        print("M4_LOAD_RSS unit=bytes samples=\(releasedRSS.count) firstReleased=\(releasedRSS.first.map(String.init) ?? "unavailable") lastReleased=\(releasedRSS.last.map(String.init) ?? "unavailable") minReleased=\(releasedRSS.min().map(String.init) ?? "unavailable") maxReleased=\(releasedRSS.max().map(String.init) ?? "unavailable") observedReleasedGrowth=\(growth.map(String.init) ?? "unavailable") maximumSampledRSS=\(observedRSS.max().map(String.init) ?? "unavailable")")
        for condition in [M4Condition.smallTwo, .largeFour, .replacement] {
            var composition = M4TimingSummary(), writer = M4TimingSummary()
            for iteration in 1...10 {
                let sample = m4Sample(condition: condition, write: true)
                composition.observe(sample.composeNanoseconds)
                writer.observe(sample.writerAccepted ? sample.writerNanoseconds : nil)
                if sample.failure != nil { failedCycles += 1 }
                reportM4Sample(sample, condition: condition.rawValue, series: "timing", iteration: iteration)
            }
            composition.report(condition: condition.rawValue, phase: "compose_plus_PNG")
            writer.report(condition: condition.rawValue, phase: "private_board_writer")
        }
        print("M4_RESULT failedCycles=\(failedCycles) finiteObservationOnly=1 percentileOrSLOClaim=0")
        guard failedCycles == 0 else { throw Failure.ownership }
        print("PASS M4-MEASUREMENTS limited synthetic workload; framework/allocator retention and real application workers remain outside this observation")
    }

    @MainActor
    static func m4Sample(condition: M4Condition, write: Bool) -> M4Sample {
        let tracker = AllocationTracker()
        weak var weakBatch: OwnedBatch?
        var sample = M4Sample()
        var stage = M4Stage.preflight
        sample.beforeRSS = ownMemory().resident
        do {
            try autoreleasepool {
                let sizes = condition.sizes
                _ = try M0ImageComposer.makePlan(metrics: sizes.map(\.metrics))
                let batch = OwnedBatch()
                weakBatch = batch
                stage = .generation
                batch.sources = try sizes.enumerated().map { index, size in
                    try highEntropy(size: size, seed: UInt64(index + 21), tracker: tracker)
                }
                if condition == .replacement {
                    // Preparation is deliberately outside the reported replacement interval.
                    // Preserve M3's old-PNG rejection, then replace the same source index only
                    // after its retained PNG has been released and the candidate is admitted.
                    stage = .replacementPreparation
                    batch.completed = try M0ImageComposer.compose(assets: batch.sources)
                    var oldPNG: Data? = batch.completed?.pngData
                    batch.completed = nil
                    guard let oldPNGBytes = oldPNG?.count else { throw Failure.missingPNG }
                    let candidate = try highEntropy(size: sizes[1], seed: 99, tracker: tracker)
                    stage = .replacementBudget
                    try withExtendedLifetime(oldPNG) {
                        var rejected = false
                        do {
                            _ = try M0ImageComposer.validateChange(existing: batch.sources, replacementIndex: 1,
                                                                  candidate: candidate, retainingExtraBytes: oldPNGBytes)
                        } catch M0ImageError.memoryLimit { rejected = true }
                        guard rejected else { throw Failure.rejectionMissing }
                    }
                    sample.oldPNGRejectionChecked = true
                    oldPNG = nil
                    _ = try M0ImageComposer.validateChange(existing: batch.sources, replacementIndex: 1, candidate: candidate)
                    batch.sources[1] = candidate
                }
                stage = .composition
                let composeStarted = DispatchTime.now().uptimeNanoseconds
                batch.completed = try M0ImageComposer.compose(assets: batch.sources)
                // Stop before memory inspection or reporting; preserve sub-ms resolution.
                sample.composeNanoseconds = DispatchTime.now().uptimeNanoseconds - composeStarted
                guard let result = batch.completed else { throw Failure.missingPNG }
                sample.composedRSS = ownMemory().resident
                sample.pngBytes = result.pngData.count
                sample.outputWidth = result.plan.width; sample.outputHeight = result.plan.height
                sample.planPeakBytes = result.plan.estimatedPeakBytes
                sample.retainedOnePNGEstimateBytes = result.actualImageBytes
                sample.encodingTwoPNGPeakEstimateBytes = try encodingTwoPNGPeak(result)
                guard write else { return }

                stage = .writer
                let board = NSPasteboard.withUniqueName()
                defer { board.releaseGlobally() }
                let destination = TimedPasteboardDestination(pasteboard: board)
                let expectedCount = destination.changeCount
                var itemCalls = 0
                let writerStarted = DispatchTime.now().uptimeNanoseconds
                let outcome = M0ClipboardProbe.writePNG(result.pngData, to: destination,
                                                       expectedChangeCount: expectedCount, itemFactory: { data in
                    itemCalls += 1
                    let itemStarted = DispatchTime.now().uptimeNanoseconds
                    let item = M0ClipboardProbe.makePNGItem(data)
                    sample.itemNanoseconds = DispatchTime.now().uptimeNanoseconds - itemStarted
                    return item
                })
                sample.writerNanoseconds = DispatchTime.now().uptimeNanoseconds - writerStarted
                sample.prepareNanoseconds = destination.prepareNanoseconds
                sample.writeNanoseconds = destination.writeNanoseconds
                sample.prepareThroughWriteNanoseconds = destination.prepareThroughWriteNanoseconds
                guard outcome.writeAccepted, outcome.prepared, itemCalls == 1,
                      destination.prepareCalls == 1, destination.writeCalls == 1,
                      sample.itemNanoseconds != nil, sample.prepareNanoseconds != nil,
                      sample.writeNanoseconds != nil, sample.prepareThroughWriteNanoseconds != nil else {
                    throw Failure.copyTiming
                }
                sample.writerAccepted = true
                sample.writtenRSS = ownMemory().resident
            }
        } catch { sample.failure = stage }

        let allocation = tracker.snapshot
        sample.batchOwnerReleased = weakBatch == nil
        sample.sourceLiveBytesAfter = allocation.live
        sample.sourcePeakBytes = allocation.peak
        sample.sourceAllocations = allocation.created; sample.sourceReleases = allocation.released
        if !sample.batchOwnerReleased || allocation.live != 0 || allocation.created != allocation.released {
            sample.failure = .ownership
        }
        let releasedMemory = ownMemory()
        sample.releasedRSS = releasedMemory.resident
        sample.processHighWater = releasedMemory.highWater
        return sample
    }

    static func reportM4Sample(_ sample: M4Sample, condition: String, series: String, iteration: Int) {
        print("M4_SAMPLE condition=\(condition) series=\(series) iteration=\(iteration) failureClass=\(sample.failure?.rawValue ?? "none") composeNS=\(sample.composeNanoseconds.map(String.init) ?? "unavailable") writerNS=\(sample.writerNanoseconds.map(String.init) ?? "not_measured") writerAccepted=\(sample.writerAccepted ? 1 : 0) itemNS=\(sample.itemNanoseconds.map(String.init) ?? "not_measured") prepareNS=\(sample.prepareNanoseconds.map(String.init) ?? "not_measured") writeNS=\(sample.writeNanoseconds.map(String.init) ?? "not_measured") prepareThroughWriteNS=\(sample.prepareThroughWriteNanoseconds.map(String.init) ?? "not_measured")")
        print("M4_BUFFERS condition=\(condition) series=\(series) iteration=\(iteration) outputWidth=\(sample.outputWidth) outputHeight=\(sample.outputHeight) pngBytes=\(sample.pngBytes) planPeakBytes=\(sample.planPeakBytes) retainedOnePNGEstimateBytes=\(sample.retainedOnePNGEstimateBytes) encodingTwoPNGPeakEstimateBytes=\(sample.encodingTwoPNGPeakEstimateBytes) oldPNGRejectionChecked=\(sample.oldPNGRejectionChecked ? 1 : 0) batchOwnerReleased=\(sample.batchOwnerReleased ? 1 : 0) sourceLiveBytesAfter=\(sample.sourceLiveBytesAfter) sourcePeakBytes=\(sample.sourcePeakBytes) sourceAllocations=\(sample.sourceAllocations) sourceReleases=\(sample.sourceReleases)")
        print("M4_MEMORY condition=\(condition) series=\(series) iteration=\(iteration) unit=bytes rssBefore=\(sample.beforeRSS) rssComposed=\(sample.composedRSS) rssWritten=\(sample.writtenRSS) rssReleased=\(sample.releasedRSS) processHighWater=\(sample.processHighWater)")
    }

    /// Independent opt-in run: do not add pasteboard allocations to the existing RSS/repetition run.
    /// All measured intervals begin after fixture generation and PNG composition have completed.
    @MainActor
    static func runCopyTiming() throws {
        let sizes = [Size(width: 720, height: 480), Size(width: 640, height: 360)]
        let tracker = AllocationTracker()
        weak var weakBatch: OwnedBatch?
        let sample: (writer: UInt64, item: UInt64, prepare: UInt64, write: UInt64, interval: UInt64) = try autoreleasepool {
            _ = try M0ImageComposer.makePlan(metrics: sizes.map(\.metrics))
            let batch = OwnedBatch()
            weakBatch = batch
            batch.sources = try sizes.enumerated().map { index, size in
                try highEntropy(size: size, seed: UInt64(index + 101), tracker: tracker)
            }
            batch.completed = try M0ImageComposer.compose(assets: batch.sources)
            guard let png = batch.completed?.pngData else { throw Failure.missingPNG }
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() } // Cleanup is outside every reported interval.
            let destination = TimedPasteboardDestination(pasteboard: board)
            let expectedCount = destination.changeCount
            var itemCalls = 0
            var itemNanoseconds: UInt64?
            let started = DispatchTime.now().uptimeNanoseconds
            let outcome = M0ClipboardProbe.writePNG(png, to: destination, expectedChangeCount: expectedCount,
                                                    itemFactory: { data in
                itemCalls += 1
                let itemStarted = DispatchTime.now().uptimeNanoseconds
                let item = M0ClipboardProbe.makePNGItem(data)
                itemNanoseconds = DispatchTime.now().uptimeNanoseconds - itemStarted
                return item
            })
            let writerNanoseconds = DispatchTime.now().uptimeNanoseconds - started
            guard outcome.writeAccepted, outcome.prepared, itemCalls == 1,
                  destination.prepareCalls == 1, destination.writeCalls == 1,
                  let itemNanoseconds, let prepare = destination.prepareNanoseconds,
                  let write = destination.writeNanoseconds,
                  let interval = destination.prepareThroughWriteNanoseconds else { throw Failure.copyTiming }
            return (writerNanoseconds, itemNanoseconds, prepare, write, interval)
        }
        let allocation = tracker.snapshot
        guard weakBatch == nil, allocation.live == 0, allocation.created == allocation.released else {
            throw Failure.ownership
        }
        print("PASS M3-COPY-TIMING completedPNGOnly=1 privateBoard=1 itemFactoryCalls=1 prepareCalls=1 singleItemWriteCalls=1 accepted=1")
        print("COPY_TIMING_NS writerIncludingItemAndChecks=\(sample.writer) itemPreparation=\(sample.item) prepareAPI=\(sample.prepare) singleItemWriteAPI=\(sample.write) prepareStartThroughWriteEnd=\(sample.interval)")
        print("SCOPE existing-PNG synchronous API acceptance only; excludes generation, composition, selection, capture, paste and general-board performance")
    }

    static func run(label: String, sizes: [Size]) throws -> Memory {
        let tracker = AllocationTracker()
        weak var weakBatch: OwnedBatch?
        let preGeneration = ownMemory()
        try autoreleasepool {
            // Before any large source allocation, validate the completed collection's dimensions.
            let estimate = try M0ImageComposer.makePlan(metrics: sizes.map(\.metrics))
            let batch = OwnedBatch()
            weakBatch = batch
            let generationStart = ContinuousClock.now
            batch.sources = try sizes.enumerated().map { index, size in
                try highEntropy(size: size, seed: UInt64(index + 1), tracker: tracker)
            }
            let generated = ownMemory()
            print("FIXTURE \(label) count=\(sizes.count) sourceBytes=\(tracker.snapshot.live) scratchImageBytes=0 generationMS=\(milliseconds(since: generationStart)) rssBefore=\(preGeneration.resident) rssAfter=\(generated.resident) ownHighWater=\(generated.highWater)")
            let compositionStart = ContinuousClock.now
            batch.completed = try M0ImageComposer.compose(assets: batch.sources)
            guard let result = batch.completed else { throw Failure.missingPNG }
            let composed = ownMemory()
            let encodingPeak = try encodingTwoPNGPeak(result)
            print("COMPOSE \(label) count=\(sizes.count) sourcePixels=\(result.plan.sourcePixels) outputWidth=\(result.plan.width) outputHeight=\(result.plan.height) pngBytes=\(result.pngData.count) planPeakBytes=\(estimate.estimatedPeakBytes) retainedOnePNGEstimateBytes=\(result.actualImageBytes) encodingTwoPNGPeakEstimateBytes=\(encodingPeak) elapsedMS=\(milliseconds(since: compositionStart)) rss=\(composed.resident) ownHighWater=\(composed.highWater)")
        }
        try checkReleased(label: label, weakBatch: weakBatch, tracker: tracker)
        return ownMemory()
    }

    static func runLargeReplacement() throws {
        // 21.6 MP sources, 6032x3876 (23.38 MP) output, predicted buffers below 384 MiB.
        // One dominant source leaves less room for a previously encoded high-entropy PNG.
        let sizes = [Size(width: 6_000, height: 3_400), Size(width: 4_000, height: 100),
                     Size(width: 4_000, height: 100), Size(width: 4_000, height: 100)]
        let tracker = AllocationTracker()
        weak var weakBatch: OwnedBatch?
        try autoreleasepool {
            let estimate = try M0ImageComposer.makePlan(metrics: sizes.map(\.metrics))
            let preGeneration = ownMemory()
            let batch = OwnedBatch()
            weakBatch = batch
            let generationStart = ContinuousClock.now
            batch.sources = try sizes.enumerated().map { index, size in
                try highEntropy(size: size, seed: UInt64(index + 21), tracker: tracker)
            }
            let generated = ownMemory()
            print("FIXTURE LARGE_4 count=4 sourceBytes=\(tracker.snapshot.live) scratchImageBytes=0 generationMS=\(milliseconds(since: generationStart)) rssBefore=\(preGeneration.resident) rssAfter=\(generated.resident) ownHighWater=\(generated.highWater)")
            let composeStart = ContinuousClock.now
            try autoreleasepool { batch.completed = try M0ImageComposer.compose(assets: batch.sources) }
            guard batch.completed != nil else { throw Failure.missingPNG }
            let memory = ownMemory()
            let encodingPeak = try encodingTwoPNGPeak(batch.completed!)
            print("COMPOSE LARGE_4 count=4 sourcePixels=\(estimate.sourcePixels) outputWidth=\(estimate.width) outputHeight=\(estimate.height) pngBytes=\(batch.completed!.pngData.count) planPeakBytes=\(estimate.estimatedPeakBytes) retainedOnePNGEstimateBytes=\(batch.completed!.actualImageBytes) encodingTwoPNGPeakEstimateBytes=\(encodingPeak) elapsedMS=\(milliseconds(since: composeStart)) rss=\(memory.resident) ownHighWater=\(memory.highWater)")

            var oldPNG: Data? = batch.completed?.pngData
            batch.completed = nil // Release the previous completed CGImage; retain only the old PNG.
            guard let oldPNGBytes = oldPNG?.count else { throw Failure.missingPNG }
            let candidate = try highEntropy(size: sizes[1], seed: 99, tracker: tracker)
            try withExtendedLifetime(oldPNG) {
                var rejected = false
                do {
                    _ = try M0ImageComposer.validateChange(existing: batch.sources, replacementIndex: 1,
                                                          candidate: candidate, retainingExtraBytes: oldPNGBytes)
                } catch M0ImageError.memoryLimit { rejected = true }
                guard rejected else { throw Failure.rejectionMissing }
                print("PASS REPLACEMENT_OLD_PNG_REJECTED count=4 oldPNGBytes=\(oldPNGBytes) sourceLiveBytes=\(tracker.snapshot.live)")
            }
            oldPNG = nil
            let adopted = try M0ImageComposer.validateChange(existing: batch.sources, replacementIndex: 1,
                                                             candidate: candidate)
            batch.sources[1] = candidate
            let replacementStart = ContinuousClock.now
            batch.completed = try M0ImageComposer.compose(assets: batch.sources)
            let replaced = ownMemory()
            let replacementEncodingPeak = try encodingTwoPNGPeak(batch.completed!)
            print("PASS REPLACEMENT_AFTER_RELEASE count=4 planPeakBytes=\(adopted.estimatedPeakBytes) pngBytes=\(batch.completed!.pngData.count) retainedOnePNGEstimateBytes=\(batch.completed!.actualImageBytes) encodingTwoPNGPeakEstimateBytes=\(replacementEncodingPeak) elapsedMS=\(milliseconds(since: replacementStart)) rss=\(replaced.resident) ownHighWater=\(replaced.highWater)")
        }
        try checkReleased(label: "LARGE_4", weakBatch: weakBatch, tracker: tracker)
    }

    /// Uses actual encoded length with both mutable destination and immutable result storage.
    /// The retained result itself has one PNG; neither figure is an observed allocation/RSS limit.
    static func encodingTwoPNGPeak(_ result: M0CompositionResult) throws -> Int {
        let peak = result.actualImageBytes.addingReportingOverflow(result.pngData.count)
        guard !peak.overflow else { throw M0ImageError.arithmeticOverflow }
        return peak.partialValue
    }

    static func checkReleased(label: String, weakBatch: OwnedBatch?, tracker: AllocationTracker) throws {
        let allocation = tracker.snapshot
        guard weakBatch == nil, allocation.live == 0, allocation.created == allocation.released else {
            throw Failure.ownership
        }
        let memory = ownMemory()
        print("RELEASE \(label) weakOwnerReleased=1 sourceLiveBytes=0 sourceAllocations=\(allocation.created) sourceReleases=\(allocation.released) sourcePeakBytes=\(allocation.peak) rss=\(memory.resident) ownHighWater=\(memory.highWater)")
    }

    static func highEntropy(size: Size, seed: UInt64, tracker: AllocationTracker) throws -> M0ImageAsset {
        let (pixels, pixelOverflow) = size.width.multipliedReportingOverflow(by: size.height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard size.width > 0, size.height > 0, !pixelOverflow, !byteOverflow else { throw Failure.invalidSize }
        _ = try M0ImageComposer.makePlan(metrics: [size.metrics])
        let storage = PixelStorage(pixelCount: pixels, tracker: tracker)
        var state = seed &+ 0x9E3779B97F4A7C15
        for index in 0..<pixels {
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            let random = state &* 2_685_821_657_736_338_717
            let rgba = (UInt32(truncatingIfNeeded: random) << 8) | 0xFF
            storage.pixels[index] = rgba.bigEndian // Deterministic opaque, random RGB pixels.
        }
        let retained = Unmanaged.passRetained(storage)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: storage.pixels,
                                            size: bytes, releaseData: { info, _, _ in
            if let info { Unmanaged<PixelStorage>.fromOpaque(info).release() }
        }) else {
            retained.release()
            throw Failure.allocation
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: size.width, height: size.height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: size.width * 4, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                    | CGBitmapInfo.byteOrder32Big.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw Failure.allocation
        }
        return M0ImageAsset(image: image)
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let elapsed = start.duration(to: .now).components
        return elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
    }

    static func ownMemory() -> Memory {
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
        return Memory(resident: status == KERN_SUCCESS ? Int64(info.resident_size) : -1,
                      highWater: highWater)
    }
}
