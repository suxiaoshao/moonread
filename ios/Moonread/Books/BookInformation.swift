import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

@MainActor @Observable
final class BookInformationModel {
    var details: BookDetails?
    var entry: LibraryEntry?
    var chapters: [ChapterEntry] = []
    var error: String?
    var preparing = false
    var downloading = false
    var progress: Double?
    var confirmDownload = false
    private enum PreparationStep { case running, paused, resumeRequested }
    private var preparationStep = PreparationStep.running
    var preparationPaused: Bool { preparationStep == .paused }
    var draft: BookMetadataDraft?
    private var task: Task<Void, Never>?
    private var lease: ReadingLease?

    struct Identity: Hashable {
        let fileID: String?
        let bookID: String?
        let key: String?
        let fromReader: Bool
        init(_ target: StatisticsRoute) {
            fileID = target.fileID; bookID = target.bookID; key = target.key; fromReader = target.fromReader
        }
    }
    private(set) var loadedIdentity: Identity?
    private var requestedIdentity: Identity?
    private var loadRevision = UUID()
    @ObservationIgnored private let service: ReaderService
    @ObservationIgnored private let readInformation: @MainActor (StatisticsRoute) async throws -> (LibraryEntry?, BookDetails)
    @ObservationIgnored private let readChapters: @MainActor (String) async throws -> [ChapterEntry]
    init(service: ReaderService = .shared,
         readInformation: (@MainActor (StatisticsRoute) async throws -> (LibraryEntry?, BookDetails))? = nil,
         readChapters: (@MainActor (String) async throws -> [ChapterEntry])? = nil) {
        self.service = service
        self.readInformation = readInformation ?? { try await Self.read($0, service: service) }
        self.readChapters = readChapters ?? { try await service.chapters($0).items }
    }
    private static func read(_ target: StatisticsRoute, service: ReaderService) async throws -> (LibraryEntry?, BookDetails) {
        let entry: LibraryEntry?
        if let file = target.fileID { entry = try await service.libraryEntry(file) }
        else if let id = target.bookID, !target.fromReader {
            entry = try await service.libraryEntries(nil).first { $0.bookId == id && !$0.directory }
        } else { entry = nil }
        let details = try await service.details(bookID: target.fromReader ? target.bookID : (entry?.bookId ?? target.bookID), sha: target.key)
        return (entry, details)
    }
    static func validSHA(_ value: String?) -> String? {
        guard let value, value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return value
    }
    func contentSHA(for target: StatisticsRoute) -> String? {
        if let sha = Self.validSHA(target.key) { return sha }
        guard loadedIdentity == Identity(target) else { return nil }
        return Self.validSHA(details?.metadata.sha)
    }
    func matches(_ target: StatisticsRoute) -> Bool { loadedIdentity == Identity(target) }
    func load(_ target: StatisticsRoute) async {
        let identity = Identity(target), revision = UUID()
        loadRevision = revision
        if requestedIdentity != identity {
            requestedIdentity = identity; loadedIdentity = nil
            entry = nil; details = nil; chapters = []; error = nil
        }
        do {
            let (entry, details) = try await readInformation(target)
            guard loadRevision == revision, requestedIdentity == identity, !Task.isCancelled else { return }
            self.entry = entry; self.details = details; loadedIdentity = identity; error = nil
            if let book = details.book {
                let chapters = try await readChapters(book.id)
                guard loadRevision == revision, requestedIdentity == identity, !Task.isCancelled else { return }
                self.chapters = chapters
            }
        } catch {
            guard loadRevision == revision, requestedIdentity == identity, !Task.isCancelled else { return }
            self.error = ReaderMessages.error(error)
            if error is UserSyncCompatibilityError { details = nil; draft = nil }
        }
    }

    func edit(_ target: StatisticsRoute) {
        if entry?.needsDownload == true { confirmDownload = true }
        else { prepareEditing(target) }
    }
    func prepareEditing(_ target: StatisticsRoute) {
        guard !preparing else { return }
        preparing = true; preparationStep = .running; downloading = entry?.needsDownload == true; progress = nil
        task = Task { [self] in
            defer { preparing = false; preparationStep = .running; task = nil; lease = nil }
            do {
                if let entry, !target.fromReader {
                    try await service.prepareSourceFile(entry.source) { [weak self] value in
                        Task { @MainActor in self?.progress = value }
                    }
                    try Task.checkCancellation()
                    downloading = false; progress = nil
                    lease = try await service.openSourceFile(entry.source)
                } else if let id = details?.book?.id ?? target.bookID {
                    lease = try await service.openReading(id)
                }
                guard let lease else { throw ReaderError.NotFound }
                while true {
                    try Task.checkCancellation()
                    let snapshot = try await service.snapshot(lease.id)
                    if snapshot.phase == .complete {
                        let result = try await service.details(bookID: lease.id)
                        guard result.metadata.sha.count == 64 else { throw ReaderError.ImportBusy }
                        details = result
                        try await service.userStore().requireMetadataReadable(key: result.metadata.sha)
                        draft = BookMetadataDraft(base: result.metadata)
                        break
                    }
                    if snapshot.phase == .failed { throw CocoaError(.fileReadCorruptFile) }
                    if snapshot.phase == .paused {
                        let userPaused = await service.isImportUserPaused(lease.id)
                        try Task.checkCancellation()
                        if userPaused && preparationStep != .resumeRequested {
                            preparationStep = .paused
                        } else {
                            preparationStep = .running
                            try await service.resumeImport(lease.id)
                        }
                    } else { preparationStep = .running }
                    progress = snapshot.sourceByteCount > 0 ? Double(snapshot.sourceBytesRead) / Double(snapshot.sourceByteCount) : nil
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch is CancellationError { }
            catch { self.error = ReaderMessages.error(error) }
        }
    }
    func resumePreparation() {
        guard preparing, preparationPaused else { return }
        // The existing preparation task owns the resume, including cancellation.
        preparationStep = .resumeRequested
    }
    func cancelPreparation() { task?.cancel() }
    func setStatus(_ status: BookReadingStatus) async {
        guard let base = details?.metadata, !base.sha.isEmpty else { return }
        var edited = base; edited.status = status
        do {
            try await service.saveMetadata(base: base, edited: edited)
            details = try await service.details(bookID: details?.book?.id, sha: base.sha)
        } catch { self.error = ReaderMessages.error(error) }
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
            let cover = try await ReaderService.shared.makeCover(data)
            guard !closed, imageRequest == request, !Task.isCancelled else { await ReaderService.shared.discardCoverDraft(cover); return }
            discardNewCover(); value.cover = cover
        } catch { if imageRequest == request { self.error = ReaderMessages.error(error) } }
    }
    func discardNewCover() {
        if let cover = value.cover, cover != base.cover { Task { await ReaderService.shared.discardCoverDraft(cover) } }
    }
    func removeCover() { imageRequest = UUID(); choosingImage = false; discardNewCover(); value.cover = nil }
    func cancel() { closed = true; imageRequest = UUID(); discardNewCover() }
}

struct BookMetadataEditor: View {
    @Bindable var draft: BookMetadataDraft
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    @State private var photo: PhotosPickerItem?
    @State private var filePicker = false
    @State private var discard = false
    @State private var newTag = ""
    @State private var suggestions: [String] = []
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        LibraryBookCover(title: "", cover: draft.value.cover).frame(width: 112, height: 160)
                        Spacer()
                    }.listRowBackground(Color.clear)
                    PhotosPicker(selection: $photo, matching: .images) { Label("从照片选择", systemImage: "photo") }
                        .buttonStyle(.borderless).disabled(draft.choosingImage)
                    Button("从文件选择", systemImage: "folder") { filePicker = true }.buttonStyle(.borderless).disabled(draft.choosingImage)
                    if draft.choosingImage { ProgressView("正在处理图片") }
                    if draft.value.cover != nil { Button("移除封面", role: .destructive) { draft.removeCover() } }
                } header: { Text("封面") }
                .listRowBackground(Color(uiColor: theme.surface))
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
                        Button("取消", systemImage: "xmark") { if draft.changed { discard = true } else { dismiss() } }
                            .labelStyle(.titleOnly).disabled(draft.saving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存", systemImage: "checkmark") {
                            addTag(); focused = false; draft.saving = true
                            Task {
                                defer { draft.saving = false }
                                do { try await ReaderService.shared.saveMetadata(base: draft.base, edited: draft.value); dismiss() }
                                catch { draft.error = ReaderMessages.error(error) }
                            }
                        }.labelStyle(.titleOnly).disabled(draft.saving || draft.choosingImage).accessibilityIdentifier("saveBookMetadata")
                    }
                }
                .confirmationDialog("放弃未保存的修改？", isPresented: $discard, titleVisibility: .visible) {
                    Button("放弃修改", role: .destructive) { dismiss() }
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
                .task { suggestions = (try? await ReaderService.shared.metadataOptions(shelfID: nil).tags) ?? [] }
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
    /// Actions open the existing task or start a new one for this book.
    var aiRequests: [AIQuickTaskRequest] = []
    var openAI: (AIQuickTaskRequest) -> Void = { _ in }
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
        } else if let book = model.details?.book, let library {
            Button { library.path.append(.reader(OpeningRequest(target: .book(book.id)))) } label: { Text("继续阅读").frame(maxWidth: .infinity) }
                .buttonStyle(ThemedProminentButtonStyle()).controlSize(.large)
        }
    }
    /// Author and tag start a contextual search on this stack; Back returns here.
    private func search(_ token: AppSearchToken) {
        guard let library else { return }
        let scope = AppSearchScope(tokens: [token])
        if target.fromReader { readerSearch = scope } else { library.path.append(.search(scope)) }
    }
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: LayoutTokens.content) {
                HStack(alignment: .top, spacing: LayoutTokens.content) {
                    LibraryBookCover(title: target.title, cover: model.details?.metadata.cover).frame(width: 64, height: 90)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: model.entry?.title ?? target.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        if let author = model.details?.metadata.author, !author.isEmpty {
                            if library != nil {
                                Button(author) { search(.author(author)) }
                                    .buttonStyle(.borderless).font(.subheadline).foregroundStyle(Color(uiColor: theme.accent))
                            } else {
                                Text(verbatim: author).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                            }
                        }
                        if let details = model.details, details.wordCount > 0 {
                            Text("\(details.wordCount.formatted()) 字 · \(details.chapterCount.formatted()) 章")
                                .font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                        }
                    }
                }
                primaryAction
                let actionLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: LayoutTokens.control))
                    : AnyLayout(HStackLayout(spacing: LayoutTokens.control))
                actionLayout {
                    ForEach(aiRequests) { request in
                        Button { openAI(request) } label: {
                            Label {
                                Text(request.family == .metadata ? "补全资料" : "找封面")
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: { Image(systemName: "sparkles") }
                                .font(.subheadline).frame(maxWidth: .infinity, minHeight: LayoutTokens.hit)
                        }.buttonStyle(.borderless)
                    }
                }
            }.padding(.vertical, LayoutTokens.compact)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("bookInformationHeader")
                .listRowBackground(Color(uiColor: theme.surface))
            if let tags = model.details?.metadata.tags, !tags.isEmpty {
                AIFlowLayout(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        Button(tag) { search(.tag(tag)) }.buttonStyle(.bordered).font(.subheadline)
                            .disabled(library == nil)
                    }
                }.padding(.vertical, LayoutTokens.compact)
            }
            if let synopsis = model.details?.metadata.synopsis, !synopsis.isEmpty {
                VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                    Text(verbatim: synopsis).font(.subheadline).lineLimit(expandedSynopsis ? nil : 3)
                    if synopsis.count > 100 || synopsis.filter({ $0 == "\n" }).count > 2 {
                        Button(expandedSynopsis ? "收起" : "展开简介") { expandedSynopsis.toggle() }
                            .font(.caption).buttonStyle(.borderless).foregroundStyle(Color(uiColor: theme.accent))
                            .frame(minHeight: LayoutTokens.hit, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.listRowBackground(Color(uiColor: theme.surface)).id("bookInformation")
        .navigationDestination(item: $readerSearch) { scope in
            if let library {
                ReaderContextSearch(model: library, scope: scope,
                                    isOpenBook: { entry in entry.id == target.fileID || (target.bookID != nil && entry.bookId == target.bookID) },
                                    returnToBook: { if let returnToReading { returnToReading() } else { dismiss() } })
            }
        }
        if let details = model.details, !details.metadata.sha.isEmpty {
            Section("我的阅读") {
                Picker("阅读状态", selection: Binding(get: { details.metadata.status }, set: { value in Task { await model.setStatus(value) } })) {
                    if case .other = details.metadata.status { Text(details.metadata.status.label).tag(details.metadata.status) }
                    if details.metadata.status == .unread { Text("未读").tag(BookReadingStatus.unread) }
                    ForEach([BookReadingStatus.reading, .finished, .paused], id: \.self) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("bookReadingStatus")
                if let book = details.book, book.positionUtf8 > 0 {
                    if let chapter = details.currentChapter { Text(verbatim: chapter).lineLimit(2) }
                    LabeledContent("全书位置", value: (Double(book.positionUtf8) / Double(max(1,book.byteCount))).formatted(.percent.precision(.fractionLength(1))))
                }
                if let chapter = model.chapters.last(where: { $0.startUtf8 <= (details.book?.positionUtf8 ?? 0) }) {
                    LabeledContent("当前章覆盖", value: chapter.coverageLabel)
                }
            }.listRowBackground(Color(uiColor: theme.surface)).id("myReading")
        }
    }
}
