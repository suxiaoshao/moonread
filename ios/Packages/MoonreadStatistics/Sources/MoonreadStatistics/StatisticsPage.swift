import MoonreadCoreBindings
import MoonreadDataTypes
import MoonreadDesign
import SwiftUI

public struct StatisticsPage<Route: Hashable>: View {
    private typealias Model = StatisticsModel
    private let target: StatisticsTarget?
    private let theme: StatisticsAppearance
    private let source: StatisticsDataSource
    private let now: () -> Date
    private let jumpToReading: Bool
    private let writerError: String?
    private let openSettings: () -> Void
    private let refreshBook: () async -> Void
    private let routeForBook: (StatisticsBook, StatisticsWindow) -> Route
    private let cover: (StatisticsBook) -> AnyView
    private let titleMatches: (String, String) -> Bool
    private let loading: (CGFloat, Bool) -> AnyView
    private let bookContext: () -> AnyView
    private let bookFooter: () -> AnyView
    private let optionsMenu: (StatisticsWindow, @escaping () -> Void) -> AnyView

    @Environment(\.scenePhase) private var scenePhase
    @State private var model: Model
    @State private var window: StatisticsWindow
    @State private var lastCalendarDate: Date
    @State private var publishedRange: DisplayRange?
    @State private var sortByDuration = false
    @State private var showAllBooks = false
    @State private var openedDay: StatisticsDayRoute?
    @State private var deleteBook = false
    @State private var positionedAtReading = false

    public init(target: StatisticsTarget?, initialWindow: StatisticsWindow, theme: StatisticsAppearance,
                source: StatisticsDataSource, now: @escaping () -> Date,
                jumpToReading: Bool, writerError: String?, openSettings: @escaping () -> Void,
                refreshBook: @escaping () async -> Void,
                routeForBook: @escaping (StatisticsBook, StatisticsWindow) -> Route,
                cover: @escaping (StatisticsBook) -> AnyView,
                titleMatches: @escaping (String, String) -> Bool,
                loading: @escaping (CGFloat, Bool) -> AnyView,
                bookContext: @escaping () -> AnyView, bookFooter: @escaping () -> AnyView,
                optionsMenu: @escaping (StatisticsWindow, @escaping () -> Void) -> AnyView) {
        self.target = target
        self.theme = theme
        self.source = source
        self.now = now
        self.jumpToReading = jumpToReading
        self.writerError = writerError
        self.openSettings = openSettings
        self.refreshBook = refreshBook
        self.routeForBook = routeForBook
        self.cover = cover
        self.titleMatches = titleMatches
        self.loading = loading
        self.bookContext = bookContext
        self.bookFooter = bookFooter
        self.optionsMenu = optionsMenu
        _model = State(initialValue: Model(source: source))
        _window = State(initialValue: initialWindow)
        _lastCalendarDate = State(initialValue: initialWindow.period.browsable ? initialWindow.date : now())
    }

    private var periodSelection: Binding<StatisticsPeriod> {
        Binding(get: { window.period }, set: { period in
            if window.period.browsable { lastCalendarDate = window.date }
            window = StatisticsWindow(period: period, date: lastCalendarDate)
        })
    }

    private var requestedRange: DisplayRange {
        let calendar = Calendar.current
        let today = StatisticsDates.day(now(), calendar: calendar)
        return .init(window: window, today: today, label: window.label(today: today),
                     scope: model.scope(window, target: target, today: today, calendar: calendar))
    }
    private var displayedRange: DisplayRange {
        let request = requestedRange
        if model.state(request.scope).content == nil,
           let publishedRange, publishedRange.scope.target == request.scope.target,
           model.state(publishedRange.scope).overview != nil {
            return publishedRange
        }
        return request
    }
    private var readingState: Model.State { model.state(requestedRange.scope) }
    private var statisticsState: Model.State { model.state(displayedRange.scope) }
    private var showingPreviousRange: Bool { displayedRange.scope != requestedRange.scope }
    private var orderedBooks: [StatisticsBook] {
        let books = statisticsState.overview?.books ?? []
        return sortByDuration ? books.sorted {
            if $0.durationMs != $1.durationMs { return $0.durationMs > $1.durationMs }
            if $0.lastFormalMs != $1.lastFormalMs { return $0.lastFormalMs > $1.lastFormalMs }
            return serializeReadingKey(key: $0.contentKey) < serializeReadingKey(key: $1.contentKey)
        } : books
    }
    private var total: UInt64 { statisticsState.overview?.totalDurationMs ?? 0 }

    public var body: some View {
        let request = requestedRange
        ScrollViewReader { proxy in
        contentList
        .task(id: LoadRequest(range: request, dataRevision: model.dataRevision)) {
            await model.observe(request.scope, retaining: publishedRange?.scope) {
                if publishedRange != request { publishedRange = request }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.restartObservation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: DispatchQueue.main)) { _ in
            model.restartObservation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: DispatchQueue.main)) { _ in
            model.restartObservation()
        }
        .onChange(of: readingSectionReady, initial: true) { _, ready in
            if ready, !positionedAtReading {
                positionedAtReading = true
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo("myReading", anchor: .top) }
            }
        }
        .onDisappear { model.cancel() }
        .refreshable {
            if target != nil { await refreshBook() }
            model.restartObservation()
        }
        .alert("清除本书的阅读统计？", isPresented: $deleteBook) {
            Button("清除统计", role: .destructive) {
                guard let key = readingState.key else { return }
                Task { do { try await source.delete(key, nil) } catch { model.report(error, scope: requestedRange.scope) } }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("正文、续读位置、书签和笔记会保留。") }
        .alert("暂时无法完成", isPresented: Binding(get: { readingState.error != nil && statisticsState.overview != nil && !showingPreviousRange }, set: { if !$0 { model.clearError(requestedRange.scope) } })) {
            Button("重试") { model.restartObservation() }
            Button("知道了", role: .cancel) { model.clearError(requestedRange.scope) }
        } message: { Text(readingState.error ?? "") }
        .accessibilityIdentifier(target == nil ? "statisticsOverview" : "statisticsBook")
        }
    }

    private var contentList: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760
            ScrollView {
                let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 28)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
                layout {
                    contextSections
                        .frame(width: wide ? min(380, (geometry.size.width - 60) * 0.43) : nil)
                        .frame(maxWidth: wide ? nil : .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 24) {
                        statisticsSections
                        bookFooter()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding([.horizontal, .top], 20).padding(.bottom).frame(maxWidth: 1200).frame(maxWidth: .infinity)
            }
        }
        .modifier(theme.page)
        .navigationTitle(target == nil ? String(localized: "统计") : String(localized: "小说详情"))
        .navigationBarTitleDisplayMode(target == nil ? .large : .inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                optionsMenu(window) { deleteBook = true }
            }
        }
        .navigationDestination(item: $openedDay) { StatisticsDayView(route: $0, theme: theme, source: source, loading: loading) }
        .navigationDestination(isPresented: $showAllBooks) {
            StatisticsBookList(books: orderedBooks, maximum: orderedBooks.map(\.durationMs).max() ?? 1, window: displayedRange.window,
                               theme: theme, routeForBook: routeForBook, cover: cover, titleMatches: titleMatches)
        }
    }

    @ViewBuilder private var contextSections: some View {
        if target != nil {
            bookContext()
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Picker("统计范围", selection: periodSelection) {
                    ForEach(StatisticsPeriod.allCases) { period in
                        Text(period == .recent ? "7 天" : period.label).tag(period)
                    }
                }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("statisticsPeriod")
                VStack(alignment: .leading, spacing: 8) {
                    summaryRangeHeader
                    if showingPreviousRange { previousRangeCaption }
                    if let overview = statisticsState.overview {
                        Text(StatisticsDates.duration(total)).font(.title.weight(.semibold)).monospacedDigit()
                        Text("\(overview.activeDayCount) 个阅读日 · \(overview.books.count) 本书")
                            .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                    } else if statisticsState.loading {
                        ProgressView("正在读取统计").font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary)).frame(maxWidth: .infinity)
                    } else if statisticsState.error != nil {
                        Text("—").font(.title.weight(.semibold))
                        Text("暂不可用").font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
            }
        }
    }

    private var statisticsSections: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("阅读统计").font(.headline).foregroundStyle(Color(uiColor: target == nil ? theme.secondary : theme.ink))
                Spacer()
                if target != nil { periodMenu }
            }
            statisticsStatus
            if let overview = statisticsState.overview {
                if target != nil {
                    periodNavigation
                    if showingPreviousRange { previousRangeCaption }
                }
                if showingPreviousRange, let error = readingState.error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Color(uiColor: theme.destructive))
                    Button("重试") { model.restartObservation() }
                }
                if overview.books.isEmpty, target != nil {
                    Text("这段时间暂无阅读记录")
                        .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                        .padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
                        .accessibilityIdentifier("statisticsEmpty")
                } else if overview.books.isEmpty {
                    ContentUnavailableView {
                        Label("暂无阅读记录", systemImage: "book.closed")
                    } description: {
                        Text(overview.preferences.enabled ? String(localized: "开始阅读后，这里会显示书籍、阅读时段和时长。") : String(localized: "开启阅读统计后记录新的阅读活动。"))
                    }.frame(maxWidth: .infinity, minHeight: 230)
                        .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
                        .accessibilityIdentifier("statisticsEmpty")
                } else {
                    periodSummary(overview)
                }
                if !overview.books.isEmpty {
                    if target == nil { bookSection } else { sessionsSection }
                }
                if target != nil { cumulativeSummary }
            } else if let error = statisticsState.error {
                ContentUnavailableView {
                    Label("暂时无法读取统计", systemImage: "exclamationmark.circle")
                } description: { Text(error) } actions: {
                    Button("重试") { model.restartObservation() }
                }.frame(maxWidth: .infinity, minHeight: 230)
                    .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
            } else if statisticsState.content?.waitingForIdentity == true {
                Text("阅读统计暂不可用")
                    .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if statisticsState.loading {
                loading(52, false).frame(maxWidth: .infinity, minHeight: 230)
            }
        }
    }

    @ViewBuilder private var statisticsStatus: some View {
        if let overview = statisticsState.overview,
           !overview.preferences.enabled || statisticsState.compatibilityNotice != nil || writerError != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if !overview.preferences.enabled { Label("阅读统计已暂停", systemImage: "pause.circle") }
                    Spacer()
                    Button("统计设置") { openSettings() }
                }
                if statisticsState.compatibilityNotice != nil || writerError != nil {
                    DisclosureGroup {
                        if let notice = statisticsState.compatibilityNotice { Text(verbatim: notice) }
                        if let error = writerError { Text(verbatim: error).foregroundStyle(Color(uiColor: theme.destructive)) }
                    } label: {
                        Label(writerError != nil ? String(localized: "部分阅读记录未能保存") : String(localized: "部分统计暂不可用"), systemImage: "exclamationmark.circle")
                    }
                }
            }.font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                .padding(12).background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 12)).accessibilityIdentifier("statisticsStatus")
        }
    }

    private struct DisplayRange: Hashable {
        let window: StatisticsWindow
        let today: Int64
        let label: String
        let scope: Model.Scope
    }
    private struct LoadRequest: Hashable {
        let range: DisplayRange
        let dataRevision: UInt64
    }
    private var previousRangeCaption: some View {
        Text("当前仍显示：\(displayedRange.label)")
            .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
    }
    private var readingSectionReady: Bool { jumpToReading && statisticsState.overview != nil }

    private func detailFact(_ label: LocalizedStringKey, value: String) -> some View {
        LabeledContent {
            Text(verbatim: value).foregroundStyle(Color(uiColor: theme.ink))
        } label: {
            Text(label).foregroundStyle(Color(uiColor: theme.secondary))
        }.font(.subheadline)
    }

    @ViewBuilder private var cumulativeSummary: some View {
        if let book = statisticsState.cumulative {
            let first = Date(timeIntervalSince1970: Double(book.firstReadMs) / 1000)
            let last = Date(timeIntervalSince1970: Double(book.lastReadMs) / 1000)
            VStack(alignment: .leading, spacing: 12) {
                Text("累计阅读").font(.headline)
                VStack(alignment: .leading, spacing: 8) {
                    if displayedRange.window.period != .all {
                        durationSummary(book.durationMs, days: book.readingDays)
                    }
                    if Calendar.current.isDate(first, inSameDayAs: last) {
                        detailFact("阅读日期", value: first.formatted(date: .abbreviated, time: .omitted))
                    } else {
                        detailFact("首次阅读", value: first.formatted(date: .abbreviated, time: .omitted))
                        detailFact("最近阅读", value: last.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
            }
        } else if statisticsState.content?.detailsLoaded == false, statisticsState.loading {
            loading(24, false)
        }
    }
    private func periodSummary(_ overview: StatisticsOverview) -> some View {
        let range = displayedRange
        let rhythm = StatisticsRhythm(period: range.window.period, bounds: range.scope.bounds, days: overview.days,
                                      today: range.today, book: target == nil ? nil : statisticsState.key, theme: theme) { openedDay = $0 }
        return VStack(alignment: .leading, spacing: 18) {
            if target != nil {
                durationSummary(total, days: UInt64(overview.activeDayCount))
                    .accessibilityElement(children: .combine).accessibilityIdentifier("statisticsSummary")
            }
            if rhythm.hasContent { rhythm }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
    }
    private func durationSummary(_ duration: UInt64, days: UInt64) -> some View {
        let time = Text(StatisticsDates.duration(duration)).font(.body.weight(.medium)).monospacedDigit()
            .foregroundStyle(Color(uiColor: theme.ink))
        let days = Text("\(days) 个阅读日").font(.subheadline)
            .foregroundStyle(Color(uiColor: theme.secondary))
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) { time; days }
            VStack(alignment: .leading) { time; days }
        }
    }
    private var periodMenu: some View {
        Picker("统计范围", selection: periodSelection) {
            ForEach(StatisticsPeriod.allCases) { Text($0.label).tag($0) }
        }.pickerStyle(.menu).labelsHidden().accessibilityIdentifier("statisticsPeriod")
    }
    private var summaryRangeHeader: some View {
        HStack(spacing: 0) {
            if window.period.browsable {
                Button { window.shift(-1) } label: {
                    Image(systemName: "chevron.left").frame(minWidth: ControlMetrics.hitSize, minHeight: ControlMetrics.hitSize).contentShape(.rect)
                }
                .accessibilityLabel(window.period == .month ? Text("上一月") : Text("上一年"))
                .accessibilityIdentifier("statisticsPreviousPeriod")
            }
            Text(requestedRange.label).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                .multilineTextAlignment(window.period.browsable ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: window.period.browsable ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("statisticsRange")
            if window.period.browsable {
                Button { window.shift(1) } label: {
                    Image(systemName: "chevron.right").frame(minWidth: ControlMetrics.hitSize, minHeight: ControlMetrics.hitSize).contentShape(.rect)
                }
                .disabled(!window.canAdvance(today: requestedRange.today))
                .accessibilityLabel(window.period == .month ? Text("下一月") : Text("下一年"))
                .accessibilityIdentifier("statisticsNextPeriod")
            }
        }.buttonStyle(.plain)
    }
    private var periodNavigation: some View {
        HStack {
            if window.period.browsable {
                Button { window.shift(-1) } label: { Image(systemName: "chevron.left").frame(minWidth: ControlMetrics.hitSize, minHeight: ControlMetrics.hitSize) }
                    .accessibilityLabel("上一时段")
            }
            Text(requestedRange.label).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("statisticsRange")
            if window.period.browsable {
                Button { window.shift(1) } label: { Image(systemName: "chevron.right").frame(minWidth: ControlMetrics.hitSize, minHeight: ControlMetrics.hitSize) }
                    .disabled(!window.canAdvance(today: requestedRange.today)).accessibilityLabel("下一时段")
            }
        }.buttonStyle(.plain)
    }
    private var bookSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("读过的书").font(.headline).foregroundStyle(Color(uiColor: theme.secondary))
                Spacer()
                Menu {
                    Picker("排序", selection: $sortByDuration) {
                        Text("最近阅读").tag(false); Text("阅读时长").tag(true)
                    }
                } label: { Label(sortByDuration ? String(localized: "阅读时长") : String(localized: "最近阅读"), systemImage: "arrow.up.arrow.down").font(.subheadline) }
            }
            VStack(spacing: 0) {
                ForEach(Array(orderedBooks.prefix(5)), id: \.contentKey) { book in
                    StatisticsBookRow(book: book, maximum: orderedBooks.map(\.durationMs).max() ?? 1, route: routeForBook(book, displayedRange.window), theme: theme, cover: cover)
                        .buttonStyle(.plain).padding(16)
                    if book.contentKey != orderedBooks.prefix(5).last?.contentKey { theme.divider }
                }
                if orderedBooks.count > 5 {
                    theme.divider
                    Button("查看全部书籍") { showAllBooks = true }.frame(maxWidth: .infinity, minHeight: ControlMetrics.hitSize)
                }
            }.background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
        }
    }
    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("阅读时段").font(.headline)
                Spacer()
            }
            VStack(spacing: 0) {
                if statisticsState.content?.detailsLoaded == false {
                    if statisticsState.loading { loading(24, false).padding(16) }
                    else { Text("—").padding(16) }
                } else {
                    let spans = statisticsState.spans
                    let dayCount = Set(spans.map(\.day)).count
                    ForEach(Array(spans.reversed().prefix(3))) { span in
                        ReadingSessionRow(span: span, showBook: false, compact: true, theme: theme,
                                          delete: source.delete, errorMessage: { source.describeError($0).message }).padding(16)
                        theme.divider
                    }
                    if dayCount > 0 {
                        NavigationLink {
                            StatisticsSessionsView(spans: spans, theme: theme, delete: source.delete,
                                                   errorMessage: { source.describeError($0).message })
                        } label: {
                            HStack {
                                Text("查看最近 \(dayCount) 个阅读日的时段")
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).accessibilityHidden(true)
                            }.font(.subheadline).padding(16).frame(minHeight: ControlMetrics.hitSize)
                        }
                    }
                }
            }.background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
                .accessibilityIdentifier("bookReadingSessions")
        }
    }
}
