import Foundation
import GRDB
import SwiftData

/// Existing released containers, opened and frozen by the handoff owner. The
/// source remains intact. A nil/uncertain scope must never be guessed as local.
struct LegacyUserSnapshot: Sendable {
    var scope: DataScope?
    var formal: ModelContainer?
    var pending: ModelContainer?
    /// The existing app-private full-size cover directory, when available.
    /// No external shelf paths or thumbnail cache is a migration source.
    var coverDirectory: URL? = nil
    var deviceState: DeviceState = .init()

    /// The identity decision belongs to startup. This only opens the
    /// published files, with saves and CloudKit disabled. An unreadable file
    /// throws; only a confirmed missing file is represented by nil.
    static func open(directory: URL, scope: DataScope, deviceState: DeviceState) throws -> Self {
        let schema = Schema([UserPosition.self, UserValue.self, AnnotationOperation.self,
                             ReadingFact.self, StatisticsClear.self, UserCover.self])
        func openStore(_ filename: String) throws -> ModelContainer? {
            let file = directory.appending(path: filename)
            do { _ = try FileManager.default.attributesOfItem(atPath: file.path) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                return nil
            }
            let configuration = ModelConfiguration("UserData", schema: schema, url: file,
                                                   allowsSave: false, cloudKitDatabase: .none)
            return try ModelContainer(for: schema, configurations: [configuration])
        }
        return try .init(scope: scope, formal: openStore("user-data.store"),
                         pending: openStore("pending-users.store"),
                         coverDirectory: directory.appending(path: "Assets/Covers", directoryHint: .isDirectory),
                         deviceState: deviceState)
    }

    struct DeviceState: Sendable {
        var hidden: [String] = []
        var preferred: [String: String] = [:]
        var resume: [String: LocalReadingResumeState.Entry] = [:]

        init() {}

        /// Legacy hidden/preferred keys had no separate account namespace.
        /// Only use them after the original owner of this store is known.
        init(defaults: UserDefaults, confirmedLegacyResumeScope: String) throws {
            let resumeState = try LocalReadingResumeState(data: defaults.data(forKey: LocalReadingResumeState.key))
            resume = resumeState.scopes[confirmedLegacyResumeScope] ?? [:]
            hidden = defaults.stringArray(forKey: "Moonread.hiddenRecent") ?? []
            for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("Moonread.preferredFile.") {
                if let file = value as? String { preferred[String(key.dropFirst("Moonread.preferredFile.".count))] = file }
            }
        }
    }
}

enum LegacyUserImport {
    private typealias Field = (String, (any DatabaseValueConvertible)?)
    private struct Identity {
        var id: String
        let book: String?
        var mark: String? = nil
        var key: String? = nil
        var session: String? = nil
        var device: String? = nil
    }

    private struct BadRow: Error {
        var reason: String
    }
    private struct Version: Decodable { var v: Int64? }
    static func run(_ db: Database, snapshot: LegacyUserSnapshot) throws {
        guard let scope = snapshot.scope else { throw DataV2Error.incompatibleSource("legacy users have no confirmed owner") }
        guard try !completed(db) else { throw DataV2Error.migrationAlreadyComplete }
        if let formal = snapshot.formal {
            try read(ModelContext(formal), db: db, partition: 0, source: scope.key, coverDirectory: snapshot.coverDirectory)
        }
        if let pending = snapshot.pending {
            try read(ModelContext(pending), db: db, partition: 1, source: scope.key, coverDirectory: snapshot.coverDirectory)
        }
        try reconcileCoverCompleteness(db, source: scope.key)
        try putDeviceState(snapshot.deviceState, db: db)
        try CurrentUserRows.settleImported(db)
        var history = ReadingHistoryRows.Changed()
        history.facts = try ReadingFactSettlement.affectedIDs(db)
        try history.settle(db, scope: scope)
        guard try Row.fetchOne(db, sql: "PRAGMA usr.foreign_key_check") == nil else {
            throw DataV2Error.migrationNotVerified
        }
        // Structural migration may retain missing attachment markers, but
        // cutover cannot use this marker as evidence that all assets arrived.
        try db.execute(sql: "INSERT INTO usr.local_data_state VALUES ('legacy-user-import','structural-v1')")
    }

    static func reconcileCoverCompleteness(_ db: Database, source: String? = nil) throws {
        // A nil UserCover has no checksum of its own. It stops being missing
        // only if its logical ID has a single, complete byte variant after
        // both partitions and all checksum-verified cache fallbacks were read.
        let missing = try Row.fetchAll(db, sql: """
            SELECT quarantine_id,raw_bytes FROM usr.quarantined_record
            WHERE source='swiftdata' AND (?1 IS NULL OR source_id=?1) AND source_type='UserCover'
              AND reason='unavailable-attachment' AND raw_format='legacy-cover-id' AND completeness='incomplete'
            """, arguments: [source])
        var markers: [String: [Int64]] = [:]
        for row in missing {
            guard let id = String(data: row["raw_bytes"], encoding: .utf8), !id.isEmpty else { continue }
            markers[DataIdentity.canonical(id), default: []].append(row["quarantine_id"])
        }
        if !markers.isEmpty {
            var resolved = Set<String>(), ambiguous = Set<String>()
            do {
                // Read only identity headers, never all the cover bytes.
                let assets = try Row.fetchCursor(db, sql: "SELECT legacy_cover_id,availability,expected_sha FROM usr.cover_asset WHERE legacy_cover_id IS NOT NULL")
                while let row = try assets.next() {
                    let id = DataIdentity.canonical(row["legacy_cover_id"])
                    guard markers[id] != nil else { continue }
                    if (row["availability"] as String) != "available" || (row["expected_sha"] as String?) == nil ||
                        !resolved.insert(id).inserted {
                        ambiguous.insert(id)
                    }
                }
            }
            for id in resolved.subtracting(ambiguous) {
                for marker in markers[id, default: []] {
                    try db.execute(sql: "DELETE FROM usr.quarantined_record WHERE quarantine_id=?", arguments: [marker])
                }
            }
        }
        try db.execute(sql: """
            UPDATE usr.legacy_import_state AS rows SET completeness=CASE WHEN EXISTS(
              SELECT 1 FROM usr.quarantined_record q WHERE q.source='swiftdata' AND q.source_id=rows.source_id
                AND q.partition=rows.partition AND q.source_type='UserCover' AND q.completeness='incomplete'
            ) THEN 'incomplete' ELSE 'complete' END
            WHERE (?1 IS NULL OR rows.source_id=?1) AND rows.source_model='UserCover'
            """, arguments: [source])
        try db.execute(sql: """
            UPDATE usr.legacy_import_state AS rows SET completeness=CASE WHEN EXISTS(
              SELECT 1 FROM usr.cover_candidate c JOIN usr.cover_asset a ON a.asset_id=c.asset_id
              WHERE c.partition=rows.partition AND a.availability<>'available'
            ) THEN 'incomplete' ELSE 'complete' END
            WHERE (?1 IS NULL OR rows.source_id=?1) AND rows.source_model='UserValue'
            """, arguments: [source])
    }

    static func completed(_ db: Database) throws -> Bool {
        switch try String.fetchOne(db, sql: "SELECT value FROM usr.local_data_state WHERE state_key='legacy-user-import'") {
        case nil: return false
        case "structural-v1", "absent-v1": return true
        default: throw DataV2Error.incompatibleSource("legacy user import marker")
        }
    }

    static func recordAbsentSource(_ db: Database) throws {
        try db.execute(sql: "INSERT INTO usr.local_data_state VALUES ('legacy-user-import','absent-v1')")
    }

    private static func read(_ context: ModelContext, db: Database, partition: Int, source: String, coverDirectory: URL?) throws {
        let importer = Importer(db: db, partition: partition, source: source, coverDirectory: coverDirectory)
        // Each pass uses the already-frozen SwiftData store; one batch of model
        // references is live at a time. Covers may be individually large.
        func each<T: PersistentModel>(_ model: T.Type, _ name: String, size: Int = 128,
                                      _ consume: (T) throws -> Void) throws {
            var count = 0
            var fetch = FetchDescriptor<T>()
            fetch.fetchLimit = size
            while true {
                try Task.checkCancellation()
                fetch.fetchOffset = count
                let rows = try context.fetch(fetch)
                if rows.isEmpty { break }
                for row in rows { try consume(row) }
                count += rows.count
                if rows.count < size { break }
            }
            let incomplete = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM usr.quarantined_record
                    WHERE partition=? AND source_id=? AND source_type=? AND completeness='incomplete')
                """, arguments: [partition, source, name]) == true
            try db.execute(sql: """
                INSERT INTO usr.legacy_import_state
                (source_id,partition,source_model,imported_count,completeness,import_version)
                VALUES (?,?,?,?,?,1)
                """, arguments: [source, partition, name, count, incomplete ? "incomplete" : "complete"])
        }

        try each(UserCover.self, "UserCover", size: 8) { try importer.asset(id: $0.id, bytes: $0.bytes) }
        try each(UserValue.self, "UserValue") { try importer.value($0.payload, key: $0.key, device: $0.device, model: "UserValue") }
        try each(UserPosition.self, "UserPosition") {
            try importer.value($0.payload, key: "position/" + $0.contentKey, device: nil, model: "UserPosition")
        }
        try each(AnnotationOperation.self, "AnnotationOperation") { try importer.annotation($0) }
        try each(ReadingFact.self, "ReadingFact") { try importer.fact($0) }
        try each(StatisticsClear.self, "StatisticsClear") { try importer.clear($0.payload) }
    }

    private static func putDeviceState(_ state: LegacyUserSnapshot.DeviceState, db: Database) throws {
        for book in state.hidden {
            try db.execute(sql: "INSERT OR IGNORE INTO usr.local_hidden_book VALUES (?)",
                           arguments: [DataIdentity.canonical(book)])
        }
        for (book, file) in state.preferred {
            try db.execute(sql: "INSERT INTO usr.local_preferred_file VALUES (?,?)",
                           arguments: [DataIdentity.canonical(book),file])
        }
        for (book, item) in state.resume {
            try db.execute(sql: "INSERT INTO usr.local_resume VALUES (?,?,?)",
                           arguments: [DataIdentity.canonical(book),item.lastLocalWriteToken,DataIdentity.unsigned(item.offset)])
        }
    }

    private struct Importer {
        let db: Database
        let partition: Int
        let source: String
        let coverDirectory: URL?

        func archive(_ data: Data, model: String, identity: Identity, reason: String, version: Int64? = nil,
                     format: String = "legacy-json", incomplete: Bool = false) throws {
            try db.execute(sql: """
                INSERT OR IGNORE INTO usr.quarantined_record
                (partition,source,source_id,source_type,record_id,schema_version,book_key,mark_id,logical_key,session_id,device_id,
                 raw_format,raw_bytes,digest,reason,completeness)
                VALUES (?,'swiftdata',?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: [partition,source,model,identity.id,version,identity.book.map(DataIdentity.canonical),
                    identity.mark.map(DataIdentity.canonical),identity.key.map(DataIdentity.canonical),
                    identity.session.map(ReadingFactRows.identity),identity.device.map(DataIdentity.canonical),
                    format,data,DataIdentity.sha(data),reason,incomplete ? "incomplete" : "complete"])
        }

        func decode(_ payload: String, model: String, identity: Identity, _ body: () throws -> Void) throws {
            do { try body() }
            catch let error as UserSyncCompatibilityError {
                let version = (try? JSONDecoder().decode(Version.self, from: Data(payload.utf8)))?.v
                try archive(Data(payload.utf8), model: model, identity: identity,
                            reason: error.reason == .newerFormat ? "future-or-unknown" : "unreadable", version: version)
            } catch let fault as BadRow {
                try archive(Data(payload.utf8), model: model, identity: identity, reason: fault.reason)
            }
        }

        func write(_ table: String, idColumn: String = "record_id", identity: Identity, body: [Field],
                   relations: [Relation] = [], clock: StoredValue? = nil) throws {
            let base: [Field] = [("partition",partition),(idColumn,identity.id),("schema_version",1)]
            let fields = base + body
            let args: StatementArguments = [partition,identity.id]
            let lookup = "WHERE partition=? AND \(idColumn)=?"
            if let old = try Row.fetchOne(db, sql: "SELECT * FROM usr.\(table) " + lookup, arguments: args) {
                let isPosition = table == "position_candidate"
                let sameFields = fields.allSatisfy { key, value in
                    // Position identity already binds token. Like the legacy
                    // same-update rule, compare the time and whole typed body,
                    // not the device column from one of the storage models.
                    if isPosition && key == "device_id" { return true }
                    let previous: DatabaseValue = old[key]
                    return previous == (value?.databaseValue ?? .null)
                }
                if sameFields, try relations.allSatisfy({ try $0.matches(db, partition: partition, id: identity.id) }) {
                    // UserValue is read first. Keep that directly recorded
                    // device when the other model has no attribution. If two
                    // explicit attributions disagree, do not choose one.
                    if isPosition, let previous = old["device_id"] as String?,
                       let incoming = identity.device, previous != incoming {
                        try db.execute(sql: "UPDATE usr.position_candidate SET device_id=NULL " + lookup, arguments: args)
                    }
                    return
                }
                if let clock {
                    let previous: (Int64, String) = (old["updated_ms"],old["token"])
                    let incoming = (clock.updated,clock.token)
                    if incoming < previous { return }
                    if incoming > previous {
                        try db.execute(sql: "DELETE FROM usr.\(table) " + lookup, arguments: args)
                    } else { throw BadRow(reason: "same-clock-conflict") }
                } else { throw BadRow(reason: "stable-id-conflict") }
            }
            try insert(table, fields: fields)
            for relation in relations { try relation.insert(self, parent: identity.id) }
        }

        private func insert(_ table: String, fields: [Field]) throws {
            let names = fields.map(\.0).joined(separator: ",")
            let markers = Array(repeating: "?", count: fields.count).joined(separator: ",")
            try db.execute(sql: "INSERT INTO usr.\(table)(\(names)) VALUES(\(markers))",
                           arguments: StatementArguments(fields.map { $0.1?.databaseValue ?? .null }))
        }

        struct Relation {
            let table: String
            let parentField: String
            let rows: [[Field]]
            func matches(_ db: Database, partition: Int, id: String) throws -> Bool {
                let existing = try Row.fetchAll(db, sql: "SELECT * FROM usr.\(table) WHERE partition=? AND \(parentField)=?",
                                                arguments: [partition,id])
                return existing.count == rows.count && rows.allSatisfy { row in
                    existing.contains { old in
                        row.allSatisfy { key, value in
                            let previous: DatabaseValue = old[key]
                            return previous == (value?.databaseValue ?? .null)
                        }
                    }
                }
            }
            func insert(_ owner: Importer, parent: String) throws {
                for row in rows { try owner.insert(table, fields: [("partition",owner.partition),(parentField,parent)] + row) }
            }
        }

        func relation(_ table: String, parent: String = "candidate_id", field: String, values: Set<String>) -> Relation {
            .init(table: table, parentField: parent, rows: values.sorted().map { [
                (field,DataIdentity.canonical($0))
            ] })
        }

        func asset(id: String, bytes: Data?) throws {
            if let bytes {
                let digest = DataIdentity.sha(bytes)
                let key = UserValueRows.assetID(id, sha: digest)
                try db.execute(sql: """
                    INSERT INTO usr.cover_asset(asset_id,legacy_cover_id,bytes,expected_sha,availability)
                    VALUES(?,?,?,?,'available') ON CONFLICT(asset_id)
                    DO UPDATE SET bytes=excluded.bytes,availability='available' WHERE cover_asset.bytes IS NULL
                    """, arguments: [key,id,bytes,digest])
            } else {
                // No logical digest is available on a bare UserCover row.
                // Preserve the original ID without making it a usable asset.
                try archive(Data(id.utf8), model: "UserCover", identity: .init(id: DataIdentity.id("cover", [id]), book: nil),
                            reason: "unavailable-attachment", format: "legacy-cover-id", incomplete: true)
            }
        }

        private func coverAsset(_ cover: UserValueRows.Cover) throws -> String {
            let key = UserValueRows.assetID(cover.id, sha: cover.sha256)
            let present = try Bool.fetchOne(db, sql: "SELECT availability='available' FROM usr.cover_asset WHERE asset_id=?",
                                            arguments: [key]) == true
            if !present, let coverDirectory, UUID(uuidString: cover.id) != nil,
               ["jpg","png"].contains(cover.format), (try? parseSha256(value: cover.sha256)) != nil {
                let file = coverDirectory.appending(path: "\(cover.id)-\(cover.sha256).\(cover.format)")
                // Files may be absent in older stores; do not turn I/O problems
                // or a mismatched digest into usable attachment bytes.
                if let bytes = try? Data(contentsOf: file), DataIdentity.sha(bytes) == cover.sha256 {
                    try asset(id: cover.id, bytes: bytes)
                    return key
                }
            }
            try db.execute(sql: "INSERT OR IGNORE INTO usr.cover_asset VALUES(?,?,NULL,?,'missing')",
                           arguments: [key,cover.id,cover.sha256])
            return key
        }

        func value(_ payload: String, key: String, device: String?, model: String) throws {
            let parts = key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let kind = UserSyncJSON.kind(key)
            let book: String? = ["metadata","position","opened","chapter"].contains(parts.first ?? "") && parts.count >= 2 ? parts[1] : nil
            let logicalID = kind == .chapter && parts.count == 3
                ? (UInt64(parts[2]).map { "chapter/\(parts[1])/\($0)" } ?? key) : key
            let identity = Identity(id: DataIdentity.id("value", [logicalID, device ?? ""]), book: book,
                                    key: logicalID, device: device)
            try decode(payload, model: model, identity: identity) {
                let head = try UserSyncJSON.storedValue(payload, key: key)
                guard let kind, parts.count >= 2 else { throw BadRow(reason: "unknown-key") }
                let member = DataIdentity.canonical(parts[1])
                if kind == .position {
                    let value = try PositionCandidate(head).value
                    let hint = value.source_hint
                    let size = hint?.byte_size.flatMap { Int64(exactly: $0) }
                    var position = identity
                    position.id = DataIdentity.id("position", [value.content_key, head.token])
                    try write("position_candidate", identity: position, body: [
                        ("book_key",member),
                        ("updated_ms",head.updated),("token",head.token),("device_id",device),
                        ("offset",DataIdentity.unsigned(value.offset)),("source_kind",hint?.source_kind.rawValue),
                        ("relative_path",hint?.relative_path),("file_name",hint?.file_name),
                        ("byte_size",size),("decoding",hint?.decoding),
                    ])
                    return
                }
                guard let device else { throw BadRow(reason: "missing-device") }
                let shared: [Field] = [("logical_key",DataIdentity.canonical(logicalID)),("device_id",DataIdentity.canonical(device)),
                                       ("updated_ms",head.updated),("token",head.token)]
                let route = try UserValueRows.Key(key)
                let body = try UserValueRows.body(route, value: head.value, coverAsset: coverAsset)
                let relations: [Relation] = body.colors.isEmpty ? [] : [.init(table: "palette_color", parentField: "candidate_id", rows: body.colors)]
                try write(route.table, identity: identity, body: shared + body.fields, relations: relations, clock: head)
            }
        }

        func annotation(_ row: AnnotationOperation) throws {
            let identity = Identity(id: DataIdentity.canonical(row.id), book: row.contentKey, mark: row.markID)
            try decode(row.payload, model: "AnnotationOperation", identity: identity) {
                let value = try UserSyncJSON.annotation(row.payload, id: row.id)
                let content = value.content
                try write("annotation_candidate", identity: identity, body: [
                    ("book_key",DataIdentity.canonical(row.contentKey)),
                    ("mark_id",DataIdentity.canonical(row.markID)),("created",DataIdentity.unsigned(value.created)),
                    ("bookmark",value.bookmark),("is_deleted",content == nil),("start",content.map { DataIdentity.unsigned($0.start) }),
                    ("end",content.map { DataIdentity.unsigned($0.end) }),("excerpt",content?.excerpt),("note",content?.note),
                    ("merged_into",value.mergedInto.map(DataIdentity.canonical)),
                ], relations: [
                    relation("annotation_ancestor", field: "ancestor_id", values: value.ancestors),
                    relation("annotation_related_mark", field: "related_mark_id", values: value.relatedMarks),
                ])
            }
        }

        func fact(_ row: ReadingFact) throws {
            let identity = Identity(id: ReadingFactRows.identity(row.id), book: row.contentKey)
            try decode(row.payload, model: "ReadingFact", identity: identity) {
                let batch = try decodeFactBatch(base: 0, payloads: [row.payload])
                guard let cue = batch.cues().first else { throw BadRow(reason: "missing-fact") }
                _ = try UserSyncJSON.bindFact(cue, id: row.id)
                let value = try batch.importColumns(ordinal: cue.ordinal)
                guard let duration = value.durationMs else { throw BadRow(reason: "duration-overflow") }
                guard duration >= 0 else { throw BadRow(reason: "negative-fact-duration") }
                guard (try? parseReadingKey(value: row.contentKey)) != nil else { throw BadRow(reason: "invalid-fact-book") }
                try ReadingFactSettlement.ingest(db, value, book: row.contentKey, partition: partition, scope: source,
                                                 origin: .init(source: "swiftdata", id: row.id))
            }
        }

        func clear(_ payload: String) throws {
            let scope = try? JSONDecoder().decode(UserSyncClearScope.self, from: Data(payload.utf8))
            let identity = Identity(id: DataIdentity.sha(Data(payload.utf8)), book: scope?.book, session: scope?.session)
            try decode(payload, model: "StatisticsClear", identity: identity) {
                let value = try UserSyncJSON.decode(ClearValue.self, payload, as: UserSyncJSON.clear, envelope: true)
                var semantic = identity
                semantic.id = ReadingFactRows.clearRecordID(book: value.book, session: value.session, through: value.through, ids: value.ids)
                try write("statistics_clear", identity: semantic, body: [
                    ("book_key",value.book.map(DataIdentity.canonical)),
                    ("session_id",value.session.map(ReadingFactRows.identity)),("through_ms",value.through)
                ], relations: [Relation(table: "statistics_clear_id", parentField: "clear_id", rows: Set(value.ids.map(ReadingFactRows.identity)).sorted().map { [("fact_id",$0)] })])
            }
        }
    }
}
