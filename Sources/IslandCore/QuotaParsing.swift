import Foundation

func normalizedSignals(_ signals: [String: String]) -> [String: String] {
    Dictionary(signals.sorted { $0.key < $1.key }.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
}
private func finiteNumber(_ string: String?) -> Double? { string.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } }
private func epochDate(_ n: Double?) -> Date? { n.map(Date.init(timeIntervalSince1970:)) }
private func minutesLabel(_ minutes: Double?) -> String {
    guard let minutes, let n = safeInteger(minutes), n > 0 else { return "Quota" }
    if n == 300 { return "5h" }; if n == 10080 { return "Week" }
    if n % 1440 == 0 { return "\(n / 1440)d" }
    if n % 60 == 0 && n < 1440 { return "\(n / 60)h" }
    return "\(n)m"
}
private func claudeLabel(_ window: String) -> String {
    switch window.replacingOccurrences(of: "-", with: "_") {
    case "5h": return "5h"
    case "7d": return "Week"
    case "7d_opus": return "Week · Opus"
    case "7d_sonnet": return "Week · Sonnet"
    default: return window
    }
}
private func claudePeriod(_ key: String) -> Double {
    let prefix = key.prefix { $0.isNumber || $0 == "." }
    guard let n = Double(prefix) else { return .greatestFiniteMagnitude }
    let unit = key.dropFirst(prefix.count).first
    switch unit { case "m": return n * 60; case "h": return n * 3600; case "d": return n * 86400; default: return .greatestFiniteMagnitude }
}
private func sortedWindows(_ pairs: [(QuotaWindow, Double)]) -> [QuotaWindow] {
    pairs.sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 < $1.1 }.map(\.0)
}
public enum HeaderQuotaParser {
    public static func windows(provider: Provider, signals: [String: String], observedAt: Date?) -> [QuotaWindow] {
        let s = normalizedSignals(signals)
        var pairs: [(QuotaWindow, Double)] = []
        switch provider {
        case .claude:
            let prefix = "anthropic-ratelimit-unified-"
            var names: Set<String> = []
            for key in s.keys where key.hasPrefix(prefix) {
                for suffix in ["-utilization", "-reset", "-status"] where key.hasSuffix(suffix) {
                    let name = String(key.dropFirst(prefix.count).dropLast(suffix.count))
                    if !name.isEmpty { names.insert(name) }
                }
            }
            for name in names {
                let base = prefix + name
                let used = finiteNumber(s[base + "-utilization"])
                let reset = epochDate(finiteNumber(s[base + "-reset"]))
                guard used != nil || reset != nil else { continue }
                let id = name.replacingOccurrences(of: "-", with: "_")
                pairs.append((QuotaWindow(id: "claude." + id, label: claudeLabel(name), usedFraction: used, resetsAt: reset), claudePeriod(name)))
            }
        case .codex:
            for kind in ["primary", "secondary"] {
                let base = "x-codex-" + kind
                let used = finiteNumber(s[base + "-used-percent"]).map { $0 / 100 }
                let minutes = finiteNumber(s[base + "-window-minutes"])
                let reset = epochDate(finiteNumber(s[base + "-reset-at"])) ?? observedAt.flatMap { date in finiteNumber(s[base + "-reset-after-seconds"]).map { date.addingTimeInterval($0) } }
                guard used != nil || reset != nil else { continue }
                pairs.append((QuotaWindow(id: "codex." + kind, label: minutesLabel(minutes), usedFraction: used, resetsAt: reset), minutes.map { $0 * 60 } ?? .greatestFiniteMagnitude))
            }
        default: break
        }
        return sortedWindows(pairs)
    }
    public static func plan(provider: Provider, signals: [String: String]) -> String? {
        provider == .codex ? normalizedSignals(signals)["x-codex-plan-type"] : nil
    }
}
public struct LiveQuota: Sendable, Hashable {
    public var windows: [QuotaWindow]
    public var plan: String?
    public var observedAt: Date
    public init(windows: [QuotaWindow], plan: String? = nil, observedAt: Date) { self.windows = windows; self.plan = plan; self.observedAt = observedAt }
}
private struct LiveBody: Decodable {
    let c: KeyedDecodingContainer<WireKey>
    init(from decoder: Decoder) throws { c = try decoder.container(keyedBy: WireKey.self) }
}
public enum LiveQuotaFetcher {
    public static func request(for file: AuthFile) -> APICallRequest? {
        guard let index = file.authIndex, !index.isEmpty, file.disabled != true, file.status?.lowercased() != "disabled" else { return nil }
        var headers = ["Authorization": "Bearer $TOKEN$", "Content-Type": "application/json"]
        let url: String
        switch Provider(raw: file.provider ?? file.type ?? "") {
        case .claude:
            url = "https://api.anthropic.com/api/oauth/usage"
            headers["anthropic-beta"] = "oauth-2025-04-20"
            headers["User-Agent"] = "claude-cli/2.1.280 (external, cli)"
        case .codex:
            url = "https://chatgpt.com/backend-api/wham/usage"
            headers["User-Agent"] = "codex-tui/0.149.1 (Mac OS 26.5.2; arm64) iTerm.app/3.6.11 (codex-tui; 0.149.1)"
            headers["Chatgpt-Account-Id"] = file.idToken?.chatgptAccountID
        default: return nil
        }
        return APICallRequest(authIndex: index, url: url, header: headers)
    }
    public static func parse(provider: Provider, response: APICallResponse, now: Date) -> LiveQuota? {
        guard let status = response.statusCode, (200..<300).contains(status), let body = response.body,
              let decoded = try? JSONDecoder().decode(LiveBody.self, from: Data(body.utf8)) else { return nil }
        let c = decoded.c
        var pairs: [(QuotaWindow, Double)] = []
        var plan: String?
        switch provider {
        case .claude:
            let specs: [(String, String, String, Double)] = [
                ("five_hour", "5h", "5h", 18000), ("seven_day", "7d", "Week", 604800),
                ("seven_day_opus", "7d_opus", "Week · Opus", 604800), ("seven_day_sonnet", "7d_sonnet", "Week · Sonnet", 604800),
                ("seven_day_oauth_apps", "7d_oauth_apps", "Week · Apps", 604800), ("seven_day_cowork", "7d_cowork", "Week · Cowork", 604800)]
            for (key, id, label, period) in specs {
                guard let w = c.value(key, as: LiveBody.self)?.c else { continue }
                pairs.append((QuotaWindow(id: "claude." + id, label: label, usedFraction: w.number("utilization").map { $0 / 100 }, resetsAt: w.date("resets_at")), period))
            }
        case .codex:
            plan = c.string("plan_type") ?? c.string("planType")
            guard let rate = (c.value("rate_limit", as: LiveBody.self) ?? c.value("rateLimit", as: LiveBody.self))?.c else { return nil }
            for (key, camel, id) in [("primary_window", "primaryWindow", "primary"), ("secondary_window", "secondaryWindow", "secondary")] {
                guard let w = (rate.value(key, as: LiveBody.self) ?? rate.value(camel, as: LiveBody.self))?.c else { continue }
                let seconds = w.number("limit_window_seconds") ?? w.number("limitWindowSeconds")
                let percent = w.number("used_percent") ?? w.number("usedPercent")
                let reset = epochDate(w.number("reset_at") ?? w.number("resetAt")) ?? (w.number("reset_after_seconds") ?? w.number("resetAfterSeconds")).map { now.addingTimeInterval($0) }
                pairs.append((QuotaWindow(id: "codex." + id, label: minutesLabel(seconds.map { $0 / 60 }), usedFraction: percent.map { $0 / 100 }, resetsAt: reset), seconds ?? .greatestFiniteMagnitude))
            }
        default: return nil
        }
        guard !pairs.isEmpty else { return nil }
        return LiveQuota(windows: sortedWindows(pairs), plan: plan, observedAt: now)
    }
}
