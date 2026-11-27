import Foundation
import MoonreadCoreBindings
import MoonreadDataTypes

extension ReaderIndex {
    public func sourceDecodings() throws -> SourceDecodingSnapshot {
        try session.readUsers(lease) { try UserValueRows.sourceDecodings($0) }
    }

    public func saveSourceDecoding(rawSHA: String, selection: String, device: String, now: () -> Int64) throws {
        let sha = try parseSha256(value: rawSHA), canonical = try normalizeSourceDecoding(decoding: selection)
        let value = try UserSyncJSON.encode(SourceDecodingValue(decoding: canonical))
        try session.writeUsers(lease) {
            try UserValueRows.put($0, key: .init("source-decoding/" + sha), value: value, device: device, now: now(), scope: lease.scope)
        }
    }

    public func mergeSourceDecodingEpoch(rawSHA: String, decoding: String) throws {
        try Task.checkCancellation()
        try session.writeUsers(lease) { db in
            // A choice with a raw identity verified by the released index is
            // legacy seed data, never a later local edit.
            guard try UpgradeOrigins.phase(db) != nil, try !ReadingCloudInitialization.isRecovering(db) else { return }
            let input = try sourceDecodingEpoch(rawSHA: rawSHA, decoding: decoding)
            let key = try UserValueRows.Key(input.key)
            let device = "source-decoding-v23"
            guard try UserValueRows.merge(db, key: key, head: input.value, device: device) else { return }
            let id = UserValueRows.recordID(logical: key.logical, device: device)
            // The same released raw SHA and normalized encoding keep their
            // seed identity if interrupted between usr commit and index cleanup.
            let batch = DataIdentity.id("legacy-index-v23-decoding", [input.value.token])
            try UpgradeOrigins.record(db, .init(partition: 0, domain: .decoding, id: id), as: .seed(batch: batch))
        }
    }
}

public func sourceDecodingEpoch(rawSHA: String, decoding: String) throws -> (key: String, value: StoredValue) {
    try Task.checkCancellation()
    let sha = try parseSha256(value: rawSHA), canonical = try normalizeSourceDecoding(decoding: decoding)
    let value = try UserSyncJSON.encode(SourceDecodingValue(decoding: canonical))
    return ("source-decoding/" + sha, .init(updated: 0, token: "source-decoding-v23/" + sha + "/" + canonical, value: value))
}
