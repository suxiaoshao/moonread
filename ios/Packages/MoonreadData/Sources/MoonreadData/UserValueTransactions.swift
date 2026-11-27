import Foundation
import MoonreadCoreBindings

extension ReaderIndex {
    public func correctChapter(bookID id: String, offset: UInt64, title: String, level: UInt32,
                               excluded: Bool, device: String, now: () -> Int64) throws {
        try session.writeUsers(lease) { db in
            let body = try IndexedBookBody.fetch(db, id: id, scope: lease.scope.key)
            guard (try? parseSha256(value: body.sha)) != nil else { throw ReaderError.ImportBusy }
            try ReaderChapterRead.validateChapterCorrection(db, body: body, offset: offset)
            let value = ChapterValue(content_key: body.sha, offset: offset, title: title.trimmingCharacters(in: .whitespaces), level: level, excluded: excluded)
            try UserValueRows.put(db, key: .init("chapter/\(body.sha)/\(offset)"), value: UserSyncJSON.encode(value), device: device, now: now(),
                                  scope: lease.scope)
        }
    }

    public func restoreChapterCorrections(bookID id: String, device: String, now: () -> Int64) throws {
        try session.writeUsers(lease) { db in
            let body = try IndexedBookBody.fetch(db, id: id, scope: lease.scope.key)
            try UserValueRows.retractChapters(db, book: body.sha, device: device, now: now(), scope: lease.scope)
        }
    }

    public func customPalettes() throws -> [ThemePalette] {
        try session.readUsers(lease) { try UserValueRows.palettes($0).filter(\.custom) }
    }

    public func savePalette(id: String, json: String, device: String, now: () -> Int64) throws {
        try session.writeUsers(lease) {
            try UserValueRows.put($0, key: .init("palette/" + id), value: json, device: device, now: now(), scope: lease.scope)
        }
    }

    public func commitBookMetadata(_ writes: [UserValueRows.MetadataWrite], admission: DataSessionLease? = nil, device: String, now: () -> Int64) throws -> [UserValueRows.CoverCopy] {
        let token = admission ?? lease
        return try session.writeUsers(token) { try UserValueRows.putMetadata($0, writes, device: device, now: now(), scope: token.scope) }
    }
}
