import SwiftUI
import UIKit

extension ReaderSession {
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
    func clearContinuation() {
        continuation = nil; continuationCollapsed = false
        continuationTimer?.cancel(); continuationTimer = nil
    }
    func resetContinuation() {
        continuationRefresh = UUID(); clearContinuation()
        continuationSuppressed = false; seenContinuationTokens.removeAll(); firstContinuationReady = false
    }
    func presentContinuation(_ candidate: ReadingContinuationCandidate) {
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
        let request = beginNavigation(.positionAdoption)
        activity.breakVisit()
        defer { finishNavigation(request) }
        do {
            let frame = try await service.frame(id, offset: candidate.location.offsetUtf8)
            guard currentNavigation(request), current(id, attempt: attempt), continuation?.token == candidate.token,
                  frame.snapshot.book.contentSha256 == candidate.contentSHA else { return }
            let target = frame.projectionAnchor ?? candidate.location.offsetUtf8
            let previous = (anchor, history, chapter?.title ?? book?.title ?? "")
            let toolContext = toolsSession.render.context
            let wasListening = listeningOwnsPosition || activeListening?.active == true
            guard try await adoptReadingPosition(target, bookID: id, request: request,
                expectedConfiguration: candidate.configuration, whileCurrent: { continuation?.token == candidate.token })
            else { return }
            snapshot = frame.snapshot; window = ReadingWindow(frame: frame)
            displayAnchor = target; anchor = target; showingCover = false
            navigation = ReadingNavigation(placement: .start); navigationRevision += 1
            history = visitReadingPosition(history: previous.1, fromUtf8: previous.0,
                fromTitle: previous.2, toUtf8: target,
                toTitle: candidate.location.chapter?.title ?? book?.title ?? "")
            clearBrowse(keepingHistory: true)
            refreshChapter(at: target, bookID: id); refreshAnnotations(); clearContinuation()
            if wasListening, toolsSession.render.compact == .listening { toolsSession.send(.finishedBrowse(toolContext)) }
        } catch {
            if currentNavigation(request), !(error is CancellationError) { self.error = ReaderMessages.error(error) }
        }
    }

    /// Own the async selection read for copy, search and AI alike. The original
    /// envelope survives page/window changes; no last-page excerpt is cached.
}
