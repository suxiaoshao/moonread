import SwiftUI
import UIKit
import BackgroundTasks

@MainActor @Observable final class MetadataExchangeModel {
    static let shared = MetadataExchangeModel(service: .shared, directory: URL.applicationSupportDirectory
        .appending(path: "Moonread", directoryHint: .isDirectory).appending(path: "MetadataImport", directoryHint: .isDirectory))

    let service: AppDataService
    let exportTask: MetadataExportTask
    enum Phase: Equatable {
        case idle, receiving, preparing, review, saving, renaming, completed, stopped, paused, failed, interrupted

        var title: LocalizedStringKey {
            switch self {
            case .idle: "导入信息"
            case .receiving: "正在接收资料"
            case .preparing: "正在准备预览"
            case .review: "等待确认"
            case .saving: "正在保存资料"
            case .renaming: "正在整理文件名"
            case .completed: "导入已完成"
            case .stopped: "导入已停止"
            case .paused: "导入已暂停"
            case .failed: "保存未完成"
            case .interrupted: "上次导入已中断"
            }
        }
    }
    struct Issue: Identifiable {
        let id: Int
        let value: MetadataDiagnostic
    }
    private struct ChoiceHint: Codable, Equatable {
        var field: String
        var selected: String?
        var replaceTags: Bool
    }
    private struct Record: Codable {
        var version = 1
        var id: UUID
        var sourceExtension: String
        var scope: String?
        var inputComplete = false
        var hints: [String: [ChoiceHint]] = [:]
        var summary: Summary?
        var finished: Bool? = nil
    }
    private struct Summary: Codable {
        var saved: Int
        var renamed: Int
        var renameIssues: Int
    }

    private(set) var phase: Phase = .idle
    private(set) var preview: MetadataImportPreview?
    private(set) var result: MetadataBatchResult?
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var cancellationRequested = false
    private(set) var error: String?
    private(set) var requiresNewPreview = false
    private(set) var sourceScopeChanged = false
    var issues: [Issue] { (preview?.diagnostics ?? []).enumerated().map { Issue(id: $0.offset, value: $0.element) } }
    var loading: Bool { phase == .receiving || phase == .preparing }
    var saving: Bool { phase == .saving || phase == .renaming }
    var hasTask: Bool { phase != .idle }
    var canStartNew: Bool { phase == .idle || phase == .completed }
    var canContinue: Bool { !requiresNewPreview && (phase == .stopped || phase == .paused) && (checkpoint != nil || hasCompleteInput) }
    var continuingPreparation: Bool { checkpoint == nil }
    var hasCompleteInput: Bool { record?.inputComplete == true }
    var canRepreview: Bool { hasCompleteInput && !sourceScopeChanged }
    var onlyRenameIssueSummary: Bool { phase == .completed && result == nil && renameIssueCount > 0 }
    var savedCount: Int { result?.outcomes.filter(\.saved).count ?? record?.summary?.saved ?? 0 }
    var renamedCount: Int { result?.outcomes.filter(\.renamed).count ?? record?.summary?.renamed ?? 0 }
    var renameIssueCount: Int { result?.outcomes.filter { $0.renameAttempted && $0.message != nil }.count ?? record?.summary?.renameIssues ?? 0 }
    // Presentation reads the existing checkpoint; it does not advance the task.
    var renameOnlyContinuation: Bool {
        guard let checkpoint else { return false }
        return checkpoint.committed == checkpoint.writeIndices.count && continueNeedsRenameConfirmation
    }
    var knownRemainingWrites: Int? {
        if let result { return result.remaining.count }
        if let checkpoint { return checkpoint.writeIndices.count - checkpoint.committed }
        if preview != nil && (phase == .failed || phase == .stopped || phase == .paused) {
            return pending.filter { !$0.changedMetadataFields.isEmpty }.count
        }
        return nil
    }
    var knownRemainingRenames: Int {
        if let result { return result.remainingRenames.count }
        if let checkpoint { return checkpoint.renameIndices.count - checkpoint.renamedThrough }
        if preview != nil && (phase == .failed || phase == .stopped || phase == .paused) {
            return pending.filter { $0.renameName != nil }.count
        }
        return 0
    }
    var knownAttemptedRenames: Int {
        if let checkpoint { return checkpoint.renamedThrough }
        return result?.outcomes.filter(\.renameAttempted).count ?? 0
    }
    var knownRenameTotal: Int? {
        if let checkpoint { return checkpoint.renameIndices.count }
        return result.map { $0.outcomes.filter(\.renameAttempted).count + $0.remainingRenames.count }
    }
    var hasCommittedMetadataBeforeRenaming: Bool { (checkpoint?.writeIndices.count ?? 0) > 0 }
    var displayPhase: Phase {
        if phase == .saving && (total == 0 || renameOnlyContinuation) { return .renaming }
        return phase
    }
    var displayedProgress: (completed: Int, total: Int) {
        if displayPhase != phase { return (knownAttemptedRenames, knownRenameTotal ?? 0) }
        return (completed, total)
    }
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var checkpoint: MetadataConfirmedImport?
    @ObservationIgnored private var systemPaused = false
    @ObservationIgnored private let systemExecution = MetadataSystemExecution()
    @ObservationIgnored private var preparedDirectory = false
    @ObservationIgnored private var preparation: MetadataPreparationProgress?
    private(set) var pauseReason: PauseReason?
    enum PauseReason: Equatable { case unavailable, expired }
    private let directory: URL?
    private var record: Record?
    private var recordURL: URL? { directory?.appending(path: "task.json") }
    private var inputURL: URL? {
        guard let directory, let record else { return nil }
        return directory.appending(path: record.id.uuidString, directoryHint: .isDirectory)
            .appending(path: "input").appendingPathExtension(record.sourceExtension)
    }

    init(service: AppDataService, directory: URL? = nil) {
        self.service = service
        exportTask = MetadataExportTask(service: service, usesSystemExecution: directory != nil)
        self.directory = directory
        if let recordURL, let data = try? Data(contentsOf: recordURL),
           let saved = try? JSONDecoder().decode(Record.self, from: data), saved.version == 1,
           Self.inputExtensions.contains(saved.sourceExtension) {
            record = saved
            // The final filename is published by an atomic move, never by partial copy.
            let complete = inputURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            record?.inputComplete = complete
            phase = saved.finished == true ? .completed : .interrupted
        }
    }
    private static let inputExtensions: Set<String> = ["moonread-metadata", "zip", "json", "jsonl"]

    private func persist() throws {
        guard let recordURL, let directory, let record else { return }
        if !preparedDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var location = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try location.setResourceValues(values)
            preparedDirectory = true
        }
        try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
    }
    private func persistChanges() {
        do { try persist() }
        catch { showError(ReaderMessages.error(error)) }
    }

    func showError(_ message: String) { error = message }
    func review(_ preview: MetadataImportPreview) { self.preview = preview; result = nil; phase = .review }
    var books: [MetadataPreviewBook] { preview?.books ?? [] }
    var invalidSelection: Bool { books.contains { $0.selectionError != nil } }
    var pending: [MetadataPreviewBook] { books.filter { $0.disposition == .changes } }
    var unchangedCount: Int { books.filter { $0.disposition == .unchanged }.count }
    var isUnchangedPreview: Bool {
        phase == .review && !books.isEmpty && error == nil
            && preview?.diagnostics.isEmpty == true && !invalidSelection
            && books.allSatisfy { $0.disposition == .unchanged && !$0.hasSuggestedChanges }
    }
    var unmatchedCount: Int { books.filter { $0.disposition == .unmatched }.count }
    var skippedCount: Int { books.filter { $0.disposition == .skipped }.count }
    func visible(query: String, filter: Int) -> [MetadataPreviewBook] {
        books.filter { book in
            (query.isEmpty || LibraryQueryRules.selectionMatches(book.title, query: query)) &&
            (filter == 0 || (filter == 1 ? book.disposition == .changes : book.disposition != .changes))
        }
    }

    func receive(_ url: URL) {
        guard canStartNew, work == nil else { return }
        let source = ProtectedFileAccess.Source(selectedFile: url)
        let suffix = url.pathExtension.lowercased()
        guard Self.inputExtensions.contains(suffix) else {
            if phase == .idle { phase = .failed }
            showError(String(localized: "清单无法读取", table: "MetadataExchange"))
            return
        }
        clear()
        record = .init(id: UUID(), sourceExtension: suffix)
        phase = .receiving
        launch { model in
            model.record?.scope = await model.service.metadataImportScope()
            try model.persist()
            guard let local = model.inputURL else {
                try await model.prepare(source.url)
                withExtendedLifetime(source) {}
                return
            }
            try await Self.copy(source, to: local)
            model.record?.inputComplete = true
            try model.persist()
            try Task.checkCancellation()
            try await model.prepare(local)
        }
    }

    private static func copy(_ source: ProtectedFileAccess.Source, to target: URL) async throws {
        try await ProtectedFileAccess().readAsync(at: source.url) { coordinated in
            defer { withExtendedLifetime(source) {} }
            let fm = FileManager.default
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = target.appendingPathExtension("partial")
            defer { try? fm.removeItem(at: staging) }
            try fm.copyItem(at: coordinated, to: staging)
            try fm.moveItem(at: staging, to: target)
        }
    }

    private func prepare(_ url: URL) async throws {
        phase = .preparing
        if let expected = record?.scope, expected != (await service.metadataImportScope()) {
            sourceScopeChanged = true
            throw ReadingDataError.changed
        }
        let (updates, stream) = AsyncStream.makeStream(of: MetadataPreparationProgress.self, bufferingPolicy: .bufferingNewest(1))
        let observer = Task {
            for await update in updates {
                guard !Task.isCancelled else { return }
                preparation = update
                publishSystemProgress()
            }
        }
        defer { stream.finish(); observer.cancel() }
        var loaded = try await service.previewMetadata(url, expectedScope: record?.scope) { stream.yield($0) }
        if let current = record?.scope, current != (await service.metadataImportScope()) {
            sourceScopeChanged = true
            throw ReadingDataError.changed
        }
        try Task.checkCancellation()
        let hints = record?.hints ?? [:]
        for index in loaded.books.indices {
            let id = loaded.books[index].id
            guard let remembered = hints[id] else { continue }
            for f in loaded.books[index].fields.indices {
                let field = loaded.books[index].fields[f].field
                guard let hint = remembered.first(where: { $0.field == field.rawValue }) else { continue }
                // File moves require a new explicit selection after rereading live sources.
                if field == .title { loaded.books[index].fields[f].selected = nil; continue }
                loaded.books[index].fields[f].selected = loaded.books[index].fields[f].options
                    .first { hint.selected == Self.optionIdentity($0) }?.id
                loaded.books[index].fields[f].replaceTags = hint.replaceTags
            }
            loaded.books[index].validateSelection(using: service)
        }
        review(loaded)
    }

    private nonisolated static func optionIdentity(_ option: MetadataOption) -> String {
        if option.clearing { return "clear" }
        if let cover = option.cover { return "cover:" + cover.sha256 }
        return option.id
    }
    private func remember(_ book: MetadataPreviewBook) {
        record?.hints[book.id] = book.fields.map { .init(field: $0.field.rawValue,
            selected: $0.chosen.map(Self.optionIdentity), replaceTags: $0.replaceTags) }
    }

    func binding(_ id: String) -> Binding<MetadataPreviewBook>? {
        guard let book = books.first(where: { $0.id == id }) else { return nil }
        return Binding(get: { self.books.first { $0.id == id } ?? book }, set: { value in
            guard self.phase == .review, var preview = self.preview,
                  let index = preview.books.firstIndex(where: { $0.id == id }) else { return }
            var value = value
            value.validateSelection(using: self.service)
            preview.books[index] = value
            self.preview = preview
            self.remember(value)
            self.persistChanges()
        })
    }
    func adopt(_ enabled: Bool, replaceTags: Bool = false) {
        guard phase == .review, var preview else { return }
        for index in preview.books.indices {
            preview.books[index].adopt(enabled, replaceTags: replaceTags)
            preview.books[index].validateSelection(using: service)
            remember(preview.books[index])
        }
        self.preview = preview
        persistChanges()
    }
    var confirmation: String {
        let books = pending
        let clear = books.reduce(0) { $0 + $1.fields.filter { $0.chosen?.clearing == true }.count }
        let removed = books.reduce(0) { $0 + Set($1.base?.tags ?? []).subtracting($1.edited?.tags ?? []).count }
        let rename = books.filter { $0.renameName != nil }.count
        let writeCount = books.filter { !$0.changedMetadataFields.isEmpty }.count
        var details: [String] = []
        if writeCount > 0 {
            details.append(rename > 0
                ? String(localized: "保存 \(writeCount) 本资料，另将 \(rename) 个文件改名。", table: "MetadataExchange")
                : String(localized: "保存 \(writeCount) 本资料。", table: "MetadataExchange"))
        } else {
            details.append(String(localized: "改名 \(rename) 个文件。", table: "MetadataExchange"))
        }
        if clear > 0 { details.append(String(localized: "清空 \(clear) 个字段。", table: "MetadataExchange")) }
        if removed > 0 { details.append(String(localized: "移除 \(removed) 个标签。", table: "MetadataExchange")) }
        if writeCount > 0 {
            details.append(String(localized: "已保存的资料不会因停止或后续失败撤回。", table: "MetadataExchange"))
        } else {
            details.append(String(localized: "已完成的改名不会因停止或后续失败撤回。", table: "MetadataExchange"))
        }
        return details.joined(separator: "\n")
    }

    func save() {
        guard phase == .review, work == nil, !invalidSelection, !pending.isEmpty, let preview else { return }
        phase = .saving
        completed = 0; total = pending.filter { !$0.changedMetadataFields.isEmpty }.count
        launch { model in
            let confirmed = try await model.service.confirmMetadata(preview)
            model.checkpoint = confirmed
            model.publishSystemProgress()
            try Task.checkCancellation()
            await model.execute(confirmed)
        }
    }
    private func execute(_ confirmed: MetadataConfirmedImport) async {
        let (updates, stream) = AsyncStream.makeStream(of: MetadataApplyProgress.self, bufferingPolicy: .bufferingNewest(1))
        let observer = Task {
            for await update in updates {
                guard !Task.isCancelled else { return }
                phase = update.phase == .saving ? .saving : .renaming
                completed = update.completed; total = update.total
                publishSystemProgress()
            }
        }
        let applied = await service.applyMetadata(confirmed) { stream.yield($0) }
        stream.finish()
        observer.cancel()
        result = applied.result
        requiresNewPreview = applied.result.requiresNewPreview
        checkpoint = applied.checkpoint
        record?.summary = .init(saved: savedCount, renamed: renamedCount, renameIssues: renameIssueCount)
        if applied.result.cancelled {
            phase = systemPaused ? .paused : .stopped
        } else if let failure = applied.result.failure {
            if applied.result.requiresNewPreview, let expected = record?.scope,
               expected != (await service.metadataImportScope()) { sourceScopeChanged = true }
            error = failure
            phase = .failed
            checkpoint = nil
        } else {
            phase = .completed
            checkpoint = nil
            record?.finished = true
            record?.hints.removeAll()
            preview = nil
            persistChanges()
            return
        }
        // Diagnostic only: a stopped/failed run still requires preview on process restart.
        persistChanges()
    }
    func cancel() {
        guard loading || saving, !cancellationRequested else { return }
        cancellationRequested = true
        work?.cancel()
    }
    func continueTask() {
        guard canContinue, work == nil else { return }
        if let checkpoint {
            phase = .saving
            completed = checkpoint.committed; total = checkpoint.writeIndices.count
            launch { await $0.execute(checkpoint) }
        } else { reviewAgain() }
    }
    var continueNeedsRenameConfirmation: Bool {
        guard let checkpoint else { return false }
        return checkpoint.renamedThrough < checkpoint.renameIndices.count
    }
    func reviewAgain() {
        guard work == nil, let inputURL, canRepreview else { return }
        checkpoint = nil
        result = nil
        requiresNewPreview = false
        record?.finished = false
        record?.summary = nil
        phase = .preparing
        launch {
            try $0.persist()
            try await $0.prepare(inputURL)
        }
    }
    func clear() {
        guard work == nil else { return }
        if let directory, let record {
            try? FileManager.default.removeItem(at: directory.appending(path: record.id.uuidString, directoryHint: .isDirectory))
        }
        if let recordURL { try? FileManager.default.removeItem(at: recordURL) }
        record = nil; preview = nil; result = nil; checkpoint = nil; error = nil
        requiresNewPreview = false; sourceScopeChanged = false; pauseReason = nil; preparation = nil
        phase = .idle; completed = 0; total = 0
    }

    private func launch(_ action: @escaping @MainActor (MetadataExchangeModel) async throws -> Void) {
        error = nil
        cancellationRequested = false
        systemPaused = false
        pauseReason = nil
        preparation = nil
        if directory != nil {
            systemExecution.begin(
                kind: "metadata-import",
                title: String(localized: "导入小说信息", table: "MetadataExchange"),
                subtitle: String(localized: "正在处理已选择的资料", table: "MetadataExchange"),
                canAttach: { [weak self] in self?.cancellationRequested == false },
                didAttach: { [weak self] in self?.publishSystemProgress() },
                didExpire: { [weak self] reason in
                    guard let self, !self.cancellationRequested else { return }
                    self.systemPaused = true
                    self.pauseReason = reason
                    self.cancel()
                })
        }
        work = Task {
            defer {
                systemExecution.finish(success: phase == .review || phase == .completed)
                work = nil; cancellationRequested = false
            }
            do { try await action(self) }
            catch is CancellationError {
                if let inputURL, FileManager.default.fileExists(atPath: inputURL.path) {
                    record?.inputComplete = true
                    persistChanges()
                }
                phase = systemPaused ? .paused : .stopped
            }
            catch {
                requiresNewPreview = error is ReadingDataError
                if requiresNewPreview, let expected = record?.scope,
                   expected != (await service.metadataImportScope()) { sourceScopeChanged = true }
                phase = .failed
                showError(ReaderMessages.error(error))
            }
        }
    }

    func sceneDidEnterBackground() {
        systemExecution.sceneDidEnterBackground()
        exportTask.sceneDidEnterBackground()
    }

    private func publishSystemProgress() {
        if #available(iOS 26, *), let task = systemExecution.background as? BGContinuedProcessingTask {
            if loading {
                let subtitle: String
                switch preparation {
                case .readingPackage:
                    subtitle = String(localized: "正在读取资料包", table: "MetadataExchange")
                case .matchingBooks(let count):
                    subtitle = String(localized: "正在匹配 \(count) 本书", table: "MetadataExchange")
                case .preparingBooks(let done, let count):
                    task.progress.totalUnitCount = Int64(count + 1) // Last unit publishes the ready preview.
                    task.progress.completedUnitCount = Int64(done)
                    subtitle = String(localized: "已准备 \(done) / \(count) 本", table: "MetadataExchange")
                case nil:
                    subtitle = phase == .receiving ? String(localized: "接收资料包", table: "MetadataExchange")
                        : String(localized: "准备预览", table: "MetadataExchange")
                }
                task.updateTitle(task.title, subtitle: subtitle)
                return
            }
            let saves = checkpoint?.writeIndices.count ?? 0
            let renames = checkpoint?.renameIndices.count ?? 0
            // Keep one final unit until the underlying operation really finishes.
            task.progress.totalUnitCount = Int64(max(1, saves + renames + 1))
            task.progress.completedUnitCount = Int64(phase == .renaming ? saves + completed : phase == .saving ? completed : 0)
            let subtitle = phase == .renaming
                ? String(localized: "已处理 \(completed) / \(total) 个改名", table: "MetadataExchange")
                : phase == .saving
                    ? String(localized: "已保存 \(completed) / \(total) 本", table: "MetadataExchange")
                    : String(localized: "准备预览", table: "MetadataExchange")
            task.updateTitle(task.title, subtitle: subtitle)
        }
    }

    func diagnosticFile() throws -> LibraryExport? {
        guard let diagnostics = preview?.diagnostics, !diagnostics.isEmpty else { return nil }
        return try LibraryExport { directory in
            let url = directory.appendingPathComponent("metadata-errors.jsonl")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
            let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
            for item in diagnostics {
                struct Diagnostic: Encodable {
                    let sourceLine: UInt64?, recordIndex: UInt64?
                    let code: String, field: String?, contentSha256: String?, message: String
                }
                try handle.write(contentsOf: encoder.encode(Diagnostic(sourceLine: item.sourceLine, recordIndex: item.recordIndex, code: item.code, field: item.field, contentSha256: item.contentSha256, message: item.message)))
                try handle.write(contentsOf: Data([10]))
            }
            return [url]
        }
    }
}

/// Shared platform execution for user-initiated metadata work. Each task keeps
/// its own run, so finishing one import/export never ends the other's claim.
@MainActor private final class MetadataSystemExecution {
    private final class Run {
        let id = UUID()
        let canAttach: @MainActor () -> Bool
        let didAttach: @MainActor () -> Void
        let didExpire: @MainActor (MetadataExchangeModel.PauseReason) -> Void
        var request: String?
        var background: BGTask?
        var assertion: UIBackgroundTaskIdentifier = .invalid

        init(canAttach: @escaping @MainActor () -> Bool, didAttach: @escaping @MainActor () -> Void,
             didExpire: @escaping @MainActor (MetadataExchangeModel.PauseReason) -> Void) {
            self.canAttach = canAttach
            self.didAttach = didAttach
            self.didExpire = didExpire
        }
    }

    private var run: Run?
    var background: BGTask? { run?.background }

    func begin(kind: String, title: String, subtitle: String,
               canAttach: @escaping @MainActor () -> Bool,
               didAttach: @escaping @MainActor () -> Void,
               didExpire: @escaping @MainActor (MetadataExchangeModel.PauseReason) -> Void) {
        guard run == nil else { return }
        let run = Run(canAttach: canAttach, didAttach: didAttach, didExpire: didExpire)
        self.run = run
        guard UIApplication.shared.applicationState != .background else { return }
        let id = run.id
        if #available(iOS 26, *) {
            let identifier = (Bundle.main.bundleIdentifier ?? "dev.moonread.Moonread") + "." + kind + ".continued." + id.uuidString
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
            request.strategy = .fail
            if BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil,
                launchHandler: FullIndexSystemCallback.launch { [weak self] task in
                    guard let self else { task.setTaskCompleted(success: false); return }
                    self.attach(task, id: id)
                }) {
                do { try BGTaskScheduler.shared.submit(request); run.request = identifier }
                catch { /* Foreground work can continue without system execution. */ }
            }
        } else {
            run.assertion = UIApplication.shared.beginBackgroundTask(withName: title) { [weak self] in
                self?.expire(id, reason: .expired)
            }
        }
    }

    private func attach(_ task: BGTask, id: UUID) {
        guard let run, run.id == id, run.request == task.identifier, run.background == nil, run.canAttach() else {
            task.setTaskCompleted(success: false); return
        }
        run.background = task
        task.expirationHandler = FullIndexSystemCallback.expiration { [weak self] in self?.expire(id, reason: .expired) }
        run.didAttach()
    }

    func sceneDidEnterBackground() {
        guard let run, run.background == nil, run.assertion == .invalid else { return }
        expire(run.id, reason: .unavailable)
    }

    private func expire(_ id: UUID, reason: MetadataExchangeModel.PauseReason) {
        guard let run, run.id == id else { return }
        run.didExpire(reason)
        // The owner keeps its worker and inputs until the operation returns.
        finish(success: false)
    }

    func finish(success: Bool) {
        guard let run else { return }
        self.run = nil
        if let task = run.background {
            task.expirationHandler = nil
            if #available(iOS 26, *), let continued = task as? BGContinuedProcessingTask, success {
                continued.progress.completedUnitCount = continued.progress.totalUnitCount
            }
            task.setTaskCompleted(success: success)
        } else if let request = run.request {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: request)
        }
        if run.assertion != .invalid { UIApplication.shared.endBackgroundTask(run.assertion) }
    }
}

@MainActor @Observable final class MetadataExportTask {
    enum Phase {
        case idle, running, completed, stopped, failed

        var title: LocalizedStringKey {
            switch self {
            case .idle: "导出小说信息"
            case .running: "正在导出"
            case .completed: "导出完成"
            case .stopped: "导出已停止"
            case .failed: "导出失败"
            }
        }

        var symbol: String {
            switch self {
            case .idle, .running: "square.and.arrow.up"
            case .completed: "checkmark.circle"
            case .stopped: "stop.circle"
            case .failed: "exclamationmark.circle"
            }
        }
    }

    private struct Request {
        let shelfID: String?
        let format: MetadataFormat
    }

    let service: AppDataService
    private let usesSystemExecution: Bool
    @ObservationIgnored private let systemExecution = MetadataSystemExecution()
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var request: Request?
    private(set) var phase: Phase = .idle
    private(set) var completed = 0
    private(set) var total: Int?
    private(set) var output: MetadataExportResult?
    private(set) var error: String?
    private(set) var stopReason: MetadataExchangeModel.PauseReason?
    private(set) var stopping = false
    var progressText: LocalizedStringKey {
        if stopping { return "正在停止导出。" }
        if let total, completed < total { return "正在导出 \(completed) / \(total) 本" }
        if total != nil { return "正在生成导出文件。" }
        return "正在准备导出…"
    }

    fileprivate init(service: AppDataService, usesSystemExecution: Bool) {
        self.service = service
        self.usesSystemExecution = usesSystemExecution
    }

    func start(shelfID: String?, format: MetadataFormat) {
        guard work == nil, phase == .idle else { return }
        launch(.init(shelfID: shelfID, format: format))
    }

    func retry() {
        guard work == nil, (phase == .stopped || phase == .failed), let request else { return }
        launch(request)
    }

    func cancel() {
        guard phase == .running, !stopping else { return }
        stopping = true
        work?.cancel()
    }

    func clear() {
        guard work == nil, phase != .running else { return }
        output = nil; error = nil; request = nil; stopReason = nil
        completed = 0; total = nil; phase = .idle
    }

    fileprivate func sceneDidEnterBackground() {
        systemExecution.sceneDidEnterBackground()
    }

    private func launch(_ request: Request) {
        self.request = request
        phase = .running; output = nil; error = nil
        completed = 0; total = nil; stopReason = nil
        if usesSystemExecution {
            systemExecution.begin(
                kind: "metadata-export",
                title: String(localized: "导出小说信息", table: "MetadataExchange"),
                subtitle: String(localized: "正在准备导出…", table: "MetadataExchange"),
                canAttach: { [weak self] in self?.stopping == false },
                didAttach: { [weak self] in self?.publishSystemProgress() },
                didExpire: { [weak self] reason in
                    guard let self, !self.stopping else { return }
                    self.stopReason = reason
                    self.cancel()
                })
        }
        work = Task {
            defer {
                systemExecution.finish(success: phase == .completed)
                work = nil
                stopping = false
            }
            do {
                let result = try await service.exportMetadata(shelfID: request.shelfID, format: request.format) { [weak self] done, count in
                    await self?.updateProgress(done, count)
                }
                try Task.checkCancellation()
                output = result
                phase = .completed
            } catch {
                if Task.isCancelled || error is CancellationError {
                    phase = .stopped
                } else {
                    self.error = ReaderMessages.error(error)
                    phase = .failed
                }
            }
        }
    }

    private func updateProgress(_ done: Int, _ count: Int) {
        guard !stopping else { return }
        completed = done
        total = count
        publishSystemProgress()
    }

    private func publishSystemProgress() {
        if #available(iOS 26, *), let task = systemExecution.background as? BGContinuedProcessingTask {
            // Keep one final unit for writing and publishing the output file.
            task.progress.totalUnitCount = Int64((total ?? 0) + 1)
            task.progress.completedUnitCount = Int64(completed)
            let subtitle = if let total, completed < total {
                String(localized: "正在导出 \(completed) / \(total) 本", table: "MetadataExchange")
            } else if total != nil {
                String(localized: "正在生成导出文件。", table: "MetadataExchange")
            } else {
                String(localized: "正在准备导出…", table: "MetadataExchange")
            }
            task.updateTitle(task.title, subtitle: subtitle)
        }
    }
}
