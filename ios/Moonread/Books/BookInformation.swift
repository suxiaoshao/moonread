import SwiftUI
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
    @ObservationIgnored private let service: AppDataService
    @ObservationIgnored private let readInformation: @MainActor (StatisticsRoute) async throws -> (LibraryEntry?, BookDetailsResult)
    @ObservationIgnored private let readChapters: @MainActor (String) async throws -> [ChapterEntry]
    init(service: AppDataService = .shared,
         readInformation: (@MainActor (StatisticsRoute) async throws -> (LibraryEntry?, BookDetailsResult))? = nil,
         readChapters: (@MainActor (String) async throws -> [ChapterEntry])? = nil) {
        self.service = service
        self.readInformation = readInformation ?? { try await Self.read($0, service: service) }
        self.readChapters = readChapters ?? { try await service.chapters($0).items }
    }
    private static func read(_ route: StatisticsRoute, service: AppDataService) async throws -> (LibraryEntry?, BookDetailsResult) {
        let details = try await service.bookDetails(route.target)
        let entry: LibraryEntry?
        if case .missing = details { entry = nil }
        else if let file = route.fileID { entry = try await service.libraryEntry(file) }
        else if !route.fromReader, case .identified(let identity, _) = details, case .associated = identity.body {
            entry = try await service.libraryEntries(nil).first { $0.readingIdentity == identity.key && !$0.directory }
        } else { entry = nil }
        return (entry, details)
    }
    func contentSHA(for route: StatisticsRoute) -> String? {
        if case .record(.formal(let sha)) = route.target { return sha }
        guard matches(route) else { return nil }
        return details?.metadata.sha
    }
    func matches(_ route: StatisticsRoute) -> Bool { loadedIdentity == Identity(route) }
    func load(_ route: StatisticsRoute) async {
        let identity = Identity(route), revision = UUID()
        loadRevision = revision
        if requestedIdentity != identity {
            requestedIdentity = identity; loadedIdentity = nil
            task?.cancel(); task = nil; preparation = .idle
            entry = nil; resolution = nil; chapters = []; error = nil
        }
        do {
            let (entry, details) = try await readInformation(route)
            guard loadRevision == revision, requestedIdentity == identity, !Task.isCancelled else { return }
            self.entry = entry; resolution = details; loadedIdentity = identity; error = nil
            if case .missing = details { error = ReaderMessages.error(ReaderError.NotFound); return }
            if let book = readableBook {
                let chapters = try await readChapters(book.id)
                guard loadRevision == revision, requestedIdentity == identity, !Task.isCancelled else { return }
                self.chapters = chapters
            } else { self.chapters = [] }
        } catch {
            guard loadRevision == revision, requestedIdentity == identity, !Task.isCancelled else { return }
            self.error = ReaderMessages.error(error)
            if error is UserSyncCompatibilityError { resolution = nil; draft = nil }
        }
    }

    func edit(_ route: StatisticsRoute) {
        guard matches(route), canEdit else { return }
        if let details { preparation = .editing(BookMetadataDraft(base: details.metadata)) }
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
                    if snapshot.phase == .complete {
                        let result = try await service.bookDetails(.cached(bookId: lease.id))
                        let details = try result.requireIdentified()
                        guard isPreparing(context), !Task.isCancelled else { return }
                        resolution = result
                        preparation = .editing(BookMetadataDraft(base: details.metadata))
                        break
                    }
                    if snapshot.phase == .failed { throw CocoaError(.fileReadCorruptFile) }
                    if snapshot.phase == .paused {
                        try Task.checkCancellation()
                        try await service.resumeImport(lease.id)
                    }
                    updatePreparation(context, step: .indexing,
                        progress: snapshot.sourceByteCount > 0 ? Double(snapshot.sourceBytesRead) / Double(snapshot.sourceByteCount) : nil)
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
    var choosingImage = false
    private var imageRequest = UUID()
    private var closed = false
    init(base: BookMetadata) { self.base = base; value = base }
    var changed: Bool { value != base }
    func image(_ data: Data) async {
        guard !closed else { return }
        let request = UUID(); imageRequest = request; choosingImage = true
        defer { if imageRequest == request { choosingImage = false } }
        do {
            let cover = try await AppDataService.shared.makeCover(data)
            guard !closed, imageRequest == request, !Task.isCancelled else { await AppDataService.shared.discardCoverDraft(cover); return }
            discardNewCover(); value.cover = cover
        } catch { if imageRequest == request { self.error = ReaderMessages.error(error) } }
    }
    func discardNewCover() {
        if let cover = value.cover, cover != base.cover { Task { await AppDataService.shared.discardCoverDraft(cover) } }
    }
    func removeCover() { imageRequest = UUID(); choosingImage = false; discardNewCover(); value.cover = nil }
    func cancel() { closed = true; imageRequest = UUID(); discardNewCover() }
}

struct BookMetadataEditor: View {
    @Bindable var draft: BookMetadataDraft
    var title = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    @State private var photo: PhotosPickerItem?
    @State private var filePicker = false
    @State private var discard = false
    @State private var newTag = ""
    @State private var suggestions: [String] = []
    @ViewBuilder private var coverActions: some View {
        PhotosPicker(selection: $photo, matching: .images) { Label("从照片选择", systemImage: "photo") }
            .buttonStyle(ThemedSecondaryButtonStyle()).disabled(draft.choosingImage)
        Button("从文件选择", systemImage: "folder") { filePicker = true }
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
                    ForEach(draft.value.tags, id: \.self) { tag in
                        HStack {
                            Text(verbatim: tag); Spacer()
                            Button("移除标签", systemImage: "minus.circle") { draft.value.tags.removeAll { $0 == tag } }
                                .labelStyle(.iconOnly).accessibilityLabel(String(localized: "移除标签 \(tag)"))
                        }
                    }
                    HStack {
                        TextField("添加标签", text: $newTag).focused($focused).keyboardInputRegion().onSubmit(addTag)
                            .accessibilityIdentifier("bookTagField")
                        Button("添加", systemImage: "plus", action: addTag).labelStyle(.iconOnly)
                            .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !suggestions.isEmpty {
                        Menu("已有标签") {
                            ForEach(suggestions.filter { !draft.value.tags.contains($0) }, id: \.self) { tag in
                                Button(tag) { draft.value.tags.append(tag) }
                            }
                        }
                    }
                }.listRowBackground(Color(uiColor: theme.surface))
                Section("简介") {
                    TextField("简介", text: $draft.value.synopsis, axis: .vertical).lineLimit(4...12)
                        .focused($focused).keyboardInputRegion().accessibilityIdentifier("bookSynopsisField")
                }.listRowBackground(Color(uiColor: theme.surface))
            }.disabled(draft.saving).themedPage().scrollDismissesKeyboard(.interactively).dismissKeyboardOnOutsideTap($focused)
                .navigationTitle("编辑小说信息").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        SystemToolbarButton("取消", role: .cancel) { if draft.changed { discard = true } else { dismiss() } }
                            .disabled(draft.saving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        SystemToolbarButton("保存", role: .confirm) {
                            addTag(); focused = false; draft.saving = true
                            Task {
                                defer { draft.saving = false }
                                do { try await AppDataService.shared.saveMetadata(base: draft.base, edited: draft.value); dismiss() }
                                catch { draft.error = ReaderMessages.error(error) }
                            }
                        }.disabled(draft.saving || draft.choosingImage).accessibilityIdentifier("saveBookMetadata")
                    }
                }
                .alert("放弃未保存的修改？", isPresented: $discard) {
                    Button("放弃修改", role: .destructive) { dismiss() }
                    Button("取消", role: .cancel) {}
                }
                .fileImporter(isPresented: $filePicker, allowedContentTypes: [.image]) { result in
                    Task {
                        do {
                            let url = try result.get(), scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            let data = try await Task.detached { try Data(contentsOf: url) }.value
                            await draft.image(data)
                        } catch { draft.error = ReaderMessages.error(error) }
                    }
                }
                .task(id: photo) {
                    guard let photo else { return }
                    do { if let data = try await photo.loadTransferable(type: Data.self) { await draft.image(data) } }
                    catch { draft.error = ReaderMessages.error(error) }
                }
                .task { suggestions = (try? await AppDataService.shared.metadataOptions(shelfID: nil).tags) ?? [] }
                .alert("暂时无法完成", isPresented: Binding(get: { draft.error != nil }, set: { if !$0 { draft.error = nil } })) {
                    Button("知道了", role: .cancel) { draft.error = nil }
                } message: { Text(draft.error ?? "") }
        }.interactiveDismissDisabled(draft.changed || draft.saving || draft.choosingImage)
            .onDisappear { draft.cancel() }
    }
    private func addTag() {
        let value = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, !draft.value.tags.contains(value) { draft.value.tags.append(value) }
        newTag = ""
    }
}

struct BookInformationSections: View {
    let model: BookInformationModel
    let target: StatisticsRoute
    let library: LibraryModel?
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    @State private var expandedSynopsis = false
    /// Search entered from an open book's details is pushed above the suspended reader.
    @State private var readerSearch: AppSearchScope?
    @Environment(\.returnToReading) private var returnToReading
    /// Reading is the page's main task: one full-width prominent action under the book identity.
    @ViewBuilder private var primaryAction: some View {
        if target.fromReader {
            Button { dismiss() } label: { Text("返回阅读").frame(maxWidth: .infinity) }
                .buttonStyle(ThemedProminentButtonStyle()).controlSize(.large)
        } else if let entry = model.entry, let library {
            Button { library.open(entry) } label: { Text(entry.lastRead == 0 ? "开始阅读" : "继续阅读").frame(maxWidth: .infinity) }
                .buttonStyle(ThemedProminentButtonStyle()).controlSize(.large)
                .disabled(library.openingFileID != nil)
        } else if let book = model.readableBook, let library {
            Button { library.path.append(.reader(OpeningRequest(target: .book(book.id)))) } label: { Text("继续阅读").frame(maxWidth: .infinity) }
                .buttonStyle(ThemedProminentButtonStyle()).controlSize(.large)
        }
    }
    /// Author and tag start a contextual search on this stack; Back returns here.
    private func search(_ token: AppSearchSeed) {
        guard let library else { return }
        let scope = AppSearchScope(seeds: [token])
        if target.fromReader { readerSearch = scope } else { library.path.append(.search(scope)) }
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
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: synopsis).font(.subheadline).lineLimit(expandedSynopsis ? nil : 3)
                        .foregroundStyle(Color(uiColor: theme.secondary))
                    if synopsis.count > 100 || synopsis.filter({ $0 == "\n" }).count > 2 {
                        Button(expandedSynopsis ? "收起" : "展开简介") { expandedSynopsis.toggle() }
                            .font(.caption).frame(minHeight: LayoutTokens.hit)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("我的阅读").font(.headline).foregroundStyle(Color(uiColor: theme.secondary))
                readingCard
            }.padding(.top, 8).id("myReading")
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
                    ProgressView(value: Double(position), total: Double(bytes)).accessibilityLabel("全书位置")
                    ViewThatFits(in: .horizontal) {
                        HStack { positionLabel(position, bytes); Spacer(); coverageLabel(position) }
                        VStack(alignment: .leading, spacing: 6) { positionLabel(position, bytes); coverageLabel(position) }
                    }.font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                } else { coverageLabel(position).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary)) }
            }
            if let error = model.error, model.details == nil {
                Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive))
                Button("重试") { Task { await model.load(target) } }
            } else if model.matches(target), model.contentSHA(for: target) == nil {
                Label("正文身份尚未确定", systemImage: "info.circle").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
            } else if model.details == nil { ProgressView() }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
    }
    private func positionLabel(_ position: UInt64, _ bytes: UInt64) -> some View {
        Text("读到全书 \((Double(position) / Double(max(1, bytes))).formatted(.percent.precision(.fractionLength(0))))")
    }
    private func coverageLabel(_ position: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("本章覆盖 \(model.chapters.last(where: { $0.startUtf8 <= position })?.coverageLabel(readingPrefix: false) ?? "—")")
            if model.chapters.isEmpty { Text("本章覆盖尚未计算完成，不影响继续阅读。").font(.caption) }
        }
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
                    manager.deleting = [key]
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
            .alert("暂时无法完成", isPresented: Binding(get: { manager.error != nil }, set: { if !$0 { manager.error = nil } })) {
                Button("知道了", role: .cancel) { manager.error = nil }
            } message: { Text(manager.error ?? "") }
    }
}
