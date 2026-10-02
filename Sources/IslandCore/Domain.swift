import Foundation

// UI-facing domain types. Everything the views render comes from here; the
// raw API shapes live in APIModels.swift and are mapped in by `AccountMapper`.

public enum Provider: Hashable, Sendable {
    case claude, codex, gemini, other(String)

    public init(raw: String) {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "claude", "anthropic": self = .claude
        case "codex", "openai": self = .codex
        case "gemini", "gemini-cli", "vertex", "aistudio", "antigravity": self = .gemini
        case let other: self = .other(other)
        }
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .other(let raw): raw.isEmpty ? "Unknown" : raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }
}

/// One rate-limit window (e.g. Claude "5h", Codex "Week").
public struct QuotaWindow: Identifiable, Hashable, Sendable {
    public var id: String
    /// Short human label: "5h", "Week", "Week · Opus".
    public var label: String
    /// Used share of the window, 0...1. nil when unknown.
    public var usedFraction: Double?
    public var resetsAt: Date?

    public init(id: String, label: String, usedFraction: Double?, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.usedFraction = usedFraction.map { min(max($0, 0), 1) }
        self.resetsAt = resetsAt
    }

    public var remainingFraction: Double? { usedFraction.map { 1 - $0 } }
}

public enum QuotaSource: Hashable, Sendable {
    /// Fetched from the provider's usage endpoint through the proxy (`api-call`).
    case live(observedAt: Date)
    /// Parsed from rate-limit response headers the proxy observed passively.
    case headers(observedAt: Date)
    case none
}

public enum AccountHealth: Hashable, Sendable {
    case ok
    /// Proxy-side cooldown or quota block. `until` = earliest time it may be retried.
    case rateLimited(until: Date?, reason: String?)
    case disabled
    case error(String)
}

public struct Account: Identifiable, Hashable, Sendable {
    public var id: String
    public var authIndex: String?
    public var provider: Provider
    /// Email, label or file name, in that order of preference.
    public var label: String
    public var plan: String?
    public var health: AccountHealth
    public var windows: [QuotaWindow]
    public var quotaSource: QuotaSource
    /// Requests (success + failed) routed to this account in the last ~60 min.
    public var requestsLastHour: Int
    public var failedLastHour: Int

    public init(
        id: String, authIndex: String?, provider: Provider, label: String, plan: String?,
        health: AccountHealth, windows: [QuotaWindow], quotaSource: QuotaSource,
        requestsLastHour: Int, failedLastHour: Int
    ) {
        self.id = id
        self.authIndex = authIndex
        self.provider = provider
        self.label = label
        self.plan = plan
        self.health = health
        self.windows = windows
        self.quotaSource = quotaSource
        self.requestsLastHour = requestsLastHour
        self.failedLastHour = failedLastHour
    }

    /// The window closest to exhaustion: the one that actually limits the account.
    public var bindingWindow: QuotaWindow? {
        windows.filter { $0.usedFraction != nil }.max { ($0.usedFraction ?? 0) < ($1.usedFraction ?? 0) }
    }
}

public struct ModelUsage: Identifiable, Hashable, Sendable {
    public var id: String { model }
    public var model: String
    public var requests: Int
    public var failed: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int

    public init(model: String, requests: Int, failed: Int, inputTokens: Int, outputTokens: Int, totalTokens: Int) {
        self.model = model
        self.requests = requests
        self.failed = failed
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

public struct UsageSummary: Hashable, Sendable {
    /// Sorted by totalTokens desc, then requests desc.
    public var lastHour: [ModelUsage]
    public var today: [ModelUsage]
    /// When the app started collecting (usage is only visible from then on).
    public var trackingSince: Date?

    public init(lastHour: [ModelUsage], today: [ModelUsage], trackingSince: Date?) {
        self.lastHour = lastHour
        self.today = today
        self.trackingSince = trackingSince
    }

    public static let empty = UsageSummary(lastHour: [], today: [], trackingSince: nil)
}

public enum ConnectionState: Hashable, Sendable {
    case needsKey
    case connecting
    case connected(at: Date)
    /// Connection refused / timed out.
    case proxyDown(String)
    /// 401/403 from the management API.
    case keyRejected
    case failed(String)
}
