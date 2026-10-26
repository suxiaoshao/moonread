import SwiftUI
import Charts

struct StatisticsView: View {
    let library: LibraryModel
    var target: StatisticsRoute?
    @Environment(\.theme) private var theme
    @State private var model = StatisticsModel()
    @State private var window = StatisticsWindow()
    @State private var sortByDuration = false
    @State private var showAllBooks = false
    @State private var showSettings = false
    @State private var openedDay: StatisticsDayRoute?
    @State private var deleteBook = false
    @State private var visible = false
    @State private var information = BookInformationModel()
    @State private var positionedAtReading = false
    @State private var aiRequest: AIQuickTaskRequest?
    @State private var removingTask: AISessionSummary?
    @Environment(AIService.self) private var ai

    init(library: LibraryModel, target: StatisticsRoute? = nil) {
        self.library = library; self.target = target
        _window = State(initialValue: target?.window ?? StatisticsWindow())
    }

    private var orderedBooks: [StatisticsBook] {
        let books = model.overview?.books ?? []
        return sortByDuration ? books.sorted {
            if $0.durationMs != $1.durationMs { return $0.durationMs > $1.durationMs }
            if $0.lastFormalMs != $1.lastFormalMs { return $0.lastFormalMs > $1.lastFormalMs }
            return $0.contentKey < $1.contentKey
        } : books
    }
    private var total: UInt64 { model.overview?.totalDurationMs ?? 0 }

    var body: some View {
        ScrollViewReader { proxy in
        contentList
        .task(id: LoadRequest(window: window, target: target)) {
            if let target { await information.load(target) }
            guard !Task.isCancelled else { return }
            await model.load(window, target: statisticsTarget)
            if target?.readingSection == true, !positionedAtReading {
                positionedAtReading = true
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo("myReading", anchor: .top) }
            }
        }
        .sheet(item: $information.draft, onDismiss: { Task { if let target { await information.load(target) } } }) { draft in
            BookMetadataEditor(draft: draft).themeScope(theme)
        }
        .confirmationDialog("下载小说后才能编辑信息", isPresented: $information.confirmDownload, titleVisibility: .visible) {
            Button("下载并准备") { if let target { information.prepareEditing(target) } }
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
        .alert("暂时无法完成", isPresented: Binding(get: { information.error != nil }, set: { if !$0 { information.error = nil } })) {
            Button("知道了", role: .cancel) { information.error = nil }
        } message: { Text(information.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .bookMetadataChanged).receive(on: DispatchQueue.main)) { _ in
            Task { if let target { await information.load(target) }; await library.reloadBooks() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudDataReceived).receive(on: DispatchQueue.main)) { _ in
            Task {
                if visible { await model.load(window, target: statisticsTarget) }
                if let target { await information.load(target) }
            }
        }
        .onChange(of: library.revision) { _, _ in
            if visible, let target { Task { await information.load(target) } }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; information.cancelPreparation() }
        // A pull reloads everything this page shows: for one book that includes the
        // file index (availability) and its information, then the statistics.
        .refreshable {
            if let target {
                await library.refresh(showIndicator: false)
                await information.load(target)
            }
            await model.load(window, target: statisticsTarget)
        }
        .onReceive(NotificationCenter.default.publisher(for: .statisticsChanged).receive(on: DispatchQueue.main)) { _ in
            if visible { Task { await model.load(window, target: statisticsTarget) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .statisticsPreferencesChanged).receive(on: DispatchQueue.main)) { _ in
            if visible { Task { await model.load(window, target: statisticsTarget) } }
        }
        .confirmationDialog("清除本书的阅读统计？", isPresented: $deleteBook, titleVisibility: .visible) {
            Button("清除统计", role: .destructive) {
                guard let key = model.key else { return }
                Task { do { try await AppDataService.shared.deleteStatistics(book: key) } catch { model.report(error) } }
            }
        } message: { Text("正文、续读位置、书签和笔记会保留。") }
        .alert("暂时无法完成", isPresented: Binding(get: { model.error != nil && model.overview != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .accessibilityIdentifier(target == nil ? "statisticsOverview" : "statisticsBook")
        }
    }

    private var contentList: some View {
        Group {
            if target == nil, model.overview?.books.isEmpty != false {
                VStack(spacing: 0) {
                    if model.overview != nil { periodControls.padding().background(Color(uiColor: theme.canvas)) }
                    if let overview = model.overview {
                        ContentUnavailableView {
                            Label("暂无阅读记录", systemImage: "book.closed")
                        } description: {
                            Text(overview.preferences.enabled ? String(localized: "开始阅读后，这里会显示书籍、阅读时段和时长。") : String(localized: "开启阅读统计后记录新的阅读活动。"))
                        }.accessibilityIdentifier("statisticsEmpty")
                    } else if let error = model.error {
                        ContentUnavailableView {
                            Label("暂时无法读取统计", systemImage: "exclamationmark.circle")
                        } description: { Text(error) } actions: {
                            Button("重试") { Task { await model.load(window, target: statisticsTarget) } }
                        }
                    } else {
                        LoadingActivity(size: 52, waitingLabel: "正在读取统计").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .toolbarBackground(Color(uiColor: theme.canvas), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
            } else {
                List {
                    if let target {
                        BookInformationSections(model: information, target: target, library: library,
                                                aiRequests: ai.availability.isAvailable ? [bookRequest(.metadata), bookRequest(.cover)].compactMap { $0 } : [],
                                                openAI: { aiRequest = $0 })
                            .listRowBackground(Color(uiColor: theme.surface))
                    }
                    if let overview = model.overview {
                        if target != nil { cumulativeSummary }
                        periodPicker
                        if overview.books.isEmpty {
                            ContentUnavailableView {
                                Label("暂无阅读记录", systemImage: "book.closed")
                            } description: {
                                Text(overview.preferences.enabled ? String(localized: "开始阅读后，这里会显示书籍、阅读时段和时长。") : String(localized: "开启阅读统计后记录新的阅读活动。"))
                            }.listRowBackground(Color.clear)
                        } else {
                            periodSummary(overview)
                            if target == nil { bookSection } else { sessionsSection }
                        }
                        fileInformation
                    } else if let error = model.error {
                        ContentUnavailableView {
                            Label("暂时无法读取统计", systemImage: "exclamationmark.circle")
                        } description: { Text(error) } actions: {
                            Button("重试") { Task { await model.load(window, target: statisticsTarget) } }
                        }.listRowBackground(Color.clear)
                    } else {
                        HStack { Spacer(); LoadingActivity(size: 52, waitingLabel: "正在读取统计"); Spacer() }
                            .frame(minHeight: 230).listRowBackground(Color.clear)
                    }
                    if let target, !target.fromReader, let details = information.details {
                        BookReadingDataClearSection(book: information, target: target, key: details.metadata.sha, manager: library.dataManagement)
                    }
                }
            }
        }
        .themedPage()
        .safeAreaInset(edge: .top, spacing: 0) { statisticsStatus }
        .navigationTitle(target == nil ? String(localized: "统计") : String(localized: "小说详情"))
        .navigationBarTitleDisplayMode(target == nil ? .large : .inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                optionsMenu
                if target == nil && ai.availability.isAvailable { AppSettingsLink() }
            }
        }
        .sheet(item: $aiRequest) { if ai.availability.isAvailable { AIQuickTaskSheet(request: $0).themeScope(theme) } }
        .onChange(of: ai.availability.isAvailable) { _, available in if !available { aiRequest = nil; removingTask = nil } }
        .confirmationDialog("移除这个任务？", isPresented: Binding(get: { removingTask != nil }, set: { if !$0 { removingTask = nil } }),
                            titleVisibility: .visible, presenting: removingTask) { task in
            Button("移除任务", role: .destructive) {
                Task {
                    do { try await ai.removeTask(task.id) }
                    catch { information.error = AIRequestError.message(error) }
                }
            }
        } message: { task in
            Text(AIQuickTaskRemoval.message(task))
        }
        .navigationDestination(isPresented: $showSettings) { StatisticsSettingsView() }
        .navigationDestination(item: $openedDay) { StatisticsDayView(route: $0) }
        .navigationDestination(isPresented: $showAllBooks) {
            StatisticsBookList(books: orderedBooks, maximum: orderedBooks.map(\.durationMs).max() ?? 1, window: window)
        }
    }

    @ViewBuilder private var statisticsStatus: some View {
        if let overview = model.overview,
           !overview.preferences.enabled || model.compatibilityNotice != nil || StatisticsWriter.shared.error != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if !overview.preferences.enabled { Label("阅读统计已暂停", systemImage: "pause.circle") }
                    Spacer()
                    Button("统计设置") { showSettings = true }
                }
                if model.compatibilityNotice != nil || StatisticsWriter.shared.error != nil {
                    DisclosureGroup {
                        if let notice = model.compatibilityNotice { Text(verbatim: notice) }
                        if let error = StatisticsWriter.shared.error { Text(verbatim: error).foregroundStyle(Color(uiColor: theme.destructive)) }
                    } label: {
                        Label(StatisticsWriter.shared.error != nil ? String(localized: "部分阅读记录未能保存") : String(localized: "部分统计暂不可用"), systemImage: "exclamationmark.circle")
                    }
                }
            }.font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                .padding(.horizontal).padding(.vertical, 8).background(Color(uiColor: theme.surface)).accessibilityIdentifier("statisticsStatus")
        }
    }

    private var optionsMenu: some View {
        Menu {
            if let target {
                Button("编辑小说信息", systemImage: "pencil") { information.edit(target) }
                    .disabled(information.preparing || (information.entry == nil && information.details?.book == nil))
                if ai.availability.isAvailable {
                    ForEach([AIQuickTaskRequest.Family.metadata, .cover], id: \.self) { family in
                        if let request = bookRequest(family) {
                            Button(family == .metadata ? "完善资料" : "封面…", systemImage: family == .metadata ? "sparkles" : "photo") { aiRequest = request }
                            if let task = request.task(ai) {
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
                Button("分析阅读", systemImage: "sparkles") { aiRequest = statisticsRequest }
                    .disabled(statisticsRequest == nil).accessibilityIdentifier("analyzeReading")
            }
            Button("统计设置", systemImage: "gearshape") { showSettings = true }
            if target != nil {
                Button("清除本书统计", systemImage: "trash", role: .destructive) { deleteBook = true }
            }
        } label: { Image(systemName: "ellipsis") }.toolbarGlyph().accessibilityLabel(target == nil ? "统计选项" : "小说选项")
    }

    /// One origin per library file, so the detail page and the library menu reopen the same task.
    private func bookRequest(_ family: AIQuickTaskRequest.Family) -> AIQuickTaskRequest? {
        guard let target else { return nil }
        let sha = information.contentSHA(for: target)
        let fileRef = information.matches(target) ? information.entry.map { AIReadingTools.ref("f", $0.id) } : target.fileID.map { AIReadingTools.ref("f", $0) }
        guard sha != nil || fileRef != nil else { return nil }
        let title = information.matches(target) ? (information.entry?.title ?? target.title) : target.title
        let attachment = AIReadingAttachment(kind: .book, origin: "detail", bookRef: sha.map(AIReadingTools.bookRef), fileRef: fileRef, title: title)
        return AIQuickTaskRequest(family: family, origin: fileRef != nil ? AITaskOrigin(bookSHA: nil, fileRef: fileRef) : AITaskOrigin(bookSHA: sha),
                                  object: AITaskObject(title: title, subtitle: information.matches(target) ? information.details.flatMap { $0.metadata.author.isEmpty ? nil : $0.metadata.author } : nil, cover: information.matches(target) ? information.details?.metadata.cover : nil),
                                  attachments: [attachment])
    }
    private struct LoadRequest: Hashable {
        let window: StatisticsWindow
        let target: StatisticsRoute?
    }
    private var statisticsRequest: AIQuickTaskRequest? {
        AIQuickTaskRequest.statistics(window: window, target: target, information: information)
    }

    private var statisticsTarget: StatisticsRoute? {
        guard var target else { return nil }
        let matches = information.matches(target)
        target.key = information.contentSHA(for: target) ?? target.key
        if matches { target.bookID = information.details?.book?.id ?? target.bookID }
        return target
    }

    @ViewBuilder private var fileInformation: some View {
        if target != nil, let entry = information.entry {
            Section {
                DisclosureGroup("文件信息") {
                    LabeledContent("书架", value: entry.shelfName)
                    LabeledContent("路径", value: entry.relativePath)
                    LabeledContent("文件大小", value: ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                    if let book = information.details?.book { LabeledContent("编码", value: book.encoding) }
                    LabeledContent("本机状态", value: entry.needsDownload ? String(localized: "待下载") : String(localized: "已下载"))
                }
            }.listRowBackground(Color(uiColor: theme.surface))
        }
    }

    /// One book's totals across all recorded reading.
    private var cumulativeSummary: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("累计阅读").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                Text(StatisticsDates.duration(model.cumulative?.durationMs ?? 0)).font(.title2).monospacedDigit()
                if let book = model.cumulative {
                    Text("\(book.readingDays) 个阅读日").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                    Text("首次阅读 \(Date(timeIntervalSince1970: Double(book.firstReadMs) / 1000).formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                    Text("最近阅读 \(Date(timeIntervalSince1970: Double(book.lastReadMs) / 1000).formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                }
            }.padding(.vertical, 4)
        }.listRowBackground(Color(uiColor: theme.surface))
    }
    /// The selected range: total time, days with reading, distinct books, then its rhythm.
    /// For one book over 全部 the totals equal the cumulative summary, so only the rhythm remains.
    @ViewBuilder private func periodSummary(_ overview: StatisticsOverview) -> some View {
        let today = StatisticsDates.day(Date())
        let rhythm = StatisticsRhythm(window: window, days: overview.days, today: today, book: target == nil ? nil : model.key) { openedDay = $0 }
        if target == nil || window.period != .all || rhythm.hasContent {
            Section {
                if target == nil || window.period != .all {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(StatisticsDates.duration(total)).font(.title2.weight(.semibold)).monospacedDigit()
                        Text(target == nil ? String(localized: "\(activeDays(overview)) 个阅读日 · \(overview.books.count) 本书")
                                           : String(localized: "\(activeDays(overview)) 个阅读日"))
                            .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                    }.padding(.vertical, 4)
                    .accessibilityElement(children: .combine).accessibilityIdentifier("statisticsSummary")
                }
                if rhythm.hasContent { rhythm.padding(.vertical, 4) }
            }.listRowBackground(Color(uiColor: theme.surface))
        }
    }
    private func activeDays(_ overview: StatisticsOverview) -> Int { overview.days.filter { $0.durationMs > 0 }.count }
    private var periodPicker: some View {
        Section { periodControls }.listRowBackground(Color(uiColor: theme.surface))
    }
    private var periodControls: some View {
        VStack(spacing: 0) {
            Picker("统计范围", selection: $window.period) {
                ForEach(StatisticsPeriod.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("statisticsPeriod")
            // Only calendar months and years step through history; the range itself is always named.
            HStack {
                if window.period.browsable {
                    Button { window.shift(-1) } label: { Image(systemName: "chevron.left").frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit) }
                        .accessibilityLabel("上一时段")
                }
                Text(window.label).font(.headline).frame(maxWidth: .infinity).accessibilityIdentifier("statisticsRange")
                if window.period.browsable {
                    Button { window.shift(1) } label: { Image(systemName: "chevron.right").frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit) }
                        .disabled(!window.canAdvance).accessibilityLabel("下一时段")
                }
            }.buttonStyle(.borderless).frame(minHeight: LayoutTokens.hit)
        }
    }
    private var bookSection: some View {
        Section {
            ForEach(Array(orderedBooks.prefix(5)), id: \.contentKey) { book in
                StatisticsBookRow(book: book, maximum: orderedBooks.map(\.durationMs).max() ?? 1, window: window)
            }
            if orderedBooks.count > 5 { Button("查看全部书籍") { showAllBooks = true } }
        } header: {
            HStack {
                Text("读过的书")
                Spacer()
                Menu {
                    Picker("排序", selection: $sortByDuration) {
                        Text("最近阅读").tag(false); Text("阅读时长").tag(true)
                    }
                } label: { Label(sortByDuration ? String(localized: "阅读时长") : String(localized: "最近阅读"), systemImage: "arrow.up.arrow.down").font(.caption) }
            }
        }.listRowBackground(Color(uiColor: theme.surface))
    }
    /// One book's exact sessions stay available but collapsed beneath its rhythm.
    private var sessionsSection: some View {
        Section {
            DisclosureGroup {
                ReadingSessionsChart(spans: model.spans, singleBook: true)
                ForEach(Array(model.spans.reversed().prefix(8))) { span in
                    ReadingSessionRow(span: span, showBook: false)
                }
                if model.spans.count > 8 {
                    NavigationLink("全部时段") {
                        StatisticsSessionsView(spans: model.spans, theme: theme)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("阅读时段")
                    Text("所选范围内最近 7 个阅读日").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                }
            }.accessibilityIdentifier("bookReadingSessions")
        }.listRowBackground(Color(uiColor: theme.surface))
    }
}
