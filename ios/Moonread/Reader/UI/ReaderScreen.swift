import TipKit
import SwiftUI
import UIKit

private enum ReaderExitPhase { case reading, saving, ready, returned }

struct ReaderScreen: View {
    let route: ReaderRoute
    var openingRequest: OpeningRequest? = nil
    @State private var contentVisible = false
    @State private var completedOpeningID: UUID?
    let onExit: (String?, UInt64) -> Void
    @State private var reviewExitIsNormal = false
    @State private var session = ReaderSession()
    @State private var panel: ReaderPanel?
    /// Which list the tool sheet opens on: chapters from the bottom bar, any list from More.
    @State private var searchExpanded = false
    @State private var searchActive = false
    @State private var pageAfterDismiss: ReaderPanel?
    @State private var detailOrigin: (panel: ReaderPanel?, controls: Bool, dock: ReaderDock, expanded: Bool)?
    @State private var coverInformation: BookDetails?
    @Environment(LibraryModel.self) private var library
    @State private var tools = ReaderToolsModel()
    @State private var controlsVisible = false
    @State private var controlsTipHeight: CGFloat = 0
    @State private var dock = ReaderDock.progress
    /// A bookmark or note list opened from 更多 returns there when it is closed.
    @State private var libraryReturnsToMore = false
    @State private var sheetDismissRequested = false
    @State private var dockHeight: CGFloat = 220
    @State private var pendingProgressNavigation = false
    @State private var libraryNavigationRevision: Int?
    @State private var settingsPreview = ReadingPreviewSource.sample
    @State private var readerWidth: CGFloat = 390
    @State private var battery = ReaderBattery()
    @State private var exitPhase = ReaderExitPhase.reading
    @State private var navigationPresentation = NavigationPresentationState()
    // Remains true throughout sheet dismissal, even after its binding is nil.
    @State private var sheetPresented = false
    @Environment(AIService.self) private var ai
    @State private var aiConversationID: String?
    @State private var aiEntrySnapshot: AIEntryContext?
    @State private var aiMoonPosition: CGPoint?
    @State private var aiPresence = AIMoonPresence()
    @State private var returnToReading = ReturnToReading()
    private let compactHeaderHeight: CGFloat = 22
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme

    private var readerContent: some View {
        Group {
            if session.opening.phase == .reading, let window = session.window, let settings = session.settings {
                ReadingView(window: window, settings: settings, anchor: session.displayAnchor ?? session.anchor,
                            openingID: session.opening.request?.id,
                            requestWindow: { direction,keep in session.requestWindow(direction,retaining:keep) },
                            dark: colorScheme == .dark, dynamicTypeSize: dynamicTypeSize,
                            navigationRevision: session.navigationRevision,
                            navigation: session.navigation, viewportAccess: session.viewportAccess,
                            annotations: session.annotations, bookmarkPositions: session.bookmarkPositions, focusRange: session.focusRange,
                            selectionStart: session.selectionStart, selection: selectText,
                            allowsBackGesture: allowsReaderBack,
                            allowsSelection: panel == nil || panel == .search,
                            allowsChapterEditing: !session.incomplete,
                            coverTitle: session.book?.title ?? route.title,
                            coverInformation: coverInformation,
                            showBookDetails: { presentPanel(.details) },
                            showingCover: session.showingCover,
                            coverChanged: { if !navigationPresentation.isSuspended { session.showingCover = $0 } },
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
                            guideHeight: Onboarding.shared.enabled && !Onboarding.shared.revealedControls && !controlsVisible ? controlsTipHeight : 0,
                            controlsVisible: controlsVisible,
                            toggleControls: { if panel == nil || panel == .search { controlsVisible.toggle() } },
                            readingBegan: { session.beganReadingInteraction(); controlsVisible = false },
                            positionChanged: { offset, end in
                                if !navigationPresentation.isSuspended { session.moved(to: offset, settled: end, userInitiated: false) }
                            })
                    .allowsHitTesting(panel?.isPage != true)
                    .ignoresSafeArea(.container)
                    .accessibilityIdentifier("readingContent")
                    .modifier(ReaderImportDiagnosticStatus(complete: session.snapshot?.phase == .complete))
                    .transition(.opacity)
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

    private var allowsReaderBack: Bool {
        exitPhase == .reading && !navigationPresentation.isSuspended
            && (panel == nil || panel == .search) && !searchExpanded
            && taskID == nil && !sheetDismissRequested
            && session.editor == nil && session.error == nil && !session.navigating
    }

    private var navigableReader: some View {
        readerContent
            .navigationTitle(session.book?.title ?? route.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(uiColor: theme.paper), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("小说详情", systemImage: "info.circle") { presentPanel(.details) }
                        .labelStyle(.iconOnly).toolbarGlyph()
                        .accessibilityIdentifier("readerBookDetails")
                }
            }
            .toolbarVisibility(readerNavigationVisible ? .visible : .hidden, for: .navigationBar)
    }

    /// Reading-time Moon notices for the conversation selected in this opening.
    private var moonAwareReader: some View {
        navigableReader
            .onChange(of: aiCurrentConversation?.moonSnapshot, initial: true) { _, snapshot in
                aiPresence.observe(snapshot, chatOpen: panel == .ai) { aiCurrentConversation?.latestTurnProposes ?? false }
                revealAIMoonNotice()
            }
            .onChange(of: panel == .ai) { _, open in
                if open { aiPresence.chatOpened() } else { aiPresence.chatClosed(); revealAIMoonNotice() }
            }
            .onChange(of: ai.availability.isAvailable) { _, available in
                if !available {
                    if panel == .ai { closeTask() }
                    aiPresence.conceal()
                }
            }
            .onChange(of: aiNoticeAllowed) { _, allowed in
                if allowed { revealAIMoonNotice() } else { aiPresence.conceal() }
            }
            .task(id: aiPresence.shown?.id) {
                guard let shown = aiPresence.shown else { return }
                do { try await Task.sleep(for: shown.notice.duration) } catch { return }
                aiPresence.expire(shown.id)
            }
    }

    private var presentedReader: some View {
        moonAwareReader
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if session.navigating && !sheetPresented && !session.isLeaving {
                LoadingActivity(size: 32, waitingLabel: "正在定位").allowsHitTesting(false)
            }
        }
        .overlay { aiMoon }
        #if DEBUG
        .overlay(alignment: .bottomTrailing) {
            if ReaderSmokeFixture.enabled {
                Button("测试批注") { selectText(start: 0, end: 3, action: .comment) }
                    .accessibilityIdentifier("smokeAddNote")
            }
        }
        #endif
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { readerWidth = $0 }
        // The keyboard belongs to the presented tools, never to the reading page.
        .ignoresSafeArea(.keyboard)
        .modifier(ReaderOpenLegacyFade(ready: session.window != nil, reduced: reduceMotion))
        .background(Color(uiColor: theme.paper))
        .background(NavigationTransitionObserver(openingID: session.opening.request?.id ?? openingRequest?.id,
                                                   appeared: { id, reason in
                                                       completedOpeningID = id; session.opening.settled(id, reason: reason)
                                                   },
                                                   visibilityChanged: { visible in
                                                       contentVisible = visible; session.opening.visibility(visible, active: scenePhase == .active)
                                                   },
                                                   willLeave: { popping in
            if popping { navigationPresentation.begin(hasPresentation: sheetPresented) }
        }, completed: { popping, cancelled in
            guard popping else { return }
            navigationPresentation.finish(cancelled: cancelled)
            if !cancelled { completeReturning() }
        }))
        .toolbarVisibility(.hidden, for: .tabBar)
        .statusBarHidden(!controlsVisible)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if Onboarding.shared.enabled, !Onboarding.shared.revealedControls, !controlsVisible,
               session.opening.phase == .reading, !session.isLeaving {
                TipView(Onboarding.shared.controls).tipViewStyle(ThemedTipStyle()).padding(.horizontal)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsTipHeight = $0 }
                    .background(Color(uiColor: theme.paper)).accessibilityIdentifier("readerControlsTip")
            }
        }
        // The reader fills the container independently of navigation visibility.
        // Only the quiet chapter/time header is an overlay; navigation is native.
        .overlay(alignment: .top) {
            if !session.isLeaving, !readerNavigationVisible, let book = session.book {
                compactHeader(book: book)
                    .opacity(navigationPresentation.isSuspended ? 0 : 1)
            }
        }
        .navigationDestination(isPresented: Binding(get: { panel == .settings && !session.isLeaving }, set: { shown in
            if !shown, panel == .settings { panel = searchActive ? .search : nil; sheetDismissRequested = false }
        })) {
                ReaderSettingsView(settings: readingSettings, preview: settingsPreview, encoding: session.encodingLabel, isRestartingEncoding: session.restartingEncoding, changeEncoding: changeEncoding)
                .themeScope(theme)
                .preferredColorScheme(theme.scheme)
        }
        .navigationDestination(isPresented: Binding(get: { panel == .details && !session.isLeaving }, set: { shown in
            if !shown { closeBookDetails() }
        })) {
            // Like reading settings, the pushed page's UIKit chrome follows the reader appearance.
            StatisticsView(library: library, target: bookDetailsTarget)
                .themeScope(theme).preferredColorScheme(theme.scheme).toolbarVisibility(.hidden, for: .tabBar)
                // Pages pushed from details (a search) can return straight to this book.
                .environment(\.returnToReading, returnToReading)
                .onAppear { returnToReading.close = closeBookDetails }
        }
        // The presentation has one identity. Routes change inside it, including
        // library, history and notes; they never dismiss and re-present the dock.
        .sheet(isPresented: Binding(get: {
            !session.isLeaving && !navigationPresentation.isSuspended && !sheetDismissRequested
                && panel?.isPage != true && (taskID != nil || controlsVisible || hasReadingAccessory)
        }, set: { shown in
            guard !shown, !navigationPresentation.isSuspended, !sheetDismissRequested else { return }
            sheetDismissRequested = true
            controlsVisible = false; dock = .progress
            if taskID == nil, searchActive { closeSearch() }
        }), onDismiss: presentationDismissed) { readerSheet }
        .overlay(alignment: .top) {
            if !session.isLeaving, session.selectionStart != nil {
                HStack {
                    Text("跨页选取中").font(.caption)
                    Button("取消") { session.selectionStart = nil }
                }
                .padding(12).background(theme.floatingBackground(), in: .capsule).padding(.top, 26)
            }
        }
    }

    private var monitoredReader: some View {
        presentedReader
        .overlay(alignment: .bottom) {
            if !controlsVisible, panel == nil, !session.isLeaving,
               session.opening.phase == .reading, !session.continuationCollapsed {
                continuationControl.padding(.horizontal, 16).padding(.bottom, 24)
            }
        }
        .allowsHitTesting(!session.isLeaving)
        .task {
            library.systemReading.register(session, navigationID: openingRequest?.id)
            await session.open(route, request: openingRequest)
        }
        .onChange(of: library.systemReading.pending) { _, request in
            // A plain reading toolbar can close through its normal onDismiss
            // path. Editors, searches and AI work keep their draft/presentation.
            if request != nil, !session.isLeaving, panel == nil, taskID == nil,
               session.editor == nil, session.chapterDraft == nil, !searchActive {
                controlsVisible = false
            }
        }
        .onChange(of: sheetPresented || panel != nil || session.editor != nil || session.chapterDraft != nil, initial: true) { _, blocked in
            library.systemReading.presentationBlocked = blocked
        }
        .onChange(of: session.opening.request?.id) { _, id in
            if let id, completedOpeningID == id { session.opening.settled(id, reason: "observedAppearance") }
        }
        .task(id: session.book?.contentSha256) {
            await loadCoverInformation()
            if statisticsReadable { session.systemReadingBecameReadable() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookMetadataChanged).receive(on: DispatchQueue.main)) { _ in
            Task { await loadCoverInformation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudDataReceived).receive(on: DispatchQueue.main)) { _ in
            Task { session.notesChanged(); await loadCoverInformation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudReadingPositionsReceived).receive(on: DispatchQueue.main)) { _ in
            Task { await session.refreshSyncedContinuation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .readingContinuationInvalidated).receive(on: DispatchQueue.main)) { _ in
            session.invalidateSyncedContinuation()
        }
        .onChange(of: statisticsReadable, initial: true) { _, readable in
            session.activity.update(readable: readable, preview: session.browseOrigin != nil)
            if readable { session.systemReadingBecameReadable() }
        }
        .onChange(of: session.browseOrigin != nil) { _, preview in
            session.activity.update(readable: statisticsReadable, preview: preview)
        }
        .onReceive(NotificationCenter.default.publisher(for: .statisticsPreferencesChanged).receive(on: DispatchQueue.main)) { _ in
            Task { await session.activity.reloadPreferences() }
        }
    }

    private var lifecycleReader: some View {
        monitoredReader
        .onAppear {
            contentVisible = true; session.opening.visibility(true, active: scenePhase == .active)
            session.opening.reduceMotion(reduceMotion)
            battery.start()
            session.activity.update(readable: statisticsReadable, preview: session.browseOrigin != nil)
        }
        .onChange(of: controlsVisible) { _, visible in
            if visible { session.refreshBookmark(); Onboarding.shared.didShowControls() }
            else { dock = .progress }
        }
        .onChange(of: searchExpanded) { _, expanded in if expanded { controlsVisible = false } }
        .onChange(of: session.navigating) { _, navigating in
            if !navigating, let revision = libraryNavigationRevision {
                libraryNavigationRevision = nil
                // A chosen record moves the text: return to reading, never to 更多.
                if panel == .library, session.navigationRevision > revision { libraryReturnsToMore = false; closeTask() }
            }
            if !navigating, pendingProgressNavigation {
                pendingProgressNavigation = false
                if session.browseOrigin != nil { controlsVisible = false }
            }
        }
        .onChange(of: session.chapterDraft) { _, draft in if draft != nil { presentPanel(.chapterEditor) } }
        .onChange(of: session.editor?.presentationID) { _, id in
            if id != nil { controlsVisible = false; dock = .progress; searchExpanded = false; libraryReturnsToMore = false }
        }
        .onChange(of: undoCapsuleVisible, initial: true) { _, visible in tools.setUndoVisible(visible) }
        .onChange(of: reduceMotion) { _, value in session.opening.reduceMotion(value) }
        .onChange(of: scenePhase) { _, phase in
            session.opening.visibility(contentVisible, active: phase == .active)
            guard !session.isLeaving else { return }
            if phase == .active {
                battery.refresh()
                session.foreground()
            } else if phase == .background {
                BackgroundSave.perform(name: "保存阅读位置") { await session.flush() }
            } else {
                Task { await session.flush() }
            }
        }
        .onDisappear {
            contentVisible = false; session.opening.visibility(false, active: false)
            session.activity.update(readable: false, preview: session.browseOrigin != nil)
            battery.stop()
            // Settings are pushed above the reader in the same navigation stack.
            // Only leaving its navigation destination ends the reading session.
            if panel?.isPage != true, !navigationPresentation.isSuspended { library.systemReading.unregister(session); completeReturning() }
        }
    }

    private var readingErrorPresented: Binding<Bool> {
        Binding(get: { !session.isLeaving && session.error != nil && session.book != nil },
                set: { if !$0 && !session.isLeaving { session.error = nil } })
    }

    var body: some View {
        lifecycleReader
        .alert("阅读遇到问题", isPresented: readingErrorPresented) {
            Button("知道了", role: .cancel) { session.error = nil }
        } message: { Text(session.error ?? "") }
    }

    private var hasReadingAccessory: Bool {
        searchActive || session.browseOrigin != nil || tools.deletedIDs != nil
    }

    /// Where the Moon may appear at all: reading this book, with no task, panel or search on top.
    private var aiMoonAllowed: Bool {
        guard ai.availability.isAvailable, let sha = session.book?.contentSha256, !sha.isEmpty, !session.isLeaving else { return false }
        return taskID == nil && dock == .progress && !searchExpanded
    }
    /// Notices wait for a calm page: foreground, not navigating or selecting across pages.
    private var aiNoticeAllowed: Bool {
        aiMoonAllowed && scenePhase == .active && !session.navigating && session.selectionStart == nil
            && !navigationPresentation.isSuspended
    }
    @ViewBuilder private var aiMoon: some View {
        if aiMoonAllowed {
            let snapshot = aiCurrentConversation?.moonSnapshot
            let pose = aiPresence.pose(live: snapshot?.pose ?? .idle)
            AIReadingMoon(pose: pose, label: snapshot?.running == true ? snapshot?.label ?? "" : pose.outcomeLabel,
                          visible: controlsVisible || aiPresence.shown != nil,
                          reservedBottom: sheetPresented ? dockHeight + 36 : 40, position: $aiMoonPosition) {
                if let selection = session.viewportAccess.controller?.selectedSourceRange() {
                    session.readSelection(start: selection.0, end: selection.1) { openAI(selection: $0) }
                } else { openAI() }
            }
        }
    }
    private func openAI(selection: TextRange? = nil) {
        guard ai.availability.isAvailable, !session.isLeaving else { return }
        aiEntrySnapshot = aiContext(selection: selection)
        controlsVisible = false; sheetDismissRequested = false; panel = .ai
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

    private var aiCurrentConversation: AIConversation? {
        aiConversationID.flatMap { ai.conversation($0) }
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

    private var statisticsReadable: Bool {
        scenePhase == .active && !session.isLeaving && session.opening.phase == .reading && session.window != nil && !session.showingCover
            && !session.isLoading && !session.navigating && session.error == nil
            && !navigationPresentation.isSuspended && !controlsVisible && !searchExpanded
            && dock == .progress && taskID == nil && panel?.isPage != true
    }

    private func loadCoverInformation() async {
        guard let id = session.readingID else { return }
        coverInformation = try? await AppDataService.shared.details(bookID: id)
    }

    private var bookDetailsTarget: StatisticsRoute {
        if case let .source(file) = route {
            return StatisticsRoute(bookID: session.readingID, title: file.title, fileID: file.id, fromReader: true)
        }
        return StatisticsRoute(bookID: session.readingID, title: session.book?.title ?? route.title, fromReader: true)
    }

    private var taskID: String? {
        if let mark = session.editor { return "note-\(mark.presentationID)" }
        if let panel, panel == .library || panel == .history || panel == .chapterEditor || panel == .ai { return panel.rawValue }
        return nil
    }

    private var readerSheet: some View {
        ReaderBottomPanel(expanded: $searchExpanded, compactHeight: $dockHeight,
                          canExpand: searchActive && dock == .progress, taskID: taskID,
                          closeTask: closeTask) {
            ZStack(alignment: .top) {
                bottomDock
                    .transaction { $0.animation = nil }
                    .id(dock)
                    .transition(MotionTokens.accessoryContent(reduced: reduceMotion))
            }
            .animation(MotionTokens.accessoryResize(reduced: reduceMotion), value: dock)
        } footer: {
            VStack(spacing: 0) {
                if controlsVisible, session.book != nil {
                    bottomControls.padding(.top, LayoutTokens.compact)
                }
            }.padding(.bottom, LayoutTokens.compact)
        } details: { readyForInput in
            searchContent(details: true, readyForInput: readyForInput)
        } taskContent: {
            readerTask
        }
        .interactiveDismissDisabled(taskID == nil && session.browseOrigin != nil)
        .themeScope(theme).preferredColorScheme(theme.scheme)
        .onAppear { sheetPresented = true }
        .overlay {
            if session.navigating && !session.isLeaving {
                LoadingActivity(size: 24, waitingLabel: "正在定位").allowsHitTesting(false)
            }
        }
    }

    private var readerTask: some View {
        ReaderTaskContent(panel: panel, session: session, tools: tools, aiEntrySnapshot: aiEntrySnapshot,
                          aiContext: { aiContext() }, aiConversationID: $aiConversationID,
                          openingIsActive: { exitPhase == .reading && !session.isLeaving }, closeTask: closeTask,
                          navigate: { start, end, placement in
            guard !session.isLeaving else { return }
            libraryNavigationRevision = session.navigationRevision
            session.browse(to: start, end: end, placement: placement)
        }, edit: { mark in
            if !session.isLeaving { session.openAnnotation(mark.id) }
        })
    }

    private func clearTask() {
        libraryNavigationRevision = nil; libraryReturnsToMore = false
        session.editor = nil; session.chapterDraft = nil
        panel = searchActive ? .search : nil
        session.notesChanged()
    }

    private func closeTask() {
        searchExpanded = false
        if panel == .library, libraryReturnsToMore {
            // The list collapses into the same sheet, back to the 更多 content it grew from.
            controlsVisible = true; dock = .more
            withAnimation(MotionTokens.panel(reduced: reduceMotion)) { clearTask() }
            return
        }
        controlsVisible = false; dock = .progress
        if hasReadingAccessory {
            withAnimation(MotionTokens.panel(reduced: reduceMotion)) { clearTask() }
        } else {
            // Keep the outgoing task intact until native dismissal finishes.
            sheetDismissRequested = true
        }
    }

    private func presentationDismissed() {
        sheetPresented = false
        if navigationPresentation.presentationDismissed() {
            if exitPhase != .reading { finishReturning() }
            return
        }
        guard exitPhase == .reading else { finishReturning(); return }
        if let next = pageAfterDismiss {
            pageAfterDismiss = nil
            withAnimation(reduceMotion ? nil : .default) { panel = next }
        } else {
            clearTask()
            searchExpanded = false
            sheetDismissRequested = false
        }
    }

    private func completeReturning() {
        guard exitPhase == .reading else { return }
        navigationPresentation.begin(hasPresentation: sheetPresented)
        exitPhase = .saving
        pageAfterDismiss = nil; detailOrigin = nil; searchActive = false
        tools.leave()
        reviewExitIsNormal = session.error == nil && session.book != nil
        let saved = session.leave()
        panel = nil
        Task {
            await saved.value
            exitPhase = .ready
            finishReturning()
        }
    }

    private func finishReturning() {
        guard exitPhase == .ready, !sheetPresented else { return }
        aiConversationID = nil; aiEntrySnapshot = nil
        exitPhase = .returned
        session.clearTransientState()
        onExit(session.error, reviewExitIsNormal && StatisticsWriter.shared.error == nil ? session.activity.effectiveReadingMilliseconds : 0)
    }

    private var undoCapsuleVisible: Bool {
        guard !session.isLeaving, !navigationPresentation.isSuspended, scenePhase == .active, session.editor == nil else { return false }
        return taskID == nil && sheetPresented && !searchExpanded && dock != .settings && !sheetDismissRequested
    }

    private func openLibrary(_ destination: ReaderLibraryTab, fromMore: Bool = false) {
        // Choose the list before publishing the panel: its first frame is already the target.
        tools.select(destination); presentPanel(.library)
        libraryReturnsToMore = fromMore
    }

    /// Ends the details presentation, and every page pushed above it, back to reading.
    private func closeBookDetails() {
        guard panel == .details else { return }
        let origin = detailOrigin; detailOrigin = nil
        panel = origin?.panel; controlsVisible = origin?.controls ?? false
        dock = origin?.dock ?? .progress; searchExpanded = origin?.expanded ?? false
        sheetDismissRequested = false
    }

    private func presentPanel(_ next: ReaderPanel) {
        if next == .details {
            detailOrigin = (panel, controlsVisible, dock, searchExpanded)
            session.activity.update(readable: false, preview: session.browseOrigin != nil)
        }
        if next == .settings, let window = session.window {
            var marks = session.annotations.map { ReadingPreviewSource.Mark(start: $0.startUtf8, end: $0.endUtf8) }
            if let focus = session.focusRange { marks.append(.init(start: focus.startUtf8, end: focus.endUtf8, search: true)) }
            settingsPreview = ReadingPreviewSource(window: window, anchor: session.anchor, title: session.book?.title ?? "", marks: marks)
        }
        controlsVisible = false; dock = .progress; libraryReturnsToMore = false
        if next == .search {
            searchActive = true; searchExpanded = true
            panel = .search
            return
        }
        searchExpanded = false
        if next.isPage, sheetPresented {
            // Only the navigation push is animated. The native dismissal
            // callback still coordinates ownership of the presentation.
            pageAfterDismiss = next
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { sheetDismissRequested = true }
        } else {
            withAnimation(MotionTokens.panel(reduced: reduceMotion)) { panel = next }
        }
    }

    private func closeSearch() {
        searchActive = false
        searchExpanded = false
        tools.stopSearch()
        panel = nil
    }

    private func selectText(start: UInt64, end: UInt64, action: ReaderSelectionAction) {
        session.beganReadingInteraction()
        if action == .removeAnnotations {
            guard !session.isLeaving, let bookID = session.readingID else { return }
            Task {
                await tools.removeAnnotations(bookID: bookID, start: start, end: end)
                guard !session.isLeaving else { return }
                if let error = tools.error { session.error = error; tools.error = nil }
                session.notesChanged()
            }
            return
        }
        guard action == .search || action == .copy else { session.selectText(start: start, end: end, action: action); return }
        guard !session.isLeaving, let id = session.readingID else { return }
        session.readSelection(start: start, end: end) { range in
            if action == .copy { UIPasteboard.general.string = range.text; return }
            await tools.prepare(bookID: id, currentChapter: 0, library: false)
            guard !Task.isCancelled, !session.isLeaving, session.readingID == id else { return }
            tools.regex = false
            tools.query = range.text.trimmingCharacters(in: .whitespacesAndNewlines)
            presentPanel(.search)
            tools.startSearch()
        }
    }

    private var undoCapsule: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "trash").accessibilityHidden(true)
                Text("已删除")
            }.foregroundStyle(Color(uiColor: theme.secondary))
            Spacer(minLength: 12)
            Button { Task { await tools.undoDelete(); session.notesChanged() } } label: {
                Text("撤销").frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
                    .contentShape(.rect)
            }.accessibilityIdentifier("undoDeletedAnnotation")
        }
        .font(.subheadline).padding(.horizontal, LayoutTokens.page).padding(.vertical, 4)
    }

    private var browsePanel: some View {
        ReaderBrowseActions(session: session, showsHistory: controlsVisible,
                            showHistory: { presentPanel(.history) }, finished: { controlsVisible = false })
            .padding(.horizontal, LayoutTokens.page).padding(.top, LayoutTokens.page)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("readerBrowsePanel")
    }

    private func compactHeader(book: BookInfo) -> some View {
        ReaderCompactHeader(session: session, battery: battery, book: book, readerWidth: readerWidth,
                            compactHeaderHeight: compactHeaderHeight, showControls: { controlsVisible = true })
    }
    private var readerNavigationVisible: Bool {
        !session.isLeaving && !navigationPresentation.isSuspended
            && (controlsVisible || session.window == nil)
    }

    private var readingSettings: Binding<ReaderSettings> {
        Binding(get: { session.settings ?? defaultReaderSettings() }, set: session.updateSettings)
    }

    private func searchContent(details: Bool, readyForInput: Bool = false) -> some View {
        ReaderSearchContent(model: tools, session: session, expanded: $searchExpanded,
                            showsDetails: details, readyForInput: readyForInput,
                            compactHeight: dockHeight, showsHistory: controlsVisible,
                            showHistory: { presentPanel(.history) }, closeSearch: closeSearch)
    }

    private var bottomDock: some View {
        VStack(spacing: LayoutTokens.compact) {
            if controlsVisible, !session.isLeaving { continuationControl }
            if Onboarding.shared.enabled, Onboarding.shared.revealedControls, !Onboarding.shared.selectedText, controlsVisible {
                TipView(Onboarding.shared.selection).tipViewStyle(ThemedTipStyle(titleOverride: ai.availability.isAvailable ? nil : Text("长按文字可以标注、写批注或拷贝"))).accessibilityIdentifier("readerSelectionTip")
            }
            if dock == .settings {
                ReaderQuickSettings(settings: readingSettings) { presentPanel(.settings) }
            } else if dock == .more {
                moreContent
            } else if searchActive {
                searchContent(details: false)
            } else if session.browseOrigin != nil {
                browsePanel
            } else if controlsVisible {
                ReaderProgressControls(session: session) {
                    pendingProgressNavigation = true
                }
                if session.history.entries.count > 1 {
                    Button("跳转历史", systemImage: "clock") { presentPanel(.history) }
                        .accessibilityIdentifier("showReadingHistory")
                }
            }
            if dock != .settings, tools.deletedIDs != nil { undoCapsule }
        }
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

    private var bottomControls: some View {
        VStack(spacing: 18) {
            if session.incomplete { importStatus }
            HStack(spacing: 0) {
                toolButton("目录", symbol: "list.bullet", id: "showChapters") { openLibrary(.chapters) }
                toolButton("搜索", symbol: "magnifyingglass", id: "showSearch") { presentPanel(.search) }
                toolButton("设置", symbol: "textformat.size", id: "readingSettings", selected: dock == .settings) {
                    dock.toggle(.settings)
                }
                toolButton("更多", symbol: "ellipsis", id: "readerMore", selected: dock == .more) {
                    dock.toggle(.more)
                }
            }
            .labelStyle(ReaderToolLabelStyle())
            .buttonStyle(.plain)

        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("readerBottomControls")
    }

    private func toolButton(_ title: LocalizedStringKey, symbol: String, id: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .foregroundStyle(Color(uiColor: selected ? theme.accent : theme.ink))
                .frame(maxWidth: .infinity, minHeight: 56).contentShape(.rect)
        }.accessibilityIdentifier(id).accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 更多 replaces the dock content like quick settings. Its actions use the same
    /// label style, columns and targets as the tools below; at accessibility sizes the
    /// same labels stack as rows so they stay readable.
    private var moreContent: some View {
        ReaderMoreContent(session: session, openLibrary: openLibrary, presentPanel: presentPanel, changeEncoding: changeEncoding)
    }
    private func changeEncoding(_ encoding: String?) {
        controlsVisible = false; dock = .progress
        closeSearch()
        // Leaving the pushed settings page programmatically does not run its
        // binding's `panel == .settings` branch. Release the former sheet gate.
        sheetDismissRequested = false
        session.restart(encoding: encoding)
    }

    private var preparationView: some View {
        ReaderPreparationContent(session: session, route: route, changeEncoding: changeEncoding)
    }
    private var importStatus: some View {
        ReaderPreparationContent(session: session, route: route, statusOnly: true, changeEncoding: changeEncoding)
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
