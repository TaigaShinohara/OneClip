import Foundation

/// Durable local output, independent of whether the clipboard accepts the same PNG.
/// No image contents or file paths are logged. Callers pass already validated capture PNGs.
struct CaptureArchive: Sendable {
    enum ArchiveError: Error, Equatable {
        case invalidPNG
        case invalidSource
    }

    static var defaultDirectory: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("OneClip", isDirectory: true)
            .appendingPathComponent("Captures", isDirectory: true)
    }

    let directory: URL

    init(directory: URL = CaptureArchive.defaultDirectory) {
        self.directory = directory.isFileURL
            ? URL(fileURLWithPath: directory.standardizedFileURL.path, isDirectory: true)
            : directory
    }

    func createDirectory() throws {
        guard directory.isFileURL else { throw ArchiveError.invalidSource }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func save(_ png: Data) throws -> URL {
        guard png.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else {
            throw ArchiveError.invalidPNG
        }
        try createDirectory()
        let destination = uniqueURL(prefix: "OneClip-\(Self.timestamp())")
        let staging = stagingURL()
        defer { try? FileManager.default.removeItem(at: staging) }
        try png.write(to: staging, options: .atomic)
        // moveItem refuses an existing destination. An output is never overwritten,
        // even if another process creates its name between preparation and commit.
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }

    /// Preserve the capture as an original. Preview edits a separate, stable file.
    func makeEditingCopy(of source: URL) throws -> URL {
        let source = source.standardizedFileURL
        guard source.isFileURL, source.pathExtension.lowercased() == "png",
              source.deletingLastPathComponent() == directory,
              source.resolvingSymlinksInPath().deletingLastPathComponent()
                == directory.resolvingSymlinksInPath() else {
            throw ArchiveError.invalidSource
        }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ArchiveError.invalidSource
        }
        let destination = uniqueURL(prefix: source.deletingPathExtension().lastPathComponent + "-edited")
        let staging = stagingURL()
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }

    private func uniqueURL(prefix: String) -> URL {
        directory.appendingPathComponent("\(prefix)-\(UUID().uuidString).png", isDirectory: false)
    }

    private func stagingURL() -> URL {
        directory.appendingPathComponent(".oneclip-\(UUID().uuidString).tmp", isDirectory: false)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }
}
