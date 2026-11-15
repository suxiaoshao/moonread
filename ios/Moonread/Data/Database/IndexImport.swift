import Foundation
import GRDB

final class ImportControl: @unchecked Sendable {
    let id: String
    let generation: Int64
    let lease: DataSessionLease
    private let lock = NSLock()
    private var stopped = false
    private var running = false

    init(id: String, generation: Int64, lease: DataSessionLease) {
        self.id = id; self.generation = generation; self.lease = lease
    }

    func bookId() -> String { id }
    func pause() { lock.withLock { stopped = true } }
    var cancelled: Bool { lock.withLock { stopped } }
    var isRunning: Bool { lock.withLock { running } }

    func run<T>(_ work: () throws -> T) throws -> T {
        try lock.withLock {
            guard !stopped else { throw ReaderError.Paused }
            guard !running else { throw ReaderError.ImportBusy }
            running = true
        }
        defer { lock.withLock { running = false } }
        return try work()
    }

    func check() throws { if cancelled { throw ReaderError.Paused } }
}

enum IndexImport {
    static func recover(_ db: Database) throws {
        // A process never resumes an opaque decoder. Keep every published
        // reading draft; only unlinked restoration drafts are disposable.
        try db.execute(sql: """
            DELETE FROM main.books WHERE content_sha256 LIKE 'pending:%'
              AND NOT EXISTS(SELECT 1 FROM main.library_files WHERE book_id=books.id)
              AND EXISTS(SELECT 1 FROM main.import_jobs WHERE book_id=books.id AND purpose='restoration');
            UPDATE main.import_jobs SET phase='paused' WHERE phase IN ('preparing','importing','finalizing');
            DELETE FROM main.chapter_scan_stage;
            """)
    }

    static func availableText(_ db: Database, id: String, scope: String) throws -> ImportText {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT b.encoding,b.title,b.content_sha256,b.byte_count,b.chunk_count
            FROM main.books original
            LEFT JOIN main.import_jobs j ON j.book_id=original.id
            JOIN main.books b ON b.id=COALESCE(j.canonical_id,original.id)
            WHERE original.id=? AND (original.content_sha256 NOT LIKE 'pending:%' OR j.pending_owner=?)
            """, arguments: [id,scope]),
            let count = UInt32(exactly: row["chunk_count"] as Int64),
            let bytes = UInt64(exactly: row["byte_count"] as Int64) else { throw ReaderError.NotFound }
        let key = try parseReadingKey(value: row["content_sha256"])
        return ImportText(encoding: row["encoding"], id: id, title: row["title"], readingKey: key,
                          byteCount: bytes, chunkCount: count)
    }
}

extension ReaderIndex {
    private func check(_ db: Database, _ control: ImportControl) throws {
        try control.check()
        guard control.lease == lease, try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM main.import_jobs WHERE book_id=? AND generation=? AND pending_owner=?
             AND phase IN ('preparing','importing','finalizing'))
            """, arguments: [control.id,control.generation,lease.scope.key]) == true else { throw ReaderError.ImportBusy }
    }

    private func createImport(title: String, purpose: String) throws -> ImportControl {
        let id = UUID().uuidString.lowercased()
        try write { db in
            try db.execute(sql: "INSERT INTO main.books(id,title,content_sha256,encoding) VALUES(?,?,?,'')",
                           arguments: [id,title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名文本" : title,"pending:" + id])
            try db.execute(sql: "INSERT INTO main.import_jobs(book_id,purpose,pending_owner) VALUES(?,?,?)",
                           arguments: [id,purpose,lease.scope.key])
        }
        return try resumeImport(bookId: id)
    }

    func createImport(title: String) throws -> ImportControl { try createImport(title: title, purpose: "reading") }
    func createRestorationImport(title: String) throws -> ImportControl { try createImport(title: title, purpose: "restoration") }

    func resumeImport(bookId: String) throws -> ImportControl {
        try withTaskMap { active in
            guard active[bookId]?.control?.isRunning != true else { throw ReaderError.ImportBusy }
            let value = try write { db -> Int64 in
                try db.execute(sql: """
                    UPDATE main.import_jobs SET phase='preparing',generation=generation+1,error=NULL,final_sha=NULL
                    WHERE book_id=? AND pending_owner=? AND phase IN ('paused','failed','preparing','importing','finalizing')
                    """, arguments: [bookId,lease.scope.key])
                guard db.changesCount == 1,
                      let generation = try Int64.fetchOne(db, sql: "SELECT generation FROM main.import_jobs WHERE book_id=?", arguments: [bookId])
                else { throw ReaderError.ImportBusy }
                return generation
            }
            let control = ImportControl(id: bookId, generation: value, lease: lease)
            active[bookId] = .init(control: control)
            return control
        }
    }

    func importStatus(bookId: String) throws -> ImportStatus {
        try importState(bookId: bookId).status
    }

    func importState(bookId: String) throws -> (status: ImportStatus, preparation: PreparationState) {
        try withTaskMap { active in
            // Read the row and the runtime outcome in the same order as
            // failImport/resumeImport. A new generation cannot mix the two.
            let task = active[bookId]
            return try read { db in
                let row = try Row.fetchOne(db, sql: """
                    SELECT generation,phase,error FROM main.import_jobs WHERE book_id=? AND pending_owner=?
                    """, arguments: [bookId,self.lease.scope.key])
                let storedPhase: String? = row?["phase"]
                let generation: Int64? = row?["generation"]
                let preparation: PreparationState
                switch storedPhase {
                case "preparing", "importing", "finalizing":
                    let current = task.flatMap { $0.generation == generation ? $0 : nil }
                    if let terminal = current?.terminal {
                        preparation = terminal
                    } else if current?.control == nil {
                        preparation = .paused(detail: .noActiveWorker)
                    } else {
                        switch storedPhase {
                        case "preparing": preparation = .preparing
                        case "importing": preparation = .importing
                        default: preparation = .finalizing
                        }
                    }
                case "failed":
                    let error = (row?["error"] as String?).flatMap { try? decodeImportError(json: $0) }
                    preparation = .failed(detail: error.map { .reported(error: $0) } ?? .unavailable)
                case "paused":
                    preparation = .paused(detail: (row?["error"] as String?) == nil ? .unknown : .interrupted)
                case nil, "complete": preparation = .complete
                default: throw ReaderError.InvalidSettings
                }
                let phase: ImportPhase
                switch preparation {
                case .preparing: phase = .preparing
                case .importing: phase = .importing
                case .finalizing: phase = .finalizing
                case .failed: phase = .failed
                case .paused: phase = .paused
                case .complete: phase = .complete
                }
                let text = try IndexImport.availableText(db, id: bookId, scope: self.lease.scope.key)
                return (ImportStatus(text: text, phase: phase), preparation)
            }
        }
    }

    func importSourceByteCount(bookId: String) throws -> UInt64 {
        try read { db in
            let bytes = try Int64.fetchOne(db, sql: "SELECT source_size FROM main.import_jobs WHERE book_id=? AND pending_owner=?", arguments: [bookId,self.lease.scope.key]) ?? 0
            guard let count = UInt64(exactly: bytes) else { throw ReaderError.InvalidRange }
            return count
        }
    }

    func sourceBook(key: SourceContentKey) throws -> ImportText? {
        _ = try parseSha256(value: key.rawSha256)
        let policy = try normalizeSourceDecoding(decoding: key.decoding)
        return try read { db in
            guard let id = try String.fetchOne(db, sql: """
              SELECT b.id FROM main.source_imports s JOIN main.books b ON b.id=s.book_id
              WHERE s.raw_sha256=? AND s.decoding=? AND b.content_sha256 NOT LIKE 'pending:%'
              """, arguments: [key.rawSha256,policy]) else { return nil }
            return try IndexImport.availableText(db, id: id, scope: self.lease.scope.key)
        }
    }

    func hashImportSource(control: ImportControl, filePath: String) throws -> String {
        try IndexInput.file(filePath) { file in
            try IndexInput.rawHash { max in
                try control.check()
                let bytes = try file.read(upToCount: max) ?? Data()
                try control.check()
                return bytes
            }
        }
    }

    func validateImportSource(control: ImportControl, key: SourceContentKey) throws {
        _ = try parseSha256(value: key.rawSha256)
        let policy = try normalizeSourceDecoding(decoding: key.decoding)
        try write { db in
            try check(db, control)
            let existing = try Row.fetchOne(db, sql: "SELECT expected_raw_sha256,decoding FROM main.import_jobs WHERE book_id=?", arguments: [control.id])
            let raw = existing?["expected_raw_sha256"] as String?, prior = existing?["decoding"] as String?
            guard raw == nil || raw == key.rawSha256, prior == nil || prior == policy else { throw ReaderError.SourceChanged }
            try db.execute(sql: "UPDATE main.import_jobs SET expected_raw_sha256=?,decoding=? WHERE book_id=?",
                           arguments: [key.rawSha256,policy,control.id])
        }
    }

    func streamImport(control: ImportControl, filePath: String, expectedRawSha256: String, encodingOverride: String?) throws {
        try control.run {
            do {
                try IndexInput.file(filePath) { file in
                    let size = try file.seekToEnd()
                    guard let count = Int64(exactly: size) else { throw ReaderError.TextCapacityExceeded }
                    try file.seek(toOffset: 0)
                    try decodeImport(control: control, expectedRawSha: expectedRawSha256, policy: encodingOverride ?? "auto",
                                     sourceBytes: count, read: { max in
                         try control.check()
                         return try file.read(upToCount: max) ?? Data()
                    }, rewind: { try file.seek(toOffset: 0) })
                }
            } catch {
                // The only copy of the Rust state has left scope. A later
                // resume must allocate a new decoder and verify the prefix.
                let failure: ReaderError = control.cancelled ? .Paused :
                    (error as? ReaderError ?? .Storage(message: String(describing: type(of: error))))
                try? failImport(control: control, error: failure)
                throw failure
            }
        }
    }

    /// Owns read position, redo, expected digest and commit order; accepts a
    /// bounded Swift accessor so the real short-read path can be exercised.
    private func decodeImport(control: ImportControl, expectedRawSha: String, policy: String, sourceBytes: Int64,
                      read input: (Int) throws -> Data, rewind: () throws -> Void) throws {
        let requested = try normalizeSourceDecoding(decoding: policy)
        try validateImportSource(control: control, key: .init(rawSha256: expectedRawSha, decoding: requested))
        let prefix = try importStatus(bookId: control.id).text
        let encoding: String
        if prefix.chunkCount > 0 {
            encoding = prefix.encoding
        } else if requested == "auto" {
            encoding = try IndexInput.encoding(read: input)
            try rewind()
        } else {
            encoding = requested
        }
        let officialEncoding = try normalizeSourceDecoding(decoding: encoding)
        var state = try beginTextImport(encoding: officialEncoding, mode: .index, publishedChunkCount: prefix.chunkCount)
        try write { db in
            try check(db, control)
            try db.execute(sql: "UPDATE main.books SET encoding=? WHERE id=?", arguments: [officialEncoding,control.id])
            try db.execute(sql: "UPDATE main.import_jobs SET phase='importing',source_size=? WHERE book_id=?",
                           arguments: [sourceBytes,control.id])
        }

        var requestedReplay: UInt32? = prefix.chunkCount > 0 ? 0 : nil
        var replay: [TextChunk] = []
        while true {
            try control.check()
            let bytes = try input(8192)
            if let from = requestedReplay {
                replay.removeAll { $0.index < from }
                let needed = min(16, prefix.chunkCount - from)
                if replay.count < needed {
                    let start = from + UInt32(replay.count)
                    replay += try read { db in
                        try Self.chunks(db, id: control.id, from: start, limit: needed - (start - from))
                    }
                }
                guard replay.count == needed else { throw ReaderError.SourceChanged }
            } else if !replay.isEmpty { replay = [] }

            let step = try advanceTextImport(previous: state, bytes: bytes, eof: bytes.isEmpty, replay: replay)
            try control.check()
            if let identity = step.identity {
                guard identity.rawSha256 == expectedRawSha,
                      identity.sourceBytes == UInt64(exactly: sourceBytes) else { throw ReaderError.SourceChanged }
            }
            // This writer commits each productive step today. A bounded
            // batch may keep intermediate successors private; only committed
            // output can advance published progress. A failed commit discards
            // the entire working state, not just the output of the last step.
            if !step.chunks.isEmpty || !step.chapters.isEmpty || !step.blankUpdates.isEmpty || step.identity != nil {
                try write { db in
                    try check(db, control)
                    try Self.publish(db, id: control.id, step: step)
                }
            }
            if step.identity != nil { return }
            guard let next = step.next else { throw ReaderError.InvalidSettings }
            state = next
            requestedReplay = step.nextReplayChunk
        }
    }

    private static func publish(_ db: Database, id: String, step: TextImportStep) throws {
        for value in step.chunks {
            let chunk = value.chunk
            try db.execute(sql: "INSERT INTO main.chunks VALUES(?,?,?,?,?,?,?)",
                           arguments: [id,chunk.index,chunk.startUtf8,chunk.endUtf8,chunk.text,value.startCharCount,value.endCharCount])
        }
        if let last = step.chunks.last?.chunk {
            try db.execute(sql: "UPDATE main.books SET byte_count=?,chunk_count=? WHERE id=?",
                           arguments: [last.endUtf8,last.index + 1,id])
        }
        try db.execute(sql: """
            UPDATE main.books SET projection_end=?,projection_revision=projection_revision+1
            WHERE id=? AND projection_end<? AND byte_count>=?
            """, arguments: [step.projectionEnd,id,step.projectionEnd,step.projectionEnd])
        for span in step.blankUpdates {
            try db.execute(sql: """
                INSERT INTO main.reading_blanks VALUES(?,?,?)
                ON CONFLICT(book_id,start_utf8) DO UPDATE SET end_utf8=excluded.end_utf8
                WHERE end_utf8<>excluded.end_utf8
                """, arguments: [id,span.startUtf8,span.endUtf8])
            if db.changesCount > 0 {
                try db.execute(sql: "UPDATE main.books SET projection_revision=projection_revision+1 WHERE id=?", arguments: [id])
            }
        }
        for chapter in step.chapters {
            try db.execute(sql: "INSERT OR IGNORE INTO main.import_chapters VALUES(?,?,?,?,?,?)", arguments: [
                id,chapter.startUtf8,chapter.title,chapter.level,chapter.startCharCount,chapter.bodyCharCount
            ])
        }
        try db.execute(sql: "UPDATE main.import_jobs SET has_text=?,bytes_read=? WHERE book_id=?",
                       arguments: [step.hasText,step.sourceBytes,id])
        if let identity = step.identity {
            try db.execute(sql: "UPDATE main.import_jobs SET phase='finalizing',final_sha=? WHERE book_id=?",
                           arguments: [identity.contentSha256,id])
        }
    }

    func failImport(control: ImportControl, error: ReaderError) throws {
        guard control.lease == lease else { throw ReaderError.ImportBusy }
        try withTaskMap { active in
            guard active[control.id]?.control === control else { return }
            let paused = control.cancelled || error == .Paused
            active[control.id]?.terminal = paused ? .paused(detail: .interrupted) : .failed(detail: .reported(error: error))
            let data = try encodeImportError(error: error)
            try write { db in
                try db.execute(sql: """
                    UPDATE main.import_jobs SET phase=?,error=? WHERE book_id=? AND generation=?
                    AND pending_owner=? AND phase!='complete'
                    """, arguments: [paused ? "paused":"failed",data,control.id,control.generation,lease.scope.key])
            }
            active[control.id]?.terminal = nil
        }
    }

    func reuseImport(control: ImportControl, existingId: String) throws {
        try write { db in
            try check(db, control)
            let current = try Self.body(db, id: control.id, scope: lease.scope.key)
            let target = try Self.body(db, id: existingId, scope: lease.scope.key)
            guard current.count == 0, !target.sha.hasPrefix("pending:"),
                  try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM main.import_jobs j JOIN main.source_imports s
                  ON j.expected_raw_sha256=s.raw_sha256 AND j.decoding=s.decoding
                  WHERE j.book_id=? AND s.book_id=?)
                """, arguments: [control.id,target.id]) == true else { throw ReaderError.SourceChanged }
            try db.execute(sql: "UPDATE main.import_jobs SET canonical_id=?,phase='complete',has_text=1 WHERE book_id=?",
                           arguments: [target.id,control.id])
            try db.execute(sql: "UPDATE main.library_files SET book_id=? WHERE book_id=?", arguments: [target.id,control.id])
        }
    }

    func finishImport(control: ImportControl) throws -> String {
        let canonical = try write { db in
            try check(db, control)
            guard let hash = try String.fetchOne(db, sql: """
                SELECT final_sha FROM main.import_jobs WHERE book_id=? AND phase='finalizing'
                """, arguments: [control.id]) else { throw ReaderError.ImportBusy }
            let canonical = try String.fetchOne(db, sql: "SELECT id FROM main.books WHERE content_sha256=?", arguments: [hash]) ?? control.id
            if canonical == control.id {
                try db.execute(sql: "UPDATE main.books SET content_sha256=? WHERE id=?", arguments: [hash,control.id])
            }
            try db.execute(sql: "UPDATE main.import_jobs SET phase='complete',error=NULL,canonical_id=? WHERE book_id=?",
                           arguments: [canonical == control.id ? nil : canonical,control.id])
            try db.execute(sql: """
                INSERT INTO main.source_imports(raw_sha256,decoding,book_id)
                SELECT expected_raw_sha256,decoding,? FROM main.import_jobs WHERE book_id=? AND expected_raw_sha256 IS NOT NULL
                ON CONFLICT(raw_sha256,decoding) DO UPDATE SET book_id=excluded.book_id
                """, arguments: [canonical,control.id])
            try db.execute(sql: "UPDATE main.library_files SET book_id=? WHERE book_id=?", arguments: [canonical,control.id])
            return canonical
        }
        if canonical != control.id { try? cleanDuplicate(control.id) }
        return canonical
    }

    private func cleanDuplicate(_ id: String) throws {
        var changed = true
        while changed {
            changed = try write { db in
                try db.execute(sql: """
                    DELETE FROM main.chunks WHERE book_id=? AND chunk_index IN (
                      SELECT chunk_index FROM main.chunks WHERE book_id=? LIMIT 16)
                    """, arguments: [id,id])
                return db.changesCount > 0
            }
        }
        try write { db in try db.execute(sql: "DELETE FROM main.import_chapters WHERE book_id=?", arguments: [id]) }
    }

    func discardRestorationImport(control: ImportControl) throws {
        guard control.lease == lease, !control.isRunning else { throw ReaderError.ImportBusy }
        try write { db in
            try db.execute(sql: """
                DELETE FROM main.books WHERE id=? AND content_sha256 LIKE 'pending:%'
                AND NOT EXISTS(SELECT 1 FROM main.library_files WHERE book_id=books.id)
                AND EXISTS(SELECT 1 FROM main.import_jobs WHERE book_id=books.id AND generation=?
                           AND purpose='restoration' AND pending_owner=?)
                """, arguments: [control.id,control.generation,lease.scope.key])
        }
        _ = try reclaimCompletedImport(bookId: control.id)
    }

    func completedReadingImportIDs(bookId: String? = nil) throws -> [String] {
        try read { db in
            try String.fetchAll(db, sql: """
                SELECT book_id FROM main.import_jobs WHERE phase='complete' AND purpose='reading'
                AND pending_owner=? AND (? IS NULL OR book_id=?) ORDER BY book_id
                """, arguments: [self.lease.scope.key,bookId,bookId])
        }
    }

    func reclaimCompletedImports(retainedBookIds: [String], promotedReadingBookIDs: Set<String> = []) throws -> [String] {
        try reclaim(retained: Set(retainedBookIds), promoted: promotedReadingBookIDs, only: nil)
    }

    func reclaimCompletedImport(bookId: String, userPromotionCommitted: Bool = false) throws -> Bool {
        try reclaim(retained: [], promoted: userPromotionCommitted ? [bookId] : [], only: bookId).isEmpty
    }

    private func reclaim(retained: Set<String>, promoted: Set<String>, only: String?) throws -> [String] {
        try withTaskMap { active in
            let byWorker = Set(active.filter { $0.value.control?.isRunning == true }.keys)
            let remaining = try write { db in
                let done = try Row.fetchAll(db, sql: """
                    SELECT book_id,canonical_id,purpose FROM main.import_jobs
                    WHERE phase='complete' AND pending_owner=? AND (? IS NULL OR book_id=?)
                    """, arguments: [lease.scope.key,only,only])
                for row in done {
                    let id: String = row["book_id"]
                    guard !retained.contains(id), !byWorker.contains(id) else { continue }
                    guard row["purpose"] as String == "restoration" || promoted.contains(id) else { continue }
                    if let canonical = row["canonical_id"] as String? {
                        try db.execute(sql: "UPDATE main.library_files SET book_id=? WHERE book_id=?", arguments: [canonical,id])
                        try db.execute(sql: "UPDATE main.source_imports SET book_id=? WHERE book_id=?", arguments: [canonical,id])
                        try db.execute(sql: "DELETE FROM main.books WHERE id=?", arguments: [id])
                    } else {
                        try db.execute(sql: "DELETE FROM main.import_jobs WHERE book_id=?", arguments: [id])
                    }
                }
                return try String.fetchAll(db, sql: """
                    SELECT book_id FROM main.import_jobs WHERE (? IS NULL OR book_id=?)
                    """, arguments: [only,only])
            }
            let ids = Set(remaining)
            active = active.filter { id, entry in
                (entry.control != nil || entry.terminal != nil) && ((only.map { $0 != id } ?? false) || ids.contains(id))
            }
            return remaining
        }
    }
}
