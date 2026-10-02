import Foundation
import Observation

@MainActor @Observable public final class IslandModel {
    public private(set) var accounts: [Account] = []
    public private(set) var usage: UsageSummary = .empty
    public private(set) var connection: ConnectionState = .connecting
    public private(set) var lastUpdated: Date?
    public private(set) var usageAvailable = true
    public var baseURLString: String
    public var liveQuotaEnabled: Bool {
        didSet {
            defaults.set(liveQuotaEnabled, forKey: "liveQuotaEnabled")
            if !liveQuotaEnabled { liveTask?.cancel() }
        }
    }
    public private(set) var hasKey: Bool
    @ObservationIgnored private let keyStore: any KeyStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let aggregator: UsageAggregator
    @ObservationIgnored private let clientFactory: @Sendable (URL, String) -> ManagementClient
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var lastResponse: AuthFilesResponse?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var live: [String: LiveQuota] = [:]
    @ObservationIgnored private var liveAttempts: [String: Date] = [:]
    @ObservationIgnored private var isDemo = false

    public init(keyStore: any KeyStore, defaults: UserDefaults = .standard, aggregator: UsageAggregator,
                clientFactory: @escaping @Sendable (URL, String) -> ManagementClient = { ManagementClient(baseURL: $0, key: $1) }) {
        self.keyStore = keyStore; self.defaults = defaults; self.aggregator = aggregator; self.clientFactory = clientFactory
        baseURLString = defaults.string(forKey: "baseURL") ?? BaseURLValidator.defaultBaseURL
        liveQuotaEnabled = defaults.object(forKey: "liveQuotaEnabled") == nil ? true : defaults.bool(forKey: "liveQuotaEnabled")
        hasKey = ((try? keyStore.read()) ?? nil)?.isEmpty == false
        if !hasKey { connection = .needsKey }
    }
    public func start() {
        guard !isDemo, task == nil else { return }
        generation += 1
        let current = generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                let started = ContinuousClock.now
                guard let shouldContinue = await self?.poll(generation: current), shouldContinue else { break }
                let remaining = Duration.seconds(15) - started.duration(to: .now)
                do { try await Task.sleep(for: max(.zero, remaining)) } catch { break }
            }
            if self?.generation == current { self?.task = nil }
        }
    }
    public func stop() { generation += 1; task?.cancel(); task = nil; liveTask?.cancel(); liveTask = nil }
    public func refreshNow() { guard !isDemo else { return }; stop(); start() }
    public func saveKey(_ key: String) throws { try keyStore.save(key); hasKey = true; live = [:]; liveAttempts = [:]; refreshNow() }
    public func clearKey() throws {
        try keyStore.delete(); stop(); hasKey = false; connection = .needsKey
        accounts = []; usage = .empty; lastUpdated = nil; live = [:]; liveAttempts = [:]
    }
    public func applyBaseURL(_ string: String) -> Bool {
        guard let url = BaseURLValidator.validate(string) else { return false }
        baseURLString = url.absoluteString; defaults.set(baseURLString, forKey: "baseURL")
        live = [:]; liveAttempts = [:]; refreshNow(); return true
    }
    public var featuredAccount: Account? {
        let enabled = accounts.filter { $0.health != .disabled }
        return enabled.filter { $0.bindingWindow != nil }.max { $0.requestsLastHour < $1.requestsLastHour }
            ?? enabled.first { !$0.windows.isEmpty } ?? enabled.first
    }
    /// Proxy-side per-account buckets survive app restarts but skip config API-key
    /// credentials; the local usage tally covers those but only since tracking began.
    /// Neither undercounts the other's blind spot, so take the larger.
    public var requestsLastHour: Int {
        let fromAccounts = accounts.reduce(0) { addingCounts($0, $1.requestsLastHour) }
        let fromUsage = usage.lastHour.reduce(0) { addingCounts($0, $1.requests) }
        return max(fromAccounts, fromUsage)
    }
    private func poll(generation current: Int) async -> Bool {
        do {
            guard let key = try keyStore.read(), !key.isEmpty else {
                guard generation == current else { return false }
                hasKey = false; connection = .needsKey; return false
            }
            guard let url = BaseURLValidator.validate(baseURLString) else { throw ManagementError.invalidBaseURL }
            hasKey = true
            let client = clientFactory(url, key)
            // Drain first: its short-lived queue must not wait for slow live quota calls.
            let drain = try await client.drainUsageQueueResult()
            await aggregator.ingest(drain.records)
            let response = try await client.authFiles()
            guard generation == current, !Task.isCancelled else { return false }
            let now = Date()
            lastResponse = response
            accounts = AccountMapper.accounts(from: response, live: liveQuotaEnabled ? live : [:], now: now)
            let summary = await aggregator.summary(now: now)
            guard generation == current, !Task.isCancelled else { return false }
            usage = summary
            usageAvailable = drain.available; lastUpdated = now; connection = .connected(at: now)
            if liveQuotaEnabled && liveTask == nil {
                liveTask = Task { [weak self] in
                    await self?.fetchLive(response.files, client: client, now: now, generation: current)
                    guard self?.generation == current else { return }
                    self?.liveTask = nil
                }
            }
            return true
        } catch {
            guard generation == current, !Task.isCancelled else { return false }
            switch error as? ManagementError {
            case .proxyDown(let message): connection = .proxyDown(message)
            case .unauthorized: connection = .keyRejected
            case .http(let code): connection = .failed("HTTP \(code)")
            case .decoding: connection = .failed("Invalid management response")
            case .invalidBaseURL: connection = .failed("Invalid gateway URL")
            case nil: connection = .failed("Unable to read management key")
            }
            return true
        }
    }
    private func fetchLive(_ files: [AuthFile], client: ManagementClient, now: Date, generation current: Int) async {
        let jobs = files.compactMap { file -> (String, Provider, APICallRequest)? in
            guard let request = LiveQuotaFetcher.request(for: file),
                  now.timeIntervalSince(liveAttempts[request.authIndex] ?? .distantPast) >= 300 else { return nil }
            return (request.authIndex, Provider(raw: file.provider ?? file.type ?? ""), request)
        }
        for job in jobs { liveAttempts[job.0] = now }
        let results = await withTaskGroup(of: (String, LiveQuota?).self) { group in
            var next = 0
            func submit(_ job: (String, Provider, APICallRequest)) {
                group.addTask {
                    guard !Task.isCancelled, let response = try? await client.apiCall(job.2) else { return (job.0, nil) }
                    return (job.0, LiveQuotaFetcher.parse(provider: job.1, response: response, now: now))
                }
            }
            while next < min(3, jobs.count) { submit(jobs[next]); next += 1 }
            var result: [(String, LiveQuota?)] = []
            for await entry in group {
                result.append(entry)
                if next < jobs.count && !Task.isCancelled { submit(jobs[next]); next += 1 }
            }
            return result
        }
        guard generation == current else { return }
        let indexes = Set(files.compactMap(\.authIndex))
        live = live.filter { indexes.contains($0.key) }
        for (index, quota) in results { if let quota { live[index] = quota } else { live[index] = nil } }
        if liveQuotaEnabled, let response = lastResponse {
            accounts = AccountMapper.accounts(from: response, live: live, now: Date())
        }
    }
    public static func demo() -> IslandModel {
        // Dedicated volatile defaults and in-memory key store: no credentials or network.
        let defaults = UserDefaults(suiteName: "dev.ksotis.dynamic-island.demo") ?? .standard
        let model = IslandModel(keyStore: InMemoryKeyStore(), defaults: defaults, aggregator: UsageAggregator(persistenceURL: nil))
        model.isDemo = true
        let now = Date(); let reference = Fixtures.referenceNow; let shift = now.timeIntervalSince(reference)
        if let response = try? JSONDecoder().decode(AuthFilesResponse.self, from: Fixtures.data("auth-files")) {
            model.accounts = AccountMapper.accounts(from: response, live: [:], now: reference).map { account in
                var a = account
                a.windows = a.windows.map { window in var w = window; w.resetsAt = w.resetsAt?.addingTimeInterval(shift); return w }
                switch a.quotaSource { case .headers(let observed): a.quotaSource = .headers(observedAt: observed.addingTimeInterval(shift)); default: break }
                if case .rateLimited(let until, let reason) = a.health { a.health = .rateLimited(until: until?.addingTimeInterval(shift), reason: reason) }
                return a
            }
        }
        if let batch = try? JSONDecoder().decode(UsageQueueBatch.self, from: Fixtures.data("usage-queue")) {
            func totals(_ records: [UsageRecord]) -> [ModelUsage] {
                Dictionary(grouping: records, by: { $0.model ?? $0.alias ?? "unknown" }).map { name, records in
                    ModelUsage(model: name, requests: records.count, failed: records.filter { $0.failed == true }.count,
                               inputTokens: records.reduce(0) { $0 + nonnegative($1.tokens?.inputTokens) },
                               outputTokens: records.reduce(0) { $0 + nonnegative($1.tokens?.outputTokens) },
                               totalTokens: records.reduce(0) { $0 + nonnegative($1.tokens?.totalTokens) })
                }.sorted { $0.totalTokens == $1.totalTokens ? $0.model < $1.model : $0.totalTokens > $1.totalTokens }
            }
            model.usage = UsageSummary(lastHour: totals(batch.records.filter { ($0.timestamp ?? reference) > reference.addingTimeInterval(-3600) }), today: totals(batch.records), trackingSince: now.addingTimeInterval(-7200))
        }
        model.connection = .connected(at: now); model.lastUpdated = now
        return model
    }
}
