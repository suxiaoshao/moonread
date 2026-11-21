import SwiftUI
import Combine
import PhotosUI
import UniformTypeIdentifiers

@MainActor @Observable
final class BookInformationModel {
    struct Identity: Hashable {
        let target: BookTarget
        let origin: StatisticsRoute.Origin
        init(_ route: StatisticsRoute) { target = route.target; origin = route.origin }
    }
    struct Preparation {
        enum Step { case downloading, indexing }
        let id: UUID
        let target: Identity
        var step: Step
        var progress: Double?
    }
    enum EditPreparation {
        case idle, confirmingDownload(StatisticsRoute), preparing(Preparation), editing(BookMetadataDraft), failed(String)
    }

    private(set) var resolution: BookDetailsResult?
    private(set) var entry: LibraryEntry?
    private(set) var chapters: [ChapterEntry] = []
    private(set) var coverageError: String?
    private(set) var preparation: EditPreparation = .idle
    private var actionError: String?
    private var task: Task<Void, Never>?

    var details: BookDetails? { if case .identified(_, let details) = resolution { return details }; return nil }
    var readableBook: BookInfo? {
        if case .pending(_, let body) = resolution { return body?.book }
        return details?.book
    }
    var error: String? {
        get { if case .failed(let message) = preparation { return message }; return actionError }
        set { if case .failed = preparation { preparation = .idle }; actionError = newValue }
    }
    var preparing: Bool { if case .preparing = preparation { return true }; return false }
    var downloading: Bool { if case .preparing(let value) = preparation { return value.step == .downloading }; return false }
    var progress: Double? { if case .preparing(let value) = preparation { return value.progress }; return nil }
    var confirmDownload: Bool {
        get { if case .confirmingDownload = preparation { return true }; return false }
        set { if !newValue, case .confirmingDownload = preparation { preparation = .idle } }
    }
    var draft: BookMetadataDraft? {
        get { if case .editing(let value) = preparation { return value }; return nil }
        set {
            if let newValue { preparation = .editing(newValue) }
            else if case .editing = preparation { preparation = .idle }
        }
    }
    var canEdit: Bool { !preparing && (details != nil || entry != nil || readableBook != nil) }

    private(set) var loadedIdentity: Identity?
    private var requestedIdentity: Identity?
    private var loadRevision = UUID()
    private var observingRevision: UUID?
    private(set) var requestRevision = 0
    @ObservationIgnored private var accountChange: AnyCancellable?
    @ObservationIgnored private let service: AppDataService
    @ObservationIgnored private let readInformation: @MainActor (StatisticsRoute) async throws -> (LibraryEntry?, BookDetailsResult)
    // Coverage is a separate §13.5 consumer. The boundary remains usable
    // independently of the information read (including existing test fixtures).
    @ObservationIgnored private let readChapters: (@MainActor (String) async throws -> [ChapterEntry])?
    init(service: AppDataService = .shared,
         readInformation: (@MainActor (StatisticsRoute) async throws -> (LibraryEntry?, BookDetailsResult))? = nil,
         readChapters: (@MainActor (String) async throws -> [ChapterEntry])? = nil) {
        self.service = service
        self.readInformation = readInformation ?? { try await Self.read($0, service: service) }
        self.readChapters = readChapters
        accountChange = MainActorNotifications.observe(.readingContinuationInvalidated, object: service) { [weak self] in
            guard let self else { return }
            loadRevision = UUID(); observingRevision = nil
            clearInformation()
            requestRevision &+= 1
        }
    }
    private static func read(_ route: StatisticsRoute, service: AppDataService) async throws -> (LibraryEntry?, BookDetailsResult) {
        try await service.bookInformation(route.target, fileID: route.fileID, includeRecordSource: !route.fromReader)
    }
    func contentSHA(for route: StatisticsRoute) -> String? {
        if case .record(.formal(let sha)) = route.target { return sha }
        guard matches(route) else { return nil }
        return details?.metadata.sha
    }
    func matches(_ route: StatisticsRoute) -> Bool { loadedIdentity == Identity(route) }
    private func clearInformation() {
        loadedIdentity = nil
        task?.cancel(); task = nil
        draft?.cancel()
        preparation = .idle
        entry = nil; resolution = nil; releaseCoverage(); error = nil
    }

    private func begin(_ identity: Identity) -> UUID {
        let revision = UUID()
        loadRevision = revision
        if requestedIdentity != identity {
            clearInformation()
            requestedIdentity = identity
        }
        return revision
    }

    private func accepts(_ identity: Identity, revision: UUID) -> Bool {
        loadRevision == revision && requestedIdentity == identity && !Task.isCancelled
    }

    private func publish(_ value: (LibraryEntry?, BookDetailsResult), identity: Identity) {
        entry = value.0; resolution = value.1; loadedIdentity = identity
        if case .missing = value.1 { error = ReaderMessages.error(ReaderError.NotFound) }
        else { error = nil }
    }

    private func publishError(_ failure: Error) {
        if failure is UserSyncCompatibilityError {
            clearInformation()
        }
        error = ReaderMessages.error(failure)
    }

    func retryInformation() { requestRevision &+= 1 }

    func observe(_ route: StatisticsRoute) async {
        let identity = Identity(route), revision = begin(identity)
        observingRevision = revision
        defer { if observingRevision == revision { observingRevision = nil } }
        do {
            let updates = try await service.bookInformationUpdates(route.target, fileID: route.fileID,
                                                                  includeRecordSource: !route.fromReader)
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

    func load(_ route: StatisticsRoute) async {
        let identity = Identity(route), revision = begin(identity)
        do {
            let value = try await readInformation(route)
            guard accepts(identity, revision: revision) else { return }
            publish(value, identity: identity)
            if let readChapters, let book = readableBook {
                let chapters = try await readChapters(book.id)
                guard accepts(identity, revision: revision) else { return }
                self.chapters = chapters
            } else { chapters = [] }
        } catch is CancellationError { }
        catch { if accepts(identity, revision: revision) { publishError(error) } }
    }

    func releaseCoverage() { chapters = []; coverageError = nil }

    func observeCoverage(bookID: String) async {
        do {
            try await service.observeChapterCoverage(bookID) { [weak self] result in
                guard let self, readableBook?.id == bookID, !Task.isCancelled else { return }
                switch result {
                case .success(let outline): chapters = outline?.items ?? []; coverageError = nil
                case .failure(let error): coverageError = ReaderMessages.error(error)
                }
            }
        } catch is CancellationError { }
        catch { if readableBook?.id == bookID && !Task.isCancelled { coverageError = ReaderMessages.error(error) } }
    }

    func edit(_ route: StatisticsRoute) {
        guard matches(route), canEdit else { return }
        if let details { preparation = .editing(BookMetadataDraft(base: details.metadata, service: service)) }
        else if entry?.needsDownload == true { preparation = .confirmingDownload(route) }
        else { prepareEditing(route) }
    }
    func prepareEditing(_ route: StatisticsRoute) {
        guard matches(route), !preparing else { return }
        let context = Preparation(id: UUID(), target: Identity(route), step: entry?.needsDownload == true ? .downloading : .indexing)
        preparation = .preparing(context)
        task = Task { [self] in
            defer {
                if isPreparing(context) { preparation = .idle }
                if requestedIdentity == context.target, !preparing { task = nil }
            }
            do {
                let lease: ReadingLease
                if let entry, !route.fromReader {
                    try await service.prepareSourceFile(entry.source) { [weak self] progress in
                        Task { @MainActor in self?.updatePreparation(context, step: .downloading, progress: progress) }
                    }
                    try Task.checkCancellation()
                    updatePreparation(context, step: .indexing, progress: nil)
                    lease = try await service.openSourceFile(entry.source)
                } else if let id = readableBook?.id {
                    lease = try await service.openReading(id)
                } else { throw ReaderError.NotFound }
                while true {
                    try Task.checkCancellation()
                    let snapshot = try await service.snapshot(lease.id)
                    if snapshot.preparation.isComplete {
                        let result = try await service.bookDetails(.cached(bookId: lease.id))
                        let details = try result.requireIdentified()
                        guard isPreparing(context), !Task.isCancelled else { return }
                        resolution = result
                        preparation = .editing(BookMetadataDraft(base: details.metadata, service: service))
                        break
                    }
                    if snapshot.preparation.isFailed { throw CocoaError(.fileReadCorruptFile) }
                    if snapshot.preparation.isPaused {
                        try Task.checkCancellation()
                        try await service.resumeImport(lease.id)
                    }
                    updatePreparation(context, step: .indexing,
                        progress: snapshot.byteProgress.total > 0 ? Double(snapshot.byteProgress.read) / Double(snapshot.byteProgress.total) : nil)
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch is CancellationError { }
            catch { if isPreparing(context) { preparation = .failed(ReaderMessages.error(error)) } }
        }
    }
    private func isPreparing(_ context: Preparation) -> Bool {
        if case .preparing(let current) = preparation { return current.id == context.id }
        return false
    }
    private func updatePreparation(_ context: Preparation, step: Preparation.Step, progress: Double?) {
        guard case .preparing(var current) = preparation, current.id == context.id else { return }
        if step == .downloading, current.step != .downloading { return }
        current.step = step; current.progress = progress
        preparation = .preparing(current)
    }
    func finishPreparationForDataDeletion() async {
        let current = task; current?.cancel(); await current?.value
    }
    func cancelPreparation() { task?.cancel() }
    func setStatus(_ status: BookReadingStatus) async {
        guard let base = details?.metadata, let identity = loadedIdentity else { return }
        var edited = base; edited.status = status
        do {
            try await service.saveMetadata(base: base, edited: edited)
            if observingRevision == loadRevision { return }
            let next = try await service.bookDetails(identity.target)
            guard loadedIdentity == identity, !Task.isCancelled else { return }
            resolution = next
        } catch { if loadedIdentity == identity { self.error = ReaderMessages.error(error) } }
    }
}

@MainActor @Observable
final class BookMetadataDraft: Identifiable {
    let id = UUID()
    let base: BookMetadata
    var value: BookMetadata
    var error: String?
    var saving = false
    private(set) var choosingImage = false
    var presentsPhotoPicker = false
    var presentsFilePicker = false
    let service: AppDataService
    private var imageRequest = UUID()
    @ObservationIgnored private var imageTask: Task<Void, Never>?
    private var closed = false
    init(base: BookMetadata, service: AppDataService = .shared) {
        self.base = base; value = base; self.service = service
    }
    var changed: Bool { value != base }
    var blocksInteractiveDismissal: Bool {
        !closed && (changed || saving || choosingImage || presentsPhotoPicker || presentsFilePicker)
    }
    enum LeaveAction { case close, confirmDiscard }
    func requestLeave() -> LeaveAction { changed ? .confirmDiscard : .close }

    @discardableResult
    func chooseImage(_ read: @escaping @Sendable () async throws -> Data?) -> Task<Void, Never>? {
        guard !closed, !saving else { return nil }
        imageTask?.cancel()
        let request = UUID(); imageRequest = request; choosingImage = true
        let task = Task {
            defer { if imageRequest == request { choosingImage = false; imageTask = nil } }
            do {
                guard let data = try await read(), !closed, imageRequest == request, !Task.isCancelled else { return }
                let cover = try await service.makeCover(data)
                guard !closed, imageRequest == request, !Task.isCancelled else { await service.discardCoverDraft(cover); return }
                discardNewCover(); value.cover = cover
            } catch is CancellationError { }
            catch { if imageRequest == request { self.error = ReaderMessages.error(error) } }
        }
        imageTask = task
        return task
    }
    @discardableResult private func discardNewCover() -> Task<Void, Never>? {
        guard let cover = value.cover, cover != base.cover else { return nil }
        return Task { [service] in await service.discardCoverDraft(cover) }
    }
    private func stopChoosingImage() {
        imageRequest = UUID(); imageTask?.cancel(); imageTask = nil; choosingImage = false
    }
    func removeCover() { stopChoosingImage(); discardNewCover(); value.cover = nil }
    @discardableResult func cancel() -> Task<Void, Never>? {
        guard !closed else { return nil }
        closed = true; stopChoosingImage()
        return discardNewCover()
    }
}

struct BookMetadataEditor: View {
    @Bindable var draft: BookMetadataDraft
    var title = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    @State private var photo: PhotosPickerItem?
    @State private var discard = false
    @ViewBuilder private var coverActions: some View {
        Button("从照片选择", systemImage: "photo") { draft.presentsPhotoPicker = true }
            .buttonStyle(ThemedSecondaryButtonStyle()).disabled(draft.choosingImage)
        Button("从文件选择", systemImage: "folder") { draft.presentsFilePicker = true }
            .buttonStyle(ThemedSecondaryButtonStyle()).disabled(draft.choosingImage)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 16) {
                        BookCoverView(title: title, cover: draft.value.cover, contentSHA256: draft.value.sha, author: draft.value.author).frame(width: 112, height: 160)
                            .overlay { if draft.choosingImage { ProgressView("正在处理图片").padding(8).background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 12)) } }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) { coverActions }
                            VStack(spacing: 12) { coverActions }
                        }
                        if draft.value.cover != nil {
                            Menu {
                                Button("移除封面", systemImage: "trash", role: .destructive) { draft.removeCover() }
                            } label: { Label("更多", systemImage: "ellipsis") }
                                .disabled(draft.choosingImage).accessibilityIdentifier("coverMore")
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                } header: { Text("封面") }
                .listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                Section("作者") {
                    TextField("作者", text: $draft.value.author).focused($focused).keyboardInputRegion()
                        .accessibilityIdentifier("bookAuthorField")
                }.listRowBackground(Color(uiColor: theme.surface))
                Section("标签") {
                    NavigationLink {
                        BookTagPicker(service: draft.service, purpose: .metadata, selection: $draft.value.tags) {
                            EmptyView()
                        } footer: {
                            EmptyView()
                        }
                    } label: {
                        tagSummary
                    }
                    .accessibilityIdentifier("editBookTags")
                }.listRowBackground(Color(uiColor: theme.surface))
                Section("简介") {
                    TextField("简介", text: $draft.value.synopsis, axis: .vertical).lineLimit(4...12)
                        .focused($focused).keyboardInputRegion().accessibilityIdentifier("bookSynopsisField")
                }.listRowBackground(Color(uiColor: theme.surface))
            }.disabled(draft.saving).themedPage().scrollDismissesKeyboard(.interactively).dismissKeyboardOnOutsideTap($focused)
                .navigationTitle("编辑小说信息").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        SystemToolbarButton("取消", role: .cancel) {
                            switch draft.requestLeave() {
                            case .close: dismiss()
                            case .confirmDiscard: discard = true
                            }
                        }
                            .disabled(draft.saving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        SystemToolbarButton("保存", role: .confirm) {
                            focused = false; draft.saving = true
                            Task {
                                defer { draft.saving = false }
                                do { try await draft.service.saveMetadata(base: draft.base, edited: draft.value); dismiss() }
                                catch { draft.error = ReaderMessages.error(error) }
                            }
                        }.disabled(draft.saving || draft.choosingImage).accessibilityIdentifier("saveBookMetadata")
                    }
                }
                .alert("放弃未保存的修改？", isPresented: $discard) {
                    Button("放弃修改", role: .destructive) { draft.cancel(); dismiss() }
                    Button("取消", role: .cancel) {}
                }
                .photosPicker(isPresented: $draft.presentsPhotoPicker, selection: Binding(get: { photo }, set: { item in
                    photo = item
                    if let item { draft.chooseImage { try await item.loadTransferable(type: Data.self) } }
                }), matching: .images)
                .fileImporter(isPresented: $draft.presentsFilePicker, allowedContentTypes: [.image]) { result in
                    draft.chooseImage {
                        let url = try result.get(), scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        return try await Task.detached { try Data(contentsOf: url) }.value
                    }
                }
                .alert("暂时无法完成", isPresented: Binding(get: { draft.error != nil }, set: { if !$0 { draft.error = nil } })) {
                    Button("知道了", role: .cancel) { draft.error = nil }
                } message: { Text(draft.error ?? "") }
        }.interactiveDismissDisabled(draft.blocksInteractiveDismissal)
            .onDisappear { draft.cancel() }
    }
    @ViewBuilder private var tagSummary: some View {
        let tags = draft.value.tags
        if tags.isEmpty {
            Text("选择标签").foregroundStyle(Color(uiColor: theme.secondary))
        } else {
            HStack(spacing: LayoutTokens.compact) {
                ForEach(tags.prefix(2), id: \.self) { tag in
                    BookTagCapsule(name: tag, style: .summary)
                }
                if tags.count > 2 {
                    Text("+\(tags.count - 2)").font(.subheadline)
                        .foregroundStyle(Color(uiColor: theme.secondary))
                        .fixedSize()
                }
            }
            .accessibilityLabel("标签")
            .accessibilityValue(tags.joined(separator: "、"))
        }
    }
}

struct BookInformationSections: View {
    let model: BookInformationModel
    let target: StatisticsRoute
    let library: LibraryModel?
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    /// Search entered from an open book's details is pushed above the suspended reader.
    @State private var readerSearch: AppSearchScope?
    @Environment(\.returnToReading) private var returnToReading
    /// Reading is the page's main task: one full-width prominent action under the book identity.
    @ViewBuilder private var primaryAction: some View {
        if target.fromReader {
            Button { dismiss() } label: { Text("返回阅读").frame(maxWidth: .infinity) }
                .buttonStyle(ThemedProminentButtonStyle()).controlSize(.large)
        } else if let entry = model.entry, let library {
            Button {
                let metadata = model.details?.metadata
                library.open(entry.withMetadata(metadata?.sha == entry.readingIdentity?.formalSHA256 ? metadata : nil))
            } label: { Text(entry.lastRead == 0 ? "开始阅读" : "继续阅读").frame(maxWidth: .infinity) }
                .buttonStyle(ThemedProminentButtonStyle()).controlSize(.large)
        } else if let book = model.readableBook, let library {
            Button { library.shell.path.append(.reader(OpeningRequest(target: .book(book.id)))) } label: { Text("继续阅读").frame(maxWidth: .infinity) }
                .buttonStyle(ThemedProminentButtonStyle()).controlSize(.large)
        }
    }
    /// Author and tag start a contextual search on this stack; Back returns here.
    private func search(_ token: AppSearchSeed) {
        guard let library else { return }
        let scope = AppSearchScope(seeds: [token])
        if target.fromReader { readerSearch = scope } else { library.shell.path.append(.search(scope)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                BookCoverView(title: model.entry?.title ?? target.title, cover: model.details?.metadata.cover, contentSHA256: model.details?.metadata.sha, author: model.details?.metadata.author)
                    .frame(width: 64, height: 90).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: model.entry?.title ?? target.title)
                        .font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { author; bookCounts }
                        VStack(alignment: .leading, spacing: 4) { author; bookCounts }
                    }.font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                }
            }.accessibilityIdentifier("bookInformationHeader")
            primaryAction
            if let tags = model.details?.metadata.tags, !tags.isEmpty {
                AIFlowLayout(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        Button(tag) { search(.tag(tag)) }
                            .font(.subheadline).buttonStyle(.bordered)
                            .disabled(library == nil)
                    }
                }
            }
            if let synopsis = model.details?.metadata.synopsis, !synopsis.isEmpty {
                BookSynopsis(synopsis: synopsis).id(synopsis)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("我的阅读").font(.headline).foregroundStyle(Color(uiColor: theme.secondary))
                readingCard
            }.id("myReading")
        }.frame(maxWidth: .infinity, alignment: .leading).id("bookInformation")
        .navigationDestination(item: $readerSearch) { scope in
            if let library {
                ReaderContextSearch(model: library, scope: scope,
                                    isOpenBook: { entry in entry.id == target.fileID || (model.contentSHA(for: target) != nil && entry.readingKey == model.contentSHA(for: target)) },
                                    returnToBook: { if let returnToReading { returnToReading() } else { dismiss() } })
            }
        }
    }
    @ViewBuilder private var author: some View {
        if let author = model.details?.metadata.author, !author.isEmpty {
            if library != nil {
                Button(author) { search(.author(author)) }.buttonStyle(.plain)
            } else { Text(verbatim: author) }
        }
    }
    @ViewBuilder private var bookCounts: some View {
        if let body = model.details?.body, body.wordCount > 0 {
            Text("\(body.wordCount) 字 · \(body.chapterCount) 章")
        }
    }
    private var readingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let details = model.details {
                let position = model.entry?.positionUtf8 ?? details.book?.positionUtf8 ?? 0
                let bytes = model.entry?.byteCount ?? details.book?.byteCount ?? 0
                HStack(alignment: .top, spacing: 12) {
                    if let chapter = details.currentChapter { Text(verbatim: chapter).font(.headline).fixedSize(horizontal: false, vertical: true) }
                    Spacer(minLength: 0)
                    Picker("阅读状态", selection: Binding(get: { details.metadata.status }, set: { value in Task { await model.setStatus(value) } })) {
                        if case .other = details.metadata.status { Text(details.metadata.status.label).tag(details.metadata.status) }
                        if details.metadata.status == .unread { Text("未读").tag(BookReadingStatus.unread) }
                        ForEach([BookReadingStatus.reading, .finished, .paused], id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.menu).labelsHidden().accessibilityIdentifier("bookReadingStatus")
                }
                if bytes > 0 {
                    let fraction = ReadingProgress.fraction(position, of: bytes)
                    let positionLabel = Text("读到全书 \(fraction.formatted(.percent.precision(.fractionLength(0))))")
                    ProgressView(value: fraction).accessibilityLabel("全书位置")
                    ViewThatFits(in: .horizontal) {
                        HStack { positionLabel; Spacer(); coverageLabel(position) }
                        VStack(alignment: .leading, spacing: 6) { positionLabel; coverageLabel(position) }
                    }.font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                } else { coverageLabel(position).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary)) }
            }
            if let error = model.error, model.details == nil {
                Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive))
                Button("重试") { model.retryInformation() }
            } else if model.matches(target), model.contentSHA(for: target) == nil {
                Label("正文身份尚未确定", systemImage: "info.circle").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
            } else if model.details == nil { ProgressView() }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
            .task(id: model.details == nil ? nil : model.readableBook?.id) {
                model.releaseCoverage()
                if model.details != nil, let id = model.readableBook?.id { await model.observeCoverage(bookID: id) }
            }
            .onDisappear { model.releaseCoverage() }
    }
    private func coverageLabel(_ position: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("本章覆盖 \(model.chapters.last(where: { $0.startUtf8 <= position })?.coverageLabel(readingPrefix: false) ?? "—")")
            if let error = model.coverageError { Text(verbatim: error).font(.caption) }
            else if model.chapters.isEmpty { Text("本章覆盖尚未计算完成，不影响继续阅读。").font(.caption) }
        }
    }
}

private struct BookSynopsis: View {
    let synopsis: String
    @Environment(\.theme) private var theme
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var previewHeight: CGFloat = 0
    private var overflows: Bool { fullHeight > previewHeight + 0.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if overflows {
                DisclosureGroup(isExpanded: $expanded) {
                    EmptyView()
                } label: {
                    Text("简介").frame(minHeight: LayoutTokens.hit, alignment: .leading)
                }
            }
            synopsisText(limit: overflows && expanded ? nil : 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                synopsisText()
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { fullHeight = $0 }
                synopsisText(limit: 3)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { previewHeight = $0 }
            }.hidden().accessibilityHidden(true)
        }
    }

    private func synopsisText(limit: Int? = nil) -> some View {
        Text(verbatim: synopsis).font(.subheadline).lineLimit(limit)
            .foregroundStyle(Color(uiColor: theme.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BookReadingDataClearSection: View {
    @Environment(\.theme) private var theme
    let book: BookInformationModel
    let target: StatisticsRoute
    let key: String
    @Bindable var manager: DataManagementModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(role: .destructive) {
                Task {
                    if !target.fromReader { await book.finishPreparationForDataDeletion() }
                    await manager.load()
                    manager.requestDelete([key])
                }
            } label: {
                Text("清除本书阅读数据").frame(maxWidth: .infinity)
            }
                .buttonStyle(.bordered).tint(Color(uiColor: theme.destructive)).foregroundStyle(Color(uiColor: theme.destructive))
                .disabled(manager.busy).accessibilityIdentifier("clearBookReadingData")
            Text("不删除小说文件。删除会随阅读数据同步到其他设备。").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
            if let message = manager.message { Text(verbatim: message).font(.footnote) }
        }.padding(.top, 8)
            .modifier(ReadingDataDeletionPrompt(model: manager))
            .onChange(of: manager.busy) { _, busy in if !busy { Task { await book.load(target) } } }
            .alert("暂时无法完成", isPresented: Binding(get: { manager.error != nil }, set: { if !$0 { manager.clearError() } })) {
                Button("知道了", role: .cancel) { manager.clearError() }
            } message: { Text(manager.error ?? "") }
    }
}
