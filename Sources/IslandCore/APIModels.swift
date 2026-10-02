import Foundation

/// Numeric wire values are deliberately tolerant, but never admit NaN or infinity.
public struct FlexibleNumber: Decodable, Sendable {
    public let value: Double?
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let n = (try? c.decode(Double.self)) ?? (try? c.decode(String.self)).flatMap(Double.init)
        value = n.flatMap { $0.isFinite ? $0 : nil }
    }
}

public enum APIDateParser {
    public static func parse(_ string: String) -> Date? {
        // Foundation accepts millisecond precision; normalize Go's nanosecond timestamps.
        let normalized = string.replacingOccurrences(of: #"(\.\d{3})\d+(?=Z|[+-]\d{2}:\d{2}$)"#, with: "$1", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: normalized) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: normalized)
    }
}

struct WireKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

extension KeyedDecodingContainer where Key == WireKey {
    func value<T: Decodable>(_ key: String, as type: T.Type = T.self) -> T? { try? decodeIfPresent(type, forKey: WireKey(key)) }
    func string(_ key: String) -> String? {
        if let s: String = value(key) { return s }
        if let n = number(key) { return String(n) }
        return nil
    }
    func number(_ key: String) -> Double? { value(key, as: FlexibleNumber.self)?.value }
    func integer(_ key: String) -> Int? { number(key).flatMap(safeInteger) }
    func bool(_ key: String) -> Bool? {
        if let b: Bool = value(key) { return b }
        switch string(key)?.lowercased() { case "true", "1": return true; case "false", "0": return false; default: return nil }
    }
    func date(_ key: String) -> Date? { string(key).flatMap(APIDateParser.parse) }
}

func safeInteger(_ value: Double) -> Int? {
    guard value.isFinite, value >= Double(Int.min), value < Double(Int.max) else { return nil }
    return Int(value)
}
func nonnegative(_ n: Int?) -> Int { max(0, n ?? 0) }
func addingCounts(_ a: Int, _ b: Int) -> Int { let (sum, overflow) = a.addingReportingOverflow(b); return overflow ? Int.max : sum }

public struct AuthFilesResponse: Decodable, Sendable {
    public var observedAt: Date?
    public var files: [AuthFile]
    public init(observedAt: Date? = nil, files: [AuthFile] = []) { self.observedAt = observedAt; self.files = files }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        observedAt = c.date("observed_at")
        files = c.value("files", as: [LossyAuthFile].self)?.compactMap(\.value) ?? []
    }
}
private struct LossyAuthFile: Decodable { let value: AuthFile?; init(from decoder: Decoder) throws { value = try? AuthFile(from: decoder) } }

public struct AuthFile: Decodable, Sendable {
    public var id: String?
    public var authIndex: String?
    public var name: String?
    public var type: String?
    public var provider: String?
    public var label: String?
    public var email: String?
    public var accountType: String?
    public var account: String?
    public var status: String?
    public var statusMessage: String?
    public var disabled: Bool?
    public var unavailable: Bool?
    public var runtimeOnly: Bool?
    public var source: String?
    public var success: Int?
    public var failed: Int?
    public var recentRequests: [RecentRequestBucket]?
    public var quota: QuotaObservation?
    public var modelQuotas: [String: QuotaObservation]?
    public var cooldowns: [Cooldown]?
    public var nextRetryAfter: Date?
    public var idToken: CodexIDToken?
    public var supportsQuota: Bool?
    public var priority: Int?
    public var note: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var lastRefresh: Date?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        id = c.string("id"); authIndex = c.string("auth_index"); name = c.string("name"); type = c.string("type"); provider = c.string("provider")
        label = c.string("label"); email = c.string("email"); accountType = c.string("account_type"); account = c.string("account")
        status = c.string("status"); statusMessage = c.string("status_message"); disabled = c.bool("disabled"); unavailable = c.bool("unavailable")
        runtimeOnly = c.bool("runtime_only"); source = c.string("source"); success = c.integer("success"); failed = c.integer("failed")
        recentRequests = c.value("recent_requests"); quota = c.value("quota"); modelQuotas = c.value("model_quotas"); cooldowns = c.value("cooldowns")
        nextRetryAfter = c.date("next_retry_after"); idToken = c.value("id_token"); supportsQuota = c.bool("supports_quota"); priority = c.integer("priority"); note = c.string("note")
        createdAt = c.date("created_at"); updatedAt = c.date("updated_at"); lastRefresh = c.date("last_refresh")
    }
}

public struct RecentRequestBucket: Decodable, Sendable {
    public var time: String?
    public var success: Int?
    public var failed: Int?
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: WireKey.self); time = c.string("time"); success = c.integer("success"); failed = c.integer("failed") }
}
public struct QuotaObservation: Decodable, Sendable {
    public var observedAt: Date?
    public var signals: [String: String]
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        observedAt = c.date("observed_at")
        if let s = try? c.nestedContainer(keyedBy: WireKey.self, forKey: WireKey("signals")) {
            signals = Dictionary(s.allKeys.compactMap { k in s.string(k.stringValue).map { (k.stringValue, $0) } }, uniquingKeysWith: { first, _ in first })
        } else { signals = [:] }
    }
}
public struct Cooldown: Decodable, Sendable {
    public var scope: String?
    public var modelKey: String?
    public var reason: String?
    public var retryAt: Date?
    public var remainingSeconds: Double?
    public var backoffLevel: Int?
    public var httpStatus: Int?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        scope = c.string("scope"); modelKey = c.string("model_key"); reason = c.string("reason"); retryAt = c.date("retry_at")
        remainingSeconds = c.number("remaining_seconds"); backoffLevel = c.integer("backoff_level"); httpStatus = c.integer("http_status")
    }
}
public struct CodexIDToken: Decodable, Sendable {
    public var chatgptAccountID: String?
    public var planType: String?
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: WireKey.self); chatgptAccountID = c.string("chatgpt_account_id"); planType = c.string("plan_type") }
}
public struct APICallRequest: Encodable, Sendable {
    public var authIndex: String
    public var method: String
    public var url: String
    public var header: [String: String]
    public init(authIndex: String, method: String = "GET", url: String, header: [String: String]) { self.authIndex = authIndex; self.method = method; self.url = url; self.header = header }
    enum CodingKeys: String, CodingKey { case authIndex = "auth_index", method, url, header }
}
public struct APICallResponse: Decodable, Sendable {
    public var statusCode: Int?
    public var header: [String: [String]]?
    public var body: String?
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: WireKey.self); statusCode = c.integer("status_code"); header = c.value("header"); body = c.string("body") }
}
/// Intentionally excludes credential, network identity, response headers, and failure bodies.
public struct UsageRecord: Decodable, Sendable {
    public var timestamp: Date?
    public var model: String?
    public var alias: String?
    public var provider: String?
    public var authIndex: String?
    public var failed: Bool?
    public var tokens: UsageTokens?
    public var latencyMS: Double?
    public init(timestamp: Date? = nil, model: String? = nil, alias: String? = nil, failed: Bool? = nil, tokens: UsageTokens? = nil) {
        self.timestamp = timestamp; self.model = model; self.alias = alias; self.failed = failed; self.tokens = tokens
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        timestamp = c.date("timestamp"); model = c.string("model"); alias = c.string("alias"); provider = c.string("provider"); authIndex = c.string("auth_index")
        failed = c.bool("failed"); tokens = c.value("tokens"); latencyMS = c.number("latency_ms")
    }
}
public struct UsageTokens: Decodable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var reasoningTokens: Int?
    public var cachedTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheCreationTokens: Int?
    public var totalTokens: Int?
    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, reasoningTokens: Int? = nil, totalTokens: Int? = nil) { self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.reasoningTokens = reasoningTokens; self.totalTokens = totalTokens }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        inputTokens = c.integer("input_tokens"); outputTokens = c.integer("output_tokens"); reasoningTokens = c.integer("reasoning_tokens"); cachedTokens = c.integer("cached_tokens")
        cacheReadTokens = c.integer("cache_read_tokens"); cacheCreationTokens = c.integer("cache_creation_tokens"); totalTokens = c.integer("total_tokens")
    }
}
public struct UsageQueueBatch: Decodable, Sendable {
    public let records: [UsageRecord]
    public let rawCount: Int
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var result: [UsageRecord] = []; var count = 0
        while !c.isAtEnd { let item = try c.superDecoder(); count += 1; if let record = try? UsageRecord(from: item) { result.append(record) } }
        records = result; rawCount = count
    }
}
