import Foundation
import Observation

@MainActor @Observable public final class ProjectUsageMonitor {
    public static var defaultRoots: [ProjectUsageSource: URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [.claudeCode: home.appendingPathComponent(".claude/projects"),
                .codex: home.appendingPathComponent(".codex/sessions")]
    }
    public private(set) var log: ProjectUsageLogState = .loading
    public private(set) var warning: String?
    public private(set) var lastResponse: Date?
    public private(set) var isDemo = false
    public private(set) var progress = ProjectUsageProgress()
    public private(set) var isLoadingProjectPage = false
    public private(set) var hasCachedUsage = false
    private var latestReports: [ProjectUsageReportKey: ProjectUsageReport] = [:]
    private var publishedState: ProjectUsageLogState?
    private var publishedWarning: String?
    private var stalePages: Set<ProjectUsageReportKey> = []
    private var pages: [ProjectUsageReportKey: Int] = [:]
    private var reports: [ProjectUsageReportKey: ProjectUsageReport] = [:]
    private let roots: [ProjectUsageSource: URL]
    private let scanner: ProjectUsageScanner
    private let now: @Sendable () -> Date
    private let calendar: @Sendable () -> Calendar
    private let pollInterval: Duration
    private var polling: Task<Void, Never>?
    private var reloading: Task<Void, Never>?
    private var worker: Task<ProjectUsageScanResult, Error>?
    private var pageWorker: Task<ProjectUsageReport?, Error>?
    private var pageGeneration: UInt64 = 0
    private var selectedProjectKey: ProjectUsageReportKey?
    private var generation: UInt64 = 0
    private var reloadRequested = false

    public convenience init(
        roots: [ProjectUsageSource: URL] = ProjectUsageMonitor.defaultRoots,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { Date() },
        pollInterval: Duration = .seconds(10),
        calendarProvider: (@Sendable () -> Calendar)? = nil
    ) {
        self.init(roots: roots, scanner: ProjectUsageScanner(
            indexURL: roots == ProjectUsageMonitor.defaultRoots ? ProjectUsageScanner.defaultIndexURL : nil),
            calendar: calendar, now: now, pollInterval: pollInterval, calendarProvider: calendarProvider)
    }

    init(roots: [ProjectUsageSource: URL], scanner: ProjectUsageScanner,
         calendar: Calendar = .autoupdatingCurrent,
         now: @escaping @Sendable () -> Date = { Date() },
         pollInterval: Duration = .seconds(10), calendarProvider: (@Sendable () -> Calendar)? = nil) {
        self.roots = roots; self.scanner = scanner; self.now = now
        self.calendar = calendarProvider ?? { calendar }; self.pollInterval = pollInterval
    }

    public func report(for range: UsageRange, source: ProjectUsageSource? = nil) -> ProjectUsageReport? {
        guard log == .loaded || hasCachedUsage else { return nil }
        return reports[.init(range: range, source: source)]
    }

    public func projectPageNumber(for range: UsageRange, source: ProjectUsageSource? = nil) -> Int {
        pages[.init(range: range, source: source)] ?? 1
    }

    public func projectPageIsStale(for range: UsageRange, source: ProjectUsageSource? = nil) -> Bool {
        stalePages.contains(.init(range: range, source: source))
    }

    public func selectProjectReport(for range: UsageRange, source: ProjectUsageSource? = nil) {
        pageGeneration &+= 1
        pageWorker?.cancel(); pageWorker = nil; isLoadingProjectPage = false
        selectedProjectKey = .init(range: range, source: source)
        refreshProjectList(for: range, source: source)
    }

    public func refreshProjectList(for range: UsageRange, source: ProjectUsageSource? = nil) {
        let key = ProjectUsageReportKey(range: range, source: source)
        guard let latest = latestReports[key] else { return }
        reports[key] = latest; pages[key] = 1; stalePages.remove(key)
    }

    public func loadProjectPage(for range: UsageRange, source: ProjectUsageSource? = nil,
                                direction: ProjectUsagePageDirection) async {
        let key = ProjectUsageReportKey(range: range, source: source)
        guard !isDemo, !isLoadingProjectPage, !stalePages.contains(key),
              selectedProjectKey == nil || selectedProjectKey == key, let report = reports[key],
              direction == .next ? report.hasNext : report.hasPrevious else { return }
        let currentGeneration = generation, currentPageGeneration = pageGeneration
        let cursor = direction == .next ? report.lastCursor : report.firstCursor
        isLoadingProjectPage = true
        defer {
            if generation == currentGeneration && pageGeneration == currentPageGeneration {
                isLoadingProjectPage = false; pageWorker = nil
            }
        }
        let task = Task.detached { [scanner] in
            try Task.checkCancellation()
            return try await scanner.projectPage(key: key, cursor: cursor, direction: direction, revision: report.revision)
        }
        pageWorker = task
        let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        guard !Task.isCancelled, generation == currentGeneration, pageGeneration == currentPageGeneration,
              reports[key]?.revision == report.revision,
              latestReports[key]?.revision == report.revision else { return }
        if case .success(let updated?) = result {
            reports[key] = updated
            pages[key] = max(1, (pages[key] ?? 1) + (direction == .next ? 1 : -1))
        }
    }

    public func start() {
        guard !isDemo, polling == nil else { return }
        polling = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                await self?.reload()
                do { try await Task.sleep(for: pollInterval) }
                catch { break }
            }
        }
    }

    public func stop() {
        generation &+= 1
        polling?.cancel(); polling = nil
        worker?.cancel(); worker = nil
        pageWorker?.cancel(); pageWorker = nil; isLoadingProjectPage = false
        reloading?.cancel(); reloading = nil
        reloadRequested = false
        let stoppedGeneration = generation
        Task { [weak self, scanner] in
            guard let self, self.generation == stoppedGeneration else { return }
            await scanner.cancel()
        }
    }

    public func refresh() {
        guard !isDemo else { return }
        let requestedGeneration = generation
        Task { [weak self] in
            guard let self, self.generation == requestedGeneration else { return }
            await self.reload()
        }
    }

    /// Overlapping requests share one serial scan, with at most one pending follow-up.
    /// Cancellation goes directly to the running task, never queues behind its actor.
    public func reload() async {
        guard !isDemo, !Task.isCancelled else { return }
        reloadRequested = true
        if reloading == nil {
            let currentGeneration = generation
            reloading = Task { [weak self] in
                guard let self else { return }
                while self.reloadRequested && !Task.isCancelled && self.generation == currentGeneration {
                    self.reloadRequested = false
                    await self.load(generation: currentGeneration)
                    if self.reloadRequested { await Task.yield() }
                }
                if self.generation == currentGeneration { self.reloading = nil }
            }
        }
        await reloading?.value
    }

    private func load(generation currentGeneration: UInt64) async {
        let date = now(), calendar = calendar()
        let task = Task.detached { [scanner, roots] in
            let result = try await scanner.scan(roots: roots, now: date, calendar: calendar)
            try Task.checkCancellation()
            return result
        }
        worker = task
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: { task.cancel() }
        guard !Task.isCancelled, generation == currentGeneration else { return }
        worker = nil
        switch result {
        case .success(let result):
            progress = result.progress
            if let publication = result.publication {
                log = publication.state; warning = publication.warning; lastResponse = publication.lastResponse
                publishedState = publication.state; publishedWarning = publication.warning
                latestReports = publication.reports
                for (key, latest) in publication.reports {
                    if (pages[key] ?? 1) > 1, var current = reports[key], current.revision != latest.revision {
                        // Keep the browsed rows visible; refreshing a changed snapshot is explicit.
                        current.totals = latest.totals; current.projectCount = latest.projectCount
                        reports[key] = current; stalePages.insert(key)
                    } else {
                        reports[key] = latest; pages[key] = 1; stalePages.remove(key)
                    }
                }
                if publication.state == .loaded || publication.lastResponse != nil ||
                    publication.reports.values.contains(where: { $0.totals.responses > 0 }) { hasCachedUsage = true }
            } else if let publishedState {
                // An unchanged successful pass still recovers from a transient worker failure.
                log = publishedState; warning = publishedWarning
            }
            if result.needsMoreWork { reloadRequested = true }
        case .failure(let error):
            if error is CancellationError { return }
            log = .unreadable("Local usage index couldn't be updated")
            progress = .init(stale: true)
            warning = "Cached local totals may be stale. The source logs were not modified."
        }
    }

    public static func demo(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> ProjectUsageMonitor {
        let monitor = ProjectUsageMonitor(roots: [:], calendar: calendar, now: { now })
        monitor.isDemo = true
        let projects = ["/demo/workspace/dynamic-island", "/demo/workspace/website", "/demo/tools/router"]
        var snapshot = ProjectUsageSnapshot(state: .loaded)
        for day in 0..<30 {
            guard let date = calendar.date(byAdding: .day, value: -day, to: now) else { continue }
            for (index, path) in projects.enumerated() {
                let input = (index + 1) * 2400 + day * 13
                snapshot.records.append(.init(source: index == 1 ? .codex : .claudeCode,
                    session: "demo-\(index)", response: "demo-\(day)-\(index)", timestamp: date,
                    explicitCWD: path, totals: .init(responses: 1, inputTokens: input, outputTokens: 300,
                        cacheReadTokens: input / 3, cacheWriteTokens: 0, totalTokens: input + 300),
                    file: "demo", line: day))
            }
        }
        let publication = ProjectUsageReducer.publish(snapshot, now: now, calendar: calendar)
        monitor.log = .loaded; monitor.reports = publication.reports; monitor.latestReports = publication.reports
        monitor.hasCachedUsage = true
        monitor.lastResponse = publication.lastResponse; monitor.progress = .init(ready: true)
        return monitor
    }
}
