import SwiftUI
import UIKit

extension ReaderSession {
    func browse(to start: UInt64, end: UInt64? = nil, placement: ReadingTargetPlacement = .context,
                bottomObstruction: CGFloat = 0, restoring: ReadingViewport? = nil, historyID: String? = nil) {
        guard !isLeaving, let id = readingID else { return }
        listening.userNavigated()
        autoReading.end()
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
        listening.userNavigated()
        autoReading.end()
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

}
