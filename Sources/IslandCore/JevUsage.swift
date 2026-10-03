import Foundation
import CoreFoundation
import Observation
import os

public struct JevCall: Hashable, Sendable {
    public var timestamp: Date
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var latencyMs: Int?
    public var ok: Bool
    public var error: String?
    public var totalTokens: Int { addingCounts(inputTokens, outputTokens) }

    public init(
        timestamp: Date, model: String, inputTokens: Int, outputTokens: Int,
        latencyMs: Int? = nil, ok: Bool, error: String? = nil
    ) {
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.latencyMs = latencyMs
        self.ok = ok
        self.error = error
    }
}

public struct JevLogParse: Equatable, Sendable {
    public var calls: [JevCall]
    public var skippedLines: Int

    public init(calls: [JevCall], skippedLines: Int) {
        self.calls = calls
        self.skippedLines = skippedLines
    }
}

public enum JevLogRead: Equatable, Sendable {
    case missing
    case unreadable(String)
    case loaded(JevLogParse)
}

public enum JevLog {
    private static let maximumBytes = 64 * 1024 * 1024

    public static func parse(_ data: Data) -> JevLogParse {
        var calls: [JevCall] = []
        var skipped = 0
        for bytes in data.split(separator: 10, omittingEmptySubsequences: false) {
            var line = Data(bytes)
            if line.last == 13 { line.removeLast() }
            if let text = String(data: line, encoding: .utf8),
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            { continue }
            // JSONSerialization's untyped object is confined to this wire boundary.
            guard String(data: line, encoding: .utf8) != nil,
                let object = try? JSONSerialization.jsonObject(with: line),
                let fields = object as? [String: Any],
                let rawDate = fields["ts"] as? String,
                let timestamp = APIDateParser.parse(rawDate)
            else {
                skipped = addingCounts(skipped, 1)
                continue
            }
            let model = fields["model"] as? String ?? ""
            let error = fields["error"] as? String
            let boolean = fields["ok"] as? NSNumber
            let ok = boolean.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil }
            calls.append(JevCall(
                timestamp: timestamp, model: model.isEmpty ? "jev" : model,
                inputTokens: count(fields["input_tokens"]) ?? 0,
                outputTokens: count(fields["output_tokens"]) ?? 0,
                latencyMs: count(fields["latency_ms"]), ok: ok ?? (error == nil), error: error))
        }
        let sorted = calls.enumerated().sorted {
            if $0.element.timestamp != $1.element.timestamp {
                return $0.element.timestamp < $1.element.timestamp
            }
            return $0.offset < $1.offset
        }.map(\.element)
        return JevLogParse(calls: sorted, skippedLines: skipped)
    }

    private static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let double = number.doubleValue
        guard double.rounded(.towardZero) == double else { return nil }
        return safeInteger(double).map { max(0, $0) }
    }

    public static func read(_ url: URL) -> JevLogRead {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                return .unreadable("Not a regular file")
            }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size <= maximumBytes else {
                let megabytes = Int(ceil(Double(size) / (1024 * 1024)))
                return .unreadable("Too large to read (\(megabytes) MB)")
            }
            let data = try Data(contentsOf: url)
            guard data.count <= maximumBytes else {
                return .unreadable("Too large to read (\(Int(ceil(Double(data.count) / (1024 * 1024)))) MB)")
            }
            return .loaded(parse(data))
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError {
                return .missing
            }
            if (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError)
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(EACCES))
            { return .unreadable("Permission denied") }
            return .unreadable(String(error.localizedDescription.prefix(80)))
        }
    }
}

public enum JevPricing {
    /// USD per million input tokens. Output tokens are free at the moment.
    public static let inputUSDPerMillionTokens: Double = 0.042

    public static func estimatedSpendUSD(inputTokens: Int) -> Double {
        Double(max(0, inputTokens)) * inputUSDPerMillionTokens / 1_000_000
    }

    /// Cents from $0.01 up; below that up to four decimals, so a day's few
    /// hundredths of a cent still read as more than nothing.
    public static func formatted(usd: Double) -> String {
        guard !usd.isNaN, usd > 0 else { return "$0.00" }
        if usd < 0.0001 { return "<$0.0001" }
        let locale = Locale(identifier: "en_US_POSIX")
        if usd >= 0.01 { return String(format: "$%.2f", locale: locale, usd) }
        var result = String(format: "$%.4f", locale: locale, usd)
        while result.last == "0", result.count - (result.firstIndex(of: ".").map {
            result.distance(from: result.startIndex, to: $0)
        } ?? 0) - 1 > 2 {
            result.removeLast()
        }
        return result
    }
}

public struct JevTotals: Hashable, Sendable {
    public var requests: Int
    public var failed: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var failuresByError: [String: Int]
    public var totalTokens: Int { addingCounts(inputTokens, outputTokens) }
    public var estimatedSpendUSD: Double { JevPricing.estimatedSpendUSD(inputTokens: inputTokens) }

    public init(
        requests: Int = 0, failed: Int = 0, inputTokens: Int = 0, outputTokens: Int = 0,
        failuresByError: [String: Int] = [:]
    ) {
        self.requests = requests
        self.failed = failed
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.failuresByError = failuresByError
    }
}

public struct JevReport: Hashable, Sendable {
    public var range: UsageRange
    public var start: Date
    public var totals: JevTotals
    public var series: UsageSeries

    public init(range: UsageRange, start: Date, totals: JevTotals, series: UsageSeries) {
        self.range = range
        self.start = start
        self.totals = totals
        self.series = series
    }
}

public enum JevUsage {
    public static let chartProvider = Provider.other("jev")

    public static func report(
        _ calls: [JevCall], range: UsageRange, now: Date, calendar: Calendar
    ) -> JevReport {
        let start = range.start(now: now, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        var totals = JevTotals()
        var entries: [UsageSeries.Entry] = []
        for call in calls where call.timestamp >= start && call.timestamp < end {
            totals.requests = addingCounts(totals.requests, 1)
            totals.inputTokens = addingCounts(totals.inputTokens, call.inputTokens)
            totals.outputTokens = addingCounts(totals.outputTokens, call.outputTokens)
            if !call.ok {
                totals.failed = addingCounts(totals.failed, 1)
                let error = call.error ?? "unknown"
                totals.failuresByError[error] = addingCounts(totals.failuresByError[error] ?? 0, 1)
            }
            entries.append(.init(
                start: call.timestamp, provider: chartProvider,
                totals: UsageTotals(
                    requests: 1, failed: call.ok ? 0 : 1, inputTokens: call.inputTokens,
                    outputTokens: call.outputTokens, totalTokens: call.totalTokens)))
        }
        return JevReport(
            range: range, start: start, totals: totals,
            series: .binned(range, entries: entries, now: now, calendar: calendar,
                            trackingSince: .distantPast))
    }
}

public enum JevLogState: Equatable, Sendable {
    case loading, missing, unreadable(String), loaded
}

public enum JevViewState: Equatable, Sendable {
    case loading, missing, unreadable(String)
    case empty(lastCall: Date?)
    case data(JevReport)
}

@MainActor @Observable public final class JevUsageMonitor {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/jev-model-router/usage.jsonl")
    }

    public private(set) var log: JevLogState = .loading
    public private(set) var reports: [UsageRange: JevReport] = [:]
    public private(set) var lastCall: Date?
    private let url: URL?
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let pollInterval: Duration
    private var calls: [JevCall] = []
    private var signature: Signature?
    private var hour: Date?
    private var skippedLines: Int?
    private var polling: Task<Void, Never>?
    private var reloading: Task<Void, Never>?
    private var requestedReload = 0
    private var isDemo = false
    private static let logger = Logger(subsystem: "dev.ksotis.dynamic-island", category: "jev")

    private struct Signature: Equatable, Sendable {
        var inode: UInt64
        var size: UInt64
        var modified: Date?

        init(url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            modified = attributes[.modificationDate] as? Date
        }
    }

    public init(
        url: URL?, calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { Date() }, pollInterval: Duration = .seconds(10)
    ) {
        self.url = url
        self.calendar = calendar
        self.now = now
        self.pollInterval = pollInterval
    }

    public func start() {
        guard !isDemo, polling == nil else { return }
        polling = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                guard self != nil else { break }
                await self?.reload()
                do { try await Task.sleep(for: pollInterval) }
                catch { break }
            }
        }
    }

    public func stop() {
        polling?.cancel()
        polling = nil
    }

    public func refresh() {
        Task { [weak self] in await self?.reload() }
    }

    /// Concurrent callers share a worker; requests arriving during a read trigger one more read.
    public func reload() async {
        guard !isDemo else { return }
        requestedReload += 1
        if reloading == nil {
            reloading = Task { [weak self] in
                guard let self else { return }
                var force = false
                while true {
                    let generation = self.requestedReload
                    await self.load(force: force)
                    if self.requestedReload == generation { break }
                    force = true
                }
                self.reloading = nil
            }
        }
        await reloading?.value
    }

    private func load(force: Bool) async {
        guard let url else {
            clear(.missing)
            return
        }
        let date = now()
        let currentHour = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        let currentSignature = await Task.detached { try? Signature(url: url) }.value
        if !force, let currentSignature, currentSignature == signature, log == .loaded {
            if currentHour != hour { recompute(now: date) }
            return
        }
        let result = await Task.detached { JevLog.read(url) }.value
        switch result {
        case .missing: clear(.missing)
        case .unreadable(let reason): clear(.unreadable(reason))
        case .loaded(let parsed):
            log = .loaded
            calls = parsed.calls
            lastCall = calls.last?.timestamp
            signature = currentSignature
            if skippedLines != parsed.skippedLines {
                Self.logger.info("Skipped \(parsed.skippedLines) Jev usage log lines")
                skippedLines = parsed.skippedLines
            }
            recompute(now: date)
        }
    }

    private func clear(_ state: JevLogState) {
        log = state
        calls = []
        reports = [:]
        lastCall = nil
        signature = nil
        hour = nil
    }

    private func recompute(now: Date) {
        hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        reports = Dictionary(uniqueKeysWithValues: UsageRange.allCases.map {
            ($0, JevUsage.report(calls, range: $0, now: now, calendar: calendar))
        })
    }

    public func state(for range: UsageRange) -> JevViewState {
        switch log {
        case .loading: .loading
        case .missing: .missing
        case .unreadable(let reason): .unreadable(reason)
        case .loaded:
            if let report = reports[range], report.totals.requests > 0 { .data(report) }
            else { .empty(lastCall: lastCall) }
        }
    }

    public static func demo(
        now: Date = Date(), calendar: Calendar = .autoupdatingCurrent
    ) -> JevUsageMonitor {
        let monitor = JevUsageMonitor(url: nil, calendar: calendar, now: { now })
        monitor.isDemo = true
        var seed: UInt64 = 42
        func random(_ upper: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1
            return Int((seed >> 32) % UInt64(upper))
        }
        let start = UsageRange.month.start(now: now, calendar: calendar)
        for offset in 0..<30 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            let count = calendar.isDateInWeekend(day) ? 5 + random(16) : 20 + random(61)
            for _ in 0..<count {
                guard let timestamp = calendar.date(bySettingHour: 9 + random(11),
                    minute: random(60), second: random(60), of: day), timestamp <= now
                else { continue }
                let failed = random(100) < 3
                monitor.calls.append(JevCall(
                    timestamp: timestamp, model: "jev-latest",
                    inputTokens: failed ? 0 : 800 + random(5201),
                    outputTokens: failed ? 0 : 1 + random(8), latencyMs: 200 + random(1000),
                    ok: !failed, error: failed ? (random(2) == 0 ? "timeout" : "http_502") : nil))
            }
        }
        monitor.calls.sort { $0.timestamp < $1.timestamp }
        monitor.lastCall = monitor.calls.last?.timestamp
        monitor.log = .loaded
        monitor.recompute(now: now)
        return monitor
    }
}
