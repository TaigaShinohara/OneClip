import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A finite, synthetic ownership diagnostic. This is not the product renderer:
/// it never calls makeImage(), captures a screen, opens a window, or writes a PNG.
@main
struct OwnedBackingLifetimeProbe {
    private static let bufferBytes = 16_384
    private static let armLimit: UInt64 = 2_000_000_000
    private static let globalLimit: UInt64 = 8_000_000_000

    private enum Arm: String, CaseIterable {
        case providerHold = "provider_hold", imageHold = "image_hold", pngEncode = "png_encode"
    }
    private enum Failure: String, Error {
        case allocationFailed = "allocation_failed", contextFailed = "context_failed"
        case contextRetained = "context_retained", providerFailed = "provider_failed"
        case imageFailed = "image_failed", encodingFailed = "encoding_failed"
        case heldControlFailed = "held_control_failed", bufferRetained = "buffer_retained"
        case callbackInvalid = "callback_invalid", deadline, internalFailure = "internal_failure"
    }
    private enum LeaseKind { case context, provider }

    private struct Snapshot {
        var created = 0, released = 0, live = 0, bytes = 0
        var contextCallbacks = 0, providerCallbacks = 0
        var invalid = false
    }
    private final class Tracker: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Snapshot()
        func created() {
            lock.lock(); defer { lock.unlock() }
            if value.created != 0 { value.invalid = true; return }
            value.created = 1; value.live = 1; value.bytes = bufferBytes
        }
        func released() {
            lock.lock(); defer { lock.unlock() }
            if value.created != 1 || value.released != 0 || value.live != 1 {
                value.invalid = true; return
            }
            value.released = 1; value.live = 0; value.bytes = 0
        }
        func callback(_ kind: LeaseKind, valid: Bool) {
            lock.lock(); defer { lock.unlock() }
            if !valid { value.invalid = true }
            switch kind {
            case .context:
                if value.contextCallbacks != 0 { value.invalid = true }
                value.contextCallbacks = 1
            case .provider:
                if value.providerCallbacks != 0 { value.invalid = true }
                value.providerCallbacks = 1
            }
        }
        func invalidate() { lock.lock(); value.invalid = true; lock.unlock() }
        var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class Storage: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer
        let tracker: Tracker
        init(tracker: Tracker) throws {
            guard let allocation = calloc(1, bufferBytes) else { throw Failure.allocationFailed }
            pointer = allocation; self.tracker = tracker; tracker.created()
            // Fictional, opaque RGBA pixels. No source image or external input is read.
            let pixels = pointer.assumingMemoryBound(to: UInt8.self)
            for index in 0..<(64 * 64) {
                pixels[index * 4] = UInt8(index % 251)
                pixels[index * 4 + 1] = UInt8((index / 64) * 3)
                pixels[index * 4 + 2] = 77
                pixels[index * 4 + 3] = 255
            }
        }
        deinit { free(pointer); tracker.released() }
    }

    /// A token can relinquish its buffer once, including on constructor failure.
    /// The bounded registry keeps the opaque token itself valid until process exit.
    /// After relinquishing the lease, the token retains scalar state, never a buffer.
    private final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Storage?
        private var consumed = false
        private let kind: LeaseKind
        private let expectedPointer: UInt
        private let tracker: Tracker
        init(storage: Storage, kind: LeaseKind) {
            self.storage = storage; self.kind = kind
            expectedPointer = UInt(bitPattern: storage.pointer); tracker = storage.tracker
        }
        func callback(data: UnsafeRawPointer?, size: Int?) {
            lock.lock()
            guard !consumed else { lock.unlock(); tracker.invalidate(); return }
            consumed = true
            let owned = storage; storage = nil
            lock.unlock()
            let pointerMatches = data.map { UInt(bitPattern: $0) == expectedPointer } ?? false
            let sizeMatches = size.map { $0 == bufferBytes } ?? true
            tracker.callback(kind, valid: pointerMatches && sizeMatches)
            withExtendedLifetime(owned) {}
        }
        func cancelConstruction() {
            lock.lock()
            if !consumed { consumed = true; storage = nil }
            lock.unlock()
        }
    }
    private final class Registry: @unchecked Sendable {
        static let shared = Registry()
        private let lock = NSLock()
        private var tokens: [Lease] = []
        private var invalidInfo = false
        func register(_ token: Lease) throws -> UnsafeMutableRawPointer {
            lock.lock(); defer { lock.unlock() }
            // provider_hold uses one token; each other arm uses two.
            guard tokens.count < 5 else { throw Failure.internalFailure }
            tokens.append(token)
            return Unmanaged.passUnretained(token).toOpaque()
        }
        func invalidateInfo() { lock.lock(); invalidInfo = true; lock.unlock() }
        var invalid: Bool { lock.lock(); defer { lock.unlock() }; return invalidInfo }
    }

    private struct Deadline {
        let globalStart: UInt64
        let armStart: UInt64
        func check() throws {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= armStart, now >= globalStart,
                  now - armStart <= armLimit, now - globalStart <= globalLimit else {
                throw Failure.deadline
            }
        }
    }
    private struct Held {
        var callbacks = -1, live = -1, bytes = -1
        mutating func observe(_ tracker: Tracker) throws {
            let value = tracker.snapshot
            callbacks = value.providerCallbacks; live = value.live; bytes = value.bytes
            guard !value.invalid, !Registry.shared.invalid else { throw Failure.callbackInvalid }
            guard callbacks == 0, live == 1, bytes == bufferBytes, value.created == 1,
                  value.released == 0 else { throw Failure.heldControlFailed }
        }
    }

    private static func draw(storage: Storage, deadline: Deadline) throws {
        try deadline.check()
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw Failure.contextFailed }
        let lease = Lease(storage: storage, kind: .context)
        let info = try Registry.shared.register(lease)
        let created = try autoreleasepool { () throws -> Bool in
            guard let context = CGContext(data: storage.pointer, width: 64, height: 64,
                bitsPerComponent: 8, bytesPerRow: 256, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue,
                releaseCallback: { info, data in
                    guard let info else { Registry.shared.invalidateInfo(); return }
                    Unmanaged<Lease>.fromOpaque(info).takeUnretainedValue()
                        .callback(data: data.map(UnsafeRawPointer.init), size: nil)
                }, releaseInfo: info) else { return false }
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            context.setFillColor(CGColor(srgbRed: 0.8, green: 0.3, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 16, y: 16, width: 24, height: 24))
            try deadline.check()
            return true
        }
        guard created else { lease.cancelConstruction(); throw Failure.contextFailed }
        try deadline.check()
        let value = storage.tracker.snapshot
        guard !value.invalid, !Registry.shared.invalid else { throw Failure.callbackInvalid }
        // No provider is made unless context destruction was actually observed.
        guard value.contextCallbacks == 1 else { throw Failure.contextRetained }
    }

    private static func makeProvider(tracker: Tracker, drawFirst: Bool, deadline: Deadline) throws -> CGDataProvider {
        try deadline.check()
        let storage = try Storage(tracker: tracker)
        if drawFirst { try draw(storage: storage, deadline: deadline) }
        try deadline.check()
        let lease = Lease(storage: storage, kind: .provider)
        let info = try Registry.shared.register(lease)
        guard let provider = CGDataProvider(dataInfo: info, data: storage.pointer, size: bufferBytes,
            releaseData: { info, data, size in
                guard let info else { Registry.shared.invalidateInfo(); return }
                Unmanaged<Lease>.fromOpaque(info).takeUnretainedValue().callback(data: data, size: size)
            }) else { lease.cancelConstruction(); throw Failure.providerFailed }
        try deadline.check()
        return provider
    }

    private static func makeProviderImage(tracker: Tracker, deadline: Deadline) throws -> CGImage {
        let provider = try makeProvider(tracker: tracker, drawFirst: true, deadline: deadline)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 256, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Failure.imageFailed }
        try deadline.check()
        return image
    }

    private static func encode(image: CGImage, deadline: Deadline) throws -> Int {
        try autoreleasepool {
            try deadline.check()
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                UTType.png.identifier as CFString, 1, nil) else { throw Failure.encodingFailed }
            CGImageDestinationAddImage(destination, image, nil)
            try deadline.check()
            let success = CGImageDestinationFinalize(destination)
            try deadline.check()
            guard success, (1...65_536).contains(data.length) else { throw Failure.encodingFailed }
            return data.length
        }
    }

    private static func run(_ arm: Arm, ordinal: Int, globalStart: UInt64) -> (record: [String: Any], observed: Bool) {
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = Deadline(globalStart: globalStart, armStart: start)
        let tracker = Tracker()
        var held = Held(), pngBytes = 0
        var failure: Failure?
        do {
            try deadline.check()
            try autoreleasepool {
                switch arm {
                case .providerHold:
                    let provider = try makeProvider(tracker: tracker, drawFirst: false, deadline: deadline)
                    try withExtendedLifetime(provider) { try held.observe(tracker); try deadline.check() }
                case .imageHold, .pngEncode:
                    let image = try makeProviderImage(tracker: tracker, deadline: deadline)
                    try withExtendedLifetime(image) {
                        if arm == .pngEncode { pngBytes = try encode(image: image, deadline: deadline) }
                        try held.observe(tracker)
                        try deadline.check()
                    }
                }
            }
            try deadline.check()
        } catch let reason as Failure { failure = reason }
        catch { failure = .internalFailure }
        let final = tracker.snapshot
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= start ? now - start : 0
        guard elapsed <= 9_007_199_254_740_991 else { exit(2) }
        if now < start || now < globalStart || elapsed > armLimit || now - globalStart > globalLimit {
            failure = .deadline
        }
        if failure == nil {
            if final.invalid || Registry.shared.invalid { failure = .callbackInvalid }
            else if final.created != 1 || final.released != 1 || final.providerCallbacks != 1 ||
                final.live != 0 || final.bytes != 0 { failure = .bufferRetained }
            else if final.contextCallbacks != (arm == .providerHold ? 0 : 1) { failure = .callbackInvalid }
        }
        let observed = failure == nil
        // An overdue framework call cannot be interrupted here. The external parent
        // enforces the absolute process deadline; an emitted elapsed value is never clamped.
        let record: [String: Any] = [
            "schema": "oneclip-owned-backing-lifetime-v1", "ordinal": ordinal, "arm": arm.rawValue,
            "status": observed ? "OBSERVED" : "NOT_ESTABLISHED", "reason": failure?.rawValue ?? "none",
            "bufferBytes": bufferBytes, "createdBuffers": final.created, "releasedBuffers": final.released,
            "providerCallbacks": final.providerCallbacks, "contextCallbacks": final.contextCallbacks,
            "heldProviderCallbacks": held.callbacks, "heldLiveBuffers": held.live, "heldLiveBytes": held.bytes,
            "finalLiveBuffers": final.live, "finalLiveBytes": final.bytes, "pngBytes": pngBytes,
            "elapsedNanoseconds": elapsed
        ]
        return (record, observed)
    }

    static func main() {
        guard Array(CommandLine.arguments.dropFirst()) == ["--owned-backing-lifetime-v1"] else { exit(2) }
        let globalStart = DispatchTime.now().uptimeNanoseconds
        for (index, arm) in Arm.allCases.enumerated() {
            let result = run(arm, ordinal: index + 1, globalStart: globalStart)
            guard var data = try? JSONSerialization.data(withJSONObject: result.record, options: [.sortedKeys]) else { exit(2) }
            data.append(10)
            FileHandle.standardOutput.write(data)
            if !result.observed { exit(2) }
        }
    }
}
