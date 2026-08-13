// UsageRecord — one assistant message's token accounting (plan 09 M1).
// Values come verbatim from the API's `usage` object: real counts, not
// estimates. Codable because the ledger persists per-session waterlines.

import Foundation

public struct TokenTotals: Equatable, Sendable, Codable {
    public var input: Int
    public var output: Int
    public var cacheCreation: Int
    public var cacheRead: Int

    public init(input: Int = 0, output: Int = 0, cacheCreation: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
    }

    public static func += (lhs: inout TokenTotals, rhs: TokenTotals) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheCreation += rhs.cacheCreation
        lhs.cacheRead += rhs.cacheRead
    }

    public var total: Int { input + output + cacheCreation + cacheRead }
}

public struct UsageRecord: Equatable, Sendable, Codable {
    public var sessionID: String
    public var messageID: String
    /// Absent on some records; part of the dedup key when present (API
    /// retries write the same messageID under a new requestId).
    public var requestID: String?
    public var model: String
    public var timestamp: Date
    public var tokens: TokenTotals

    /// What the context window held when this message was produced:
    /// everything the model read (fresh + cached), excluding its own output.
    public var contextTokens: Int { tokens.input + tokens.cacheCreation + tokens.cacheRead }

    public init(
        sessionID: String, messageID: String, requestID: String?,
        model: String, timestamp: Date, tokens: TokenTotals
    ) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.requestID = requestID
        self.model = model
        self.timestamp = timestamp
        self.tokens = tokens
    }
}
