import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif
import OneClipAgentCore

// oneclip-agent: machine interface to OneClip's saved-data store.
// Contract: docs/AGENT_GUIDE.md. All machine output is one JSON envelope on
// stdout; human notes go to stderr. Reads are side-effect free.

let appVersion = "1.0.1"
let appBuild = "4"
let agentLevel = 1

struct Options {
    var human = false
    var root: String?
    var timeout: TimeInterval = 30
    var dryRun = false
    var yes = false
    var idempotencyKey: String?
    var destination: String?
    var bundleID: String = "local.OneClip"
    var limit: Int = 50
    var testData = false
    var help = false
    var positionals: [String] = []
}

let globalHelp = """
oneclip-agent — machine interface to OneClip's saved captures and settings.

USAGE:
  oneclip-agent <command> [arguments] [flags]

COMMANDS:
  status                 App version, data locations, archive summary (read)
  list                   List saved captures (read)
  get <id>               Show one saved capture's metadata (read)
  settings list          List known preference keys and values (read)
  settings get <key>     Show one preference key (read)
  history [--limit n]    Show recorded machine write operations (read)
  doctor                 Check prerequisites and report problems (read)
  verify                 Verify archive integrity (read)
  export <id> --to <dir> Copy a saved capture out of the archive (write)
  delete <id> --yes      Move a saved capture to .trash (write, recoverable)
  seed                   Create deterministic test fixtures (test roots only)
  reset --test-data      Clear a seeded test root (test roots only)

COMMON FLAGS:
  --json                 JSON output (default)
  --human                Human-readable output instead of JSON
  --root <dir>           Data root (a Library-like directory). Default: ~/Library
                         Env: ONECLIP_AGENT_ROOT
  --timeout <sec>        Scan timeout (default 30)
  --dry-run              Report what a write would do, without doing it
  --yes                  Confirm a destructive write (required for delete)
  --idempotency-key <k>  Make a write safe to retry: same key returns the
                         first result instead of duplicating the operation
  --help                 Show help for the command

EXIT CODES: 0 success / 1 input error / 2 app failure / 3 permission / 4 not found
Image contents are never printed. Items are metadata only.
"""

let commandHelp: [String: String] = [
    "status": "status — app version, data root, archive counts, preference domains, history availability.\nExample: oneclip-agent status --json",
    "list": "list — all saved captures with stable IDs, kind (original/edited), filename timestamp and size.\nExample: oneclip-agent list --json",
    "get": "get <id> — metadata for one saved capture, including its file path and PNG signature check.\nExample: oneclip-agent get 11111111-1111-4111-8111-111111111111 --json",
    "settings": "settings list | settings get <key> [--bundle-id <id>] — read the app's preferences domain (default local.OneClip). Binary values are reported as presence + byte count.\nExample: oneclip-agent settings get OneClip.hasSeenWelcome --json",
    "history": "history [--limit n] — machine write operations recorded by this CLI (the GUI app keeps no history).\nExample: oneclip-agent history --limit 20 --json",
    "doctor": "doctor — checks the data root, archive readability, preference domains and what the CLI cannot verify (screen-recording permission).\nExample: oneclip-agent doctor --json",
    "verify": "verify — archive integrity: filename grammar, PNG signatures, no symlinks. Exit 2 when it fails.\nExample: oneclip-agent verify --json",
    "export": "export <id> --to <dir> [--dry-run] [--idempotency-key <k>] — copy a saved capture to a directory. Never overwrites.\nExample: oneclip-agent export <id> --to ~/Desktop/out --dry-run",
    "delete": "delete <id> --yes [--dry-run] [--idempotency-key <k>] — move a saved capture into Captures/.trash (recoverable). --yes is required.\nExample: oneclip-agent delete <id> --yes",
    "seed": "seed — create deterministic fixture captures in an explicit --root test directory. Refuses the real data root.\nExample: oneclip-agent seed --root /tmp/oneclip-test",
    "reset": "reset --test-data — remove fixtures and CLI history from a seeded test root. Requires the seed marker; refuses the real data root.\nExample: oneclip-agent reset --test-data --root /tmp/oneclip-test",
]

func parseOptions(_ args: [String]) throws -> (command: [String], options: Options) {
    var options = Options()
    var command: [String] = []
    var index = 0
    func value(after flag: String) throws -> String {
        guard index + 1 < args.count else {
            throw AgentError.invalidInput("\(flag) requires a value.")
        }
        index += 1
        return args[index]
    }
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--json": break
        case "--human": options.human = true
        case "--help", "-h": options.help = true
        case "--root": options.root = try value(after: arg)
        case "--timeout":
            let raw = try value(after: arg)
            guard let seconds = TimeInterval(raw), seconds > 0 else {
                throw AgentError.invalidInput("--timeout must be a positive number of seconds.")
            }
            options.timeout = seconds
        case "--dry-run": options.dryRun = true
        case "--yes": options.yes = true
        case "--idempotency-key": options.idempotencyKey = try value(after: arg)
        case "--to": options.destination = try value(after: arg)
        case "--bundle-id": options.bundleID = try value(after: arg)
        case "--limit":
            let raw = try value(after: arg)
            guard let limit = Int(raw), limit > 0 else {
                throw AgentError.invalidInput("--limit must be a positive integer.")
            }
            options.limit = limit
        case "--test-data": options.testData = true
        default:
            if arg.hasPrefix("--") {
                throw AgentError.invalidInput("Unknown flag: \(arg). See --help for supported flags.")
            }
            command.append(arg)
        }
        index += 1
    }
    return (command, options)
}

func printHuman(_ value: AgentJSONValue, indent: String = "") {
    switch value {
    case .object(let pairs):
        for (key, item) in pairs {
            switch item {
            case .array(let elements) where !elements.isEmpty && elements.allSatisfy({ if case .object = $0 { return true } else { return false } }):
                print("\(indent)\(key):")
                for element in elements {
                    print("\(indent)  -")
                    printHuman(element, indent: indent + "    ")
                }
            case .object:
                print("\(indent)\(key):")
                printHuman(item, indent: indent + "  ")
            case .array(let elements):
                print("\(indent)\(key): \(elements.map { describe($0) }.joined(separator: ", "))")
            default:
                print("\(indent)\(key): \(describe(item))")
            }
        }
    default:
        print("\(indent)\(describe(value))")
    }
}

func describe(_ value: AgentJSONValue) -> String {
    switch value {
    case .string(let text): return text
    case .int(let number): return String(number)
    case .double(let number): return String(number)
    case .bool(let flag): return flag ? "true" : "false"
    case .null: return "null"
    case .array(let elements): return "[\(elements.count) items]"
    case .object: return "{...}"
    }
}

func run(command: [String], options: Options, requestID: String) throws -> (AgentJSONValue, [(String, AgentJSONValue)]) {
    let rootURL = options.root.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? ProcessInfo.processInfo.environment["ONECLIP_AGENT_ROOT"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    let store = ArchiveStore(root: rootURL)
    let deadline = AgentDeadline(timeoutSeconds: options.timeout)
    let history = HistoryStore(store: store)
    let head = command.first ?? ""

    func requireID() throws -> String {
        guard options.positionals.count == 1, let raw = options.positionals.first else {
            throw AgentError.invalidInput("Exactly one <id> argument is required.")
        }
        guard UUID(uuidString: raw) != nil else {
            throw AgentError.invalidInput("<id> must be a UUID (the trailing part of a capture file name).")
        }
        return raw.lowercased()
    }

    /// Runs a write command with idempotency replay + history recording.
    func write(_ name: String, body: () throws -> AgentJSONValue) throws -> (AgentJSONValue, [(String, AgentJSONValue)]) {
        if let key = options.idempotencyKey, !options.dryRun,
           let prior = history.successfulEntry(idempotencyKey: key, command: name), let summary = prior.summary {
            return (summary, [("idempotent_replay", .bool(true))])
        }
        do {
            let result = try body()
            if !options.dryRun {
                history.append(command: name, requestID: requestID, ok: true, errorCode: nil,
                               idempotencyKey: options.idempotencyKey, summary: result)
            }
            return (result, [])
        } catch let error as AgentError {
            // A refused production-guard operation must not write anything
            // anywhere, including the history file.
            if !options.dryRun && error.code != .productionGuard {
                history.append(command: name, requestID: requestID, ok: false, errorCode: error.code.rawValue,
                               idempotencyKey: options.idempotencyKey, summary: nil)
            }
            throw error
        }
    }

    switch head {
    case "status":
        let scan = try store.scan(deadline: deadline)
        let totalBytes = scan.items.reduce(0) { $0 + $1.bytes }
        let edited = scan.items.filter { $0.kind == "edited" }.count
        let domains = PreferencesReader.bundleIDs.map { bundleID -> AgentJSONValue in
            .object([("bundle_id", .string(bundleID)),
                     ("present", .bool(PreferencesReader(store: store).domainExists(bundleID: bundleID)))])
        }
        let historyInfo = history.entries(limit: 0)
        return (.object([
            ("app", .string("OneClip")),
            ("app_version", .string(appVersion)),
            ("build", .string(appBuild)),
            ("agent_level", .int(agentLevel)),
            ("root", .string(store.root.path)),
            ("is_default_root", .bool(store.isDefaultRoot)),
            ("captures", .object([
                ("directory", .string(store.capturesDirectory.path)),
                ("exists", .bool(store.capturesDirectoryExists)),
                ("count", .int(scan.items.count)),
                ("edited_count", .int(edited)),
                ("total_bytes", .int(totalBytes)),
                ("trashed_count", .int(store.trashedCount())),
            ])),
            ("preferences", .object([("domains", .array(domains))])),
            ("history", .object([
                ("available", .bool(history.isAvailable)),
                ("entries", .int(historyInfo.entries.count)),
            ])),
        ]), [])

    case "list":
        let scan = try store.scan(deadline: deadline)
        return (.object([
            ("items", .array(scan.items.map { $0.jsonObject() })),
            ("count", .int(scan.items.count)),
            ("nonconforming_count", .int(scan.nonconformingNames.count)),
            ("symlink_count", .int(scan.symlinkNames.count)),
        ]), [])

    case "get":
        let item = try store.item(id: try requireID(), deadline: deadline)
        var pairs: [(String, AgentJSONValue)] = []
        if case .object(let itemPairs) = item.jsonObject() { pairs = itemPairs }
        pairs.append(("path", .string(store.capturesDirectory.appendingPathComponent(item.fileName).path)))
        pairs.append(("png_signature_valid", .bool(store.hasValidPNGSignature(item))))
        return (.object(pairs), [])

    case "settings":
        let reader = PreferencesReader(store: store)
        let sub = command.count > 1 ? command[1] : ""
        let domain = try reader.loadDomain(bundleID: options.bundleID)
        switch sub {
        case "list":
            var entries: [AgentJSONValue] = []
            for known in PreferencesReader.knownKeys {
                if let value = domain[known.key] {
                    entries.append(.object([("key", .string(known.key)), ("present", .bool(true)),
                                            ("kind", .string(known.kind)),
                                            ("value", PreferencesReader.render(value: value))]))
                } else {
                    entries.append(.object([("key", .string(known.key)), ("present", .bool(false)),
                                            ("kind", .string(known.kind))]))
                }
            }
            let knownSet = Set(PreferencesReader.knownKeys.map { $0.key })
            for key in domain.keys.sorted() where !knownSet.contains(key) {
                entries.append(.object([("key", .string(key)), ("present", .bool(true)),
                                        ("kind", .string(PreferencesReader.typeName(of: domain[key]!)))]))
            }
            return (.object([("bundle_id", .string(options.bundleID)), ("entries", .array(entries))]), [])
        case "get":
            guard options.positionals.count == 1, let key = options.positionals.first else {
                throw AgentError.invalidInput("settings get requires exactly one <key>.")
            }
            guard let value = domain[key] else {
                throw AgentError.notFound("Key not present in \(options.bundleID): \(key)",
                                          details: ["key": .string(key)])
            }
            return (.object([("bundle_id", .string(options.bundleID)), ("key", .string(key)),
                             ("value", PreferencesReader.render(value: value))]), [])
        default:
            throw AgentError.invalidInput("settings requires a subcommand: list or get.")
        }

    case "history":
        let result = history.entries(limit: options.limit)
        return (.object([
            ("entries", .array(result.entries.map { $0.jsonObject() })),
            ("count", .int(result.entries.count)),
            ("skipped_lines", .int(result.skippedLines)),
            ("scope", .string("Machine write operations by this CLI only. The GUI app keeps no persistent history.")),
        ]), [])

    case "doctor":
        var checks: [AgentJSONValue] = []
        func check(_ name: String, _ status: String, _ detail: String, _ hint: String? = nil) {
            var pairs: [(String, AgentJSONValue)] = [("name", .string(name)), ("status", .string(status)),
                                                     ("detail", .string(detail))]
            if let hint { pairs.append(("hint", .string(hint))) }
            checks.append(.object(pairs))
        }
        if store.capturesDirectoryExists {
            check("captures_directory", "ok", store.capturesDirectory.path)
        } else {
            check("captures_directory", "warn", "Captures directory does not exist yet.",
                  "It is created when the app first saves a capture.")
        }
        do {
            _ = try store.scan(deadline: deadline)
            check("captures_readable", "ok", "The archive can be scanned.")
        } catch let error as AgentError {
            check("captures_readable", "fail", error.message)
        }
        let reader = PreferencesReader(store: store)
        let found = PreferencesReader.bundleIDs.filter { reader.domainExists(bundleID: $0) }
        if found.isEmpty {
            check("preferences_domain", "warn", "No preferences domain found for any known bundle ID.",
                  "The app may not have run on this data root yet.")
        } else {
            check("preferences_domain", "ok", "Found: \(found.joined(separator: ", "))")
        }
        check("screen_recording_permission", "unknown",
              "The CLI cannot inspect the macOS screen-recording permission (TCC).",
              "The app itself shows the permission state in its permission screen.")
        #if os(macOS)
        let appCandidates = ["/Applications/OneClip.app",
                             FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/OneClip.app").path]
        if appCandidates.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            check("app_bundle", "ok", "OneClip.app is installed.")
        } else {
            check("app_bundle", "unknown", "OneClip.app was not found in the standard locations; the CLI can still inspect a data root.")
        }
        #else
        check("app_bundle", "unknown", "Not running on macOS; app bundle presence cannot be checked.")
        #endif
        if history.isAvailable {
            check("history_file", "ok", "Machine operation history exists.")
        } else {
            check("history_file", "warn", "No machine write operations have been recorded yet.")
        }
        func checksContain(status wanted: String) -> Bool {
            checks.contains { entry in
                guard case .object(let pairs) = entry else { return false }
                return pairs.contains { $0.0 == "status" && $0.1 == .string(wanted) }
            }
        }
        let hasFail = checksContain(status: "fail")
        let hasWarn = checksContain(status: "warn")
        let overall = hasFail ? "fail" : (hasWarn ? "warn" : "ok")
        if hasFail {
            throw AgentError(code: .appFailure, message: "doctor found failing checks.",
                             exitCode: .appFailure,
                             details: ["checks": .array(checks), "overall": .string(overall)])
        }
        return (.object([("checks", .array(checks)), ("overall", .string(overall))]), [])

    case "verify":
        let scan = try store.scan(deadline: deadline)
        var failures: [AgentJSONValue] = []
        var warnings: [AgentJSONValue] = []
        for name in scan.symlinkNames {
            failures.append(.object([("file", .string(name)), ("reason", .string("symlink_in_archive"))]))
        }
        for item in scan.items {
            try deadline.check()
            if !store.hasValidPNGSignature(item) {
                failures.append(.object([("file", .string(item.fileName)), ("reason", .string("invalid_png_signature"))]))
            }
        }
        for name in scan.nonconformingNames {
            warnings.append(.object([("file", .string(name)), ("reason", .string("name_outside_archive_grammar"))]))
        }
        let result = failures.isEmpty ? "pass" : "fail"
        let data: AgentJSONValue = .object([
            ("result", .string(result)),
            ("checked", .int(scan.items.count)),
            ("failures", .array(failures)),
            ("warnings", .array(warnings)),
            ("trashed_count", .int(store.trashedCount())),
        ])
        if !failures.isEmpty {
            throw AgentError(code: .appFailure, message: "Archive verification failed.",
                             exitCode: .appFailure,
                             details: ["result": .string(result), "failures": .array(failures),
                                       "warnings": .array(warnings), "checked": .int(scan.items.count)])
        }
        return (data, [])

    case "export":
        let id = try requireID()
        guard let destinationRaw = options.destination else {
            throw AgentError.invalidInput("export requires --to <dir>.")
        }
        let destination = URL(fileURLWithPath: (destinationRaw as NSString).expandingTildeInPath, isDirectory: true)
        return try write("export") {
            let item = try store.item(id: id, deadline: deadline)
            if options.dryRun {
                return .object([("id", .string(item.id)), ("file_name", .string(item.fileName)),
                                ("destination", .string(destination.appendingPathComponent(item.fileName).path)),
                                ("bytes", .int(item.bytes)), ("dry_run", .bool(true))])
            }
            let target = try store.export(item: item, toDirectory: destination)
            return .object([("id", .string(item.id)), ("file_name", .string(item.fileName)),
                            ("destination", .string(target.path)), ("bytes", .int(item.bytes)),
                            ("dry_run", .bool(false))])
        }

    case "delete":
        let id = try requireID()
        if !options.dryRun && !options.yes {
            throw AgentError(code: .confirmationRequired,
                             message: "delete is destructive. Re-run with --yes to confirm, or --dry-run to preview.",
                             exitCode: .invalidInput)
        }
        return try write("delete") {
            let item = try store.item(id: id, deadline: deadline)
            if options.dryRun {
                return .object([("id", .string(item.id)), ("file_name", .string(item.fileName)),
                                ("trash_path", .string(".trash/\(item.fileName)")), ("dry_run", .bool(true))])
            }
            let trashPath = try store.quarantine(item: item)
            return .object([("id", .string(item.id)), ("file_name", .string(item.fileName)),
                            ("trash_path", .string(trashPath)), ("dry_run", .bool(false))])
        }

    case "seed":
        return try write("seed") {
            if options.dryRun {
                try TestFixtures.guardNotDefaultRoot(store)
                return .object([("would_create", .array(TestFixtures.fileNames.map { .string($0) })),
                                ("dry_run", .bool(true))])
            }
            let result = try TestFixtures.seed(store: store)
            return .object([("created", .array(result.created.map { .string($0) })),
                            ("skipped_existing", .array(result.skipped.map { .string($0) })),
                            ("dry_run", .bool(false))])
        }

    case "reset":
        guard options.testData else {
            throw AgentError.invalidInput("reset requires --test-data. It only clears roots created by seed.")
        }
        return try write("reset") {
            if options.dryRun {
                try TestFixtures.guardNotDefaultRoot(store)
                let scan = try store.scan(deadline: deadline)
                return .object([("would_remove_items", .int(scan.items.count)), ("dry_run", .bool(true))])
            }
            let removed = try TestFixtures.reset(store: store)
            return .object([("removed_entries", .int(removed)), ("dry_run", .bool(false))])
        }

    default:
        throw AgentError.invalidInput("Unknown command: \(head.isEmpty ? "(none)" : head). See --help.")
    }
}

// MARK: - Entry point

let requestID = UUID().uuidString.lowercased()
let rawArgs = Array(CommandLine.arguments.dropFirst())

do {
    let (command, options) = try parseOptions(rawArgs)
    if options.help || command.isEmpty {
        if let head = command.first, let help = commandHelp[head] {
            print(help)
        } else {
            print(globalHelp)
        }
        exit(AgentExitCode.success.rawValue)
    }
    var adjusted = options
    if command.first == "settings" {
        adjusted.positionals = Array(command.dropFirst(2))
    } else {
        adjusted.positionals = Array(command.dropFirst())
    }
    let (data, extraMeta) = try run(command: command, options: adjusted, requestID: requestID)
    if adjusted.human {
        printHuman(data)
    } else {
        FileHandle.standardOutput.write(AgentEnvelope.success(data: data, requestID: requestID, extraMeta: extraMeta))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
    exit(AgentExitCode.success.rawValue)
} catch let error as AgentError {
    if rawArgs.contains("--human") {
        FileHandle.standardError.write("error [\(error.code.rawValue)]: \(error.message)\n".data(using: .utf8)!)
        // doctor/verify carry structured detail in JSON mode; in human mode, print it too.
        if !error.details.isEmpty {
            printHuman(.object(error.details.sorted { $0.key < $1.key }))
        }
    } else {
        FileHandle.standardOutput.write(AgentEnvelope.failure(error: error, requestID: requestID))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
    exit(error.exitCode.rawValue)
} catch {
    let wrapped = AgentError.appFailure("Unexpected failure: \(error.localizedDescription)")
    FileHandle.standardOutput.write(AgentEnvelope.failure(error: wrapped, requestID: requestID))
    FileHandle.standardOutput.write(Data([0x0A]))
    exit(AgentExitCode.appFailure.rawValue)
}
