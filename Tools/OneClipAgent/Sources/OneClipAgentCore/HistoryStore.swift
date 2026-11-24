import Foundation

/// Append-only JSONL history of the CLI's own write operations, stored at
/// `<root>/Application Support/OneClip/Agent/history.jsonl`.
/// Read commands never write here (reads stay side-effect free). The GUI app
/// keeps no persistent history, so GUI operations never appear here — the
/// guide states this openly.
public struct HistoryEntry: Sendable {
    public let timestamp: String
    public let requestID: String
    public let command: String
    public let ok: Bool
    public let errorCode: String?
    public let idempotencyKey: String?
    public let summary: AgentJSONValue?

    public func jsonObject() -> AgentJSONValue {
        var pairs: [(String, AgentJSONValue)] = [
            ("timestamp", .string(timestamp)),
            ("request_id", .string(requestID)),
            ("command", .string(command)),
            ("ok", .bool(ok)),
        ]
        if let errorCode { pairs.append(("error_code", .string(errorCode))) }
        if let idempotencyKey { pairs.append(("idempotency_key", .string(idempotencyKey))) }
        if let summary { pairs.append(("summary", summary)) }
        return .object(pairs)
    }
}

public struct HistoryStore: Sendable {
    public let store: ArchiveStore

    public init(store: ArchiveStore) { self.store = store }

    public var fileURL: URL { store.agentDirectory.appendingPathComponent("history.jsonl") }
    public var isAvailable: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    public func append(command: String, requestID: String, ok: Bool, errorCode: String?,
                       idempotencyKey: String?, summary: AgentJSONValue?) {
        let entry = HistoryEntry(timestamp: AgentISO8601.string(from: Date()),
                                 requestID: requestID, command: command, ok: ok,
                                 errorCode: errorCode, idempotencyKey: idempotencyKey, summary: summary)
        guard let data = try? JSONSerialization.data(withJSONObject: entry.jsonObject().foundationObject,
                                                     options: [.sortedKeys]) else { return }
        var line = data
        line.append(contentsOf: [0x0A])
        do {
            try FileManager.default.createDirectory(at: store.agentDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: fileURL)
            }
        } catch {
            // History is best-effort: a failed append must not fail the operation.
        }
    }

    public func entries(limit: Int) -> (entries: [HistoryEntry], skippedLines: Int) {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return ([], 0) }
        var parsed: [HistoryEntry] = []
        var skipped = 0
        for line in text.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestamp = object["timestamp"] as? String,
                  let requestID = object["request_id"] as? String,
                  let command = object["command"] as? String,
                  let ok = object["ok"] as? Bool else {
                skipped += 1
                continue
            }
            parsed.append(HistoryEntry(
                timestamp: timestamp, requestID: requestID, command: command, ok: ok,
                errorCode: object["error_code"] as? String,
                idempotencyKey: object["idempotency_key"] as? String,
                summary: (object["summary"]).map { AgentJSONValue(foundation: $0) }))
        }
        if limit > 0, parsed.count > limit { parsed = Array(parsed.suffix(limit)) }
        return (parsed, skipped)
    }

    /// Finds a previously successful result for an idempotency key + command,
    /// so a retried write returns the first result instead of duplicating.
    public func successfulEntry(idempotencyKey: String, command: String) -> HistoryEntry? {
        entries(limit: 0).entries.last { $0.idempotencyKey == idempotencyKey && $0.command == command && $0.ok }
    }
}
