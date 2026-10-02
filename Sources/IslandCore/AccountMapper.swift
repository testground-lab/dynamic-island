import Foundation

public enum AccountMapper {
    public static func accounts(from response: AuthFilesResponse, live: [String: LiveQuota], now: Date) -> [Account] {
        response.files.enumerated().map { offset, file in
            let provider = Provider(raw: file.provider ?? file.type ?? "")
            let signals = file.quota?.signals ?? [:]
            let observed = file.quota?.observedAt ?? response.observedAt
            let headers = HeaderQuotaParser.windows(provider: provider, signals: signals, observedAt: observed)
            let candidate = file.authIndex.flatMap { live[$0] }
            let fresh = candidate.flatMap { now.timeIntervalSince($0.observedAt) < 900 && $0.observedAt <= now ? $0 : nil }
            let windows = fresh?.windows ?? headers
            let source: QuotaSource = fresh.map { .live(observedAt: $0.observedAt) } ?? (headers.isEmpty ? .none : .headers(observedAt: observed ?? now))
            let buckets = Array((file.recentRequests ?? []).suffix(6))
            let failed = buckets.reduce(0) { addingCounts($0, nonnegative($1.failed)) }
            let requests = buckets.reduce(0) { addingCounts($0, addingCounts(nonnegative($1.success), nonnegative($1.failed))) }
            return Account(id: file.id ?? file.authIndex ?? file.name ?? "unknown-\(offset)", authIndex: file.authIndex,
                           provider: provider, label: file.email ?? file.label ?? file.account ?? file.name ?? file.id ?? "Unknown",
                           plan: candidate?.plan ?? file.idToken?.planType ?? HeaderQuotaParser.plan(provider: provider, signals: signals),
                           health: health(file, provider: provider, windows: windows, now: now), windows: windows, quotaSource: source,
                           requestsLastHour: requests, failedLastHour: failed)
        }.sorted {
            let aDisabled = $0.health == .disabled; let bDisabled = $1.health == .disabled
            if aDisabled != bDisabled { return !aDisabled }
            if $0.requestsLastHour != $1.requestsLastHour { return $0.requestsLastHour > $1.requestsLastHour }
            if $0.provider.displayName != $1.provider.displayName { return $0.provider.displayName < $1.provider.displayName }
            if $0.label != $1.label { return $0.label < $1.label }
            return $0.id < $1.id
        }
    }
    private static func health(_ file: AuthFile, provider: Provider, windows: [QuotaWindow], now: Date) -> AccountHealth {
        if file.disabled == true || file.status?.lowercased() == "disabled" { return .disabled }
        if let cooldown = file.cooldowns?.filter({ ($0.retryAt ?? .distantPast) > now }).max(by: { ($0.retryAt ?? .distantPast) < ($1.retryAt ?? .distantPast) }) {
            return .rateLimited(until: cooldown.retryAt, reason: cooldown.reason)
        }
        if file.unavailable == true, let retry = file.nextRetryAfter, retry > now { return .rateLimited(until: retry, reason: nil) }
        if file.status?.lowercased() == "error" { return .error(file.statusMessage ?? "Error") }
        let s = normalizedSignals(file.quota?.signals ?? [:])
        let rejected = provider == .codex && s["x-codex-limit-reached"]?.lowercased() == "true"
            || provider == .claude && s.contains { $0.key.hasPrefix("anthropic-ratelimit-unified-") && $0.key.hasSuffix("status") && $0.value.lowercased() == "rejected" }
        if rejected {
            let binding = windows.filter { $0.usedFraction != nil }.max { ($0.usedFraction ?? 0) < ($1.usedFraction ?? 0) }
            return .rateLimited(until: binding?.resetsAt, reason: "limit reached")
        }
        return .ok
    }
}
