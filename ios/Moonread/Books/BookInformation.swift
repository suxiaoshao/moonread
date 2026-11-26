import MoonreadLibrary
import MoonreadDataTypes
import MoonreadCoreBindings
import SwiftUI
import Combine
import PhotosUI
import UniformTypeIdentifiers

extension BookInformationModel {
    convenience init(
        service: AppDataService = .shared,
        readInformation: (@MainActor (BookInformationTarget) async throws -> (LibraryEntry?, BookDetailsResult))? = nil,
        readChapters: (@MainActor (String) async throws -> [ChapterEntry])? = nil
    ) {
        self.init(source: .init(
            read: readInformation ?? {
                try await service.bookInformation($0.target, fileID: $0.fileID, includeRecordSource: !$0.fromReader)
            },
            readChapters: readChapters,
            updates: {
                try await service.bookInformationUpdates($0.target, fileID: $0.fileID, includeRecordSource: !$0.fromReader)
            },
            observeCoverage: { try await service.observeChapterCoverage($0, receive: $1) },
            prepareMetadata: { try await prepareBookMetadata(service: service, source: $0, cachedBookID: $1, progress: $2) },
            makeDraft: { base in
                .init(base: base, makeCover: { try await service.makeCover($0) },
                      discardCover: { await service.discardCoverDraft($0) }, describeError: { ReaderMessages.error($0) })
            },
            saveMetadata: { try await service.saveMetadata(base: $0, edited: $1) },
            details: { try await service.bookDetails($0) },
            observeAccount: { MainActorNotifications.observe(.readingContinuationInvalidated, object: service, using: $0) },
            describeError: { ReaderMessages.error($0) }
        ))
    }
}

@MainActor
private func prepareBookMetadata(
    service: AppDataService,
    source: SourceFile?, cachedBookID: String?,
    progress: @escaping BookInformationSource.Progress
) async throws -> BookDetailsResult {
    let lease: ReadingLease
    if let source {
        try await service.prepareSourceFile(source) { value in
            Task { @MainActor in progress(.downloading, value) }
        }
        try Task.checkCancellation()
        progress(.indexing, nil)
        lease = try await service.openSourceFile(source)
    } else if let id = cachedBookID {
        lease = try await service.openReading(id)
    } else { throw ReaderError.NotFound }
    while true {
        try Task.checkCancellation()
        let snapshot = try await service.snapshot(lease.id)
        if snapshot.preparation.isComplete {
            let result = try await service.bookDetails(.cached(bookId: lease.id))
            _ = try result.requireIdentified()
            return result
        }
        if snapshot.preparation.isFailed { throw CocoaError(.fileReadCorruptFile) }
        if snapshot.preparation.isPaused {
            try Task.checkCancellation()
            try await service.resumeImport(lease.id)
        }
        progress(.indexing, snapshot.byteProgress.total > 0 ? Double(snapshot.byteProgress.read) / Double(snapshot.byteProgress.total) : nil)
        try await Task.sleep(for: .milliseconds(100))
    }
}

struct BookMetadataEditor: View {
    @Bindable var draft: BookMetadataDraft
    var title = ""
    let service: AppDataService
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
                        ZStack {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) { coverActions }
                                VStack(spacing: 12) { coverActions }
                            }
                            .opacity(draft.choosingImage ? 0 : 1)
                            .accessibilityHidden(draft.choosingImage)
                            if draft.choosingImage {
                                InlineTaskProgress(title: Text("正在处理图片"))
                                    .font(.subheadline)
                                    .foregroundStyle(Color(uiColor: theme.secondary))
                            }
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
                        BookTagPicker(service: service, purpose: .metadata, selection: $draft.value.tags) {
                            EmptyView()
                        } status: {
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
                                do { try await service.saveMetadata(base: draft.base, edited: draft.value); dismiss() }
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
                    BookTagSummaryCapsule(name: tag)
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
    let host: LibraryBrowsingHost
    @Environment(\.theme) private var theme
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    @State private var readerDestination: LibraryRoute?
    @Environment(\.returnToReading) private var returnToReading
    /// Reading is the page's main task: one full-width prominent action under the book identity.
    @ViewBuilder private var primaryAction: some View {
        if target.fromReader {
            Button { dismiss() } label: { Text("返回阅读").frame(maxWidth: .infinity) }
                .buttonStyle(ThemedProminentButtonStyle()).controlSize(.large)
        } else if let entry = model.entry, let library {
            Button {
                let metadata = model.details?.metadata
                host.open(entry.withMetadata(metadata?.sha == entry.readingIdentity?.formalSHA256 ? metadata : nil), in: library)
            } label: { Text(entry.lastRead == 0 ? "开始阅读" : "继续阅读").frame(maxWidth: .infinity) }
                .buttonStyle(ThemedProminentButtonStyle()).controlSize(.large)
        } else if let book = model.readableBook, let library {
            Button { host.navigate(.reader(OpeningRequest(target: .book(book.id))), in: library) } label: { Text("继续阅读").frame(maxWidth: .infinity) }
                .buttonStyle(ThemedProminentButtonStyle()).controlSize(.large)
        }
    }
    /// A push from the reader's details keeps the original reader on this stack.
    private func navigate(_ route: LibraryRoute) {
        guard let library else { return }
        if target.fromReader { readerDestination = route } else { host.navigate(route, in: library) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                BookCoverView(title: model.entry?.title ?? target.title, cover: model.details?.metadata.cover, contentSHA256: model.details?.metadata.sha, author: model.details?.metadata.author)
                    .frame(width: 64, height: 90).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: model.entry?.title ?? target.title)
                        .font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    author
                    bookCounts.font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                }
            }.accessibilityIdentifier("bookInformationHeader")
            primaryAction
            if let tags = model.details?.metadata.tags, !tags.isEmpty {
                AIFlowLayout(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        Button(tag) { navigate(.search(.init(seeds: [.tag(tag)]))) }
                            .font(.subheadline).buttonStyle(.bordered)
                            .disabled(library == nil)
                    }
                }
            }
            if let synopsis = model.details?.metadata.synopsis, !synopsis.isEmpty {
                BookSynopsis(synopsis: synopsis).id(synopsis)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("我的阅读").font(.headline)
                readingCard
            }.id("myReading")
        }.frame(maxWidth: .infinity, alignment: .leading).id("bookInformation")
        .navigationDestination(item: $readerDestination) { route in
            HostedLibraryDestination(route: route, host: .init(allowsFileBrowsing: false, isOpenBook: { entry in
                entry.id == target.fileID || model.contentSHA(for: target.informationTarget).map { entry.readingKey == $0 } == true
            }, returnToOpenBook: {
                if let returnToReading { returnToReading() } else { dismiss() }
            }))
        }
    }
    @ViewBuilder private var author: some View {
        if let author = model.details?.metadata.author, !author.isEmpty {
            if library != nil {
                Button { navigate(.author(.init(author))) } label: {
                    let arrow = Text(Image(systemName: "chevron.right")).font(.caption.weight(.semibold))
                    Text("\(Text(verbatim: author)) \(arrow)")
                        .accessibilityLabel(Text(verbatim: author))
                }
                    .buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.accent))
            } else { Text(verbatim: author) }
        }
    }
    @ViewBuilder private var bookCounts: some View {
        if let body = model.details?.body, body.wordCount > 0 {
            let style = IntegerFormatStyle<UInt64>.number.locale(locale)
            let count = body.wordCount < 10_000
                ? body.wordCount.formatted(style)
                : body.wordCount.formatted(style.notation(.compactName).precision(.fractionLength(0)))
            Text("\(count) 字 · \(body.chapterCount) 章")
                .accessibilityLabel(Text("\(body.wordCount) 字 · \(body.chapterCount) 章"))
        }
    }
    private var readingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let details = model.details {
                let position = model.entry?.positionUtf8 ?? details.book?.positionUtf8 ?? 0
                let bytes = model.entry?.byteCount ?? details.book?.byteCount ?? 0
                HStack(alignment: .top, spacing: 12) {
                    if let chapter = details.currentChapter { Text(verbatim: chapter).font(.body).fixedSize(horizontal: false, vertical: true) }
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
            } else if model.matches(target.informationTarget), model.contentSHA(for: target.informationTarget) == nil {
                Text("阅读位置暂不可用").font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
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
                    Text("简介").font(.headline).foregroundStyle(Color(uiColor: theme.ink)).frame(minHeight: LayoutTokens.hit, alignment: .leading)
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
        Text(verbatim: synopsis).font(.body).lineLimit(limit)
            .foregroundStyle(Color(uiColor: theme.ink))
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
            if let message = manager.message { Text(verbatim: message).font(.footnote) }
        }.padding(.top, 8)
            .modifier(ReadingDataDeletionPrompt(model: manager))
            .onChange(of: manager.busy) { _, busy in if !busy { Task { await book.load(target.informationTarget) } } }
            .alert("暂时无法完成", isPresented: Binding(get: { manager.error != nil }, set: { if !$0 { manager.clearError() } })) {
                Button("知道了", role: .cancel) { manager.clearError() }
            } message: { Text(manager.error ?? "") }
    }
}
