import Foundation

/// Read/write access to OneClip's saved-capture archive, following the same
/// on-disk contract the app uses (`CaptureArchive`):
/// - Location: `<root>/Application Support/OneClip/Captures/`
/// - Originals: `OneClip-<yyyy-MM-dd-HHmmss>-<UUID>.png`
/// - Edited copies: `<original base>-edited-<UUID>.png`
/// - The trailing UUID is the stable item ID. It is never reused.
/// The CLI never prints image bytes; items are metadata only.
public struct ArchiveItem: Sendable, Equatable {
    public let id: String
    public let kind: String // "original" | "edited"
    public let fileName: String
    public let bytes: Int
    public let filenameTimestamp: String
    public let createdAt: Date?
    public let modifiedAt: Date?

    public func jsonObject() -> AgentJSONValue {
        var pairs: [(String, AgentJSONValue)] = [
            ("id", .string(id)),
            ("kind", .string(kind)),
            ("file_name", .string(fileName)),
            ("bytes", .int(bytes)),
            ("filename_timestamp", .string(filenameTimestamp)),
        ]
        if let createdAt {
            pairs.append(("created_at", .string(AgentISO8601.string(from: createdAt))))
        }
        if let modifiedAt {
            pairs.append(("modified_at", .string(AgentISO8601.string(from: modifiedAt))))
        }
        return .object(pairs)
    }
}

public enum AgentISO8601 {
    public static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

public struct ArchiveScan: Sendable {
    public let items: [ArchiveItem]
    public let nonconformingNames: [String]
    public let symlinkNames: [String]
}

public struct ArchiveStore: Sendable {
    public let root: URL
    public let isDefaultRoot: Bool

    /// Candidate real data roots. The passwd home and `$HOME` can disagree
    /// (e.g. root shells with a user's HOME); the production guard must treat
    /// every candidate as the real root.
    public static var defaultRootCandidates: [URL] {
        var urls = [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)]
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            urls.append(URL(fileURLWithPath: home).appendingPathComponent("Library", isDirectory: true))
        }
        return urls
    }

    public static var defaultRoot: URL { defaultRootCandidates[0] }

    public init(root: URL?) {
        if let root {
            let standardized = root.standardizedFileURL
            self.root = standardized
            self.isDefaultRoot = Self.defaultRootCandidates.contains {
                $0.standardizedFileURL.path == standardized.path
            }
        } else {
            self.root = Self.defaultRoot
            self.isDefaultRoot = true
        }
    }

    public var capturesDirectory: URL {
        root.appendingPathComponent("Application Support/OneClip/Captures", isDirectory: true)
    }

    public var agentDirectory: URL {
        root.appendingPathComponent("Application Support/OneClip/Agent", isDirectory: true)
    }

    public var trashDirectory: URL {
        capturesDirectory.appendingPathComponent(".trash", isDirectory: true)
    }

    public func preferencesURL(bundleID: String) -> URL {
        root.appendingPathComponent("Preferences/\(bundleID).plist")
    }

    public var capturesDirectoryExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: capturesDirectory.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // MARK: - Filename grammar (shared contract with the app)

    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    /// Parses a capture file name into (id, kind, timestamp). Returns nil for
    /// names outside the archive grammar.
    public static func parse(fileName: String) -> (id: String, kind: String, timestamp: String)? {
        guard fileName.hasSuffix(".png") else { return nil }
        let stem = String(fileName.dropLast(4))
        // Trailing "-<UUID>" (36 chars) is the stable ID.
        guard stem.count > 37 else { return nil }
        let uuidStart = stem.index(stem.endIndex, offsetBy: -36)
        guard stem[stem.index(before: uuidStart)] == "-",
              let uuid = UUID(uuidString: String(stem[uuidStart...])) else { return nil }
        let head = String(stem[..<stem.index(before: uuidStart)])
        if head.hasSuffix("-edited") {
            let base = String(head.dropLast("-edited".count))
            guard let timestamp = parseOriginalStem(base) else { return nil }
            return (uuid.uuidString.lowercased(), "edited", timestamp)
        }
        guard let timestamp = parseOriginalHead(head) else { return nil }
        return (uuid.uuidString.lowercased(), "original", timestamp)
    }

    private static func parseOriginalHead(_ head: String) -> String? {
        // "OneClip-" (8) + "yyyy-MM-dd-HHmmss" (17)
        guard head.hasPrefix("OneClip-"), head.count == 25 else { return nil }
        let timestamp = String(head.dropFirst(8))
        guard timestampFormatter.date(from: timestamp) != nil else { return nil }
        return timestamp
    }

    /// The full stem of an original capture: `OneClip-<timestamp>-<UUID>` (62
    /// chars). Edited copies are named `<original stem>-edited-<UUID>`.
    private static func parseOriginalStem(_ stem: String) -> String? {
        guard stem.count == 62 else { return nil }
        let separator = stem.index(stem.startIndex, offsetBy: 25)
        guard stem[separator] == "-",
              UUID(uuidString: String(stem[stem.index(after: separator)...])) != nil else { return nil }
        return parseOriginalHead(String(stem.prefix(25)))
    }

    // MARK: - Reading

    public func scan(deadline: AgentDeadline) throws -> ArchiveScan {
        guard capturesDirectoryExists else {
            return ArchiveScan(items: [], nonconformingNames: [], symlinkNames: [])
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: capturesDirectory.path)
        } catch {
            throw AgentError.permission("Cannot read the captures directory: \(error.localizedDescription)")
        }
        var items: [ArchiveItem] = []
        var nonconforming: [String] = []
        var symlinks: [String] = []
        for name in names.sorted() {
            try deadline.check()
            if name == ".trash" { continue }
            let url = capturesDirectory.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                                            .fileSizeKey, .creationDateKey, .contentModificationDateKey])
            if values?.isSymbolicLink == true {
                symlinks.append(name)
                continue
            }
            guard values?.isRegularFile == true else { continue }
            guard let parsed = Self.parse(fileName: name) else {
                nonconforming.append(name)
                continue
            }
            items.append(ArchiveItem(
                id: parsed.id, kind: parsed.kind, fileName: name,
                bytes: values?.fileSize ?? 0, filenameTimestamp: parsed.timestamp,
                createdAt: values?.creationDate, modifiedAt: values?.contentModificationDate))
        }
        items.sort { ($0.filenameTimestamp, $0.id) < ($1.filenameTimestamp, $1.id) }
        return ArchiveScan(items: items, nonconformingNames: nonconforming, symlinkNames: symlinks)
    }

    public func item(id: String, deadline: AgentDeadline) throws -> ArchiveItem {
        let scan = try scan(deadline: deadline)
        guard let item = scan.items.first(where: { $0.id == id.lowercased() }) else {
            throw AgentError.notFound("No saved capture with id \(id).",
                                      details: ["id": .string(id)])
        }
        return item
    }

    public static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public func hasValidPNGSignature(_ item: ArchiveItem) -> Bool {
        let url = capturesDirectory.appendingPathComponent(item.fileName)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8), data.count == 8 else { return false }
        return [UInt8](data) == Self.pngSignature
    }

    // MARK: - Writing

    /// Copies an item to a destination directory. Refuses to overwrite.
    public func export(item: ArchiveItem, toDirectory destination: URL) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw AgentError.permission("Cannot create the destination directory: \(error.localizedDescription)")
        }
        let target = destination.appendingPathComponent(item.fileName)
        if FileManager.default.fileExists(atPath: target.path) {
            throw AgentError(code: .conflict,
                             message: "Destination already exists: \(target.path). Nothing was overwritten.",
                             exitCode: .appFailure)
        }
        do {
            try FileManager.default.copyItem(at: capturesDirectory.appendingPathComponent(item.fileName), to: target)
        } catch {
            throw AgentError.appFailure("Export failed: \(error.localizedDescription)", retryable: true)
        }
        return target
    }

    /// Moves an item into `Captures/.trash/` so deletion stays recoverable.
    public func quarantine(item: ArchiveItem) throws -> String {
        do {
            try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        } catch {
            throw AgentError.permission("Cannot create the trash directory: \(error.localizedDescription)")
        }
        var targetName = item.fileName
        var counter = 2
        while FileManager.default.fileExists(atPath: trashDirectory.appendingPathComponent(targetName).path) {
            targetName = String(item.fileName.dropLast(4)) + "-\(counter).png"
            counter += 1
        }
        do {
            try FileManager.default.moveItem(at: capturesDirectory.appendingPathComponent(item.fileName),
                                             to: trashDirectory.appendingPathComponent(targetName))
        } catch {
            throw AgentError.appFailure("Delete failed: \(error.localizedDescription)", retryable: true)
        }
        return ".trash/\(targetName)"
    }

    public func trashedCount() -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: trashDirectory.path) else { return 0 }
        return names.count
    }
}
