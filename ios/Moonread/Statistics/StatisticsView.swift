import SwiftUI
import Charts

struct StatisticsRoute: Hashable {
    var key: String?
    var bookID: String?
    var title: String
    var fileID: String? = nil
    var fromReader = false
    var window: StatisticsWindow? = nil
    var readingSection = false
}

/// The recent window answers "what have I been reading"; months and years are
/// calendar units for looking back. Every day is a local calendar day.
enum StatisticsPeriod: String, CaseIterable, Identifiable {
    case recent, month, year, all
    var id: Self { self }
    var label: LocalizedStringKey {
        switch self { case .recent: "近 7 天"; case .month: "月"; case .year: "年"; case .all: "全部" }
    }
    /// Only calendar periods have a history to step through.
    var browsable: Bool { self == .month || self == .year }
}

struct StatisticsWindow: Hashable {
    var period: StatisticsPeriod = .recent
    var date = Date()
    /// Inclusive local calendar days. The recent window is the last seven days, ending with today.
    func bounds(today: Int64 = StatisticsDates.day(Date()), calendar: Calendar = .current) -> ClosedRange<Int64> {
        switch period {
        case .recent: return (today - 6)...today
        case .all: return 0...today
        case .month, .year:
            let interval = calendar.dateInterval(of: period == .month ? .month : .year, for: date)!
            return StatisticsDates.day(interval.start, calendar: calendar)...StatisticsDates.day(interval.end.addingTimeInterval(-1), calendar: calendar)
        }
    }
    var bounds: ClosedRange<Int64> { bounds() }
    func label(today: Int64 = StatisticsDates.day(Date())) -> String {
        let range = bounds(today: today)
        switch period {
        case .recent: return StatisticsDates.rangeLabel(range, today: today)
        case .month: return StatisticsDates.format(range.lowerBound, template: "yMMMM")
        case .year: return StatisticsDates.format(range.lowerBound, template: "y")
        case .all: return String(localized: "全部时间")
        }
    }
    var label: String { label() }
    mutating func shift(_ direction: Int, calendar: Calendar = .current) {
        guard period.browsable else { return }
        date = calendar.date(byAdding: period == .month ? .month : .year, value: direction, to: date) ?? date
    }
    func canAdvance(today: Int64 = StatisticsDates.day(Date())) -> Bool { period.browsable && bounds(today: today).upperBound < today }
    var canAdvance: Bool { canAdvance() }
}

/// One bar or cell of a rhythm chart: an inclusive run of local calendar days.
struct StatisticsBucket: Identifiable, Equatable {
    var id: Int64 { first }
    let first: Int64
    let last: Int64
    let durationMs: UInt64
}

enum StatisticsBuckets {
    private static func amounts(_ days: [StatisticsDay]) -> [Int64: UInt64] {
        Dictionary(days.map { ($0.day, $0.durationMs) }, uniquingKeysWith: +)
    }
    /// Every day in the range, including days without reading.
    static func days(_ days: [StatisticsDay], range: ClosedRange<Int64>) -> [StatisticsBucket] {
        let values = amounts(days)
        return range.map { StatisticsBucket(first: $0, last: $0, durationMs: values[$0] ?? 0) }
    }
    /// Calendar months of one year that have begun by today; later months are not zeros, they have not happened.
    static func months(_ days: [StatisticsDay], year range: ClosedRange<Int64>, today: Int64) -> [StatisticsBucket] {
        let calendar = StatisticsDates.civilCalendar
        let year = calendar.component(.year, from: StatisticsDates.date(range.lowerBound))
        return (1...12).compactMap { month in
            guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let end = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start) else { return nil }
            let first = StatisticsDates.civilDay(start), last = StatisticsDates.civilDay(end)
            guard first <= today else { return nil }
            let total = days.filter { $0.day >= first && $0.day <= last }.reduce(0) { $0 + $1.durationMs }
            return StatisticsBucket(first: first, last: last, durationMs: total)
        }
    }
    /// Calendar years from the first recorded reading through the current year.
    static func years(_ days: [StatisticsDay], today: Int64) -> [StatisticsBucket] {
        let calendar = StatisticsDates.civilCalendar
        guard let earliest = days.filter({ $0.durationMs > 0 }).map(\.day).min() else { return [] }
        let firstYear = calendar.component(.year, from: StatisticsDates.date(earliest))
        let lastYear = calendar.component(.year, from: StatisticsDates.date(today))
        return (firstYear...max(firstYear, lastYear)).compactMap { year in
            guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let end = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) else { return nil }
            let first = StatisticsDates.civilDay(start), last = StatisticsDates.civilDay(end)
            let total = days.filter { $0.day >= first && $0.day <= last }.reduce(0) { $0 + $1.durationMs }
            return StatisticsBucket(first: first, last: last, durationMs: total)
        }
    }
}

struct StatisticsSpan: Identifiable {
    let id: String
    let sessionID: String
    let key: String
    let title: String
    let day: Int64
    let offset: Int32
    let preview: Bool
    let start: Int64
    var end: Int64
    var milliseconds: UInt64
    var startClock: Double { Double(start + Int64(offset) * 1000 - day * 86_400_000) / 3_600_000 }
    var endClock: Double { Double(end + Int64(offset) * 1000 - day * 86_400_000) / 3_600_000 }
    var time: String { "\(StatisticsDates.clock(start, offset: offset))–\(StatisticsDates.clock(end, offset: offset))" }

    static func merge(_ rows: [ReadingActivity]) -> [Self] {
        var result: [Self] = []
        for row in rows {
            if let last = result.last, last.sessionID == row.sessionId, last.key == row.contentKey,
               last.day == row.localDay, last.offset == row.utcOffsetSeconds, last.preview == row.preview,
               abs(last.end - row.startedMs) <= 2 {
                result[result.count - 1].end = row.endedMs
                result[result.count - 1].milliseconds += UInt64(row.endedMs - row.startedMs)
            } else {
                result.append(Self(id: row.id, sessionID: row.sessionId, key: row.contentKey, title: row.title,
                    day: row.localDay, offset: row.utcOffsetSeconds, preview: row.preview,
                    start: row.startedMs, end: row.endedMs, milliseconds: UInt64(row.endedMs - row.startedMs)))
            }
        }
        return result
    }
}

@MainActor @Observable
final class StatisticsModel {
    var overview: StatisticsOverview?
    var cumulative: StatisticsBook?
    var spans: [StatisticsSpan] = []
    var key: String?
    var title: String?
    var error: String?
    var compatibilityNotice: String?
    var loading = false
    private var revision = 0

    func report(_ error: Error) {
        self.error = ReaderMessages.error(error)
        if error is UserSyncCompatibilityError { overview = nil; cumulative = nil; spans = []; compatibilityNotice = nil }
    }

    func load(_ window: StatisticsWindow, target: StatisticsRoute?) async {
        revision += 1
        let request = revision
        loading = true; error = nil
        defer { if revision == request { loading = false } }
        do {
            await StatisticsWriter.shared.drain()
            var contentKey = target?.key
            if let target, contentKey == nil, let id = target.bookID {
                contentKey = try await ReaderService.shared.book(id).contentSha256
            }
            if target != nil, contentKey == nil { contentKey = "unprepared" }
            let notice = try await ReaderService.shared.statisticsCompatibilityNotice(book: contentKey)
            let bounds = window.bounds
            let result = try await ReaderService.shared.statistics(first: bounds.lowerBound, last: bounds.upperBound, book: contentKey)
            let all = target == nil ? nil : try await ReaderService.shared.statistics(first: 0, last: StatisticsDates.day(Date()), book: contentKey).books.first
            // One book's sessions: the last seven reading days within the selected range.
            var spans: [StatisticsSpan] = []
            if target != nil, let first = result.days.suffix(7).first?.day, let last = result.days.last?.day {
                spans = StatisticsSpan.merge(try await ReaderService.shared.activities(first: first, last: last, book: contentKey))
            }
            guard !Task.isCancelled, request == revision else { return }
            key = contentKey; title = target?.title; overview = result; cumulative = all; self.spans = spans; compatibilityNotice = notice
        } catch is CancellationError { }
        catch {
            if request == revision {
                report(error)
            }
        }
    }
}

/// A day opened from a rhythm chart, optionally limited to one book.
struct StatisticsDayRoute: Hashable, Identifiable {
    var id: String { "\(day)-\(book ?? "")" }
    let day: Int64
    var book: String?
}

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
    private var total: UInt64 { (model.overview?.books ?? []).reduce(0) { $0 + $1.durationMs } }

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
            if information.preparing && !information.preparationPaused {
                VStack(spacing: 16) {
                    ProgressView(value: information.progress)
                    Text(information.downloading ? "正在下载小说" : "正在准备正文")
                    Button("取消") { information.cancelPreparation() }
                }.padding(24).frame(maxWidth: 270).background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
            }
        }
        .alert("正文准备已暂停", isPresented: Binding(get: { information.preparationPaused }, set: { _ in })) {
            // Actions transition the preparation task's state; dismissing the
            // presentation binding must not cancel an explicit resume request.
            Button("继续准备") { information.resumePreparation() }
            Button("取消", role: .cancel) { information.cancelPreparation() }
        } message: {
            Text("编辑详情需要先完成正文准备。")
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
                Task { do { try await ReaderService.shared.deleteStatistics(book: key) } catch { model.report(error) } }
            }
        } message: { Text("正文、续读位置、书签和笔记会保留。") }
        .alert("暂时无法完成", isPresented: Binding(get: { model.error != nil && model.overview != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .accessibilityIdentifier(target == nil ? "statisticsOverview" : "statisticsBook")
        }
    }

    private var contentList: some View {
        List {
            if let target {
                BookInformationSections(model: information, target: target, library: library,
                                        aiRequests: ai.availability.isAvailable ? [bookRequest(.metadata), bookRequest(.cover)].compactMap { $0 } : [],
                                        openAI: { aiRequest = $0 })
                    .listRowBackground(Color(uiColor: theme.surface))
            }
            if let overview = model.overview {
                if let notice = model.compatibilityNotice {
                    Section { Label(notice, systemImage: "exclamationmark.circle") }.listRowBackground(Color(uiColor: theme.surface))
                }
                if !overview.preferences.enabled {
                    Section { Label("阅读统计已暂停", systemImage: "pause.circle").foregroundStyle(Color(uiColor: theme.secondary)) }
                        .listRowBackground(Color(uiColor: theme.surface))
                }
                if let error = StatisticsWriter.shared.error {
                    Section {
                        Text("部分阅读记录尚未保存")
                        Button("重试") { StatisticsWriter.shared.retry() }
                        Text(error).font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                    }.listRowBackground(Color(uiColor: theme.surface))
                }
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
        }
        .themedPage()
        .navigationTitle(target == nil ? String(localized: "统计") : String(localized: "小说详情"))
        .navigationBarTitleDisplayMode(target == nil ? .large : .inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                optionsMenu
                if target == nil { AppSettingsLink() }
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
        Section {
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
        }.listRowBackground(Color(uiColor: theme.surface))
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
                        List(model.spans.reversed()) { ReadingSessionRow(span: $0, showBook: false) }
                            .themedPage().navigationTitle("阅读时段")
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

/// A book's time in the range. The bar is scaled to the range's longest book and
/// ends at its written duration, so it reads as a comparison, never as progress.
private struct StatisticsBookRow: View {
    let book: StatisticsBook
    let maximum: UInt64
    var window = StatisticsWindow()
    @Environment(\.theme) private var theme
    var body: some View {
        NavigationLink(value: LibraryRoute.statistics(StatisticsRoute(key: book.contentKey, bookID: book.bookId, title: book.title, window: window, readingSection: true))) {
            HStack(spacing: LayoutTokens.control) {
                LibraryBookCover(title: book.title, compact: true).frame(width: 30, height: 42).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: book.title).lineLimit(1)
                    StatisticsDurationBar(fraction: Double(book.durationMs) / Double(max(1, maximum)), color: theme.statisticsColor(book.contentKey)) {
                        Text(StatisticsDates.duration(book.durationMs)).font(.caption).monospacedDigit()
                            .foregroundStyle(Color(uiColor: theme.secondary))
                    }
                    if book.lastFormalMs > 0 {
                        Text(Date(timeIntervalSince1970: Double(book.lastFormalMs) / 1000), format: .dateTime.month().day().hour().minute())
                            .font(.caption2).foregroundStyle(Color(uiColor: theme.secondary))
                    } else { Text("仅查阅").font(.caption2).foregroundStyle(Color(uiColor: theme.secondary)) }
                }
            }.padding(.vertical, 3)
        }.accessibilityIdentifier("statistics-book-\(book.contentKey)")
    }
}

/// A bar without a track whose written value follows its end.
private struct StatisticsDurationBar<Value: View>: View {
    let fraction: Double
    let color: Color
    @ViewBuilder let value: () -> Value
    var body: some View {
        BarWithValueLayout(fraction: min(1, max(0, fraction))) {
            Capsule().fill(color).frame(height: 5).accessibilityHidden(true)
            value()
        }
    }
}
private struct BarWithValueLayout: Layout {
    let fraction: Double
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let label = subviews[1].sizeThatFits(.unspecified)
        return CGSize(width: proposal.width ?? label.width * 3, height: max(label.height, 5))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let label = subviews[1].sizeThatFits(.unspecified)
        let barWidth = max(3, (bounds.width - label.width - spacing) * fraction)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: barWidth, height: 5))
        subviews[1].place(at: CGPoint(x: bounds.minX + barWidth + spacing, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(label))
    }
}

private struct StatisticsBookList: View {
    let books: [StatisticsBook]
    let maximum: UInt64
    let window: StatisticsWindow
    @State private var query = ""
    @Environment(\.theme) private var theme
    var body: some View {
        List(books.filter { query.isEmpty || $0.title.localizedStandardContains(query) }, id: \.contentKey) {
            StatisticsBookRow(book: $0, maximum: maximum, window: window).listRowBackground(Color(uiColor: theme.surface))
        }.themedPage().navigationTitle("读过的书").searchable(text: $query, prompt: "搜索书名")
    }
}

/// The selected range's day-level rhythm: seven daily bars, a month calendar,
/// a year's monthly bars, or all-time yearly bars when there is more than one year.
struct StatisticsRhythm: View {
    let window: StatisticsWindow
    let days: [StatisticsDay]
    let today: Int64
    var book: String?
    let open: (StatisticsDayRoute) -> Void
    private var buckets: [StatisticsBucket] {
        switch window.period {
        case .recent: StatisticsBuckets.days(days, range: window.bounds(today: today))
        case .month: []
        case .year: StatisticsBuckets.months(days, year: window.bounds(today: today), today: today)
        case .all: StatisticsBuckets.years(days, today: today)
        }
    }
    var hasContent: Bool { window.period == .all ? buckets.count > 1 : true }
    var body: some View {
        switch window.period {
        case .recent:
            StatisticsBarChart(buckets: buckets, label: { $0.first == today ? String(localized: "今天") : StatisticsDates.format($0.first, template: "d") },
                               accessibilityLabel: { StatisticsDates.dateLabel($0.first, full: true) },
                               open: { bucket in if bucket.durationMs > 0 { open(StatisticsDayRoute(day: bucket.first, book: book)) } })
        case .month:
            ReadingCalendarChart(days: days, month: window.bounds(today: today), today: today) { open(StatisticsDayRoute(day: $0, book: book)) }
        case .year:
            StatisticsBarChart(buckets: buckets, slots: 12, label: { StatisticsDates.format($0.first, template: "MMM") },
                               accessibilityLabel: { StatisticsDates.format($0.first, template: "yMMMM") })
        case .all:
            StatisticsBarChart(buckets: buckets, label: { StatisticsDates.format($0.first, template: "y") },
                               accessibilityLabel: { StatisticsDates.format($0.first, template: "y") })
        }
    }
}

/// Reading time per bucket. Labels name the bucket; values stay in minutes on a
/// short axis, and VoiceOver reads each bucket's exact duration.
private struct StatisticsBarChart: View {
    let buckets: [StatisticsBucket]
    var slots: Int? = nil
    let label: (StatisticsBucket) -> String
    let accessibilityLabel: (StatisticsBucket) -> String
    var open: ((StatisticsBucket) -> Void)? = nil
    @Environment(\.theme) private var theme
    private var maximum: Double { max(1, buckets.map { Double($0.durationMs) / 60_000 }.max() ?? 1) }
    /// Categorical slots; a year keeps twelve so months that have not begun hold their place.
    private var keys: [String] { buckets.map { String($0.first) } + (buckets.count..<max(buckets.count, slots ?? 0)).map { "slot-\($0)" } }
    private func bucket(_ key: String) -> StatisticsBucket? { buckets.first { String($0.first) == key } }
    var body: some View {
        Chart(buckets) { bucket in
            BarMark(x: .value(String(localized: "日期"), String(bucket.first)), y: .value(String(localized: "阅读分钟"), Double(bucket.durationMs) / 60_000), width: .ratio(0.6))
                .foregroundStyle(Color(uiColor: theme.accent))
                .cornerRadius(3)
        }
        .chartXScale(domain: keys)
        .chartYScale(domain: 0...(StatisticsDates.axisSteps(maximum).last ?? maximum))
        .chartXAxis {
            AxisMarks(values: keys) { value in
                AxisValueLabel {
                    if let key = value.as(String.self), let bucket = bucket(key) { Text(verbatim: label(bucket)).font(.caption2) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: StatisticsDates.axisSteps(maximum)) { value in
                AxisGridLine()
                AxisValueLabel { if let minutes = value.as(Double.self) { Text(verbatim: StatisticsDates.axisMinutes(minutes)).font(.caption2) } }
            }
        }
        .chartOverlay { proxy in
            if let open {
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { location in
                        // The whole column belongs to its bucket, including the gaps between bars.
                        guard let frame = proxy.plotFrame else { return }
                        let plot = geometry[frame]
                        let column = Int(((location.x - plot.minX) / max(1, plot.width) * CGFloat(keys.count)).rounded(.down))
                        guard keys.indices.contains(column), let bucket = bucket(keys[column]) else { return }
                        open(bucket)
                    }
                }
            }
        }
        .frame(height: 150)
        // Axis labels share fixed columns; exact values scale elsewhere and in VoiceOver.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityRepresentation {
            VStack {
                ForEach(buckets) { bucket in
                    if let open, bucket.durationMs > 0 {
                        Button("\(accessibilityLabel(bucket))，\(StatisticsDates.duration(bucket.durationMs))") { open(bucket) }
                    } else {
                        Text("\(accessibilityLabel(bucket))，\(StatisticsDates.duration(bucket.durationMs))")
                    }
                }
            }
        }
        .accessibilityIdentifier("statisticsRhythmChart")
    }
}

private struct ReadingSessionsChart: View {
    let spans: [StatisticsSpan]
    let singleBook: Bool
    @State private var selectedHour: Double?
    @Environment(\.theme) private var theme
    private func row(_ value: StatisticsSpan) -> String { singleBook ? String(value.day) : value.key }
    private func rowLabel(_ key: String) -> String {
        guard let span = spans.first(where: { row($0) == key }) else { return key }
        return singleBook ? StatisticsDates.dateLabel(span.day) : span.title
    }
    private var rows: [String] { spans.reduce(into: []) { if !$0.contains(row($1)) { $0.append(row($1)) } } }
    private var keys: [String] { Array(Set(spans.map(\.key))).sorted() }
    private var domain: ClosedRange<Double> {
        let low = max(0, floor(spans.map(\.startClock).min() ?? 0))
        return low...min(24, max(low + 1, ceil(spans.map(\.endClock).max() ?? 24)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(spans) { span in
                    BarMark(xStart: .value(String(localized: "开始钟点"), span.startClock), xEnd: .value(String(localized: "结束钟点"), span.endClock),
                            y: .value(singleBook ? String(localized: "阅读日期") : String(localized: "书籍"), row(span)), height: .ratio(0.45))
                        .foregroundStyle(by: .value(String(localized: "书籍"), span.key))
                        .accessibilityLabel("\(span.title)，\(StatisticsDates.dateLabel(span.day))，\(span.time)")
                        .accessibilityValue(StatisticsDates.duration(span.milliseconds))
                }
                if let hour = selectedHour { RuleMark(x: .value(String(localized: "所选钟点"), hour)).foregroundStyle(Color(uiColor: theme.secondary).opacity(0.3)) }
            }
            .chartForegroundStyleScale(domain: keys, range: keys.map { theme.statisticsColor($0) })
            .chartLegend(.hidden).chartXScale(domain: domain).chartYScale(domain: rows)
            .chartXSelection(value: $selectedHour)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let hour = value.as(Double.self) { Text(String(format: "%02d:%02d", Int(hour), Int((hour.truncatingRemainder(dividingBy: 1) * 60).rounded()))) } }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let key = value.as(String.self) { Text(verbatim: rowLabel(key)).font(.caption2).lineLimit(1).frame(maxWidth: 100, alignment: .leading) }
                    }
                }
            }
            .frame(height: CGFloat(max(1, rows.count)) * 36 + 30)
            .accessibilityIdentifier("readingSessionsChart")
            if let hour = selectedHour {
                ForEach(spans.filter { hour >= $0.startClock && hour <= $0.endClock }) { span in
                    Text("\(rowLabel(row(span))) · \(span.time) · \(StatisticsDates.duration(span.milliseconds))").font(.caption)
                        .foregroundStyle(Color(uiColor: theme.secondary))
                }
            }
        }.padding(.vertical, 8)
    }
}

private struct ReadingSessionRow: View {
    let span: StatisticsSpan
    let showBook: Bool
    @Environment(\.theme) private var theme
    @State private var confirmDelete = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(showBook ? span.title : StatisticsDates.dateLabel(span.day)).lineLimit(1)
                Spacer()
                Text(StatisticsDates.duration(span.milliseconds)).font(.subheadline).monospacedDigit()
            }
            HStack {
                Text(span.time)
                if span.preview { Text("查阅") }
            }.font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
        }.padding(.vertical, 4)
            .contextMenu { Button("删除本次阅读记录", systemImage: "trash", role: .destructive) { confirmDelete = true } }
            .confirmationDialog("删除本次阅读记录？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除记录", role: .destructive) { Task { do { try await ReaderService.shared.deleteStatistics(book: span.key, session: span.sessionID) } catch { self.error = ReaderMessages.error(error) } } }
            } message: { Text("删除这次开书产生的统计片段，正文和续读位置会保留。") }
            .alert("暂时无法完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("知道了", role: .cancel) { error = nil } } message: { Text(error ?? "") }
    }
}

/// A weekday-aligned month. Days that have not happened are outlined, not zero;
/// tapping a day with reading opens that day.
private struct ReadingCalendarChart: View {
    let days: [StatisticsDay]
    let month: ClosedRange<Int64>
    let today: Int64
    let open: (Int64) -> Void
    @Environment(\.theme) private var theme
    private var first: Int64 { month.lowerBound }
    private var shift: Int {
        let weekday = StatisticsDates.civilCalendar.component(.weekday, from: StatisticsDates.date(first))
        return (weekday - Calendar.current.firstWeekday + 7) % 7
    }
    private var cells: [StatisticsBucket] { StatisticsBuckets.days(days, range: month) }
    private var maximum: UInt64 { max(1, cells.map(\.durationMs).max() ?? 1) }
    private var rows: Int { (shift + cells.count + 6) / 7 }
    private func position(_ day: Int64) -> (column: Int, row: Int) {
        let index = Int(day - first) + shift
        // Charts place larger values higher; the first week sits at the top.
        return (index % 7, rows - 1 - index / 7)
    }
    private func fill(_ cell: StatisticsBucket) -> Color {
        if cell.first > today { return .clear }
        if cell.durationMs == 0 { return Color(uiColor: theme.raised) }
        return Color(uiColor: theme.accent).opacity(0.25 + 0.75 * Double(cell.durationMs) / Double(maximum))
    }
    private func ink(_ cell: StatisticsBucket) -> Color {
        if cell.first > today { return Color(uiColor: theme.secondary) }
        return Color(uiColor: cell.durationMs > 0 && cell.durationMs * 2 >= maximum ? theme.onAccent : theme.ink)
    }
    var body: some View {
        Chart(cells) { cell in
            let place = position(cell.first)
            RectangleMark(xStart: .value(String(localized: "星期"), Double(place.column) - 0.43), xEnd: .value(String(localized: "星期"), Double(place.column) + 0.43),
                          yStart: .value(String(localized: "周"), Double(place.row) - 0.43), yEnd: .value(String(localized: "周"), Double(place.row) + 0.43))
                .foregroundStyle(fill(cell))
                .cornerRadius(4)
                .annotation(position: .overlay) {
                    Text("\(cell.first - first + 1)").font(.caption).fontWeight(cell.first == today ? .bold : .regular)
                        .foregroundStyle(ink(cell))
                }
        }
        .chartXScale(domain: -0.5...6.5)
        .chartYScale(domain: -0.5...(Double(rows) - 0.5), range: .plotDimension(startPadding: 0, endPadding: 0))
        .chartYAxis(.hidden).chartXAxis {
            AxisMarks(position: .top, values: Array(0...6)) { value in
                AxisValueLabel { if let value = value.as(Int.self) { Text(Calendar.current.veryShortStandaloneWeekdaySymbols[(value + Calendar.current.firstWeekday - 1) % 7]) } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { location in
                    guard let frame = proxy.plotFrame,
                          let x = proxy.value(atX: location.x - geometry[frame].origin.x, as: Double.self),
                          let y = proxy.value(atY: location.y - geometry[frame].origin.y, as: Double.self) else { return }
                    let day = first + Int64((rows - 1 - Int(y.rounded())) * 7 + Int(x.rounded()) - shift)
                    if month.contains(day), day <= today, cells.first(where: { $0.first == day })?.durationMs ?? 0 > 0 { open(day) }
                }
            }
        }
        .frame(height: CGFloat(rows) * 34 + 24)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityRepresentation {
            VStack {
                ForEach(cells.filter { $0.first <= today }) { cell in
                    if cell.durationMs > 0 {
                        Button("\(StatisticsDates.dateLabel(cell.first))，\(StatisticsDates.duration(cell.durationMs))") { open(cell.first) }
                    } else {
                        Text("\(StatisticsDates.dateLabel(cell.first))，\(StatisticsDates.duration(0))")
                    }
                }
            }
        }
        .accessibilityIdentifier("readingCalendarChart")
    }
}

/// One local calendar day: its clock-hour timeline and exact sessions.
struct StatisticsDayView: View {
    let route: StatisticsDayRoute
    @Environment(\.theme) private var theme
    @State private var spans: [StatisticsSpan] = []
    @State private var compatibilityNotice: String?
    @State private var loaded = false
    @State private var error: String?
    private var total: UInt64 { spans.reduce(0) { $0 + $1.milliseconds } }
    var body: some View {
        List {
            if error == nil, let compatibilityNotice { Text(compatibilityNotice).listRowBackground(Color(uiColor: theme.surface)) }
            if let error {
                Text(error).foregroundStyle(Color(uiColor: theme.destructive)).listRowBackground(Color(uiColor: theme.surface))
            } else if loaded && spans.isEmpty {
                ContentUnavailableView("这天没有阅读记录", systemImage: "book.closed").listRowBackground(Color.clear)
            } else if loaded {
                Section {
                    Text(StatisticsDates.duration(total)).font(.title2.weight(.semibold)).monospacedDigit()
                    ReadingSessionsChart(spans: spans, singleBook: false)
                }.listRowBackground(Color(uiColor: theme.surface))
                Section("阅读时段") {
                    ForEach(spans.reversed()) { ReadingSessionRow(span: $0, showBook: route.book == nil) }
                }.listRowBackground(Color(uiColor: theme.surface))
            }
        }
        .themedPage()
        .navigationTitle(StatisticsDates.dateLabel(route.day, full: true)).navigationBarTitleDisplayMode(.inline)
        .overlay { if !loaded && error == nil { LoadingActivity(fullPage: true, waitingLabel: "正在读取统计") } }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .statisticsChanged).receive(on: DispatchQueue.main)) { _ in Task { await load() } }
        .accessibilityIdentifier("statisticsDay")
        .onReceive(NotificationCenter.default.publisher(for: .cloudDataReceived).receive(on: DispatchQueue.main)) { _ in Task { await load() } }
    }
    private func load() async {
        do {
            await StatisticsWriter.shared.drain()
            compatibilityNotice = try await ReaderService.shared.statisticsCompatibilityNotice(book: route.book)
            spans = StatisticsSpan.merge(try await ReaderService.shared.activities(first: route.day, last: route.day, book: route.book))
            error = nil
        } catch { self.error = ReaderMessages.error(error) }
        loaded = true
    }
}

struct StatisticsSettingsView: View {
    @State private var enabled = true
    @State private var clearing = false
    @State private var error: String?
    @Environment(\.theme) private var theme
    var body: some View {
        Form {
            Section {
                Toggle("在此设备记录阅读统计", isOn: Binding(get: { enabled }, set: { value in
                    enabled = value
                    Task { do { await StatisticsWriter.shared.drain(); try await ReaderService.shared.setStatisticsEnabled(value) } catch { enabled = !value; self.error = ReaderMessages.error(error) } }
                })).accessibilityIdentifier("statisticsEnabled")
            } footer: { Text("只记录可见正文的阅读活动。锁屏、后台和工具面板中暂停；连续 2 分钟没有正文操作后暂停，再次操作恢复。") }
                .listRowBackground(Color(uiColor: theme.surface))
            Section {
                Button("清除阅读统计", role: .destructive) { clearing = true }.accessibilityIdentifier("clearStatistics")
                    .foregroundStyle(Color(uiColor: theme.destructive))
            } footer: { Text("不影响小说文件、续读位置、书签和笔记。历史阅读时长无法由旧进度补算。") }
                .listRowBackground(Color(uiColor: theme.surface))
        }.themedPage().navigationTitle("阅读统计设置").navigationBarTitleDisplayMode(.inline)
            .task { enabled = await ReaderService.shared.statisticsPreferences().enabled }
            .confirmationDialog("清除阅读统计？", isPresented: $clearing, titleVisibility: .visible) {
                Button("清除阅读统计", role: .destructive) { Task { do { try await ReaderService.shared.deleteStatistics() } catch { self.error = ReaderMessages.error(error) } } }
            }
            .alert("暂时无法完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("知道了", role: .cancel) { error = nil } } message: { Text(error ?? "") }
    }
}
