import Foundation
import Security

/// Resolve only Apple's system Preview. Launch Services' bundle-ID heuristics are not an
/// identity check. This helper never launches/registers an app or receives image/file contents.
enum TrustedPreviewApplication {
    static let systemURL = URL(fileURLWithPath: "/System/Applications/Preview.app", isDirectory: true)
    static let bundleIdentifier = "com.apple.Preview"
    static let requirement = "anchor apple and identifier \"com.apple.Preview\""
    static let validationFlags: UInt32 = kSecCSStrictValidate | kSecCSCheckAllArchitectures

    struct Metadata: Sendable {
        let canonicalURL: URL
        let isDirectory: Bool
        let isSymbolicLink: Bool
        let bundleIdentifier: String?
    }

    /// Pure policy tests replace both operations. Production always uses the fixed live
    /// implementation; no arguments, preferences or remote entry point can select a backend.
    struct Backend: Sendable {
        let metadata: @Sendable (URL) -> Metadata?
        let signatureValid: @Sendable (URL, String, UInt32) -> Bool

        static var live: Backend {
            Backend(metadata: { url in
                guard let attributes = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      let isDirectory = attributes.isDirectory,
                      let isSymbolicLink = attributes.isSymbolicLink else { return nil }
                return Metadata(canonicalURL: url.resolvingSymlinksInPath().standardizedFileURL,
                    isDirectory: isDirectory, isSymbolicLink: isSymbolicLink,
                    bundleIdentifier: Bundle(url: url)?.bundleIdentifier)
            }, signatureValid: { url, policy, flags in
                var code: SecStaticCode?
                var requirement: SecRequirement?
                guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(rawValue: 0), &code) == errSecSuccess,
                      let code,
                      SecRequirementCreateWithString(policy as CFString, SecCSFlags(rawValue: 0), &requirement) == errSecSuccess,
                      let requirement else { return false }
                // The flags retain executable/resource checks and validate every architecture.
                // No network-access flag is supplied; raw OSStatus/error/signing data is not logged.
                return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: flags), requirement) == errSecSuccess
            })
        }
    }

    /// Run off MainActor: strict validation can read an entire code bundle. Only fixed policy
    /// and a URL are used. The caller must recheck its user-action generation before opening.
    static func verifiedURL(candidate: URL = systemURL, using backend: Backend = .live) -> URL? {
        guard candidate.isFileURL, candidate.host == nil || candidate.host == "" || candidate.host == "localhost",
              candidate.standardizedFileURL.path == systemURL.path else { return nil }
        guard accepts(backend.metadata(systemURL)),
              backend.signatureValid(systemURL, requirement, validationFlags),
              accepts(backend.metadata(systemURL)) else { return nil }
        return systemURL
    }

    private static func accepts(_ metadata: Metadata?) -> Bool {
        guard let metadata else { return false }
        return metadata.isDirectory && !metadata.isSymbolicLink
            && metadata.canonicalURL.isFileURL
            && (metadata.canonicalURL.host == nil || metadata.canonicalURL.host == "" || metadata.canonicalURL.host == "localhost")
            && metadata.canonicalURL.standardizedFileURL.path == systemURL.path
            && metadata.bundleIdentifier == bundleIdentifier
    }
}
