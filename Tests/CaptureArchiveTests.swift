import Foundation

/// Uses tiny fabricated bytes and a unique temporary directory. No screen, clipboard,
/// user capture folder, application launch, or permissions are accessed.
@main
struct CaptureArchiveTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    // The archive boundary validates the signature; complete PNG validation belongs to
    // the image pipeline before this service. Distinct payloads expose accidental reuse.
    static let firstPNG = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3])
    static let secondPNG = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 4, 5, 6])

    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneClip-ArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try testSaves(root)
        print("PASS ARCHIVE-01 unique durable outputs preserve both payloads")
        try testEditing(root)
        print("PASS ARCHIVE-02 editing copy preserves capture original and associates filename")
        try testFailure(root)
        print("PASS ARCHIVE-03 invalid input and unwritable destination report failure")
        try testSourceBoundary(root)
        print("PASS ARCHIVE-04 editing rejects outside files, symlinks and non-regular sources")
        print("PASS 4 archive groups; fabricated temporary files only")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }

    static func expectFailure(_ body: () throws -> Void) throws {
        var failed = false
        do { try body() } catch { failed = true }
        try expect(failed, "Operation unexpectedly succeeded")
    }

    static func testSaves(_ root: URL) throws {
        let archive = CaptureArchive(directory: root.appendingPathComponent("nested/captures"))
        let first = try archive.save(firstPNG)
        let second = try archive.save(secondPNG)
        try expect(first != second, "Consecutive captures shared a filename")
        try expect(first.pathExtension == "png" && second.pathExtension == "png", "Outputs must be PNG files")
        try expect(first.deletingLastPathComponent() == archive.directory, "Capture escaped archive folder")
        let firstData = try Data(contentsOf: first)
        let secondData = try Data(contentsOf: second)
        try expect(firstData == firstPNG && secondData == secondPNG, "Saving altered or replaced capture bytes")
        let files = try FileManager.default.contentsOfDirectory(at: archive.directory, includingPropertiesForKeys: nil)
        try expect(files.count == 2, "Staging artifacts remained after successful saves")
    }

    static func testEditing(_ root: URL) throws {
        let archive = CaptureArchive(directory: root.appendingPathComponent("editing"))
        let source = try archive.save(firstPNG)
        let edited = try archive.makeEditingCopy(of: source)
        let secondCopy = try archive.makeEditingCopy(of: source)
        try expect(source != edited && edited != secondCopy, "Editing overwrote an existing file")
        try expect(edited.lastPathComponent.hasPrefix(source.deletingPathExtension().lastPathComponent + "-edited-"),
                   "Editing copy lost original filename association")
        let copiedBytes = try Data(contentsOf: edited)
        try expect(copiedBytes == firstPNG, "Editing copy changed original bytes")
        try secondPNG.write(to: edited, options: .atomic)
        let originalBytes = try Data(contentsOf: source)
        let otherCopyBytes = try Data(contentsOf: secondCopy)
        try expect(originalBytes == firstPNG && otherCopyBytes == firstPNG, "Editing changed capture or another copy")
    }

    static func testFailure(_ root: URL) throws {
        let invalid = CaptureArchive(directory: root.appendingPathComponent("invalid"))
        try expectFailure { _ = try invalid.save(Data([1, 2, 3])) }
        try expect(!FileManager.default.fileExists(atPath: invalid.directory.path), "Invalid PNG created archive folder")
        let blocked = root.appendingPathComponent("blocked")
        try Data([0]).write(to: blocked)
        let archive = CaptureArchive(directory: blocked.appendingPathComponent("captures"))
        try expectFailure { _ = try archive.save(firstPNG) }
        let retained = try Data(contentsOf: blocked)
        try expect(retained == Data([0]), "Save failure modified blocking file")
        let remote = CaptureArchive(directory: URL(string: "https://example.invalid/captures")!)
        try expectFailure { try remote.createDirectory() }
    }

    static func testSourceBoundary(_ root: URL) throws {
        let archive = CaptureArchive(directory: root.appendingPathComponent("boundary"))
        try archive.createDirectory()
        let outside = root.appendingPathComponent("outside.png")
        try firstPNG.write(to: outside)
        try expectFailure { _ = try archive.makeEditingCopy(of: outside) }
        let symbolic = archive.directory.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: outside)
        try expectFailure { _ = try archive.makeEditingCopy(of: symbolic) }
        let folder = archive.directory.appendingPathComponent("folder.png", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try expectFailure { _ = try archive.makeEditingCopy(of: folder) }
        let original = try Data(contentsOf: outside)
        try expect(original == firstPNG, "Rejected operation modified outside file")
    }
}
