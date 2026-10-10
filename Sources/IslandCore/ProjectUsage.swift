import Foundation

public enum ProjectUsageSource: String, CaseIterable, Hashable, Sendable {
    case claudeCode, codex
    public var title: String { self == .claudeCode ? "Claude Code" : "Codex" }
}

public struct ProjectUsageTotals: Hashable, Sendable {
    public var responses: Int
    /// Includes cache reads and writes; cache counters below are subsets, not additions.
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var totalTokens: Int

    public init(responses: Int = 0, inputTokens: Int = 0, outputTokens: Int = 0,
                cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0, totalTokens: Int = 0) {
        self.responses = responses
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens
    }

    func adding(_ other: Self) -> Self? {
        let lhs = [responses, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, totalTokens]
        let rhs = [other.responses, other.inputTokens, other.outputTokens, other.cacheReadTokens,
                   other.cacheWriteTokens, other.totalTokens]
        var sums: [Int] = []
        for (a, b) in zip(lhs, rhs) {
            let (sum, overflow) = a.addingReportingOverflow(b)
            guard !overflow, a >= 0, b >= 0 else { return nil }
            sums.append(sum)
        }
        return Self(responses: sums[0], inputTokens: sums[1], outputTokens: sums[2],
                    cacheReadTokens: sums[3], cacheWriteTokens: sums[4], totalTokens: sums[5])
    }
}

public struct ProjectUsageRow: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var path: String?
    public var totals: ProjectUsageTotals
    public init(id: String, name: String, path: String?, totals: ProjectUsageTotals) {
        self.id = id; self.name = name; self.path = path; self.totals = totals
    }
}

public struct ProjectUsageProjectCursor: Hashable, Sendable {
    public var sortTokens: Int
    public var path: String
}

public enum ProjectUsagePageDirection: Sendable { case next, previous }

public struct ProjectUsageSourceProgress: Equatable, Sendable {
    public var source: ProjectUsageSource
    public var discoveredFiles: Int
    public var completedFiles: Int
    public var processedBytes: Int64
    public var knownBytes: Int64
    public var discoveryComplete: Bool
    public var stale: Bool
}

public struct ProjectUsageProgress: Equatable, Sendable {
    public var sources: [ProjectUsageSourceProgress]
    public var publishing: Bool
    public var ready: Bool
    public var stale: Bool
    public init(sources: [ProjectUsageSourceProgress] = [], publishing: Bool = false,
                ready: Bool = false, stale: Bool = false) {
        self.sources = sources; self.publishing = publishing; self.ready = ready; self.stale = stale
    }
}

public struct ProjectUsageReport: Hashable, Sendable {
    /// Full range/source totals, never just the visible project page.
    public var totals: ProjectUsageTotals
    public var projects: [ProjectUsageRow]
    public var projectCount: Int
    public var revision: Int64
    public var firstCursor: ProjectUsageProjectCursor?
    public var lastCursor: ProjectUsageProjectCursor?
    public var hasPrevious: Bool
    public var hasNext: Bool
    public init(totals: ProjectUsageTotals = .init(), projects: [ProjectUsageRow] = [],
                projectCount: Int? = nil, revision: Int64 = 0,
                firstCursor: ProjectUsageProjectCursor? = nil, lastCursor: ProjectUsageProjectCursor? = nil,
                hasPrevious: Bool = false, hasNext: Bool = false) {
        self.totals = totals; self.projects = projects; self.projectCount = projectCount ?? projects.count
        self.revision = revision; self.firstCursor = firstCursor; self.lastCursor = lastCursor
        self.hasPrevious = hasPrevious; self.hasNext = hasNext
    }
}

public enum ProjectUsageLogState: Equatable, Sendable {
    case loading, missing, unreadable(String), loaded
}

// Only these normalized values survive parsing. Transcript bodies never enter the cache.
struct ProjectUsageRecord: Hashable, Sendable {
    var source: ProjectUsageSource
    var session: String
    var response: String
    var timestamp: Date
    var explicitCWD: String?
    var totals: ProjectUsageTotals
    var file: String
    var line: Int
}

struct ProjectUsageMetadata: Hashable, Sendable {
    var source: ProjectUsageSource
    var session: String
    var cwd: String
}

struct ProjectUsageSnapshot: Sendable {
    var state: ProjectUsageLogState
    var records: [ProjectUsageRecord] = []
    var metadata: [ProjectUsageMetadata] = []
    var warnings: Set<String> = []
}

struct ProjectUsageReportKey: Hashable, Sendable {
    var range: UsageRange
    var source: ProjectUsageSource?
}

struct ProjectUsagePublication: Sendable {
    var state: ProjectUsageLogState
    var warning: String?
    var lastResponse: Date?
    var reports: [ProjectUsageReportKey: ProjectUsageReport]
    var progress: ProjectUsageProgress = .init(ready: true)
}

/// Global de-duplication and attribution precede range filtering. This matters when a
/// copied response's newest snapshot or conflicting session metadata lies outside Today.
enum ProjectUsageReducer {
    private struct Identity: Hashable {
        var source: ProjectUsageSource
        var session: String
        var response: String
    }
    private struct Session: Hashable {
        var source: ProjectUsageSource
        var session: String
    }
    static func path(_ raw: String?) -> String? {
        guard let raw, raw.hasPrefix("/"), !raw.contains("\0"), raw.utf8.count <= 4096 else { return nil }
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }

    static func publish(_ snapshot: ProjectUsageSnapshot, now: Date,
                        calendar: Calendar) -> ProjectUsagePublication {
        var warnings = snapshot.warnings
        if snapshot.records.contains(where: { $0.timestamp > now }) {
            warnings.insert("Future-dated responses omitted")
        }
        var latest: [Identity: ProjectUsageRecord] = [:]
        for record in snapshot.records {
            let key = Identity(source: record.source, session: record.session, response: record.response)
            if let old = latest[key] {
                if old.timestamp == record.timestamp,
                   old.totals != record.totals || path(old.explicitCWD) != path(record.explicitCWD) ||
                    (old.explicitCWD == nil) != (record.explicitCWD == nil) {
                    warnings.insert("Conflicting response snapshots; deterministic latest snapshot used")
                }
                let newer = record.timestamp > old.timestamp || (record.timestamp == old.timestamp &&
                    (record.file > old.file || (record.file == old.file && record.line > old.line)))
                if newer { latest[key] = record }
            } else { latest[key] = record }
        }
        var cwds: [Session: Set<String>] = [:]
        for metadata in snapshot.metadata {
            let key = Session(source: metadata.source, session: metadata.session)
            cwds[key, default: []].insert(path(metadata.cwd) ?? "")
        }
        let records = latest.values.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            if $0.source != $1.source { return $0.source.rawValue < $1.source.rawValue }
            if $0.session != $1.session { return $0.session < $1.session }
            return $0.response < $1.response
        }
        var reports: [ProjectUsageReportKey: ProjectUsageReport] = [:]
        for range in UsageRange.allCases {
            for source in [ProjectUsageSource?.none] + ProjectUsageSource.allCases.map(Optional.some) {
                var totals = ProjectUsageTotals()
                var groups: [String: ProjectUsageTotals] = [:]
                let start = range.start(now: now, calendar: calendar)
                for record in records where record.timestamp >= start && record.timestamp <= now &&
                    (source == nil || source == record.source) {
                    let sessionPaths = cwds[Session(source: record.source, session: record.session)] ?? []
                    let inferred = sessionPaths.count == 1 ? sessionPaths.first.flatMap(path) : nil
                    let project = record.explicitCWD != nil ? path(record.explicitCWD) : inferred
                    let id = project ?? "unattributed"
                    guard let newTotal = totals.adding(record.totals),
                          let newGroup = (groups[id] ?? .init()).adding(record.totals) else {
                        warnings.insert("Token aggregation overflow; affected responses omitted")
                        continue
                    }
                    totals = newTotal
                    groups[id] = newGroup
                }
                let names = groups.keys.filter { $0 != "unattributed" }.map {
                    URL(fileURLWithPath: $0).lastPathComponent
                }
                let nameCounts = names.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
                let duplicateNames = Set(nameCounts.filter { $0.value > 1 }.map(\.key))
                let rows = groups.map { id, total -> ProjectUsageRow in
                    guard id != "unattributed" else {
                        return .init(id: id, name: "Unattributed", path: nil, totals: total)
                    }
                    let url = URL(fileURLWithPath: id)
                    let leaf = url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
                    let name = duplicateNames.contains(leaf)
                        ? "\(leaf) — \(url.deletingLastPathComponent().path)" : leaf
                    return .init(id: id, name: name, path: id, totals: total)
                }.sorted {
                    if $0.totals.totalTokens != $1.totals.totalTokens {
                        return $0.totals.totalTokens > $1.totals.totalTokens
                    }
                    return $0.id < $1.id
                }
                reports[.init(range: range, source: source)] = .init(totals: totals, projects: rows)
            }
        }
        return .init(state: snapshot.state,
                     warning: warnings.isEmpty ? nil : warnings.sorted().joined(separator: "; ") + ". Totals may be incomplete.",
                     lastResponse: records.last(where: { $0.timestamp <= now })?.timestamp, reports: reports)
    }
}
