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
    @ObservationIgnored private let service: AppDataService
    @ObservationIgnored private let readInformation: @MainActor (StatisticsRoute) async throws -> (LibraryEntry?, BookDetails)
    @ObservationIgnored private let readChapters: @MainActor (String) async throws -> [ChapterEntry]
    init(service: AppDataService = .shared,
         readInformation: (@MainActor (StatisticsRoute) async throws -> (LibraryEntry?, BookDetails))? = nil,
         readChapters: (@MainActor (String) async throws -> [ChapterEntry])? = nil) {
        self.service = service
        self.readInformation = readInformation ?? { try await Self.read($0, service: service) }
        self.readChapters = readChapters ?? { try await service.chapters($0).items }
    }
    private static func read(_ target: StatisticsRoute, service: AppDataService) async throws -> (LibraryEntry?, BookDetails) {
        let entry: LibraryEntry?
        if let file = target.fileID { entry = try await service.libraryEntry(file) }
        else if let id = target.bookID, !target.fromReader {
            let key: String
            if let known = target.key { key = known } else { key = try await service.userKey(id) }
            entry = try await service.libraryEntries(nil).first { $0.readingKey == key && !$0.directory }
        } else { entry = nil }
        let key = entry?.readingKey ?? target.key
        let bookID = entry?.bookId ?? (validSHA(key) == nil ? target.bookID : nil)
        let details = try await service.details(bookID: target.fromReader ? target.bookID : bookID, sha: key)
        return (entry, details)
    }
    static func validSHA(_ value: String?) -> String? {
        value.flatMap { try? parseSha256(value: $0) }
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
            } else { self.chapters = [] }
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
        preparing = true; downloading = entry?.needsDownload == true; progress = nil
        task = Task { [self] in
            defer { preparing = false; task = nil; lease = nil }
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
                        guard (try? parseSha256(value: result.metadata.sha)) != nil else { throw ReaderError.ImportBusy }
                        details = result
                        try await service.userStore().requireMetadataReadable(key: result.metadata.sha)
                        draft = BookMetadataDraft(base: result.metadata)
                        break
                    }
                    if snapshot.phase == .failed { throw CocoaError(.fileReadCorruptFile) }
                    if snapshot.phase == .paused {
                        try Task.checkCancellation()
                        try await service.resumeImport(lease.id)
                    }
                    progress = snapshot.sourceByteCount > 0 ? Double(snapshot.sourceBytesRead) / Double(snapshot.sourceByteCount) : nil
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch is CancellationError { }
            catch { self.error = ReaderMessages.error(error) }
        }
    }
    func finishPreparationForDataDeletion() async {
        let current = task; current?.cancel(); await current?.value; lease = nil
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
                        LibraryBookCover(title: "", cover: draft.value.cover).frame(width: 112, height: 160)
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
                        Button("取消", systemImage: "xmark") { if draft.changed { discard = true } else { dismiss() } }
                            .labelStyle(.titleOnly).disabled(draft.saving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存", systemImage: "checkmark") {
                            addTag(); focused = false; draft.saving = true
                            Task {
                                defer { draft.saving = false }
                                do { try await AppDataService.shared.saveMetadata(base: draft.base, edited: draft.value); dismiss() }
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
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                LibraryBookCover(title: target.title, cover: model.details?.metadata.cover)
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
                            .font(.subheadline).buttonStyle(.plain)
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 7))
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
        if let details = model.details, details.wordCount > 0 {
            Text("\(details.wordCount) 字 · \(details.chapterCount) 章")
        }
    }
    private var readingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let details = model.details, !details.metadata.sha.isEmpty {
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
            Text("本章覆盖 \(model.chapters.last(where: { $0.startUtf8 <= position })?.coverageLabel ?? "—")")
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
            } label: { Text("清除本书阅读数据").frame(maxWidth: .infinity, minHeight: LayoutTokens.hit) }
                .buttonStyle(.bordered)
                .foregroundStyle(Color(uiColor: theme.destructive)).disabled(manager.busy).accessibilityIdentifier("clearBookReadingData")
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
