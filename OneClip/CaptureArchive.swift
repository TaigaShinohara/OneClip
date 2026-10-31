import Darwin
import Foundation

/// Local output, independent of clipboard acceptance. The private archive and its files are
/// opened through directory descriptors; no image contents, paths or raw OS errors are logged.
struct CaptureArchive: Sendable {
    enum ArchiveError: Error, Equatable { case invalidPNG, invalidSource, unavailable }

    // The image pipeline applies tighter pixel/encoding limits before this boundary. Bound
    // externally modified originals too, without reading an unbounded file into memory.
    static let maximumPNGBytes = 384 * 1_024 * 1_024

    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("OneClip", isDirectory: true)
            .appendingPathComponent("Captures", isDirectory: true)
    }

    /// Internal fault injection only. Normal callers use nil; there is no launch-time switch.
    struct TestingHooks: Sendable {
        enum WriteDirective: Sendable { case normal, interrupt, fail, limit(Int) }
        var beforePublish: (@Sendable (URL) throws -> Void)?
        var afterSourceOpened: (@Sendable () throws -> Void)?
        var writeDirective: (@Sendable (Int) -> WriteDirective)?
    }

    private struct Location: Sendable { let anchor: URL; let components: [String] }
    let directory: URL
    private let location: Location?
    private let hooks: TestingHooks?

    init(directory: URL = CaptureArchive.defaultDirectory, testingHooks: TestingHooks? = nil) {
        // Resolve only the OS-provided trusted anchor (which may contain a system alias such
        // as /var). Never resolve the app-owned suffix: a symlink there must be rejected.
        var found: Location?
        if directory.isFileURL && (directory.host == nil || directory.host == "" || directory.host == "localhost") {
            let target = directory.standardizedFileURL.pathComponents
            for base in [URL.applicationSupportDirectory, FileManager.default.temporaryDirectory] {
                let canonical = base.standardizedFileURL.resolvingSymlinksInPath()
                for prefix in [base.standardizedFileURL.pathComponents, canonical.pathComponents] {
                    if target.count > prefix.count && Array(target.prefix(prefix.count)) == prefix {
                        let suffix = Array(target.dropFirst(prefix.count))
                        if suffix.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) {
                            found = Location(anchor: canonical, components: suffix)
                        }
                        break
                    }
                }
                if found != nil { break }
            }
        }
        location = found
        if let found {
            self.directory = found.components.reduce(found.anchor) { $0.appendingPathComponent($1, isDirectory: true) }
        } else { self.directory = directory }
        hooks = testingHooks
    }

    func createDirectory() throws {
        let fd = try openDirectory(create: true)
        defer { Darwin.close(fd) }
        try requireCurrentDirectory(fd)
    }

    func save(_ png: Data) throws -> URL {
        guard png.count <= Self.maximumPNGBytes,
              png.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else { throw ArchiveError.invalidPNG }
        let directoryFD = try openDirectory(create: true)
        defer { Darwin.close(directoryFD) }
        return try publish(in: directoryFD, prefix: "OneClip-\(Self.timestamp())") { fd in
            try png.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { try writeAll(fd, bytes: base, count: bytes.count) }
            }
            guard try information(fd).st_size == png.count else { throw ArchiveError.unavailable }
        }
    }

    /// Preserve the capture as an original. Only a bounded, owned, regular source inside the
    /// current archive may be copied. Both source and output stay bound to opened descriptors.
    func makeEditingCopy(of source: URL) throws -> URL {
        try withSource(source) { directoryFD, sourceFD, initial, name in
            return try publish(in: directoryFD, prefix: source.deletingPathExtension().lastPathComponent + "-edited",
                validateBeforePublish: { try requireSource(initial, name: name, sourceFD: sourceFD, directoryFD: directoryFD) }) { output in
                var buffer = [UInt8](repeating: 0, count: 65_536)
                var remaining = Int(initial.st_size)
                while remaining > 0 {
                    let amount = min(buffer.count, remaining)
                    let readCount = buffer.withUnsafeMutableBytes { Darwin.read(sourceFD, $0.baseAddress, amount) }
                    if readCount < 0 && errno == EINTR { continue }
                    guard readCount > 0 else { throw ArchiveError.unavailable }
                    try buffer.withUnsafeBytes { try writeAll(output, bytes: $0.baseAddress!, count: readCount) }
                    remaining -= readCount
                }
                guard try information(output).st_size == initial.st_size else { throw ArchiveError.unavailable }
            }
        }
    }

    /// Cache reuse never trusts a pathname or capture ID alone. Only compare an exact-size
    /// source, in bounded chunks, and verify its descriptor/name identity again afterwards.
    func matchesSavedCapture(_ source: URL, png: Data) throws -> Bool {
        guard png.count <= Self.maximumPNGBytes,
              png.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else { throw ArchiveError.invalidPNG }
        return try withSource(source) { _, sourceFD, info, _ in
            guard info.st_size == png.count else { return false }
            return try png.withUnsafeBytes { expected in
                var buffer = [UInt8](repeating: 0, count: 65_536)
                var offset = 0
                while offset < png.count {
                    let amount = min(buffer.count, png.count - offset)
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(sourceFD, $0.baseAddress, amount) }
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw ArchiveError.unavailable }
                    let matches = buffer.withUnsafeBytes { memcmp($0.baseAddress!, expected.baseAddress!.advanced(by: offset), count) == 0 }
                    if !matches { return false }
                    offset += count
                }
                return true
            }
        }
    }

    func validateSavedFile(_ source: URL) throws {
        try withSource(source) { _, _, _, _ in () }
    }

    /// Snapshot a private PNG through the already validated descriptor. File size is checked
    /// before allocation; a path/link/content replacement is rejected by withSource afterwards.
    func readSavedPNG(_ source: URL, maximumBytes: Int = maximumPNGBytes,
                      checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> Data {
        guard maximumBytes > 0 else { throw ArchiveError.invalidSource }
        try checkCancellation()
        return try withSource(source) { _, fd, info, _ in
            guard info.st_size <= maximumBytes else { throw ArchiveError.invalidSource }
            try checkCancellation()
            var data = Data(count: Int(info.st_size))
            try data.withUnsafeMutableBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try checkCancellation()
                    let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw ArchiveError.unavailable }
                    offset += count
                }
            }
            try checkCancellation()
            return data
        }
    }

    private func withSource<T>(_ source: URL, body: (Int32, Int32, stat, String) throws -> T) throws -> T {
        let source = source.standardizedFileURL
        guard source.isFileURL, source.pathExtension.lowercased() == "png",
              source.deletingLastPathComponent() == directory else { throw ArchiveError.invalidSource }
        let directoryFD = try openDirectory(create: true)
        defer { Darwin.close(directoryFD) }
        let name = source.lastPathComponent
        let sourceFD = Darwin.openat(directoryFD, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw ArchiveError.invalidSource }
        defer { Darwin.close(sourceFD) }
        let initial = try information(sourceFD)
        guard initial.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), initial.st_uid == geteuid(),
              initial.st_nlink == 1, initial.st_mode & 0o022 == 0,
              initial.st_size >= 8, initial.st_size <= Self.maximumPNGBytes else { throw ArchiveError.invalidSource }
        try requireEmptyACL(sourceFD)
        var prefix = [UInt8](repeating: 0, count: 8)
        var readBytes = 0
        while readBytes < prefix.count {
            let amount = prefix.count - readBytes
            let count = prefix.withUnsafeMutableBytes { Darwin.read(sourceFD, $0.baseAddress!.advanced(by: readBytes), amount) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ArchiveError.invalidSource }
            readBytes += count
        }
        guard prefix == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], Darwin.lseek(sourceFD, 0, SEEK_SET) == 0 else { throw ArchiveError.invalidSource }
        try requireCurrentDirectory(directoryFD)
        try hooks?.afterSourceOpened?()
        let value = try body(directoryFD, sourceFD, initial, name)
        try requireSource(initial, name: name, sourceFD: sourceFD, directoryFD: directoryFD)
        try requireCurrentDirectory(directoryFD)
        return value
    }

    private func requireSource(_ initial: stat, name: String, sourceFD: Int32, directoryFD: Int32) throws {
        var named = stat()
        guard Darwin.fstatat(directoryFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              sameObject(initial, named), sameContents(initial, try information(sourceFD)) else { throw ArchiveError.invalidSource }
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        guard let location else { throw ArchiveError.invalidSource }
        var current = Darwin.open(location.anchor.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw ArchiveError.unavailable }
        do {
            let anchor = try information(current)
            guard anchor.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), anchor.st_uid == geteuid(),
                  anchor.st_mode & 0o022 == 0 else { throw ArchiveError.invalidSource }
            try requireEmptyACL(current)
            for component in location.components {
                if create && Darwin.mkdirat(current, component, 0o700) != 0 && errno != EEXIST { throw ArchiveError.unavailable }
                let next = Darwin.openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ArchiveError.invalidSource }
                do {
                    let info = try information(next)
                    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == geteuid() else { throw ArchiveError.invalidSource }
                    // Never erase an existing ACL, including one inherited at creation.
                    try requireEmptyACL(next)
                    if info.st_mode & 0o7777 != 0o700 {
                        guard create, Darwin.fchmod(next, 0o700) == 0,
                              try information(next).st_mode & 0o7777 == 0o700 else { throw ArchiveError.invalidSource }
                    }
                } catch { Darwin.close(next); throw error }
                Darwin.close(current)
                current = next
            }
            return current
        } catch { Darwin.close(current); throw error }
    }

    private func requireCurrentDirectory(_ fd: Int32) throws {
        let current = try openDirectory(create: false)
        defer { Darwin.close(current) }
        guard sameObject(try information(fd), try information(current)) else { throw ArchiveError.invalidSource }
    }

    private func publish(in directoryFD: Int32, prefix: String, validateBeforePublish: (() throws -> Void)? = nil,
                         write: (Int32) throws -> Void) throws -> URL {
        let name = prefix + "-" + UUID().uuidString + ".png"
        let staging = ".oneclip-" + UUID().uuidString + ".tmp"
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        let fd = Darwin.openat(directoryFD, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ArchiveError.unavailable }
        defer {
            // Never recursively remove a replacement directory or unlink a different inode.
            var named = stat()
            if let owned = try? information(fd), Darwin.fstatat(directoryFD, staging, &named, AT_SYMLINK_NOFOLLOW) == 0,
               sameObject(owned, named) { _ = Darwin.unlinkat(directoryFD, staging, 0) }
            Darwin.close(fd)
        }
        let info = try information(fd)
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(), info.st_nlink == 1,
              Darwin.fchmod(fd, 0o600) == 0 else { throw ArchiveError.invalidSource }
        try requireEmptyACL(fd)
        try write(fd)
        while Darwin.fsync(fd) != 0 { if errno != EINTR { throw ArchiveError.unavailable } }
        let written = try information(fd)
        try hooks?.beforePublish?(destination)
        try requireCurrentDirectory(directoryFD)
        try validateBeforePublish?()
        var staged = stat()
        guard Darwin.fstatat(directoryFD, staging, &staged, AT_SYMLINK_NOFOLLOW) == 0,
              sameObject(info, staged), sameContents(written, staged) else { throw ArchiveError.invalidSource }
        // Darwin's exclusive rename is one filesystem operation. There is no exists→rename gap,
        // no overwriting fallback, and both names are relative to the same pinned directory.
        guard Darwin.renameatx_np(directoryFD, staging, directoryFD, name, UInt32(RENAME_EXCL)) == 0 else { throw ArchiveError.unavailable }
        try requireCurrentDirectory(directoryFD)
        return destination
    }

    private func writeAll(_ fd: Int32, bytes: UnsafeRawPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let remaining = count - offset
            let result: Int
            switch hooks?.writeDirective?(remaining) ?? .normal {
            case .normal: result = Darwin.write(fd, bytes.advanced(by: offset), remaining)
            case .interrupt: errno = EINTR; result = -1
            case .fail: errno = EIO; result = -1
            case .limit(let limit):
                guard limit > 0 else { throw ArchiveError.unavailable }
                result = Darwin.write(fd, bytes.advanced(by: offset), min(limit, remaining))
            }
            if result < 0 && errno == EINTR { continue }
            guard result > 0 && result <= remaining else { throw ArchiveError.unavailable }
            offset += result
        }
    }

    private func information(_ fd: Int32) throws -> stat {
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else { throw ArchiveError.unavailable }
        return info
    }

    private func requireEmptyACL(_ fd: Int32) throws {
        // Distinguish an absent ACL from an ACL-query failure using the descriptor's
        // filesec property bit. acl_get_fd_np alone may return nil for either case.
        guard let security = filesec_init() else { throw ArchiveError.unavailable }
        defer { filesec_free(security) }
        var info = stat()
        var present: Int32 = 0
        guard fstatx_np(fd, &info, security) == 0,
              filesec_query_property(security, FILESEC_ACL, &present) == 0 else { throw ArchiveError.unavailable }
        if present == 0 { return }
        var value: acl_t?
        guard filesec_get_property(security, FILESEC_ACL, &value) == 0, let acl = value else { throw ArchiveError.unavailable }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw ArchiveError.unavailable }
        var entry: acl_entry_t?
        // Darwin returns 0 for an entry and -1/EINVAL for an exhausted empty ACL
        // (unlike platforms which use 1/0). A retrieved entry is always rejected.
        errno = 0
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        guard result == -1 && errno == EINVAL else { throw ArchiveError.invalidSource }
    }

    private func sameObject(_ lhs: stat, _ rhs: stat) -> Bool { lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino }
    private func sameContents(_ lhs: stat, _ rhs: stat) -> Bool {
        sameObject(lhs, rhs) && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }
}
