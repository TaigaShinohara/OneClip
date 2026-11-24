import Foundation
#if os(Linux)
import CoreFoundation
#endif

/// Read-only view over the app's UserDefaults plist
/// (`<root>/Preferences/<bundle-id>.plist`). Values are reported by type;
/// binary values (such as the recorded hotkey chords) are reported as
/// presence + byte count only, never as raw content.
public struct PreferencesReader: Sendable {
    public let store: ArchiveStore

    public init(store: ArchiveStore) { self.store = store }

    public static let knownKeys: [(key: String, kind: String)] = [
        ("OneClip.hasSeenCaptureGuide", "bool"),
        ("OneClip.hasSeenCollectionGuide", "bool"),
        ("OneClip.hasSeenPasteHint", "bool"),
        ("OneClip.hasSeenWelcome", "bool"),
        ("OneClip.completedOnboardingVersion", "number"),
        ("OneClip.onboardingConcern", "string"),
        ("OneClip.onboardingTrialSample", "string"),
        ("OneClip.singleCaptureHotKey.v1", "data"),
        ("OneClip.collectionCaptureHotKey.v1", "data"),
    ]

    public static let bundleIDs = ["local.OneClip", "com.taigashinohara.oneclipmac"]

    public func domainExists(bundleID: String) -> Bool {
        FileManager.default.fileExists(atPath: store.preferencesURL(bundleID: bundleID).path)
    }

    public func loadDomain(bundleID: String) throws -> [String: Any] {
        let url = store.preferencesURL(bundleID: bundleID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AgentError.notFound("No preferences domain for \(bundleID).",
                                      details: ["bundle_id": .string(bundleID)])
        }
        do {
            let data = try Data(contentsOf: url)
            let object = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let dict = object as? [String: Any] else {
                throw AgentError.appFailure("Preferences for \(bundleID) are not a dictionary plist.")
            }
            return dict
        } catch let error as AgentError {
            throw error
        } catch {
            throw AgentError.appFailure("Cannot read preferences for \(bundleID): \(error.localizedDescription)")
        }
    }

    /// Renders one plist value for machine output. Scalars pass through;
    /// data becomes presence + size; containers become a type label only.
    public static func render(value: Any) -> AgentJSONValue {
        switch value {
        case let data as Data:
            return .object([("present", .bool(true)), ("bytes", .int(data.count)), ("type", .string("data"))])
        case let string as String:
            return .string(string)
        case let date as Date:
            return .string(AgentISO8601.string(from: date))
        case is [Any]:
            return .object([("present", .bool(true)), ("type", .string("array"))])
        case is [String: Any]:
            return .object([("present", .bool(true)), ("type", .string("dictionary"))])
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .double(number.doubleValue)
        default:
            return .object([("present", .bool(true)), ("type", .string("unknown"))])
        }
    }

    public static func typeName(of value: Any) -> String {
        switch value {
        case is Data: return "data"
        case is String: return "string"
        case is Date: return "date"
        case is [Any]: return "array"
        case is [String: Any]: return "dictionary"
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
        default: return "unknown"
        }
    }
}
