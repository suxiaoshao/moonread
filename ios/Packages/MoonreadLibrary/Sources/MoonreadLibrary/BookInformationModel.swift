import Combine
import Foundation
import MoonreadCoreBindings
import MoonreadData
import MoonreadDataTypes
import Observation

@MainActor @Observable
public final class BookInformationModel {
    private struct Preparation {
        let id: UUID
        let target: BookInformationTarget
        var step: BookInformationPreparationStep
        var progress: Double?
    }
    private enum EditPreparation {
        case idle, confirmingDownload(BookInformationTarget), preparing(Preparation), editing(BookMetadataDraft), failed(String)
    }

    private var resolution: BookDetailsResult?
    public private(set) var entry: LibraryEntry?
    public private(set) var chapters: [ChapterEntry] = []
    public private(set) var coverageError: String?
    private var preparation: EditPreparation = .idle
    private var actionError: String?
    private var task: Task<Void, Never>?

    public var details: BookDetails? { if case .identified(_, let details) = resolution { return details }; return nil }
    public var readableBook: BookInfo? {
        if case .pending(_, let body) = resolution { return body?.book }
        return details?.book
    }
    public var error: String? {
        get { if case .failed(let message) = preparation { return message }; return actionError }
        set { if case .failed = preparation { preparation = .idle }; actionError = newValue }
    }
    public var preparing: Bool { if case .preparing = preparation { return true }; return false }
    public var downloading: Bool { if case .preparing(let value) = preparation { return value.step == .downloading }; return false }
    public var progress: Double? { if case .preparing(let value) = preparation { return value.progress }; return nil }
    public var confirmDownload: Bool {
        get { if case .confirmingDownload = preparation { return true }; return false }
        set { if !newValue, case .confirmingDownload = preparation { preparation = .idle } }
    }
    public var draft: BookMetadataDraft? {
        get { if case .editing(let value) = preparation { return value }; return nil }
        set {
            if let newValue { preparation = .editing(newValue) }
            else if case .editing = preparation { preparation = .idle }
        }
    }
    public var canEdit: Bool { !preparing && (details != nil || entry != nil || readableBook != nil) }

    private var loadedIdentity: BookInformationTarget?
    private var requestedIdentity: BookInformationTarget?
    private var loadRevision = UUID()
    private var observingRevision: UUID?
    public private(set) var requestRevision = 0
    @ObservationIgnored private var accountChange: AnyCancellable?
    @ObservationIgnored private let source: BookInformationSource

    public init(source: BookInformationSource) {
        self.source = source
        accountChange = source.observeAccount { [weak self] in
            guard let self else { return }
            loadRevision = UUID(); observingRevision = nil
            clearInformation()
            requestRevision &+= 1
        }
    }

    public func contentSHA(for route: BookInformationTarget) -> String? {
        if case .record(.formal(let sha)) = route.target { return sha }
        guard matches(route) else { return nil }
        return details?.metadata.sha
    }
    public func matches(_ route: BookInformationTarget) -> Bool { loadedIdentity == route }
    private func clearInformation() {
        loadedIdentity = nil
        task?.cancel(); task = nil
        draft?.cancel()
        preparation = .idle
        entry = nil; resolution = nil; releaseCoverage(); error = nil
    }

    private func begin(_ identity: BookInformationTarget) -> UUID {
        let revision = UUID()
        loadRevision = revision
        if requestedIdentity != identity {
            clearInformation()
            requestedIdentity = identity
        }
        return revision
    }

    private func accepts(_ identity: BookInformationTarget, revision: UUID) -> Bool {
        loadRevision == revision && requestedIdentity == identity && !Task.isCancelled
    }

    private func publish(_ value: (LibraryEntry?, BookDetailsResult), identity: BookInformationTarget) {
        entry = value.0; resolution = value.1; loadedIdentity = identity
        if case .missing = value.1 { error = source.describeError(ReaderError.NotFound) }
        else { error = nil }
    }

    private func publishError(_ failure: Error) {
        if failure is UserSyncCompatibilityError {
            clearInformation()
        }
        error = source.describeError(failure)
    }

    public func retryInformation() { requestRevision &+= 1 }

    public func observe(_ route: BookInformationTarget) async {
        let identity = route, revision = begin(identity)
        observingRevision = revision
        defer { if observingRevision == revision { observingRevision = nil } }
        do {
            let updates = try await source.updates(route)
            for try await update in updates {
                guard accepts(identity, revision: revision) else { return }
                do { publish(try update.resolved(), identity: identity) }
                catch {
                    if case .missingSource = update { clearInformation() }
                    publishError(error)
                }
            }
        } catch is CancellationError { }
        catch { if accepts(identity, revision: revision) { publishError(error) } }
    }

    public func load(_ route: BookInformationTarget) async {
        let identity = route, revision = begin(identity)
        do {
            let value = try await source.read(route)
            guard accepts(identity, revision: revision) else { return }
            publish(value, identity: identity)
            if let readChapters = source.readChapters, let book = readableBook {
                let chapters = try await readChapters(book.id)
                guard accepts(identity, revision: revision) else { return }
                self.chapters = chapters
            } else { chapters = [] }
        } catch is CancellationError { }
        catch { if accepts(identity, revision: revision) { publishError(error) } }
    }

    public func releaseCoverage() { chapters = []; coverageError = nil }

    public func observeCoverage(bookID: String) async {
        do {
            try await source.observeCoverage(bookID, { [weak self] result in
                guard let self, readableBook?.id == bookID, !Task.isCancelled else { return }
                switch result {
                case .success(let outline): chapters = outline?.items ?? []; coverageError = nil
                case .failure(let error): coverageError = source.describeError(error)
                }
            })
        } catch is CancellationError { }
        catch { if readableBook?.id == bookID && !Task.isCancelled { coverageError = source.describeError(error) } }
    }

    public func edit(_ route: BookInformationTarget) {
        guard matches(route), canEdit else { return }
        if let details { preparation = .editing(source.makeDraft(details.metadata)) }
        else if entry?.needsDownload == true { preparation = .confirmingDownload(route) }
        else { prepareEditing(route) }
    }
    public func prepareEditing(_ route: BookInformationTarget) {
        guard matches(route), !preparing else { return }
        let context = Preparation(id: UUID(), target: route, step: entry?.needsDownload == true ? .downloading : .indexing)
        preparation = .preparing(context)
        task = Task { [self] in
            defer {
                if isPreparing(context) { preparation = .idle }
                if requestedIdentity == context.target, !preparing { task = nil }
            }
            do {
                let result = try await source.prepareMetadata(
                    route.fromReader ? nil : entry?.source, readableBook?.id
                ) { [weak self] step, progress in
                    self?.updatePreparation(context, step: step, progress: progress)
                }
                guard isPreparing(context), !Task.isCancelled,
                      case .identified(_, let details) = result else { return }
                resolution = result
                preparation = .editing(source.makeDraft(details.metadata))
            } catch is CancellationError { }
            catch { if isPreparing(context) { preparation = .failed(source.describeError(error)) } }
        }
    }
    private func isPreparing(_ context: Preparation) -> Bool {
        if case .preparing(let current) = preparation { return current.id == context.id }
        return false
    }
    private func updatePreparation(_ context: Preparation, step: BookInformationPreparationStep, progress: Double?) {
        guard case .preparing(var current) = preparation, current.id == context.id else { return }
        if step == .downloading, current.step != .downloading { return }
        current.step = step; current.progress = progress
        preparation = .preparing(current)
    }
    public func finishPreparationForDataDeletion() async {
        let current = task; current?.cancel(); await current?.value
    }
    public func cancelPreparation() { task?.cancel() }
    public func setStatus(_ status: BookReadingStatus) async {
        guard let base = details?.metadata, let identity = loadedIdentity else { return }
        var edited = base; edited.status = status
        do {
            try await source.saveMetadata(base, edited)
            if observingRevision == loadRevision { return }
            let next = try await source.details(identity.target)
            guard loadedIdentity == identity, !Task.isCancelled else { return }
            resolution = next
        } catch { if loadedIdentity == identity { self.error = source.describeError(error) } }
    }
}
