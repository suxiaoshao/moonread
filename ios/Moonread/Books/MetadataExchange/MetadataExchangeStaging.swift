import MoonreadCoreBindings
import Foundation
import GRDB

/// Rust calls each stream synchronously. Swift owns the handle and its lifetime.
final class MetadataFileInput: MetadataInput, @unchecked Sendable {
    private let handle: FileHandle
    private let size: UInt64

    init(_ url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }

    func length() -> UInt64 { size }

    func read(offset: UInt64, count: UInt32) throws -> Data {
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: Int(count)) ?? Data()
    }
}

final class MetadataFileOutput: MetadataOutput, @unchecked Sendable {
    private let handle: FileHandle

    init(_ url: URL) throws {
        try Data().write(to: url, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: url)
    }

    func write(offset: UInt64, bytes: Data) throws {
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: bytes)
    }

    func finish() throws {
        try handle.synchronize()
        try handle.close()
    }
}

private final class MetadataArchiveDirectory: MetadataArchiveInput, MetadataArchiveOutput {
    let root: URL

    init(root: URL) { self.root = root }

    func openMember(name: String) throws -> any MetadataInput {
        try MetadataFileInput(root.appendingPathComponent(name))
    }

    func createMember(name: String) throws -> any MetadataOutput {
        let target = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try MetadataFileOutput(target)
    }
}

func writeMetadataArchive(stagingDirectory: URL, destination: URL) throws {
    let manager = FileManager.default
    let root = stagingDirectory.resolvingSymlinksInPath()
    let fileType: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    func members(in directory: URL, prefix: String, into names: inout [String]) throws {
        for file in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(fileType)) {
            let values = try file.resourceValues(forKeys: fileType)
            let name = prefix + file.lastPathComponent
            guard values.isSymbolicLink != true else { throw ReaderError.MetadataExchange(message: "暂存中含链接") }
            if values.isDirectory == true {
                try members(in: file, prefix: name + "/", into: &names)
            } else {
                guard values.isRegularFile == true else { throw ReaderError.MetadataExchange(message: "暂存中含非普通文件") }
                names.append(name)
            }
        }
    }
    var names: [String] = []
    try members(in: root, prefix: "", into: &names)
    let output = try MetadataFileOutput(destination)
    do {
        try encodeMetadataArchive(members: names, source: MetadataArchiveDirectory(root: root), destination: output)
        try output.finish()
    } catch {
        try? manager.removeItem(at: destination)
        throw error
    }
}

/// Preserves the JSONL fields shared by the disposable stage and exported diagnostics.
struct MetadataDiagnosticPayload: Codable {
    let sourceLine: UInt64?
    let recordIndex: UInt64?
    let code: String
    let field: String?
    let contentSha256: String?
    let message: String

    init(_ value: MetadataDiagnostic) {
        sourceLine = value.sourceLine
        recordIndex = value.recordIndex
        code = value.code
        field = value.field
        contentSha256 = value.contentSha256
        message = value.message
    }

    var value: MetadataDiagnostic {
        .init(sourceLine: sourceLine, recordIndex: recordIndex, code: code,
              field: field, contentSha256: contentSha256, message: message)
    }
}

final class MetadataImportDocument: Sendable {
    let root: URL
    private let database: DatabaseQueue

    init(input: URL, stagingRoot: URL) throws {
        let root = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let database = try DatabaseQueue(path: root.appendingPathComponent("inspection.sqlite").path)
            try database.write { db in
                try db.execute(sql: """
                    CREATE TABLE records(
                        id INTEGER PRIMARY KEY, sha TEXT NOT NULL, payload TEXT NOT NULL,
                        source_line INTEGER, record_index INTEGER NOT NULL, duplicates INTEGER NOT NULL,
                        UNIQUE(sha, payload)
                    );
                    CREATE INDEX records_sha ON records(sha, id);
                    CREATE TABLE diagnostics(id INTEGER PRIMARY KEY, payload BLOB NOT NULL);
                    """)
                let sink = try StagingSink(db: db, root: root)
                let source = try MetadataFileInput(input)
                let manifest: any MetadataInput
                let format: MetadataFormat
                var extracted: URL?
                switch input.pathExtension.lowercased() {
                case "json":
                    manifest = source
                    format = .json
                case "jsonl":
                    manifest = source
                    format = .jsonl
                case "zip", "moonread-metadata":
                    let item = try unpackMetadataArchive(input: source, destination: MetadataArchiveDirectory(root: root), sink: sink)
                    let url = root.appendingPathComponent(item.name)
                    manifest = try MetadataFileInput(url)
                    format = item.format
                    extracted = url
                default:
                    throw ReaderError.MetadataExchange(message: "请选择JSON、JSONL或moonread-metadata文件")
                }
                try parseMetadataManifest(input: manifest, format: format, packaged: extracted != nil, sink: sink)
                if let extracted { try manager.removeItem(at: extracted) }
            }
            self.database = database
            self.root = root
        } catch {
            try? manager.removeItem(at: root)
            throw error
        }
    }

    deinit {
        try? database.close()
        try? FileManager.default.removeItem(at: root)
    }

    private final class StagingSink: MetadataStagingSink, @unchecked Sendable {
        private let root: URL
        private let records: Statement
        private let diagnostics: Statement
        private let encoder = JSONEncoder()

        // The parser invokes the sink within this synchronous GRDB writer transaction.
        init(db: Database, root: URL) throws {
            self.root = root
            records = try db.makeStatement(sql: """
                INSERT INTO records(sha, payload, source_line, record_index, duplicates) VALUES (?, ?, ?, ?, 1)
                ON CONFLICT(sha, payload) DO UPDATE SET duplicates = duplicates + 1
                """)
            diagnostics = try db.makeStatement(sql: "INSERT INTO diagnostics(payload) VALUES (?)")
            encoder.keyEncodingStrategy = .convertToSnakeCase
        }

        func record(sha: String, payload: String, sourceLine: UInt64?, recordIndex: UInt64) throws {
            try records.execute(arguments: [sha, payload, sourceLine, recordIndex])
        }

        func diagnostic(diagnostic: MetadataDiagnostic) throws {
            try diagnostics.execute(arguments: [encoder.encode(MetadataDiagnosticPayload(diagnostic))])
        }

        func hasCover(name: String) -> Bool {
            (try? root.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    func summary() throws -> MetadataDocumentSummary {
        try database.read { db in
            let records = try Row.fetchOne(db, sql: "SELECT count(DISTINCT sha), count(*) FROM records")!
            let diagnostics = try UInt64.fetchOne(db, sql: "SELECT count(*) FROM diagnostics")!
            return .init(books: records[0], variants: records[1], diagnostics: diagnostics)
        }
    }

    func bookKeys(after: String?, count: UInt32) throws -> MetadataKeysPage {
        guard count > 0 else { throw ReaderError.MetadataExchange(message: "分页大小无效") }
        return try database.read { db in
            let keys = try String.fetchAll(db, sql: "SELECT DISTINCT sha FROM records WHERE sha > ? ORDER BY sha LIMIT ?",
                                           arguments: [after ?? "", Int64(count) + 1])
            return .init(keys: Array(keys.prefix(Int(count))), done: keys.count <= count)
        }
    }

    func records(sha: String?, cursor: UInt64, count: UInt32) throws -> MetadataRecordPage {
        guard count > 0, cursor <= Int64.max else { throw ReaderError.InvalidSettings }
        if let sha { _ = try parseSha256(value: sha) }
        return try database.read { db in
            let select = "SELECT id, payload, source_line, record_index, duplicates FROM records WHERE"
            let page = "id > ? ORDER BY id LIMIT ?"
            let limit = Int64(count) + 1
            let rows = if let sha {
                try Row.fetchAll(db, sql: "\(select) sha = ? AND \(page)", arguments: [sha, cursor, limit])
            } else {
                try Row.fetchAll(db, sql: "\(select) \(page)", arguments: [cursor, limit])
            }
            let values = try rows.prefix(Int(count)).map { row in
                try MetadataRecord(id: row[0], sourceLine: row[2], recordIndex: row[3], duplicates: row[4],
                                   book: decodeStagedMetadataBook(payload: row[1]))
            }
            return .init(records: values, nextCursor: values.last?.id ?? cursor, done: rows.count <= count)
        }
    }

    func diagnostics(cursor: UInt64, count: UInt32) throws -> MetadataDiagnosticsPage {
        guard count > 0, cursor <= Int64.max else { throw ReaderError.InvalidSettings }
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, payload FROM diagnostics WHERE id > ? ORDER BY id LIMIT ?",
                                        arguments: [cursor, Int64(count) + 1])
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let page = rows.prefix(Int(count))
            let values = try page.map { try decoder.decode(MetadataDiagnosticPayload.self, from: $0[1]).value }
            return .init(diagnostics: values, nextCursor: page.last?[0] ?? cursor, done: rows.count <= count)
        }
    }

    func coverURL(_ path: String) throws -> URL {
        try validateMetadataCoverPath(name: path)
        let url = root.appendingPathComponent(path)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ReaderError.MetadataExchange(message: "封面文件缺失")
        }
        return url
    }
}
