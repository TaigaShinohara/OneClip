import Foundation

/// Default tests use metadata/signature fakes only: no bundle read, Launch Services, application,
/// screen, board or file write. The opt-in system check reads Apple's app signature, never opens it.
@main
struct TrustedPreviewApplicationTests {
    struct Failure: Error { let code: String }

    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0, validations = 0
        let first: TrustedPreviewApplication.Metadata?
        let later: TrustedPreviewApplication.Metadata?
        let signed: Bool
        let expectedPolicy: String
        init(first: TrustedPreviewApplication.Metadata?, later: TrustedPreviewApplication.Metadata? = nil,
             signed: Bool = true, expectedPolicy: String = "anchor apple and identifier \"com.apple.Preview\"") {
            self.first = first; self.later = later; self.signed = signed; self.expectedPolicy = expectedPolicy
        }
        var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (reads, validations) }
        var backend: TrustedPreviewApplication.Backend {
            .init(metadata: { [self] url in
                lock.lock(); defer { lock.unlock() }
                reads += 1
                guard url.path == "/System/Applications/Preview.app" else { return nil }
                return reads > 1 ? (later ?? first) : first
            }, signatureValid: { [self] url, requirement, flags in
                lock.lock(); defer { lock.unlock() }
                validations += 1
                return signed && url.path == "/System/Applications/Preview.app" && requirement == expectedPolicy
                    && flags == TrustedPreviewApplication.validationFlags
                    && flags == 0x11 // strict validation + all architectures, no bypass/network flags.
            })
        }
    }

    static var good: TrustedPreviewApplication.Metadata {
        .init(canonicalURL: TrustedPreviewApplication.systemURL, isDirectory: true,
              isSymbolicLink: false, bundleIdentifier: "com.apple.Preview")
    }

    static func require(_ condition: @autoclosure () -> Bool, _ code: String) throws {
        guard condition() else { throw Failure(code: code) }
    }

    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] {
            print("TrustedPreviewApplicationTests: default synthetic policy tests; --verify-system-preview reads the system signature without launching it")
            return
        }
        if arguments == ["--verify-system-preview"] {
            guard TrustedPreviewApplication.verifiedURL() != nil else {
                print("FAIL PREVIEW_SYSTEM_IDENTITY_SIGNATURE"); exit(1)
            }
            print("PASS PREVIEW_SYSTEM_IDENTITY_SIGNATURE READ_ONLY_NO_LAUNCH")
            return
        }
        guard arguments.isEmpty else { print("BLOCKED PREVIEW_TEST_ARGUMENTS"); exit(2) }

        let accepted = Probe(first: good)
        try require(TrustedPreviewApplication.verifiedURL(using: accepted.backend) == TrustedPreviewApplication.systemURL,
                    "PREVIEW_FIXED_SYSTEM_REJECTED")
        try require(accepted.counts == (2, 1), "PREVIEW_REQUIRED_CHECKS_SKIPPED")
        print("PASS PREVIEW-01 fixed system candidate requires strict Apple identity and both metadata checks")

        for url in [URL(fileURLWithPath: "/Applications/Preview.app"),
                    URL(fileURLWithPath: "/private/tmp/Preview.app"),
                    URL(string: "https://example.invalid/Preview.app")!,
                    URL(string: "file://example.invalid/System/Applications/Preview.app")!] {
            let probe = Probe(first: good)
            try require(TrustedPreviewApplication.verifiedURL(candidate: url, using: probe.backend) == nil,
                        "PREVIEW_OTHER_LOCATION_ACCEPTED")
            try require(probe.counts == (0, 0), "PREVIEW_REJECTED_PATH_READ")
        }
        print("PASS PREVIEW-02 alternate local paths and remote URLs rejected before inspection")

        let rejected: [TrustedPreviewApplication.Metadata?] = [nil,
            .init(canonicalURL: TrustedPreviewApplication.systemURL, isDirectory: false, isSymbolicLink: false, bundleIdentifier: "com.apple.Preview"),
            .init(canonicalURL: TrustedPreviewApplication.systemURL, isDirectory: true, isSymbolicLink: true, bundleIdentifier: "com.apple.Preview"),
            .init(canonicalURL: URL(fileURLWithPath: "/private/tmp/Preview.app"), isDirectory: true, isSymbolicLink: false, bundleIdentifier: "com.apple.Preview"),
            .init(canonicalURL: TrustedPreviewApplication.systemURL, isDirectory: true, isSymbolicLink: false, bundleIdentifier: "example.invalid"),
            .init(canonicalURL: TrustedPreviewApplication.systemURL, isDirectory: true, isSymbolicLink: false, bundleIdentifier: nil)]
        for metadata in rejected {
            let probe = Probe(first: metadata)
            try require(TrustedPreviewApplication.verifiedURL(using: probe.backend) == nil, "PREVIEW_BAD_METADATA_ACCEPTED")
            try require(probe.counts == (1, 0), "PREVIEW_BAD_METADATA_REACHED_SIGNATURE")
        }
        print("PASS PREVIEW-03 missing, non-directory, symbolic, redirected and wrong-identifier metadata rejected")

        for probe in [Probe(first: good, signed: false),
                      Probe(first: good, expectedPolicy: "anchor apple generic and identifier \"com.apple.Preview\"")] {
            try require(TrustedPreviewApplication.verifiedURL(using: probe.backend) == nil,
                        "PREVIEW_NONAPPLE_OR_WRONG_POLICY_ACCEPTED")
            try require(probe.counts == (1, 1), "PREVIEW_FAILED_SIGNATURE_ACCEPTED")
        }
        print("PASS PREVIEW-04 failed signature and weaker Apple-issued policy rejected")

        let changed = TrustedPreviewApplication.Metadata(canonicalURL: TrustedPreviewApplication.systemURL,
            isDirectory: true, isSymbolicLink: false, bundleIdentifier: "example.invalid")
        let racing = Probe(first: good, later: changed)
        try require(TrustedPreviewApplication.verifiedURL(using: racing.backend) == nil
                    && racing.counts == (2, 1), "PREVIEW_CHANGED_METADATA_ACCEPTED")
        print("PASS PREVIEW-05 changed post-validation metadata rejected")
        print("PASS 5 Preview policy groups; synthetic backends only")
    }
}
