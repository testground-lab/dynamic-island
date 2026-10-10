import Foundation
import Darwin
import CryptoKit

/// These are work-per-pass budgets, never corpus admission limits.
struct ProjectUsageLimits: Sendable {
    var files = 32
    var bytes = 2 * 1024 * 1024
    var records = 512
    var residentBytes = 16 * 1024 * 1024
    var discoveryEntries = 512
    var collectedPaths = 2048 // Compatibility only; discovered paths live in SQLite.
    var lineBytes = 256 * 1024 // Compatibility only; valid lines have no size limit.
    var chunkBytes = 64 * 1024
    var depth = 64
}

struct ProjectUsageScanResult: Sendable {
    var publication: ProjectUsagePublication?
    var progress: ProjectUsageProgress
    var needsMoreWork: Bool
    var rawPending: Bool = false
    var maintenancePending: Bool = false
    var publicationPending: Bool = false
}

actor ProjectUsageScanner {
    private final class DirectoryCursor {
        let path: String
        let descriptor: Int32
        let directory: UnsafeMutablePointer<DIR>
        init?(descriptor: Int32, path: String) {
            guard let directory = fdopendir(dup(descriptor)) else { close(descriptor); return nil }
            self.descriptor = descriptor; self.path = path; self.directory = directory
        }
        deinit { closedir(directory); close(descriptor) }
    }
    private struct Walk {
        var root: String
        var id: Int64
        var stack: [DirectoryCursor]
        var succeeded = true
        var enumerated = false
        var reconciled = false
        var discovered = 0
        var completed = 0
        var knownBytes: Int64 = 0
        var indexedBytes: Int64 = 0
        var incompleteFiles = 0
    }
    private struct Reader {
        var source: ProjectUsageSource
        var generation: Int64
        var offset: Int64
        var recordStart: Int64
        var line: Int64
        var parser = ProjectUsageJSONStream()
        var hashOffset: Int64
        var hashBytes = Data()
    }
    static var defaultIndexURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DynamicIsland/ProjectUsage/index.sqlite")
    }
    private let indexURL: URL?
    private var index: ProjectUsageIndexStore?
    private let limits: ProjectUsageLimits
    private let beforeRead: (@Sendable (URL) -> Void)?
    private let beforePass: (@Sendable () throws -> Void)?
    private let afterRead: (@Sendable (URL) -> Void)?
    private var walks: [ProjectUsageSource: Walk] = [:]
    private var readers: [Int64: Reader] = [:]
    private var freshFirst: [ProjectUsageSource: Bool] = [:]
    private var cycleActive = false
    private var sourceWarnings: Set<String> = []
    private var rootState: ProjectUsageLogState = .missing
    private var publishing = false
    private var publicationDirty = true
    private var published: ProjectUsagePublication?
    private var publishedAt: Date?
    private var publishedCalendar: Calendar?
    private(set) var streamedFiles = 0
    private(set) var streamedBytes = 0
    private var verificationBytes: Int64 = 0
    private static let blockSize = 64 * 1024

    init(limits: ProjectUsageLimits = .init(), indexURL: URL? = nil,
         beforeRead: (@Sendable (URL) -> Void)? = nil, afterRead: (@Sendable (URL) -> Void)? = nil,
         beforePass: (@Sendable () throws -> Void)? = nil) {
        self.limits = limits; self.indexURL = indexURL
        self.beforeRead = beforeRead; self.afterRead = afterRead; self.beforePass = beforePass
    }

    private func store() throws -> ProjectUsageIndexStore {
        if let index { return index }
        if let indexURL {
            // Create only our application's parent if absent. Store owns/private-modes its child.
            let parent = indexURL.deletingLastPathComponent().deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parent.path) {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
        }
        let opened = try ProjectUsageIndexStore(url: indexURL)
        index = opened
        return opened
    }

    /// Production entry point: one finite, fair pass. No raw record snapshots escape.
    func scan(roots: [ProjectUsageSource: URL], now: Date, calendar: Calendar) throws -> ProjectUsageScanResult {
        try Task.checkCancellation()
        try beforePass?()
        let db = try store()
        if !cycleActive { try beginCycle(roots: roots, db: db) }
        if publishedAt.map({ now < $0 || !calendar.isDate($0, inSameDayAs: now) }) ?? true || publishedCalendar != calendar {
            publicationDirty = true
        }
        for source in ProjectUsageSource.allCases {
            try Task.checkCancellation()
            try discover(source: source, db: db)
            try reconcile(source: source, db: db)
        }
        var pendingFiles = false
        for source in ProjectUsageSource.allCases {
            try Task.checkCancellation()
            pendingFiles = try process(source: source, db: db) || pendingFiles
        }
        let maintenance = try db.advanceMaintenance(maxRows: max(1, limits.records))
        if maintenance.contentChanged { publicationDirty = true }
        let walking = walks.values.contains { !$0.enumerated || !$0.reconciled }
        let stale = sourceWarnings.count > 0 || walks.values.contains { !$0.succeeded }
        let coveragePending = walks.values.contains { $0.incompleteFiles > 0 }
        var progress = progressSnapshot(walking: walking, pending: pendingFiles || maintenance.pending || coveragePending, stale: stale)
        var emitted: ProjectUsagePublication?
        if publicationDirty && !publishing {
            // A finite snapshot of index-so-far is useful while catch-up is running.
            let state = rootState
            _ = try db.beginPublication(now: now, calendar: calendar, state: state,
                                       progress: indexProgress(progress))
            publishing = true; publicationDirty = false
            publishedAt = now; publishedCalendar = calendar
        }
        if publishing, let result = try db.advancePublication(maxRecords: max(1, limits.records)) {
            publishing = false
            var warnings = result.warnings
            warnings.formUnion(sourceWarnings)
            var reports: [ProjectUsageReportKey: ProjectUsageReport] = [:]
            for report in result.reports {
                try Task.checkCancellation()
                let page = try db.projectPage(key: report.key, cursor: nil, direction: .next,
                                              pageSize: 20, revision: result.revision)
                reports[report.key] = .init(totals: report.totals, projects: page.rows,
                    projectCount: report.projectCount, revision: result.revision,
                    firstCursor: publicCursor(page.firstCursor), lastCursor: publicCursor(page.lastCursor),
                    hasPrevious: page.hasPrevious, hasNext: page.hasNext)
            }
            // Completion of an older partial snapshot is not completion of current indexing.
            let settled = !walking && !pendingFiles && !maintenance.pending && !publicationDirty && !stale && !coveragePending
            progress = progressSnapshot(walking: walking, pending: !settled, stale: stale)
            emitted = .init(state: result.state,
                warning: warnings.isEmpty ? nil : warnings.sorted().joined(separator: "; ") + ". Totals may be incomplete.",
                lastResponse: result.lastResponse, reports: reports, progress: progress)
            published = emitted
        }
        progress.publishing = publishing
        progress.ready = !walking && !pendingFiles && !maintenance.pending && !publishing && !publicationDirty && !stale && !coveragePending
        if !publishing && !publicationDirty {
            published?.progress = progress
            emitted?.progress = progress
        }
        let more = walking || pendingFiles || maintenance.pending || publishing || publicationDirty
        if !more { cycleActive = false; walks.removeAll() }
        return .init(publication: emitted, progress: progress, needsMoreWork: more,
                     rawPending: walking || pendingFiles, maintenancePending: maintenance.pending,
                     publicationPending: publishing || publicationDirty)
    }

    /// Bounded fixture adapter; production never asks for historical records in RAM.
    func scan(roots: [ProjectUsageSource: URL], now: Date) throws -> ProjectUsageSnapshot {
        var result = try scan(roots: roots, now: now, calendar: Calendar(identifier: .gregorian))
        var passes = 0
        while result.needsMoreWork && passes < 100_000 {
            try Task.checkCancellation()
            result = try scan(roots: roots, now: now, calendar: Calendar(identifier: .gregorian))
            passes += 1
        }
        var snapshot = try store().testSnapshot(maxRecords: 100_000)
        snapshot.state = rootState
        snapshot.warnings.formUnion(sourceWarnings)
        if result.needsMoreWork { snapshot.warnings.insert("Local usage indexing still in progress") }
        return snapshot
    }

    func projectPage(key: ProjectUsageReportKey, cursor: ProjectUsageProjectCursor?,
                     direction: ProjectUsagePageDirection, revision: Int64) throws -> ProjectUsageReport? {
        try Task.checkCancellation()
        guard let report = published?.reports[key], report.revision == revision else { return nil }
        let page = try store().projectPage(key: key,
            cursor: cursor.map { .init(sortTokens: $0.sortTokens, path: $0.path) },
            direction: direction == .next ? .next : .previous, pageSize: 20, revision: revision)
        return .init(totals: report.totals, projects: page.rows, projectCount: page.projectCount,
            revision: revision, firstCursor: publicCursor(page.firstCursor), lastCursor: publicCursor(page.lastCursor),
            hasPrevious: page.hasPrevious, hasNext: page.hasNext)
    }

    func currentPublication() -> ProjectUsagePublication? { published }
    func verifiedReadBytes() -> Int64 { verificationBytes }

    func cancel() {
        index?.cancelPublication(); publishing = false; publicationDirty = true
        cycleActive = false; walks.removeAll(); readers.removeAll()
    }

    private func beginCycle(roots: [ProjectUsageSource: URL], db: ProjectUsageIndexStore) throws {
        let oldState = rootState, oldWarnings = sourceWarnings
        cycleActive = true; sourceWarnings.removeAll(); walks.removeAll()
        var readable = 0, existing = 0
        for source in ProjectUsageSource.allCases {
            guard let root = roots[source] else { continue }
            let path = root.path
            let descriptor = Self.openSecure(path, directory: true)
            guard descriptor >= 0 else {
                let missing = errno == ENOENT
                if !missing { existing += 1 }
                sourceWarnings.insert("\(source.title) source folder \(missing ? "missing" : "unavailable; cached usage may be stale")")
                continue
            }
            existing += 1
            guard let cursor = DirectoryCursor(descriptor: descriptor, path: path) else {
                sourceWarnings.insert("\(source.title) source folder unreadable; cached usage may be stale")
                continue
            }
            readable += 1
            let id = try db.beginWalk(source: source, root: path)
            walks[source] = .init(root: path, id: id, stack: [cursor])
        }
        rootState = readable > 0 ? .loaded : existing > 0 ? .unreadable("Local usage folders couldn't be read") : .missing
        if rootState != oldState || sourceWarnings != oldWarnings || published == nil ||
            published?.warning?.contains("Future-dated") == true { publicationDirty = true }
    }

    private func discover(source: ProjectUsageSource, db: ProjectUsageIndexStore) throws {
        guard var walk = walks[source], !walk.enumerated else { return }
        var entries = 0
        while let cursor = walk.stack.last, entries < max(1, limits.discoveryEntries) {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(cursor.directory) else {
                if errno != 0 { walk.succeeded = false; sourceWarnings.insert("\(source.title) subfolder unreadable; cached usage may be stale") }
                walk.stack.removeLast(); continue
            }
            entries += 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            let path = cursor.path + "/" + name
            guard path.utf8.count <= 4096 else { walk.succeeded = false; sourceWarnings.insert("\(source.title) path limit exceeded"); continue }
            var attributes = stat()
            guard fstatat(cursor.descriptor, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0 else {
                walk.succeeded = false; sourceWarnings.insert("\(source.title) entries changed or unreadable"); continue
            }
            if attributes.st_mode & S_IFMT == S_IFDIR {
                guard walk.stack.count <= max(1, limits.depth) else { walk.succeeded = false; sourceWarnings.insert("\(source.title) directory depth exceeded"); continue }
                let child = openat(cursor.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0, let next = DirectoryCursor(descriptor: child, path: path) else {
                    walk.succeeded = false; sourceWarnings.insert("\(source.title) subfolder unreadable; cached usage may be stale"); continue
                }
                walk.stack.append(next)
            } else if attributes.st_mode & S_IFMT == S_IFREG && name.hasSuffix(".jsonl") &&
                (source == .claudeCode || name.hasPrefix("rollout")) {
                let signature = Self.signature(attributes)
                let file = try db.registerFile(source: source, root: walk.root, path: path, signature: signature, walkID: walk.id)
                walk.discovered += 1
                walk.knownBytes = Self.saturatingAdd(walk.knownBytes, signature.size)
                walk.indexedBytes = Self.saturatingAdd(walk.indexedBytes,
                    Self.sameIdentity(file.target, signature) && signature.size >= file.committedOffset ? file.committedOffset : 0)
                if file.phase == .complete && signature == file.target { walk.completed += 1 }
                if file.phase == .awaitingNewline && signature == file.target { walk.incompleteFiles += 1 }
                try prepare(file, observed: signature, db: db)
            }
        }
        if walk.stack.isEmpty {
            walk.enumerated = true
            try db.finishWalk(source: source, root: walk.root, walkID: walk.id, successful: walk.succeeded)
            if !walk.succeeded { walk.reconciled = true }
        }
        walks[source] = walk
    }

    private func reconcile(source: ProjectUsageSource, db: ProjectUsageIndexStore) throws {
        guard var walk = walks[source], walk.enumerated, walk.succeeded, !walk.reconciled else { return }
        let unseen = try db.unseenFiles(source: source, root: walk.root, walkID: walk.id, limit: max(1, limits.files))
        for file in unseen {
            try Task.checkCancellation()
            let descriptor = Self.openSecure(file.path, directory: false)
            let failure: Int32
            if descriptor >= 0 {
                defer { close(descriptor) }
                var attributes = stat()
                if fstat(descriptor, &attributes) == 0 {
                    if attributes.st_mode & S_IFMT != S_IFREG {
                        try db.confirmAbsent(fileID: file.id, generation: file.generation)
                        readers.removeValue(forKey: file.id); publicationDirty = true
                        continue
                    }
                    let found = try db.registerFile(source: source, root: walk.root, path: file.path,
                        signature: Self.signature(attributes), walkID: walk.id)
                    try prepare(found, observed: Self.signature(attributes), db: db)
                    continue
                }
                failure = errno
            } else { failure = errno }
            if failure == ENOENT || failure == ENOTDIR || failure == ELOOP {
                try db.confirmAbsent(fileID: file.id, generation: file.generation)
                readers.removeValue(forKey: file.id); publicationDirty = true
            } else {
                sourceWarnings.insert("\(source.title) log existence couldn't be verified; cached usage may be stale")
                // Mark seen without pretending the failure proves deletion; this advances reconciliation.
                _ = try db.registerFile(source: source, root: walk.root, path: file.path,
                    signature: file.target, walkID: walk.id)
                try db.markStale(fileID: file.id, generation: file.generation, warning: "\(source.title) log file unreadable")
            }
        }
        if unseen.isEmpty { walk.reconciled = true }
        walks[source] = walk
    }

    private func prepare(_ file: ProjectUsageIndexedFile, observed: ProjectUsageFileSignature,
                         db: ProjectUsageIndexStore) throws {
        if file.phase == .queued {
            try db.setTarget(fileID: file.id, generation: file.generation, signature: observed,
                highWaterSize: observed.size, phase: .reading)
        } else if file.phase == .complete || file.phase == .awaitingNewline || file.phase == .stale {
            guard observed != file.target || file.phase == .stale else { return }
            if Self.sameIdentity(file.target, observed), observed.size >= file.highWaterSize {
                try db.setTarget(fileID: file.id, generation: file.generation, signature: observed,
                    highWaterSize: observed.size, phase: file.prefixLength > 0 ? .verifying : .reading)
                readers.removeValue(forKey: file.id)
            } else {
                _ = try db.invalidate(fileID: file.id, generation: file.generation, replacement: observed)
                readers.removeValue(forKey: file.id)
            }
            publicationDirty = true
        } else if observed != file.target {
            try db.queueGrowth(fileID: file.id, generation: file.generation, signature: observed)
        }
    }

    private func process(source: ProjectUsageSource, db: ProjectUsageIndexStore) throws -> Bool {
        guard let walk = walks[source] else { return false }
        let workFiles = min(128, max(1, limits.files))
        for phase in [ProjectUsageIndexPhase.queued, .verifying, .reading] {
            // Hash validation and tail parsing each own an allotment; neither can starve the other.
            var bytes = 0, attempted = 0
            var admitted: Set<Int64> = []
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
            while attempted < 128 && bytes < max(1, limits.bytes) && ContinuousClock.now < deadline {
                let files: [ProjectUsageIndexedFile]
                if phase == .reading {
                    files = try readingSchedule(source: source, walk: walk, limit: workFiles, db: db)
                } else {
                    files = try db.nextFiles(source: source, root: walk.root, walkID: walk.id,
                                             phase: phase, limit: workFiles)
                }
                var worked = false
                for initial in files {
                    try Task.checkCancellation()
                    if attempted >= 128 || bytes >= max(1, limits.bytes) || ContinuousClock.now >= deadline { break }
                    guard admitted.contains(initial.id) || admitted.count < workFiles else { continue }
                    admitted.insert(initial.id); attempted += 1; worked = true
                    try db.markServed(fileID: initial.id, generation: initial.generation)
                    guard initial.root == walk.root, initial.walkID == walk.id else { continue }
                    let file = initial
                    if phase == .queued {
                        try db.setTarget(fileID: file.id, generation: file.generation, signature: file.target,
                                         highWaterSize: file.highWaterSize, phase: .reading)
                        continue // Preparing targets does not consume another tail-reading allotment.
                    }
                    let descriptor = Self.openSecure(file.path, directory: false)
                    guard descriptor >= 0 else {
                        try db.markStale(fileID: file.id, generation: file.generation, warning: "\(source.title) log file unreadable")
                        sourceWarnings.insert("\(source.title) log file unreadable; cached usage may be stale")
                        readers.removeValue(forKey: file.id); continue
                    }
                    defer { close(descriptor) }
                    var attributes = stat()
                    guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else {
                        try db.markStale(fileID: file.id, generation: file.generation, warning: "\(source.title) log file unreadable")
                        continue
                    }
                    let observed = Self.signature(attributes)
                    if !Self.sameIdentity(file.target, observed) || observed.size < file.highWaterSize ||
                        (observed.size == file.highWaterSize && observed != file.target) {
                        resetProgress(file)
                        _ = try db.invalidate(fileID: file.id, generation: file.generation, replacement: observed)
                        readers.removeValue(forKey: file.id); publicationDirty = true; continue
                    }
                    if observed != file.target { try db.queueGrowth(fileID: file.id, generation: file.generation, signature: observed) }
                    let allowance = min(64 * 1024, max(1, limits.chunkBytes), max(1, limits.bytes) - bytes)
                    if file.phase == .verifying {
                        bytes += try verify(file, descriptor: descriptor, allowance: allowance, db: db)
                    } else {
                        let maxReaders = max(1, min(32, limits.residentBytes / (512 * 1024)))
                        let canRetain = readers[file.id] != nil || readers.values.filter({ $0.source == source }).count < maxReaders
                        // A bounded transient probe admits checkpointable files while giant records occupy slots.
                        bytes += try read(file, descriptor: descriptor, allowance: allowance, retainUnfinished: canRetain, db: db)
                    }
                }
                if !worked { break }
            }
        }
        // Awaiting-newline and stale files wait for a new discovery/stat cycle, not a busy loop.
        for phase in [ProjectUsageIndexPhase.queued, .verifying, .reading] {
            if try !db.nextFiles(source: source, root: walk.root, walkID: walk.id, phase: phase, limit: 1).isEmpty { return true }
        }
        return false
    }

    /// Existing giant-record states get a reserved quantum without waiting for the whole file queue to wrap.
    /// Fresh files retain oldest-served admission, including bounded probes when all state slots are occupied.
    private func readingSchedule(source: ProjectUsageSource, walk: Walk, limit: Int,
                                 db: ProjectUsageIndexStore) throws -> [ProjectUsageIndexedFile] {
        let activeIDs = readers.compactMap { id, reader in
            reader.source == source ? (id, reader.generation) : nil
        }
        var active: [ProjectUsageIndexedFile] = []
        for (id, generation) in activeIDs {
            try Task.checkCancellation()
            do {
                let file = try db.file(id, generation)
                if file.phase != .reading { readers.removeValue(forKey: id); continue }
                if file.root == walk.root && file.walkID == walk.id { active.append(file) }
            } catch let error as ProjectUsageIndexStoreError where error == .staleGeneration {
                readers.removeValue(forKey: id)
            }
        }
        active.sort {
            $0.servedSequence == $1.servedSequence ? $0.id < $1.id : $0.servedSequence < $1.servedSequence
        }
        let activeSet = Set(active.map(\.id))
        let waiting = try db.nextFiles(source: source, root: walk.root, walkID: walk.id,
            phase: .reading, limit: limit + active.count).filter { !activeSet.contains($0.id) }
        let preferFresh = !(freshFirst[source] ?? true)
        freshFirst[source] = preferFresh
        let reserved = min(active.count, limit == 1 && preferFresh && !waiting.isEmpty ? 0 : max(1, limit / 2))
        let fresh = min(waiting.count, limit - reserved)
        let activeHead = Array(active.prefix(reserved)), freshHead = Array(waiting.prefix(fresh))
        // Alternating order also preserves fairness when a tiny byte budget permits just one quantum.
        let head = preferFresh ? freshHead + activeHead : activeHead + freshHead
        return head + Array(active.dropFirst(reserved)) + Array(waiting.dropFirst(fresh))
    }

    private func resetProgress(_ file: ProjectUsageIndexedFile) {
        if var walk = walks[file.source], walk.id == file.walkID {
            walk.indexedBytes = max(0, walk.indexedBytes - file.committedOffset)
            walks[file.source] = walk
        }
    }

    private func verify(_ file: ProjectUsageIndexedFile, descriptor: Int32, allowance: Int,
                        db: ProjectUsageIndexStore) throws -> Int {
        guard file.verificationOffset < file.prefixLength else {
            try db.finishVerification(fileID: file.id, generation: file.generation); return 0
        }
        let blocks = try db.prefixBlocks(fileID: file.id, generation: file.generation,
                                        fromOffset: file.verificationOffset, limit: 1)
        guard let block = blocks.first, block.offset == file.verificationOffset else {
            resetProgress(file)
            _ = try db.invalidate(fileID: file.id, generation: file.generation, replacement: file.target)
            publicationDirty = true; return 0
        }
        // One digest block is the minimum verification quantum (<=64KiB), even with tiny test budgets.
        let data = try Self.readBytes(descriptor, offset: block.offset, count: block.length)
        verificationBytes += Int64(data.count)
        if data.count != block.length || Data(SHA256.hash(data: data)) != block.digest {
            resetProgress(file)
            _ = try db.invalidate(fileID: file.id, generation: file.generation, replacement: file.target)
            readers.removeValue(forKey: file.id); publicationDirty = true
        } else {
            try db.checkpointVerification(fileID: file.id, generation: file.generation,
                expectedOffset: file.verificationOffset, offset: block.offset + Int64(block.length))
            if block.offset + Int64(block.length) >= file.prefixLength {
                try db.finishVerification(fileID: file.id, generation: file.generation)
            }
        }
        return max(data.count, min(allowance, 1))
    }

    private func read(_ file: ProjectUsageIndexedFile, descriptor: Int32, allowance: Int,
                      retainUnfinished: Bool, db: ProjectUsageIndexStore) throws -> Int {
        var reader: Reader
        if let active = readers[file.id], active.generation == file.generation { reader = active }
        else {
            streamedFiles += 1; beforeRead?(URL(fileURLWithPath: file.path))
            let start = file.committedOffset / Int64(Self.blockSize) * Int64(Self.blockSize)
            reader = .init(source: file.source, generation: file.generation, offset: file.committedOffset,
                           recordStart: file.committedOffset, line: file.committedLine, hashOffset: start)
            if file.committedOffset > start {
                reader.hashBytes = try Self.readBytes(descriptor, offset: start, count: Int(file.committedOffset - start))
            }
        }
        let count = Int(min(Int64(allowance), max(0, file.highWaterSize - reader.offset)))
        let data = try Self.readBytes(descriptor, offset: reader.offset, count: count)
        let beforeOffset = reader.offset
        reader.offset += Int64(data.count)
        streamedBytes += data.count
        var hashes: [ProjectUsagePrefixBlock] = []
        for byte in data {
            reader.hashBytes.append(byte)
            if reader.hashBytes.count == Self.blockSize {
                hashes.append(.init(offset: reader.hashOffset, length: Self.blockSize,
                                    digest: Data(SHA256.hash(data: reader.hashBytes))))
                reader.hashOffset += Int64(Self.blockSize)
                reader.hashBytes.removeAll(keepingCapacity: true)
            }
        }
        let envelopes = reader.parser.feed(data)
        var batch = ProjectUsageIndexBatch(records: [], metadata: [], codexSessionIDs: [], codexCWDs: [],
                                           sawLegacy: false, sawCanonical: false, warnings: [])
        var committed = file.committedOffset
        for envelope in envelopes {
            try Task.checkCancellation()
            reader.recordStart += Int64(envelope.byteLength); reader.line += 1
            committed = reader.recordStart
            normalize(envelope, source: file.source, path: file.path, line: reader.line, into: &batch)
        }
        afterRead?(URL(fileURLWithPath: file.path))
        try Task.checkCancellation()
        var after = stat(), pathAfter = stat()
        guard fstat(descriptor, &after) == 0, lstat(file.path, &pathAfter) == 0,
              Self.sameIdentity(file.target, Self.signature(after)),
              Self.sameIdentity(file.target, Self.signature(pathAfter)), after.st_size >= file.highWaterSize,
              (after.st_size > file.highWaterSize || Self.signature(after) == file.target),
              Self.signature(after) == Self.signature(pathAfter) else {
            readers.removeValue(forKey: file.id)
            sourceWarnings.insert("\(file.source.title) log changed during scan")
            if lstat(file.path, &pathAfter) == 0, pathAfter.st_mode & S_IFMT == S_IFREG {
                resetProgress(file)
                _ = try db.invalidate(fileID: file.id, generation: file.generation, replacement: Self.signature(pathAfter))
            } else { try db.markStale(fileID: file.id, generation: file.generation, warning: "\(file.source.title) log changed during scan") }
            publicationDirty = true; return data.count
        }
        if Self.signature(after) != file.target {
            try db.queueGrowth(fileID: file.id, generation: file.generation, signature: Self.signature(after))
        }
        if !hashes.isEmpty { try db.stagePrefixBlocks(fileID: file.id, generation: file.generation, blocks: hashes) }
        var committedHashes: [ProjectUsagePrefixBlock] = []
        if committed > 0 && committed % Int64(Self.blockSize) != 0 {
            let offset = committed / Int64(Self.blockSize) * Int64(Self.blockSize)
            let short = try Self.readBytes(descriptor, offset: offset, count: Int(committed - offset))
            committedHashes.append(.init(offset: offset, length: short.count, digest: Data(SHA256.hash(data: short))))
        }
        let reached = reader.offset >= file.highWaterSize
        if !envelopes.isEmpty || reached {
            try db.commit(fileID: file.id, generation: file.generation, batch: batch,
                checkpoint: .init(expectedOffset: file.committedOffset, offset: committed, line: reader.line,
                    prefixBlocks: committedHashes, reachedWatermark: reached, unfinishedRecord: reached && reader.parser.unfinished))
            if var walk = walks[file.source], walk.id == file.walkID {
                walk.indexedBytes = Self.saturatingAdd(walk.indexedBytes, committed - file.committedOffset)
                if reached {
                    if reader.parser.unfinished { walk.incompleteFiles += 1 }
                    else { walk.completed += 1 }
                }
                walks[file.source] = walk
            }
            publicationDirty = true
        }
        if reached || committed > file.committedOffset || !retainUnfinished {
            readers.removeValue(forKey: file.id)
            // Once a new newline is durable, release the slot. Replaying its unfinished suffix
            // costs at most this quantum; giant records with no new newline retain their state.
            // EOF states wait for the next finite walk, not an occupied resident slot.
        } else { readers[file.id] = reader }
        if data.isEmpty && !reached && reader.offset == beforeOffset {
            readers.removeValue(forKey: file.id)
            try db.markStale(fileID: file.id, generation: file.generation, warning: "\(file.source.title) log file unreadable")
        }
        return data.count
    }

    private func normalize(_ envelope: ProjectUsageEnvelope, source: ProjectUsageSource, path: String,
                           line: Int64, into batch: inout ProjectUsageIndexBatch) {
        if envelope.warning != nil { batch.warnings.insert("Malformed \(source.title) log lines skipped"); return }
        let f = envelope.fields
        guard !f.isEmpty else { return }
        for value in f.values {
            if case .string(let text) = value, text.isEmpty || text.contains("\0") {
                batch.warnings.insert("Malformed \(source.title) log lines skipped"); return
            }
        }
        func string(_ key: ProjectUsageField) -> String? { if case .string(let value) = f[key] { return value }; return nil }
        func integer(_ key: ProjectUsageField) -> Int? { if case .integer(let value) = f[key], value >= 0 { return value }; return nil }
        guard let type = string(.type) else { batch.warnings.insert("Malformed \(source.title) log lines skipped"); return }
        if source == .claudeCode {
            if let session = string(.sessionId), let cwd = string(.cwd) {
                batch.metadata.append(.init(source: source, session: session, cwd: cwd))
            }
            guard type == "assistant" else {
                if type.contains("usage") || type.contains("token") { batch.warnings.insert("Unsupported Claude Code usage record format") }
                return
            }
            guard let session = string(.sessionId), let response = string(.messageId),
                  let date = string(.timestamp).flatMap(APIDateParser.parse),
                  let input = integer(.messageInputTokens), let output = integer(.messageOutputTokens),
                  let read = optionalCounter(f, .messageCacheReadInputTokens),
                  let write = optionalCounter(f, .messageCacheCreationInputTokens),
                  let ordinal = Int(exactly: line) else {
                batch.warnings.insert("Claude Code usage missing identity, timestamp or counters"); return
            }
            guard let inclusive = Self.sum([input, read, write]), let total = Self.sum([inclusive, output]) else {
                batch.warnings.insert("Claude Code token overflow; response omitted"); return
            }
            batch.records.append(.init(source: source, session: session, response: response, timestamp: date,
                explicitCWD: string(.cwd), totals: .init(responses: 1, inputTokens: inclusive, outputTokens: output,
                    cacheReadTokens: read, cacheWriteTokens: write, totalTokens: total), file: path, line: ordinal))
        } else if type == "token_usage_record" {
            guard let session = string(.payloadSessionId) ?? string(.payloadThreadId),
                  let response = string(.payloadResponseId), let date = string(.timestamp).flatMap(APIDateParser.parse),
                  let input = integer(.payloadInputTokens), let output = integer(.payloadOutputTokens),
                  let read = optionalCounter(f, .payloadCachedInputTokens),
                  let write = optionalCounter(f, .payloadCacheWriteInputTokens),
                  let reasoning = optionalCounter(f, .payloadReasoningOutputTokens),
                  let ordinal = Int(exactly: line) else {
                batch.warnings.insert("Codex usage missing identity, timestamp or counters"); return
            }
            guard let cache = Self.sum([read, write]), cache <= input, reasoning <= output,
                  let total = Self.sum([input, output]) else {
                batch.warnings.insert("Codex invalid cache subsets or token overflow; response omitted"); return
            }
            if let supplied = integer(.payloadTotalTokens), supplied != total {
                batch.warnings.insert("Codex total counter inconsistent; input plus output used")
            } else if f[.payloadTotalTokens] != nil && integer(.payloadTotalTokens) == nil {
                batch.warnings.insert("Codex usage missing identity, timestamp or counters"); return
            }
            batch.sawCanonical = true; batch.codexSessionIDs.append(session)
            batch.records.append(.init(source: source, session: session, response: response, timestamp: date,
                explicitCWD: nil, totals: .init(responses: 1, inputTokens: input, outputTokens: output,
                    cacheReadTokens: read, cacheWriteTokens: write, totalTokens: total), file: path, line: ordinal))
        } else if type == "session_meta" || type == "turn_context" {
            if let session = string(.payloadSessionId) ?? string(.payloadId) ?? string(.payloadThreadId) { batch.codexSessionIDs.append(session) }
            if let cwd = string(.payloadCwd) { batch.codexCWDs.append(cwd) }
        } else if type == "event_msg" {
            if string(.payloadType) == "token_count" { batch.sawLegacy = true }
        } else if type.contains("usage") || type.contains("token") {
            batch.warnings.insert("Unsupported Codex usage record format")
        }
    }

    private func optionalCounter(_ fields: [ProjectUsageField: ProjectUsageScalar], _ field: ProjectUsageField) -> Int? {
        guard let raw = fields[field] else { return 0 }
        if case .integer(let value) = raw, value >= 0 { return value }
        return nil
    }
    private func progressSnapshot(walking: Bool, pending: Bool, stale: Bool) -> ProjectUsageProgress {
        .init(sources: ProjectUsageSource.allCases.compactMap { source in
            guard let walk = walks[source] else { return nil }
            return .init(source: source, discoveredFiles: walk.discovered, completedFiles: walk.completed,
                processedBytes: walk.indexedBytes, knownBytes: walk.knownBytes,
                discoveryComplete: walk.enumerated && walk.reconciled, stale: !walk.succeeded)
        }, publishing: publishing, ready: !walking && !pending && !stale, stale: stale)
    }
    private func indexProgress(_ p: ProjectUsageProgress) -> ProjectUsageIndexProgress {
        .init(sources: p.sources.map { .init(source: $0.source, discoveredFiles: $0.discoveredFiles,
            completedFiles: $0.completedFiles, processedBytes: $0.processedBytes, knownBytes: $0.knownBytes,
            discoveryComplete: $0.discoveryComplete, pendingValidation: !p.ready, pendingContext: !p.ready, stale: $0.stale) },
            publishing: p.publishing, ready: p.ready)
    }
    private func publicCursor(_ c: ProjectUsageIndexPageCursor?) -> ProjectUsageProjectCursor? {
        c.map { .init(sortTokens: $0.sortTokens, path: $0.path) }
    }
    private static func sum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values { let (next, overflow) = total.addingReportingOverflow(value); if overflow || value < 0 { return nil }; total = next }
        return total
    }
    private static func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b); return overflow ? Int64.max : sum
    }
    private static func signature(_ s: stat) -> ProjectUsageFileSignature {
        .init(device: UInt64(UInt32(bitPattern: s.st_dev)), inode: UInt64(s.st_ino), size: Int64(s.st_size),
              modifiedSeconds: Int64(s.st_mtimespec.tv_sec), modifiedNanos: Int64(s.st_mtimespec.tv_nsec),
              changedSeconds: Int64(s.st_ctimespec.tv_sec), changedNanos: Int64(s.st_ctimespec.tv_nsec))
    }
    private static func sameIdentity(_ a: ProjectUsageFileSignature, _ b: ProjectUsageFileSignature) -> Bool {
        a.device == b.device && a.inode == b.inode
    }
    private static func readBytes(_ descriptor: Int32, offset: Int64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var bytes = Data(count: count)
        let readCount = bytes.withUnsafeMutableBytes { raw in pread(descriptor, raw.baseAddress, count, off_t(offset)) }
        guard readCount >= 0 else { throw CocoaError(.fileReadUnknown) }
        bytes.count = readCount
        return bytes
    }
    /// NOFOLLOW on every component prevents parent symlinks redirecting source reads.
    private static func openSecure(_ path: String, directory: Bool) -> Int32 {
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else { errno = EINVAL; return -1 }
        let components = path.split(separator: "/").map(String.init)
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return -1 }
        for (index, component) in components.enumerated() {
            let isDirectory = index < components.count - 1 || directory
            let next = openat(descriptor, component, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (isDirectory ? O_DIRECTORY : O_NONBLOCK))
            let saved = errno; close(descriptor)
            if next < 0 { errno = saved; return -1 }; descriptor = next
        }
        return descriptor
    }
}
