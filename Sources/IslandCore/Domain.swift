import Foundation

// UI-facing domain types. Everything the views render comes from here; the
// raw API shapes live in APIModels.swift and are mapped in by `AccountMapper`.

public enum Provider: Hashable, Sendable {
    case claude, codex, gemini
    case other(String)

    public init(raw: String) {
        switch raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "claude", "anthropic": self = .claude
        case "codex", "openai": self = .codex
        case "gemini", "gemini-cli", "vertex", "aistudio", "antigravity": self = .gemini
        case let other: self = .other(other)
        }
    }

    public var isUnknown: Bool { self == .other("") }

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
    /// Full duration of this quota window, independent of its utilization.
    public var periodSeconds: TimeInterval?

    public init(
        id: String, label: String, usedFraction: Double?, resetsAt: Date?,
        periodSeconds: TimeInterval? = nil
    ) {
        self.id = id
        self.label = label
        self.usedFraction = usedFraction.map { min(max($0, 0), 1) }
        self.resetsAt = resetsAt
        self.periodSeconds = periodSeconds
    }

    public var remainingFraction: Double? { usedFraction.map { 1 - $0 } }

    public func elapsedFraction(now: Date) -> Double? {
        guard let resetsAt, let periodSeconds, periodSeconds.isFinite, periodSeconds > 0 else {
            return nil
        }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining.isFinite else { return nil }
        return min(max(1 - remaining / periodSeconds, 0), 1)
    }
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
        windows.filter { $0.usedFraction != nil }.max {
            ($0.usedFraction ?? 0) < ($1.usedFraction ?? 0)
        }
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

    public init(
        model: String, requests: Int, failed: Int, inputTokens: Int, outputTokens: Int,
        totalTokens: Int
    ) {
        self.model = model
        self.requests = requests
        self.failed = failed
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

public enum UsageRange: String, CaseIterable, Hashable, Sendable {
    case today, week, month, halfYear

    public var title: String {
        switch self {
        case .today: "Today"
        case .week: "7d"
        case .month: "30d"
        case .halfYear: "6m"
        }
    }

    public var granularity: UsageGranularity {
        switch self {
        case .today: .hour
        case .week, .month: .day
        case .halfYear: .week
        }
    }

    public func start(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        if self == .halfYear {
            let week = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
            let earlier = calendar.date(byAdding: .weekOfYear, value: -25, to: week) ?? week
            return calendar.dateInterval(of: .weekOfYear, for: earlier)?.start ?? earlier
        }
        let days = self == .today ? 0 : self == .week ? -6 : -29
        return calendar.date(byAdding: .day, value: days, to: today) ?? today
    }

    public func chartEnd(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        if self == .halfYear {
            return calendar.dateInterval(of: .weekOfYear, for: today)?.end ?? today
        }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }
}

public enum UsageGranularity: Hashable, Sendable {
    case hour, day, week
}

public struct ProviderTokens: Hashable, Sendable {
    public var provider: Provider
    public var inputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int
    public var requests: Int

    public init(
        provider: Provider, inputTokens: Int, outputTokens: Int, totalTokens: Int, requests: Int
    ) {
        self.provider = provider
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.requests = requests
    }
}

public struct UsageSeriesPoint: Identifiable, Hashable, Sendable {
    public var id: Date { start }
    public let start: Date
    public let end: Date
    public let byProvider: [ProviderTokens]
    public let recorded: Bool
    public let partial: Bool
    public let future: Bool

    public init(
        start: Date, end: Date, byProvider: [ProviderTokens] = [],
        trackingSince: Date? = nil, now: Date
    ) {
        self.start = start
        self.end = end
        self.byProvider = byProvider.sorted {
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            return $0.provider.displayName < $1.provider.displayName
        }
        recorded = trackingSince.map { end > $0 } ?? false
        partial = trackingSince.map { start <= $0 && $0 < end } ?? false
        future = start > now
    }

    public var totalTokens: Int {
        byProvider.reduce(0) { addingCounts($0, $1.totalTokens) }
    }
}

public struct UsageSeries: Hashable, Sendable {
    public var range: UsageRange
    public var granularity: UsageGranularity
    public var points: [UsageSeriesPoint]
    public var trackingSince: Date?

    public init(
        range: UsageRange, granularity: UsageGranularity, points: [UsageSeriesPoint],
        trackingSince: Date? = nil
    ) {
        self.range = range
        self.granularity = granularity
        self.points = points
        self.trackingSince = trackingSince
    }

    public var peakTokens: Int { points.map(\.totalTokens).max() ?? 0 }
}

public struct UsageTotals: Hashable, Sendable {
    public var requests: Int
    public var failed: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int

    public init(
        requests: Int = 0, failed: Int = 0, inputTokens: Int = 0,
        outputTokens: Int = 0, totalTokens: Int = 0
    ) {
        self.requests = requests
        self.failed = failed
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }

    public static let zero = UsageTotals()
}

public struct AccountUsage: Identifiable, Hashable, Sendable {
    public var id: String { authIndex ?? "unattributed" }
    public var authIndex: String?
    public var provider: Provider
    public var label: String
    public var totals: UsageTotals

    public init(authIndex: String?, provider: Provider, label: String, totals: UsageTotals) {
        self.authIndex = authIndex
        self.provider = provider
        self.label = label
        self.totals = totals
    }
}

public struct UsageReport: Hashable, Sendable {
    public var range: UsageRange
    public var start: Date
    public var totals: UsageTotals
    public var byAccount: [AccountUsage]
    public var byModel: [ModelUsage]
    public var trackingSince: Date?

    public init(
        range: UsageRange, start: Date, totals: UsageTotals = .zero,
        byAccount: [AccountUsage] = [], byModel: [ModelUsage] = [], trackingSince: Date? = nil
    ) {
        self.range = range
        self.start = start
        self.totals = totals
        self.byAccount = byAccount
        self.byModel = byModel
        self.trackingSince = trackingSince
    }

    public var isPartial: Bool { trackingSince.map { $0 > start } ?? true }
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
