import Foundation

struct CodexHistoryEvent: Sendable {
    var timestampMs: Double
    var model: String
    var sessionID: String
    var tokens: APICostTokens
    var reasoning: Double
    var dedupeKey: String?
    var reportedCost: Double?
    var vendor: APICostVendor = .openAI
}

struct CodexHistoryState: Codable, Sendable {
    var model = ""
    var sessionId = ""
    var lastUsageSignature: String?
    var sawSessionMeta = false
    var suppressingForkCopies = false
    var forkCopyAnchorMs: Double = 0
}

struct CodexHistoryFile: Sendable {
    var size: Int
    var mtimeMs: Double
    var provider: String
    var records: [CodexHistoryEvent]
    var tail: [CodexHistoryEvent]
    var offset: Int
    var guardLength: Int
    var guardHash: UInt32
    var state: CodexHistoryState?
    var incomplete = false
    var pendingScan = false
    /// Reducer revision that produced `records`; an older revision is rescanned from the start.
    var scanVersion = 1
}

/// T3 v3's compact interned representation, with optional Pace Bar provenance/checkpoint fields.
/// Keeping records unfiltered is intentional: importing a 30-day display must not destroy older history.
/// Pace Bar appends two optional row columns after T3's ten: one-hour cache writes and the API vendor.
struct CodexHistoryArchive: Sendable {
    var files: [String: CodexHistoryFile] = [:]
    var importedT3 = false
    var t3Stamp: String?
    private static let limit = 128 * 1024 * 1024

    static func read(_ url: URL) throws -> Self {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.limit + 1) ?? Data()
        guard data.count <= Self.limit else { throw UsageError.oversized }
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= self.limit,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              integer(root["version"]) == 3,
              let models = root["models"] as? [String], let sessions = root["sessions"] as? [String],
              let entries = root["files"] as? [String: [String: Any]] else { throw self.invalid }
        var archive = Self()
        archive.importedT3 = root["paceBarImportedT3"] as? Bool ?? false
        archive.t3Stamp = root["paceBarT3Stamp"] as? String
        for (path, entry) in entries {
            guard path.hasPrefix("/"),
                  let size = Self.integer(entry["s"]), let modified = Self.number(entry["m"]),
                  let provider = entry["p"] as? String, ["codex", "omp", "claude", "grok"].contains(provider),
                  let rows = entry["r"] as? [[Any]], let tailRows = entry["t"] as? [[Any]],
                  let offset = Self.integer(entry["o"]), offset <= size,
                  let length = Self.integer(entry["gl"]), length <= 64, length <= offset,
                  let hash = Self.integer(entry["gh"]), hash <= Int(UInt32.max) else { throw Self.invalid }
            let state: CodexHistoryState?
            if let raw = entry["cs"] as? [String: Any] {
                state = try JSONDecoder().decode(
                    CodexHistoryState.self,
                    from: JSONSerialization.data(withJSONObject: raw))
                guard state?.forkCopyAnchorMs.isFinite == true else { throw Self.invalid }
            } else { state = nil }
            guard provider != "codex" || state != nil else { throw Self.invalid }
            archive.files[path] = try CodexHistoryFile(
                size: size, mtimeMs: modified, provider: provider,
                records: rows.map { try Self.event($0, models: models, sessions: sessions) },
                tail: tailRows.map { try Self.event($0, models: models, sessions: sessions) },
                offset: offset, guardLength: length, guardHash: UInt32(hash), state: state,
                incomplete: entry["paceBarIncomplete"] as? Bool ?? false,
                pendingScan: entry["paceBarPendingScan"] as? Bool ?? false,
                scanVersion: Self.integer(entry["paceBarScanVersion"]) ?? 1)
        }
        return archive
    }

    private static func event(_ row: [Any], models: [String], sessions: [String]) throws -> CodexHistoryEvent {
        guard row.count >= 10, let timestamp = number(row[0]),
              let modelIndex = integer(row[1]), models.indices.contains(modelIndex),
              let uncached = number(row[3]), let cached = number(row[4]),
              let written = number(row[5]), let output = number(row[6]), let reasoning = number(row[7]),
              (uncached + cached + written).isFinite,
              row[8] is NSNull || row[8] is String,
              row[9] is NSNull || number(row[9]) != nil else { throw self.invalid }
        let long = row.count > 10 ? Self.number(row[10]) : 0
        let vendor = row.count > 11 ? (row[11] as? String).flatMap(APICostVendor.init(rawValue:)) : .openAI
        guard let long, long <= written, let vendor else { throw self.invalid }
        let sessionIndex = Self.integer(row[2])
        let session = sessionIndex.flatMap { sessions.indices.contains($0) ? sessions[$0] : nil } ?? ""
        return CodexHistoryEvent(
            timestampMs: timestamp, model: models[modelIndex], sessionID: session,
            tokens: APICostTokens(
                input: uncached + cached + written,
                cachedInput: cached,
                cacheWrite: written,
                cacheWriteLong: long,
                output: output),
            reasoning: reasoning, dedupeKey: row[8] as? String, reportedCost: Self.number(row[9]), vendor: vendor)
    }

    func write(to url: URL) throws {
        var models: [String] = []
        var sessions: [String] = []
        var modelIndexes: [String: Int] = [:]
        var sessionIndexes: [String: Int] = [:]
        func rows(_ events: [CodexHistoryEvent]) -> [[Any]] {
            events.map { event in
                let modelIndex = modelIndexes[event.model] ?? models.count
                if modelIndex == models.count {
                    modelIndexes[event.model] = modelIndex
                    models.append(event.model)
                }
                let sessionIndex = sessionIndexes[event.sessionID] ?? sessions.count
                if sessionIndex == sessions.count {
                    sessionIndexes[event.sessionID] = sessionIndex
                    sessions.append(event.sessionID)
                }
                let tokens = event.tokens
                return [
                    event.timestampMs, modelIndex, sessionIndex,
                    max(0, tokens.input - tokens.cachedInput - tokens.cacheWrite), tokens.cachedInput,
                    tokens.cacheWrite,
                    tokens.output, event.reasoning, event.dedupeKey as Any? ?? NSNull(),
                    event.reportedCost as Any? ?? NSNull(), tokens.cacheWriteLong, event.vendor.rawValue,
                ]
            }
        }
        var entries: [String: Any] = [:]
        for (path, entry) in self.files {
            let state: Any = try entry.state
                .map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()
            entries[path] = [
                "s": entry.size, "m": entry.mtimeMs, "p": entry.provider, "r": rows(entry.records),
                "t": rows(entry.tail),
                "o": entry.offset, "gl": entry.guardLength, "gh": entry.guardHash, "cs": state,
                "paceBarIncomplete": entry.incomplete, "paceBarPendingScan": entry.pendingScan,
                "paceBarScanVersion": entry.scanVersion,
            ] as [String: Any]
        }
        var root: [String: Any] = [
            "version": 3, "models": models, "sessions": sessions, "files": entries,
            "paceBarImportedT3": self.importedT3,
        ]
        if let stamp = self.t3Stamp { root["paceBarT3Stamp"] = stamp }
        let data = try JSONSerialization.data(withJSONObject: root)
        guard data.count <= Self.limit else { throw UsageError.oversized }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static var invalid: UsageError {
        .message("Unrecognized or incomplete T3 usage-history cache.")
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = Self.number(value), number.rounded(.down) == number,
              number < Double(Int.max) else { return nil }
        return Int(number)
    }
}
