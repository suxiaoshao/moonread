import TipKit
import SwiftUI
import UIKit

private enum ReaderExitPhase { case reading, saving, ready, returned }

struct ReaderScreen: View {
    let route: ReaderRoute
    var openingRequest: OpeningRequest? = nil
    @State private var contentVisible = false
    @State private var completedOpeningID: UUID?
    let onExit: (String?) -> Void
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
                            readingBegan: { controlsVisible = false },
                            positionChanged: { offset, end in
                                if !navigationPresentation.isSuspended { session.moved(to: offset, settled: end) }
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
                ReaderSettingsView(settings: readingSettings, preview: settingsPreview, encoding: session.encodingLabel, changeEncoding: changeEncoding)
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
        .allowsHitTesting(!session.isLeaving)
        .task { await session.open(route, request: openingRequest) }
        .onChange(of: session.opening.request?.id) { _, id in
            if let id, completedOpeningID == id { session.opening.settled(id, reason: "observedAppearance") }
        }
        .task(id: session.book?.contentSha256) { await loadCoverInformation() }
        .onReceive(NotificationCenter.default.publisher(for: .bookMetadataChanged).receive(on: DispatchQueue.main)) { _ in
            Task { await loadCoverInformation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudDataReceived).receive(on: DispatchQueue.main)) { _ in
            Task { session.notesChanged(); await loadCoverInformation() }
        }
        .onChange(of: statisticsReadable, initial: true) { _, readable in
            session.activity.update(readable: readable, preview: session.browseOrigin != nil)
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
            if panel?.isPage != true, !navigationPresentation.isSuspended { completeReturning() }
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
        guard let sha = session.book?.contentSha256, !sha.isEmpty, !session.isLeaving else { return false }
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
        guard !session.isLeaving else { return }
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
        coverInformation = try? await ReaderService.shared.details(bookID: id)
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

    @ViewBuilder private var readerTask: some View {
        if panel == .ai {
            AIReadingConversation(context: aiEntrySnapshot ?? aiContext(), close: closeTask, selected: $aiConversationID, openingIsActive: { exitPhase == .reading && !session.isLeaving })
        } else if let mark = session.editor {
            NoteEditor(edit: mark, close: closeTask)
        } else if panel == .history {
            ReaderHistorySheet(session: session, close: closeTask)
        } else if panel == .chapterEditor, let draft = session.chapterDraft, let id = session.readingID {
            NavigationStack {
                ChapterEditor(bookID: id, draft: draft) { await session.refreshOutline(); closeTask() }
                    .toolbar { ToolbarItem(placement: .topBarLeading) {
                        Button("取消", systemImage: "xmark", action: closeTask).labelStyle(.titleOnly)
                    } }
            }
        } else if panel == .library {
            ReaderLibrarySheet(model: tools, session: session, navigate: { start, end, placement in
                guard !session.isLeaving else { return }
                // Keep the library until the target is ready, then collapse
                // directly to its browse actions without a gap between sheets.
                libraryNavigationRevision = session.navigationRevision
                session.browse(to: start, end: end, placement: placement)
            }, edit: { mark in
                if !session.isLeaving { session.openAnnotation(mark.id) }
            }, close: closeTask)
            .disabled(session.navigating)
        }
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
        onExit(session.error)
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
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Text(session.showingCover ? String(localized: "封面") : (session.chapter?.title ?? book.title))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("readingChapter")
                if !session.incomplete && !session.showingCover {
                    Text("·").accessibilityHidden(true)
                    progress(book: book).fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if session.atPreparedEdge {
                Button { controlsVisible = true } label: {
                    Text(session.preparing ? String(localized: "后续准备中") : (session.snapshot?.phase == .failed ? String(localized: "查看问题") : String(localized: "继续准备")))
                        .fixedSize()
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("preparedEdge")
            }
            HStack(spacing: 5) {
                TimelineView(.everyMinute) { timeline in
                    Text(timeline.date, format: .dateTime.hour().minute())
                        .monospacedDigit()
                        .accessibilityLabel("当前时间")
                        .accessibilityValue(timeline.date.formatted(.dateTime.hour().minute()))
                        .accessibilityIdentifier("readingClock")
                }
                Image(systemName: battery.symbol)
                    .accessibilityLabel(battery.accessibilityLabel)
                    .accessibilityIdentifier("readingBattery")
            }
            .fixedSize()
        }
        .font(.system(size: 11))
        .foregroundStyle(Color(uiColor: theme.secondary))
        .padding(.horizontal, ReadingTypography.insets(session.settings ?? defaultReaderSettings(), width: readerWidth).left)
        .frame(height: compactHeaderHeight)
        .background(Color(uiColor: theme.paper))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("readerCompactHeader")
        .allowsHitTesting(session.atPreparedEdge)
    }

    private func progress(book: BookInfo) -> some View {
        let fraction = Double(session.anchor) / Double(max(book.byteCount, 1))
        return Text(fraction, format: .percent.precision(.fractionLength(1)))
            .monospacedDigit()
            .accessibilityLabel("阅读进度")
            .accessibilityIdentifier("readingProgress")
            .accessibilityValue(ProcessInfo.processInfo.arguments.contains("--ui-testing")
                                ? String(session.anchor)
                                : fraction.formatted(.percent.precision(.fractionLength(1))))
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
            if Onboarding.shared.enabled, Onboarding.shared.revealedControls, !Onboarding.shared.selectedText, controlsVisible {
                TipView(Onboarding.shared.selection).tipViewStyle(ThemedTipStyle()).accessibilityIdentifier("readerSelectionTip")
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
            }
            if dock != .settings, tools.deletedIDs != nil { undoCapsule }
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 18) {
            if session.incomplete { importStatus }
            HStack(spacing: 0) {
                toolButton("目录", symbol: "list.bullet", id: "showChapters") { openLibrary(.chapters) }
                toolButton("搜索", symbol: "magnifyingglass", id: "showSearch") { presentPanel(.search) }
                toolButton("设置", symbol: "textformat.size", id: "readingSettings", selected: dock == .settings) {
                    dock = dock == .settings ? .progress : .settings
                }
                toolButton("更多", symbol: "ellipsis", id: "readerMore", selected: dock == .more) {
                    dock = dock == .more ? .progress : .more
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
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    ForEach(moreActions) { action in
                        moreButton(action) { label in
                            HStack { label; Spacer(minLength: 0) }
                                // The whole row is the target; the sheet draws slightly scaled.
                                .frame(minHeight: 52)
                        }
                    }
                    if session.encodingLabel != nil {
                        moreEncodingMenu.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    }
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(moreActions) { action in
                        moreButton(action) { label in
                            label.labelStyle(ReaderToolLabelStyle())
                                .frame(maxWidth: .infinity, minHeight: 56)
                        }
                    }
                    if session.encodingLabel != nil {
                        moreEncodingMenu.labelStyle(ReaderToolLabelStyle())
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                }
            }
        }
        .padding(.horizontal, 24).padding(.top, LayoutTokens.content)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("readerMorePanel")
    }

    private func changeEncoding(_ encoding: String?) {
        controlsVisible = false; dock = .progress
        closeSearch()
        // Leaving the pushed settings page programmatically does not run its
        // binding's `panel == .settings` branch. Release the former sheet gate.
        sheetDismissRequested = false
        session.restart(encoding: encoding)
    }

    private var moreEncodingMenu: some View {
        ReaderEncodingMenu(title: "更换编码", symbol: "character.bubble", select: changeEncoding)
            .foregroundStyle(Color(uiColor: theme.ink))
            .accessibilityIdentifier("moreTextEncoding")
    }

    private enum MoreAction: String, Identifiable {
        case bookmark, bookmarks, notes, details
        var id: Self { self }
    }

    private var moreActions: [MoreAction] { [.bookmark, .bookmarks, .notes, .details] }

    /// One 更多 action: the visible names stay short; VoiceOver and Voice Control get the full ones.
    private func moreButton(_ action: MoreAction, @ViewBuilder layout: (MoreLabel) -> some View) -> some View {
        let marked = action == .bookmark && session.bookmarked
        let symbol = switch action {
        case .bookmark: marked ? "bookmark.fill" : "bookmark"
        case .bookmarks: "list.bullet.rectangle"
        case .notes: "highlighter"
        case .details: "info.circle"
        }
        let title: LocalizedStringKey = switch action {
        case .bookmark: "书签"
        case .bookmarks: "书签列表"
        case .notes: "笔记"
        case .details: "详情"
        }
        let label = MoreLabel(title: title, symbol: symbol, bookmarked: session.bookmarked, reduceMotion: reduceMotion)
        return Button {
            switch action {
            case .bookmark: Task { await session.toggleBookmark() }
            case .bookmarks: openLibrary(.bookmarks, fromMore: true)
            case .notes: openLibrary(.notes, fromMore: true)
            case .details: presentPanel(.details)
            }
        } label: {
            layout(label).foregroundStyle(Color(uiColor: marked ? theme.accent : theme.ink)).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(action == .bookmark && (session.showingCover || session.changingBookmark))
        .opacity(action == .bookmark && session.showingCover ? 0.45 : 1)
        .modifier(MoreAccessibility(action: action, bookmarked: session.bookmarked, cover: session.showingCover))
    }

    /// The action's label; the surrounding label style decides the layout.
    private struct MoreLabel: View {
        let title: LocalizedStringKey
        let symbol: String
        let bookmarked: Bool
        let reduceMotion: Bool
        var body: some View {
            Label(title, systemImage: symbol)
                .contentTransition(.symbolEffect(.replace))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: bookmarked)
        }
    }

    private struct MoreAccessibility: ViewModifier {
        let action: MoreAction
        let bookmarked: Bool
        let cover: Bool
        func body(content: Content) -> some View {
            switch action {
            case .bookmark:
                content
                    .accessibilityLabel("书签")
                    .accessibilityValue(bookmarked ? Text("已添加") : Text("未添加"))
                    .accessibilityHint(cover ? Text("封面不能添加书签") : Text("添加或移除当前位置的书签"))
                    .accessibilityInputLabels([Text("书签"), Text("添加书签"), Text("移除书签")])
                    .accessibilityAddTraits(bookmarked ? .isSelected : [])
                    .accessibilityIdentifier("toggleBookmark")
            case .bookmarks:
                content.accessibilityLabel("书签列表").accessibilityHint("查看全部书签")
                    .accessibilityIdentifier("openBookmarks")
            case .notes:
                content.accessibilityLabel("标注与笔记")
                    .accessibilityInputLabels([Text("笔记"), Text("标注与笔记")])
                    .accessibilityIdentifier("openNotes")
            case .details:
                content.accessibilityLabel("小说详情")
                    .accessibilityInputLabels([Text("详情"), Text("小说详情")])
                    .accessibilityIdentifier("moreBookDetails")
            }
        }
    }

    private var preparationFraction: Double? {
        guard let state = session.snapshot, state.sourceByteCount > 0 else { return nil }
        return min(1, Double(state.sourceBytesRead) / Double(state.sourceByteCount))
    }

    private var preparationView: some View {
        ReaderTitlePage(title: session.book?.title ?? route.title)
            .overlay(alignment: .bottom) {
                VStack(spacing: 12) {
                if session.preparing && session.error == nil {
                    if session.opening.showsProgress {
                        HStack(spacing: 12) {
                            LoadingActivity(size: 24, fraction: preparationFraction, delay: .zero)
                            Text("正在准备正文").font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                            Button("暂停准备", systemImage: "pause", action: session.pause).labelStyle(.iconOnly)
                        }
                    }
                } else {
                    Text(session.snapshot?.phase == .paused ? String(localized: "准备已暂停") : String(localized: "暂时无法准备正文"))
                        .font(.headline)
                    if let error = session.snapshot?.error.map { ReaderMessages.error($0) } ?? session.error {
                        Text(error).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                            .multilineTextAlignment(.center)
                    }
                    if session.snapshot != nil {
                        Button("继续准备", action: session.resume).buttonStyle(.bordered)
                        encodingMenu
                    } else {
                        Button("重试") { Task { await session.retry(route) } }.buttonStyle(.bordered)
                    }
                }
                }
                .padding(.horizontal, 28).padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .background(Color(uiColor: theme.paper))
                .padding(.bottom, 12)
            }
        .accessibilityIdentifier("preparingBook")
    }

    private var importStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if session.preparing { LoadingActivity(size: 28, fraction: preparationFraction) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.preparing ? String(localized: "正在准备后续内容") : (session.snapshot?.phase == .failed ? String(localized: "准备失败") : String(localized: "准备已暂停")))
                        .font(.subheadline.weight(.medium))
                    if let fraction = preparationFraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption).monospacedDigit().foregroundStyle(Color(uiColor: theme.secondary))
                    }
                }
                Spacer()
                Button(session.preparing ? String(localized: "暂停") : String(localized: "继续")) {
                    if session.preparing { session.pause() } else { session.resume() }
                }
                    .font(.subheadline).frame(minHeight: 44)
            }
            if let message = session.snapshot?.error {
                Text(ReaderMessages.error(message)).font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                HStack {
                    Button("重新准备") { session.restart() }
                    Spacer()
                    encodingMenu
                }.font(.caption)
            }
        }
        .padding(16)
        .background(theme.floatingBackground(.thinMaterial), in: .rect(cornerRadius: LayoutTokens.floatingRadius))
        .accessibilityIdentifier("importStatus")
    }

    private var encodingMenu: some View {
        ReaderEncodingMenu(select: changeEncoding)
    }

}

/// Battery monitoring is a platform concern and only runs while reading.
@MainActor @Observable
private final class ReaderBattery {
    private(set) var level: Float = -1
    private(set) var state: UIDevice.BatteryState = .unknown
    private var observers: [NSObjectProtocol] = []
    private var wasMonitoring = false

    var symbol: String {
        if state == .charging { return "battery.100percent.bolt" }
        guard level >= 0 else { return "battery.0percent" }
        switch level {
        case ..<0.125: return "battery.0percent"
        case ..<0.375: return "battery.25percent"
        case ..<0.625: return "battery.50percent"
        case ..<0.875: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var accessibilityLabel: String {
        guard level >= 0 else { return "电量不可用" }
        let percentage = Int((level * 100).rounded())
        return state == .charging ? String(localized: "电量百分之\(percentage)，正在充电") : String(localized: "电量百分之\(percentage)")
    }

    func start() {
        guard observers.isEmpty else { return }
        wasMonitoring = UIDevice.current.isBatteryMonitoringEnabled
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()
        observers = [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
    }

    func refresh() {
        level = UIDevice.current.batteryLevel
        state = UIDevice.current.batteryState
    }

    func stop() {
        guard !observers.isEmpty else { return }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        UIDevice.current.isBatteryMonitoringEnabled = wasMonitoring
    }
}

/// The content above the reader's anchored tools: progress (or search/browse), quick settings, or 更多.
private enum ReaderDock { case progress, settings, more }

private struct ReaderToolLabelStyle: LabelStyle {
    @ScaledMetric(relativeTo: .body) private var iconSize = 22.0
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 6) {
            configuration.icon.font(.system(size: iconSize)).frame(width: iconSize + 4, height: iconSize + 4)
            configuration.title.font(.caption).lineLimit(1)
        }
        .padding(.vertical, 4)
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


/// Manual choices do not perform detection in Swift. Labels are encoding_rs names;
/// the Rust decoding policy validates and canonicalizes every selected value.
enum ReadingEncodingGroup: String, CaseIterable, Identifiable {
    case simplifiedChinese, traditionalChinese, japanese, korean, westernEuropean, other
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁体中文"
        case .japanese: "日文"
        case .korean: "韩文"
        case .westernEuropean: "西欧"
        case .other: "其他编码"
        }
    }
    var encodings: [String] {
        switch self {
        case .simplifiedChinese: ["gb18030", "GBK"]
        case .traditionalChinese: ["Big5"]
        case .japanese: ["Shift_JIS", "EUC-JP", "ISO-2022-JP"]
        case .korean: ["EUC-KR"]
        case .westernEuropean: ["windows-1252", "ISO-8859-14", "ISO-8859-15", "macintosh"]
        case .other: ["UTF-8", "UTF-16LE", "UTF-16BE", "IBM866", "ISO-8859-2", "ISO-8859-3", "ISO-8859-4",
                      "ISO-8859-5", "ISO-8859-6", "ISO-8859-7", "ISO-8859-8", "ISO-8859-8-I", "ISO-8859-10",
                      "ISO-8859-13", "ISO-8859-16", "KOI8-R", "KOI8-U", "windows-1250", "windows-1251",
                      "windows-1253", "windows-1254", "windows-1255", "windows-1256", "windows-1257",
                      "windows-1258", "windows-874", "x-mac-cyrillic"]
        }
    }
}

struct ReaderEncodingMenu: View {
    var title: LocalizedStringKey = "更换编码重新打开"
    var value: String? = nil
    var symbol: String? = nil
    let select: (String?) -> Void
    @State private var pendingEncoding: String?
    @Environment(\.theme) private var theme
    var body: some View {
        Menu {
            Button("自动识别") { pendingEncoding = "auto" }
            ForEach(ReadingEncodingGroup.allCases) { group in
                Menu {
                    ForEach(group.encodings, id: \.self) { encoding in
                        Button(encoding) { pendingEncoding = encoding }
                    }
                } label: { Text(group.title) }
            }
        } label: {
            HStack {
                if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
                if let value {
                    Spacer()
                    HStack(spacing: 5) {
                        Text(value)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .accessibilityHidden(true)
                    }.foregroundStyle(Color(uiColor: theme.accent))
                }
            }.contentShape(.rect)
        }
        .menuOrder(.fixed)
        .accessibilityLabel(value.map { Text("文字编码，\($0)，可更换") } ?? Text(title))
        .accessibilityIdentifier("readerEncodingMenu")
        .alert("更换文字编码？", isPresented: Binding(get: { pendingEncoding != nil }, set: { if !$0 { pendingEncoding = nil } }), presenting: pendingEncoding) { encoding in
            Button("重新读取") { pendingEncoding = nil; select(encoding == "auto" ? nil : encoding) }
            Button("取消", role: .cancel) { pendingEncoding = nil }
        } message: { _ in
            Text("正文会按新编码重新读取。当前编码下的阅读位置、书签和批注不会带到不同的新正文，原数据会保留。原文件未变时，换回原编码可找回。")
        }
    }
}
