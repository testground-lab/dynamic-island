import Foundation

public actor UsageAggregator {
    private struct Bucket: Codable {
        var minute: Int
        var model: String
        var requests: Int = 0
        var failed: Int = 0
        var input: Int = 0
        var output: Int = 0
        var total: Int = 0
    }
    private struct BucketKey: Hashable { let minute: Int; let model: String }
    private struct Snapshot: Codable { var trackingSince: Date?; var buckets: [Bucket] }
    private var buckets: [BucketKey: Bucket] = [:]
    private var trackingSince: Date?
    private let persistenceURL: URL?
    private let calendar: Calendar
    private let nowProvider: @Sendable () -> Date
    public init(persistenceURL: URL?, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.persistenceURL = persistenceURL; self.calendar = calendar; self.nowProvider = now
        if let url = persistenceURL, let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            trackingSince = snapshot.trackingSince
            for bucket in snapshot.buckets where bucket.requests >= 0 && bucket.failed >= 0 && bucket.input >= 0 && bucket.output >= 0 && bucket.total >= 0 {
                buckets[BucketKey(minute: bucket.minute, model: bucket.model)] = bucket
            }
        }
    }
    public func ingest(_ records: [UsageRecord]) {
        let now = nowProvider()
        if trackingSince == nil { trackingSince = now }
        for record in records {
            let date = record.timestamp ?? now
            guard let minute = safeInteger(floor(date.timeIntervalSince1970 / 60) * 60) else { continue }
            let model = [record.model, record.alias].compactMap { $0 }.first { !$0.isEmpty } ?? "unknown"
            let key = BucketKey(minute: minute, model: model)
            var bucket = buckets[key] ?? Bucket(minute: minute, model: model)
            let input = nonnegative(record.tokens?.inputTokens); let output = nonnegative(record.tokens?.outputTokens)
            let supplied = nonnegative(record.tokens?.totalTokens)
            let total = supplied > 0 ? supplied : addingCounts(addingCounts(input, output), nonnegative(record.tokens?.reasoningTokens))
            bucket.requests = addingCounts(bucket.requests, 1); bucket.failed = addingCounts(bucket.failed, record.failed == true ? 1 : 0)
            bucket.input = addingCounts(bucket.input, input); bucket.output = addingCounts(bucket.output, output); bucket.total = addingCounts(bucket.total, total)
            buckets[key] = bucket
        }
        buckets = buckets.filter { Double($0.key.minute) >= now.timeIntervalSince1970 - 48 * 3600 }
        persist()
    }
    public func summary(now: Date) -> UsageSummary {
        let hour = now.timeIntervalSince1970 - 3600
        let today = calendar.startOfDay(for: now).timeIntervalSince1970
        let end = now.timeIntervalSince1970
        return UsageSummary(lastHour: summarize { Double($0.minute) > hour && Double($0.minute) <= end },
                            today: summarize { Double($0.minute) >= today && Double($0.minute) <= end }, trackingSince: trackingSince)
    }
    private func summarize(_ include: (Bucket) -> Bool) -> [ModelUsage] {
        var result: [String: ModelUsage] = [:]
        for b in buckets.values where include(b) {
            var m = result[b.model] ?? ModelUsage(model: b.model, requests: 0, failed: 0, inputTokens: 0, outputTokens: 0, totalTokens: 0)
            m.requests = addingCounts(m.requests, b.requests); m.failed = addingCounts(m.failed, b.failed)
            m.inputTokens = addingCounts(m.inputTokens, b.input); m.outputTokens = addingCounts(m.outputTokens, b.output); m.totalTokens = addingCounts(m.totalTokens, b.total)
            result[b.model] = m
        }
        return result.values.sorted {
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            if $0.requests != $1.requests { return $0.requests > $1.requests }
            return $0.model < $1.model
        }
    }
    public func reset() { buckets = [:]; trackingSince = nil; persist() }
    private func persist() {
        guard let url = persistenceURL, let data = try? JSONEncoder().encode(Snapshot(trackingSince: trackingSince, buckets: Array(buckets.values))) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
