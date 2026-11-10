import SwiftUI
import UIKit

extension ReaderSession {
    func browse(to start: UInt64, end: UInt64? = nil, placement: ReadingTargetPlacement = .context,
                bottomObstruction: CGFloat = 0, restoring: ReadingViewport? = nil, historyID: String? = nil) {
        guard !isLeaving, let id = readingID else { return }
        listening.pause(); listening.userNavigated()
        autoReading.end()
        activity.breakVisit()
        let firstPreview = browseOrigin == nil
        let origin = browseOrigin ?? anchor
        let leaving = anchor
        let leavingTitle = chapter?.title ?? book?.title ?? ""
        let leavingWasCover = showingCover
        let originalViewport = browseOrigin == nil ? viewportAccess.capture() : browseViewport
        let visibleWindow = placement == .context && restoring == nil
            ? viewportAccess.controller?.visibleWindow(containing: start, end: end, bottomObstruction: bottomObstruction) : nil
        if firstPreview {
            browseOrigin = origin; browseViewport = originalViewport
            // The already-accepted formal saveTask keeps its captured point.
            // Do not cancel its debounce or create another origin timestamp.
            // Preview moves cannot replace it; Continue/exit await it in order.
        }
        navigationGeneration += 1
        let revision = navigationGeneration
        navigationTask?.cancel()
        navigating = true
        navigationTask = Task {
            defer { if revision == navigationGeneration { navigating = false } }
            do {
                let frame = try await service.frame(id, offset: start)
                guard !isLeaving, !Task.isCancelled, revision == navigationGeneration else { return }
                let target = min(start, frame.snapshot.book.byteCount)
                let heading = frame.chapter
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
                window = visibleWindow.flatMap { $0.revision == frame.projectionRevision ? $0 : nil } ?? ReadingWindow(frame: frame)
                displayAnchor = frame.projectionAnchor
                anchor = target
                showingCover = placement == .cover || restoring?.isCover == true
                focusRange = end.map { TextRange(startUtf8: start, endUtf8: $0, text: "") }
                navigation = ReadingNavigation(placement: placement, bottomObstruction: bottomObstruction, restoring: restoring)
                navigationRevision += 1
                chapter = heading
                refreshAnnotations()
            } catch is CancellationError { }
            catch { if !isLeaving, !Task.isCancelled, revision == navigationGeneration { self.error = ReaderMessages.error(error) } }
        }
    }

    func returnFromBrowse() async {
        guard !isLeaving, let original = browseOrigin else { return }
        browse(to: original, placement: .start, restoring: browseViewport)
        let revision = navigationGeneration
        await navigationTask?.value
        if !isLeaving, revision == navigationGeneration, !navigating, anchor == original { browseOrigin = nil; browseViewport = nil; focusRange = nil; history = emptyReadingHistory() }
    }

    func continueReading() async {
        guard !isLeaving, !navigating, let id = readingID else { return }
        listening.pause(); listening.userNavigated()
        autoReading.end()
        let revision = navigationGeneration
        let position = anchor, cover = showingCover
        do {
            await saveTask?.value
            guard !isLeaving, !navigating, revision == navigationGeneration else { return }
            if listeningOwnsPosition {
                // Explicit continuation adopts the browsed location. End audio
                // without its final checkpoint/reveal replacing that selection.
                listening.end(savePosition: false, returnToText: false)
            }
            if !cover {
                try await service.savePosition(bookID: id, offset: position)
                hasEnteredBody = true
                hasLocalReadingInteraction = true
            } else { hasEnteredBody = false }
            guard !isLeaving, revision == navigationGeneration else { return }
            browseOrigin = nil; browseViewport = nil; navigation = nil; focusRange = nil
            history = emptyReadingHistory()
        } catch { if !isLeaving { self.error = ReaderMessages.error(error) } }
    }

}
