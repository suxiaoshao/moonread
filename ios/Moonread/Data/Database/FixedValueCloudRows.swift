import Foundation
import GRDB

/// Transport for the released per-device value identities. Position tokens,
/// annotation operations and reading history have their own identities.
enum FixedValueCloudRows {
    enum Family: String, CaseIterable, Sendable {
        case author = "MetadataAuthor", synopsis = "MetadataSynopsis", status = "MetadataStatus"
        case tag = "MetadataTag", cover = "BookCover", opened = "BookOpened", chapter = "ChapterOverride"
        case decoding = "SourceDecoding", palette = "ThemePalette", shelf = "ShelfReference"

        init?(_ kind: UserSyncJSON.ValueKind) {
            switch kind {
            case .author: self = .author
            case .synopsis: self = .synopsis
            case .status: self = .status
            case .tag: self = .tag
            case .cover: self = .cover
            case .opened: self = .opened
            case .chapter: self = .chapter
            case .sourceDecoding: self = .decoding
            case .palette: self = .palette
            case .shelfReference: self = .shelf
            case .position: return nil
            }
        }

        var table: String {
            switch self {
            case .author, .synopsis, .status: "metadata_text_candidate"
            case .tag: "tag_candidate"
            case .cover: "cover_candidate"
            case .opened: "opened_candidate"
            case .chapter: "chapter_override_candidate"
            case .decoding: "source_decoding_candidate"
            case .palette: "palette_candidate"
            case .shelf: "shelf_reference_candidate"
            }
        }

        var predicate: String {
            switch self {
            case .author: " AND field='author'"
            case .synopsis: " AND field='synopsis'"
            case .status: " AND field='status'"
            default: ""
            }
        }

        var bookOwned: Bool {
            switch self {
            case .decoding, .palette, .shelf: false
            default: true
            }
        }

        func isCreationValue(_ row: Row) -> Bool {
            switch self {
            case .author, .synopsis, .status: !(row["value_text"] as String).isEmpty
            case .tag, .palette: !(row["is_deleted"] as Bool)
            case .cover: !(row["is_empty"] as Bool)
            case .chapter: !(row["is_retracted"] as Bool)
            case .opened, .decoding, .shelf: true
            }
        }
    }

    private static let receiptPrefix = "x2-delete-acked:"
    private static let waitingPrefix = "x2-await-delete:"
    private static let freshPrefix = "x2-unpublished:"
    private static let verifyStatus = CloudTransportRows.missingSaveStatus

    enum DeleteDecision: Equatable, Sendable { case removed, keptLocalCreation, verify, ignored }

    struct Remote: Sendable {
        let family: Family
        let name, id, logical, device, payload: String
        let attachment, systemFields: Data?
    }

    struct Prepared: Sendable {
        let attempt: CloudTransportRows.Attempt
        let logical, device, payload: String?
        let systemFields: Data?
        let attachment: Data?
    }

    private struct Material {
        let logical, device, payload: String
        let cover: UserValueRows.Cover?
        let creationValue: Bool
        var digest: String { DataIdentity.sha(Data(payload.utf8)) }
    }

    static func key(_ family: Family, id: String) -> CloudTransportRows.Key {
        .init(zone: ReadingHistoryTransport.zone, type: family.rawValue, name: family.rawValue + "-" + id)
    }

    static func applyRemote(_ db: Database, _ value: Remote, verifying: Bool = false) throws {
        let key = try UserValueRows.Key(value.logical)
        let transport = self.key(value.family, id: value.id)
        guard Family(key.kind) == value.family, key.logical == value.logical,
              transport.name == value.name, UserValueRows.recordID(logical: key.logical, device: value.device) == value.id else {
            throw UserSyncCompatibilityError()
        }
        if let book = key.book, case .pending = try parseReadingKey(value: book) { throw UserSyncCompatibilityError() }
        let head = try UserSyncJSON.storedValue(value.payload, key: key.logical)
        if try CloudTransportRows.deletionPending(db, transport) { return }
        if !verifying, try blocksSave(db, key: transport) { return }
        if value.family == .cover {
            if let prior = try missingCoverBarrier(db, name: value.name, id: value.id, logical: key.logical),
               blocks(head, behind: prior) { return }
            if let cover = try JSONDecoder().decode(UserValueRows.Cover?.self, from: Data(head.value.utf8)) {
                if let bytes = value.attachment { try UserValueRows.attach(db, id: cover.id, sha: cover.sha256, bytes: bytes, publishRepair: false) }
                else { throw ReadingDataError.missingAsset }
            }
        }
        try removeCloudIsolation(db, family: value.family, name: value.name, id: value.id)
        if try !UserValueRows.merge(db, key: key, head: head, device: value.device, preserveSiblingIdentity: true) {
            try key.settle(db)
        }
        try CloudTransportRows.recordPresent(db, transport, businessID: value.id, systemFields: value.systemFields)
        if let pending = try CloudTransportRows.pending(db, transport), case .save(let digest) = pending.intent,
           try currentDigest(db, value.family, id: value.id) != digest {
            try CloudTransportRows.withdrawSave(db, transport)
        }
    }

    private static func removeCloudIsolation(_ db: Database, family: Family, name: String, id: String) throws {
        try db.execute(sql: """
            DELETE FROM usr.quarantined_record WHERE partition=0 AND source='cloud' AND source_type=? AND source_id=?
              AND (record_id=? OR (record_id=source_id AND raw_format IN ('ck-record-archive','ck-record-summary')))
            """, arguments: [family.rawValue,name,id])
    }

    private static func material(_ db: Database, _ family: Family, id: String) throws -> Material? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT * FROM usr.\(family.table)
            WHERE partition=0 AND record_id=? AND schema_version=1\(family.predicate)
            """, arguments: [id]),
              let kind = UserSyncJSON.kind(row["logical_key"] as String), Family(kind) == family else { return nil }
        do {
            let (wire, cover) = try UserValueRows.encodedCandidate(db, row: row, forSync: true)
            return .init(logical: wire.key, device: wire.device, payload: wire.payload,
                         cover: cover, creationValue: family.isCreationValue(row))
        } catch ReadingDataError.missingAsset { return nil }
          catch ReadingDataError.updateRequired { return nil }
    }

    static func currentDigest(_ db: Database, _ family: Family, id: String) throws -> String? {
        if family == .cover, let missing = try missingCoverOffer(db, id: id) {
            return missing.digest
        }
        return try material(db, family, id: id)?.digest
    }

    private struct MissingCover: Codable {
        let missingCoverVersion: Int
        let reference: String
    }

    // Only records that previously passed the explicit missing-cover
    // receiver get this format. SDK capture errors use other formats.
    static let retainedMissingCoverSQL = """
        source='cloud' AND source_type='BookCover' AND raw_format='missing-cover-v1'
          AND schema_version=1 AND reason='unavailable-attachment' AND completeness='incomplete'
        """

    private static func missingCoverBarrier(_ db: Database, name: String, id: String, logical: String) throws -> StoredValue? {
        guard let raw = try Data.fetchOne(db, sql: """
            SELECT raw_bytes FROM usr.quarantined_record WHERE partition=0 AND source='cloud' AND source_id=?
              AND source_type=? AND record_id=? AND raw_format='missing-cover-v1'
            """, arguments: [name,Family.cover.rawValue,id]) else { return nil }
        return try UserSyncJSON.storedValue(String(decoding: raw, as: UTF8.self), key: logical)
    }

    private static func blocks(_ incoming: StoredValue, behind baseline: StoredValue) -> Bool {
        (incoming.updated,incoming.token) < (baseline.updated,baseline.token)
            || ((incoming.updated,incoming.token) == (baseline.updated,baseline.token) && incoming.value != baseline.value)
    }

    /// Only the relational missing-asset state from durable intake is a
    /// source of absence. An SDK capture with no asset is never this state.
    private static func missingCoverOffer(_ db: Database, id: String) throws -> Material? {
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.cover_candidate c JOIN usr.cover_asset a ON a.asset_id=c.asset_id
              WHERE c.partition=0 AND c.record_id=? AND c.schema_version=1 AND NOT c.is_empty
                AND a.availability='missing' AND a.legacy_cover_id IS NOT NULL AND a.expected_sha=c.sha256)
            """, arguments: [id]) == true,
           let value = try material(db, .cover, id: id), value.cover != nil, try readable(db, value) {
            return try wrappedMissingCover(value.payload, logical: value.logical, device: value.device)
        }
        // A W2 winner may only have the missing evidence originally sent
        // by a peer, with no typed candidate or local legacy asset row.
        let rows = try Row.fetchAll(db, sql: """
            SELECT raw_bytes,digest,logical_key,device_id,book_key FROM usr.quarantined_record
            WHERE partition=0 AND record_id=? AND source_id=? AND \(retainedMissingCoverSQL)
            """, arguments: [id,key(.cover, id: id).name])
        guard rows.count == 1, let row = rows.first,
              let logical = row["logical_key"] as String?, let device = row["device_id"] as String?,
              let book = row["book_key"] as String?, let userKey = try? UserValueRows.Key(logical),
              userKey.kind == .cover, userKey.logical == logical, userKey.book == book,
              (try? parseSha256(value: book)) == book, UserValueRows.recordID(logical: logical, device: device) == id,
              let raw = row["raw_bytes"] as Data?, DataIdentity.sha(raw) == (row["digest"] as String),
              let reference = String(data: raw, encoding: .utf8),
              let head = try? UserSyncJSON.storedValue(reference, key: logical),
              let cover = try? JSONDecoder().decode(UserValueRows.Cover?.self, from: Data(head.value.utf8)),
              (try? parseSha256(value: cover.sha256)) == cover.sha256 else { return nil }
        return try wrappedMissingCover(reference, logical: logical, device: device)
    }

    private static func wrappedMissingCover(_ reference: String, logical: String, device: String) throws -> Material {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try String(decoding: encoder.encode(MissingCover(missingCoverVersion: 1, reference: reference)), as: UTF8.self)
        return .init(logical: logical, device: device, payload: payload, cover: nil, creationValue: false)
    }

    static func receiveMissingCover(_ db: Database, _ record: CloudInboxRows.Record,
                                    verifying: Bool) throws -> Bool {
        guard record.type == Family.cover.rawValue, let payload = record.payload,
              let missing = try? JSONDecoder().decode(MissingCover.self, from: Data(payload.utf8))
        else { return false }
        guard missing.missingCoverVersion == 1, record.assets.isEmpty,
              let id = record.id, let logical = record.logical, let device = record.device,
              let userKey = try? UserValueRows.Key(logical), userKey.kind == .cover,
              let book = userKey.book, (try? parseSha256(value: book)) == book,
              logical == userKey.logical, record.name == key(.cover, id: id).name,
              id == UserValueRows.recordID(logical: logical, device: device)
        else { throw UserSyncCompatibilityError() }
        let head = try UserSyncJSON.storedValue(missing.reference, key: logical)
        guard let cover = try JSONDecoder().decode(UserValueRows.Cover?.self, from: Data(head.value.utf8)),
              (try? parseSha256(value: cover.sha256)) == cover.sha256 else { throw UserSyncCompatibilityError() }
        let route = key(.cover, id: id)
        if try CloudTransportRows.deletionPending(db, route) { return true }
        if !verifying, try blocksSave(db, key: route) { return true }
        if let prior = try missingCoverBarrier(db, name: record.name, id: id, logical: logical),
           blocks(head, behind: prior) { return true }
        // The sender already has this incomplete candidate in its durable
        // asset table. Don't turn its own echo into a competing barrier.
        if let local = try material(db, .cover, id: id) {
            let status = try String.fetchOne(db, sql: """
               SELECT availability FROM usr.cover_asset WHERE asset_id=?
               """, arguments: [UserValueRows.assetID(cover.id, sha: cover.sha256)])
            let previous = try UserSyncJSON.storedValue(local.payload, key: logical)
            if (local.payload == missing.reference && (status == "missing" || status == "available"))
                || blocks(head, behind: previous) {
                try CloudTransportRows.recordPresent(db, route, businessID: id, systemFields: record.systemFields)
                return true
            }
        }
        try removeCloudIsolation(db, family: .cover, name: record.name, id: id)
        let raw = Data(missing.reference.utf8)
        try db.execute(sql: """
            INSERT INTO usr.quarantined_record(partition,source,source_id,source_type,record_id,book_key,logical_key,
                device_id,schema_version,raw_format,raw_bytes,digest,reason,completeness)
            VALUES(0,'cloud',?,?,?,?,?,?,1,'missing-cover-v1',?,?,'unavailable-attachment','incomplete')
            """, arguments: [record.name,Family.cover.rawValue,id,book,logical,device,raw,DataIdentity.sha(raw)])
        try userKey.settle(db)
        try CloudTransportRows.recordPresent(db, route, businessID: id, systemFields: record.systemFields)
        return true
    }

    static func initialCoverage(_ db: Database, _ family: Family, id: String) throws -> ReadingCloudInitialization.Coverage {
        if family == .cover, let missing = try missingCoverOffer(db, id: id) {
            return .save(missing.digest)
        }
        if family == .cover, try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.cover_candidate c LEFT JOIN usr.cover_asset a ON a.asset_id=c.asset_id
              WHERE c.partition=0 AND c.record_id=? AND c.schema_version=1 AND NOT c.is_empty
                AND (a.legacy_cover_id IS NULL OR a.availability<>'available'))
            """, arguments: [id]) == true { return .blocked(.missingAttachment) }
        guard let value = try material(db, family, id: id), try readable(db, value)
        else { return .blocked(.unrepresented) }
        if let cover = value.cover {
            guard let bytes = try matchingCoverBytes(db, cover) else { return .blocked(.missingAttachment) }
            guard bytes.count <= ReadingSyncEngineAdapter.attachmentLimit else { return .blocked(.unrepresented) }
        }
        return .save(value.digest)
    }

    private static func matchingCoverBytes(_ db: Database, _ cover: UserValueRows.Cover) throws -> Data? {
        guard let bytes = try UserValueRows.coverBytes(db, id: cover.id, sha: cover.sha256),
              DataIdentity.sha(bytes) == cover.sha256 else { return nil }
        return bytes
    }

    static func enqueueLocalEdit(_ db: Database, _ family: Family, id: String, previousDigest: String?) throws {
        guard let value = try material(db, family, id: id) else { return }
        let key = key(family, id: id), status = try CloudTransportRows.recordStatus(db, key)
        let digest = value.digest
        if let pending = try CloudTransportRows.pending(db, key), pending.intent == .delete {
            let prefix = waitingPrefix + String(pending.generation) + ":"
            if (previousDigest == nil && value.creationValue) || previousDigest.map({ status == prefix + $0 }) == true {
                try setControl(db, key, id, prefix + digest)
            }
            return
        }
        let fence = if previousDigest == nil && value.creationValue { parseFence(status, prefix: receiptPrefix) }
            else if let previousDigest, let status, status.hasSuffix(":" + previousDigest) { parseFence(status, prefix: freshPrefix) }
            else { nil as Int64? }
        try CloudTransportRows.enqueueSave(db, key, businessID: id, digest: digest)
        if let fence {
            try setControl(db, key, id, freshPrefix + String(fence) + ":" + digest)
        } else if status?.hasPrefix(freshPrefix) == true {
            // An intake that replaced the candidate cannot inherit explicit
            // recreation evidence. Keep this ID closed until verified.
            try setControl(db, key, id, verifyStatus)
        }
    }

    static func queueBookDeletion(_ db: Database, book: String) throws {
        for family in Family.allCases where family.bookOwned {
            let ids = try String.fetchAll(db, sql: """
                SELECT record_id FROM usr.\(family.table) WHERE partition=0 AND book_key=?\(family.predicate)
                """, arguments: [book])
            for id in ids { try CloudTransportRows.enqueueBookDelete(db, key(family, id: id), businessID: id) }
        }
        // A retained explicit missing cover has no candidate row.
        let missing = try String.fetchAll(db, sql: """
            SELECT DISTINCT record_id FROM usr.quarantined_record
            WHERE partition=0 AND book_key=? AND \(retainedMissingCoverSQL)
            """, arguments: [book])
        for id in missing { try CloudTransportRows.enqueueBookDelete(db, key(.cover, id: id), businessID: id) }
    }

    static func didConfirmDeletion(_ db: Database, _ family: Family, sent: CloudTransportRows.Attempt) throws {
        let status = try CloudTransportRows.recordStatus(db, sent.key)
        // A fetch that started before this ACK cannot close its echo window.
        let generation = try CloudTransportRows.allocateGeneration(db)
        if let value = try material(db, family, id: sent.businessID),
           status == waitingPrefix + String(sent.generation) + ":" + value.digest {
            try CloudTransportRows.enqueueSave(db, sent.key, businessID: sent.businessID, digest: value.digest)
            try setControl(db, sent.key, sent.businessID, freshPrefix + String(generation) + ":" + value.digest)
        } else {
            try setControl(db, sent.key, sent.businessID, receiptPrefix + String(generation))
        }
    }

    static func expireReceipts(_ db: Database, through generation: Int64) throws {
        let owned = Family.allCases.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: """
            SELECT record_type,record_name,server_state FROM usr.cloud_record_state
            WHERE zone=? AND record_type IN (\(owned)) AND (server_state LIKE 'x2-delete-acked:%' OR server_state LIKE 'x2-unpublished:%')
            """, arguments: StatementArguments([ReadingHistoryTransport.zone] + Family.allCases.map(\.rawValue)))
        for row in rows {
            let status: String = row["server_state"]
            guard let fence = parseFence(status, prefix: receiptPrefix) ?? parseFence(status, prefix: freshPrefix),
                  fence <= generation else { continue }
            try CloudTransportRows.forgetServerRecord(db, .init(zone: ReadingHistoryTransport.zone, type: row["record_type"], name: row["record_name"]))
        }
    }

    private static func parseFence(_ status: String?, prefix: String) -> Int64? {
        guard let status, status.hasPrefix(prefix) else { return nil }
        return status.dropFirst(prefix.count).split(separator: ":", maxSplits: 1).first.flatMap { Int64($0) }
    }

    /// A SAVE for a replacement cannot be offered or ACKed before a committed
    /// own-zone catch-up covers its DELETE. The engine cannot reorder that
    /// replacement's SAVE ACK ahead of the old echo.
    static func blocksSave(_ db: Database, key: CloudTransportRows.Key) throws -> Bool {
        let status = try CloudTransportRows.recordStatus(db, key)
        return status == verifyStatus || status?.hasPrefix(freshPrefix) == true ||
               status?.hasPrefix(receiptPrefix) == true || status?.hasPrefix(waitingPrefix) == true
    }

    static func prepare(_ db: Database, _ family: Family, id: String) throws -> Prepared? {
        let key = key(family, id: id)
        guard let attempt = try CloudTransportRows.pending(db, key), attempt.businessID == id else { return nil }
        let prepared: Prepared
        switch attempt.intent {
        case .delete:
            prepared = .init(attempt: attempt, logical: nil, device: nil, payload: nil, systemFields: nil, attachment: nil)
        case .save(let digest):
            if family == .cover, try !blocksSave(db, key: key), let missing = try missingCoverOffer(db, id: id),
               missing.digest == digest {
                return .init(attempt: attempt, logical: missing.logical, device: missing.device, payload: missing.payload,
                             systemFields: try CloudTransportRows.systemFields(db, key), attachment: nil)
            }
            guard try !blocksSave(db, key: key), let value = try material(db, family, id: id), value.digest == digest,
                  try readable(db, value) else { return nil }
            var attachment: Data?
            if let cover = value.cover {
                guard let bytes = try matchingCoverBytes(db, cover) else { return nil }
                attachment = bytes
            }
            prepared = .init(attempt: attempt, logical: value.logical, device: value.device, payload: value.payload,
                             systemFields: try CloudTransportRows.systemFields(db, key), attachment: attachment)
        }
        return prepared
    }

    static func applyDeletion(_ db: Database, _ family: Family, name: String, verifiedAbsent: Bool = false) throws -> DeleteDecision {
        guard name.hasPrefix(family.rawValue + "-") else { return .ignored }
        let id = String(name.dropFirst(family.rawValue.count + 1))
        guard (try? parseSha256(value: id)) == id else { return .ignored }
        let key = key(family, id: id)
        let pending = try CloudTransportRows.pending(db, key)
        let status = try CloudTransportRows.recordStatus(db, key)
        let digest = try currentDigest(db, family, id: id)
        if !verifiedAbsent && status == verifyStatus { return .verify }
        if !verifiedAbsent && digest == nil && (status?.hasPrefix(freshPrefix) == true || status?.hasPrefix(waitingPrefix) == true) {
            try setControl(db, key, id, verifyStatus)
            return .verify
        }
        if !verifiedAbsent, let pending, let digest {
            if pending.intent == .delete, status == waitingPrefix + String(pending.generation) + ":" + digest {
                return .keptLocalCreation
            }
            if case .save = pending.intent, status != "present", status?.hasPrefix(receiptPrefix) != true {
                if pending.intent == .save(digest: digest), status?.hasPrefix(freshPrefix) == true,
                   status?.hasSuffix(":" + digest) == true { return .keptLocalCreation }
                try setControl(db, key, id, verifyStatus)
                return .verify
            }
        }
        if status?.hasPrefix(receiptPrefix) == true, digest == nil { return .ignored }

        var logical = Set(try String.fetchAll(db, sql: """
            SELECT logical_key FROM usr.\(family.table) WHERE partition=0 AND record_id=?\(family.predicate)
            UNION SELECT logical_key FROM usr.quarantined_record WHERE partition=0 AND source='cloud'
              AND source_type=? AND source_id=? AND record_id=? AND logical_key IS NOT NULL
            """, arguments: [id,family.rawValue,name,id]))
        let asset = family == .cover ? try String.fetchOne(db, sql: "SELECT asset_id FROM usr.cover_candidate WHERE partition=0 AND record_id=?",
                                                            arguments: [id]) : nil
        try db.execute(sql: "DELETE FROM usr.\(family.table) WHERE partition=0 AND record_id=?\(family.predicate)", arguments: [id])
        try removeCloudIsolation(db, family: family, name: name, id: id)
        try CloudTransportRows.applyPeerDeletion(db, key)
        while let name = logical.popFirst() {
            if let kind = UserSyncJSON.kind(name), Family(kind) == family, let key = try? UserValueRows.Key(name) { try key.settle(db) }
        }
        if let asset, try UserValueRows.canReclaimCoverAssets(db) { try UserValueRows.removeUnreferencedCover(db, id: asset) }
        return .removed
    }

    static func rebuildOutbox(_ db: Database) throws {
        for family in Family.allCases {
            let ids = try String.fetchAll(db, sql: """
                SELECT record_id FROM usr.\(family.table) WHERE partition=0 AND schema_version=1\(family.predicate)
                """)
            for id in ids {
                guard let value = try material(db, family, id: id), try readable(db, value) else { continue }
                try CloudTransportRows.enqueueSave(db, key(family, id: id), businessID: id, digest: value.digest)
            }
        }
    }

    private static func readable(_ db: Database, _ value: Material) throws -> Bool {
        do {
            let key = try UserValueRows.Key(value.logical)
            if key.kind == .opened { try ReadingPositionRows.requireFormalOpenedReadable(db, book: key.member) }
            else { try UserValueRows.requireReadable(db, key) }
            return true
        }
        catch is UserSyncCompatibilityError { return false }
    }

    private static func setControl(_ db: Database, _ key: CloudTransportRows.Key, _ id: String, _ status: String) throws {
        try CloudTransportRows.setFixedValueControl(db, key, businessID: id, status: status)
    }
}
