import Foundation
import Observation

@MainActor @Observable public final class IslandModel {
    public private(set) var accounts: [Account] = []
    public private(set) var usageReports: [UsageRange: UsageReport] = [:]
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
    @ObservationIgnored private let store: UsageStore
    @ObservationIgnored private let nowProvider: @Sendable () -> Date
    @ObservationIgnored private let clientFactory: @Sendable (URL, String) -> ManagementClient
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var lastResponse: AuthFilesResponse?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var live: [String: LiveQuota] = [:]
    @ObservationIgnored private var liveAttempts: [String: Date] = [:]
    @ObservationIgnored private var isDemo = false
    @ObservationIgnored private var lastReportDay: Date?
    @ObservationIgnored private var lastReportAccounts: [Account]?
    @ObservationIgnored private var reportsDirty = true

    public init(
        keyStore: any KeyStore, defaults: UserDefaults = .standard, store: UsageStore,
        clientFactory: @escaping @Sendable (URL, String) -> ManagementClient = {
            ManagementClient(baseURL: $0, key: $1)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.keyStore = keyStore
        self.defaults = defaults
        self.store = store
        self.usageReports = store.initialReports
        self.clientFactory = clientFactory
        self.nowProvider = now
        baseURLString = defaults.string(forKey: "baseURL") ?? BaseURLValidator.defaultBaseURL
        liveQuotaEnabled =
            defaults.object(forKey: "liveQuotaEnabled") == nil
            ? true : defaults.bool(forKey: "liveQuotaEnabled")
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
                guard let shouldContinue = await self?.poll(generation: current), shouldContinue
                else { break }
                let remaining = Duration.seconds(15) - started.duration(to: .now)
                do { try await Task.sleep(for: max(.zero, remaining)) } catch { break }
            }
            if self?.generation == current { self?.task = nil }
        }
    }
    public func stop() {
        generation += 1
        task?.cancel()
        task = nil
        liveTask?.cancel()
        liveTask = nil
    }
    public func refreshNow() {
        guard !isDemo else { return }
        stop()
        start()
    }
    public func saveKey(_ key: String) throws {
        try keyStore.save(key)
        hasKey = true
        connection = .connecting
        live = [:]
        liveAttempts = [:]
        refreshNow()
    }
    public func clearKey() throws {
        try keyStore.delete()
        stop()
        hasKey = false
        connection = .needsKey
        accounts = []
        usageReports = [:]
        reportsDirty = true
        lastUpdated = nil
        live = [:]
        liveAttempts = [:]
    }
    public func applyBaseURL(_ string: String) -> Bool {
        guard let url = BaseURLValidator.validate(string) else { return false }
        baseURLString = url.absoluteString
        connection = .connecting
        defaults.set(baseURLString, forKey: "baseURL")
        live = [:]
        liveAttempts = [:]
        refreshNow()
        return true
    }
    private func poll(generation current: Int) async -> Bool {
        do {
            guard let key = try keyStore.read(), !key.isEmpty else {
                guard generation == current else { return false }
                hasKey = false
                connection = .needsKey
                return false
            }
            guard let url = BaseURLValidator.validate(baseURLString) else {
                throw ManagementError.invalidBaseURL
            }
            hasKey = true
            let client = clientFactory(url, key)
            // Drain first: its short-lived queue must not wait for slow live quota calls.
            let drain: UsageDrainResult?
            do {
                drain = try await client.drainUsageQueueResult()
            } catch ManagementError.unauthorized {
                throw ManagementError.unauthorized
            } catch {
                guard !Task.isCancelled else { throw CancellationError() }
                drain = nil
            }
            if let drain, drain.available {
                if await store.ingest(drain.records) { reportsDirty = true }
            }
            let response = try await client.authFiles()
            guard generation == current, !Task.isCancelled else { return false }
            let now = nowProvider()
            lastResponse = response
            pruneLive(for: response.files)
            accounts = AccountMapper.accounts(
                from: response, live: liveQuotaEnabled ? live : [:], now: now)
            await refreshUsageReports(now: now, generation: current)
            guard generation == current, !Task.isCancelled else { return false }
            if let drain { usageAvailable = drain.available }
            lastUpdated = now
            connection = .connected(at: now)
            if liveQuotaEnabled && liveTask == nil {
                liveTask = Task { [weak self] in
                    await self?.fetchLive(
                        response.files, client: client, now: now, generation: current)
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
            case .responseTooLarge: connection = .failed("Management response too large")
            case .tls: connection = .failed("TLS error")
            case nil: connection = .failed("Unable to read management key")
            }
            await refreshUsageReports(now: nowProvider(), generation: current)
            guard generation == current, !Task.isCancelled else { return false }
            return true
        }
    }
    private func refreshUsageReports(now: Date, generation current: Int) async {
        let day = store.dayStart(now: now)
        let currentAccounts = accounts
        guard reportsDirty || lastReportDay != day || lastReportAccounts != currentAccounts else {
            return
        }
        var reports: [UsageRange: UsageReport] = [:]
        for range in UsageRange.allCases {
            reports[range] = await store.report(range, accounts: currentAccounts, now: now)
        }
        guard generation == current, !Task.isCancelled else { return }
        if reports != usageReports { usageReports = reports }
        reportsDirty = false
        lastReportDay = day
        lastReportAccounts = currentAccounts
    }

    private func fetchLive(
        _ files: [AuthFile], client: ManagementClient, now: Date, generation current: Int
    ) async {
        let jobs = files.compactMap { file -> (String, Provider, APICallRequest)? in
            guard let request = LiveQuotaFetcher.request(for: file),
                now.timeIntervalSince(liveAttempts[request.authIndex] ?? .distantPast) >= 300
            else { return nil }
            return (request.authIndex, Provider(raw: file.provider ?? file.type ?? ""), request)
        }
        for job in jobs { liveAttempts[job.0] = now }
        let results = await withTaskGroup(of: (String, LiveQuota?).self) { group in
            var next = 0
            func submit(_ job: (String, Provider, APICallRequest)) {
                group.addTask {
                    guard !Task.isCancelled, let response = try? await client.apiCall(job.2) else {
                        return (job.0, nil)
                    }
                    return (
                        job.0, LiveQuotaFetcher.parse(provider: job.1, response: response, now: now)
                    )
                }
            }
            while next < min(3, jobs.count) {
                submit(jobs[next])
                next += 1
            }
            var result: [(String, LiveQuota?)] = []
            for await entry in group {
                result.append(entry)
                if next < jobs.count && !Task.isCancelled {
                    submit(jobs[next])
                    next += 1
                }
            }
            return result
        }
        guard generation == current else { return }
        let currentFiles = lastResponse?.files ?? files
        let indexes = Set(currentFiles.compactMap(\.authIndex))
        pruneLive(for: currentFiles)
        for (index, quota) in results where indexes.contains(index) {
            if let quota { live[index] = quota }
        }
        if liveQuotaEnabled, let response = lastResponse {
            accounts = AccountMapper.accounts(from: response, live: live, now: nowProvider())
        }
    }
    private func pruneLive(for files: [AuthFile]) {
        let indexes = Set(files.compactMap(\.authIndex))
        live = live.filter { indexes.contains($0.key) }
        liveAttempts = liveAttempts.filter { indexes.contains($0.key) }
    }

    public static func demo() -> IslandModel {
        let now = Date()
        let reference = Fixtures.referenceNow
        let shift = now.timeIntervalSince(reference)
        let response =
            (try? JSONDecoder().decode(
                AuthFilesResponse.self, from: Fixtures.data("auth-files"))) ?? AuthFilesResponse()
        let accounts = AccountMapper.accounts(from: response, live: [:], now: reference).map {
            account in
            var result = account
            result.windows = result.windows.map { window in
                var shifted = window
                shifted.resetsAt = shifted.resetsAt?.addingTimeInterval(shift)
                return shifted
            }
            if case .headers(let observed) = result.quotaSource {
                result.quotaSource = .headers(observedAt: observed.addingTimeInterval(shift))
            }
            if case .rateLimited(let until, let reason) = result.health {
                result.health = .rateLimited(
                    until: until?.addingTimeInterval(shift), reason: reason)
            }
            return result
        }
        let records =
            ((try? JSONDecoder().decode(
                UsageQueueBatch.self, from: Fixtures.data("usage-history")))?.records ?? []).map {
                record in
                var shifted = record
                shifted.timestamp = record.timestamp?.addingTimeInterval(shift)
                return shifted
            }
        let trackingSince = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -20, to: now)
        let store = UsageStore(
            url: nil, now: { now }, initialRecords: records,
            initialAccounts: accounts, trackingSince: trackingSince)
        let defaults = UserDefaults(suiteName: "dev.ksotis.dynamic-island.demo") ?? .standard
        let model = IslandModel(keyStore: InMemoryKeyStore(), defaults: defaults, store: store)
        model.isDemo = true
        model.accounts = accounts
        model.connection = .connected(at: now)
        model.lastUpdated = now
        return model
    }
}
