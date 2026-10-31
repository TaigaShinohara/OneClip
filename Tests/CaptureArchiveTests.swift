import Darwin
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
        try testPrivatePermissions(root)
        print("PASS ARCHIVE-05 private modes are explicit and process-default mode controls are unchanged")
        try testDirectoryLinks(root)
        print("PASS ARCHIVE-06 root and intermediate directory links cannot redirect output")
        try testNoOverwriteAndCleanup(root)
        print("PASS ARCHIVE-07 exclusive publication preserves a competing file and cleans owned staging")
        try testDirectoryReplacement(root)
        print("PASS ARCHIVE-08 directory replacement cannot publish to a different archive")
        try testSourceReplacement(root)
        print("PASS ARCHIVE-09 source replacement cannot substitute another file during editing")
        try testIOBoundaries(root)
        print("PASS ARCHIVE-10 EINTR and short writes complete; write failure cleans staging")
        try testSavedIdentity(root)
        print("PASS ARCHIVE-11 cache reuse checks bounded full bytes and safe source identity")
        try testSourceKindsAndLimits(root)
        print("PASS ARCHIVE-12 hard links, FIFO, oversized sources and invalid PNG signatures are rejected")
        try testACLBoundary(root)
        print("PASS ARCHIVE-13 existing ACLs are rejected and preserved")
        try testBoundedReader(root)
        print("PASS ARCHIVE-14 descriptor snapshot reader enforces byte bounds and rejects link/content replacement")
        print("PASS 14 archive groups; fabricated temporary files only")
    }

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }
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

    static func info(_ url: URL) throws -> stat {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else { throw Failure(description: "Missing fabricated file metadata") }
        return value
    }

    static func entries(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    static func testPrivatePermissions(_ root: URL) throws {
        // Observe the process's ordinary mkdir defaults on both sides without reading or
        // changing its umask. All controls are inside this unique fabricated parent.
        let before = root.appendingPathComponent("default-before")
        let after = root.appendingPathComponent("default-after")
        try expect(Darwin.mkdir(before.path, 0o777) == 0, "Default control creation failed")
        let existing = root.appendingPathComponent("private-existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try expect(Darwin.chmod(existing.path, 0o755) == 0, "Fabricated existing mode setup failed")
        let archive = CaptureArchive(directory: existing.appendingPathComponent("captures"))
        let original = try archive.save(firstPNG)
        let editing = try archive.makeEditingCopy(of: original)
        try expect(try info(existing).st_mode & 0o7777 == 0o700, "Owned existing directory remained broad")
        try expect(try info(archive.directory).st_mode & 0o7777 == 0o700, "Archive directory is not private")
        for file in [original, editing] {
            let attributes = try info(file)
            try expect(attributes.st_uid == geteuid() && attributes.st_nlink == 1
                       && attributes.st_mode & 0o7777 == 0o600, "Archive file is not private and independently owned")
        }
        try expect(Darwin.mkdir(after.path, 0o777) == 0, "Second default control creation failed")
        try expect(try info(before).st_mode & 0o7777 == info(after).st_mode & 0o7777,
                   "Archive changed process-default creation permissions")
    }

    static func testDirectoryLinks(_ root: URL) throws {
        let outside = root.appendingPathComponent("link-target")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try secondPNG.write(to: sentinel)
        let link = root.appendingPathComponent("archive-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        for directory in [link, link.appendingPathComponent("nested")] {
            try expectFailure { _ = try CaptureArchive(directory: directory).save(firstPNG) }
        }
        try expect(try entries(outside).count == 1 && Data(contentsOf: sentinel) == secondPNG,
                   "Directory link redirected an output or changed target data")
    }

    static func testNoOverwriteAndCleanup(_ root: URL) throws {
        let target = root.appendingPathComponent("publish-collision")
        let archive = CaptureArchive(directory: target, testingHooks: .init(beforePublish: { destination in
            try secondPNG.write(to: destination, options: .withoutOverwriting)
        }))
        try expectFailure { _ = try archive.save(firstPNG) }
        let files = try entries(archive.directory)
        try expect(files.count == 1 && files[0].pathExtension == "png", "Failed publication retained staging")
        try expect(try Data(contentsOf: files[0]) == secondPNG, "Publication replaced a competing destination")

        let failed = CaptureArchive(directory: root.appendingPathComponent("publish-failure"),
            testingHooks: .init(beforePublish: { _ in throw Failure(description: "Injected publish failure") }))
        try expectFailure { _ = try failed.save(firstPNG) }
        try expect(try entries(failed.directory).isEmpty, "Injected failure retained owned staging")
    }

    static func testDirectoryReplacement(_ root: URL) throws {
        let target = root.appendingPathComponent("replace-directory")
        let moved = root.appendingPathComponent("replace-directory-moved")
        let outside = root.appendingPathComponent("replace-directory-target")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let archive = CaptureArchive(directory: target, testingHooks: .init(beforePublish: { _ in
            try FileManager.default.moveItem(at: target, to: moved)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        }))
        try expectFailure { _ = try archive.save(firstPNG) }
        try expect(try entries(outside).isEmpty && entries(moved).isEmpty,
                   "Replaced directory received output or left owned staging")
    }

    static func testSourceReplacement(_ root: URL) throws {
        let directory = root.appendingPathComponent("replace-source")
        let plain = CaptureArchive(directory: directory)
        let source = try plain.save(firstPNG)
        let backup = source.deletingLastPathComponent().appendingPathComponent("original-backup.png")
        let outside = root.appendingPathComponent("replace-source-outside.png")
        try secondPNG.write(to: outside)
        let archive = CaptureArchive(directory: directory, testingHooks: .init(afterSourceOpened: {
            try FileManager.default.moveItem(at: source, to: backup)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        }))
        try expectFailure { _ = try archive.makeEditingCopy(of: source) }
        try expect(try Data(contentsOf: backup) == firstPNG && Data(contentsOf: outside) == secondPNG,
                   "Source replacement changed an original or outside data")
        try expect(try entries(plain.directory).count == 2, "Source substitution published a copy or retained staging")
    }

    final class ShortWrites: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func directive() -> CaptureArchive.TestingHooks.WriteDirective {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return count == 1 ? .interrupt : .limit(2)
        }
    }

    static func testIOBoundaries(_ root: URL) throws {
        let writes = ShortWrites()
        let archive = CaptureArchive(directory: root.appendingPathComponent("short-writes"),
            testingHooks: .init(writeDirective: { _ in writes.directive() }))
        let output = try archive.save(firstPNG)
        try expect(try Data(contentsOf: output) == firstPNG, "Short or interrupted write lost bytes")
        let failed = CaptureArchive(directory: root.appendingPathComponent("failed-write"),
            testingHooks: .init(writeDirective: { _ in .fail }))
        try expectFailure { _ = try failed.save(firstPNG) }
        try expect(try entries(failed.directory).isEmpty, "Failed write retained staging")
    }

    static func testSavedIdentity(_ root: URL) throws {
        let archive = CaptureArchive(directory: root.appendingPathComponent("saved-identity"))
        let source = try archive.save(firstPNG)
        try expect(try archive.matchesSavedCapture(source, png: firstPNG), "Identical saved PNG did not match")
        try expect(try !archive.matchesSavedCapture(source, png: secondPNG), "Different same-length PNG matched")
        try expect(try !archive.matchesSavedCapture(source, png: firstPNG + Data([9])), "Different size PNG matched")
        try archive.validateSavedFile(source)
        try secondPNG.write(to: source, options: .atomic)
        try expect(try !archive.matchesSavedCapture(source, png: firstPNG), "Replaced original was reused")
        let link = archive.directory.appendingPathComponent("identity-link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        try expectFailure { _ = try archive.matchesSavedCapture(link, png: secondPNG) }
        try expectFailure { try archive.validateSavedFile(link) }
        let folder = archive.directory.appendingPathComponent("identity-folder.png")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try expectFailure { _ = try archive.matchesSavedCapture(folder, png: firstPNG) }

        let raceDirectory = root.appendingPathComponent("identity-replacement")
        let stable = CaptureArchive(directory: raceDirectory)
        let raced = try stable.save(firstPNG)
        let backup = stable.directory.appendingPathComponent("identity-backup.png")
        let changing = CaptureArchive(directory: raceDirectory, testingHooks: .init(afterSourceOpened: {
            try FileManager.default.moveItem(at: raced, to: backup)
            try secondPNG.write(to: raced, options: .withoutOverwriting)
        }))
        try expectFailure { _ = try changing.matchesSavedCapture(raced, png: firstPNG) }
        try expect(try Data(contentsOf: backup) == firstPNG && Data(contentsOf: raced) == secondPNG,
                   "Identity validation modified a replacement or its original")
    }

    static func testSourceKindsAndLimits(_ root: URL) throws {
        let archive = CaptureArchive(directory: root.appendingPathComponent("source-kinds"))
        let source = try archive.save(firstPNG)
        let hard = archive.directory.appendingPathComponent("hard.png")
        try expect(Darwin.link(source.path, hard.path) == 0, "Fabricated hard-link setup failed")
        try expectFailure { _ = try archive.makeEditingCopy(of: hard) }
        let fifo = archive.directory.appendingPathComponent("pipe.png")
        try expect(Darwin.mkfifo(fifo.path, 0o600) == 0, "Fabricated FIFO setup failed")
        try expectFailure { _ = try archive.makeEditingCopy(of: fifo) }
        let huge = archive.directory.appendingPathComponent("oversized.png")
        let fd = Darwin.open(huge.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        try expect(fd >= 0, "Sparse source setup failed")
        defer { Darwin.close(fd) }
        try expect(Darwin.ftruncate(fd, off_t(CaptureArchive.maximumPNGBytes + 1)) == 0, "Sparse size setup failed")
        try expectFailure { _ = try archive.makeEditingCopy(of: huge) }
        let invalid = archive.directory.appendingPathComponent("invalid.png")
        try Data(repeating: 0, count: 16).write(to: invalid)
        try expectFailure { try archive.validateSavedFile(invalid) }
    }

    static func testACLBoundary(_ root: URL) throws {
        let archive = CaptureArchive(directory: root.appendingPathComponent("acl-boundary"))
        try archive.createDirectory()
        let fd = Darwin.open(archive.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try expect(fd >= 0, "ACL fixture directory setup failed")
        defer { Darwin.close(fd) }
        var acl = acl_init(1)
        guard acl != nil else { throw Failure(description: "ACL fixture allocation failed") }
        defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
        var entry: acl_entry_t?
        try expect(acl_create_entry(&acl, &entry) == 0, "ACL fixture entry setup failed")
        guard let acl, let entry else { throw Failure(description: "ACL fixture descriptor unavailable") }
        var principal = UUID().uuid
        try expect(acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0, "ACL fixture tag setup failed")
        let qualifier = withUnsafePointer(to: &principal) { acl_set_qualifier(entry, $0) }
        var permissions: acl_permset_t?
        try expect(qualifier == 0 && acl_get_permset(entry, &permissions) == 0, "ACL fixture fields failed")
        guard let permissions else { throw Failure(description: "ACL fixture permissions unavailable") }
        try expect(acl_add_perm(permissions, ACL_READ_SECURITY) == 0
                   && acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0, "ACL fixture installation failed")
        try expectFailure { _ = try archive.save(firstPNG) }
        guard let retained = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { throw Failure(description: "Existing ACL was lost") }
        defer { acl_free(UnsafeMutableRawPointer(retained)) }
        var retainedEntry: acl_entry_t?
        try expect(acl_get_entry(retained, Int32(ACL_FIRST_ENTRY.rawValue), &retainedEntry) == 0,
                   "Rejected operation removed the existing ACL")
        try expect(try entries(archive.directory).isEmpty, "Rejected ACL directory received image data")
    }

    static func testBoundedReader(_ root: URL) throws {
        let directory = root.appendingPathComponent("bounded-reader")
        let archive = CaptureArchive(directory: directory)
        let source = try archive.save(firstPNG)
        try expect(try archive.readSavedPNG(source, maximumBytes: firstPNG.count) == firstPNG,
                   "Exact-size private PNG snapshot changed bytes")
        try expectFailure { _ = try archive.readSavedPNG(source, maximumBytes: firstPNG.count - 1) }
        try expectFailure { _ = try archive.readSavedPNG(source, maximumBytes: 0) }
        let linked = archive.directory.appendingPathComponent("reader-link.png")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: source)
        try expectFailure { _ = try archive.readSavedPNG(linked) }
        let backup = archive.directory.appendingPathComponent("reader-original.png")
        let racing = CaptureArchive(directory: directory, testingHooks: .init(afterSourceOpened: {
            try FileManager.default.moveItem(at: source, to: backup)
            try secondPNG.write(to: source, options: .withoutOverwriting)
        }))
        try expectFailure { _ = try racing.readSavedPNG(source) }
        try expect(try Data(contentsOf: backup) == firstPNG && Data(contentsOf: source) == secondPNG,
                   "Rejected reader replacement changed fabricated files")
    }
}
