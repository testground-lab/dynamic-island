import Foundation
import SQLite3

struct ProjectIndexCandidate {
    var id: Int64; var fileID: Int64; var generation: Int64
    var source: String; var session: String; var response: String; var timestamp: Double
    var path: String; var line: Int64; var cwd: String; var cwdPresent: Bool; var totals: ProjectUsageTotals
    var identity: [ProjectIndexValue] { [.text(source), .text(session), .text(response)] }
    func newer(than old: Self) -> Bool {
        timestamp > old.timestamp || (timestamp == old.timestamp && (path > old.path || (path == old.path && line > old.line)))
    }
}

extension ProjectUsageIndexStore {
    static let candidateColumns = "id,file_id,gen,source,session,response,timestamp,path,line,cwd,cwd_present,responses,input,output,cache_read,cache_write,total"
    static let winnerColumns = "candidate_id,file_id,gen,source,session,response,timestamp,path,line,cwd,cwd_present,responses,input,output,cache_read,cache_write,total"
    static let allowedWarnings: Set<String> = [
        "Future-dated responses omitted", "Conflicting response snapshots; deterministic latest snapshot used",
        "Token aggregation overflow; affected responses omitted", "Unsupported Claude Code usage record format",
        "Claude Code usage missing identity, timestamp or counters", "Claude Code token overflow; response omitted",
        "Codex usage missing identity, timestamp or counters", "Codex invalid cache subsets or token overflow; response omitted",
        "Codex total counter inconsistent; input plus output used", "Unsupported Codex usage record format",
        "Malformed Claude Code log lines skipped", "Malformed Codex log lines skipped",
        "Claude Code oversized log lines skipped", "Codex oversized log lines skipped",
        "Claude Code unfinished log line deferred", "Codex unfinished log line deferred",
        "Codex session context ambiguous; usage unattributed", "Legacy Codex token_count usage unsupported and not counted",
        "Claude Code log file unreadable", "Codex log file unreadable", "Claude Code log changed during scan", "Codex log changed during scan",
        "Claude Code source folder missing", "Codex source folder missing", "Claude Code source folder unavailable", "Codex source folder unavailable",
        "Claude Code subfolder unreadable", "Codex subfolder unreadable", "Claude Code entries changed or unreadable", "Codex entries changed or unreadable",
        "Local usage index incomplete"
    ]
    func addFileWarning(_ fileID: Int64, _ gen: Int64, _ warning: String) throws {
        // Never persist an arbitrary diagnostic, JSON value, file path, or credential.
        let safe = Self.allowedWarnings.contains(warning) ? warning : "Local usage index incomplete"
        try writer.run("INSERT OR IGNORE INTO warning_bindings(file_id,gen,message) VALUES(?,?,?)", [.int(fileID), .int(gen), .text(safe)])
        guard sqlite3_changes(writer.handle) > 0 else { return }
        let refs = try writer.scalar("SELECT refs FROM warnings WHERE message=?", [.text(safe)])
        guard refs < Int64.max else { throw ProjectUsageIndexStoreError.database }
        try writer.run("INSERT INTO warnings VALUES(?,1) ON CONFLICT(message) DO UPDATE SET refs=refs+1", [.text(safe)])
    }
    func removeFileWarning(_ id: Int64, message: String) throws {
        let refs = try writer.scalar("SELECT refs FROM warnings WHERE message=?", [.text(message)])
        guard refs > 0 else { throw ProjectUsageIndexStoreError.schema }
        try writer.run("DELETE FROM warning_bindings WHERE id=?", [.int(id)])
        if refs == 1 { try writer.run("DELETE FROM warnings WHERE message=?", [.text(message)]) }
        else { try writer.run("UPDATE warnings SET refs=refs-1 WHERE message=?", [.text(message)]) }
    }
    func readWarnings(_ db: ProjectIndexDatabase) throws -> Set<String> {
        let q = try db.query("SELECT message FROM warnings LIMIT ?", [.int(Int64(Self.allowedWarnings.count))])
        var result: Set<String> = []
        while try q.step() { if Self.allowedWarnings.contains(q.text(0)) { result.insert(q.text(0)) } }
        if try db.scalar("SELECT 1 FROM files WHERE legacy=1 AND canonical=0 AND phase='complete' AND present=1 AND eligible=1 ORDER BY id LIMIT 1") == 1 {
            result.insert("Legacy Codex token_count usage unsupported and not counted")
        }
        for source in ProjectUsageSource.allCases {
            if try db.scalar("SELECT 1 FROM files WHERE source=? AND phase='awaitingNewline' AND present=1 AND eligible=1 ORDER BY id LIMIT 1", [.text(source.rawValue)]) == 1 {
                result.insert("\(source.title) unfinished log line deferred")
            }
        }
        return result
    }
    func candidate(_ q: ProjectIndexStatement) -> ProjectIndexCandidate {
        .init(id: q.int(0), fileID: q.int(1), generation: q.int(2), source: q.text(3), session: q.text(4), response: q.text(5),
              timestamp: q.real(6), path: q.text(7), line: q.int(8), cwd: q.text(9), cwdPresent: q.int(10) != 0, totals: q.totals(11))
    }
    func eligible(_ c: ProjectIndexCandidate, db: ProjectIndexDatabase? = nil) throws -> Bool {
        try (db ?? writer).scalar("SELECT 1 FROM files WHERE id=? AND generation=? AND eligible=1 AND present=1", [.int(c.fileID), .int(c.generation)]) == 1
    }
    func getCandidate(_ id: Int64) throws -> ProjectIndexCandidate? {
        let q = try writer.query("SELECT \(Self.candidateColumns) FROM candidates WHERE id=?", [.int(id)])
        return try q.step() ? candidate(q) : nil
    }
    func winner(_ identity: [ProjectIndexValue]) throws -> ProjectIndexCandidate? {
        let q = try writer.query("SELECT \(Self.winnerColumns) FROM winners WHERE source=? AND session=? AND response=?", identity)
        return try q.step() ? candidate(q) : nil
    }
    func writeWinner(_ c: ProjectIndexCandidate) throws {
        let ordinal = try nextSequence()
        try writer.run("INSERT INTO winners(source,session,response,candidate_id,file_id,gen,timestamp,path,line,cwd,cwd_present,\(Self.totalColumns),ordinal) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(source,session,response) DO UPDATE SET candidate_id=excluded.candidate_id,file_id=excluded.file_id,gen=excluded.gen,timestamp=excluded.timestamp,path=excluded.path,line=excluded.line,cwd=excluded.cwd,cwd_present=excluded.cwd_present,responses=excluded.responses,input=excluded.input,output=excluded.output,cache_read=excluded.cache_read,cache_write=excluded.cache_write,total=excluded.total,ordinal=excluded.ordinal", c.identity + [.int(c.id), .int(c.fileID), .int(c.generation), .real(c.timestamp), .text(c.path), .int(c.line), .text(c.cwd), .int(c.cwdPresent ? 1 : 0)] + c.totals.indexValues + [.int(ordinal)])
    }
    func consider(_ c: ProjectIndexCandidate) throws {
        if let old = try winner(c.identity) {
            if old.timestamp == c.timestamp && (old.totals != c.totals || old.cwd != c.cwd || old.cwdPresent != c.cwdPresent) {
                try addFileWarning(c.fileID, c.generation, "Conflicting response snapshots; deterministic latest snapshot used")
            }
            if try c.newer(than: old) || !eligible(old) { try writeWinner(c) }
        } else { try writeWinner(c) }
        // A finite repair already in progress must finish, then include this immutable row.
        try writer.run("UPDATE jobs SET dirty=1 WHERE kind='repair' AND source=? AND session=? AND response=?", c.identity)
    }
    func stagedFrontier(_ file: ProjectUsageIndexedFile) throws -> Int64 {
        let epoch = try writer.scalar("SELECT value FROM meta WHERE key=?", [.text("hash_epoch/\(file.id)")])
        guard epoch == bootEpoch else { return file.prefixLength }
        return max(file.prefixLength, try writer.scalar("SELECT staged_prefix FROM files WHERE id=?", [.int(file.id)]))
    }
    func stagePrefixBlocks(fileID: Int64, generation: Int64, blocks: [ProjectUsagePrefixBlock]) throws {
        guard blocks.count <= 4096 else { throw ProjectUsageIndexStoreError.invalidMetadata }
        try writer.transaction {
            let old = try file(fileID, generation)
            var frontier = try stagedFrontier(old)
            for block in blocks {
                guard block.offset >= old.prefixLength - old.prefixLength % 65536,
                      block.offset % 65536 == 0, block.offset <= frontier,
                      block.length == 65536, block.digest.count == 32,
                      Int64(block.length) <= old.highWaterSize - block.offset else { throw ProjectUsageIndexStoreError.invalidCheckpoint }
                try writer.run("INSERT INTO prefixes(file_id,gen,offset,length,digest,pending_digest) VALUES(?,?,?,?,?,?) ON CONFLICT(file_id,gen,offset) DO UPDATE SET pending_digest=excluded.pending_digest", [.int(fileID), .int(generation), .int(block.offset), .int(Int64(block.length)), .blob(block.digest), .blob(block.digest)])
                frontier = max(frontier, block.offset + Int64(block.length))
            }
            try writer.run("UPDATE files SET staged_prefix=? WHERE id=?", [.int(frontier), .int(fileID)])
            try writer.run("INSERT INTO meta VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text("hash_epoch/\(fileID)"), .int(bootEpoch)])
        }
    }
    func commit(fileID: Int64, generation: Int64, batch: ProjectUsageIndexBatch, checkpoint: ProjectUsageIndexCheckpoint) throws {
        guard batch.records.count + batch.metadata.count + batch.codexSessionIDs.count + batch.codexCWDs.count <= 4096,
              checkpoint.prefixBlocks.count <= 4096, batch.warnings.count <= 64 else { throw ProjectUsageIndexStoreError.invalidMetadata }
        try writer.transaction {
            _ = try nextSequence("data_revision")
            let old = try file(fileID, generation)
            guard [.queued, .reading, .awaitingNewline].contains(old.phase), checkpoint.expectedOffset == old.committedOffset,
                  checkpoint.offset >= old.committedOffset, checkpoint.offset <= old.highWaterSize,
                  checkpoint.line >= old.committedLine,
                  checkpoint.line - old.committedLine <= checkpoint.offset - old.committedOffset,
                  checkpoint.offset != old.committedOffset || checkpoint.line == old.committedLine,
                  !checkpoint.unfinishedRecord || checkpoint.reachedWatermark,
                  !checkpoint.reachedWatermark || checkpoint.unfinishedRecord || checkpoint.offset == old.highWaterSize else { throw ProjectUsageIndexStoreError.invalidCheckpoint }
            // Hash coverage must be contiguous, replacing only the prior short final block.
            let start = old.prefixLength - old.prefixLength % 65536
            let staged = try stagedFrontier(old)
            var covered = max(old.prefixLength, min(staged, checkpoint.offset - checkpoint.offset % 65536))
            if let first = checkpoint.prefixBlocks.first {
                guard first.offset >= start, first.offset <= covered else { throw ProjectUsageIndexStoreError.invalidCheckpoint }
                var next = first.offset
                for block in checkpoint.prefixBlocks {
                    guard block.offset == next, block.offset % 65536 == 0, (1...65536).contains(block.length), block.digest.count == 32,
                          Int64(block.length) <= checkpoint.offset - block.offset,
                          block.length == 65536 || block.offset + Int64(block.length) == checkpoint.offset else { throw ProjectUsageIndexStoreError.invalidCheckpoint }
                    next += Int64(block.length)
                }
                covered = next
            }
            guard covered == checkpoint.offset else { throw ProjectUsageIndexStoreError.invalidCheckpoint }
            for record in batch.records {
                try validateText(record.session); try validateText(record.response)
                guard record.source == old.source, record.file == old.path, record.timestamp.timeIntervalSince1970.isFinite,
                      record.line > old.committedLine, record.line <= checkpoint.line, record.totals.responses == 1,
                      record.totals.adding(.init()) != nil,
                      record.totals.cacheReadTokens <= record.totals.inputTokens,
                      record.totals.cacheWriteTokens <= record.totals.inputTokens else { throw ProjectUsageIndexStoreError.invalidMetadata }
                let (sum, overflow) = record.totals.inputTokens.addingReportingOverflow(record.totals.outputTokens)
                guard !overflow, sum == record.totals.totalTokens else { throw ProjectUsageIndexStoreError.invalidMetadata }
                let cwd = ProjectUsageReducer.path(record.explicitCWD) ?? ""
                try writer.run("INSERT INTO candidates(file_id,gen,source,session,response,timestamp,path,line,cwd,cwd_present,\(Self.totalColumns)) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [.int(fileID), .int(generation), .text(record.source.rawValue), .text(record.session), .text(record.response), .real(record.timestamp.timeIntervalSince1970), .text(old.path), .int(Int64(record.line)), .text(cwd), .int(record.explicitCWD == nil ? 0 : 1)] + record.totals.indexValues)
                guard let c = try getCandidate(sqlite3_last_insert_rowid(writer.handle)) else { throw ProjectUsageIndexStoreError.database }
                try consider(c)
            }
            for metadata in batch.metadata {
                guard metadata.source == old.source else { throw ProjectUsageIndexStoreError.invalidMetadata }
                try validateText(metadata.session)
                try insertBinding(fileID, generation, metadata.source.rawValue, metadata.session, ProjectUsageReducer.path(metadata.cwd) ?? "")
            }
            for session in batch.codexSessionIDs {
                guard old.source == .codex else { throw ProjectUsageIndexStoreError.invalidMetadata }
                try validateText(session)
                try writer.run("INSERT OR IGNORE INTO facts(file_id,gen,kind,value) VALUES(?,?,0,?)", [.int(fileID), .int(generation), .text(session)])
            }
            for cwd in batch.codexCWDs {
                guard old.source == .codex else { throw ProjectUsageIndexStoreError.invalidMetadata }
                try writer.run("INSERT OR IGNORE INTO facts(file_id,gen,kind,value) VALUES(?,?,1,?)", [.int(fileID), .int(generation), .text(ProjectUsageReducer.path(cwd) ?? "")])
            }
            for block in checkpoint.prefixBlocks {
                // One read quantum can hash a full block before an earlier LF is
                // checkpointed. Preserve that current-lifetime full hash alongside
                // the short committed digest, so subsequent LFs need not reread it.
                // Expired staging never qualifies, even if its pending row remains.
                let keepStaged = block.length < 65536 && block.offset <= staged - 65536
                try writer.run("INSERT INTO prefixes(file_id,gen,offset,length,digest) VALUES(?,?,?,?,?) ON CONFLICT(file_id,gen,offset) DO UPDATE SET length=excluded.length,digest=excluded.digest,pending_digest=CASE WHEN ?=1 THEN prefixes.pending_digest ELSE NULL END", [.int(fileID), .int(generation), .int(block.offset), .int(Int64(block.length)), .blob(block.digest), .int(keepStaged ? 1 : 0)])
            }
            let derivedWarnings: Set<String> = ["Legacy Codex token_count usage unsupported and not counted", "Claude Code unfinished log line deferred", "Codex unfinished log line deferred"]
            for warning in batch.warnings where !derivedWarnings.contains(warning) { try addFileWarning(fileID, generation, warning) }
            let phase: ProjectUsageIndexPhase = checkpoint.reachedWatermark ? (checkpoint.unfinishedRecord ? .awaitingNewline : .complete) : .reading
            try writer.run("UPDATE files SET committed_offset=?,committed_line=?,prefix_length=?,phase=?,legacy=MAX(legacy,?),canonical=MAX(canonical,?) WHERE id=?", [.int(checkpoint.offset), .int(checkpoint.line), .int(covered), .text(phase.rawValue), .int(batch.sawLegacy ? 1 : 0), .int(batch.sawCanonical ? 1 : 0), .int(fileID)])
            if checkpoint.reachedWatermark && old.source == .codex {
                try enqueueProjection(fileID, generation)
                // Legacy-only warning is derived by indexed finite-EOF flags, not
                // persisted forever: a later canonical append clears that condition.
            }
        }
        try secureFiles()
    }

    func insertBinding(_ fileID: Int64, _ gen: Int64, _ source: String, _ session: String, _ cwd: String) throws {
        try writer.run("INSERT OR IGNORE INTO bindings(file_id,gen,source,session,cwd) VALUES(?,?,?,?,?)", [.int(fileID), .int(gen), .text(source), .text(session), .text(cwd)])
        guard sqlite3_changes(writer.handle) > 0 else { return }
        let key: [ProjectIndexValue] = [.text(source), .text(session), .text(cwd)]
        let refs = try writer.scalar("SELECT refs FROM context_refs WHERE source=? AND session=? AND cwd=?", key)
        guard refs < Int64.max else { throw ProjectUsageIndexStoreError.database }
        try writer.run("INSERT INTO context_refs VALUES(?,?,?,1) ON CONFLICT(source,session,cwd) DO UPDATE SET refs=refs+1", key)
        if refs == 0 {
            try writer.run("INSERT INTO sessions VALUES(?,?,1,?) ON CONFLICT(source,session) DO UPDATE SET distinct_count=distinct_count+1,resolved=''", [.text(source), .text(session), .text(cwd)])
        }
    }
    func removeBinding(_ q: ProjectIndexStatement) throws {
        let key: [ProjectIndexValue] = [.text(q.text(1)), .text(q.text(2)), .text(q.text(3))]
        let refs = try writer.scalar("SELECT refs FROM context_refs WHERE source=? AND session=? AND cwd=?", key)
        guard refs > 0 else { throw ProjectUsageIndexStoreError.schema }
        if refs > 1 {
            try writer.run("UPDATE context_refs SET refs=refs-1 WHERE source=? AND session=? AND cwd=?", key)
        } else {
            try writer.run("DELETE FROM context_refs WHERE source=? AND session=? AND cwd=?", key)
            let sessionKey = Array(key.prefix(2))
            try writer.run("UPDATE sessions SET distinct_count=distinct_count-1 WHERE source=? AND session=?", sessionKey)
            let count = try writer.scalar("SELECT distinct_count FROM sessions WHERE source=? AND session=?", sessionKey)
            if count == 0 { try writer.run("DELETE FROM sessions WHERE source=? AND session=?", sessionKey) }
            else if count == 1 {
                let remaining = try writer.query("SELECT cwd FROM context_refs WHERE source=? AND session=? ORDER BY cwd LIMIT 1", sessionKey)
                guard try remaining.step() else { throw ProjectUsageIndexStoreError.schema }
                try writer.run("UPDATE sessions SET resolved=? WHERE source=? AND session=?", [.text(remaining.text(0))] + sessionKey)
            }
        }
        try writer.run("DELETE FROM bindings WHERE id=?", [.int(q.int(0))])
    }
    func enqueueRetirement(_ fileID: Int64, _ gen: Int64) throws {
        try writer.run("INSERT OR IGNORE INTO jobs(kind,file_id,gen) VALUES('retire',?,?)", [.int(fileID), .int(gen)])
    }
    func enqueueRepair(_ c: ProjectIndexCandidate) throws {
        let frontier = try writer.scalar("SELECT id FROM candidates WHERE source=? AND session=? AND response=? ORDER BY id DESC LIMIT 1", c.identity)
        try writer.run("INSERT INTO jobs(kind,source,session,response,frontier) VALUES('repair',?,?,?,?) ON CONFLICT(kind,file_id,gen,source,session,response) DO UPDATE SET dirty=1", c.identity + [.int(frontier)])
    }
    func enqueueProjection(_ fileID: Int64, _ gen: Int64) throws {
        let frontier = try writer.scalar("SELECT id FROM bindings WHERE file_id=? AND gen=? ORDER BY id DESC LIMIT 1", [.int(fileID), .int(gen)])
        try writer.run("INSERT INTO jobs(kind,file_id,gen,frontier) VALUES('project',?,?,?) ON CONFLICT DO UPDATE SET dirty=1", [.int(fileID), .int(gen), .int(frontier)])
    }
    func enqueueCleanup(_ revision: Int64) throws {
        try writer.run("INSERT OR IGNORE INTO jobs(kind,file_id) VALUES('cleanup',?)", [.int(revision)])
    }
    func hasPendingMaintenance() throws -> Bool { try writer.scalar("SELECT 1 FROM jobs ORDER BY served,id LIMIT 1") == 1 }
    func advanceMaintenance(maxRows: Int) throws -> ProjectUsageIndexMaintenance {
        var processed = 0, contentChanged = false
        for _ in 0..<clamp(maxRows) {
            let didWork = try writer.transaction { () -> Bool in
                let job = try writer.query("SELECT id,kind,file_id,gen,source,session,response,cursor,frontier,stage,best,dirty FROM jobs ORDER BY served,id LIMIT 1")
                guard try job.step() else { return false }
                if job.text(1) != "cleanup" {
                    _ = try nextSequence("data_revision")
                    contentChanged = true
                }
                switch job.text(1) {
                case "retire": try retireStep(job)
                case "repair": try repairStep(job)
                case "project": try projectionStep(job)
                case "cleanup": try cleanupStep(job)
                default: throw ProjectUsageIndexStoreError.schema
                }
                try writer.run("UPDATE jobs SET served=? WHERE id=?", [.int(try nextSequence()), .int(job.int(0))])
                return true
            }
            guard didWork else { break }; processed += 1
        }
        return .init(processed: processed, pending: try hasPendingMaintenance(), contentChanged: contentChanged)
    }
    func deleteJob(_ id: Int64) throws { try writer.run("DELETE FROM jobs WHERE id=?", [.int(id)]) }
    func advanceJob(_ id: Int64, cursor: Int64) throws { try writer.run("UPDATE jobs SET cursor=? WHERE id=?", [.int(cursor), .int(id)]) }
    func retireStep(_ job: ProjectIndexStatement) throws {
        let id = job.int(0), fileID = job.int(2), gen = job.int(3), cursor = job.int(7), stage = job.int(9)
        let values: [ProjectIndexValue] = [.int(fileID), .int(gen), .int(cursor)]
        switch stage {
        case 0:
            let q = try writer.query("SELECT \(Self.candidateColumns) FROM candidates WHERE file_id=? AND gen=? AND id>? ORDER BY id LIMIT 1", values)
            if try q.step() {
                let c = candidate(q)
                try writer.run("DELETE FROM candidates WHERE id=?", [.int(c.id)])
                try enqueueRepair(c); try advanceJob(id, cursor: c.id); return
            }
        case 1:
            let q = try writer.query("SELECT id,source,session,cwd FROM bindings WHERE file_id=? AND gen=? AND id>? ORDER BY id LIMIT 1", values)
            if try q.step() { try removeBinding(q); try advanceJob(id, cursor: q.int(0)); return }
        case 2:
            // Offset is also the prefix table's indexed key. -1 includes the offset-zero block.
            let q = try writer.query("SELECT offset FROM prefixes WHERE file_id=? AND gen=? AND offset>? ORDER BY offset LIMIT 1", values)
            if try q.step() {
                try writer.run("DELETE FROM prefixes WHERE file_id=? AND gen=? AND offset=?", [.int(fileID), .int(gen), .int(q.int(0))])
                try advanceJob(id, cursor: q.int(0)); return
            }
        case 3:
            // Separate kind frontiers use the covering fact_file index, no whole-file sort.
            let q = try writer.query("SELECT id FROM facts WHERE file_id=? AND gen=? AND kind=0 AND id>? ORDER BY id LIMIT 1", values)
            if try q.step() { try writer.run("DELETE FROM facts WHERE id=?", [.int(q.int(0))]); try advanceJob(id, cursor: q.int(0)); return }
        case 4:
            let q = try writer.query("SELECT id FROM facts WHERE file_id=? AND gen=? AND kind=1 AND id>? ORDER BY id LIMIT 1", values)
            if try q.step() { try writer.run("DELETE FROM facts WHERE id=?", [.int(q.int(0))]); try advanceJob(id, cursor: q.int(0)); return }
        case 5:
            let q = try writer.query("SELECT id,message FROM warning_bindings WHERE file_id=? AND gen=? AND id>? ORDER BY id LIMIT 1", values)
            if try q.step() { try removeFileWarning(q.int(0), message: q.text(1)); try advanceJob(id, cursor: q.int(0)); return }
        default: try deleteJob(id); return
        }
        try writer.run("UPDATE jobs SET stage=stage+1,cursor=-1 WHERE id=?", [.int(id)])
    }
    func repairStep(_ job: ProjectIndexStatement) throws {
        let id = job.int(0), cursor = job.int(7), frontier = job.int(8)
        let identity: [ProjectIndexValue] = [.text(job.text(4)), .text(job.text(5)), .text(job.text(6))]
        let q = try writer.query("SELECT \(Self.candidateColumns) FROM candidates WHERE source=? AND session=? AND response=? AND id>? AND id<=? ORDER BY id LIMIT 1", identity + [.int(cursor), .int(frontier)])
        if try q.step() {
            let c = candidate(q)
            if try eligible(c) {
                let best = try getCandidate(job.int(10))
                if best == nil || c.newer(than: best!) {
                    try writer.run("UPDATE jobs SET best=? WHERE id=?", [.int(c.id), .int(id)])
                }
                if let best, best.timestamp == c.timestamp && (best.totals != c.totals || best.cwd != c.cwd || best.cwdPresent != c.cwdPresent) {
                    try addFileWarning(c.fileID, c.generation, "Conflicting response snapshots; deterministic latest snapshot used")
                }
            }
            try advanceJob(id, cursor: c.id); return
        }
        if let best = try getCandidate(job.int(10)), try eligible(best) { try writeWinner(best) }
        else { try writer.run("DELETE FROM winners WHERE source=? AND session=? AND response=?", identity) }
        let dirty = job.int(11) != 0
        try deleteJob(id)
        if dirty {
            let high = try writer.scalar("SELECT id FROM candidates WHERE source=? AND session=? AND response=? ORDER BY id DESC LIMIT 1", identity)
            try writer.run("INSERT OR IGNORE INTO jobs(kind,source,session,response,frontier) VALUES('repair',?,?,?,?)", identity + [.int(high)])
        }
    }
    func projectionStep(_ job: ProjectIndexStatement) throws {
        let id = job.int(0), fileID = job.int(2), gen = job.int(3), stage = job.int(9)
        let key: [ProjectIndexValue] = [.int(fileID), .int(gen)]
        guard try writer.scalar("SELECT 1 FROM files WHERE id=? AND generation=? AND present=1", key) == 1 else { try deleteJob(id); return }
        if stage == 0 {
            let q = try writer.query("SELECT id,source,session,cwd FROM bindings WHERE file_id=? AND gen=? AND id>? AND id<=? ORDER BY id LIMIT 1", key + [.int(job.int(7)), .int(job.int(8))])
            if try q.step() { try removeBinding(q); try advanceJob(id, cursor: q.int(0)); return }
            let sessions = try writer.query("SELECT value FROM facts WHERE file_id=? AND gen=? AND kind=0 ORDER BY id LIMIT 2", key)
            var ids: [String] = []; while try sessions.step() { ids.append(sessions.text(0)) }
            guard !ids.isEmpty else { try deleteJob(id); return }
            let multiple = ids.count > 1
            let kind: Int64 = multiple ? 0 : 1
            let frontier = try writer.scalar("SELECT id FROM facts WHERE file_id=? AND gen=? AND kind=? ORDER BY id DESC LIMIT 1", key + [.int(kind)])
            try writer.run("UPDATE jobs SET stage=?,session=?,frontier=?,cursor=0 WHERE id=?", [.int(multiple ? 2 : 1), .text(multiple ? "" : ids[0]), .int(frontier), .int(id)])
            if multiple { try addFileWarning(fileID, gen, "Codex session context ambiguous; usage unattributed") }
            return
        }
        let q = try writer.query("SELECT id,value FROM facts WHERE file_id=? AND gen=? AND kind=? AND id>? AND id<=? ORDER BY id LIMIT 1", key + [.int(stage == 1 ? 1 : 0), .int(job.int(7)), .int(job.int(8))])
        if try q.step() {
            try insertBinding(fileID, gen, ProjectUsageSource.codex.rawValue, stage == 1 ? job.text(5) : q.text(1), stage == 1 ? q.text(1) : "")
            try advanceJob(id, cursor: q.int(0)); return
        }
        let dirty = job.int(11) != 0
        try deleteJob(id)
        if dirty { try enqueueProjection(fileID, gen) }
    }
    func cleanupStep(_ job: ProjectIndexStatement) throws {
        let revision = job.int(2)
        let q = try writer.query("SELECT id FROM report_groups WHERE revision=? AND id>? ORDER BY id LIMIT 1", [.int(revision), .int(job.int(7))])
        if try q.step() {
            try writer.run("DELETE FROM report_groups WHERE id=?", [.int(q.int(0))]); try advanceJob(job.int(0), cursor: q.int(0)); return
        }
        // Exactly twelve keys, not an unbounded report delete.
        try writer.run("DELETE FROM report_totals WHERE revision=?", [.int(revision)])
        try deleteJob(job.int(0))
    }

    /// Bounded compatibility adapter for fixtures, never used by the production scanner.
    func testSnapshot(maxRecords: Int) throws -> ProjectUsageSnapshot {
        let limit = min(100_000, max(0, maxRecords))
        let q = try writer.query("SELECT \(Self.candidateColumns) FROM candidates ORDER BY id LIMIT ?", [.int(Int64(limit))])
        var records: [ProjectUsageRecord] = []
        while try q.step() {
            let c = candidate(q)
            if try eligible(c), let source = ProjectUsageSource(rawValue: c.source) {
                records.append(.init(source: source, session: c.session, response: c.response, timestamp: Date(timeIntervalSince1970: c.timestamp), explicitCWD: c.cwdPresent ? c.cwd : nil, totals: c.totals, file: c.path, line: Int(c.line)))
            }
        }
        let metadataQuery = try writer.query("SELECT file_id,gen,source,session,cwd FROM bindings ORDER BY id LIMIT ?", [.int(Int64(limit))])
        var metadata: [ProjectUsageMetadata] = []
        while try metadataQuery.step() {
            if try writer.scalar("SELECT 1 FROM files WHERE id=? AND generation=? AND eligible=1 AND present=1", [.int(metadataQuery.int(0)), .int(metadataQuery.int(1))]) == 1,
               let source = ProjectUsageSource(rawValue: metadataQuery.text(2)) {
                metadata.append(.init(source: source, session: metadataQuery.text(3), cwd: metadataQuery.text(4)))
            }
        }
        return .init(state: .loaded, records: records, metadata: metadata, warnings: try readWarnings(writer))
    }
}
