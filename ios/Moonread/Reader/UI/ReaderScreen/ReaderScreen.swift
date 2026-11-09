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
    @State var coverInformation: BookDetails?
    @State private var coverRequest = UUID()
    @Environment(LibraryModel.self) private var library
    @State private var tools = ReaderToolsModel()
    @State private var toolSession = ReaderToolSession()
    @State private var presentationOwner = UUID()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var sourceCurrent = false
    @State private var layoutStatus = ReadingLayoutStatus()
    private var isWide: Bool { horizontalSizeClass == .regular }
    @State private var controlsTipHeight: CGFloat = 0
    @State private var dockHeight: CGFloat = 220
    @State private var pendingProgressNavigation = false
    @State private var libraryNavigationRevision: Int?
    @State private var settingsPreview = ReadingPreviewSource.sample
    @State private var readerWidth: CGFloat = 390
    @State private var localHeaderTop: CGFloat = 0
    @State private var battery = ReaderBattery()
    @State private var exitPhase = ReaderExitPhase.reading
    @State private var navigationPresentation = NavigationPresentationState()
    // Same View-owned storage; extensions only read the existing owner/binding values.
    var readerSession: ReaderSession { session }
    var readerTools: ReaderToolsModel { tools }
    var readerDockHeight: CGFloat { dockHeight }

    var automatic: ReaderAutoReading { session.autoReading }
    private var automaticSelected: Bool { renderedNode.location.selection == .automatic }
    private var automaticHidden: Bool { automaticSelected && renderedNode.exposure == .hidden }
    var attachmentExpanded: Bool {
        get { automaticSelected ? renderedNode.exposure == .expanded : searchExpanded }
        nonmutating set {
            if automaticSelected {
                guard !nativeHost.dismissing, !automatic.hidingTools else { return }
                presentation.exposure = newValue ? .expanded : .accessory
            } else { searchExpanded = newValue }
        }
    }
    private var presentation: ReaderPresentationState { toolSession.presentation }
    private var nativeHost: ReaderPresentationHost { toolSession.host }
    private var currentNode: ReaderInstalledNode {
        ReaderInstalledNode(location: presentation.location, exposure: presentation.exposure,
            controls: presentation.controlsVisible, searchActive: tools.searchActive,
            noteID: session.editor?.presentationID, noteEditor: session.noteEditorModel, editor: toolSession.editor)
    }
    private var renderedNode: ReaderInstalledNode {
        nativeHost.dismissing ? (nativeHost.node ?? currentNode) : currentNode
    }
    var controlsVisible: Bool {
        get { renderedNode.controls }
        nonmutating set {
            if newValue { automatic.pause() }
            presentation.setControlsVisible(newValue)
        }
    }
    var dock: ReaderDock {
        get { renderedNode.dock }
        nonmutating set {
            automatic.pause()
            switch newValue { case .automatic: presentation.location.selection = .automatic
            case .settings: presentation.location.selection = .settings; case .more: presentation.location.selection = .more
            case .progress: presentation.location.selection = tools.searchActive ? .search : .library }
            presentation.exposure = .accessory
        }
    }
    private var searchActive: Bool {
        get { renderedNode.searchActive }
        nonmutating set { if newValue { tools.beginSearchSession() } else { tools.stopSearch() } }
    }
    var searchExpanded: Bool {
        get { renderedNode.searchExpanded }
        nonmutating set { presentation.expandSearch(newValue) }
    }
    private var libraryReturnsToMore: Bool { presentation.location.selection == .more && presentation.location.path.contains(.library) }
    private var panel: ReaderPanel? {
        get { renderedNode.panel }
        nonmutating set {
            guard panel != newValue else { return }
            switch newValue {
            case .library: presentation.push(.library)
            case .settings: presentation.push(.fullSettings)
            case .history: presentation.push(.history)
            case .details: presentation.push(.details)
            case .ai: presentation.push(.ai)
            case .chapterEditor: break // The editor owner has already published its ID.
            case .search:
                toolSession.setPath([])
                if presentation.location.selection != .more { presentation.location.selection = .search }
            case nil: toolSession.setPath([])
            }
        }
    }
    private var sheetPresented: Bool {
        nativeHost.token != nil && nativeHost.target == .dock
    }
    private var sheetDismissRequested: Bool {
        get { nativeHost.dismissing }
        nonmutating set { if newValue { nativeHost.installation.beginDismissal() } }
    }

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
    @Environment(\.moonreadReduceMotion) var reduceMotion
    @Environment(\.theme) var theme

    func readingView(window: ReadingWindow, settings: ReaderSettings) -> some View {
        // Keep the representable (and its selection/pager) alive when the native
        // host changes size class; only its geometry input changes.
        GeometryReader { geometry in
            readingView(window: window, settings: settings,
                geometry: isWide ? ReadingContentGeometry(size: geometry.size) : nil)
                .overlay(alignment: .top) {
                    if isWide, !session.isLeaving, !readerNavigationVisible, let book = session.book {
                        ReaderCompactHeader(session: session, battery: battery, book: book, readerWidth: geometry.size.width,
                            compactHeaderHeight: compactHeaderHeight, showControls: { controlsVisible = true })
                            .padding(.top, localHeaderTop)
                            .opacity(navigationPresentation.isSuspended ? 0 : 1)
                    }
                }
        }
        .ignoresSafeArea(.container)
        .overlay { if isWide, !layoutStatus.hasValidLayout { ReaderTitlePage(title: session.book?.title ?? route.title, information: coverInformation, contentSHA256: session.book?.contentSha256) } }
    }

    private func readingView(window: ReadingWindow, settings: ReaderSettings, geometry: ReadingContentGeometry?) -> some View {
                ReadingView(window: window, settings: settings, anchor: session.displayAnchor ?? session.anchor,
                            openingID: session.opening.request?.id,
                            requestWindow: { direction,keep in session.requestWindow(direction,retaining:keep) },
                            dark: colorScheme == .dark, dynamicTypeSize: dynamicTypeSize,
                            navigationRevision: session.navigationRevision,
                            navigation: session.navigation, resumeAutomaticReading: requestAutomaticStart, autoReading: automatic, viewportAccess: session.viewportAccess,
                            annotations: session.annotations, bookmarkPositions: session.bookmarkPositions, focusRange: session.focusRange,
                            selectionStart: session.selectionStart, selection: selectText,
                            allowsBackGesture: allowsReaderBack,
                            prepareInteractivePop: {
                                var transaction = Transaction(); transaction.disablesAnimations = true
                                withTransaction(transaction) { navigationPresentation.prepareInteractivePop() }
                            },
                            endUnstartedInteractivePop: { navigationPresentation.endUnstartedInteractivePop() },
                            allowsSelection: (panel == nil || panel == .search) && toolSession.editor == nil && session.noteEditorModel == nil,
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
                            bodyDisplayed: { session.bodyDidDisplay() },
                            statisticsInteraction: { session.activity.interacted() },
                            statisticsPresentationChanged: { [weak activity = session.activity, weak automatic, weak viewport = session.viewportAccess] in
                                activity?.sample()
                                if automatic?.running == true, activity?.bodyReadable(through: viewport) != true { automatic?.pause() }
                            },
                            annotationChooserChanged: { choosingAnnotations = $0 },
                            edgeChanged: { session.nearEdge = $0 },
                            compactHeaderHeight: compactHeaderHeight,
                            guideHeight: Onboarding.shared.enabled && !Onboarding.shared.revealedControls && !controlsVisible ? controlsTipHeight : 0,
                            contentGeometry: geometry, layoutStatus: layoutStatus,
                            headerPositionChanged: { localHeaderTop = $0 },
                            controlsVisible: controlsVisible,
                            toggleControls: toggleReadingControls,
                            readingBegan: { session.beganReadingInteraction(); controlsVisible = false },
                            positionChanged: { offset, end in
                                if !navigationPresentation.isSuspended { session.moved(to: offset, settled: end, userInitiated: false) }
                            })
                    .allowsHitTesting(panel?.isPage != true)
                    .ignoresSafeArea(.container)
                    .accessibilityIdentifier("readingContent")
                    .modifier(ReaderImportDiagnosticStatus(complete: session.snapshot?.phase == .complete))
                    .transition(.opacity)
    }

    private func toggleReadingControls() {
        guard panel == nil || panel == .search else { return }
        if automaticSelected && !automaticHidden { closeReadingControls(); return }
        if automaticHidden { presentation.choose(.library, exposure: .accessory) }
        if controlsVisible { closeReadingControls() }
        else { controlsVisible = true; synchronizeNativePresentation() }
    }

    /// Body taps and cancelled native returns use the same close path. The
    /// header, status bar, navigation and sheet all derive from that one intent.
    private func closeReadingControls() {
        if automaticSelected && !automaticHidden { closeAutomaticReading() }
        else { controlsVisible = false }
        synchronizeNativePresentation()
    }

    private var allowsReaderBack: Bool {
        exitPhase == .reading && !navigationPresentation.isSuspended
            && (panel == nil || panel == .search) && !searchExpanded
            && taskID == nil && !sheetDismissRequested
            && session.editor == nil && session.error == nil && !session.navigating
    }

    private var navigableReader: some View {
        readerContent
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
        let token = nativeHost.token
        let generation = presentation.revision
        return moonAwareReader
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
        .toolbarVisibility(.hidden, for: .tabBar)
        .statusBarHidden(!presentation.controlsVisible)
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
            if !isWide, !session.isLeaving, !readerNavigationVisible, let book = session.book {
                compactHeader(book: book)
                    .opacity(navigationPresentation.isSuspended ? 0 : 1)
            }
        }
        // The presentation has one identity. Routes change inside it, including
        // library, history and notes; they never dismiss and re-present the dock.
        .sheet(isPresented: Binding(get: {
            rootPresentation == .dock
        }, set: { shown in
            guard !shown, !navigationPresentation.isSuspended, !sheetDismissRequested else { return }
            nativeDockClosed(token: token, generation: generation)
        }), onDismiss: { presentationDismissed(token) }) { readerSheet }
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
            library.systemReading.savingEdits = { [weak session, weak toolSession] in
                session?.noteEditorModel?.saving == true || session?.chapterDraft?.saving == true || toolSession?.savingDraft == true
            }
            library.systemReading.hasUnsavedEdits = { [weak session, weak toolSession] in
                session?.noteEditorModel?.hasUnsavedChanges == true || session?.chapterDraft?.hasUnsavedChanges == true || toolSession?.hasUnsavedChanges == true
            }
            library.systemReading.hasEditor = { [weak session, weak toolSession] in
                session?.noteEditorModel != nil || toolSession?.hasEditableDraft == true
            }
            library.systemReading.discardEdits = { [weak session, weak toolSession] in
                session?.editor = nil; session?.chapterDraft = nil
                if let current = toolSession?.editor { toolSession?.finishEditing(current.id) }
            }
            if coverInformation == nil, let metadata = openingRequest?.metadataHint {
                coverInformation = BookDetails(book: nil, metadata: metadata, wordCount: 0, chapterCount: 0, currentChapter: nil)
            }
            await session.open(route, request: openingRequest)
        }
        .onChange(of: library.systemReading.pending) { _, request in
            if request != nil { automatic.pause() }
            // A plain reading toolbar can close through its normal onDismiss
            // path. Editors, searches and AI work keep their draft/presentation.
            if request != nil, !session.isLeaving, panel == nil, taskID == nil,
               session.editor == nil, session.chapterDraft == nil, !searchActive {
                controlsVisible = false
            }
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
            session.notesChanged() // CloudSync also posts bookMetadataChanged once for this import.
        }
        .onReceive(NotificationCenter.default.publisher(for: .statisticsChanged).receive(on: DispatchQueue.main)) { notification in
            // Keep clear/import invalidation alive even while the directory is
            // closed. Ordinary appends retain validated values until replacement.
            let reset = notification.userInfo?["reset"] as? Bool == true
            Task {
                await tools.refreshChapterStatistics(reset: reset,
                    presented: !session.isLeaving && !navigationPresentation.isSuspended && nativeHost.presentsChapterList)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudReadingPositionsReceived).receive(on: DispatchQueue.main)) { _ in
            Task { await session.refreshSyncedContinuation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .readingContinuationInvalidated).receive(on: DispatchQueue.main)) { _ in
            session.invalidateSyncedContinuation()
        }
        .onChange(of: statisticsVisibility, initial: true) { _, visibility in
            session.activity.update(visibility: visibility, preview: session.browseOrigin != nil)
            if statisticsReadable { session.systemReadingBecameReadable() }
        }
        .onChange(of: session.browseOrigin != nil) { _, preview in
            session.activity.update(visibility: statisticsVisibility, preview: preview)
        }
        .onReceive(NotificationCenter.default.publisher(for: .statisticsPreferencesChanged).receive(on: DispatchQueue.main)) { _ in
            Task { await session.activity.reloadPreferences() }
        }
    }

    private var presentationAwareReader: some View {
        monitoredReader
        .onAppear {
            synchronizeNativePresentation()
            contentVisible = true; session.opening.visibility(true, active: scenePhase == .active)
            session.opening.reduceMotion(reduceMotion)
            battery.start()
            session.activity.update(visibility: statisticsVisibility, preview: session.browseOrigin != nil)
        }
        .onChange(of: library.selectedTab) { _, _ in automatic.pause(); synchronizeNativePresentation() }
        .onChange(of: automatic.panelRequest) { _, _ in
            guard scenePhase == .active, !session.isLeaving, !sheetPresented,
                  !session.viewportAccess.hasBlockingPresentation(allowingReaderAccessory: false),
                  presentation.sourcePage == nil else { return }
            openAutomaticReading()
        }
        .onChange(of: session.opening.navigationSettled) { _, _ in synchronizeNativePresentation() }
        .onChange(of: sourceCurrent) { _, _ in synchronizeNativePresentation() }
        .onChange(of: nativeHost.phase) { _, _ in synchronizeNativePresentation() }
        .onChange(of: desiredPresentation, initial: true) { _, _ in synchronizeNativePresentation() }
        .onChange(of: presentation.revision) { _, _ in synchronizeNativePresentation() }
        .onChange(of: nativeHost.token?.id) { _, token in
            if token == nil {
                synchronizeNativePresentation(animatePage: true)
                startAutomaticAfterDismissal()
            }
        }
        .onChange(of: nativeHost.hasModalChild) { _, child in if !child { synchronizeNativePresentation() } }
        .onChange(of: session.opening.phase) { _, _ in synchronizeNativePresentation() }
        .onChange(of: theme.plan) { _, _ in synchronizeNativePresentation() }
    }

    private var lifecycleReader: some View {
        presentationAwareReader
        .onChange(of: controlsVisible) { _, visible in
            if visible { session.refreshBookmark(); Onboarding.shared.didShowControls() }
        }
        .onChange(of: session.navigating) { _, navigating in
            if !navigating, let revision = libraryNavigationRevision {
                libraryNavigationRevision = nil
                // A chosen record moves the text: return to reading, never to 更多.
                if panel == .library, session.navigationRevision > revision { presentation.location.selection = .library; closeTask() }
            }
            if !navigating, pendingProgressNavigation {
                pendingProgressNavigation = false
                if session.browseOrigin != nil { controlsVisible = false }
            }
        }
        .onChange(of: session.chapterDraft?.id) { _, id in
            if id != nil, let draft = session.chapterDraft {
                toolSession.beginEditing(.chapter(draft), presenter: .readerTask)
                session.chapterDraft = nil
                presentPanel(.chapterEditor)
            }
        }
        .onChange(of: session.editor?.presentationID) { _, id in
            if let id {
                controlsVisible = false; dock = .progress; searchExpanded = false
                presentation.push(.note(id))
            } else if let route = presentation.location.path.last, case .note = route { presentation.close(route) }
        }
        .onChange(of: undoCapsuleVisible, initial: true) { _, visible in tools.setUndoVisible(visible) }
        .onChange(of: reduceMotion) { _, value in session.opening.reduceMotion(value) }
        .onChange(of: scenePhase) { _, phase in
            session.opening.visibility(contentVisible, active: phase == .active)
            if phase != .active { automatic.pause() }
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
            automatic.pause()
            contentVisible = false; session.opening.visibility(false, active: false)
            session.activity.update(visibility: .init(body: false), preview: session.browseOrigin != nil)
            battery.stop()
            // Settings are pushed above the reader in the same navigation stack.
            // Only leaving its navigation destination ends the reading session.
            if session.isLeaving { completeReturning() }
        }
    }

    private var readingErrorPresented: Binding<Bool> {
        Binding(get: { !session.isLeaving && session.error != nil && session.book != nil },
                set: { if !$0 && !session.isLeaving { session.error = nil } })
    }

    private var sourceObserver: some View {
        NavigationTransitionObserver(openingID: session.opening.request?.id ?? openingRequest?.id, expectedDepth: sourceDepth,
                                                   appeared: { id, reason in
                                                       completedOpeningID = id; session.opening.settled(id, reason: reason)
                                                   },
                                                   visibilityChanged: { visible in
                                                       contentVisible = visible; session.opening.visibility(visible, active: scenePhase == .active)
                                                   },
                                                   willLeave: { popping in
            if popping { navigationPresentation.begin(hasPresentation: sheetPresented) }
            if popping || presentation.sourcePage != nil || !sourceRoutePresent { sourceCurrent = false }
            ReaderSceneDiagnostics.record("source.willLeave", opening: session.opening.request?.id, fields: ["popping": popping])
        }, completed: { popping, cancelled in
            if cancelled { sourceCurrent = true }
            ReaderSceneDiagnostics.record("source.completed", opening: session.opening.request?.id, fields: ["popping": popping, "cancelled": cancelled])
            guard popping else { return }
            navigationPresentation.finish(cancelled: cancelled)
            if cancelled { closeReadingControls() }
            else if !sourceRoutePresent { completeReturning() }
        }, removed: { if !sourceRoutePresent { completeReturning() } }, becameCurrent: {
            sourceCurrent = true
            ReaderSceneDiagnostics.record("source.current", opening: session.opening.request?.id)
        })
    }

    private var sourceReader: some View {
        lifecycleReader
            .background(sourceObserver)
            .navigationTitle(session.book?.title ?? route.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(uiColor: theme.paper), for: .navigationBar)
            .toolbarBackground(readerOwnsChrome ? .visible : .automatic, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("小说详情", systemImage: "info.circle") { presentPanel(.details) }
                        .labelStyle(.iconOnly).toolbarGlyph()
                        .accessibilityIdentifier("readerBookDetails")
                }
            }
            .toolbarVisibility(readerOwnsChrome ? (readerNavigationVisible ? .visible : .hidden) : .automatic, for: .navigationBar)
        .navigationDestination(isPresented: sourcePageBinding(.fullSettings)) {
            ReaderSettingsView(settings: readingSettings, preview: settingsPreview, encoding: session.encodingLabel, isRestartingEncoding: session.restartingEncoding, changeEncoding: changeEncoding, editing: toolSession.settingsEditing, editorClosed: readerEditorClosed)
                .themeScope(theme)
                .preferredColorScheme(theme.scheme)
        }
        .navigationDestination(isPresented: sourcePageBinding(.details)) {
            // Like reading settings, the pushed page's UIKit chrome follows the reader appearance.
            StatisticsView(library: library, target: bookDetailsTarget)
                .themeScope(theme).preferredColorScheme(theme.scheme).toolbarVisibility(.hidden, for: .tabBar)
                .environment(\.returnToReading, returnToReading)
                .onAppear { returnToReading.close = closeBookDetails }
        }
    }

    private func sourcePageBinding(_ destination: ReaderDestination) -> Binding<Bool> {
        Binding(get: {
            // This gate only sequences entry: finish dismissing the tool sheet
            // before the system pushes. There is no installed source-page mirror.
            presentation.sourcePage == destination && !sheetPresented
        }, set: { shown in
            guard !shown, presentation.sourcePage == destination else { return }
            presentation.sourcePage = nil
            if destination == .fullSettings {
                presentation.location.selection = tools.searchActive ? .search : .library
                presentation.exposure = tools.searchActive ? .accessory : .hidden
            }
            toolSession.releaseFinishedEditors()
        })
    }

    @State private var excerptShare: NoteSharePayload?
    @State private var sharingExcerpt = false
    @State private var choosingAnnotations = false
    @Environment(\.systemReadingRouter) private var systemReadingRouter
    var body: some View {
        sourceReader
        .onChange(of: panel) { old, new in
            if old == .library, new != .library { tools.clearNoteSelection(); tools.selectingNotes = false }
        }
        .overlay { if sharingExcerpt { ProgressView().padding().background(Color(uiColor: theme.surface), in: .capsule) } }
        .sheet(item: $excerptShare) { LibraryShareSheet(files: $0.files, text: $0.text) }
        .modifier(SystemReadingConfirmation(active: !sheetPresented))
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
        automatic.end()
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

    private var statisticsVisibility: ReaderStatisticsVisibility {
        ReaderStatisticsVisibility(body: scenePhase == .active && !session.isLeaving && session.opening.phase == .reading && session.window != nil && !session.showingCover
            && !session.isLoading && !session.navigating && session.error == nil
            && !navigationPresentation.isSuspended && !controlsVisible && !searchExpanded
            && (dock == .progress || automaticHidden) && taskID == nil && panel?.isPage != true
            && toolSession.editor == nil,
            preparingExcerpt: sharingExcerpt, excerptPresented: excerptShare != nil,
            confirmationPresented: systemReadingRouter?.presentsConfirmation(active: !sheetPresented, editor: false) == true,
            choosingAnnotations: choosingAnnotations,
            readerAccessoryPresented: sheetPresented && nativeHost.phase == .confirmed
                && taskID == nil && (panel == nil || panel == .search) && dock == .progress && !searchExpanded && !controlsVisible)
    }

    private var statisticsReadable: Bool {
        statisticsVisibility.isReadable(nativeTaskPresented: session.viewportAccess.hasBlockingPresentation(
            allowingReaderAccessory: statisticsVisibility.readerAccessoryPresented))
    }

    private func loadCoverInformation() async {
        guard let id = session.readingID else { return }
        guard let sha = session.book?.contentSha256, (try? parseSha256(value: sha)) != nil else { return }
        let request = UUID(); coverRequest = request
        do {
            let next = try await AppDataService.shared.details(bookID: id, sha: sha)
            guard !Task.isCancelled, coverRequest == request, session.readingID == id,
                  session.book?.contentSha256 == sha else { return }
            coverInformation = next
        } catch { /* Keep the last successful value; failure is not a cover deletion. */ }
    }

    private var bookDetailsTarget: StatisticsRoute {
        if case let .source(file) = route {
            return StatisticsRoute(bookID: session.readingID, title: file.title, fileID: file.id, fromReader: true)
        }
        return StatisticsRoute(bookID: session.readingID, title: session.book?.title ?? route.title, fromReader: true)
    }

    private var taskID: String? { renderedNode.taskID }

    private var desiredPresentation: ReaderPresentationTarget {
        ReaderPresentationProjection.target(state: presentation,
            editorParent: toolSession.editor?.presenter, hasNote: session.noteEditorModel != nil,
            hasAccessory: !automatic.hidingTools && !automaticHidden && (tools.searchActive || session.browseOrigin != nil || tools.deletedIDs != nil),
            available: !session.isLeaving && exitPhase == .reading && !navigationPresentation.isSuspended)
    }
    private var rootPresentation: ReaderPresentationTarget { nativeHost.showing }
    private var sourceLocation: (tab: AppTab, depth: Int)? {
        (openingRequest?.id ?? session.opening.request?.id).flatMap { library.readerDestinationLocation($0) }
    }
    private var sourceDepth: Int? { sourceLocation?.depth }
    private var sourceSelected: Bool { sourceLocation.map { $0.tab == library.selectedTab } ?? true }
    private var sourceRoutePresent: Bool {
        guard let id = openingRequest?.id ?? session.opening.request?.id else { return true }
        return library.containsReaderDestination(id)
    }
    private var readerNativeReady: Bool {
        sourceRoutePresent && sourceSelected && sourceCurrent && session.opening.navigationSettled && presentation.sourcePage == nil
            && !navigationPresentation.isSuspended && !session.isLeaving
    }

    private var readerSheet: some View {
        let token = nativeHost.token
        return ReaderBottomPanel(expanded: Binding(get: { attachmentExpanded }, set: { attachmentExpanded = $0 }), compactHeight: $dockHeight,
                          canExpand: automaticSelected || (searchActive && dock == .progress), dismissing: nativeHost.dismissing, taskID: taskID,
                          closeTask: closeTask) {
            ReaderCompactLayout(selection: dock) {
                bottomDock
                    .transaction { $0.animation = nil }
                    .layoutValue(key: ReaderCompactIdentity.self, value: dock)
                    .id(dock)
                    .transition(MotionTokens.accessoryContent(reduced: reduceMotion))
            }
            .animation(MotionTokens.accessoryResize(reduced: reduceMotion), value: dock)
        } footer: {
            VStack(spacing: 0) {
                if (controlsVisible || automaticSelected), session.book != nil {
                    bottomControls.padding(.top, LayoutTokens.compact)
                }
            }.padding(.bottom, LayoutTokens.compact)
        } details: { readyForInput in
            if automaticSelected {
                ScrollView { automaticContent(expanded: true) }.scrollBounceBehavior(.basedOnSize)
            } else { searchContent(details: true, readyForInput: readyForInput) }
        } taskContent: {
            readerTask
        }
        .onAppear { if let token { nativeHost.confirmed(token) } }
        .interactiveDismissDisabled(!automaticSelected && taskID == nil && session.browseOrigin != nil)
        .themeScope(theme).preferredColorScheme(theme.scheme)
        .background(ReaderModalChildProbe(host: nativeHost))
        .overlay {
            if session.navigating && !session.isLeaving {
                LoadingActivity(size: 24, waitingLabel: "正在定位").allowsHitTesting(false)
            }
        }
    }

    private var readerTask: some View {
        ReaderTaskContent(panel: panel, session: session, tools: tools, toolSession: toolSession,
                          retainedNote: renderedNode.noteEditor, retainedEditor: renderedNode.editor, aiEntrySnapshot: aiEntrySnapshot,
                          aiContext: { aiContext() }, aiConversationID: $aiConversationID,
                          openingIsActive: { exitPhase == .reading && !session.isLeaving }, closeTask: closeTask,
                          navigate: navigateFromLibrary, edit: editFromLibrary, editorClosed: readerEditorClosed)
    }

    private func clearTask() {
        libraryNavigationRevision = nil
        session.editor = nil; session.chapterDraft = nil
        if let editor = toolSession.editor, editor.presenter == .readerTask { toolSession.finishEditing(editor.id) }
        toolSession.setPath([])
        session.notesChanged()
    }

    private func closeTask() {
        searchExpanded = false
        if panel == .library, libraryReturnsToMore {
            // The list collapses into the same sheet, back to the 更多 content it grew from.
            controlsVisible = true; dock = .more
            withAnimation(MotionTokens.panel(reduced: reduceMotion)) { clearTask(); readerEditorClosed() }
            return
        }
        controlsVisible = false; dock = .progress
        if hasReadingAccessory {
            withAnimation(MotionTokens.panel(reduced: reduceMotion)) { clearTask(); readerEditorClosed() }
        } else {
            // Keep the outgoing task intact until native dismissal finishes.
            sheetDismissRequested = true
            clearTask()
        }
    }

    private func nativeInputAllowed(_ token: ReaderHostToken?, generation: UInt64) -> Bool {
        guard let token else { return false }
        return nativeHost.acceptsInput(token, opening: session.opening.request?.id ?? presentationOwner, generation: generation)
            && generation == presentation.revision && desiredPresentation == nativeHost.target
    }
    private func nativeDockClosed(token: ReaderHostToken?, generation: UInt64) {
        guard nativeInputAllowed(token, generation: generation) else { return }
        if automaticSelected {
            closeAutomaticReading(); nativeHost.installation.beginDismissal(); return
        }
        controlsVisible = false; dock = .progress
        nativeHost.installation.beginDismissal()
        clearTask(); if tools.searchActive { closeSearch() }
    }
    private func presentationDismissed(_ token: ReaderHostToken?) {
        guard let token, nativeHost.completed(token) else { return }
        toolSession.releaseFinishedEditors()
        if navigationPresentation.presentationDismissed(), exitPhase != .reading { finishReturning(); return }
        guard exitPhase == .reading else { finishReturning(); return }
        synchronizeNativePresentation(animatePage: true)
    }

    private func completeReturning() {
        guard exitPhase == .reading else { return }
        if let editor = toolSession.editor { toolSession.finishEditing(editor.id) }
        navigationPresentation.begin(hasPresentation: sheetPresented)
        exitPhase = .saving
        presentation.reset(); searchActive = false
        tools.leave()
        reviewExitIsNormal = session.error == nil && session.book != nil
        let saved = session.leave()
        library.systemReading.unregister(session)
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

    func openLibrary(_ destination: ReaderLibraryTab, fromMore: Bool = false) {
        // Choose the list before publishing the panel: its first frame is already the target.
        tools.select(destination); presentPanel(.library)
        if fromMore { presentation.location.selection = .more }
    }

    /// Ends the details presentation, and every page pushed above it, back to reading.
    private func closeBookDetails() { presentation.close(.details) }

    func presentPanel(_ next: ReaderPanel) {
        automatic.end()
        guard panel != next || (next == .search && !searchExpanded) else { return }
        if next == .details {
            session.activity.update(visibility: .init(body: false), preview: session.browseOrigin != nil)
            if sheetPresented {
                presentation.push(.details)
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { nativeHost.installation.beginDismissal() }
            } else {
                withAnimation(MotionTokens.panel(reduced: reduceMotion)) {
                    presentation.push(.details)
                    synchronizeNativePresentation()
                }
            }
            return
        }
        if next == .settings, let window = session.window {
            var marks = session.annotations.map { ReadingPreviewSource.Mark(start: $0.startUtf8, end: $0.endUtf8) }
            if let focus = session.focusRange { marks.append(.init(start: focus.startUtf8, end: focus.endUtf8, search: true)) }
            settingsPreview = ReadingPreviewSource(window: window, anchor: session.anchor, title: session.book?.title ?? "", marks: marks)
        }
        controlsVisible = false; dock = .progress
        if next == .search {
            searchActive = true; searchExpanded = true
            panel = .search
            return
        }
        searchExpanded = false
        if sheetPresented, next.isPage {
            // Only the navigation push is animated. The native dismissal
            // callback still coordinates ownership of the presentation.
            panel = next
            if next == .settings { presentation.location.selection = .settings }
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { sheetDismissRequested = true }
        } else {
            withAnimation(MotionTokens.panel(reduced: reduceMotion)) {
                panel = next
                if next == .settings { presentation.location.selection = .settings }
                synchronizeNativePresentation()
            }
        }
    }

    func closeSearch() {
        searchActive = false
        searchExpanded = false
        panel = nil
    }

    private func selectText(start: UInt64, end: UInt64, action: ReaderSelectionAction) {
        automatic.end()
        if action != .shareExcerpt { session.beganReadingInteraction() }
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
        guard action == .search || action == .copy || action == .shareExcerpt else { session.selectText(start: start, end: end, action: action); return }
        guard !session.isLeaving, let id = session.readingID else { return }
        if action == .shareExcerpt {
            guard !sharingExcerpt, excerptShare == nil else { return }
            sharingExcerpt = true
        }
        session.readSelection(start: start, end: end, finished: {
            if action == .shareExcerpt { sharingExcerpt = false }
        }) { range in
            if action == .copy { UIPasteboard.general.string = range.text; return }
            if action == .shareExcerpt {
                do {
                    let text = try await AppDataService.shared.shareExcerpt(id, range: range)
                    guard !Task.isCancelled, !session.isLeaving, session.readingID == id else { return }
                    excerptShare = NoteSharePayload(text: text)
                } catch { session.error = ReaderMessages.error(error) }
                return
            }
            await tools.prepare(bookID: id, currentChapter: 0, library: false)
            guard !Task.isCancelled, !session.isLeaving, session.readingID == id else { return }
            tools.regex = false
            tools.query = range.text.trimmingCharacters(in: .whitespacesAndNewlines)
            presentPanel(.search)
            tools.startSearch()
        }
    }

    private func compactHeader(book: BookInfo) -> some View {
        ReaderCompactHeader(session: session, battery: battery, book: book, readerWidth: readerWidth,
                            compactHeaderHeight: compactHeaderHeight, showControls: { controlsVisible = true })
    }
    private var readerOwnsChrome: Bool {
        // The temporary bar belongs to C's interactive pop. Otherwise the
        // current reader owns its preference even while a tool is dismissing.
        navigationPresentation.revealsNavigation
            || (sourceSelected && sourceCurrent && presentation.sourcePage == nil && !session.isLeaving)
    }
    private var readerNavigationVisible: Bool {
        !session.isLeaving && (navigationPresentation.revealsNavigation
            || (!navigationPresentation.isSuspended && (presentation.controlsVisible || session.window == nil)))
    }

    private var readingSettings: Binding<ReaderSettings> {
        Binding(get: { session.settings ?? defaultReaderSettings() }, set: session.updateSettings)
    }

    private var bottomDock: some View {
        VStack(spacing: LayoutTokens.compact) {
            if controlsVisible, !session.isLeaving { continuationControl }
            if Onboarding.shared.enabled, Onboarding.shared.revealedControls, !Onboarding.shared.selectedText, controlsVisible {
                TipView(Onboarding.shared.selection).tipViewStyle(ThemedTipStyle(titleOverride: ai.availability.isAvailable ? nil : Text("长按文字可以标注、写批注或拷贝"))).accessibilityIdentifier("readerSelectionTip")
            }
            if dock == .automatic {
                automaticContent(expanded: false)
            } else if dock == .settings {
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

    func selectFooterDock(_ destination: ReaderDock) {
        if destination == .more { automatic.pause() } else { automatic.end() }
        let tool: ReaderTool = destination == .more ? .more : .settings
        if !presentation.leaveAutomaticAccessory(for: tool) { dock.toggle(destination) }
    }

    func openAutomaticReading() {
        automatic.pause()
        controlsVisible = false
        tools.stopSearch()
        toolSession.setPath([])
        presentation.choose(.automatic, exposure: .accessory)
    }

    func closeAutomaticReading() {
        presentation.setControlsVisible(false)
        presentation.choose(.automatic, exposure: .hidden)
    }

    func requestAutomaticStart() {
        guard session.settings?.mode == .scroll else { return }
        automatic.requestStart()
        closeAutomaticReading()
        if nativeHost.token == nil { startAutomaticAfterDismissal() }
    }

    private func startAutomaticAfterDismissal() {
        guard automatic.phase == .starting else { return }
        guard scenePhase == .active, readerNativeReady, automaticHidden else { automatic.pause(); return }
        session.activity.update(visibility: statisticsVisibility, preview: session.browseOrigin != nil)
        session.beganReadingInteraction() // Permit ordinary checkpoints; not a statistics interaction.
        automatic.startAfterDismissal(opening: session.opening.request?.id,
            speed: session.settings?.autoReadingSpeed ?? autoReadingControl().defaultValue)
    }

    func changeEncoding(_ encoding: String?) {
        controlsVisible = false; dock = .progress
        closeSearch()
        // Leaving the pushed settings page programmatically does not run its
        // binding's `panel == .settings` branch. Release the former sheet gate.
        sheetDismissRequested = false
        session.restart(encoding: encoding)
    }

    private func synchronizeNativePresentation(animatePage: Bool = false) {
        let update = {
            let desired = desiredPresentation
            let opening = session.opening.request?.id ?? presentationOwner
            let page = desired == .details || desired == .settings
            // Release the tool sheet before pushing on the source stack.
            let toolTarget: ReaderPresentationTarget = page || !readerNativeReady ? .none : desired
            if nativeHost.token == nil || (nativeHost.target == toolTarget && !nativeHost.dismissing) { nativeHost.retain(currentNode) }
            nativeHost.update(toolTarget, opening: opening, generation: presentation.revision,
                force: session.isLeaving || exitPhase != .reading || navigationPresentation.isSuspended)
            ReaderSceneDiagnostics.record("presentation.project", opening: opening, fields: [
                "sourceTab": String(describing: library.selectedTab), "sourceCurrent": sourceCurrent,
                "sourceRouteCount": library.path.count, "sourcePage": String(describing: presentation.sourcePage),
                "navigationSettled": session.opening.navigationSettled, "location": String(describing: presentation.location),
                "desired": String(describing: desired), "toolRequested": String(describing: nativeHost.showing),
                "toolPhase": nativeHost.phase.rawValue, "token": nativeHost.token?.id.uuidString ?? "none"])
        }
        if animatePage, desiredPresentation == .settings || desiredPresentation == .details {
            withAnimation(reduceMotion ? nil : .default, update)
        } else { update() }
    }
    private func readerEditorClosed() { synchronizeNativePresentation() }

    private func navigateFromLibrary(_ start: UInt64, _ end: UInt64?, _ placement: ReadingTargetPlacement) {
        guard !session.isLeaving else { return }
        libraryNavigationRevision = session.navigationRevision
        session.browse(to: start, end: end, placement: placement)
    }

    private func editFromLibrary(_ mark: ReaderMark) {
        guard !session.isLeaving else { return }
        session.openAnnotation(mark.id)
    }


}
