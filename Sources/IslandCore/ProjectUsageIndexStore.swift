import Foundation
import Darwin
import SQLite3

struct ProjectUsageFileSignature: Equatable, Sendable {
    var device: UInt64; var inode: UInt64; var size: Int64
    var modifiedSeconds: Int64; var modifiedNanos: Int64
    var changedSeconds: Int64; var changedNanos: Int64
}
enum ProjectUsageIndexPhase: String, Sendable { case queued, verifying, reading, awaitingNewline, complete, stale }
struct ProjectUsageIndexedFile: Sendable {
    var id: Int64; var source: ProjectUsageSource; var root: String; var path: String
    var generation: Int64; var phase: ProjectUsageIndexPhase
    var target: ProjectUsageFileSignature; var pending: ProjectUsageFileSignature?
    var highWaterSize: Int64; var committedOffset: Int64; var committedLine: Int64
    var verificationOffset: Int64; var prefixLength: Int64; var servedSequence: Int64; var walkID: Int64
    var sawLegacy: Bool; var sawCanonical: Bool
}
struct ProjectUsagePrefixBlock: Sendable { var offset: Int64; var length: Int; var digest: Data }
struct ProjectUsageIndexCheckpoint: Sendable {
    var expectedOffset: Int64; var offset: Int64; var line: Int64
    var prefixBlocks: [ProjectUsagePrefixBlock]; var reachedWatermark: Bool; var unfinishedRecord: Bool
}
struct ProjectUsageIndexBatch: Sendable {
    var records: [ProjectUsageRecord]; var metadata: [ProjectUsageMetadata]
    var codexSessionIDs: [String]; var codexCWDs: [String]
    var sawLegacy: Bool; var sawCanonical: Bool; var warnings: Set<String>
}
struct ProjectUsageIndexSourceProgress: Sendable {
    var source: ProjectUsageSource; var discoveredFiles: Int; var completedFiles: Int
    var processedBytes: Int64; var knownBytes: Int64; var discoveryComplete: Bool
    var pendingValidation: Bool; var pendingContext: Bool; var stale: Bool
}
struct ProjectUsageIndexProgress: Sendable {
    var sources: [ProjectUsageIndexSourceProgress]; var publishing: Bool; var ready: Bool
}
struct ProjectUsageIndexReport: Sendable {
    var key: ProjectUsageReportKey; var totals: ProjectUsageTotals; var projectCount: Int
}
struct ProjectUsageIndexPublication: Sendable {
    var revision: Int64; var state: ProjectUsageLogState; var reports: [ProjectUsageIndexReport]
    var warnings: Set<String>; var lastResponse: Date?; var progress: ProjectUsageIndexProgress
}
struct ProjectUsageIndexPageCursor: Equatable, Sendable { var sortTokens: Int; var path: String }
enum ProjectUsageIndexPageDirection: Sendable { case next, previous }
struct ProjectUsageIndexPage: Sendable {
    var revision: Int64; var key: ProjectUsageReportKey; var pageSize: Int; var projectCount: Int
    var rows: [ProjectUsageRow]; var firstCursor: ProjectUsageIndexPageCursor?; var lastCursor: ProjectUsageIndexPageCursor?
    var hasPrevious: Bool; var hasNext: Bool
}
struct ProjectUsageIndexMaintenance: Sendable {
    var processed: Int; var pending: Bool; var contentChanged: Bool = false
}

/// Synchronous, intentionally non-Sendable. Its scanner actor owns both WAL connections.
/// No transcript bytes, open transcript handles, or unbounded record arrays live here.
final class ProjectUsageIndexStore {
    let writer: ProjectIndexDatabase
    let reader: ProjectIndexDatabase
    let url: URL
    let ephemeral: Bool
    var publication: ProjectIndexPublishing?
    var bootEpoch: Int64 = 0
    static let fileColumns = "id,source,root,path,generation,phase,target,pending,high_water,committed_offset,committed_line,verification_offset,prefix_length,served,walk_id,legacy,canonical"
    static let totalColumns = "responses,input,output,cache_read,cache_write,total"
    static let schema = [
        "CREATE TABLE meta(key TEXT PRIMARY KEY,value INTEGER NOT NULL)",
        "CREATE TABLE walks(source TEXT,root TEXT,walk_id INTEGER NOT NULL,successful INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(source,root)) WITHOUT ROWID",
        "CREATE TABLE files(id INTEGER PRIMARY KEY,source TEXT NOT NULL,root TEXT NOT NULL,path TEXT NOT NULL,generation INTEGER NOT NULL DEFAULT 1,phase TEXT NOT NULL,target TEXT NOT NULL,pending TEXT,high_water INTEGER NOT NULL,committed_offset INTEGER NOT NULL DEFAULT 0,committed_line INTEGER NOT NULL DEFAULT 0,verification_offset INTEGER NOT NULL DEFAULT 0,prefix_length INTEGER NOT NULL DEFAULT 0,served INTEGER NOT NULL DEFAULT 0,walk_id INTEGER NOT NULL,legacy INTEGER NOT NULL DEFAULT 0,canonical INTEGER NOT NULL DEFAULT 0,eligible INTEGER NOT NULL DEFAULT 1,present INTEGER NOT NULL DEFAULT 1,staged_prefix INTEGER NOT NULL DEFAULT 0,UNIQUE(source,root,path))",
        "CREATE INDEX file_schedule ON files(source,phase,present,served,id)",
        "CREATE INDEX file_walk_schedule ON files(source,root,walk_id,phase,present,served,id)",
        "CREATE INDEX file_walk ON files(source,root,present,walk_id,id)",
        "CREATE INDEX file_legacy ON files(legacy,canonical,phase,present,eligible,id)",
        "CREATE INDEX file_deferred ON files(source,phase,present,eligible,id)",
        "CREATE TABLE prefixes(file_id INTEGER,gen INTEGER,offset INTEGER,length INTEGER NOT NULL,digest BLOB NOT NULL,pending_digest BLOB,PRIMARY KEY(file_id,gen,offset)) WITHOUT ROWID",
        "CREATE TABLE candidates(id INTEGER PRIMARY KEY AUTOINCREMENT,file_id INTEGER NOT NULL,gen INTEGER NOT NULL,source TEXT NOT NULL,session TEXT NOT NULL,response TEXT NOT NULL,timestamp REAL NOT NULL,path TEXT NOT NULL,line INTEGER NOT NULL,cwd TEXT NOT NULL,cwd_present INTEGER NOT NULL,responses INTEGER NOT NULL,input INTEGER NOT NULL,output INTEGER NOT NULL,cache_read INTEGER NOT NULL,cache_write INTEGER NOT NULL,total INTEGER NOT NULL,UNIQUE(file_id,gen,line,session,response))",
        "CREATE INDEX candidate_file ON candidates(file_id,gen,id)",
        "CREATE INDEX candidate_identity ON candidates(source,session,response,id)",
        "CREATE TABLE winners(source TEXT,session TEXT,response TEXT,candidate_id INTEGER NOT NULL,file_id INTEGER NOT NULL,gen INTEGER NOT NULL,timestamp REAL NOT NULL,path TEXT NOT NULL,line INTEGER NOT NULL,cwd TEXT NOT NULL,cwd_present INTEGER NOT NULL,responses INTEGER NOT NULL,input INTEGER NOT NULL,output INTEGER NOT NULL,cache_read INTEGER NOT NULL,cache_write INTEGER NOT NULL,total INTEGER NOT NULL,ordinal INTEGER NOT NULL UNIQUE,PRIMARY KEY(source,session,response)) WITHOUT ROWID",
        "CREATE TABLE bindings(id INTEGER PRIMARY KEY AUTOINCREMENT,file_id INTEGER NOT NULL,gen INTEGER NOT NULL,source TEXT NOT NULL,session TEXT NOT NULL,cwd TEXT NOT NULL,UNIQUE(file_id,gen,source,session,cwd))",
        "CREATE INDEX binding_file ON bindings(file_id,gen,id)",
        "CREATE TABLE context_refs(source TEXT,session TEXT,cwd TEXT,refs INTEGER NOT NULL,PRIMARY KEY(source,session,cwd)) WITHOUT ROWID",
        "CREATE TABLE sessions(source TEXT,session TEXT,distinct_count INTEGER NOT NULL,resolved TEXT NOT NULL,PRIMARY KEY(source,session)) WITHOUT ROWID",
        "CREATE TABLE facts(id INTEGER PRIMARY KEY AUTOINCREMENT,file_id INTEGER NOT NULL,gen INTEGER NOT NULL,kind INTEGER NOT NULL,value TEXT NOT NULL,UNIQUE(file_id,gen,kind,value))",
        "CREATE INDEX fact_file ON facts(file_id,gen,kind,id)",
        "CREATE TABLE jobs(id INTEGER PRIMARY KEY AUTOINCREMENT,kind TEXT NOT NULL,file_id INTEGER NOT NULL DEFAULT 0,gen INTEGER NOT NULL DEFAULT 0,source TEXT NOT NULL DEFAULT '',session TEXT NOT NULL DEFAULT '',response TEXT NOT NULL DEFAULT '',cursor INTEGER NOT NULL DEFAULT 0,frontier INTEGER NOT NULL DEFAULT 0,stage INTEGER NOT NULL DEFAULT 0,best INTEGER NOT NULL DEFAULT 0,dirty INTEGER NOT NULL DEFAULT 0,served INTEGER NOT NULL DEFAULT 0,UNIQUE(kind,file_id,gen,source,session,response))",
        "CREATE INDEX job_schedule ON jobs(served,id)",
        "CREATE UNIQUE INDEX project_job ON jobs(file_id,gen) WHERE kind='project'",
        "CREATE TABLE warnings(message TEXT PRIMARY KEY,refs INTEGER NOT NULL) WITHOUT ROWID",
        "CREATE TABLE warning_bindings(id INTEGER PRIMARY KEY AUTOINCREMENT,file_id INTEGER NOT NULL,gen INTEGER NOT NULL,message TEXT NOT NULL,UNIQUE(file_id,gen,message))",
        "CREATE INDEX warning_file ON warning_bindings(file_id,gen,id)",
        "CREATE TABLE report_groups(id INTEGER PRIMARY KEY AUTOINCREMENT,revision INTEGER NOT NULL,report_key TEXT NOT NULL,path TEXT NOT NULL,name TEXT NOT NULL,responses INTEGER NOT NULL,input INTEGER NOT NULL,output INTEGER NOT NULL,cache_read INTEGER NOT NULL,cache_write INTEGER NOT NULL,total INTEGER NOT NULL,sort_tokens INTEGER NOT NULL,UNIQUE(revision,report_key,path))",
        "CREATE INDEX report_page ON report_groups(revision,report_key,sort_tokens,path)",
        "CREATE INDEX report_name ON report_groups(revision,report_key,name,path)",
        "CREATE INDEX report_cleanup ON report_groups(revision,id)",
        "CREATE TABLE report_totals(revision INTEGER,report_key TEXT,responses INTEGER NOT NULL,input INTEGER NOT NULL,output INTEGER NOT NULL,cache_read INTEGER NOT NULL,cache_write INTEGER NOT NULL,total INTEGER NOT NULL,project_count INTEGER NOT NULL,PRIMARY KEY(revision,report_key)) WITHOUT ROWID"
    ]

    init(url supplied: URL?) throws {
        ephemeral = supplied == nil
        url = supplied ?? FileManager.default.temporaryDirectory.appendingPathComponent("project-index-" + UUID().uuidString, isDirectory: true).appendingPathComponent("index.sqlite")
        let parent = url.deletingLastPathComponent()
        // The caller supplies a dedicated cache child, never the proxy history's parent.
        var statBuffer = stat()
        if lstat(parent.path, &statBuffer) == 0 {
            guard statBuffer.st_mode & S_IFMT == S_IFDIR, statBuffer.st_uid == getuid() else { throw ProjectUsageIndexStoreError.database }
        } else {
            guard errno == ENOENT else { throw ProjectUsageIndexStoreError.database }
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        guard chmod(parent.path, 0o700) == 0 else { throw ProjectUsageIndexStoreError.database }
        let exists = lstat(url.path, &statBuffer) == 0
        if exists {
            guard statBuffer.st_mode & S_IFMT == S_IFREG, statBuffer.st_uid == getuid(), statBuffer.st_nlink == 1 else { throw ProjectUsageIndexStoreError.database }
        } else {
            guard errno == ENOENT else { throw ProjectUsageIndexStoreError.database }
            let fd = open(url.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw ProjectUsageIndexStoreError.database }; close(fd)
        }
        // Reject unsafe sidecars before SQLite can open them.
        for suffix in ["-wal", "-shm", "-journal"] {
            if lstat(url.path + suffix, &statBuffer) == 0 {
                guard statBuffer.st_mode & S_IFMT == S_IFREG, statBuffer.st_uid == getuid(), statBuffer.st_nlink == 1 else { throw ProjectUsageIndexStoreError.database }
            } else if errno != ENOENT { throw ProjectUsageIndexStoreError.database }
        }
        writer = try ProjectIndexDatabase(path: url.path)
        reader = try ProjectIndexDatabase(path: url.path)
        let marker = try writer.scalar("PRAGMA application_id")
        let version = try writer.scalar("PRAGMA user_version")
        if marker == 0 && version == 0 {
            let objects = try writer.query("SELECT 1 FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' LIMIT 1")
            guard try !objects.step() else { throw ProjectUsageIndexStoreError.schema }
            try writer.transaction {
                for sql in Self.schema { try writer.run(sql) }
                try writer.run("PRAGMA application_id=1347766601")
                try writer.run("PRAGMA user_version=1")
                for key in ["sequence", "walk", "revision", "published", "staging", "publication_cursor", "data_revision"] {
                    try writer.run("INSERT INTO meta VALUES(?,0)", [.text(key)])
                }
            }
        } else {
            guard marker == 1347766601, version == 1 else { throw ProjectUsageIndexStoreError.schema }
            // Validate required columns without a full-database integrity scan.
            _ = try writer.query("SELECT \(Self.fileColumns),eligible,present FROM files LIMIT 0")
            _ = try writer.query("SELECT ordinal,\(Self.totalColumns) FROM winners LIMIT 0")
            // Older development caches lacking the scheduling index are rejected,
            // rather than hiding an unbounded index build or per-pass sort in open.
            _ = try writer.query("SELECT message,refs FROM warnings LIMIT 0")
            _ = try writer.query("SELECT id,file_id,gen,message FROM warning_bindings LIMIT 0")
            for name in ["file_walk_schedule", "file_deferred", "warning_file"] {
                let schedule = try writer.query("SELECT 1 FROM sqlite_schema WHERE type='index' AND name=? LIMIT 1", [.text(name)])
                guard try schedule.step() else { throw ProjectUsageIndexStoreError.schema }
            }
        }
        try writer.run("PRAGMA journal_mode=WAL")
        try writer.run("PRAGMA synchronous=NORMAL")
        try reader.run("PRAGMA query_only=ON")
        try secureFiles()
        // Staged suffix hashes belong to one scanner lifetime. Advancing this single
        // key invalidates all unfinished coverage without scanning every file/hash.
        // Effective hashes below each committed prefixLength remain valid forever.
        bootEpoch = try writer.transaction {
            try writer.run("INSERT OR IGNORE INTO meta VALUES('hash_boot_epoch',0)")
            return try nextSequence("hash_boot_epoch")
        }
        let staging = try writer.scalar("SELECT value FROM meta WHERE key='staging'")
        if staging != 0 {
            try enqueueCleanup(staging)
            try writer.run("UPDATE meta SET value=0 WHERE key='staging'")
        }
    }
    deinit {
        try? reader.run("ROLLBACK")
        if ephemeral {
            // Only our UUID child and exact known files, never a recursive cache deletion.
            for suffix in ["", "-wal", "-shm", "-journal"] { unlink(url.path + suffix) }
            rmdir(url.deletingLastPathComponent().path)
        }
    }
    func secureFiles() throws {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            var s = stat()
            if lstat(url.path + suffix, &s) == 0 {
                guard s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid(), s.st_nlink == 1,
                      chmod(url.path + suffix, 0o600) == 0 else { throw ProjectUsageIndexStoreError.database }
            } else if errno != ENOENT { throw ProjectUsageIndexStoreError.database }
        }
    }
    func nextSequence(_ key: String = "sequence") throws -> Int64 {
        let old = try writer.scalar("SELECT value FROM meta WHERE key=?", [.text(key)])
        guard old < Int64.max else { throw ProjectUsageIndexStoreError.database }
        try writer.run("UPDATE meta SET value=? WHERE key=?", [.int(old+1), .text(key)])
        return old+1
    }
    func validateText(_ text: String, limit: Int = 4096) throws {
        guard !text.isEmpty, !text.contains("\0"), text.utf8.count <= limit else { throw ProjectUsageIndexStoreError.invalidMetadata }
    }
    func decodeFile(_ q: ProjectIndexStatement) throws -> ProjectUsageIndexedFile {
        guard let source = ProjectUsageSource(rawValue: q.text(1)), let phase = ProjectUsageIndexPhase(rawValue: q.text(5)) else { throw ProjectUsageIndexStoreError.schema }
        return .init(id: q.int(0), source: source, root: q.text(2), path: q.text(3), generation: q.int(4), phase: phase,
                     target: try .init(encoded: q.text(6)), pending: q.isNull(7) ? nil : try .init(encoded: q.text(7)),
                     highWaterSize: q.int(8), committedOffset: q.int(9), committedLine: q.int(10), verificationOffset: q.int(11),
                     prefixLength: q.int(12), servedSequence: q.int(13), walkID: q.int(14), sawLegacy: q.int(15) != 0, sawCanonical: q.int(16) != 0)
    }
    func file(_ id: Int64, _ generation: Int64) throws -> ProjectUsageIndexedFile {
        let q = try writer.query("SELECT \(Self.fileColumns) FROM files WHERE id=? AND generation=? AND present=1", [.int(id), .int(generation)])
        guard try q.step() else { throw ProjectUsageIndexStoreError.staleGeneration }
        return try decodeFile(q)
    }
    func beginWalk(source: ProjectUsageSource, root: String) throws -> Int64 {
        try validateText(root, limit: 4096)
        return try writer.transaction {
            let id = try nextSequence("walk")
            try writer.run("INSERT INTO walks(source,root,walk_id,successful) VALUES(?,?,?,0) ON CONFLICT(source,root) DO UPDATE SET walk_id=excluded.walk_id,successful=0", [.text(source.rawValue), .text(root), .int(id)])
            return id
        }
    }
    func registerFile(source: ProjectUsageSource, root: String, path: String, signature: ProjectUsageFileSignature, walkID: Int64) throws -> ProjectUsageIndexedFile {
        try validateText(root, limit: 4096); try validateText(path, limit: 4096)
        guard signature.valid else { throw ProjectUsageIndexStoreError.invalidMetadata }
        return try writer.transaction {
            guard try writer.scalar("SELECT walk_id FROM walks WHERE source=? AND root=?", [.text(source.rawValue), .text(root)]) == walkID, walkID > 0 else { throw ProjectUsageIndexStoreError.invalidCheckpoint }
            try writer.run("INSERT INTO files(source,root,path,phase,target,high_water,walk_id) VALUES(?,?,?,'queued',?,?,?) ON CONFLICT(source,root,path) DO UPDATE SET walk_id=excluded.walk_id", [.text(source.rawValue), .text(root), .text(path), .text(signature.encoded), .int(signature.size), .int(walkID)])
            let q = try writer.query("SELECT \(Self.fileColumns),present FROM files WHERE source=? AND root=? AND path=?", [.text(source.rawValue), .text(root), .text(path)])
            guard try q.step() else { throw ProjectUsageIndexStoreError.database }
            let found = try decodeFile(q)
            if q.int(17) == 0 {
                try writer.run("UPDATE files SET present=1 WHERE id=?", [.int(found.id)])
                return try invalidateInside(found, replacement: signature)
            }
            return found
        }
    }
    func finishWalk(source: ProjectUsageSource, root: String, walkID: Int64, successful: Bool) throws {
        try writer.run("UPDATE walks SET successful=? WHERE source=? AND root=? AND walk_id=?", [.int(successful ? 1 : 0), .text(source.rawValue), .text(root), .int(walkID)])
    }
    func unseenFiles(source: ProjectUsageSource, root: String, walkID: Int64, limit: Int) throws -> [ProjectUsageIndexedFile] {
        guard try writer.scalar("SELECT successful FROM walks WHERE source=? AND root=? AND walk_id=?", [.text(source.rawValue), .text(root), .int(walkID)]) == 1 else { return [] }
        let q = try writer.query("SELECT \(Self.fileColumns) FROM files WHERE source=? AND root=? AND walk_id<? AND present=1 ORDER BY walk_id,id LIMIT ?", [.text(source.rawValue), .text(root), .int(walkID), .int(Int64(clamp(limit)))])
        var result: [ProjectUsageIndexedFile] = []; while try q.step() { result.append(try decodeFile(q)) }; return result
    }
    func confirmAbsent(fileID: Int64, generation: Int64) throws {
        try writer.transaction {
            _ = try file(fileID, generation)
            try writer.run("UPDATE files SET eligible=0,present=0,phase='stale' WHERE id=?", [.int(fileID)])
            try enqueueRetirement(fileID, generation)
            _ = try nextSequence("data_revision")
        }
    }
    func nextFiles(source: ProjectUsageSource, phase: ProjectUsageIndexPhase, limit: Int) throws -> [ProjectUsageIndexedFile] {
        let q = try writer.query("SELECT \(Self.fileColumns) FROM files WHERE source=? AND phase=? AND present=1 ORDER BY served,id LIMIT ?", [.text(source.rawValue), .text(phase.rawValue), .int(Int64(clamp(limit)))])
        var result: [ProjectUsageIndexedFile] = []; while try q.step() { result.append(try decodeFile(q)) }; return result
    }
    func nextFiles(source: ProjectUsageSource, root: String, walkID: Int64, phase: ProjectUsageIndexPhase, limit: Int) throws -> [ProjectUsageIndexedFile] {
        let q = try writer.query("SELECT \(Self.fileColumns) FROM files WHERE source=? AND root=? AND walk_id=? AND phase=? AND present=1 ORDER BY served,id LIMIT ?", [.text(source.rawValue), .text(root), .int(walkID), .text(phase.rawValue), .int(Int64(clamp(limit)))])
        var result: [ProjectUsageIndexedFile] = []
        while try q.step() { result.append(try decodeFile(q)) }
        return result
    }
    func markServed(fileID: Int64, generation: Int64) throws {
        try writer.transaction {
            _ = try file(fileID, generation)
            try writer.run("UPDATE files SET served=? WHERE id=?", [.int(try nextSequence()), .int(fileID)])
        }
    }
    func setTarget(fileID: Int64, generation: Int64, signature: ProjectUsageFileSignature, highWaterSize: Int64, phase: ProjectUsageIndexPhase) throws {
        guard signature.valid, highWaterSize >= 0, highWaterSize <= signature.size else { throw ProjectUsageIndexStoreError.invalidCheckpoint }
        try writer.transaction {
            let old = try file(fileID, generation)
            guard old.phase == .complete || old.phase == .awaitingNewline || old.phase == .stale || (old.phase == .queued && old.committedOffset == 0), highWaterSize >= old.committedOffset else { throw ProjectUsageIndexStoreError.invalidCheckpoint }
            try writer.run("UPDATE files SET target=?,pending=NULL,high_water=?,phase=?,verification_offset=0 WHERE id=?", [.text(signature.encoded), .int(highWaterSize), .text(phase.rawValue), .int(fileID)])
            _ = try nextSequence("data_revision")
        }
    }
    func queueGrowth(fileID: Int64, generation: Int64, signature: ProjectUsageFileSignature) throws {
        guard signature.valid else { throw ProjectUsageIndexStoreError.invalidMetadata }
        try writer.transaction {
            let old = try file(fileID, generation)
            guard signature.size >= old.highWaterSize, signature.device == old.target.device, signature.inode == old.target.inode else { throw ProjectUsageIndexStoreError.invalidCheckpoint }
            try writer.run("UPDATE files SET pending=? WHERE id=?", [.text(signature.encoded), .int(fileID)])
        }
    }
    func invalidate(fileID: Int64, generation: Int64, replacement: ProjectUsageFileSignature) throws -> ProjectUsageIndexedFile {
        guard replacement.valid else { throw ProjectUsageIndexStoreError.invalidMetadata }
        return try writer.transaction { try invalidateInside(file(fileID, generation), replacement: replacement) }
    }
    func invalidateInside(_ old: ProjectUsageIndexedFile, replacement: ProjectUsageFileSignature) throws -> ProjectUsageIndexedFile {
        guard old.generation < Int64.max else { throw ProjectUsageIndexStoreError.database }
        try enqueueRetirement(old.id, old.generation)
        _ = try nextSequence("data_revision")
        try writer.run("UPDATE files SET generation=?,phase='queued',target=?,pending=NULL,high_water=?,committed_offset=0,committed_line=0,verification_offset=0,prefix_length=0,staged_prefix=0,legacy=0,canonical=0,eligible=1 WHERE id=?", [.int(old.generation+1), .text(replacement.encoded), .int(replacement.size), .int(old.id)])
        return try file(old.id, old.generation+1)
    }
    func prefixBlocks(fileID: Int64, generation: Int64, fromOffset: Int64, limit: Int) throws -> [ProjectUsagePrefixBlock] {
        _ = try file(fileID, generation)
        let boundary = try file(fileID, generation).prefixLength
        let q = try writer.query("SELECT offset,CASE WHEN pending_digest IS NOT NULL AND offset<=?-65536 THEN 65536 ELSE length END,CASE WHEN pending_digest IS NOT NULL AND offset<=?-65536 THEN pending_digest ELSE digest END FROM prefixes WHERE file_id=? AND gen=? AND offset>=? AND offset<? ORDER BY offset LIMIT ?", [.int(boundary), .int(boundary), .int(fileID), .int(generation), .int(fromOffset), .int(boundary), .int(Int64(clamp(limit)))])
        var result: [ProjectUsagePrefixBlock] = []; while try q.step() { result.append(.init(offset: q.int(0), length: Int(q.int(1)), digest: q.blob(2))) }; return result
    }
    func checkpointVerification(fileID: Int64, generation: Int64, expectedOffset: Int64, offset: Int64) throws {
        try writer.transaction {
            let old = try file(fileID, generation)
            guard old.phase == .verifying, old.verificationOffset == expectedOffset, offset >= expectedOffset, offset <= old.prefixLength else { throw ProjectUsageIndexStoreError.invalidCheckpoint }
            try writer.run("UPDATE files SET verification_offset=? WHERE id=?", [.int(offset), .int(fileID)])
        }
    }
    func finishVerification(fileID: Int64, generation: Int64) throws {
        try writer.transaction {
            let old = try file(fileID, generation)
            guard old.phase == .verifying, old.verificationOffset >= old.prefixLength else { throw ProjectUsageIndexStoreError.invalidCheckpoint }
            try writer.run("UPDATE files SET phase='reading' WHERE id=?", [.int(fileID)])
        }
    }
    func markStale(fileID: Int64, generation: Int64, warning: String) throws {
        try writer.transaction {
            _ = try file(fileID, generation)
            try writer.run("UPDATE files SET phase='stale' WHERE id=?", [.int(fileID)])
            _ = try nextSequence("data_revision")
            try addFileWarning(fileID, generation, warning)
        }
    }
    func clamp(_ value: Int) -> Int { min(4096, max(0, value)) }
}
