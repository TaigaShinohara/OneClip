import Foundation
#if os(Linux)
import CoreFoundation
#endif

/// Stable string error codes for the agent contract. Codes never change once
/// published; new failures get new codes. See docs/AGENT_GUIDE.md.
public enum AgentErrorCode: String, Sendable {
    case invalidInput = "invalid_input"
    case notFound = "not_found"
    case appFailure = "app_failure"
    case permissionDenied = "permission_denied"
    case productionGuard = "production_guard"
    case confirmationRequired = "confirmation_required"
    case conflict = "conflict"
    case invalidPNG = "invalid_png"
    case timeout = "timeout"
    case unsupported = "unsupported"
}

/// Exit codes are part of the contract:
/// 0 success, 1 caller input error, 2 app-side failure, 3 permission, 4 not found.
public enum AgentExitCode: Int32, Sendable {
    case success = 0
    case invalidInput = 1
    case appFailure = 2
    case permission = 3
    case notFound = 4
}

public struct AgentError: Error, Sendable {
    public let code: AgentErrorCode
    public let message: String
    public let exitCode: AgentExitCode
    public let retryable: Bool
    public let details: [String: AgentJSONValue]

    public init(code: AgentErrorCode, message: String, exitCode: AgentExitCode,
                retryable: Bool = false, details: [String: AgentJSONValue] = [:]) {
        self.code = code
        self.message = message
        self.exitCode = exitCode
        self.retryable = retryable
        self.details = details
    }

    public static func invalidInput(_ message: String, details: [String: AgentJSONValue] = [:]) -> AgentError {
        AgentError(code: .invalidInput, message: message, exitCode: .invalidInput, details: details)
    }

    public static func notFound(_ message: String, details: [String: AgentJSONValue] = [:]) -> AgentError {
        AgentError(code: .notFound, message: message, exitCode: .notFound, details: details)
    }

    public static func appFailure(_ message: String, retryable: Bool = false) -> AgentError {
        AgentError(code: .appFailure, message: message, exitCode: .appFailure, retryable: retryable)
    }

    public static func permission(_ message: String) -> AgentError {
        AgentError(code: .permissionDenied, message: message, exitCode: .permission)
    }
}

/// A minimal ordered JSON value used for envelope payloads. The CLI never
/// embeds image bytes or other captured content in these payloads.
public enum AgentJSONValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([AgentJSONValue])
    case object([(String, AgentJSONValue)])
}

extension AgentJSONValue: Equatable {
    public static func == (lhs: AgentJSONValue, rhs: AgentJSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.null, .null): return true
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }
}

extension AgentJSONValue {

    public var foundationObject: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        case .array(let values): return values.map { $0.foundationObject }
        case .object(let pairs):
            var dict: [String: Any] = [:]
            for (key, value) in pairs { dict[key] = value.foundationObject }
            return dict
        }
    }

    /// Converts a Foundation JSON object back into an AgentJSONValue
    /// (used when reading recorded history entries).
    public init(foundation value: Any) {
        switch value {
        case let string as String: self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if number.doubleValue == Double(number.intValue) {
                self = .int(number.intValue)
            } else {
                self = .double(number.doubleValue)
            }
        case let array as [Any]: self = .array(array.map { AgentJSONValue(foundation: $0) })
        case let dict as [String: Any]:
            self = .object(dict.keys.sorted().map { ($0, AgentJSONValue(foundation: dict[$0]!)) })
        default: self = .null
        }
    }
}

public enum AgentEnvelope {
    public static let schemaVersion = 1

    public static func success(data: AgentJSONValue, requestID: String,
                               extraMeta: [(String, AgentJSONValue)] = []) -> Data {
        var meta: [(String, AgentJSONValue)] = [
            ("schema_version", .int(schemaVersion)),
            ("request_id", .string(requestID)),
        ]
        meta.append(contentsOf: extraMeta)
        return encode(.object([
            ("ok", .bool(true)),
            ("data", data),
            ("meta", .object(meta)),
        ]))
    }

    public static func failure(error: AgentError, requestID: String) -> Data {
        var errorObject: [(String, AgentJSONValue)] = [
            ("code", .string(error.code.rawValue)),
            ("message", .string(error.message)),
            ("retryable", .bool(error.retryable)),
        ]
        if !error.details.isEmpty {
            errorObject.append(("details", .object(error.details.sorted { $0.key < $1.key })))
        }
        return encode(.object([
            ("ok", .bool(false)),
            ("error", .object(errorObject)),
            ("meta", .object([
                ("schema_version", .int(schemaVersion)),
                ("request_id", .string(requestID)),
            ])),
        ]))
    }

    private static func encode(_ value: AgentJSONValue) -> Data {
        // Sorted keys keep output deterministic for tests and diffing.
        (try? JSONSerialization.data(withJSONObject: value.foundationObject,
                                     options: [.sortedKeys, .prettyPrinted])) ?? Data()
    }
}

/// A simple deadline used to honour `--timeout` during directory scans.
public struct AgentDeadline: Sendable {
    public let limit: TimeInterval
    private let start: Date

    public init(timeoutSeconds: TimeInterval) {
        self.limit = timeoutSeconds
        self.start = Date()
    }

    public func check() throws {
        if Date().timeIntervalSince(start) > limit {
            throw AgentError(code: .timeout,
                             message: "Operation exceeded the \(Int(limit))s timeout.",
                             exitCode: .appFailure, retryable: true)
        }
    }
}
