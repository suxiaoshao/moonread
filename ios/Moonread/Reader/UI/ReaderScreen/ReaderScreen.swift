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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var sourceCurrent = false
    @State private var layoutStatus = ReadingLayoutStatus()
    private var isWide: Bool { horizontalSizeClass == .regular }
    @State private var controlsTipHeight: CGFloat = 0
    @State private var dockHeight: CGFloat = 220
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

    private var automatic: ReaderAutoReading? { session.autoReading }
    private var listening: ListeningSession? { session.activeListening }
    var toolSession: ReaderToolSession { session.toolsSession }
    private var tools: ReaderToolsModel { toolSession.tools }
    private var nativeHost: ReaderPresentationHost { toolSession.host }
    private var render: ReaderRenderSnapshot { toolSession.render }
    private var rendered: ReaderRenderSnapshot { nativeHost.dismissing ? (nativeHost.node ?? render) : render }
    var controlsVisible: Bool { rendered.controls }
    private var taskID: String? { rendered.taskID }
    private var isSearch: Bool { rendered.compact == .search }
    private var isLibrary: Bool { rendered.taskID == "library" }
    private var isAI: Bool { rendered.taskID == "ai" }
    private var sheetPresented: Bool { nativeHost.token != nil && nativeHost.target == .dock }

    func sendTool(_ action: ReaderToolSession.Action, from context: ReaderActionContext? = nil) {
        withAnimation(MotionTokens.panel(reduced: reduceMotion)) { toolSession.send(action, from: context) }
    }

    @Environment(AIService.self) private var ai
    @State private var aiConversationID: String?
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
                            compactHeaderHeight: compactHeaderHeight, showControls: { sendTool(.showChrome) })
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
                            navigation: session.navigation, resumeAutomaticReading: requestAutomaticStart, listening: listening, listeningUIActive: listeningBodyVisible, autoReading: automatic, viewportAccess: session.viewportAccess,
                            annotations: session.annotations, bookmarkPositions: session.bookmarkPositions, focusRange: session.focusRange,
                            selectionStart: session.selectionStart, selection: selectText,
                            allowsBackGesture: allowsReaderBack,
                            prepareInteractivePop: {
                                var transaction = Transaction(); transaction.disablesAnimations = true
                                withTransaction(transaction) { navigationPresentation.prepareInteractivePop() }
                            },
                            endUnstartedInteractivePop: { navigationPresentation.endUnstartedInteractivePop() },
                            allowsSelection: (taskID == nil && rendered.sourcePage == nil) && toolSession.editor == nil && session.noteEditorModel == nil,
                            allowsChapterEditing: !session.incomplete,
                            coverTitle: session.book?.title ?? route.title,
                            coverInformation: coverInformation,
                            showBookDetails: { openBookDetails() },
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
                            statisticsPresentationChanged: { [weak activity = session.activity, weak automatic, weak viewport = session.viewportAccess, weak listening] in
                                activity?.sample()
                                listening?.checkPresentation()
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
                            readingBegan: {
                                session.beganReadingInteraction()
                                if controlsVisible { sendTool(.hideChrome) }
                            },
                            positionChanged: { offset, end in
                                if !navigationPresentation.isSuspended { session.moved(to: offset, settled: end, userInitiated: false) }
                            })
                    .allowsHitTesting(rendered.sourcePage == nil)
                    .ignoresSafeArea(.container)
                    .accessibilityIdentifier("readingContent")
                    .modifier(ReaderImportDiagnosticStatus(complete: session.snapshot?.phase == .complete))
                    .transition(.opacity)
    }

    private func toggleReadingControls() {
        guard taskID == nil, rendered.sourcePage == nil else { return }
        sendTool(.toggleChrome)
    }

    private var allowsReaderBack: Bool {
        exitPhase == .reading && !navigationPresentation.isSuspended
            && (taskID == nil && rendered.sourcePage == nil) && !rendered.expanded
            && taskID == nil && !nativeHost.dismissing
            && session.editor == nil && session.error == nil && !session.navigating
    }

    private var navigableReader: some View {
        readerContent
    }

    /// Reading-time Moon notices for the conversation selected in this opening.
    private var moonAwareReader: some View {
        navigableReader
            .onChange(of: aiCurrentConversation?.moonSnapshot, initial: true) { _, snapshot in
                aiPresence.observe(snapshot, chatOpen: isAI) { aiCurrentConversation?.latestTurnProposes ?? false }
                revealAIMoonNotice()
            }
            .onChange(of: isAI) { _, open in
                if open { aiPresence.chatOpened() } else { aiPresence.chatClosed(); revealAIMoonNotice() }
            }
            .onChange(of: ai.availability.isAvailable) { _, available in
                if !available {
                    if isAI, let visit = render.visit { sendTool(.closeVisit(visit.id)) }
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
        .statusBarHidden(!render.controls)
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
            guard !shown, !navigationPresentation.isSuspended, !nativeHost.dismissing, let token else { return }
            sendTool(.nativeClose(token))
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
            if !controlsVisible, taskID == nil, rendered.sourcePage == nil, !session.isLeaving,
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
            if request != nil { sendTool(.systemRequest) }
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
            session.stopListening()
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
        .onChange(of: library.selectedTab) { _, _ in sendTool(.sourceChanged); synchronizeNativePresentation() }
        .onChange(of: automatic?.panelRequest) { _, _ in
            guard scenePhase == .active, !session.isLeaving, !sheetPresented,
                  !session.viewportAccess.hasBlockingPresentation(allowingReaderAccessory: false),
                  render.sourcePage == nil else { return }
            sendTool(.openAutomatic)
        }
        .onChange(of: session.opening.navigationSettled) { _, _ in synchronizeNativePresentation() }
        .onChange(of: sourceCurrent) { _, _ in synchronizeNativePresentation() }
        .onChange(of: nativeHost.phase) { _, _ in synchronizeNativePresentation() }
        .onChange(of: desiredPresentation, initial: true) { _, _ in synchronizeNativePresentation() }
        .onChange(of: render.context.revision) { _, _ in synchronizeNativePresentation() }
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
        .onChange(of: session.chapterDraft?.id) { _, id in
            if id != nil, let draft = session.chapterDraft {
                toolSession.beginEditing(.chapter(draft), presenter: .readerTask)
                session.chapterDraft = nil
            }
        }
        .onChange(of: session.editor?.presentationID) { _, _ in sendTool(.noteChanged(session.noteEditorModel)) }
        .onChange(of: undoCapsuleVisible, initial: true) { _, visible in tools.setUndoVisible(visible) }
        .onChange(of: reduceMotion) { _, value in session.opening.reduceMotion(value) }
        .onChange(of: listeningBodyVisible, initial: true) { _, visible in
            session.listeningUIActive = visible
            if visible {
                if listening?.active != true, let offset = session.listeningPosition { session.finishListeningPosition(offset, reveal: true) }
                else { session.followListeningPosition() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            session.opening.visibility(contentVisible, active: phase == .active)
            if phase != .active { sendTool(.backgrounded) }
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
            sendTool(.backgrounded)
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
            if popping || render.sourcePage != nil || !sourceRoutePresent { sourceCurrent = false }
            ReaderSceneDiagnostics.record("source.willLeave", opening: session.opening.request?.id, fields: ["popping": popping])
        }, completed: { popping, cancelled in
            if cancelled { sourceCurrent = true }
            ReaderSceneDiagnostics.record("source.completed", opening: session.opening.request?.id, fields: ["popping": popping, "cancelled": cancelled])
            guard popping else { return }
            navigationPresentation.finish(cancelled: cancelled)
            if cancelled { sendTool(.hideChrome) }
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
                    Button("小说详情", systemImage: "info.circle") { openBookDetails() }
                        .labelStyle(.iconOnly).toolbarGlyph()
                        .accessibilityIdentifier("readerBookDetails")
                }
            }
            .toolbarVisibility(readerOwnsChrome ? (readerNavigationVisible ? .visible : .hidden) : .automatic, for: .navigationBar)
        .navigationDestination(isPresented: sourcePageBinding(.settings)) {
            ReaderSettingsView(settings: readingSettings, preview: settingsPreview, encoding: session.encodingLabel, isRestartingEncoding: session.restartingEncoding, changeEncoding: changeEncoding, editing: toolSession.settingsEditing, editorClosed: readerEditorClosed)
                .environment(\.readerListeningOpening, session.opening.request?.id)
                .themeScope(theme)
                .preferredColorScheme(theme.scheme)
        }
        .navigationDestination(isPresented: sourcePageBinding(.details)) {
            // Like reading settings, the pushed page's UIKit chrome follows the reader appearance.
            StatisticsView(library: library, target: detailsTarget)
                .environment(\.readerListeningOpening, session.opening.request?.id)
                .themeScope(theme).preferredColorScheme(theme.scheme).toolbarVisibility(.hidden, for: .tabBar)
                .environment(\.returnToReading, returnToReading)
                .onAppear {
                    let visit = render.visit?.id
                    returnToReading.close = { if let visit { sendTool(.closeVisit(visit)) } }
                }
        }
    }

    private var detailsTarget: StatisticsRoute {
        if case .details(let target) = render.visit?.route { return target }
        return bookDetailsTarget
    }

    private func sourcePageBinding(_ destination: ReaderSourcePage) -> Binding<Bool> {
        let visit = render.visit?.id
        return Binding(get: { render.sourcePage == destination && !sheetPresented }, set: { shown in
            if !shown, let visit, render.sourcePage == destination { sendTool(.closeVisit(visit)) }
        })
    }

    @State private var excerptShare: NoteSharePayload?
    @State private var sharingExcerpt = false
    @State private var choosingAnnotations = false
    @Environment(\.systemReadingRouter) private var systemReadingRouter
    var body: some View {
        sourceReader
        .onChange(of: isLibrary) { old, new in
            if old && !new { tools.clearNoteSelection(); tools.selectingNotes = false }
        }
        .overlay { if sharingExcerpt { ProgressView().padding().background(Color(uiColor: theme.surface), in: .capsule) } }
        .sheet(item: $excerptShare) { LibraryShareSheet(files: $0.files, text: $0.text) }
        .modifier(SystemReadingConfirmation(active: !sheetPresented))
        .alert("阅读遇到问题", isPresented: readingErrorPresented) {
            Button("知道了", role: .cancel) { session.error = nil }
        } message: { Text(session.error ?? "") }
    }

    /// Where the Moon may appear at all: reading this book, with no task, panel or search on top.
    private var aiMoonAllowed: Bool {
        guard ai.availability.isAvailable, let sha = session.book?.contentSha256, !sha.isEmpty, !session.isLeaving else { return false }
        return taskID == nil && [.none, .progress, .browse, .search].contains(rendered.compact) && !rendered.expanded
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
        sendTool(.open(.ai(aiContext(selection: selection))))
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
            && !session.isLoading && !session.navigating && session.error == nil && listening?.running != true
            && !navigationPresentation.isSuspended && !controlsVisible && !rendered.expanded
            && ([.none, .progress, .browse, .search, .listening].contains(rendered.compact)) && taskID == nil && rendered.sourcePage == nil
            && toolSession.editor == nil,
            preparingExcerpt: sharingExcerpt, excerptPresented: excerptShare != nil,
            confirmationPresented: systemReadingRouter?.presentsConfirmation(active: !sheetPresented, editor: false) == true,
            choosingAnnotations: choosingAnnotations,
            readerAccessoryPresented: sheetPresented && nativeHost.phase == .confirmed
                && taskID == nil && (taskID == nil && rendered.sourcePage == nil) && ([.none, .progress, .browse, .search].contains(rendered.compact) || (rendered.compact == .listening && !rendered.expanded && listening?.running != true)) && !rendered.expanded && !controlsVisible)
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
        listening?.updateCover(title: session.book?.title ?? route.title, sha: session.book?.contentSha256,
            author: coverInformation?.metadata.author, cover: coverInformation?.metadata.cover, service: session.service)
    }

    private var bookDetailsTarget: StatisticsRoute {
        if case let .source(file) = route {
            return StatisticsRoute(bookID: session.readingID, title: file.title, fileID: file.id, fromReader: true)
        }
        return StatisticsRoute(bookID: session.readingID, title: session.book?.title ?? route.title, fromReader: true)
    }

    private var desiredPresentation: ReaderPresentationTarget {
        guard !session.isLeaving, exitPhase == .reading, !navigationPresentation.isSuspended else { return .none }
        return render.target
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
        sourceRoutePresent && sourceSelected && sourceCurrent && session.opening.navigationSettled && render.sourcePage == nil
            && !navigationPresentation.isSuspended && !session.isLeaving
    }

    private var listeningBodyVisible: Bool {
        scenePhase == .active && sourceCurrent && sourceSelected && render.sourcePage == nil
            && !navigationPresentation.isSuspended && !session.isLeaving
    }

    private var readerSheet: some View {
        let snapshot = rendered
        let context = snapshot.context
        let token = nativeHost.token
        return ReaderBottomPanel(expanded: Binding(get: { snapshot.expanded }, set: { expanded in
            guard !nativeHost.dismissing else { return }
            sendTool(expanded ? .expand : .collapse, from: context)
        }), compactHeight: $dockHeight, canExpand: snapshot.canExpand,
        dismissing: nativeHost.dismissing, taskID: snapshot.taskID, closeTask: {
            if let token, toolSession.acceptsNativeInput(token, generation: context.revision), let visit = snapshot.visit {
                sendTool(.closeVisit(visit.id), from: context)
            }
        }) {
            ReaderCompactLayout(selection: snapshot.compact) {
                bottomDock(snapshot)
                    .transaction { $0.animation = nil }
                    .layoutValue(key: ReaderCompactIdentity.self, value: snapshot.compact)
                    .id(snapshot.compact)
                    .transition(MotionTokens.accessoryContent(reduced: reduceMotion))
            }
            .animation(MotionTokens.accessoryResize(reduced: reduceMotion), value: snapshot.compact)
        } footer: {
            VStack(spacing: 0) {
                if (snapshot.controls || snapshot.compact == .automatic || (snapshot.compact == .listening && listening?.active != true)),
                   session.book != nil { bottomControls(snapshot).padding(.top, LayoutTokens.compact) }
            }.padding(.bottom, LayoutTokens.compact)
        } details: { readyForInput in
            switch snapshot.visit?.route {
            case .listeningSettings(let player, let child):
                NavigationStack {
                    ScrollView { listeningContent(player, snapshot: snapshot, expanded: true) }.scrollBounceBehavior(.basedOnSize)
                        .navigationTitle("听书").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) {
                            SystemToolbarButton("关闭", role: .close) { sendTool(.collapse, from: context) }.labelStyle(.iconOnly)
                        } }
                        .navigationDestination(isPresented: Binding(get: { child == .voices }, set: {
                            if !$0 { sendTool(.showVoices(false), from: context) }
                        })) {
                            ListeningVoicesView(session: player,
                                choose: { sendTool(.chooseVoice($0), from: context) },
                                preview: { sendTool(.previewVoice($0), from: context) })
                        }
                }
            case .automaticSettings(let auto):
                ScrollView { automaticContent(auto, snapshot: snapshot, expanded: true) }.scrollBounceBehavior(.basedOnSize)
            case .search:
                searchContent(snapshot, details: true, readyForInput: readyForInput)
            default:
                EmptyView()
            }
        } taskContent: {
            ReaderTaskContent(visit: snapshot.visit, session: session, tools: tools, toolSession: toolSession,
                aiConversationID: $aiConversationID, openingIsActive: { exitPhase == .reading && !session.isLeaving },
                closeTask: { if let visit = snapshot.visit { sendTool(.closeVisit(visit.id), from: context) } },
                navigate: { start, end, placement, history in
                    navigate(start, end: end, placement: placement, historyID: history, from: context)
                },
                edit: editFromLibrary, editorClosed: readerEditorClosed)
        }
        .onAppear { if let token { sendTool(.nativeConfirmed(token)) } }
        .interactiveDismissDisabled(snapshot.compact != .automatic && snapshot.compact != .listening && snapshot.taskID == nil && session.browseOrigin != nil)
        .themeScope(theme).preferredColorScheme(theme.scheme)
        .readerListeningToolPresentation()
        .environment(\.readerListeningOpening, token?.opening)
        .background(ReaderModalChildProbe(host: nativeHost))
        .overlay {
            if session.navigating && !session.isLeaving { LoadingActivity(size: 24, waitingLabel: "正在定位").allowsHitTesting(false) }
        }
    }

    private func presentationDismissed(_ token: ReaderHostToken?) {
        guard let token, nativeHost.token?.id == token.id else { return }
        sendTool(.nativeDismissed(token))
        if navigationPresentation.presentationDismissed(), exitPhase != .reading { finishReturning(); return }
        guard exitPhase == .reading else { finishReturning(); return }
        synchronizeNativePresentation(animatePage: true)
    }

    private func completeReturning() {
        guard exitPhase == .reading else { return }
        navigationPresentation.begin(hasPresentation: sheetPresented)
        exitPhase = .saving
        reviewExitIsNormal = session.error == nil && session.book != nil
        let saved = session.leave()
        library.systemReading.unregister(session)
        Task {
            await saved.value
            exitPhase = .ready
            finishReturning()
        }
    }

    private func finishReturning() {
        guard exitPhase == .ready, !sheetPresented else { return }
        aiConversationID = nil
        exitPhase = .returned
        session.clearTransientState()
        onExit(session.error, reviewExitIsNormal && StatisticsWriter.shared.error == nil ? session.activity.effectiveReadingMilliseconds : 0)
    }

    private var undoCapsuleVisible: Bool {
        guard !session.isLeaving, !navigationPresentation.isSuspended, scenePhase == .active, session.editor == nil else { return false }
        return taskID == nil && sheetPresented && !rendered.expanded && rendered.compact != .settings && !nativeHost.dismissing
    }

    func openBookDetails(from context: ReaderActionContext? = nil) {
        session.activity.update(visibility: .init(body: false), preview: session.browseOrigin != nil)
        sendTool(.open(.details(bookDetailsTarget)), from: context)
    }

    func openFullSettings(from context: ReaderActionContext) {
        if let window = session.window {
            var marks = session.annotations.map { ReadingPreviewSource.Mark(start: $0.startUtf8, end: $0.endUtf8) }
            if let focus = session.focusRange { marks.append(.init(start: focus.startUtf8, end: focus.endUtf8, search: true)) }
            settingsPreview = ReadingPreviewSource(window: window, anchor: session.anchor, title: session.book?.title ?? "", marks: marks)
        }
        sendTool(.open(.settings(.main)), from: context)
    }

    private func selectText(start: UInt64, end: UInt64, action: ReaderSelectionAction) {
        if action == .removeAnnotations { sendTool(.selectionChanged) }
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
            sendTool(.openSearch)
            tools.startSearch()
        }
    }

    private func compactHeader(book: BookInfo) -> some View {
        ReaderCompactHeader(session: session, battery: battery, book: book, readerWidth: readerWidth,
                            compactHeaderHeight: compactHeaderHeight, showControls: { sendTool(.showChrome) })
    }
    private var readerOwnsChrome: Bool {
        // The temporary bar belongs to C's interactive pop. Otherwise the
        // current reader owns its preference even while a tool is dismissing.
        navigationPresentation.revealsNavigation
            || (sourceSelected && sourceCurrent && render.sourcePage == nil && !session.isLeaving)
    }
    private var readerNavigationVisible: Bool {
        !session.isLeaving && (navigationPresentation.revealsNavigation
            || (!navigationPresentation.isSuspended && (render.controls || session.window == nil)))
    }

    private var readingSettings: Binding<ReaderSettings> {
        Binding(get: { session.settings ?? defaultReaderSettings() }, set: session.updateSettings)
    }

    private func bottomDock(_ snapshot: ReaderRenderSnapshot) -> some View {
        let context = snapshot.context
        return VStack(spacing: LayoutTokens.compact) {
            if snapshot.controls, !session.isLeaving { continuationControl }
            if Onboarding.shared.enabled, Onboarding.shared.revealedControls, !Onboarding.shared.selectedText, snapshot.controls {
                TipView(Onboarding.shared.selection).tipViewStyle(ThemedTipStyle(titleOverride: ai.availability.isAvailable ? nil : Text("长按文字可以标注、写批注或拷贝"))).accessibilityIdentifier("readerSelectionTip")
            }
            switch snapshot.compact {
            case .listening:
                if let listening {
                    if listening.active {
                        ReaderListeningCompact(session: listening, expand: { sendTool(.expand, from: context) },
                            resume: { sendTool(.startListening, from: context) },
                            pause: { sendTool(.pauseListening, from: context) }, stop: { sendTool(.stopListening, from: context) }) {
                                listeningPositionActions(snapshot)
                            }
                    } else { listeningContent(listening, snapshot: snapshot, expanded: false) }
                }
            case .automatic:
                if let automatic { automaticContent(automatic, snapshot: snapshot, expanded: false) }
            case .settings:
                ReaderQuickSettings(settings: readingSettings) { openFullSettings(from: context) }
            case .more:
                moreContent(snapshot)
            case .search:
                searchContent(snapshot, details: false)
            case .browse:
                browsePanel(snapshot)
            case .progress:
                ReaderProgressControls(session: session) { offset in navigate(offset, from: context) }
                if session.history.entries.count > 1 {
                    Button("跳转历史", systemImage: "clock") { sendTool(.open(.history), from: context) }
                        .accessibilityIdentifier("showReadingHistory")
                }
            case .none:
                EmptyView()
            }
            if snapshot.compact != .settings, tools.deletedIDs != nil { undoCapsule }
        }
    }

    @ViewBuilder private func listeningPositionActions(_ snapshot: ReaderRenderSnapshot) -> some View {
        if session.browseOrigin != nil { browsePanel(snapshot) }
        else if listening?.following == .detached {
            Button {
                sendTool(.returnToSpeech, from: snapshot.context)
            } label: {
                Label("回到朗读处", systemImage: "scope").frame(maxWidth: .infinity, minHeight: LayoutTokens.hit)
            }
            .disabled(session.navigating).accessibilityIdentifier("returnToSpeech")
        }
    }

    private func listeningContent(_ player: ListeningSession, snapshot: ReaderRenderSnapshot, expanded: Bool) -> some View {
        let context = snapshot.context
        return ReaderListeningContent(session: player, showsHeader: !expanded, navigatesToVoices: expanded,
            canStart: session.opening.phase == .reading && session.window != nil && !session.isLoading
                && !session.isLeaving && !session.navigating && session.error == nil,
            openVoices: { sendTool(.expand, from: context); sendTool(.showVoices(true)) },
            close: { sendTool(expanded ? .collapse : .hideAccessory, from: context) },
            start: { sendTool(.startListening, from: context) },
            pause: { sendTool(.pauseListening, from: context) }, stop: { sendTool(.stopListening, from: context) },
            updateRate: { sendTool(.rate($0), from: context) }, updateTimer: { sendTool(.timer($0), from: context) })
    }

    private func requestAutomaticStart() {
        sendTool(.startAutomatic)
        if nativeHost.token == nil { startAutomaticAfterDismissal() }
    }
    private func startAutomaticAfterDismissal() {
        guard automatic?.pendingStart != nil else { return }
        session.activity.update(visibility: statisticsVisibility, preview: session.browseOrigin != nil)
        sendTool(.startAutomaticAfterRelease(scenePhase == .active && readerNativeReady))
    }

    func changeEncoding(_ encoding: String?) { sendTool(.encode(encoding)) }

    private func synchronizeNativePresentation(animatePage: Bool = false) {
        let update = {
            let desired = desiredPresentation
            let opening = toolSession.opening
            let page = desired == .details || desired == .settings
            // Release the tool sheet before pushing on the source stack.
            let toolTarget: ReaderPresentationTarget = page || !readerNativeReady ? .none : desired
            if nativeHost.token == nil || (nativeHost.target == toolTarget && !nativeHost.dismissing) { nativeHost.retain(render) }
            nativeHost.update(toolTarget, opening: opening, generation: render.context.revision,
                force: session.isLeaving || exitPhase != .reading || navigationPresentation.isSuspended)
            ReaderSceneDiagnostics.record("presentation.project", opening: opening, fields: [
                "sourceTab": String(describing: library.selectedTab), "sourceCurrent": sourceCurrent,
                "sourceRouteCount": library.path.count, "sourcePage": String(describing: render.sourcePage),
                "navigationSettled": session.opening.navigationSettled, "location": String(describing: render.compact),
                "desired": String(describing: desired), "toolRequested": String(describing: nativeHost.showing),
                "toolPhase": nativeHost.phase.rawValue, "token": nativeHost.token?.id.uuidString ?? "none"])
        }
        if animatePage, desiredPresentation == .settings || desiredPresentation == .details {
            withAnimation(reduceMotion ? nil : .default, update)
        } else { update() }
    }
    private func readerEditorClosed() { synchronizeNativePresentation() }

    func navigate(_ start: UInt64, end: UInt64? = nil, placement: ReadingTargetPlacement = .start,
                  obstruction: CGFloat = 0, historyID: String? = nil, from context: ReaderActionContext) {
        let target = ReaderReadingTarget(start: start, end: end, placement: placement,
                                         bottomObstruction: obstruction, historyID: historyID)
        sendTool(.navigate(.userJump(target)), from: context)
    }

    private func editFromLibrary(_ mark: ReaderMark) {
        guard !session.isLeaving else { return }
        session.openAnnotation(mark.id)
    }


}
