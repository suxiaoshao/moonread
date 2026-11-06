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
    @ObservationIgnored private var listeningOwner: ListeningSession?
    var listening: ListeningSession {
        if let listeningOwner { return listeningOwner }
        let value = makeListeningSession(); listeningOwner = value; return value
    }
    var listeningOwnsPosition: Bool { listeningOwner?.ownsPosition == true }
    func pauseListening() { listeningOwner?.pause() }
    func stopListening(releasingPosition: Bool = false) {
        listeningOwner?.end()
        if releasingPosition { listeningOwner?.userNavigated() }
    }
    let autoReading: ReaderAutoReading
    let activity: ReadingActivityRecorder
    var browseViewport: ReadingViewport?
    var browseOrigin: UInt64?
    var history = emptyReadingHistory()
    var focusRange: TextRange?
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
    var navigationGeneration = 0
    var navigating = false
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
         readContinuation: (@Sendable (String, UInt64?) async throws -> ReadingResumeContext)? = nil) {
        self.service = service; self.activity = activity ?? ReadingActivityRecorder()
        self.settingsStore = settingsStore ?? (service === AppDataService.shared ? .shared : ReaderSettingsStore(service: service))
        self.restartReading = restartReading ?? { try await service.restartImport($0, encoding: $1) }
        self.readContinuation = readContinuation ?? { try await service.readingResumeContext($0, currentOffset: $1) }
        autoReading = ReaderAutoReading(viewport: viewportAccess)
        autoReading.readable = { [weak activity = self.activity, weak viewport = viewportAccess] in activity?.bodyReadable(through: viewport) == true }
        autoReading.motionChanged = { [weak activity = self.activity] in activity?.sample() }

    }

    deinit {
        // Closing a scene can destroy the owner without a navigation-pop callback.
        if let listeningOwner { Task { @MainActor in listeningOwner.end() } }
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

    func beganReadingInteraction() { listeningOwner?.userNavigated(); hasLocalReadingInteraction = true }

    func flush() async {
        saveTask?.cancel()
        let currentAnchor = autoReading.phase == .idle ? anchor : (viewportAccess.capture()?.offset ?? anchor)
        // Capture before any suspension. Exit clears preview state, and settings
        // writes may finish after the reader's UI has started disappearing.
        let progress = leavingProgress ?? readingID.flatMap { id in
            window == nil || !hasEnteredBody || !hasLocalReadingInteraction ? nil : (bookID: id, offset: browseOrigin ?? currentAnchor)
        }
        await settingsStore.flush()
        guard let progress else { return }
        do { try await service.savePosition(bookID: progress.bookID, offset: progress.offset) }
        catch { reportAutomaticReadingError(error) }
    }

    @discardableResult
    func leave() -> Task<Void, Never> {
        if let leaveTask { return leaveTask }
        stopListening()
        restartTask?.cancel()
        activityStartTask?.cancel(); activityStartTask = nil
        if autoReading.phase != .idle, let visible = viewportAccess.capture()?.offset {
            moved(to: visible, settled: true, userInitiated: false)
        }
        autoReading.end()
        activity.stop()
        leavingProgress = readingID.flatMap { id in
            window == nil || !hasEnteredBody || !hasLocalReadingInteraction ? nil : (bookID: id, offset: browseOrigin ?? anchor)
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
        navigationTask?.cancel()
        navigationGeneration += 1
        pendingChapterAnchor = nil
        navigating = false
        error = nil
        let task = Task { await flush(); await StatisticsWriter.shared.drain(); await service.scheduleSystemReadingCatalog(immediate: true) }
        leaveTask = task
        return task
    }

    func clearTransientState() {
        // Keep the presented panel's content stable until its dismissal ends.
        // The exit flag hides reader overlays immediately and blocks late work.
        browseOrigin = nil; browseViewport = nil; focusRange = nil
        selectionStart = nil; editor = nil; navigation = nil
        chapterDraft = nil
        history = emptyReadingHistory()
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
