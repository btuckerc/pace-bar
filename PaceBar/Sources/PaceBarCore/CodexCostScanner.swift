import Foundation

/// T3-compatible Codex reducer and guarded append-only reader. Only usage metadata survives a scan.
struct CodexCostScanner {
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()
    private static let markers = ["\"token_count\"", "\"turn_context\"", "\"session_meta\""].map { Data($0.utf8) }

    /// OMP revision 2 retains Anthropic subscription usage; earlier OMP scans discarded it.
    static func version(for provider: String) -> Int {
        provider == "omp" ? 2 : 1
    }

    init() {
        self.fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func read(
        file: URL, previous: CodexHistoryFile?, size: Int, mtimeMs: Double,
        budget: inout Int, provider: String = "codex")
        -> CodexHistoryFile?
    {
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var result = CodexHistoryFile(
                size: size, mtimeMs: mtimeMs, provider: provider, records: [], tail: [],
                offset: 0, guardLength: 0, guardHash: 0, state: CodexHistoryState(),
                scanVersion: Self.version(for: provider))
            if let previous, previous.provider == provider, previous.state != nil,
               previous.scanVersion == Self.version(for: provider),
               size > previous.size || previous.pendingScan, size >= previous.offset,
               previous.offset > 0, previous.guardLength > 0,
               try self.guardMatches(handle, previous)
            {
                result = previous
                result.size = size
                result.mtimeMs = mtimeMs
                result.tail = []
            }
            result.pendingScan = false
            var state = result.state ?? CodexHistoryState()
            // T3 stores JSON.stringify order; normalize only for equality, never alter token values.
            if let signature = state.lastUsageSignature,
               let object = try? JSONSerialization.jsonObject(with: Data(signature.utf8)) as? [String: Any]
            {
                state.lastUsageSignature = Self.signature(object)
            }
            try handle.seek(toOffset: UInt64(result.offset))
            var position = result.offset
            var pending = Data()
            var discarding = false
            while position < size, budget > 0, !Task.isCancelled {
                // FileHandle/JSONSerialization bridge autoreleased Foundation objects. Drain each chunk,
                // not the entire multi-gigabyte onboarding task.
                let progressed = try autoreleasepool { () throws -> Bool in
                    let count = min(65536, size - position, budget)
                    guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { return false }
                    position += chunk.count
                    budget -= chunk.count
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 10) {
                        if !discarding, let event = self
                            .consume(
                                pending[..<newline],
                                state: &state,
                                incomplete: &result.incomplete,
                                provider: provider)
                        {
                            result.records.append(event)
                        }
                        pending.removeSubrange(...newline)
                        result.offset = position - pending.count
                        discarding = false
                    }
                    if pending.count > 2 * 1024 * 1024 {
                        pending.removeAll(keepingCapacity: true)
                        discarding = true
                        result.incomplete = true
                    }
                    return true
                }
                guard progressed else { return nil }
            }
            result.state = state
            result.pendingScan = position < size
            if !result.pendingScan, !discarding, !pending.isEmpty {
                var tailState = state
                var tailIncomplete = false
                if let event = self.consume(
                    pending,
                    state: &tailState,
                    incomplete: &tailIncomplete,
                    provider: provider)
                {
                    result.tail = [event]
                }
                // An unfinished trailing JSON object is normal for an active writer. It is reread next time.
            }
            result.guardLength = min(64, result.offset)
            try handle.seek(toOffset: UInt64(result.offset - result.guardLength))
            let guardBytes = try handle.read(upToCount: result.guardLength) ?? Data()
            guard guardBytes.count == result.guardLength else { return nil }
            result.guardHash = Self.hash(guardBytes)
            return result
        } catch { return nil }
    }

    private func guardMatches(_ handle: FileHandle, _ file: CodexHistoryFile) throws -> Bool {
        try handle.seek(toOffset: UInt64(file.offset - file.guardLength))
        let bytes = try handle.read(upToCount: file.guardLength) ?? Data()
        return bytes.count == file.guardLength && Self.hash(bytes) == file.guardHash
    }

    private static func hash(_ bytes: Data) -> UInt32 {
        var value: UInt32 = 0x811C_9DC5
        for byte in bytes {
            value = (value ^ UInt32(byte)) &* 0x0100_0193
        }
        return value
    }

    private func consume(
        _ line: Data,
        state: inout CodexHistoryState,
        incomplete: inout Bool,
        provider: String) -> CodexHistoryEvent?
    {
        if provider == "omp" { return self.consumeOMP(line, state: &state, incomplete: &incomplete) }
        guard Self.markers.contains(where: { line.range(of: $0) != nil }) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { incomplete = true; return nil }
        if object["type"] as? String == "session_meta" {
            guard !state.sawSessionMeta else { return nil }
            state.sawSessionMeta = true
            state.sessionId = payload["id"] as? String ?? payload["session_id"] as? String ?? ""
            let spawn =
                ((payload["source"] as? [
                    String: Any
                ])?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any]
            if payload["forked_from_id"] is String || spawn?["parent_thread_id"] is String {
                if let date = self.date(object["timestamp"]) {
                    state.suppressingForkCopies = true
                    state.forkCopyAnchorMs = date.timeIntervalSince1970 * 1000
                } else { incomplete = true }
            }
            return nil
        }
        if object["type"] as? String == "turn_context" {
            if let model = payload["model"] as? String { state.model = model }
            return nil
        }
        guard payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any] else { return nil }
        guard let last = info["last_token_usage"] as? [String: Any],
              let timestamp = self.date(object["timestamp"]),
              !state.model.isEmpty else { incomplete = true; return nil }
        let signature = Self.signature(last)
        guard signature != state.lastUsageSignature else { return nil }
        state.lastUsageSignature = signature
        let milliseconds = timestamp.timeIntervalSince1970 * 1000
        if state.suppressingForkCopies {
            if milliseconds - state.forkCopyAnchorMs < 1000 {
                state.forkCopyAnchorMs = milliseconds
                return nil
            }
            state.suppressingForkCopies = false
        }
        guard let input = Self.number(last["input_tokens"] ?? 0),
              let cached = Self.number(last["cached_input_tokens"] ?? 0),
              let written = Self.number(last["cache_write_input_tokens"] ?? 0),
              let output = Self.number(last["output_tokens"] ?? 0),
              let reasoning = Self.number(last["reasoning_output_tokens"] ?? 0) else { incomplete = true; return nil }
        // Match T3's separate uncached/cache columns even for inconsistent inclusive totals.
        let inclusive = max(0, input - cached - written) + cached + written
        guard inclusive > 0 || output > 0 else { return nil }
        return CodexHistoryEvent(
            timestampMs: milliseconds, model: state.model, sessionID: state.sessionId,
            tokens: APICostTokens(input: inclusive, cachedInput: cached, cacheWrite: written, output: output),
            reasoning: min(reasoning, output), dedupeKey: nil, reportedCost: nil)
    }

    private func consumeOMP(
        _ line: Data,
        state: inout CodexHistoryState,
        incomplete: inout Bool) -> CodexHistoryEvent?
    {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            if !line.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) { incomplete = true }
            return nil
        }
        if object["type"] as? String == "session" {
            state.sessionId = object["id"] as? String ?? ""
            return nil
        }
        guard object["type"] as? String == "message",
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "assistant" else { return nil }
        guard let provider = message["provider"] as? String else { incomplete = true; return nil }
        let vendor: APICostVendor
        switch provider {
        case "openai-codex", "openai": vendor = .openAI
        // Only direct Anthropic sign-ins; Claude through OpenRouter or Antigravity bills elsewhere.
        case "anthropic": vendor = .anthropic
        default: return nil
        }
        guard let usage = message["usage"] as? [String: Any],
              let input = Self.number(usage["input"]),
              let output = Self.number(usage["output"]),
              let cached = Self.number(usage["cacheRead"] ?? 0),
              let written = Self.number(usage["cacheWrite"] ?? 0),
              let model = message["model"] as? String, !model.isEmpty
        else { incomplete = true; return nil }
        let ttl = usage["cttl"] as? [String: Any]
        guard let long = Self.number(ttl?["ephemeral1h"] ?? 0) else { incomplete = true; return nil }
        let timestamp = Self.number(message["timestamp"])
            ?? self.date(message["timestamp"]).map { $0.timeIntervalSince1970 * 1000 }
            ?? self.date(object["timestamp"]).map { $0.timeIntervalSince1970 * 1000 }
        guard let milliseconds = timestamp, milliseconds.isFinite, milliseconds > 0 else {
            incomplete = true
            return nil
        }
        let inclusive = input + cached + written
        guard inclusive.isFinite else { incomplete = true; return nil }
        guard inclusive > 0 || output > 0 else { return nil }
        let identity: String
        if let response = message["responseId"] as? String, !response.isEmpty {
            identity = "omp:response:\(response)"
        } else {
            guard let id = object["id"] as? String, !id.isEmpty else { incomplete = true; return nil }
            // Forks retain message IDs; timestamps and usage prevent unrelated short IDs from colliding.
            identity = [
                "omp:message",
                id,
                String(milliseconds),
                model,
                String(input),
                String(cached),
                String(written),
                String(output),
            ].joined(separator: "|")
        }
        return CodexHistoryEvent(
            timestampMs: milliseconds, model: model, sessionID: state.sessionId,
            tokens: APICostTokens(
                input: inclusive, cachedInput: cached, cacheWrite: written, cacheWriteLong: min(long, written),
                output: output),
            reasoning: 0, dedupeKey: identity, reportedCost: nil, vendor: vendor)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return floor(number.doubleValue)
    }

    private static func signature(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return self.fractional.date(from: text) ?? self.plain.date(from: text)
    }
}
