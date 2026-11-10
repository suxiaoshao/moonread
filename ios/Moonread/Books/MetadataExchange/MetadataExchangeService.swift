import Foundation

extension AppDataService {
    func exportMetadata(shelfID: String?, format: MetadataFormat, progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> MetadataExportResult {
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        try Task.checkCancellation()
        let configuration = userCloudConfigurationRevision
        let query = try await catalogueQuery(shelfID.map { LibraryLocation(shelfID: $0) }, recursive: true)
        let shelves = try shelves(), names = Dictionary(uniqueKeysWithValues: shelves.map { ($0.id, $0.name) })
        let entries: [LibraryEntry]
        if let shelfID { entries = try query.allLibraryBooks(shelfId: shelfID) }
        else { entries = try query.librarySearchCandidates(scope: .all, booksOnly: true).map(\.entry) }
        var grouped: [String: [LibraryEntry]] = [:]
        var skipped: [MetadataSkippedFile] = []
        for entry in entries where !entry.directory {
            try Task.checkCancellation()
            guard let sha = entry.contentSha256, (try? parseSha256(value: sha)) != nil else { skipped.append(.init(id: entry.id, shelf: names[entry.shelfId] ?? "", path: entry.relativePath)); continue }
            grouped[sha, default: []].append(entry)
        }
        await progress(0, grouped.count)
        try Task.checkCancellation()
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("MetadataExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let manifest = stage.appendingPathComponent(format == .json ? "metadata.json" : "metadata.jsonl")
        // Packaging is decided from selected metadata, not by looking at the TXT.
        let store = try await userStore()
        var warning: [String] = [], count = 0
        var metadataSnapshot: [String: BookMetadata] = [:]
        for sha in grouped.keys {
            try Task.checkCancellation()
            try await store.requireMetadataReadable(key: sha)
            metadataSnapshot[sha] = try query.bookDetails(bookId: nil, contentSha: sha).metadata
        }
        let hasCovers = metadataSnapshot.values.contains { $0.cover != nil }
        let writer = try createMetadataWriter(destination: manifest.path, format: format, packaged: hasCovers)
        for sha in grouped.keys.sorted() {
            try Task.checkCancellation()
            let sources = grouped[sha]!
            let metadata = metadataSnapshot[sha]!
            let state: String?
            switch metadata.status { case .unread: state = "unread"; case .reading: state = "reading"; case .finished: state = "finished"; case .paused: state = "paused"; case .other: state = nil; warning.append(String(localized: "有较新版本的阅读状态，未导出该状态", table: "MetadataExchange")) }
            var coverPath: String?
            if let cover = metadata.cover {
                // Missing user assets fail visibly; never export a fallback as a user cover.
                let bytes = try await coverBytes(cover)
                let name = "covers/\(cover.sha256).\(cover.extension)"
                let target = stage.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: target.path) { try bytes.write(to: target, options: .atomic) }
                coverPath = name
            }
            let globalSources = try query.systemReadingSources(contentSha256: sha)
            let first = sources[0]
            let references = sources.map { MetadataFileReference(title: ($0.name as NSString).deletingPathExtension, shelf: names[$0.shelfId] ?? "", path: $0.relativePath) }
            let book = MetadataBook(v: 1, contentSha256: sha,
                reference: .init(title: (first.name as NSString).deletingPathExtension, author: metadata.author.isEmpty ? nil : metadata.author, files: references),
                title: globalSources.count == 1 ? (first.name as NSString).deletingPathExtension : nil,
                author: metadata.author.isEmpty ? nil : metadata.author, tags: metadata.tags,
                description: metadata.synopsis.isEmpty ? nil : metadata.synopsis, cover: coverPath, readingState: state, clear: [], requires: [])
            try writer.append(book: book); count += 1
            await progress(count, grouped.count)
        }
        try writer.finish()
        guard configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        try Task.checkCancellation()
        let file = try LibraryExport { directory in
            if hasCovers {
                try Data("Moonread metadata v1\nFormat: https://suxiaoshao.github.io/moonread/metadata-format/\nSchema: https://suxiaoshao.github.io/moonread/schema/moonread-metadata-v1.schema.json\nSkill: https://suxiaoshao.github.io/moonread/skills/moonread-metadata/SKILL.md\nAgent: https://suxiaoshao.github.io/moonread/agent.txt\nWhen editing this exported manifest, preserve content_sha256 and reference unchanged. New manifests may be generated directly from TXT using normalization-v1. Use the same text encoding as Moonread. Reference: https://suxiaoshao.github.io/moonread/skills/moonread-metadata/identity/README.md\nThis is not a reading-data backup.\n".utf8).write(to: stage.appendingPathComponent("README.txt"))
                let output = directory.appendingPathComponent("Moonread.moonread-metadata")
                try writeMetadataArchive(stagingDirectory: stage.path, destination: output.path)
                return [output]
            }
            let output = directory.appendingPathComponent(manifest.lastPathComponent)
            try FileManager.default.copyItem(at: manifest, to: output)
            return [output]
        }
        try Task.checkCancellation()
        return .init(file: file, count: count, skipped: skipped, warnings: Array(Set(warning)).sorted())
    }

    func previewMetadata(_ url: URL) async throws -> MetadataImportPreview {
        let configuration = userCloudConfigurationRevision
        let source = ProtectedFileAccess.Source(selectedFile: url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-MetadataImports", isDirectory: true)
        let document = try await ProtectedFileAccess().readAsync(at: source.url) { readable in
            defer { withExtendedLifetime(source) {} }
            return try inspectMetadataExchange(inputPath: readable.path, stagingRoot: root.path)
        }
        let session = MetadataImportSession(document: document, configuration: configuration)
        return try await metadataPreview(session)
    }
    func metadataPreview(_ session: MetadataImportSession) async throws -> MetadataImportPreview {
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        guard session.configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        let query = try await catalogueQuery(nil, recursive: true)
        let store = try await userStore()
        var diagnostics: [MetadataDiagnostic] = [], cursor: UInt64 = 0
        repeat {
            let page = try session.document.diagnostics(cursor: cursor, count: 100)
            diagnostics += page.diagnostics; cursor = page.nextCursor
            if page.done { break }
        } while true
        let messagesBySHA = Dictionary(grouping: diagnostics.filter { $0.contentSha256 != nil }, by: { $0.contentSha256! })
        var shas: [String] = [], after: String?
        repeat {
            let page = try session.document.bookKeys(after: after, count: 100)
            shas += page.keys; after = page.keys.last
            if page.done { break }
        } while true
        var books: [MetadataPreviewBook] = []
        for sha in shas {
            try Task.checkCancellation()
            let sources = try query.systemReadingSources(contentSha256: sha)
            var item = MetadataPreviewBook(id: sha, title: sources.first.map { ($0.name as NSString).deletingPathExtension } ?? String(localized: "找不到这本书", table: "MetadataExchange"), base: nil, source: sources.count == 1 ? sources[0] : nil, sourceCount: sources.count, fields: [], messages: [])
            guard !sources.isEmpty else {
                item.messages = [String(localized: "找不到这本书", table: "MetadataExchange")]; books.append(item)
                let record = try session.document.records(sha: sha, cursor: 0, count: 1).records.first
                diagnostics.append(.init(sourceLine: record?.sourceLine, recordIndex: record?.recordIndex, code: "book_not_found", field: "content_sha256", contentSha256: sha, message: item.messages[0])); continue
            }
            do { try await store.requireMetadataReadable(key: sha) }
            catch {
                item.messages = [String(localized: "这本书的资料无法读取，未导入", table: "MetadataExchange")]; books.append(item)
                diagnostics.append(.init(sourceLine: nil, recordIndex: nil, code: "metadata_unreadable", field: nil, contentSha256: sha, message: item.messages[0])); continue
            }
            let base = try query.bookDetails(bookId: nil, contentSha: sha).metadata
            let hasPosition = try query.metadataHasReadingPosition(contentSha256: sha)
            item = MetadataPreviewBook(id: sha, title: item.title, base: base, source: item.source, sourceCount: sources.count, fields: [], messages: [])
            item.coverUnavailable = messagesBySHA[sha, default: []].contains { $0.code == "cover_unavailable" }
            var choices: [MetadataField: [MetadataOption]] = [:]
            var acceptedCovers: [BookCoverAsset] = []
            cursor = 0
            repeat {
                let page = try session.document.records(sha: sha, cursor: cursor, count: 50)
                for record in page.records {
                    let book = record.book
                    let origin = metadataSourceDescription(sourceLine: record.sourceLine, recordIndex: record.recordIndex)!
                    for field in MetadataField.allCases {
                        var text: String?, tags: [String] = [], cover: BookCoverAsset?
                        let clear = book.clear.contains(field.transportKey)
                        switch field {
                        case .author: text = book.author?.trimmingCharacters(in: .whitespacesAndNewlines)
                        case .description: text = book.description?.trimmingCharacters(in: .whitespacesAndNewlines)
                        case .title: text = book.title
                        case .readingState: text = book.readingState
                        case .tags:
                            if let incoming = book.tags { var normalized = base; normalized.tags = incoming; tags = normalized.normalizedForSaving.tags; text = "tags" }
                        case .cover:
                            if let path = book.cover {
                                if !item.coverFiles.contains(path) { item.coverFiles.append(path) }
                                do {
                                    let bytes = try Data(contentsOf: URL(fileURLWithPath: session.document.coverPath(path: path)))
                                    cover = try await importedCover(bytes, reusing: (base.cover.map { [$0] } ?? []) + acceptedCovers)
                                    if let cover, cover != base.cover, !acceptedCovers.contains(cover) {
                                        session.retainDraft(coverDraftURL(cover)); acceptedCovers.append(cover)
                                    }
                                    text = "cover"
                                } catch {
                                    item.coverUnavailable = true
                                    let message = String(localized: "封面无法读取；其他资料仍可导入", table: "MetadataExchange")
                                    item.messages.append(message)
                                    diagnostics.append(.init(sourceLine: record.sourceLine, recordIndex: record.recordIndex, code: "cover_invalid", field: "cover", contentSha256: sha, message: message))
                                }
                            }
                        }
                        guard clear || text != nil else { continue }
                        if field == .title && sources.count != 1 {
                            item.messages.append(String(localized: "同一正文对应多个文件，已跳过改名建议", table: "MetadataExchange")); continue
                        }
                        if field == .readingState && text == "unread" && hasPosition {
                            item.messages.append(String(localized: "这本书有阅读记录，不能改为未读；不会删除阅读记录", table: "MetadataExchange")); continue
                        }
                        // Reuse the form owner for byte limits and normalization, including invalid imported fields.
                        var validation = base
                        if field == .author { validation.author = text ?? "" }
                        if field == .description { validation.synopsis = text ?? "" }
                        if field == .tags { validation.tags = tags }
                        do { _ = try metadataEditPlan(base: base, edited: validation) }
                        catch {
                            let message = String(localized: "资料超出当前编辑限制，未采用该字段", table: "MetadataExchange")
                            item.messages.append(message)
                            diagnostics.append(.init(sourceLine: record.sourceLine, recordIndex: record.recordIndex, code: "field_limit", field: field.transportKey, contentSha256: sha, message: message)); continue
                        }
                        let id: String
                        if clear { id = "clear" }
                        else if let cover { id = "cover:" + cover.sha256 }
                        else if field == .tags { id = "tags:" + String(decoding: try JSONEncoder().encode(tags), as: UTF8.self) }
                        else { id = "value:" + text! }
                        if let index = choices[field]?.firstIndex(where: { $0.id == id }) { choices[field]![index].sources.append(origin) }
                        else { choices[field, default: []].append(.init(id: id, text: clear ? nil : text, tags: tags, cover: cover, sources: [origin], clearing: clear)) }
                    }
                }
                cursor = page.nextCursor
                if page.done { break }
            } while true
            for field in MetadataField.allCases {
                guard let options = choices[field] else { continue }
                let empty: Bool
                switch field { case .author: empty = base.author.isEmpty; case .description: empty = base.synopsis.isEmpty; case .tags: empty = true; case .cover: empty = base.cover == nil; default: empty = false }
                let selected = options.count == 1 && !options[0].clearing && field != .title && empty ? options[0].id : nil
                item.fields.append(.init(field: field, options: options, selected: selected))
            }
            item.messages += messagesBySHA[sha, default: []].map { String(localized: String.LocalizationValue($0.message), table: "MetadataExchange") }
            item.messages = Array(Set(item.messages)).sorted(); item.validateSelection(using: self); books.append(item)
        }
        guard session.configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        return .init(session: session, books: books, diagnostics: diagnostics)
    }

    func applyMetadata(_ preview: MetadataImportPreview, progress: @escaping @Sendable (Int, Int) async -> Void) async -> MetadataBatchResult {
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        let selected = preview.books.filter { !$0.changedFields.isEmpty }
        var result = MetadataBatchResult()
        for (index, book) in selected.enumerated() {
            if Task.isCancelled { result.cancelled = true; result.remaining = selected[index...].map { .init(id: $0.id, title: $0.title, saved: false, message: nil, cover: $0.base?.cover) }; break }
            do {
                guard preview.session.configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
                guard let base = book.base, let edited = book.edited else { continue }
                let plan = try metadataEditPlan(base: base, edited: edited, fields: Set(book.fields.filter { $0.chosen != nil }.map { $0.field.metadataKey }))
                try await commitMetadata(plan, cover: edited.cover != base.cover ? edited.cover : nil)
            } catch {
                result.outcomes.append(.init(id: book.id, title: book.title, saved: false, message: String(localized: "资料保存失败，已停止；此前保存的资料保留", table: "MetadataExchange"), cover: book.base?.cover))
                result.remaining = selected.dropFirst(index + 1).map { .init(id: $0.id, title: $0.title, saved: false, message: nil, cover: $0.base?.cover) }; break
            }
            var message: String?
            var renamed = false
            if let name = book.renameName, let source = book.source {
                // Only this explicit file-operation phase touches original bytes. Never download.
                do {
                    let snapshot = try aiFileSnapshot(source.location)
                    try renameLibraryItem(source, name: name, replace: false, expected: snapshot)
                    renamed = true
                } catch let error as AIFileExecutionError {
                    switch error.stage {
                    case .movedButIndexFailed: renamed = true; message = String(localized: "资料已保存，文件已改名，但索引未更新；请刷新书架", table: "MetadataExchange")
                    case .uncertain, .copiedSourceRemains: message = String(localized: "资料已保存，文件操作未完成；请检查书架中的文件", table: "MetadataExchange")
                    default: message = Self.metadataRenameFailure(error.underlying)
                    }
                } catch { message = Self.metadataRenameFailure(error) }
            }
            result.outcomes.append(.init(id: book.id, title: book.title, saved: true, message: message, cover: book.edited?.cover, savedFieldCount: book.changedMetadataFields.count, renamed: renamed))
            await progress(index + 1, selected.count)
        }
        return result
    }
    private nonisolated static func metadataRenameFailure(_ error: Error) -> String {
        if let error = error as? AIToolError, error.code == "needs_preparation" {
            return String(localized: "资料已保存，文件未改名：原文件尚未下载；本次不会下载", table: "MetadataExchange")
        }
        if case LibraryFileError.conflict = error { return String(localized: "资料已保存，文件未改名：目标名称已存在", table: "MetadataExchange") }
        if let error = error as? AIToolError, error.code == "stale_reference" { return String(localized: "资料已保存，文件未改名：原文件已变化", table: "MetadataExchange") }
        return String(localized: "资料已保存，文件未改名：原文件不可用、无权限或名称无效", table: "MetadataExchange")
    }
}
