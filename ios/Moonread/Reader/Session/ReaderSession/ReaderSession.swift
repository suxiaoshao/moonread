import SwiftUI
import UIKit

@MainActor @Observable
final class ReaderSession {
    let opening = ReaderOpeningState()
    private var systemDonationOpening: UUID?
    var monitorToken = UUID()
    var snapshot: ReadingSnapshot?
    var book: BookInfo? { snapshot?.book }
    var window: ReadingWindow?
    let settingsStore: ReaderSettingsStore
    var settings: ReaderSettings? { settingsStore.value }
    var anchor: UInt64 = 0
    var displayAnchor: UInt64?
    var showingCover = true
    private var openedTask: Task<Void, Never>?
    private var openedAttempt: UUID?
    var hasEnteredBody = false
    var hasLocalReadingInteraction = false
    var continuation: ReadingContinuationCandidate?
    var continuationCollapsed = false
    var continuationSuppressed = false
    var seenContinuationTokens = Set<String>()
    var continuationTimer: Task<Void, Never>?
    var continuationRefresh = UUID()
    var firstContinuationReady = false
    var decodingPolicy: String?
    var encodingLabel: String? {
        guard let decodingPolicy, let encoding = book?.encoding else { return nil }
        return decodingPolicy == "auto" ? String(localized: "自动 · \(encoding.uppercased())") : encoding.uppercased()
    }
    var chapter: ChapterInfo?
    private var sessionError: String?
    var error: String? {
        get { sessionError ?? settingsStore.error }
        set { sessionError = newValue; if newValue == nil { settingsStore.error = nil } }
    }
    private var hasPresentedCompatibilityNotice = false
    var isLoading = true
    var nearEdge = false
    var navigationRevision = 0
    var navigation: ReadingNavigation?
    let viewportAccess = ReadingViewportAccess()
    @ObservationIgnored private lazy var toolOwner = ReaderToolSession(reader: self)
    var toolsSession: ReaderToolSession { toolOwner }
    private(set) var execution = ReaderExecution.manual
    @ObservationIgnored private let listeningFactory: ((ReaderSession) -> ListeningSession)?
    var activeListening: ListeningSession? {
        if case .listening(let player) = execution { return player }
        return nil
    }
    var autoReading: ReaderAutoReading? {
        if case .automatic(let reader) = execution { return reader }
        return nil
    }
    var listeningWindowTask: Task<Void, Never>?
    var listeningUIActive = true
    var listeningOwnsPosition: Bool { activeListening?.ownsPosition == true }
    func pauseListening() { activeListening?.pause() }
    func stopListening(releasingPosition: Bool = false, returnToText: Bool = true) {
        listeningWindowTask?.cancel()
        activeListening?.end(returnToText: returnToText && !releasingPosition)
        if releasingPosition { activeListening?.userNavigated() }
    }
    func selectListening() -> ListeningSession {
        if let activeListening { return activeListening }
        if let autoReading, autoReading.phase != .idle, let offset = viewportAccess.capture()?.offset {
            moved(to: offset, settled: true, userInitiated: false)
        }
        autoReading?.end()
        let player = listeningFactory?(self) ?? makeListeningSession()
        execution = .listening(player)
        return player
    }
    func selectAutomaticReading() -> ReaderAutoReading {
        if let autoReading { return autoReading }
        stopListening()
        let reader = ReaderAutoReading(viewport: viewportAccess)
        reader.readable = { [weak activity, weak viewport = viewportAccess] in activity?.bodyReadable(through: viewport) == true }
        reader.motionChanged = { [weak activity] in activity?.sample() }
        execution = .automatic(reader)
        return reader
    }
    func resetExecution() {
        stopListening(releasingPosition: true, returnToText: false)
        autoReading?.end()
        execution = .manual
    }

    let activity: ReadingActivityRecorder
    var browseState: ReaderBrowseState = .reading(emptyReadingHistory())
    var browseOrigin: UInt64? { browseState.preview?.origin }
    var browseViewport: ReadingViewport? { browseState.preview?.viewport }
    var focusRange: TextRange? { browseState.preview?.focus }
    var history: ReadingHistory {
        get { browseState.history }
        set { browseState.history = newValue }
    }

    func clearBrowse(keepingHistory: Bool = false) {
        browseState = .reading(keepingHistory ? history : emptyReadingHistory())
    }
    func clearSearchFocus() {
        guard var preview = browseState.preview else { return }
        preview.focus = nil
        browseState = .preview(preview)
    }
    var annotations: [ReaderMark] = []
    var bookmarkPositions: [UInt64] = []
    var bookmarked = false
    var changingBookmark = false
    var selectionStart: UInt64?
    var noteEditorModel: NoteEditorModel?
    var editor: AnnotationEdit? {
        didSet { noteEditorModel = editor.map { NoteEditorModel(edit: $0, service: service) } }
    }
    var chapterDraft: ChapterEditDraft?
    var marksRevision = 0
    var annotationTask: Task<Void, Never>?
    var selectionTask: Task<Void, Never>?
    var navigationTask: Task<Void, Never>?
    private(set) var navigationGeneration = 0
    private(set) var navigationWork: ReaderNavigationRequest?
    var navigating: Bool { navigationWork?.intent.blocksPositionInput == true }
    func beginNavigation(_ intent: ReaderNavigationIntent) -> ReaderNavigationRequest {
        navigationTask?.cancel()
        navigationGeneration += 1
        let request = ReaderNavigationRequest(generation: navigationGeneration, opening: opening.request?.id, intent: intent)
        navigationWork = request
        return request
    }
    func currentNavigation(_ request: ReaderNavigationRequest) -> Bool {
        !isLeaving && !Task.isCancelled && request.generation == navigationGeneration && request.opening == opening.request?.id
    }
    func finishNavigation(_ request: ReaderNavigationRequest) {
        if currentNavigation(request) { navigationWork = nil }
    }
    func cancelNavigation() {
        navigationTask?.cancel()
        navigationGeneration += 1
        navigationWork = nil
    }
    var readingLease: ReadingLease?
    var readingID: String? { readingLease?.id }
    let service: AppDataService
    private var activityStartTask: Task<Void, Never>?
    var monitorTask: Task<Void, Never>?
    var saveTask: Task<Void, Never>?
    var windowTask: Task<Void, Never>?
    var chapterTask: Task<Void, Never>?
    var pendingChapterAnchor: UInt64?
    var isLeaving = false
    private var leavingProgress: (bookID: String, offset: UInt64)?
    private var leaveTask: Task<Void, Never>?
    var restartTask: Task<Void, Never>?
    var restartingEncoding: Bool { restartTask != nil }
    let restartReading: @Sendable (String, String?) async throws -> ReadingLease
    let readContinuation: @Sendable (String, UInt64?) async throws -> ReadingResumeContext

    init(service: AppDataService = .shared, activity: ReadingActivityRecorder? = nil,
         settingsStore: ReaderSettingsStore? = nil,
         restartReading: (@Sendable (String, String?) async throws -> ReadingLease)? = nil,
         readContinuation: (@Sendable (String, UInt64?) async throws -> ReadingResumeContext)? = nil,
         makeListening: ((ReaderSession) -> ListeningSession)? = nil) {
        self.listeningFactory = makeListening
        self.service = service; self.activity = activity ?? ReadingActivityRecorder()
        self.settingsStore = settingsStore ?? (service === AppDataService.shared ? .shared : ReaderSettingsStore(service: service))
        self.restartReading = restartReading ?? { try await service.restartImport($0, encoding: $1) }
        self.readContinuation = readContinuation ?? { try await service.readingResumeContext($0, currentOffset: $1) }
    }

    isolated deinit {
        if case .listening(let player) = execution { Task { @MainActor in player.end() } }
    }

    var preparing: Bool {
        guard let snapshot else { return isLoading }
        return [.preparing, .importing, .finalizing].contains(snapshot.phase)
    }
    var incomplete: Bool { snapshot.map { $0.phase != .complete } ?? true }
    var atPreparedEdge: Bool { nearEdge && incomplete && window?.isPreparedTail == true }

    func open(_ route: ReaderRoute, request: OpeningRequest? = nil) async {
        guard !isLeaving else { return }
        if opening.request == nil { opening.begin(request ?? OpeningRequest(target: route)) }
        let attempt = opening.request?.id
        if let attempt { toolsSession.beginOpening(attempt) }
        ReaderOpenDiagnostics.mark(attempt, "sessionOpen")
        if readingID == nil {
            isLoading = true
            do {
                ReaderOpenDiagnostics.mark(attempt, "settingsRequested")
                try settingsStore.load()
                ReaderOpenDiagnostics.mark(attempt, "settingsLoaded")
                guard !isLeaving, !Task.isCancelled, opening.request?.id == attempt else { return }
                ReaderOpenDiagnostics.mark(attempt, "leaseRequested")
                let diagnostic = ReaderOpenDiagnostics.trace(attempt)
                diagnostic?.mark("lease.queued")
                let lease: ReadingLease
                switch route {
                case let .book(id): lease = try await service.openReading(id, diagnostic: diagnostic)
                case let .source(file): lease = try await service.openSourceFile(file, diagnostic: diagnostic)
                }
                diagnostic?.mark("lease.mainResumed")
                guard !isLeaving, !Task.isCancelled, opening.request?.id == attempt else { return }
                readingLease = lease
                decodingPolicy = await service.readingDecoding(lease.id)
            } catch { if !isLeaving, !Task.isCancelled, opening.request?.id == attempt { self.error = ReaderMessages.error(error); isLoading = false; updateOpening() }; return }
        }
        guard !isLeaving else { return }
        if let readingLease {
            if let attempt = opening.request?.id { ReaderOpenDiagnostics.bind(readingLease.id, to: attempt) }
            ReaderOpenDiagnostics.mark(opening.request?.id, "leaseCreated")
            if ReaderOpenDiagnostics.serialStatistics, let attempt {
                activity.prepareStart(attempt)
                ReaderOpenDiagnostics.mark(attempt, "activityStart")
                await activity.start(lease: readingLease, viewport: viewportAccess, attempt: attempt)
                ReaderOpenDiagnostics.mark(attempt, "activityStarted")
            }
        }
        guard !isLeaving, !Task.isCancelled, opening.request?.id == attempt else { return }
        startMonitoring()
        if !ReaderOpenDiagnostics.serialStatistics { startActivity(attempt: attempt) }
    }

    func startActivity(attempt: UUID?) {
        guard let attempt, let lease = readingLease, !isLeaving else { return }
        activityStartTask?.cancel()
        activity.prepareStart(attempt)
        activityStartTask = Task { [weak self] in
            guard let self, current(lease.id, attempt: attempt) else { return }
            ReaderOpenDiagnostics.mark(attempt, "activityStart")
            await activity.start(lease: lease, viewport: viewportAccess, attempt: attempt)
            guard current(lease.id, attempt: attempt) else { return }
            ReaderOpenDiagnostics.mark(attempt, "activityStarted")
        }
    }

    func updateOpening() {
        opening.update(ready: settings != nil && window.map { $0.status != .awaiting && $0.projectionAnchor != nil } == true,
                       terminal: error != nil || snapshot.map { [.paused, .failed].contains($0.phase) } == true)
    }
    func retry(_ route: ReaderRoute) async {
        opening.begin(OpeningRequest(target: route, expectedContentSHA: opening.request?.expectedContentSHA), navigationSettled: true)
        error = nil; await open(route)
    }
    func current(_ id: String, attempt: UUID?, monitor: UUID? = nil) -> Bool {
        !isLeaving && !Task.isCancelled && readingID == id && opening.request?.id == attempt
            && (monitor == nil || monitor == monitorToken)
    }
    func systemReadingBecameReadable() {
        guard !isLeaving, browseOrigin == nil, let openingID = opening.request?.id,
              systemDonationOpening != openingID, let id = readingID,
              let sha = book?.contentSha256, (try? parseSha256(value: sha)) != nil else { return }
        systemDonationOpening = openingID
        Task { await service.systemReadingBegan(id) }
    }

    func bodyDidDisplay() {
        guard !isLeaving, let attempt = opening.request?.id, openedAttempt != attempt,
              let id = readingID, book != nil else { return }
        openedAttempt = attempt
        let at = Int64(Date().timeIntervalSince1970 * 1000)
        openedTask = Task { [service] in try? await service.recordBookOpened(id, at: at) }
    }

    func beganReadingInteraction() {
        toolsSession.send(.manualInteraction)
        if browseOrigin == nil { hasLocalReadingInteraction = true }
    }

    func flush() async {
        saveTask?.cancel()
        let audioOwnedPosition = listeningOwnsPosition
        let currentAnchor = listeningPosition ?? ((autoReading?.phase ?? .idle) == .idle ? anchor : (viewportAccess.capture()?.offset ?? anchor))
        // Capture before any suspension. Exit clears preview state, and settings
        // writes may finish after the reader's UI has started disappearing.
        let progress = leavingProgress ?? readingID.flatMap { id in
            window == nil || !hasEnteredBody || !hasLocalReadingInteraction ? nil : (bookID: id, offset: listeningPosition ?? browseOrigin ?? currentAnchor)
        }
        await settingsStore.flush()
        await saveTask?.value
        // A paused audio flush may outlive an explicit Continue Reading handoff.
        // Its captured audio anchor must not overwrite the newly adopted position.
        guard !audioOwnedPosition || listeningOwnsPosition else { return }
        guard let progress else { return }
        do { try await service.savePosition(bookID: progress.bookID, offset: progress.offset) }
        catch { reportAutomaticReadingError(error) }
    }

    @discardableResult
    func leave() -> Task<Void, Never> {
        if let leaveTask { return leaveTask }
        toolsSession.invalidateOpening()
        stopListening(returnToText: false)
        restartTask?.cancel()
        activityStartTask?.cancel(); activityStartTask = nil
        if let autoReading, autoReading.phase != .idle, let visible = viewportAccess.capture()?.offset {
            moved(to: visible, settled: true, userInitiated: false)
        }
        autoReading?.end()
        activity.stop()
        leavingProgress = readingID.flatMap { id in
            window == nil || !hasEnteredBody || !hasLocalReadingInteraction ? nil : (bookID: id, offset: listeningPosition ?? browseOrigin ?? anchor)
        }
        clearContinuation()
        isLeaving = true
        opening.leave(); monitorToken = UUID()
        saveTask?.cancel()
        monitorTask?.cancel()
        windowTask?.cancel()
        chapterTask?.cancel()
        annotationTask?.cancel()
        selectionTask?.cancel(); selectionTask = nil
        cancelNavigation()
        pendingChapterAnchor = nil
        error = nil
        let task = Task { await openedTask?.value; await flush(); await StatisticsWriter.shared.drain(); await service.scheduleSystemReadingCatalog(immediate: true) }
        leaveTask = task
        return task
    }

    func clearTransientState() {
        // Keep the presented panel's content stable until its dismissal ends.
        // The exit flag hides reader overlays immediately and blocks late work.
        clearBrowse()
        selectionStart = nil; editor = nil; navigation = nil
        chapterDraft = nil
    }

    /// Automatic refreshes/saves must not repeatedly interrupt a read-only session.
    /// Explicit editing actions keep their normal operation-specific error paths.
    func presentCompatibilityNotice(_ notice: String) {
        guard !isLeaving, !hasPresentedCompatibilityNotice, error == nil else { return }
        hasPresentedCompatibilityNotice = true
        error = notice
    }

    func reportAutomaticReadingError(_ error: Error) {
        if error is UserSyncCompatibilityError { presentCompatibilityNotice(ReaderMessages.error(error)) }
        else { self.error = ReaderMessages.error(error) }
    }

    @discardableResult
    func synchronizeHistory() {
        guard !showingCover else { return }
        history = updateHistoryPosition(history: history, offsetUtf8: anchor, title: chapter?.title ?? book?.title ?? "")
    }

    func refreshOutline() async {
        guard !isLeaving, let id = readingID else { return }
        await refreshWindow(id, at: anchor)
        refreshChapter(at: anchor, bookID: id)
    }

    func foreground() {
        guard !isLeaving, readingID != nil else { return }
        startMonitoring()
    }
}
