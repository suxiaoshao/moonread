import Foundation
import CryptoKit

extension AppDataService {
    func metadataImportScope() -> String {
        switch userCloudMode {
        case .local: return "local"
        case .cloud(let account):
            let digest = SHA256.hash(data: Data(account.recordName.utf8))
            return "cloud:" + digest.map { String(format: "%02x", $0) }.joined()
        }
    }
    func exportMetadata(shelfID: String?, format: MetadataFormat, progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> MetadataExportResult {
        try await acquireCancellableUserDataOperation(); defer { releaseUserDataOperation() }
        try Task.checkCancellation()
        let configuration = userCloudConfigurationRevision
        let inputs = try await metadataExchangeInputs(.export(shelfId: shelfID), configuration: configuration)
        let bases = Dictionary(uniqueKeysWithValues: inputs.read.books.map { ($0.metadata.sha, $0) })
        var grouped: [String: [MetadataExchangeFile]] = [:]
        var skipped: [MetadataSkippedFile] = []
        for entry in inputs.read.exportFiles {
            try Task.checkCancellation()
            let file = entry.file
            guard let sha = entry.sha else {
                skipped.append(.init(id: file.id, shelf: file.shelfName, path: file.relativePath))
                continue
            }
            grouped[sha, default: []].append(file)
        }
        await progress(0, grouped.count)
        try Task.checkCancellation()
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("MetadataExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let manifest = stage.appendingPathComponent(format == .json ? "metadata.json" : "metadata.jsonl")
        // Packaging is decided from selected metadata, not by looking at the TXT.
        var warning: [String] = [], count = 0
        for sha in grouped.keys {
            try Task.checkCancellation()
            guard !inputs.formalBlockedMetadata.contains(sha) else { throw UserSyncCompatibilityError() }
        }
        let hasCovers = bases.values.contains { $0.metadata.cover != nil }
        let writer = try createMetadataWriter(destination: manifest.path, format: format, packaged: hasCovers)
        for sha in grouped.keys.sorted() {
            try Task.checkCancellation()
            let sources = grouped[sha]!
            let base = bases[sha]!
            let metadata = base.metadata
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
            let first = sources[0]
            let references = sources.map { MetadataFileReference(title: ($0.name as NSString).deletingPathExtension, shelf: $0.shelfName, path: $0.relativePath) }
            let book = MetadataBook(v: 1, contentSha256: sha,
                reference: .init(title: (first.name as NSString).deletingPathExtension, author: metadata.author.isEmpty ? nil : metadata.author, files: references),
                title: base.sourceCount == 1 ? (first.name as NSString).deletingPathExtension : nil,
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

    func previewMetadata(_ url: URL, expectedScope: String? = nil,
                         progress: (@Sendable (MetadataPreparationProgress) -> Void)? = nil) async throws -> MetadataImportPreview {
        if let expectedScope, expectedScope != metadataImportScope() { throw ReadingDataError.changed }
        let configuration = userCloudConfigurationRevision
        let source = ProtectedFileAccess.Source(selectedFile: url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-MetadataImports", isDirectory: true)
        progress?(.readingPackage)
        let document = try await ProtectedFileAccess().readAsync(at: source.url) { readable in
            defer { withExtendedLifetime(source) {} }
            return try inspectMetadataExchange(inputPath: readable.path, stagingRoot: root.path)
        }
        let session = MetadataImportSession(document: document, configuration: configuration)
        return try await metadataPreview(session, progress: progress)
    }
    func metadataPreview(_ session: MetadataImportSession,
                         progress: (@Sendable (MetadataPreparationProgress) -> Void)? = nil) async throws -> MetadataImportPreview {
        guard session.configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        var diagnostics: [MetadataDiagnostic] = [], cursor: UInt64 = 0
        repeat {
            try Task.checkCancellation()
            let page = try session.document.diagnostics(cursor: cursor, count: 100)
            diagnostics += page.diagnostics; cursor = page.nextCursor
            if page.done { break }
        } while true
        let messagesBySHA = Dictionary(grouping: diagnostics.filter { $0.contentSha256 != nil }, by: { $0.contentSha256! })
        var shas: [String] = [], after: String?
        repeat {
            try Task.checkCancellation()
            let page = try session.document.bookKeys(after: after, count: 100)
            shas += page.keys; after = page.keys.last
            if page.done { break }
        } while true
        progress?(.matchingBooks(shas.count))
        let inputs = try await metadataExchangeInputs(.import(shas: shas), configuration: session.configuration)
        let bases = Dictionary(uniqueKeysWithValues: inputs.read.books.map { ($0.metadata.sha, $0) })
        var books: [MetadataPreviewBook] = []
        var coverCache = PreviewCoverCache()
        var newDrafts: [URL] = []
        var keepDrafts = false
        defer {
            if !keepDrafts { for url in newDrafts { try? FileManager.default.removeItem(at: url) } }
        }
        progress?(.preparingBooks(completed: 0, total: shas.count))
        for sha in shas {
            try Task.checkCancellation()
            defer {
                if books.count.isMultiple(of: 8) || books.count == shas.count {
                    progress?(.preparingBooks(completed: books.count, total: shas.count))
                }
            }
            guard let matched = bases[sha] else {
                let message = String(localized: "找不到这本书", table: "MetadataExchange")
                books.append(.init(id: sha, title: message, match: .unmatched, messages: [message]))
                let record = try session.document.records(sha: sha, cursor: 0, count: 1).records.first
                diagnostics.append(.init(sourceLine: record?.sourceLine, recordIndex: record?.recordIndex, code: "book_not_found", field: "content_sha256", contentSha256: sha, message: message)); continue
            }
            let source = MetadataPreviewBook.Source(matched)
            let title = (matched.firstSourceName as NSString).deletingPathExtension
            if inputs.formalBlockedMetadata.contains(sha) {
                let message = String(localized: "这本书的资料无法读取，未导入", table: "MetadataExchange")
                books.append(.init(id: sha, title: title, match: .skipped(reason: message, source), messages: [message]))
                diagnostics.append(.init(sourceLine: nil, recordIndex: nil, code: "metadata_unreadable", field: nil, contentSha256: sha, message: message)); continue
            }
            let base = matched.metadata
            let hasPosition = matched.hasReadingPosition
            var item = MetadataPreviewBook(id: sha, title: title, match: .matched(.init(base: base, source: source)))
            item.coverUnavailable = messagesBySHA[sha, default: []].contains { $0.code == "cover_unavailable" }
            var choices: [MetadataField: [MetadataOption]] = [:]
            var choiceIndices: [MetadataField: [String: Int]] = [:]
            var coverPaths: Set<String> = []
            var acceptedCovers = PreviewCoverCandidates()
            cursor = 0
            repeat {
                let page = try session.document.records(sha: sha, cursor: cursor, count: 50)
                for record in page.records {
                    try Task.checkCancellation()
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
                                if coverPaths.insert(path).inserted { item.coverFiles.append(path) }
                                do {
                                    cover = try await importedCover(path: path, base: base.cover, cache: &coverCache,
                                        candidates: &acceptedCovers, read: {
                                            try Data(contentsOf: URL(fileURLWithPath: session.document.coverPath(path: path)))
                                        }, drafts: &newDrafts)
                                    text = "cover"
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch {
                                    item.coverUnavailable = true
                                    let message = String(localized: "封面无法读取；其他资料仍可导入", table: "MetadataExchange")
                                    item.messages.append(message)
                                    diagnostics.append(.init(sourceLine: record.sourceLine, recordIndex: record.recordIndex, code: "cover_invalid", field: "cover", contentSha256: sha, message: message))
                                }
                            }
                        }
                        guard clear || text != nil else { continue }
                        if field == .title && matched.sourceCount != 1 {
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
                        else if let cover { id = "cover:" + cover.id }
                        else if field == .tags { id = "tags:" + String(decoding: try JSONEncoder().encode(tags), as: UTF8.self) }
                        else { id = "value:" + text! }
                        if let index = choiceIndices[field]?[id] { choices[field]![index].sources.append(origin) }
                        else {
                            choiceIndices[field, default: [:]][id] = choices[field]?.count ?? 0
                            choices[field, default: []].append(.init(id: id, text: clear ? nil : text, tags: tags, cover: cover, sources: [origin], clearing: clear))
                        }
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
        try Task.checkCancellation()
        session.retainDrafts(newDrafts)
        keepDrafts = true
        return .init(session: session, books: books, diagnostics: diagnostics)
    }

    func confirmMetadata(_ preview: MetadataImportPreview) async throws -> MetadataConfirmedImport {
        try Task.checkCancellation()
        guard preview.session.configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        let books = preview.books.filter { !$0.changedFields.isEmpty }
        guard Set(books.map(\.id)).count == books.count,
              books.allSatisfy({ $0.selectionError == nil }) else { throw ReaderError.InvalidSettings }
        let deletionTokens = Dictionary(uniqueKeysWithValues: books.map { ($0.id, localReadingWriteLease($0.id)) })
        let expectedStoreID = userStoreTask?.id
        let store = try await userStore()
        guard preview.session.configuration == userCloudConfigurationRevision, let storeID = userStoreTask?.id,
              expectedStoreID == nil || expectedStoreID == storeID else { throw ReadingDataError.changed }
        try Task.checkCancellation()
        return .init(session: preview.session, books: books,
                     writeIndices: books.indices.filter { !books[$0].changedMetadataFields.isEmpty },
                     renameIndices: books.indices.filter { books[$0].renameName != nil },
                     store: store, storeID: storeID, deletionTokens: deletionTokens)
    }

    private struct PreparedMetadataBook: Sendable {
        let index: Int
        let plan: BookMetadataEditPlan
        let asset: BookCoverAsset?
        let url: URL?
        let budget: MetadataBatchBudget
    }

    private func prepareMetadataBook(_ index: Int, _ book: MetadataPreviewBook) throws -> PreparedMetadataBook {
        guard let base = book.base, let edited = book.edited else { throw ReaderError.InvalidSettings }
        let plan = try metadataEditPlan(base: base, edited: edited,
                                        fields: Set(book.fields.compactMap { $0.chosen == nil ? nil : $0.field.metadataKey }))
        guard !plan.values.isEmpty else { throw ReaderError.InvalidSettings }
        var text = 0
        for (key, value) in plan.values {
            let (subtotal, firstOverflow) = text.addingReportingOverflow(key.utf8.count)
            let (next, secondOverflow) = subtotal.addingReportingOverflow(value.utf8.count)
            guard !firstOverflow, !secondOverflow else { throw ReaderError.InvalidSettings }
            text = next
        }
        let asset = edited.cover == base.cover ? nil : edited.cover
        let url = asset.map(coverDraftURL)
        var size = 0
        if let url {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let length = values.fileSize, length > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            size = length
        }
        return .init(index: index, plan: plan, asset: asset, url: url,
                     budget: .init(keys: plan.values.count, text: text, covers: size))
    }

    func applyMetadata(_ preview: MetadataImportPreview,
                       progress: @Sendable (Int, Int) -> Void = { _, _ in }) async -> MetadataBatchResult {
        do {
            let confirmed = try await confirmMetadata(preview)
            return await applyMetadata(confirmed) { update in
                if update.phase == .saving { progress(update.completed, update.total) }
            }.result
        } catch {
            var result = MetadataBatchResult()
            result.cancelled = error is CancellationError
            result.requiresNewPreview = error is ReadingDataError
            if !result.cancelled { result.failure = ReaderMessages.error(error) }
            let outstanding: (MetadataPreviewBook) -> MetadataImportOutcome = {
                .init(id: $0.id, title: $0.title, saved: false, message: nil, cover: $0.base?.cover)
            }
            result.remaining = preview.books.filter { !$0.changedMetadataFields.isEmpty }.map(outstanding)
            result.remainingRenames = preview.books.filter { $0.renameName != nil }.map(outstanding)
            return result
        }
    }

    func applyMetadata(_ confirmed: MetadataConfirmedImport,
                       progress: @Sendable (MetadataApplyProgress) -> Void = { _ in }) async
    -> (checkpoint: MetadataConfirmedImport, result: MetadataBatchResult) {
        var checkpoint = confirmed
        var result = MetadataBatchResult()
        var wroteThisRun = false
        defer {
            if wroteThisRun, confirmed.session.configuration == userCloudConfigurationRevision {
                scheduleSystemReadingCatalog(immediate: systemCatalog?.task == nil)
            }
        }
        let bookAt = confirmed.books
        let writes = confirmed.writeIndices
        let renames = confirmed.renameIndices
        var next: PreparedMetadataBook?
        do {
            try Task.checkCancellation()
            let outstanding = Array(writes.dropFirst(checkpoint.committed)) + Array(renames.dropFirst(checkpoint.renamedThrough))
            try validateMetadataScope(confirmed, indices: outstanding)
            while checkpoint.committed < writes.count {
                try Task.checkCancellation()
                var prepared: [PreparedMetadataBook] = []
                var budget = MetadataBatchBudget.zero
                while checkpoint.committed + prepared.count < writes.count {
                    try Task.checkCancellation()
                    let index = writes[checkpoint.committed + prepared.count]
                    let candidate = try next ?? prepareMetadataBook(index, bookAt[index])
                    guard let combined = budget.adding(candidate.budget, within: .target) else {
                        if prepared.isEmpty { prepared.append(candidate); next = nil }
                        else { next = candidate }
                        break
                    }
                    next = nil
                    prepared.append(candidate)
                    budget = combined
                }
                let entries = try prepared.map { item in
                    try Task.checkCancellation()
                    let cover: UserDataStore.CoverWrite?
                    if let asset = item.asset, let url = item.url {
                        cover = try Self.readCoverDraft(asset, url: url, length: item.budget.covers)
                    } else { cover = nil }
                    return UserDataStore.MetadataWrite(plan: item.plan, cover: cover)
                }
                try await acquireCancellableUserDataOperation()
                do {
                    defer { releaseUserDataOperation() }
                    try Task.checkCancellation()
                    try validateMetadataScope(confirmed, indices: prepared.map(\.index))
                    try await confirmed.store.putMetadata(entries, device: userDevice)
                    // A successful save is a fact even when a stop raced the return.
                    checkpoint.committed += prepared.count
                    wroteThisRun = true
                    for item in prepared {
                        let book = bookAt[item.index]
                        checkpoint.outcomes[item.index] = .init(id: book.id, title: book.title, saved: true,
                            message: nil, cover: book.edited?.cover, savedFieldCount: book.changedMetadataFields.count)
                    }
                    publishMetadataCommit(prepared.map(\.plan), deferCatalogRefresh: true)
                }
                progress(.init(phase: .saving, completed: checkpoint.committed, total: writes.count))
            }
            if checkpoint.renamedThrough < renames.count {
                try Task.checkCancellation()
                progress(.init(phase: .renaming, completed: checkpoint.renamedThrough, total: renames.count))
            }
            while checkpoint.renamedThrough < renames.count {
                try Task.checkCancellation()
                let index = renames[checkpoint.renamedThrough]
                try validateMetadataScope(confirmed, indices: [index])
                let book = bookAt[index]
                guard let name = book.renameName, let source = book.source else { throw ReaderError.InvalidSettings }
                var outcome = checkpoint.outcomes[index] ?? .init(id: book.id, title: book.title, saved: false, message: nil, cover: book.base?.cover)
                do {
                    try await renameLibraryBook(source, name: name, expected: .formal(sha256: book.id),
                                                configuration: confirmed.session.configuration,
                                                deletionToken: confirmed.deletionTokens[book.id])
                    outcome.renamed = true
                } catch is CancellationError { throw CancellationError() }
                catch let error as ReadingDataError { throw error }
                catch let error as AIFileExecutionError {
                    switch error.stage {
                    case .movedButIndexFailed:
                        outcome.renamed = true
                        outcome.message = String(localized: outcome.saved ? "资料已保存，文件已改名，但索引未更新；请刷新书架" : "文件已改名，但索引未更新；请刷新书架", table: "MetadataExchange")
                    case .uncertain, .copiedSourceRemains:
                        outcome.message = String(localized: outcome.saved ? "资料已保存，文件操作未完成；请检查书架中的文件" : "文件操作未完成；请检查书架中的文件", table: "MetadataExchange")
                    default: outcome.message = Self.metadataRenameFailure(error.underlying, saved: outcome.saved)
                    }
                } catch { outcome.message = Self.metadataRenameFailure(error, saved: outcome.saved) }
                outcome.renameAttempted = true
                checkpoint.outcomes[index] = outcome
                checkpoint.renamedThrough += 1
                progress(.init(phase: .renaming, completed: checkpoint.renamedThrough, total: renames.count))
            }
        } catch is CancellationError { result.cancelled = true }
        catch {
            result.requiresNewPreview = error is ReadingDataError
            result.failure = ReaderMessages.error(error)
        }
        result.outcomes = checkpoint.outcomes.keys.sorted().compactMap { checkpoint.outcomes[$0] }
        result.remaining = writes.dropFirst(checkpoint.committed).map {
            let book = bookAt[$0]
            return .init(id: book.id, title: book.title, saved: false, message: nil, cover: book.base?.cover)
        }
        result.remainingRenames = renames.dropFirst(checkpoint.renamedThrough).map {
            let book = bookAt[$0]
            return checkpoint.outcomes[$0] ?? .init(id: book.id, title: book.title, saved: false, message: nil, cover: book.base?.cover)
        }
        return (checkpoint, result)
    }

    private func validateMetadataScope(_ confirmed: MetadataConfirmedImport, indices: [Int]) throws {
        guard confirmed.session.configuration == userCloudConfigurationRevision, confirmed.storeID == userStoreTask?.id,
              indices.allSatisfy({ index in
                  let key = confirmed.books[index].id
                  return confirmed.deletionTokens[key] == localReadingWriteLeases[key]
              }) else { throw ReadingDataError.changed }
    }
    private nonisolated static func metadataRenameFailure(_ error: Error, saved: Bool) -> String {
        if let error = error as? AIToolError, error.code == "needs_preparation" {
            return String(localized: saved ? "资料已保存，文件未改名：原文件尚未下载；本次不会下载" : "文件未改名：原文件尚未下载；本次不会下载", table: "MetadataExchange")
        }
        if case LibraryFileError.conflict = error { return String(localized: saved ? "资料已保存，文件未改名：目标名称已存在" : "文件未改名：目标名称已存在", table: "MetadataExchange") }
        let changed: Bool
        if case ReaderError.SourceChanged = error { changed = true }
        else { changed = (error as? AIToolError)?.code == "stale_reference" }
        if changed { return String(localized: saved ? "资料已保存，文件未改名：原文件已变化" : "文件未改名：原文件已变化", table: "MetadataExchange") }
        return String(localized: saved ? "资料已保存，文件未改名：原文件不可用、无权限或名称无效" : "文件未改名：原文件不可用、无权限或名称无效", table: "MetadataExchange")
    }
}
