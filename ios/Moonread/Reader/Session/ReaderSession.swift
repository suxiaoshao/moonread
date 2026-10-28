import SwiftUI
import UIKit

@MainActor @Observable
final class ReaderSession {
    let opening = ReaderOpeningState()
    private var systemDonationOpening: UUID?
    private var monitorToken = UUID()
    var snapshot: ReadingSnapshot?
    var book: BookInfo? { snapshot?.book }
    var window: ReadingWindow?
    private let settingsStore: ReaderSettingsStore
    var settings: ReaderSettings? { settingsStore.value }
    var anchor: UInt64 = 0
    private(set) var displayAnchor: UInt64?
    var showingCover = true
    private var hasEnteredBody = false
    private var hasLocalReadingInteraction = false
    private(set) var continuation: ReadingContinuationCandidate?
    private(set) var continuationCollapsed = false
    private var continuationSuppressed = false
    private var seenContinuationTokens = Set<String>()
    private var continuationTimer: Task<Void, Never>?
    private var continuationRefresh = UUID()
    private var firstContinuationReady = false
    private(set) var decodingPolicy: String?
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
    let activity: ReadingActivityRecorder
    private var browseViewport: ReadingViewport?
    var browseOrigin: UInt64?
    var history = emptyReadingHistory()
    var focusRange: TextRange?
    var annotations: [ReaderMark] = []
    var bookmarkPositions: [UInt64] = []
    var bookmarked = false
    private(set) var changingBookmark = false
    var selectionStart: UInt64?
    var marksRevision = 0
    private var annotationTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var navigationTask: Task<Void, Never>?
    private var navigationGeneration = 0
    private(set) var navigating = false
    private var readingLease: ReadingLease?
    var readingID: String? { readingLease?.id }
    private let service: AppDataService
    private var activityStartTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var windowTask: Task<Void, Never>?
    private var chapterTask: Task<Void, Never>?
    private var pendingChapterAnchor: UInt64?
    private(set) var isLeaving = false
    private var leavingProgress: (bookID: String, offset: UInt64)?
    private var leaveTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    var restartingEncoding: Bool { restartTask != nil }
    private let restartReading: @Sendable (String, String?) async throws -> ReadingLease
    private let readContinuation: @Sendable (String, UInt64?) async throws -> ReadingResumeContext

    init(service: AppDataService = .shared, activity: ReadingActivityRecorder? = nil,
         settingsStore: ReaderSettingsStore? = nil,
         restartReading: (@Sendable (String, String?) async throws -> ReadingLease)? = nil,
         readContinuation: (@Sendable (String, UInt64?) async throws -> ReadingResumeContext)? = nil) {
        self.service = service; self.activity = activity ?? ReadingActivityRecorder()
        self.settingsStore = settingsStore ?? (service === AppDataService.shared ? .shared : ReaderSettingsStore(service: service))
        self.restartReading = restartReading ?? { try await service.restartImport($0, encoding: $1) }
        self.readContinuation = readContinuation ?? { try await service.readingResumeContext($0, currentOffset: $1) }
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

    private func startActivity(attempt: UUID?) {
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

    private func updateOpening() {
        opening.update(ready: settings != nil && window.map { $0.status != .awaiting && $0.projectionAnchor != nil } == true,
                       terminal: error != nil || snapshot.map { [.paused, .failed].contains($0.phase) } == true)
    }
    func retry(_ route: ReaderRoute) async {
        opening.begin(OpeningRequest(target: route, expectedContentSHA: opening.request?.expectedContentSHA), navigationSettled: true)
        error = nil; await open(route)
    }
    private func current(_ id: String, attempt: UUID?, monitor: UUID? = nil) -> Bool {
        !isLeaving && !Task.isCancelled && readingID == id && opening.request?.id == attempt
            && (monitor == nil || monitor == monitorToken)
    }
    private func startMonitoring() {
        guard !isLeaving else { return }
        monitorTask?.cancel(); monitorToken = UUID()
        let token = monitorToken, attempt = opening.request?.id
        monitorTask = Task { [weak self] in
            guard let self else { return }
            do {
                repeat {
                    guard let id = readingID, current(id, attempt: attempt, monitor: token) else { return }
                    ReaderOpenDiagnostics.mark(attempt, "revision.queued")
                    let revision = await service.readingChangeRevision(id)
                    ReaderOpenDiagnostics.mark(attempt, "revision.mainResumed")
                    ReaderOpenDiagnostics.mark(attempt, "snapshotRequested")
                    let diagnostic = ReaderOpenDiagnostics.trace(attempt)
                    diagnostic?.mark("openingFrame.queued")
                    var resume: ReadingResumeContext?
                    if window == nil {
                        do { resume = try await readContinuation(id, nil) }
                        catch is CancellationError { throw CancellationError() }
                        catch { reportAutomaticReadingError(error) }
                    }
                    let update = try await service.openingFrame(id, offset: window == nil ? resume?.localOffset : anchor, attempt: attempt, diagnostic: diagnostic)
                    diagnostic?.mark("openingFrame.mainResumed")
                    ReaderOpenDiagnostics.mark(attempt, "mainActorOpeningResumed")
                    let value = update.0
                    guard current(id, attempt: attempt, monitor: token) else { return }
                    ReaderOpenDiagnostics.mark(attempt, "snapshotCompleted")
                    snapshot = value
                    isLoading = !value.canRead && preparing
                    let expected = opening.request?.expectedContentSHA
                    if let expected, value.phase == .complete, value.book.contentSha256 != expected {
                        throw SystemReadingRouteError.contentChanged
                    }
                    // A system identity must be verified before any prefix is displayed.
                    if value.canRead && (expected == nil || value.phase == .complete) {
                        let firstDisplay = window?.projectionAnchor == nil
                        if firstDisplay {
                            ReaderOpenDiagnostics.mark(attempt, "canRead")
                            anchor = update.1?.projectionAnchor ?? value.book.positionUtf8
                            hasEnteredBody = value.hasStarted
                            showingCover = !value.hasStarted
                        }
                        if let frame = update.1 { publishFrame(frame, id: id, attempt: attempt, monitor: token) }
                        if let candidate = resume?.candidate { presentContinuation(candidate) }
                        guard current(id, attempt: attempt, monitor: token) else { return }
                        refreshChapter(at: anchor, bookID: id)
                    }
                    updateOpening()
                    if value.phase == .complete {
                        if !firstContinuationReady { await refreshSyncedContinuation() }
                        break
                    }
                    let timeout = Duration.milliseconds(preparing ? 150 : 1000)
                    if ReaderOpenDiagnostics.wakes { try await service.waitForChange(id, after: revision, timeout: timeout) }
                    else { try await Task.sleep(for: timeout) }
                } while !Task.isCancelled
            } catch is CancellationError { }
            catch {
                if !isLeaving, !Task.isCancelled, opening.request?.id == attempt, monitorToken == token {
                    self.error = ReaderMessages.error(error); isLoading = false; updateOpening()
                }
            }
        }
    }

    private func refreshWindow(_ id: String, at offset: UInt64, monitor: UUID? = nil) async {
        let attempt = opening.request?.id
        do {
            ReaderOpenDiagnostics.mark(attempt, "frameRequested")
            let frame = try await service.frame(id, offset: offset)
            guard current(id, attempt: attempt, monitor: monitor) else { return }
            publishFrame(frame, id: id, attempt: attempt, monitor: monitor)
        } catch {
            if current(id, attempt: attempt, monitor: monitor) { self.error = ReaderMessages.error(error); updateOpening() }
        }
    }

    private func publishFrame(_ frame: ReadingFrame, id: String, attempt: UUID?, monitor: UUID?) {
        guard current(id, attempt: attempt, monitor: monitor) else { return }
        let value = ReadingWindow(frame: frame)
        if window?.projectionAnchor == nil { displayAnchor = value.projectionAnchor }
        if value.projectionAnchor == nil, window?.projectionAnchor != nil { return }
        if window != value {
            window = value; ReaderOpenDiagnostics.mark(attempt, "windowPublished")
            updateOpening(); refreshAnnotations()
        }
    }

    func systemReadingBecameReadable() {
        guard !isLeaving, browseOrigin == nil, let openingID = opening.request?.id,
              systemDonationOpening != openingID, let id = readingID,
              let sha = book?.contentSha256, (try? parseSha256(value: sha)) != nil else { return }
        systemDonationOpening = openingID
        Task { await service.systemReadingBegan(id) }
    }

    func beganReadingInteraction() { hasLocalReadingInteraction = true }

    func moved(to offset: UInt64, settled: Bool, userInitiated: Bool = true) {
        guard !isLeaving, let book, let id = readingID else { return }
        guard !navigating else { return }
        showingCover = false
        if browseOrigin == nil { hasEnteredBody = true }
        displayAnchor = nil
        anchor = min(offset, book.byteCount)
        if userInitiated { hasLocalReadingInteraction = true }
        if let continuation, anchor >= continuation.location.offsetUtf8 { clearContinuation() }
        refreshChapter(at: anchor, bookID: id)
        saveTask?.cancel()
        guard hasLocalReadingInteraction else { return }
        let position = anchor
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
                guard self?.isLeaving == false, self?.browseOrigin == nil else { return }
                try await self?.service.savePosition(bookID: id, offset: position)
            } catch is CancellationError { } catch { self?.reportAutomaticReadingError(error) }
        }
        // Window requests are independent of reported/saved reading positions.
    }

    @discardableResult func requestWindow(_ direction: ReadingDirection, retaining: SourceSpan? = nil) -> Bool {
        guard !isLeaving, !navigating, windowTask == nil, let window, let id = readingID else { return false }
        let cursor = direction == .forward ? window.nextCursor : window.previousCursor
        guard let cursor else { return false }
        let keep = retaining ?? viewportAccess.controller?.protectedSourceRange() ?? SourceSpan(startUtf8:displayAnchor ?? anchor,endUtf8:(displayAnchor ?? anchor)+1)
        let attempt = opening.request?.id
        windowTask = Task { [weak self] in
            guard let self else { return }
            defer { windowTask = nil; viewportAccess.controller?.reevaluateWindowRequests() }
            do {
                let frame = try await service.extensionFrame(id,cursor:cursor,direction:direction,retaining:keep)
                guard current(id, attempt: attempt) else { return }
                acceptExtension(frame,direction:direction)
            } catch { if current(id, attempt: attempt) { self.error = ReaderMessages.error(error) } }
        }
        return true
    }

    /// Availability never replaces a readable payload or turns prefetch into navigation.
    func acceptExtension(_ frame: ReadingFrame, direction: ReadingDirection) {
        guard !isLeaving, let previous = window else { return }
        guard frame.status != .deferred else { return }
        guard frame.status == .ready else {
            var retained = previous
            if direction == .forward {
                retained.nextCursor = nil
                retained.isPreparedTail = frame.status == .awaiting
                retained.isEndOfBook = frame.status == .end && frame.snapshot.phase == .complete
            } else { retained.previousCursor = nil }
            window = retained
            return
        }
        let visible = viewportAccess.capture()?.offset ?? displayAnchor ?? anchor
        let protected = viewportAccess.controller?.protectedSourceRange()
        guard frame.chunks.contains(where:{visible >= $0.startUtf8 && visible < $0.endUtf8}),
              protected.map({frame.sourceStart <= $0.startUtf8 && frame.sourceEnd >= $0.endUtf8}) ?? true else { return }
        let value = ReadingWindow(frame:frame)
        if value != previous { window = value; refreshAnnotations() }
    }

    private func refreshChapter(at offset: UInt64, bookID: String) {
        pendingChapterAnchor = offset
        guard chapterTask == nil else { return }
        chapterTask = Task { [weak self] in
            guard let self else { return }
            defer { chapterTask = nil }
            while let position = pendingChapterAnchor {
                pendingChapterAnchor = nil
                let value = try? await service.chapter(bookID: bookID, offset: position)
                if !isLeaving, !Task.isCancelled, anchor == position, readingID == bookID { chapter = value }
            }
        }
    }

    func retryPreparation() {
        guard !isLeaving, snapshot?.phase == .failed, let id = readingID else { return }
        error = nil
        Task {
            do { try await service.resumeImport(id); startMonitoring() }
            catch { if !isLeaving { self.error = ReaderMessages.error(error) } }
        }
    }

    func restart(encoding: String? = nil) {
        // Admission is synchronous, before flush/actor hops. No second import can
        // be created until this task ends, including its worker-finish wait.
        guard !isLeaving, restartTask == nil, let id = readingID else { return }
        resetContinuation()
        restartTask = Task {
            defer { restartTask = nil }
            do {
                await flush()
                try Task.checkCancellation()
                guard !isLeaving, readingID == id else { return }
                let next = try await restartReading(id, encoding)
                // A late unclaimed lease is released normally. Its service-owned,
                // file-associated worker remains tracked through finish/reclaim.
                guard !isLeaving, !Task.isCancelled, readingID == id else { return }
                opening.begin(OpeningRequest(target: .book(next.id)), navigationSettled: true)
                let attempt = opening.request?.id
                monitorToken = UUID()
                monitorTask?.cancel(); windowTask?.cancel(); saveTask?.cancel(); chapterTask?.cancel()
                navigationTask?.cancel(); navigationTask = nil; navigationGeneration += 1; navigating = false
                windowTask = nil; chapterTask = nil; pendingChapterAnchor = nil
                browseOrigin = nil; browseViewport = nil; navigation = nil
                history = emptyReadingHistory()
                focusRange = nil; selectionStart = nil; annotations = []; bookmarkPositions = []
                // Transfer ownership and clear old projection before any more await.
                readingLease = next; decodingPolicy = nil
                snapshot = nil; window = nil; chapter = nil; anchor = 0
                showingCover = true; hasEnteredBody = false; hasLocalReadingInteraction = false
                error = nil; isLoading = true; nearEdge = false; navigationRevision += 1
                startMonitoring(); startActivity(attempt: attempt)
                let policy = await service.readingDecoding(next.id)
                guard !isLeaving, !Task.isCancelled, readingID == next.id,
                      opening.request?.id == attempt else { return }
                decodingPolicy = policy
                try await service.waitForImportFinish(next.id)
            } catch is CancellationError { }
            catch { if !isLeaving, !Task.isCancelled { self.error = ReaderMessages.error(error) } }
        }
    }

    func update(mode: ReadingMode? = nil, fontSize: Double? = nil, lineSpacing: Double? = nil) {
        guard var value = settings else { return }
        if let mode { value.mode = mode }; if let fontSize { value.fontSize = fontSize }; if let lineSpacing { value.lineSpacing = lineSpacing }
        updateSettings(value)
    }

    func updateSettings(_ value: ReaderSettings) {
        guard !isLeaving else { return }
        settingsStore.update(value)
    }

    func flush() async {
        saveTask?.cancel()
        // Capture before any suspension. Exit clears preview state, and settings
        // writes may finish after the reader's UI has started disappearing.
        let progress = leavingProgress ?? readingID.flatMap { id in
            window == nil || !hasEnteredBody || !hasLocalReadingInteraction ? nil : (bookID: id, offset: browseOrigin ?? anchor)
        }
        await settingsStore.flush()
        guard let progress else { return }
        do { try await service.savePosition(bookID: progress.bookID, offset: progress.offset) }
        catch { reportAutomaticReadingError(error) }
    }

    @discardableResult
    func leave() -> Task<Void, Never> {
        if let leaveTask { return leaveTask }
        restartTask?.cancel()
        activityStartTask?.cancel(); activityStartTask = nil
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
        selectionStart = nil; navigation = nil
        history = emptyReadingHistory()
    }

    /// Automatic refreshes/saves must not repeatedly interrupt a read-only session.
    /// Explicit editing actions keep their normal operation-specific error paths.
    private func presentCompatibilityNotice(_ notice: String) {
        guard !isLeaving, !hasPresentedCompatibilityNotice, error == nil else { return }
        hasPresentedCompatibilityNotice = true
        error = notice
    }

    private func reportAutomaticReadingError(_ error: Error) {
        if error is UserSyncCompatibilityError { presentCompatibilityNotice(ReaderMessages.error(error)) }
        else { self.error = ReaderMessages.error(error) }
    }

    @discardableResult
    func refreshAnnotations() -> Task<Void, Never>? {
        annotationTask?.cancel()
        guard !isLeaving, let id = readingID, let window else { return nil }
        annotationTask = Task {
            do {
                let compatibilityNotice = try await service.readingCompatibilityNotice(id)
                let values = try await service.annotations(id, start: min(selectionStart ?? window.start, window.start), end: max(selectionStart ?? window.end, window.end))
                let positions = try await service.bookmarkPositions(id, start: window.start, end: window.end)
                guard !isLeaving, !Task.isCancelled, readingID == id else { return }
                annotations = values
                bookmarkPositions = positions
                if let compatibilityNotice { presentCompatibilityNotice(compatibilityNotice) }
            } catch { if !Task.isCancelled { reportAutomaticReadingError(error) } }
        }
        refreshBookmark()
        return annotationTask
    }

    func refreshBookmark() {
        guard !isLeaving, let id = readingID else { return }
        let position = anchor
        Task { if let marked = try? await service.hasBookmark(id, at: position), !isLeaving, readingID == id, anchor == position { bookmarked = marked } }
    }

    /// True means the write succeeded, including removing an existing bookmark.
    func toggleBookmark() async -> Bool {
        guard !isLeaving, !showingCover, let id = readingID, !changingBookmark else { return false }
        changingBookmark = true
        defer { changingBookmark = false }
        let position = anchor
        do {
            let added = try await service.toggleBookmark(id, at: position)
            guard !isLeaving, readingID == id else { return false }
            if anchor == position { bookmarked = added }
            marksRevision += 1
            refreshAnnotations()
            return true
        } catch {
            if !isLeaving, readingID == id { self.error = ReaderMessages.error(error) }
            return false
        }
    }

    func browse(to start: UInt64, end: UInt64? = nil, placement: ReadingTargetPlacement = .context,
                bottomObstruction: CGFloat = 0, restoring: ReadingViewport? = nil, historyID: String? = nil) {
        guard !isLeaving, let id = readingID else { return }
        hasLocalReadingInteraction = true
        activity.breakVisit()
        saveTask?.cancel()
        let origin = browseOrigin ?? anchor
        let leaving = anchor
        let leavingTitle = chapter?.title ?? book?.title ?? ""
        let leavingWasCover = showingCover
        let originalViewport = browseOrigin == nil ? viewportAccess.capture() : browseViewport
        let visibleWindow = placement == .context && restoring == nil
            ? viewportAccess.controller?.visibleWindow(containing: start, end: end, bottomObstruction: bottomObstruction) : nil
        navigationGeneration += 1
        let revision = navigationGeneration
        navigationTask?.cancel()
        navigating = true
        navigationTask = Task {
            defer { if revision == navigationGeneration { navigating = false } }
            do {
                // Persist the original reading point before displaying a preview.
                if hasEnteredBody {
                    do { try await service.savePosition(bookID: id, offset: origin) }
                    catch let error as UserSyncCompatibilityError { reportAutomaticReadingError(error) }
                }
                let frame = try await service.frame(id, offset: start)
                guard !isLeaving, !Task.isCancelled, revision == navigationGeneration else { return }
                let target = min(start, frame.snapshot.book.byteCount)
                let heading = try await service.chapter(bookID: id, offset: target)
                guard !isLeaving, !Task.isCancelled, revision == navigationGeneration else { return }
                if let historyID {
                    history = try selectReadingHistory(history: updateHistoryPosition(history: history, offsetUtf8: leaving, title: leavingTitle), id: historyID)
                } else if restoring == nil && !leavingWasCover && placement != .cover {
                    history = visitReadingPosition(history: history, fromUtf8: leaving, fromTitle: leavingTitle,
                                                   toUtf8: target, toTitle: heading?.title ?? book?.title ?? "")
                }
                browseOrigin = origin
                browseViewport = originalViewport
                snapshot = frame.snapshot
                windowTask?.cancel(); windowTask = nil
                window = visibleWindow ?? ReadingWindow(frame: frame)
                displayAnchor = frame.projectionAnchor
                anchor = target
                showingCover = placement == .cover || restoring?.isCover == true
                focusRange = end.map { TextRange(startUtf8: start, endUtf8: $0, text: "") }
                navigation = ReadingNavigation(placement: placement, bottomObstruction: bottomObstruction, restoring: restoring)
                navigationRevision += 1
                refreshChapter(at: target, bookID: id)
                refreshAnnotations()
            } catch { if !isLeaving { self.error = ReaderMessages.error(error) } }
        }
    }

    func returnFromBrowse() async {
        guard !isLeaving, let original = browseOrigin else { return }
        browse(to: original, placement: .start, restoring: browseViewport)
        await navigationTask?.value
        if !isLeaving, anchor == original { browseOrigin = nil; browseViewport = nil; focusRange = nil; history = emptyReadingHistory() }
    }

    func continueReading() async {
        guard !isLeaving, !navigating, let id = readingID else { return }
        do {
            if !showingCover {
                try await service.savePosition(bookID: id, offset: anchor)
                hasEnteredBody = true
                hasLocalReadingInteraction = true
            } else { hasEnteredBody = false }
            guard !isLeaving else { return }
            browseOrigin = nil; browseViewport = nil; navigation = nil; focusRange = nil
            history = emptyReadingHistory()
        } catch { if !isLeaving { self.error = ReaderMessages.error(error) } }
    }

    var continuationMessage: String? {
        guard let location = continuation?.location else { return nil }
        let percentage = location.percentage.formatted(.number.precision(.fractionLength(0)))
        if let chapter = location.chapter { return String(localized: "已同步到\(chapter.title)（约 \(percentage)%）") }
        return String(localized: "已同步到约 \(percentage)%")
    }
    func collapseContinuation() { continuationCollapsed = true }
    func expandContinuation() { continuationCollapsed = false }
    func stayAtLocalPosition() { continuationSuppressed = true; clearContinuation() }
    func invalidateSyncedContinuation() { continuationRefresh = UUID(); continuationSuppressed = true; clearContinuation() }
    private func clearContinuation() {
        continuation = nil; continuationCollapsed = false
        continuationTimer?.cancel(); continuationTimer = nil
    }
    private func resetContinuation() {
        continuationRefresh = UUID(); clearContinuation()
        continuationSuppressed = false; seenContinuationTokens.removeAll(); firstContinuationReady = false
    }
    private func presentContinuation(_ candidate: ReadingContinuationCandidate) {
        guard !continuationSuppressed, !isLeaving, candidate.contentSHA == book?.contentSha256,
              candidate.location.offsetUtf8 > anchor, seenContinuationTokens.insert(candidate.token).inserted else { return }
        clearContinuation(); continuation = candidate
        continuationTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard self?.continuation?.token == candidate.token, !UIAccessibility.isVoiceOverRunning else { return }
            self?.collapseContinuation()
        }
        if UIAccessibility.isVoiceOverRunning, let message = continuationMessage {
            let queued = NSAttributedString(string: message, attributes: [.accessibilitySpeechQueueAnnouncement: true])
            UIAccessibility.post(notification: .announcement, argument: queued)
        }
    }
    func refreshSyncedContinuation() async {
        guard !isLeaving, !continuationSuppressed, let id = readingID, window != nil,
              snapshot?.phase == .complete else { return }
        firstContinuationReady = true
        let attempt = opening.request?.id, refresh = UUID()
        continuationRefresh = refresh
        do {
            let context = try await readContinuation(id, anchor)
            guard current(id, attempt: attempt), refresh == continuationRefresh else { return }
            if let candidate = context.candidate { presentContinuation(candidate) }
            else { clearContinuation() }
        } catch is CancellationError { }
        catch {
            guard current(id, attempt: attempt), refresh == continuationRefresh else { return }
            clearContinuation(); reportAutomaticReadingError(error)
        }
    }
    func acceptSyncedContinuation() async {
        guard !isLeaving, !navigating, let id = readingID, let candidate = continuation else { return }
        let attempt = opening.request?.id
        let previous = (snapshot, window, anchor, displayAnchor, showingCover, history, navigation, browseOrigin)
        navigating = true; saveTask?.cancel(); activity.breakVisit()
        defer { navigating = false }
        do {
            let frame = try await service.frame(id, offset: candidate.location.offsetUtf8)
            guard current(id, attempt: attempt), continuation?.token == candidate.token,
                  frame.snapshot.book.contentSha256 == candidate.contentSHA else { return }
            let target = frame.projectionAnchor ?? candidate.location.offsetUtf8
            snapshot = frame.snapshot; window = ReadingWindow(frame: frame)
            displayAnchor = target; anchor = target; showingCover = false
            navigation = ReadingNavigation(placement: .start); navigationRevision += 1
            try await service.writePosition(id, offset: target, expectedConfiguration: candidate.configuration)
            guard current(id, attempt: attempt) else { return }
            history = visitReadingPosition(history: previous.5, fromUtf8: previous.2,
                fromTitle: chapter?.title ?? book?.title ?? "", toUtf8: target,
                toTitle: candidate.location.chapter?.title ?? book?.title ?? "")
            browseOrigin = nil; browseViewport = nil; focusRange = nil
            hasEnteredBody = true; hasLocalReadingInteraction = true
            refreshChapter(at: target, bookID: id); refreshAnnotations(); clearContinuation()
        } catch {
            guard !isLeaving, readingID == id, opening.request?.id == attempt else { return }
            snapshot = previous.0; window = previous.1; anchor = previous.2; displayAnchor = previous.3
            showingCover = previous.4; history = previous.5; navigation = previous.6; browseOrigin = previous.7
            navigationRevision += 1
            if !(error is CancellationError) { self.error = ReaderMessages.error(error) }
        }
    }

    /// Own the async selection read for copy, search and AI alike. The original
    /// envelope survives page/window changes; no last-page excerpt is cached.
    func readSelection(start: UInt64, end: UInt64, perform: @escaping (TextRange) async -> Void) {
        selectionTask?.cancel()
        guard !isLeaving, let id = readingID else { return }
        let from = min(selectionStart ?? start, start), to = max(selectionStart ?? end, end)
        selectionTask = Task {
            do {
                let range = try await service.displayTextRange(id, start: from, end: to)
                guard !Task.isCancelled, !isLeaving, readingID == id else { return }
                await perform(range)
            } catch is CancellationError {
                // Leaving or another selection replaces the consumer, not its data.
            } catch {
                if !Task.isCancelled, !isLeaving, readingID == id { self.error = ReaderMessages.error(error) }
            }
        }
    }

    enum PreparedSelection { case chapter(ChapterEditDraft), note(AnnotationEdit) }

    /// Returns a prepared payload; the UI task owner atomically adopts it.
    func prepareSelection(start: UInt64, end: UInt64, action: ReaderSelectionAction) async -> PreparedSelection? {
        guard !isLeaving, let id = readingID else { return nil }
        if action == .beginRange { selectionStart = start; refreshAnnotations(); return nil }
        do {
            if action == .chapter {
                guard !incomplete else { return nil }
                let line = try await service.paragraph(id, at: start)
                guard !isLeaving, readingID == id else { return nil }
                guard line.text.trimmingCharacters(in: .whitespacesAndNewlines).count <= 80 else {
                    error = String(localized: "请选择单独的章节标题行。"); return nil
                }
                return .chapter(ChapterEditDraft(start: line.startUtf8, title: line.text.trimmingCharacters(in: .whitespacesAndNewlines), level: 1))
            }
            let range: TextRange
            if action == .paragraph { range = try await service.paragraph(id, at: start) }
            else {
                let from = selectionStart.map { min($0, start) } ?? start
                let to = selectionStart.map { max($0, end) } ?? end
                range = try await service.textRange(id, start: from, end: to)
            }
            let prepared: PreparedSelection?
            if action == .highlight {
                _ = try await service.annotate(id, start: range.startUtf8, end: range.endUtf8)
                prepared = nil
            } else {
                prepared = .note(try await service.prepareAnnotation(id, start: range.startUtf8, end: range.endUtf8))
            }
            guard !isLeaving, readingID == id else { return nil }
            selectionStart = nil; marksRevision += 1; refreshAnnotations()
            return prepared
        } catch { if !isLeaving { self.error = ReaderMessages.error(error) }; return nil }
    }

    func prepareAnnotation(_ id: String) async -> AnnotationEdit? {
        guard !isLeaving, let bookID = readingID else { return nil }
        do {
            let value = try await service.mark(id)
            guard !isLeaving, readingID == bookID else { return nil }
            let edit = try await service.prepareAnnotation(bookID, start: value.startUtf8, end: value.endUtf8)
            return !isLeaving && readingID == bookID ? edit : nil
        } catch { if !isLeaving { self.error = ReaderMessages.error(error) }; return nil }
    }

    var displayedProgress: Double? {
        guard !incomplete, let book, book.byteCount > 0 else { return nil }
        return Double(displayAnchor ?? anchor) / Double(book.byteCount) * 100
    }
    var displayedProgressText: String {
        displayedProgress.map { ($0 / 100).formatted(.percent.precision(.fractionLength(1))) } ?? String(localized: "进度")
    }

    func notesChanged() { if !isLeaving { marksRevision += 1; refreshAnnotations() } }

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
