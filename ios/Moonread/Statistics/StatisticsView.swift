import MoonreadLibrary
import MoonreadDataTypes
import MoonreadCoreBindings
import MoonreadAI
import MoonreadStatistics
import SwiftUI

/// Composes the statistics feature with book details and the host's actions.
struct StatisticsView: View {
    let library: LibraryModel
    let host: LibraryBrowsingHost
    let target: StatisticsRoute?
    @Environment(\.theme) private var theme
    @Environment(AIHost.self) private var ai
    @State private var information: BookInformationModel
    @State private var aiRequest: AIQuickTaskRequest?
    @State private var removingTask: AISessionSummary?

    init(library: LibraryModel, target: StatisticsRoute? = nil, host: LibraryBrowsingHost = .main) {
        self.library = library
        self.host = host
        self.target = target
        _information = State(initialValue: BookInformationModel(service: library.service))
    }

    var body: some View {
        StatisticsPage(
            target: target.map { .book($0.target) }, initialWindow: target?.window ?? .recent,
            theme: theme.statisticsAppearance,
            source: AppDataService.shared.statisticsDataSource(), now: { StatisticsClock.now },
            jumpToReading: readingSectionReady, writerError: StatisticsWriter.shared.error,
            openSettings: { library.shell.openSettings(target: .statistics) },
            refreshBook: {
                information.retryInformation()
                await library.refresh(showIndicator: false)
            },
            routeForBook: { book, window in
                LibraryRoute.statistics(.init(target: .record(key: book.contentKey), title: book.title,
                                              window: window, readingSection: true))
            },
            cover: { book in
                AnyView(BookCoverView(title: book.title, compact: true, cover: book.cover,
                                      contentSHA256: book.contentKey.formalSHA256, author: book.author))
            },
            titleMatches: { LibraryQueryRules.selectionMatches($0, query: $1) },
            loading: { size, fullPage in
                AnyView(LoadingActivity(size: size, fullPage: fullPage, waitingLabel: "正在读取统计"))
            },
            bookContext: {
                AnyView(Group {
                    if let target { BookInformationSections(model: information, target: target, library: library, host: host) }
                })
            },
            bookFooter: { AnyView(Group { fileInformation; deletionSection }) },
            optionsMenu: { window, clear in AnyView(optionsMenu(window, clearStatistics: clear)) }
        )
        .task(id: InformationRequest(identity: target.map(\.informationTarget), revision: information.requestRevision)) {
            if let target { await information.observe(target.informationTarget) }
        }
        .sheet(item: $information.draft) { draft in
            BookMetadataEditor(draft: draft, title: information.entry?.title ?? target?.title ?? "", service: library.service).themeScope(theme)
                .readerToolPresentation()
        }
        .alert("下载小说后才能编辑信息", isPresented: $information.confirmDownload) {
            Button("下载并准备") { if let target { information.prepareEditing(target.informationTarget) } }
            Button("取消", role: .cancel) {}
        }
        .overlay {
            if information.preparing {
                VStack(spacing: 16) {
                    ProgressView(value: information.progress)
                    Text(information.downloading ? "正在下载小说" : "正在准备正文")
                    Button("取消") { information.cancelPreparation() }
                }.padding(24).frame(maxWidth: 270).background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
            }
        }
        .alert("暂时无法完成", isPresented: Binding(get: { information.error != nil && information.details != nil }, set: { if !$0 { information.error = nil } })) {
            Button("知道了", role: .cancel) { information.error = nil }
        } message: { Text(information.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .bookMetadataChanged).receive(on: DispatchQueue.main)) { _ in
            Task { await library.reloadBooks() }
        }
        .onDisappear { information.cancelPreparation() }
        .sheet(item: $aiRequest) { request in
            AIEntry { AIQuickTaskSheet(request: request).themeScope(theme).readerToolPresentation() }
        }
        .onChange(of: ai.availability.isAvailable) { _, available in if !available { aiRequest = nil; removingTask = nil } }
        .alert("移除这个任务？", isPresented: Binding(get: { removingTask != nil }, set: { if !$0 { removingTask = nil } }),
                            presenting: removingTask) { task in
            Button("移除任务", role: .destructive) {
                Task {
                    do { try await ai.runtime?.removeTask(task.id) }
                    catch { information.error = AIRequestError.message(error) }
                }
            }
            Button("取消", role: .cancel) { removingTask = nil }
        } message: { task in
            Text(AIQuickTaskRemoval.message(task))
        }
    }

    @ViewBuilder private var deletionSection: some View {
        if let target, !target.fromReader, let details = information.details {
            BookReadingDataClearSection(book: information, target: target, key: details.metadata.sha, manager: library.shell.dataManagement)
        }
    }

    private func optionsMenu(_ window: StatisticsWindow, clearStatistics: @escaping () -> Void) -> some View {
        Menu {
            if let target {
                Button("编辑小说信息", systemImage: "pencil") { information.edit(target.informationTarget) }
                    .disabled(!information.canEdit)
                if ai.availability.isAvailable {
                    ForEach([AIQuickTaskRequest.Family.metadata, .cover], id: \.self) { family in
                        if let request = bookRequest(family) {
                            Button(family == .metadata ? "完善资料" : "封面…", systemImage: family == .metadata ? "sparkles" : "photo") { aiRequest = request }
                            if let runtime = ai.runtime, let task = request.task(runtime) {
                                Button(family == .metadata ? "移除资料任务" : "移除封面任务", systemImage: "trash", role: .destructive) {
                                    removingTask = task
                                }.disabled(task.deleting)
                            }
                        }
                    }
                }
                if let entry = information.entry {
                    Button("重命名文件", systemImage: "pencil.line") { library.sheet = .rename(entry) }
                    Button("移动", systemImage: "folder") { library.sheet = .move([entry]) }
                }
                Divider()
            }
            if ai.availability.isAvailable {
                Button("分析阅读", systemImage: "sparkles") { aiRequest = statisticsRequest(window) }
                    .disabled(statisticsRequest(window) == nil).accessibilityIdentifier("analyzeReading")
            }
            Button("统计设置", systemImage: "gearshape") { library.shell.openSettings(target: .statistics) }
            if target != nil {
                Button("清除本书统计", systemImage: "trash", role: .destructive) { clearStatistics() }
            }
        } label: { Image(systemName: "ellipsis") }.toolbarGlyph().accessibilityLabel(target == nil ? "统计选项" : "小说选项")
    }

    /// One origin per library file, so the detail page and the library menu reopen the same task.
    private func bookRequest(_ family: AIQuickTaskRequest.Family) -> AIQuickTaskRequest? {
        guard let target else { return nil }
        let sha = information.contentSHA(for: target.informationTarget)
        let fileRef = information.matches(target.informationTarget) ? information.entry.map { AIReadingTools.ref("f", $0.id) } : target.fileID.map { AIReadingTools.ref("f", $0) }
        guard sha != nil || fileRef != nil else { return nil }
        let title = information.matches(target.informationTarget) ? (information.entry?.title ?? target.title) : target.title
        let attachment = AIReadingAttachment(kind: .book, origin: "detail", bookRef: sha.map(AIReadingTools.bookRef), fileRef: fileRef, title: title)
        return AIQuickTaskRequest(family: family, origin: fileRef != nil ? AITaskOrigin(bookSHA: nil, fileRef: fileRef) : AITaskOrigin(bookSHA: sha),
                                  object: AITaskObject(title: title, subtitle: information.matches(target.informationTarget) ? information.details.flatMap { $0.metadata.author.isEmpty ? nil : $0.metadata.author } : nil, cover: information.matches(target.informationTarget) ? information.details?.metadata.cover : nil),
                                  attachments: [attachment])
    }
    private func statisticsRequest(_ window: StatisticsWindow) -> AIQuickTaskRequest? {
        AIQuickTaskRequest.statistics(window: window, target: target, information: information)
    }

    private struct InformationRequest: Hashable {
        let identity: BookInformationTarget?
        let revision: Int
    }

    private var readingSectionReady: Bool {
        guard let target, target.readingSection else { return false }
        return information.matches(target.informationTarget)
    }

    @ViewBuilder private var fileInformation: some View {
        if target != nil, let entry = information.entry {
            VStack(alignment: .leading, spacing: 14) {
                Text("文件信息").font(.headline)
                VStack(spacing: 12) {
                    detailFact("书架", value: entry.shelfName)
                    detailFact("路径", value: entry.relativePath)
                    detailFact("文件大小", value: ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                    if let count = information.details?.wordCount, count > 0 {
                        detailFact("正文字数", value: String(localized: "\(count) 字"))
                    }
                    if let book = information.details?.book { detailFact("编码", value: book.encoding) }
                    detailFact("本机状态", value: entry.needsDownload ? String(localized: "待下载") : String(localized: "已下载"))
                }
                .padding(16).background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
            }
        }
    }

    private func detailFact(_ label: LocalizedStringKey, value: String) -> some View {
        LabeledContent {
            Text(verbatim: value).foregroundStyle(Color(uiColor: theme.ink))
        } label: {
            Text(label).foregroundStyle(Color(uiColor: theme.secondary))
        }.font(.subheadline)
    }
}
