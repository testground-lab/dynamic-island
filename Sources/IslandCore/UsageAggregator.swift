import Foundation

public actor UsageAggregator {
    private struct Bucket: Codable, Equatable {
        var minute: Int
        var model: String
        var requests: Int = 0
        var failed: Int = 0
        var input: Int = 0
        var output: Int = 0
        var total: Int = 0
    }

    private struct BucketKey: Hashable {
        let minute: Int
        let model: String
    }

    private struct Snapshot: Codable {
        var trackingSince: Date?
        var buckets: [Bucket]
    }

    private var buckets: [BucketKey: Bucket] = [:]
    private var trackingSince: Date?
    nonisolated let initialSummary: UsageSummary
    private let persistenceURL: URL?
    private let calendar: Calendar
    private let nowProvider: @Sendable () -> Date

    public init(
        persistenceURL: URL?, calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        initialRecords: [UsageRecord] = []
    ) {
        self.persistenceURL = persistenceURL
        self.calendar = calendar
        self.nowProvider = now
        if let url = persistenceURL,
            let data = try? Data(contentsOf: url),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        {
            trackingSince = snapshot.trackingSince
            let current = now()
            var models: Set<String> = []
            for var bucket in snapshot.buckets.sorted(by: { $0.model < $1.model }) {
                guard bucket.requests >= 0, bucket.failed >= 0, bucket.input >= 0,
                    bucket.output >= 0, bucket.total >= 0,
                    let minute = Self.boundedMinute(
                        Date(timeIntervalSince1970: Double(bucket.minute)), now: current)
                else {
                    continue
                }
                bucket.minute = minute
                bucket.model = Self.boundedModel(bucket.model, models: models)
                models.insert(bucket.model)
                let key = BucketKey(minute: bucket.minute, model: bucket.model)
                buckets[key] = Self.merge(buckets[key], bucket)
            }
        }
        let current = now()
        if !initialRecords.isEmpty {
            Self.accumulate(
                initialRecords, now: current, buckets: &buckets, trackingSince: &trackingSince)
        }
        initialSummary = Self.makeSummary(
            buckets: buckets, trackingSince: trackingSince, calendar: calendar, now: current)
    }

    public func ingest(_ records: [UsageRecord]) {
        let now = nowProvider()
        let previousBuckets = buckets
        let previousTrackingSince = trackingSince
        Self.accumulate(records, now: now, buckets: &buckets, trackingSince: &trackingSince)
        if previousBuckets != buckets || previousTrackingSince != trackingSince { persist() }
    }

    private static func accumulate(
        _ records: [UsageRecord], now: Date,
        buckets: inout [BucketKey: Bucket], trackingSince: inout Date?
    ) {
        if trackingSince == nil { trackingSince = now }
        let oldestMinute = floor((now.timeIntervalSince1970 - 48 * 3600) / 60) * 60
        buckets = buckets.filter { Double($0.key.minute) >= oldestMinute }
        var models = Set(buckets.keys.map(\.model))
        for record in records {
            guard let minute = Self.boundedMinute(record.timestamp ?? now, now: now) else {
                continue
            }
            let rawModel =
                [record.model, record.alias].compactMap { $0 }.first { !$0.isEmpty } ?? "unknown"
            let model = Self.boundedModel(rawModel, models: models)
            models.insert(model)
            let key = BucketKey(minute: minute, model: model)
            let input = nonnegative(record.tokens?.inputTokens)
            let output = nonnegative(record.tokens?.outputTokens)
            let supplied = nonnegative(record.tokens?.totalTokens)
            let total =
                supplied > 0
                ? supplied
                : addingCounts(
                    addingCounts(input, output), nonnegative(record.tokens?.reasoningTokens))
            let addition = Bucket(
                minute: minute, model: model, requests: 1, failed: record.failed == true ? 1 : 0,
                input: input, output: output, total: total
            )
            buckets[key] = Self.merge(buckets[key], addition)
        }
    }

    private static func boundedMinute(_ date: Date, now: Date) -> Int? {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= now.timeIntervalSince1970 - 48 * 3600 else { return nil }
        return safeInteger(floor(min(seconds, now.timeIntervalSince1970) / 60) * 60)
    }

    private static func boundedModel(_ name: String, models: Set<String>) -> String {
        let truncated = String((name.isEmpty ? "unknown" : name).prefix(64))
        if models.contains(truncated) { return truncated }
        // Reserve one of the 50 slots for overflow, so total cardinality never exceeds 50.
        let capacity = models.contains("other") ? 50 : 49
        return models.count < capacity ? truncated : "other"
    }

    private static func merge(_ existing: Bucket?, _ addition: Bucket) -> Bucket {
        guard var result = existing else { return addition }
        result.requests = addingCounts(result.requests, addition.requests)
        result.failed = addingCounts(result.failed, addition.failed)
        result.input = addingCounts(result.input, addition.input)
        result.output = addingCounts(result.output, addition.output)
        result.total = addingCounts(result.total, addition.total)
        return result
    }

    public func summary(now: Date) -> UsageSummary {
        Self.makeSummary(
            buckets: buckets, trackingSince: trackingSince, calendar: calendar, now: now)
    }

    private static func makeSummary(
        buckets: [BucketKey: Bucket], trackingSince: Date?, calendar: Calendar, now: Date
    ) -> UsageSummary {
        let hour = now.timeIntervalSince1970 - 3600
        let today = calendar.startOfDay(for: now).timeIntervalSince1970
        let end = now.timeIntervalSince1970
        return UsageSummary(
            lastHour: summarize(buckets) { Double($0.minute) > hour && Double($0.minute) <= end },
            today: summarize(buckets) { Double($0.minute) >= today && Double($0.minute) <= end },
            trackingSince: trackingSince
        )
    }

    private static func summarize(_ buckets: [BucketKey: Bucket], _ include: (Bucket) -> Bool)
        -> [ModelUsage]
    {
        var result: [String: ModelUsage] = [:]
        for bucket in buckets.values where include(bucket) {
            var model =
                result[bucket.model]
                ?? ModelUsage(
                    model: bucket.model, requests: 0, failed: 0, inputTokens: 0, outputTokens: 0,
                    totalTokens: 0)
            model.requests = addingCounts(model.requests, bucket.requests)
            model.failed = addingCounts(model.failed, bucket.failed)
            model.inputTokens = addingCounts(model.inputTokens, bucket.input)
            model.outputTokens = addingCounts(model.outputTokens, bucket.output)
            model.totalTokens = addingCounts(model.totalTokens, bucket.total)
            result[bucket.model] = model
        }
        return result.values.sorted {
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            if $0.requests != $1.requests { return $0.requests > $1.requests }
            return $0.model < $1.model
        }
    }

    public func reset() {
        guard !buckets.isEmpty || trackingSince != nil else { return }
        buckets = [:]
        trackingSince = nil
        persist()
    }

    private func persist() {
        guard let url = persistenceURL,
            let data = try? JSONEncoder().encode(
                Snapshot(trackingSince: trackingSince, buckets: Array(buckets.values)))
        else {
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
