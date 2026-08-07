// UsageRecordParser — one JSONL transcript line → UsageRecord? (plan 09 M1).
//
// Same three disciplines as WaitSignalParser:
// 1. Unknown → skip silently; no entry point throws, no force-unwrap.
// 2. Depth guard before JSONSerialization (512 KB cooperative stacks).
// 3. Closed read surface: RecordKey/MessageKey/UsageKey are the ONLY places
//    a transcript key is named, pinned by UsageRecordParserTests. `content`
//    and every other conversational field are never read.

import Foundation
import TranscriptSupport

public struct UsageRecordParser: Sendable {

    public static let maxJSONDepth = 64

    /// Diagnostics carry no transcript text — closed cases only.
    public enum Diagnostic: Equatable, Sendable, CaseIterable {
        case lineNotJSON
        case lineTooDeeplyNested
        case notAnAssistantRecord
        case sidechainIgnored
        case missingOrInvalidField
    }

    /// The complete record-level read surface (pinned by tests).
    enum RecordKey: String, CaseIterable {
        case type, isSidechain, sessionId, timestamp, requestId, message
    }

    /// The complete message-level read surface (pinned by tests).
    enum MessageKey: String, CaseIterable {
        case id, model, usage
    }

    /// The complete usage-level read surface (pinned by tests).
    enum UsageKey: String, CaseIterable {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationTokens = "cache_creation_input_tokens"
        case cacheReadTokens = "cache_read_input_tokens"
    }

    public var onDiagnostic: (@Sendable (Diagnostic) -> Void)?

    public init(onDiagnostic: (@Sendable (Diagnostic) -> Void)? = nil) {
        self.onDiagnostic = onDiagnostic
    }

    public func parse(line: String) -> UsageRecord? {
        // Cheap pre-filter: a record without a usage object cannot yield
        // anything. (Not a correctness guard — the type check below is.)
        guard line.contains("\"usage\"") else { return nil }

        guard let data = line.data(using: .utf8) else {
            report(.lineNotJSON)
            return nil
        }
        guard JSONDepth.isWithin(Self.maxJSONDepth, data) else {
            report(.lineTooDeeplyNested)
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let record = object as? [String: Any]
        else {
            report(.lineNotJSON)
            return nil
        }

        guard JSON.string(record[RecordKey.type.rawValue]) == "assistant" else {
            report(.notAnAssistantRecord)
            return nil
        }
        if JSON.bool(record[RecordKey.isSidechain.rawValue]) == true {
            report(.sidechainIgnored)
            return nil
        }

        guard let sessionID = JSON.string(record[RecordKey.sessionId.rawValue]), !sessionID.isEmpty,
              let timestampText = JSON.string(record[RecordKey.timestamp.rawValue]),
              let timestamp = ISO8601UTCTimestamp.date(from: timestampText),
              let message = record[RecordKey.message.rawValue] as? [String: Any],
              let messageID = JSON.string(message[MessageKey.id.rawValue]), !messageID.isEmpty,
              let model = JSON.string(message[MessageKey.model.rawValue]), !model.isEmpty
        else {
            report(.missingOrInvalidField)
            return nil
        }

        // A missing usage object is normal (streaming interims); silence.
        guard let usage = message[MessageKey.usage.rawValue] as? [String: Any] else {
            return nil
        }

        guard let input = JSON.nonNegativeInteger(usage[UsageKey.inputTokens.rawValue]),
              let output = JSON.nonNegativeInteger(usage[UsageKey.outputTokens.rawValue]),
              let cacheCreation = optionalCount(usage[UsageKey.cacheCreationTokens.rawValue]),
              let cacheRead = optionalCount(usage[UsageKey.cacheReadTokens.rawValue])
        else {
            report(.missingOrInvalidField)
            return nil
        }

        return UsageRecord(
            sessionID: sessionID,
            messageID: messageID,
            requestID: JSON.string(record[RecordKey.requestId.rawValue]),
            model: model,
            timestamp: timestamp,
            tokens: TokenTotals(
                input: input, output: output,
                cacheCreation: cacheCreation, cacheRead: cacheRead
            )
        )
    }

    /// Absent → 0 (older records omit cache fields); present-but-invalid → nil.
    private func optionalCount(_ value: Any?) -> Int? {
        guard let value else { return 0 }
        return JSON.nonNegativeInteger(value)
    }

    private func report(_ diagnostic: Diagnostic) {
        onDiagnostic?(diagnostic)
    }
}
