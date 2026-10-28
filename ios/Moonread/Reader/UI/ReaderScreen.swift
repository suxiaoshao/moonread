import TipKit
import SwiftUI
import UIKit

private enum ReaderExitPhase { case reading, saving, ready, returned }

struct ReaderScreen: View {
    let route: ReaderRoute
    var openingRequest: OpeningRequest? = nil
    let onExit: (String?, UInt64) -> Void
    @State private var session = ReaderSession()
    @State private var ui = ReaderUIState()
    @State private var context: ReaderPresentationContext?
    @Environment(\.readerPresentation) private var native
    @Environment(LibraryModel.self) private var library
    @Environment(AIService.self) private var ai
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    @State private var contentVisible = false
    @State private var completedOpeningID: UUID?
    @State private var coverInformation: BookDetails?
    @State private var controlsTipHeight: CGFloat = 0
    @State private var readerWidth: CGFloat = 390
    @State private var localHeaderTop: CGFloat = 0
    @State private var bodyLayout = ReaderBodyLayout()
    @State private var battery = ReaderBattery()
    @State private var exitPhase = ReaderExitPhase.reading
    @State private var reviewExitIsNormal = false
    @State private var aiMoonPosition: CGPoint?
    @State private var aiPresence = AIMoonPresence()
    @State private var returnToReading = ReturnToReading()
    private let compactHeaderHeight: CGFloat = 22
    private var isWide: Bool { horizontalSizeClass == .regular }
    private var plan: ReaderPresentationPlan { context?.plan ?? ReaderPresentationPlan() }
    private var controlsVisible: Bool { ui.controlsVisible }

    private var readerContent: some View {
        Group {
            if session.opening.phase == .reading, let window = session.window, let settings = session.settings {
                readingView(window: window, settings: settings)
            } else if session.opening.phase == .titlePage || !ReaderOpenDiagnostics.deferredPage {
                preparationView
                    .background(ReaderPlaceholderWitness {
                        if let id = session.opening.request?.id { session.opening.placeholderDisplayed(id) }
                    })
                    .transition(.opacity)
            } else { Color(uiColor: theme.paper) }
        }
        .modifier(ReaderOpenContentFade(phase: session.opening.phase, enabled: session.opening.fadesContent && !reduceMotion))
    }

    private func readingView(window: ReadingWindow, settings: ReaderSettings) -> some View {
        // Keep the representable (and its selection/pager) alive when the native
        // host changes size class; only its geometry input changes.
        GeometryReader { geometry in
            readingView(window: window, settings: settings,
                geometry: isWide ? ReadingContentGeometry(size: geometry.size) : nil)
                .overlay(alignment: .top) {
                    if isWide, !session.isLeaving, !readerNavigationVisible, let book = session.book {
                        ReaderCompactHeader(session: session, battery: battery, book: book, readerWidth: geometry.size.width,
                            compactHeaderHeight: compactHeaderHeight, showControls: { ui.controlsVisible = true })
                            .padding(.top, localHeaderTop)
                            .opacity(native?.suspended == true ? 0 : 1)
                    }
                }
        }.ignoresSafeArea(.container, edges: isWide ? [.top, .bottom] : [])
    }

    private func readingView(window: ReadingWindow, settings: ReaderSettings, geometry: ReadingContentGeometry?) -> some View {
                ReadingView(window: window, settings: settings, anchor: session.displayAnchor ?? session.anchor,
                            openingID: session.opening.request?.id,
                            requestWindow: { direction,keep in session.requestWindow(direction,retaining:keep) },
                            dark: colorScheme == .dark, dynamicTypeSize: dynamicTypeSize,
                            navigationRevision: session.navigationRevision,
                            navigation: session.navigation, viewportAccess: session.viewportAccess,
                            annotations: session.annotations, bookmarkPositions: session.bookmarkPositions, focusRange: session.focusRange,
                            selectionStart: session.selectionStart, selection: selectText,
                            allowsBackGesture: allowsReaderBack,
                            allowsSelection: plan.allowsSelection,
                            allowsChapterEditing: !session.incomplete,
                            coverTitle: session.book?.title ?? route.title,
                            coverInformation: coverInformation,
                            showBookDetails: { ui.show(.details) },
                            showingCover: session.showingCover,
                            coverChanged: { if native?.suspended != true { session.showingCover = $0 } },
                            brightnessChanged: { brightness in
                                guard var value = session.settings else { return }
                                value.brightness = brightness; session.updateSettings(value)
                            },
                            orientationFailed: {
                                guard var value = session.settings else { return }
                                value.orientation = .system; session.updateSettings(value)
                                session.error = String(localized: "当前无法切换屏幕方向，已恢复跟随系统。")
                            },
                            statisticsInteraction: { session.activity.interacted() },
                            edgeChanged: { session.nearEdge = $0 },
                            compactHeaderHeight: compactHeaderHeight,
                            guideHeight: Onboarding.shared.enabled && !Onboarding.shared.revealedControls && !ui.controlsVisible ? controlsTipHeight : 0,
                            contentGeometry: geometry,
                            headerPositionChanged: { localHeaderTop = $0 },
                            bodyLayoutChanged: { bodyLayout = $0; updateLayout() },
                            controlsVisible: ui.controlsVisible,
                            toggleControls: { if plan.allowsBodyInteraction { ui.controlsVisible.toggle() } },
                            readingBegan: { session.beganReadingInteraction(); ui.controlsVisible = false },
                            positionChanged: { offset, end in
                                if native?.suspended != true { session.moved(to: offset, settled: end, userInitiated: false) }
                            })
                    .allowsHitTesting(plan.allowsBodyInteraction)
                    .ignoresSafeArea(.container, edges: isWide ? [] : .all)
                    .accessibilityIdentifier("readingContent")
                    .modifier(ReaderImportDiagnosticStatus(complete: session.snapshot?.phase == .complete))
                    .transition(.opacity)
    }

    private var allowsReaderBack: Bool {
        exitPhase == .reading && native?.suspended != true
            && ui.editor == nil && (ui.foreground.tool == nil || ui.foreground.tool == .search)
            && ui.search?.expanded != true && session.error == nil && !session.navigating
    }
    private var readerNavigationVisible: Bool {
        !session.isLeaving && native?.suspended != true
            && (ui.controlsVisible || ui.foreground.tool == .progress || session.window == nil)
    }
    private var bookDetailsTarget: StatisticsRoute {
        if case .source(let source) = route {
            return StatisticsRoute(bookID: session.readingID, title: source.title, fileID: source.id, fromReader: true)
        }
        return StatisticsRoute(bookID: session.readingID, title: session.book?.title ?? route.title, fromReader: true)
    }

    var body: some View {
        lifecycleReader
            .alert("阅读遇到问题", isPresented: Binding(get: { !session.isLeaving && session.error != nil && session.book != nil },
                set: { if !$0 { session.error = nil } })) {
                Button("知道了", role: .cancel) { session.error = nil }
            } message: { Text(session.error ?? "") }
    }
    private var navigableReader: some View {
        readerContent
            .navigationTitle(session.book?.title ?? route.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(uiColor: theme.paper), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { readerToolbar }
            .toolbarVisibility(readerNavigationVisible ? .visible : .hidden, for: .navigationBar)
            .toolbarVisibility(readerNavigationVisible ? .visible : .hidden, for: .bottomBar)
            .toolbarVisibility(.hidden, for: .tabBar)
            .statusBarHidden(!readerNavigationVisible)
            .modifier(ReaderToolbarAxis(ui: ui))
            .navigationDestination(item: pagePath) { page in
                if page.kind == .settings {
                    if let context { context.settingsView().background(pageWitness(page)) }
                } else {
                    StatisticsView(library: library, target: bookDetailsTarget)
                        .themeScope(theme).preferredColorScheme(theme.scheme).toolbarVisibility(.hidden, for: .tabBar)
                        .environment(\.returnToReading, returnToReading)
                        .onAppear { returnToReading.close = { ui.closeTask() } }
                        .background(pageWitness(page))
                }
            }
    }
    private var presentedReader: some View {
        navigableReader
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { readerWidth = $0; updateLayout() }
            .ignoresSafeArea(.keyboard)
            .modifier(ReaderOpenLegacyFade(ready: session.window != nil, reduced: reduceMotion))
            .background(Color(uiColor: theme.paper))
            .background(NavigationTransitionObserver(openingID: session.opening.request?.id ?? openingRequest?.id,
                appeared: { id, reason in completedOpeningID = id; session.opening.settled(id, reason: reason) },
                visibilityChanged: { visible in
                    contentVisible = visible; session.opening.visibility(visible, active: scenePhase == .active)
                }, willLeave: { popping in
                    if popping { native?.suspended = true }
                }, completed: { popping, cancelled in
                    guard popping else { return }
                    if cancelled { native?.suspended = false }
                    else { completeReturning() }
                }, removed: completeReturning))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if Onboarding.shared.enabled, !Onboarding.shared.revealedControls, !ui.controlsVisible,
                   session.opening.phase == .reading, !session.isLeaving {
                    TipView(Onboarding.shared.controls).tipViewStyle(ThemedTipStyle()).padding(.horizontal)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsTipHeight = $0 }
                        .background(Color(uiColor: theme.paper)).accessibilityIdentifier("readerControlsTip")
                }
            }
            .overlay(alignment: .top) {
                if !isWide, !session.isLeaving, !readerNavigationVisible, let book = session.book {
                    ReaderCompactHeader(session: session, battery: battery, book: book, readerWidth: readerWidth,
                        compactHeaderHeight: compactHeaderHeight, showControls: { ui.controlsVisible = true })
                        .opacity(native?.suspended == true ? 0 : 1)
                }
            }
            .overlay(alignment: .top) {
                if !session.isLeaving, session.selectionStart != nil {
                    HStack {
                        Text("跨页选取中").font(.caption)
                        Button("取消") { session.selectionStart = nil }
                    }.padding(12).background(theme.floatingBackground(), in: .capsule).padding(.top, 26)
                }
            }
            .overlay { aiMoon }
            .overlay(alignment: .bottom) {
                if !ui.controlsVisible, ui.foreground.tool == nil, ui.editor == nil,
                   !session.isLeaving, session.opening.phase == .reading, !session.continuationCollapsed {
                    continuationControl.padding(.horizontal, 16).padding(.bottom, 24)
                }
            }
            #if DEBUG
            .overlay(alignment: .bottomTrailing) {
                if ReaderSmokeFixture.enabled {
                    Button("测试批注") { selectText(start: 0, end: 3, action: .comment) }.accessibilityIdentifier("smokeAddNote")
                }
            }
            #endif
    }
    private var registeredReader: some View {
        presentedReader
            .task {
                library.systemReading.register(session, navigationID: openingRequest?.id)
                await session.open(route, request: openingRequest)
            }
            .onAppear {
                if context == nil {
                    context = ReaderPresentationContext(ui: ui, session: session, route: route, surface: theme,
                        aiContext: { aiContext() }, changeEncoding: changeEncoding)
                }
                if let context, !session.isLeaving { native?.attach(context) }
                updateLayout(); battery.start()
                contentVisible = true; session.opening.visibility(true, active: scenePhase == .active)
                session.opening.reduceMotion(reduceMotion)
            }
            .onChange(of: horizontalSizeClass) { _, _ in updateLayout() }
            .onChange(of: native?.hostWidth) { _, _ in updateLayout() }
            .onChange(of: native?.inspector?.width) { _, _ in updateLayout() }
            .onChange(of: session.settings) { _, _ in updateLayout() }
            .onChange(of: native?.retainedOpeningIDs) { _, _ in finishReturning() }
            .onChange(of: session.settings?.wideToolsExpanded) { _, _ in native?.reconcile() }
            .onChange(of: theme) { _, value in context?.surface = value }
            .onChange(of: ui.controlsVisible) { _, visible in
                if visible { session.refreshBookmark(); Onboarding.shared.didShowControls() }
            }
            .onChange(of: library.systemReading.pending) { _, request in
                if request != nil, ui.foreground.tool == nil, ui.editor == nil, ui.search == nil { ui.controlsVisible = false }
            }
            .onChange(of: systemReadingBlocked, initial: true) { _, blocked in library.systemReading.presentationBlocked = blocked }
            .onChange(of: session.opening.request?.id) { _, id in
                if let id, completedOpeningID == id { session.opening.settled(id, reason: "observedAppearance") }
            }
            .onChange(of: session.navigating) { _, navigating in
                if !navigating { ui.finishLibraryNavigation(revision: session.navigationRevision) }
            }
    }
    private var dataAwareReader: some View {
        registeredReader
            .task(id: session.book?.contentSha256) {
                await loadCoverInformation()
                if statisticsReadable { session.systemReadingBecameReadable() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .bookMetadataChanged).receive(on: DispatchQueue.main)) { _ in Task { await loadCoverInformation() } }
            .onReceive(NotificationCenter.default.publisher(for: .cloudDataReceived).receive(on: DispatchQueue.main)) { _ in Task { session.notesChanged(); await loadCoverInformation() } }
            .onReceive(NotificationCenter.default.publisher(for: .cloudReadingPositionsReceived).receive(on: DispatchQueue.main)) { _ in Task { await session.refreshSyncedContinuation() } }
            .onReceive(NotificationCenter.default.publisher(for: .readingContinuationInvalidated).receive(on: DispatchQueue.main)) { _ in session.invalidateSyncedContinuation() }
            .onChange(of: statisticsReadable, initial: true) { _, readable in
                session.activity.update(readable: readable, preview: session.browseOrigin != nil)
                if readable { session.systemReadingBecameReadable() }
            }
            .onChange(of: session.browseOrigin != nil) { _, preview in session.activity.update(readable: statisticsReadable, preview: preview) }
            .onReceive(NotificationCenter.default.publisher(for: .statisticsPreferencesChanged).receive(on: DispatchQueue.main)) { _ in Task { await session.activity.reloadPreferences() } }
            .onChange(of: undoVisible, initial: true) { _, visible in ui.tools.setUndoVisible(visible) }
            .onChange(of: reduceMotion) { _, value in session.opening.reduceMotion(value) }
            .onChange(of: scenePhase) { _, phase in
                session.opening.visibility(contentVisible, active: phase == .active)
                guard !session.isLeaving else { return }
                if phase == .active { battery.refresh(); session.foreground() }
                else if phase == .background { BackgroundSave.perform(name: "保存阅读位置") { await session.flush() } }
                else { Task { await session.flush() } }
            }
    }
    private var lifecycleReader: some View {
        dataAwareReader
            .onChange(of: aiCurrentConversation?.moonSnapshot, initial: true) { _, snapshot in
                aiPresence.observe(snapshot, chatOpen: ui.foreground.tool == .ai) { aiCurrentConversation?.latestTurnProposes ?? false }
                revealAIMoonNotice()
            }
            .onChange(of: ui.foreground.tool == .ai) { _, open in
                if open { aiPresence.chatOpened() } else { aiPresence.chatClosed(); revealAIMoonNotice() }
            }
            .onChange(of: ai.availability.isAvailable) { _, available in
                if !available { if ui.foreground.tool == .ai { ui.closeTask() }; aiPresence.conceal() }
            }
            .onChange(of: aiNoticeAllowed) { _, allowed in if allowed { revealAIMoonNotice() } else { aiPresence.conceal() } }
            .task(id: aiPresence.shown?.id) {
                guard let shown = aiPresence.shown else { return }
                do { try await Task.sleep(for: shown.notice.duration) } catch { return }
                aiPresence.expire(shown.id)
            }
            .onDisappear {
                contentVisible = false; session.opening.visibility(false, active: false)
                session.activity.update(readable: false, preview: session.browseOrigin != nil); battery.stop()
                // Actual removal/pop, not a covering settings page, owns leave.
                if session.isLeaving { completeReturning() }
            }
    }

    private var bookmarkTitle: LocalizedStringKey { session.bookmarked ? "移除当前位置书签" : "添加当前位置书签" }
    @ToolbarContentBuilder private var readerToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(bookmarkTitle,
                systemImage: session.bookmarked ? "bookmark.fill" : "bookmark") { Task { await session.toggleBookmark() } }
                .disabled(session.showingCover || session.changingBookmark || session.window == nil)
                .accessibilityValue(session.bookmarked ? Text("已添加") : Text("未添加"))
                .accessibilityIdentifier("toggleBookmark")
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button("目录、书签与批注", systemImage: "list.bullet.rectangle") { openLibrary() }
                .accessibilityIdentifier("showChapters")
            Spacer()
            Button("搜索", systemImage: "magnifyingglass") { openTool(.search) }.accessibilityIdentifier("showSearch")
            Spacer()
            Button("阅读设置", systemImage: "textformat") { openTool(.settings) }.accessibilityIdentifier("readingSettings")
            Spacer()
            progressButton
            Spacer()
        }
        if #available(iOS 27, *) {
            ToolbarOverflowMenu { moreActions }
        } else {
            ToolbarItem(placement: .bottomBar) {
                Menu { moreActions } label: { Label("更多", systemImage: "ellipsis") }.accessibilityIdentifier("readerMore")
            }
        }
    }
    private var progressButton: some View {
        Button { openTool(.progress) } label: {
            if ui.layout.verticalToolbar { Label("阅读进度", systemImage: "percent") }
            else { Text(session.displayedProgressText).monospacedDigit() }
        }
        .accessibilityLabel("阅读进度").accessibilityValue(session.displayedProgressText)
        .accessibilityIdentifier("readerProgress").disabled(session.window == nil)
        .popover(isPresented: Binding(get: { plan.root == .progressPopover && native?.canShowPopover == true }, set: { shown in
            if !shown, plan.root == .progressPopover, native?.canShowPopover == true { ui.closeTask() }
        }), arrowEdge: nil) {
            if let context {
                ReaderProgressContent(context: context)
                    .background(NavigationTransitionObserver(
                        visibilityChanged: { native?.popoverVisibility($0, owner: ui.openingID) },
                        willLeave: { _ in }, completed: { _, _ in },
                        removed: { native?.popoverVisibility(false, owner: ui.openingID) }))
            }
        }
    }
    @ViewBuilder private var moreActions: some View {
        Button("小说详情", systemImage: "info.circle") { openTool(.details) }.accessibilityIdentifier("readerBookDetails")
        Button("跳转历史", systemImage: "clock.arrow.circlepath") { openTool(.history) }.accessibilityIdentifier("showReadingHistory")
        if session.encodingLabel != nil {
            ReaderEncodingMenu(title: "更换编码", symbol: "character.bubble", isRestarting: session.restartingEncoding, select: changeEncoding)
        }
    }
    private func openLibrary() {
        // The model alone owns the last selected chapter/bookmark/note segment.
        openTool(.library)
    }
    private func openTool(_ tool: ReaderTool) {
        guard !session.isLeaving, ui.editor == nil else { return }
        if tool == .library || tool == .search || tool == .settings {
            if ui.layout.canInspect, var settings = session.settings, settings.wideToolsExpanded != true {
                settings.wideToolsExpanded = true; session.updateSettings(settings)
            }
        }
        if tool == .settings { captureSettingsPreview() }
        ui.show(tool)
    }
    private func captureSettingsPreview() {
        guard let window = session.window else { return }
        var marks = session.annotations.map { ReadingPreviewSource.Mark(start: $0.startUtf8, end: $0.endUtf8) }
        if let focus = session.focusRange { marks.append(.init(start: focus.startUtf8, end: focus.endUtf8, search: true)) }
        context?.preview = ReadingPreviewSource(window: window, anchor: session.anchor, title: session.book?.title ?? "", marks: marks)
    }
    private var pagePath: Binding<ReaderPageRoute?> {
        Binding(get: {
            // A deeper reader can own this source stack's modal host while the
            // original details/settings route remains in its native back stack.
            if let context, native?.context !== context {
                return context.installedPage?.id == plan.navigation?.id ? context.installedPage : nil
            }
            if native?.keepsSettingsParent == true { return context?.installedPage }
            guard let route = plan.navigation, native?.canNavigate(to: route) == true else { return nil }
            return route
        }, set: { _ in
            // A real completed pop (including an interactive cancellation) is
            // observed below; binding writes do not complete user tasks.
        })
    }
    private func pageWitness(_ page: ReaderPageRoute) -> some View {
        NavigationTransitionObserver(willLeave: { _ in }, completed: { popping, cancelled in
            guard popping, !cancelled, plan.navigation?.id == page.id else { return }
            ui.closeTask()
        }, removed: { if let context { native?.pageRemoved(page.id, in: context) } })
        .onAppear { if let context { native?.pageAppeared(page, in: context) } }
    }
    private func updateLayout() {
        ui.layout.regular = isWide
        // Use space, not device identity. The native inspector needs its own
        // minimum column plus readable prose; full source width is stable while mounted.
        let width = native?.hostWidth ?? readerWidth
        ui.layout.canInspect = native != nil && ReaderLayoutFacts.inspectorFits(regular: isWide, hostWidth: width, body: bodyLayout,
            inspectorWidth: native?.inspector?.width ?? 0, settings: session.settings)
    }
    private var systemReadingBlocked: Bool {
        ui.editor != nil || ui.foreground.tool != nil || native?.isPresented == true
    }
    private var statisticsReadable: Bool {
        scenePhase == .active && !session.isLeaving && session.opening.phase == .reading && session.window != nil && !session.showingCover
            && !session.isLoading && !session.navigating && session.error == nil && native?.suspended != true
            && plan.allowsStatistics && !ui.inputFocused && !ui.libraryEditing.editingOutline && !ui.libraryEditing.restoringOutline
    }
    private var undoVisible: Bool {
        guard !session.isLeaving, scenePhase == .active else { return false }
        if case .inspector = plan.root { return native?.inspectorMounted == true }
        if case .sheet(.accessory) = plan.root { return native?.rootRequested == true }
        if case .sheet(.search) = plan.root { return native?.rootRequested == true && ui.search?.expanded != true }
        return ui.foreground.tool == .progress && native?.isPresented == true
    }
    private func selectText(start: UInt64, end: UInt64, action: ReaderSelectionAction) {
        session.beganReadingInteraction()
        guard !session.isLeaving else { return }
        if action == .removeAnnotations {
            guard let id = session.readingID else { return }
            Task {
                await ui.tools.removeAnnotations(bookID: id, start: start, end: end)
                guard !session.isLeaving else { return }
                if let error = ui.tools.error { session.error = error; ui.tools.error = nil }
                session.notesChanged()
            }
            return
        }
        let intent = ui.intentID
        if action == .search || action == .copy {
            guard let id = session.readingID else { return }
            session.readSelection(start: start, end: end) { range in
                guard ui.intentID == intent else { return }
                if action == .copy { UIPasteboard.general.string = range.text; return }
                await ui.tools.prepare(bookID: id, currentChapter: 0, library: false)
                guard !Task.isCancelled, !session.isLeaving, session.readingID == id, ui.intentID == intent else { return }
                ui.tools.regex = false; ui.tools.query = range.text.trimmingCharacters(in: .whitespacesAndNewlines)
                ui.show(.search); ui.tools.startSearch()
            }
            return
        }
        Task {
            let value = await session.prepareSelection(start: start, end: end, action: action)
            guard !session.isLeaving, ui.intentID == intent, let value else { return }
            switch value {
            case .chapter(let draft): ui.beginEditing(.chapter(draft), origin: .reader)
            case .note(let edit): ui.beginEditing(.note(NoteEditorModel(edit: edit)), origin: .reader)
            }
        }
    }
    private func changeEncoding(_ encoding: String?) {
        ui.closeSearch(); ui.closeTask(); ui.controlsVisible = false
        session.restart(encoding: encoding)
    }
    private func completeReturning() {
        guard exitPhase == .reading else { return }
        exitPhase = .saving; ui.leave(); native?.remove(ui.openingID)
        reviewExitIsNormal = session.error == nil && session.book != nil
        let saved = session.leave(); library.systemReading.unregister(session)
        Task { await saved.value; exitPhase = .ready; finishReturning() }
    }
    private func finishReturning() {
        guard exitPhase == .ready, native?.retainedOpeningIDs.contains(ui.openingID) != true else { return }
        exitPhase = .returned; session.clearTransientState()
        onExit(session.error, reviewExitIsNormal && StatisticsWriter.shared.error == nil ? session.activity.effectiveReadingMilliseconds : 0)
    }
    private func loadCoverInformation() async {
        guard let id = session.readingID else { return }
        coverInformation = try? await AppDataService.shared.details(bookID: id)
    }

    private var aiCurrentConversation: AIConversation? { context?.aiConversationID.flatMap { ai.conversation($0) } }
    private var aiMoonAllowed: Bool {
        ai.availability.isAvailable && session.book?.contentSha256.isEmpty == false && !session.isLeaving
            && ui.editor == nil && (ui.foreground.tool == nil || ui.foreground.tool == .search) && ui.search?.expanded != true
    }
    private var aiNoticeAllowed: Bool {
        aiMoonAllowed && scenePhase == .active && !session.navigating && session.selectionStart == nil && native?.suspended != true
    }
    @ViewBuilder private var aiMoon: some View {
        if aiMoonAllowed {
            let snapshot = aiCurrentConversation?.moonSnapshot
            AIReadingMoon(pose: aiPresence.pose(live: snapshot?.pose ?? .idle), label: snapshot?.running == true ? snapshot?.label ?? "" : aiPresence.pose(live: snapshot?.pose ?? .idle).outcomeLabel,
                visible: ui.controlsVisible || aiPresence.shown != nil, reservedBottom: native?.rootRequested == true ? 166 : 40, position: $aiMoonPosition) {
                if let selection = session.viewportAccess.controller?.selectedSourceRange() {
                    session.readSelection(start: selection.0, end: selection.1) { openAI(selection: $0) }
                } else { openAI() }
            }
        }
    }
    private func openAI(selection: TextRange? = nil) {
        guard ai.availability.isAvailable, !session.isLeaving else { return }
        context?.aiEntry = aiContext(selection: selection); ui.show(.ai)
    }
    private func revealAIMoonNotice() {
        guard aiNoticeAllowed, let shown = aiPresence.reveal() else { return }
        let message: String
        switch shown.notice {
        case .working: return
        case .needsYou: message = String(localized: "月读助手正在等你确认")
        case .outcome(let pose): message = String(localized: "月读助手：\(pose.outcomeLabel)")
        }
        var announcement = AttributedString(message)
        announcement.accessibilitySpeechAnnouncementPriority = .low
        AccessibilityNotification.Announcement(announcement).post()
    }
    private func aiContext(selection: TextRange? = nil) -> AIEntryContext {
        let sha = session.book?.contentSha256
        let title = session.book?.title ?? route.title
        let visible = session.viewportAccess.controller?.statisticsRange()
        let start = visible?.0 ?? session.anchor
        var attachments: [AIReadingAttachment] = [
            .init(kind: .position, origin: "reader", bookRef: sha.map(AIReadingTools.bookRef), title: title,
                  chapter: session.chapter?.title, startUtf8: start, endUtf8: visible?.1,
                  progress: session.incomplete ? nil : session.book.map { Double(start) / Double(max(1, $0.byteCount)) })
        ]
        if let selection {
            attachments.append(.init(kind: .selection, origin: "reader", bookRef: sha.map(AIReadingTools.bookRef), title: title,
                                     chapter: session.chapter?.title, startUtf8: selection.startUtf8, endUtf8: selection.endUtf8, excerpt: selection.text))
        }
        return AIEntryContext(association: AIContext(contentSHA: sha, title: title, chapter: session.chapter?.title), attachments: attachments)
    }

    @ViewBuilder private var continuationControl: some View {
        if let message = session.continuationMessage {
            if session.continuationCollapsed {
                Button("同步进度") { session.expandContinuation() }
                    .font(.footnote).buttonStyle(.plain)
                    .foregroundStyle(Color(uiColor: theme.accent))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(uiColor: theme.surface), in: .capsule)
                    .accessibilityIdentifier("showSyncedProgress")
            } else {
                ReadingContinuationBanner(message: message, busy: session.navigating,
                    accept: { Task { await session.acceptSyncedContinuation() } },
                    stay: { session.stayAtLocalPosition() })
            }
        }
    }

    private var preparationView: some View {
        ReaderPreparationContent(session: session, route: route, changeEncoding: changeEncoding)
    }
}

private struct ReaderToolbarAxis: ViewModifier {
    let ui: ReaderUIState
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 27.1, *) { content.modifier(ReaderVerticalToolbarAxis(ui: ui)) }
        else { content }
    }
}
@available(iOS 27.1, *) private struct ReaderVerticalToolbarAxis: ViewModifier {
    @Environment(\.toolbarVerticalEdge) private var edge
    let ui: ReaderUIState
    func body(content: Content) -> some View {
        content.onChange(of: edge, initial: true) { _, value in ui.layout.verticalToolbar = value != nil }
    }
}

private struct ReaderOpenLegacyFade: ViewModifier {
    let ready: Bool
    let reduced: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if ReaderOpenDiagnostics.deferredPage { content }
        else { content.animation(.easeOut(duration: reduced ? 0.1 : 0.2), value: ready) }
    }
}

private struct ReaderOpenContentFade: ViewModifier {
    let phase: ReaderOpeningPhase
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if ReaderOpenDiagnostics.deferredPage { content.animation(enabled ? .easeOut(duration: 0.2) : nil, value: phase) }
        else { content }
    }
}

private struct ReaderImportDiagnosticStatus: ViewModifier {
    let complete: Bool
    func body(content: Content) -> some View {
        #if READER_OPEN_DIAGNOSTICS
        content.accessibilityValue(complete ? "import-complete" : "import-pending")
        #else
        content
        #endif
    }
}
