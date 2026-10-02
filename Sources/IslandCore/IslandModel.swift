import Foundation
import Observation
import os

private let usageLog = Logger(subsystem: "dev.ksotis.dynamic-island", category: "usage")

@MainActor @Observable public final class IslandModel {
    public private(set) var accounts: [Account] = []
    public private(set) var usageReports: [UsageRange: UsageReport] = [:]
    public private(set) var usageSeries: [UsageRange: UsageSeries] = [:]
    public private(set) var connection: ConnectionState = .connecting
    public private(set) var lastUpdated: Date?
    public private(set) var usageAvailable = true
    /// Last usage-queue read failure other than 401/404 (short, no secrets).
    public private(set) var usageQueueError: String?
    /// Last logged queue failure, so a failure repeated every poll is logged once.
    @ObservationIgnored private var lastLoggedQueueFailure: String?
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
    @ObservationIgnored private var lastReportHour: Date?
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
        self.usageSeries = store.initialSeries
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
        resetUsageStatus()
        refreshNow()
    }
    public func clearKey() throws {
        try keyStore.delete()
        stop()
        hasKey = false
        connection = .needsKey
        accounts = []
        usageReports = [:]
        usageSeries = [:]
        reportsDirty = true
        lastUpdated = nil
        live = [:]
        liveAttempts = [:]
        resetUsageStatus()
    }

    /// Queue status belongs to the proxy and key it was observed with.
    private func resetUsageStatus() {
        usageAvailable = true
        usageQueueError = nil
        lastLoggedQueueFailure = nil
    }
    public func applyBaseURL(_ string: String) -> Bool {
        guard let url = BaseURLValidator.validate(string) else { return false }
        baseURLString = url.absoluteString
        connection = .connecting
        resetUsageStatus()
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
                usageLog.notice("no management key stored; usage-queue not polled")
                return false
            }
            guard let url = BaseURLValidator.validate(baseURLString) else {
                throw ManagementError.invalidBaseURL
            }
            hasKey = true
            let client = clientFactory(url, key)
            // Drain first: its short-lived queue must not wait for slow live quota calls.
            let drain: UsageDrainResult?
            var queueError: String?
            do {
                drain = try await client.drainUsageQueueResult()
                if let drain {
                    if drain.records.isEmpty {
                        usageLog.debug("usage-queue read: 0 records, available=\(drain.available, privacy: .public)")
                    } else {
                        usageLog.notice("usage-queue read: \(drain.records.count, privacy: .public) records, available=\(drain.available, privacy: .public)")
                    }
                }
            } catch ManagementError.unauthorized {
                if generation == current, !Task.isCancelled { logQueueFailure("401 unauthorized") }
                throw ManagementError.unauthorized
            } catch {
                guard !Task.isCancelled else { throw CancellationError() }
                let reason = Self.describe(error)
                queueError = reason
                if generation == current { logQueueFailure(reason) }
                drain = nil
            }
            guard generation == current else { return false }
            usageQueueError = queueError
            if queueError == nil { lastLoggedQueueFailure = nil }
            if let drain, drain.available || !drain.records.isEmpty {
                if await store.ingest(drain.records, trackingAvailable: drain.available) {
                    reportsDirty = true
                }
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
    private func logQueueFailure(_ reason: String) {
        guard reason != lastLoggedQueueFailure else { return }
        lastLoggedQueueFailure = reason
        usageLog.error("usage-queue read failed: \(reason, privacy: .public)")
    }

    /// Short, secret-free description of a management error.
    static func describe(_ error: Error) -> String {
        switch error as? ManagementError {
        case .proxyDown: "proxy not reachable"
        case .unauthorized: "key rejected (401)"
        case .http(let code): "HTTP \(code)"
        case .decoding: "unreadable response"
        case .invalidBaseURL: "invalid proxy address"
        case .responseTooLarge: "response too large"
        case .tls: "TLS error"
        case nil: "unexpected error"
        }
    }

    /// Why the Usage section shows what it shows for `range`.
    public func usageState(for range: UsageRange) -> UsageState {
        UsageState.resolve(connection: connection, usageAvailable: usageAvailable,
                           queueError: usageQueueError, report: usageReports[range])
    }

    private func refreshUsageReports(now: Date, generation current: Int) async {
        let day = store.dayStart(now: now)
        let hour = store.hourStart(now: now)
        let currentAccounts = accounts
        guard reportsDirty || lastReportDay != day || lastReportHour != hour
            || lastReportAccounts != currentAccounts else { return }
        var reports: [UsageRange: UsageReport] = [:]
        for range in UsageRange.allCases {
            reports[range] = await store.report(range, accounts: currentAccounts, now: now)
        }
        let series = await store.seriesAll(now: now)
        guard generation == current, !Task.isCancelled else { return }
        if reports != usageReports { usageReports = reports }
        if series != usageSeries { usageSeries = series }
        reportsDirty = false
        lastReportDay = day
        lastReportHour = hour
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
