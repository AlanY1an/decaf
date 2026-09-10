import Foundation
import TranscriptSupport

/// Reconciles local cumulative token observations. Persisting the observations
/// makes copied files, out-of-order backfill and counter resets reproducible.
/// No conversational fields are retained.
public struct CodexUsageParser: Sendable {
    public struct Context: Codable, Equatable, Sendable {
        public var sessionID: String
        public var model: String
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
        public init() {}
    }
    public private(set) var state: State
    public var unresolvedRecordCount: Int { state.unresolvedBySession?.values.reduce(0, +) ?? 0 }
    public init(state: State = State()) { self.state = state }

    /// Convenience for ordered single-event callers. Production uses the batch
    /// API because backfill can correct an already-accounted neighboring event.
    public mutating func parse(line: String, path: String) -> UsageRecord? {
        parseRecords(line: line, path: path).first
    }

    public mutating func parseRecords(line: String, path: String) -> [UsageRecord] {
        guard line.contains("session_meta") || line.contains("turn_context") || line.contains("token_count"),
              let data = line.data(using: .utf8), JSONDepth.isWithin(64, data),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = record["type"] as? String,
              let payload = record["payload"] as? [String: Any] else { return [] }
        if kind == "session_meta" {
            guard let id = (payload["session_id"] ?? payload["id"]) as? String, !id.isEmpty else { return [] }
            state.contexts[path] = Context(sessionID: id, model: "Unknown Codex model")
            return []
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
