import Foundation
import GRDB
import SwiftData

/// A writable mirror is a new, isolated store for one verified account.
/// Never open the shared v1.6 file for network writes: the released owner
/// preference is evidence for local migration, not attestation of that file.
struct LegacyMirrorStore: Sendable {
    let scope: DataScope
    let file: URL
    let container: ModelContainer

    static func location(in layout: DataLayout, scope: DataScope) throws -> URL {
        guard scope != .local else { throw DataV2Error.invalidOwnerState }
        let path = try layout.directory(scope).appending(path: "legacy-mirror/user-data.store")
        let root = layout.root.standardizedFileURL
        let relative = String(path.standardizedFileURL.path.dropFirst(root.path.count))
        let expected = root.resolvingSymlinksInPath().path + relative
        guard path.resolvingSymlinksInPath().path == expected else {
            throw DataV2Error.incompatibleSource("redirected legacy mirror")
        }
        return path
    }

    private init(layout: DataLayout, scope: DataScope, cloud: ModelConfiguration.CloudKitDatabase) throws {
        let file = try Self.location(in: layout, scope: scope)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let schema = UserDataStore.schema
        let config = ModelConfiguration("UserData", schema: schema, url: file, cloudKitDatabase: cloud)
        let container = try ModelContainer(for: schema, configurations: [config])
        self.scope = scope
        self.file = file
        self.container = container
    }

    /// Only the signed Probe factory can produce an account proof.
    static func openProbe(layout: DataLayout, account: ReadingSyncEngineAdapter.VerifiedProbeAccount) throws -> Self {
        try .init(layout: layout, scope: account.scope, cloud: .private(ReadingSyncEngineAdapter.testContainer))
    }

    #if DEBUG
    /// Synthetic disk store only: there is no arbitrary container/setter and
    /// this entry never enables mirroring or reads the released source.
    static func localFixture(layout: DataLayout, scope: DataScope) throws -> Self {
        try .init(layout: layout, scope: scope, cloud: .none)
    }
    #endif
}

/// This status is device-local and stored in the account writer. Retiring
/// the engine does not retire the bridge, and an old SDK result cannot undo
/// an explicit finish. No state here is published to CloudKit.
enum LegacyBridgePolicy {
    enum Phase: String, Sendable { case required = "required-v1", finished = "finished-v1" }
    enum Failure: Error { case finished, notReady }
    private static let key = "legacy-mirror-phase"

    static func phase(_ db: Database) throws -> Phase? {
        guard let value = try String.fetchOne(db, sql: "SELECT value FROM usr.local_data_state WHERE state_key=?",
                                             arguments: [key]) else { return nil }
        guard let phase = Phase(rawValue: value) else {
            throw DataV2Error.incompatibleSource("legacy bridge phase")
        }
        return phase
    }

    static func require(_ db: Database) throws {
        guard try phase(db) != .finished else { throw Failure.finished }
        switch try CloudTransportRows.zoneStage(db, zone: ReadingHistoryTransport.zone) {
        case .ready, .unverified, .needsCreation: break
        default: throw Failure.notReady
        }
        try db.execute(sql: "INSERT OR IGNORE INTO usr.local_data_state VALUES (?,?)",
                       arguments: [key, Phase.required.rawValue])
    }

    static func checkIntake(_ db: Database) throws {
        guard try phase(db) == .required,
              try CloudTransportRows.zoneStage(db, zone: ReadingHistoryTransport.zone) == .ready else {
            throw Failure.notReady
        }
    }

    /// Only an explicit bridge finish or a confirmed W2 privacy reset may
    /// close intake permanently for this existing account database.
    static func finish(_ db: Database) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO usr.local_data_state VALUES (?,?)",
                       arguments: [key, Phase.finished.rawValue])
        try db.execute(sql: "DELETE FROM usr.legacy_mirror_link")
        try db.execute(sql: "DELETE FROM usr.local_data_state WHERE state_key=?", arguments: [LegacyUserImport.mirrorCursor])
    }
}

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
    static let mirrorCursor = "legacy-mirror-cursor-v1"
    private struct MirrorCursor: Codable {
        let store: String
        let token: DefaultHistoryToken
    }

    private static func mirrorModel<T: PersistentModel>(_ type: T.Type, _ context: ModelContext,
                                                         _ id: PersistentIdentifier) throws -> T? {
        var request = FetchDescriptor<T>(predicate: #Predicate { $0.persistentModelID == id })
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    /// Read committed changes only. An expired token or a replaced store
    /// must not turn into a full replay of the old mirror.
    static func consumeMirrorPage(_ db: Database, store: LegacyMirrorStore) throws -> Bool {
        try LegacyBridgePolicy.checkIntake(db)
        let saved = try String.fetchOne(db, sql: "SELECT value FROM usr.local_data_state WHERE state_key=?",
                                       arguments: [mirrorCursor])
        let prior = try saved.map { try JSONDecoder().decode(MirrorCursor.self, from: Data($0.utf8)) }
        var history = HistoryDescriptor<DefaultHistoryTransaction>()
        if let token = prior?.token { history.predicate = #Predicate { $0.token > token } }
        history.fetchLimit = 1  // One source transaction per target commit.
        let context = ModelContext(store.container)
        context.autosaveEnabled = false
        guard let transaction = try context.fetchHistory(history).first else { return false }
        guard prior.map({ $0.store == transaction.storeIdentifier && $0.token < transaction.token }) ?? true else {
            throw DataV2Error.incompatibleSource("legacy mirror history changed")
        }

        // Read each object's current evidence once, in its last change order.
        // A missing upsert may have a later physical DELETE; only a history
        // DELETE explicitly authorizes removal of a mapped candidate.
        var latest: [PersistentIdentifier: Int] = [:]
        for (index, change) in transaction.changes.enumerated() {
            latest[change.changedPersistentIdentifier] = index
        }
        let effects = MirrorEffects()
        for (index, change) in transaction.changes.enumerated() {
            let identifier = change.changedPersistentIdentifier
            guard latest[identifier] == index else { continue }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let sourceIdentifier = try encoder.encode(identifier)
            if case .delete = change {
                try MirrorEffects.unlink(db, object: DataIdentity.sha(sourceIdentifier),
                                         removingEvidence: transaction.author != LegacyReadingDeletion.author,
                                         effects: effects)
                continue
            }
            let tracking = MirrorTracking(sourceIdentifier: sourceIdentifier, effects: effects)
            let importer = Importer(db: db, partition: 0, source: store.scope.key, coverDirectory: nil, mirror: tracking)
            if try importer.importMirrorModel(context, identifier) {
                try MirrorEffects.replaceLinks(db, tracking: tracking)
            }
        }
        try effects.reselectFixedSlots(db, context: context, scope: store.scope)
        try effects.settleAndRelease(db, scope: store.scope)
        let cursor = try JSONEncoder().encode(MirrorCursor(store: transaction.storeIdentifier, token: transaction.token))
        try db.execute(sql: "INSERT OR REPLACE INTO usr.local_data_state VALUES (?,?)",
                       arguments: [mirrorCursor,String(decoding: cursor, as: UTF8.self)])
        return true
    }

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

    private enum MirrorDomain: String {
        case metadata = "metadata_text_candidate", tag = "tag_candidate", cover = "cover_candidate"
        case position = "position_candidate", opened = "opened_candidate", chapter = "chapter_override_candidate"
        case annotation = "annotation_candidate", fact = "reading_fact", clear = "statistics_clear"
        case decoding = "source_decoding_candidate", palette = "palette_candidate", shelf = "shelf_reference_candidate"
        case opaque = "quarantined_record", asset = "cover_asset"

        var filter: String {
            switch self {
            case .fact: "partition=0 AND fact_id=?"
            case .opaque: "partition=0 AND quarantine_id=?"
            case .asset: "asset_id=?"
            default: "partition=0 AND record_id=?"
            }
        }

        func row(_ db: Database, _ id: String) throws -> Row? {
            try Row.fetchOne(db, sql: "SELECT * FROM usr.\(rawValue) WHERE " + filter, arguments: [id])
        }

        func transport(_ row: Row, id: String) -> CloudTransportRows.Key? {
            if let family = fixedFamily(row) { return FixedValueCloudRows.key(family, id: id) }
            switch self {
            case .position: return CausalCloudRows.key(.position, id: id)
            case .annotation: return CausalCloudRows.key(.annotation, id: id)
            case .clear: return ReadingHistoryTransport.key(.clear, id: id)
            default: return nil
            }
        }

        func fixedFamily(_ row: Row) -> FixedValueCloudRows.Family? {
            switch self {
            case .metadata, .tag, .cover, .opened, .chapter, .decoding, .palette, .shelf:
                (row["logical_key"] as String?).flatMap(UserSyncJSON.kind).flatMap(FixedValueCloudRows.Family.init)
            default: nil
            }
        }
    }

    private struct MirrorRef: Hashable {
        let domain: MirrorDomain
        let id: String
        let fingerprint: String?
        init(_ domain: MirrorDomain, _ id: String, _ fingerprint: String?) {
            self.domain = domain; self.id = id; self.fingerprint = fingerprint
        }
        init(row: Row) throws {
            guard let domain = MirrorDomain(rawValue: row["domain"]) else {
                throw DataV2Error.incompatibleSource("legacy mirror link")
            }
            self.init(domain, row["record_id"], row["fingerprint"])
        }
        static func fingerprint(_ row: Row) -> String {
            let cells = zip(row.columnNames, row.databaseValues).flatMap { name, value -> [String] in
                let cell: String = switch value.storage {
                case .null: "n"
                case .int64(let number): "i" + String(number)
                case .double(let number): "f" + String(number.bitPattern)
                case .string(let text): "t" + DataIdentity.sha(Data(text.utf8))
                case .blob(let bytes): "b" + DataIdentity.sha(bytes)
                }
                return [name, cell]
            }
            return DataIdentity.id("legacy-mirror-row", cells)
        }
    }

    private final class MirrorTracking {
        let object: String
        let sourceIdentifier: Data
        let effects: MirrorEffects
        var refs = Set<MirrorRef>()
        init(sourceIdentifier: Data, effects: MirrorEffects) {
            self.sourceIdentifier = sourceIdentifier
            object = DataIdentity.sha(sourceIdentifier)
            self.effects = effects
        }
        func persistLinks(_ db: Database) throws {
            for ref in refs {
                try db.execute(sql: "INSERT OR REPLACE INTO usr.legacy_mirror_link VALUES(?,?,?,?,?)",
                               arguments: [object,ref.domain.rawValue,ref.id,ref.fingerprint,sourceIdentifier])
            }
        }
        func record(_ db: Database, domain: MirrorDomain, id: String, row: Row, changed: Bool) throws {
            refs.insert(.init(domain, id, MirrorRef.fingerprint(row)))
            try effects.touch(db, domain: domain, id: id, row: row)
            if changed, let key = domain.transport(row, id: id) { effects.saves[key] = (domain,id) }
        }
    }

    private final class MirrorEffects {
        var saves: [CloudTransportRows.Key: (MirrorDomain, String)] = [:]
        var deletes: [CloudTransportRows.Key: String] = [:]
        private var fixedFallbacks: [CloudTransportRows.Key: (MirrorDomain, String)] = [:]
        var values = Set<String>(), positions = Set<String>(), annotations: [String: Set<String>] = [:]
        var history = ReadingHistoryRows.Changed()

        static func replaceLinks(_ db: Database, tracking: MirrorTracking) throws {
            try unlink(db, object: tracking.object, removingEvidence: true, keeping: tracking.refs, effects: tracking.effects)
            try tracking.persistLinks(db)
        }

        static func unlink(_ db: Database, object: String, removingEvidence: Bool, keeping: Set<MirrorRef> = [],
                           effects: MirrorEffects) throws {
            let refs = try Row.fetchAll(db, sql: "SELECT * FROM usr.legacy_mirror_link WHERE object_id=?",
                                        arguments: [object]).map { try MirrorRef(row: $0) }
            try db.execute(sql: "DELETE FROM usr.legacy_mirror_link WHERE object_id=?", arguments: [object])
            guard removingEvidence else { return }
            for ref in refs where !keeping.contains(ref) {
                guard let fingerprint = ref.fingerprint,
                      let row = try ref.domain.row(db,ref.id), MirrorRef.fingerprint(row) == fingerprint,
                      try Bool.fetchOne(db, sql: """
                          SELECT NOT EXISTS(SELECT 1 FROM usr.legacy_mirror_link WHERE domain=? AND record_id=? AND fingerprint=?)
                          """, arguments: [ref.domain.rawValue,ref.id,fingerprint]) == true else { continue }
                try effects.touch(db, domain: ref.domain, id: ref.id, row: row)
                if ref.domain == .asset {
                    try UserValueRows.removeUnreferencedCover(db, id: ref.id)
                    continue
                }
                if let family = ref.domain.fixedFamily(row) {
                    effects.fixedFallbacks[FixedValueCloudRows.key(family, id: ref.id)] = (ref.domain,ref.id)
                }
                if let key = ref.domain.transport(row, id: ref.id),
                   !row.hasColumn("book_key") || (row["book_key"] as String?).map({ (try? parseSha256(value: $0)) != nil }) != false {
                    effects.saves[key] = nil
                    effects.deletes[key] = ref.id
                }
                try db.execute(sql: "DELETE FROM usr.\(ref.domain.rawValue) WHERE " + ref.domain.filter, arguments: [ref.id])
            }
        }

        /// The relational slot only stores its current winner. Retain exact
        /// source IDs even for losing old objects and consult only that slot
        /// when its matched, mirrored winner is removed.
        func reselectFixedSlots(_ db: Database, context: ModelContext, scope: DataScope) throws {
            for (key, (domain, id)) in fixedFallbacks {
                if try CloudTransportRows.deletionPending(db,key) || FixedValueCloudRows.blocksSave(db,key: key) {
                    deletes[key] = nil
                    continue
                }
                let sources = try Data.fetchAll(db, sql: """
                    SELECT source_identifier FROM usr.legacy_mirror_link
                    WHERE domain=? AND record_id=? ORDER BY object_id
                    """, arguments: [domain.rawValue,id])
                for source in sources {
                    let identifier = try JSONDecoder().decode(PersistentIdentifier.self, from: source)
                    guard let row = try LegacyUserImport.mirrorModel(UserValue.self, context, identifier),
                          let route = try? UserValueRows.Key(row.key), route.table == domain.rawValue,
                          UserValueRows.recordID(logical: route.logical, device: row.device) == id else { continue }
                    let tracking = MirrorTracking(sourceIdentifier: source, effects: self)
                    let importer = Importer(db: db, partition: 0, source: scope.key, coverDirectory: nil, mirror: tracking)
                    try importer.value(row.payload, key: row.key, device: row.device, model: "UserValue")
                    try tracking.persistLinks(db)
                }
                // A remaining candidate contributes a SAVE (when readable),
                // never the provisional DELETE of its previous winner.
                if try domain.row(db,id) != nil { deletes[key] = nil }
            }
        }

        func touch(_ db: Database, domain: MirrorDomain, id: String, row: Row) throws {
            switch domain {
            case .asset: break
            case .position:
                positions.insert(row["book_key"])
            case .annotation:
                annotations[row["book_key"], default: []].insert(row["mark_id"])
            case .clear:
                if let value = try ReadingClearRows.load(db, partition: 0, id: id) {
                    try ReadingClearRows.recordAffected(db,value,partition: 0,changed: &history)
                }
            case .fact: history.facts.insert(id)
            case .opaque:
                if let key = row["logical_key"] as String? { values.insert(key) }
                let type: String = row["source_type"]
                if type == "ReadingFact" || type == "reading_fact" { history.facts.insert(row["record_id"]) }
                if type == "StatisticsClear" {
                    history.clearFacts.formUnion(try ReadingFactSettlement.affectedIDs(db, partition: 0,
                        book: row["book_key"], session: row["session_id"]))
                    history.clearSegments.formUnion(try ReadingSegmentRows.affected(db, partition: 0,
                        book: row["book_key"], session: row["session_id"]))
                }
                if let book = row["book_key"] as String? {
                    if type == "UserPosition" { positions.insert(book) }
                    if type == "AnnotationOperation", let mark = row["mark_id"] as String? {
                        annotations[book, default: []].insert(mark)
                    }
                }
            default:
                values.insert(row["logical_key"])
            }
        }

        func settleAndRelease(_ db: Database, scope: DataScope) throws {
            for key in values.sorted() {
                if let route = try? UserValueRows.Key(key) { try route.settle(db) }
                else if key.hasPrefix("position/"), (try? parseReadingKey(value: String(key.dropFirst(9)))) != nil {
                    positions.insert(String(key.dropFirst(9)))
                }
            }
            for book in positions.sorted() { try ReadingPositionRows.settleCurrent(db, book: book) }
            for (book, marks) in annotations { for mark in marks {
                try AnnotationRows.settleHeads(db, key: book, markID: mark, partition: 0)
            } }
            try history.settle(db, scope: scope)
            // The cursor and outbox never advance outside the same policy
            // check and transaction as the imported business evidence.
            try LegacyBridgePolicy.checkIntake(db)
            for (key, id) in deletes where saves[key] == nil {
                try CloudTransportRows.enqueueDelete(db,key,businessID: id)
            }
            for (_, (domain,id)) in saves {
                guard let row = try domain.row(db,id) else { continue }
                if let book = row.hasColumn("book_key") ? row["book_key"] as String? : nil,
                   (try? parseSha256(value: book)) == nil { continue }
                if let family = domain.fixedFamily(row) {
                    try FixedValueCloudRows.enqueueBridgeSave(db, family, id: id)
                } else if domain == .position || domain == .annotation {
                    let family: CausalCloudRows.Family = domain == .position ? .position : .annotation
                    if let value = try CausalCloudRows.material(db,family,id: id) {
                        try CloudTransportRows.enqueueSave(db,CausalCloudRows.key(family,id: id),businessID: id,digest: value.digest)
                    }
                } else if domain == .clear, let clear = try ReadingClearRows.load(db,partition: 0,id: id) {
                    try ReadingHistoryTransport.enqueueClear(db,id: id,value: clear,scope: scope)
                }
            }
        }
    }

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
        var mirror: MirrorTracking? = nil

        func importMirrorModel(_ context: ModelContext, _ id: PersistentIdentifier) throws -> Bool {
            func read<T: PersistentModel>(_ type: T.Type, _ consume: (T) throws -> Void) throws -> Bool {
                guard let row = try LegacyUserImport.mirrorModel(type,context,id) else { return false }
                try consume(row)
                return true
            }
            switch id.entityName {
            case "UserCover":
                return try read(UserCover.self) { try asset(id: $0.id, bytes: $0.bytes) }
            case "UserValue":
                return try read(UserValue.self) { try value($0.payload, key: $0.key, device: $0.device, model: "UserValue") }
            case "UserPosition":
                return try read(UserPosition.self) {
                    try value($0.payload, key: "position/" + $0.contentKey, device: nil, model: "UserPosition")
                }
            case "AnnotationOperation": return try read(AnnotationOperation.self, annotation)
            case "ReadingFact": return try read(ReadingFact.self, fact)
            case "StatisticsClear": return try read(StatisticsClear.self) { try clear($0.payload) }
            default:
                // Other framework records are not a business change.
                return false
            }
        }

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
            if let mirror, let row = try Row.fetchOne(db, sql: """
                SELECT * FROM usr.quarantined_record
                WHERE partition=? AND source='swiftdata' AND source_id=? AND source_type=? AND record_id=? AND digest=? AND reason=?
                """, arguments: [partition,source,model,identity.id,DataIdentity.sha(data),reason]) {
                try mirror.record(db, domain: .opaque, id: String(row["quarantine_id"] as Int64), row: row, changed: false)
            }
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
            let domain = mirror.flatMap { _ in MirrorDomain(rawValue: table) }
            if let domain {
                let transport: CloudTransportRows.Key?
                switch domain {
                case .position: transport = CausalCloudRows.key(.position, id: identity.id)
                case .annotation: transport = CausalCloudRows.key(.annotation, id: identity.id)
                case .clear: transport = ReadingHistoryTransport.key(.clear, id: identity.id)
                default:
                    transport = identity.key.flatMap(UserSyncJSON.kind).flatMap(FixedValueCloudRows.Family.init)
                        .map { FixedValueCloudRows.key($0,id: identity.id) }
                }
                if let transport, try CloudTransportRows.deletionPending(db,transport) || FixedValueCloudRows.blocksSave(db,key: transport) {
                    return
                }
            }
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
                    if let mirror, let domain, let row = try domain.row(db,identity.id) {
                        try mirror.record(db, domain: domain, id: identity.id, row: row, changed: false)
                    }
                    return
                }
                if let clock {
                    let previous: (Int64, String) = (old["updated_ms"],old["token"])
                    let incoming = (clock.updated,clock.token)
                    if incoming < previous {
                        // Keep the source as a fallback, without claiming
                        // ownership of the newer relational candidate.
                        if let mirror, let domain, domain.fixedFamily(old) != nil {
                            mirror.refs.insert(.init(domain, identity.id, nil))
                        }
                        return
                    }
                    if incoming > previous {
                        try db.execute(sql: "DELETE FROM usr.\(table) " + lookup, arguments: args)
                    } else { throw BadRow(reason: "same-clock-conflict") }
                } else { throw BadRow(reason: "stable-id-conflict") }
            }
            try insert(table, fields: fields)
            for relation in relations { try relation.insert(self, parent: identity.id) }
            if let mirror, let domain, let row = try domain.row(db,identity.id) {
                try mirror.record(db, domain: domain, id: identity.id, row: row, changed: true)
            }
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
                if let mirror, let row = try MirrorDomain.asset.row(db,key) {
                    try mirror.record(db, domain: .asset, id: key, row: row, changed: false)
                    let covers = try Row.fetchAll(db, sql: "SELECT * FROM usr.cover_candidate WHERE partition=0 AND asset_id=?",
                                                  arguments: [key])
                    for cover in covers {
                        let id: String = cover["record_id"]
                        if let transport = MirrorDomain.cover.transport(cover,id: id) {
                            mirror.effects.values.insert(cover["logical_key"])
                            mirror.effects.saves[transport] = (.cover,id)
                        }
                    }
                }
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
                let existing = mirror == nil ? nil : try MirrorDomain.fact.row(db,identity.id)
                let origin = ReadingFactSettlement.Origin(source: "swiftdata", id: mirror?.object ?? row.id)
                let changed = try ReadingFactSettlement.ingest(db, value, book: row.contentKey, partition: partition, scope: source,
                                                                origin: origin)
                if let mirror {
                    mirror.effects.history.facts.insert(identity.id)
                    // A changed fact with an existing ID was isolated; it
                    // does not acquire ownership of the other payload.
                    if (existing == nil || !changed), let written = try MirrorDomain.fact.row(db,identity.id),
                       written["book_key"] as String == DataIdentity.canonical(row.contentKey) {
                        try mirror.record(db, domain: .fact, id: identity.id, row: written, changed: false)
                    }
                    for isolated in try Row.fetchAll(db, sql: """
                        SELECT * FROM usr.quarantined_record WHERE partition=0 AND source='swiftdata' AND source_id=?
                          AND source_type='reading_fact' AND record_id=?
                        """, arguments: [mirror.object,identity.id]) {
                        try mirror.record(db, domain: .opaque, id: String(isolated["quarantine_id"] as Int64), row: isolated, changed: false)
                    }
                }
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
