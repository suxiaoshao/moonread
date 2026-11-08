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
        let previous = (snapshot, window, anchor, displayAnchor, showingCover, history, navigation, browseOrigin)
        autoReading.end()
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
}
