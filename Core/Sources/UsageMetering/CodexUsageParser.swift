import Foundation
import TranscriptSupport

/// Reconciles local cumulative token observations. Persisting the observations
/// makes copied files, out-of-order backfill and counter resets reproducible.
/// No conversational fields are retained.
public struct CodexUsageParser: Sendable {
    public struct Context: Codable, Equatable, Sendable {
        public var sessionID: String
        public var model: String
        /// Explicit owner of the latest response, including inherited records.
        public var responseThreadID: String? = nil
    }
    public struct Observation: Codable, Equatable, Sendable {
        public var timestamp: Date
        public var model: String
        public var total: TokenTotals
        public var last: TokenTotals?

        var identity: String {
            "\(timestamp.timeIntervalSince1970):\(total.input):\(total.output):\(total.cacheCreation):\(total.cacheRead)"
        }
    }
    public struct State: Codable, Equatable, Sendable {
        public var contexts: [String: Context] = [:]
        // Retained for decoding schema-2 stores before their backed-up rebuild.
        public var totals: [String: TokenTotals] = [:]
        public var observations: [String: [Observation]]? = [:]
        public var unresolvedBySession: [String: Int]? = [:]
        /// Response records have their own stable identity and include usage
        /// (for example compaction) absent from the legacy context counters.
        public var responses: [String: UsageRecord]? = [:]
        public var responseIssues: Set<String>? = []
        public init() {}
    }
    public private(set) var state: State
    private var responseStarts: [String: Date] = [:]
    public var unresolvedRecordCount: Int {
        (state.unresolvedBySession?.values.reduce(0, +) ?? 0) + (state.responseIssues?.count ?? 0)
    }
    public init(state: State = State()) {
        self.state = state
        for record in state.responses?.values ?? Dictionary<String, UsageRecord>().values {
            responseStarts[record.sessionID] = min(responseStarts[record.sessionID] ?? record.timestamp, record.timestamp)
        }
    }

    /// Convenience for ordered single-event callers. Production uses the batch
    /// API because backfill can correct an already-accounted neighboring event.
    public mutating func parse(line: String, path: String) -> UsageRecord? {
        parseRecords(line: line, path: path).first
    }

    /// A replaced/truncated rollout starts a new canonical header at this path.
    public mutating func resetContext(path: String) { state.contexts.removeValue(forKey: path) }

    public mutating func parseRecords(line: String, path: String) -> [UsageRecord] {
        guard line.contains("session_meta") || line.contains("turn_context") || line.contains("token_count") || line.contains("token_usage_record"),
              let data = line.data(using: .utf8), JSONDepth.isWithin(64, data),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = record["type"] as? String,
              let payload = record["payload"] as? [String: Any] else { return [] }
        if kind == "session_meta" {
            // session_id groups a root and its subagents; id owns the counter.
            // Forks may copy parent metadata after their canonical first header.
            guard state.contexts[path] == nil,
                  let id = (payload["id"] ?? payload["session_id"]) as? String, !id.isEmpty else { return [] }
            state.contexts[path] = Context(sessionID: id, model: "Unknown Codex model")
            return []
        }
        if kind == "token_usage_record" {
            return parseResponse(payload, timestamp: record["timestamp"], path: path)
        }
        if kind == "turn_context" {
            guard var context = state.contexts[path], let model = payload["model"] as? String, !model.isEmpty else { return [] }
            context.model = model
            state.contexts[path] = context
            return []
        }
        guard kind == "event_msg", payload["type"] as? String == "token_count",
              let context = state.contexts[path],
              let timestamp = record["timestamp"] as? String,
              let date = ISO8601UTCTimestamp.date(from: timestamp),
              let info = payload["info"] as? [String: Any],
              let usage = info["total_token_usage"] as? [String: Any],
              let total = normalized(usage) else { return [] }
        // A modern response stream replaces overlapping legacy counters, not
        // older history from before this thread began emitting response records.
        if let start = responseStarts[context.responseThreadID ?? context.sessionID], date >= start { return [] }
        let last = (info["last_token_usage"] as? [String: Any]).flatMap(normalized)
        let observation = Observation(timestamp: date, model: context.model, total: total, last: last)
        var observations = state.observations?[context.sessionID] ?? []
        let before: Reconciliation
        if let index = observations.firstIndex(where: { $0.identity == observation.identity }) {
            // A duplicate may supply missing last-call evidence. Otherwise it
            // changes no usage, regardless of the file it was copied into.
            guard observations[index].last == nil, last != nil else { return [] }
            before = reconcile(observations, session: context.sessionID)
            observations[index].last = last
        } else {
            before = reconcile(observations, session: context.sessionID)
            observations.append(observation)
            observations.sort {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                if $0.total.total != $1.total.total { return $0.total.total < $1.total.total }
                return $0.identity < $1.identity
            }
        }
        let after = reconcile(observations, session: context.sessionID)
        if state.observations == nil { state.observations = [:] }
        if state.unresolvedBySession == nil { state.unresolvedBySession = [:] }
        state.observations?[context.sessionID] = observations
        state.unresolvedBySession?[context.sessionID] = after.unresolved
        state.totals[context.sessionID] = after.lastTotal
        var changes = after.records.values.filter { before.records[$0.messageID] != $0 }
        for (id, record) in before.records where after.records[id] == nil {
            var removed = record
            removed.tokens = TokenTotals()
            changes.append(removed)
        }
        return changes.sorted { ($0.timestamp, $0.messageID) < ($1.timestamp, $1.messageID) }
    }

    private struct Reconciliation {
        var records: [String: UsageRecord] = [:]
        var lastTotal = TokenTotals()
        var unresolved = 0
    }

    private mutating func parseResponse(_ payload: [String: Any], timestamp: Any?, path: String) -> [UsageRecord] {
        guard let thread = payload["thread_id"] as? String, !thread.isEmpty,
              let response = payload["response_id"] as? String, !response.isEmpty,
              let timestamp = timestamp as? String,
              let date = ISO8601UTCTimestamp.date(from: timestamp),
              let usage = payload["usage"] as? [String: Any],
              let tokens = normalized(usage) else { return [] }
        state.contexts[path]?.responseThreadID = thread
        // Explicit thread ownership also handles parent responses copied into
        // a child's rollout. Neither the file path nor root session is a key.
        let id = "codex-response:\(thread):\(response)"
        var record = UsageRecord(sessionID: thread, messageID: id, requestID: response,
            model: state.contexts[path]?.model ?? "Unknown Codex model", timestamp: date, tokens: tokens)
        if let previous = state.responses?[id] {
            if previous.tokens != record.tokens {
                if state.responseIssues == nil { state.responseIssues = [] }
                state.responseIssues?.insert(id)
            }
            // A copied record can have a new outer timestamp. Keep the original
            // date and one complete usage value, never add both copies.
            if previous.tokens.total >= record.tokens.total { record = previous }
            record.timestamp = min(previous.timestamp, date)
            if previous == record { return [] }
        }
        var changes: [UsageRecord] = []
        if responseStarts[thread].map({ date < $0 }) ?? true {
            let observations = state.observations?[thread] ?? []
            let before = reconcile(observations, session: thread)
            let retained = observations.filter { $0.timestamp < date }
            let after = reconcile(retained, session: thread)
            for (id, old) in before.records where after.records[id] == nil {
                var removed = old
                removed.tokens = TokenTotals()
                changes.append(removed)
            }
            changes += after.records.values.filter { before.records[$0.messageID] != $0 }
            if state.observations == nil { state.observations = [:] }
            if state.unresolvedBySession == nil { state.unresolvedBySession = [:] }
            state.observations?[thread] = retained
            state.unresolvedBySession?[thread] = after.unresolved
            state.totals[thread] = after.lastTotal
            responseStarts[thread] = date
        }
        if state.responses == nil { state.responses = [:] }
        state.responses?[id] = record
        changes.append(record)
        return changes
    }

    private func reconcile(_ observations: [Observation], session: String) -> Reconciliation {
        var result = Reconciliation()
        var previousTime: Date?
        for observation in observations {
            let total = observation.total
            let previous = result.lastTotal
            guard total != previous else { continue } // quota-only re-emission
            let delta: TokenTotals
            // The first completed response in a new segment has total == last.
            // Require forward time: a replay isn't a new segment. File copies
            // with original timestamps have already collapsed by identity.
            if previous.total > 0, total.total > 0, observation.last == total,
               previousTime.map({ observation.timestamp > $0 }) == true {
                delta = total
            } else if total.input >= previous.input, total.output >= previous.output,
                      total.cacheRead >= previous.cacheRead, total.cacheCreation >= previous.cacheCreation {
                var growth = total
                growth -= previous
                delta = growth
            } else {
                result.unresolved += 1
                continue
            }
            result.lastTotal = total
            previousTime = observation.timestamp
            guard delta.total > 0 else { continue }
            let id = "codex:\(session):\(observation.identity)"
            result.records[id] = UsageRecord(sessionID: session, messageID: id, requestID: nil,
                model: observation.model, timestamp: observation.timestamp, tokens: delta)
        }
        return result
    }

    private func normalized(_ usage: [String: Any]) -> TokenTotals? {
        guard let input = JSON.nonNegativeInteger(usage["input_tokens"]),
              let output = JSON.nonNegativeInteger(usage["output_tokens"]),
              let cached = optionalCount(usage["cached_input_tokens"]),
              let written = optionalCount(usage["cache_write_input_tokens"]),
              cached <= input, written <= input - cached,
              input <= Int.max / 4, output <= Int.max / 4 else { return nil }
        // Cache is part of input; reasoning is part of output. Each counts once.
        return TokenTotals(input: input - cached - written, output: output,
                           cacheCreation: written, cacheRead: cached)
    }

    private func optionalCount(_ value: Any?) -> Int? {
        guard let value else { return 0 }
        return JSON.nonNegativeInteger(value)
    }
}
