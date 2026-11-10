import SwiftUI
import UIKit

enum ReaderExecution {
    case manual
    case listening(ListeningSession)
    case automatic(ReaderAutoReading)
}

struct ReaderReadingTarget {
    let start: UInt64
    var end: UInt64?
    var placement: ReadingTargetPlacement = .context
    var bottomObstruction: CGFloat = 0
    var restoring: ReadingViewport?
    var historyID: String?
}

enum ReaderNavigationIntent {
    case userJump(ReaderReadingTarget)
    case returnToPreview(ReaderReadingTarget)
    case returnToSpeech(ListeningSession)
    case listeningFollow(ListeningSession)
    case speechExit(UInt64)
    case positionAdoption

    var blocksPositionInput: Bool {
        switch self {
        case .listeningFollow, .speechExit: false
        default: true
        }
    }
}

struct ReaderNavigationRequest {
    let generation: Int
    let opening: UUID?
    let intent: ReaderNavigationIntent
}

struct ReaderBrowseContext {
    let origin: UInt64
    let viewport: ReadingViewport?
    var target: UInt64
    var focus: TextRange?
    var history: ReadingHistory
}

enum ReaderBrowseState {
    case reading(ReadingHistory)
    case preview(ReaderBrowseContext)

    var preview: ReaderBrowseContext? {
        if case .preview(let context) = self { return context }
        return nil
    }
    var history: ReadingHistory {
        get {
            switch self {
            case .reading(let history): history
            case .preview(let context): context.history
            }
        }
        set {
            switch self {
            case .reading: self = .reading(newValue)
            case .preview(var context):
                context.history = newValue
                self = .preview(context)
            }
        }
    }
}

extension ReaderSession {
    func browse(to start: UInt64, end: UInt64? = nil, placement: ReadingTargetPlacement = .context,
                bottomObstruction: CGFloat = 0, restoring: ReadingViewport? = nil, historyID: String? = nil) {
        let target = ReaderReadingTarget(start: start, end: end, placement: placement,
            bottomObstruction: bottomObstruction, restoring: restoring, historyID: historyID)
        toolsSession.send(.navigate(.userJump(target)))
    }

    func executeBrowse(_ target: ReaderReadingTarget, intent: ReaderNavigationIntent) {
        guard !isLeaving, let id = readingID else { return }
        let start = target.start, end = target.end, placement = target.placement
        let restoring = target.restoring, historyID = target.historyID, bottomObstruction = target.bottomObstruction
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
            browseState = .preview(.init(origin: origin, viewport: originalViewport, target: leaving,
                                         focus: nil, history: history))
            // The already-accepted formal saveTask keeps its captured point.
            // Do not cancel its debounce or create another origin timestamp.
            // Preview moves cannot replace it; Continue/exit await it in order.
        }
        let request = beginNavigation(intent)
        navigationTask = Task {
            defer { finishNavigation(request) }
            do {
                let frame = try await service.frame(id, offset: start)
                guard currentNavigation(request) else { return }
                let target = min(start, frame.snapshot.book.byteCount)
                let heading = frame.chapter
                if let historyID {
                    history = try selectReadingHistory(history: updateHistoryPosition(history: history, offsetUtf8: leaving, title: leavingTitle), id: historyID)
                } else if restoring == nil && !leavingWasCover && placement != .cover {
                    history = visitReadingPosition(history: history, fromUtf8: leaving, fromTitle: leavingTitle,
                                                   toUtf8: target, toTitle: heading?.title ?? book?.title ?? "")
                }
                snapshot = frame.snapshot
                windowTask?.cancel(); windowTask = nil
                window = visibleWindow.flatMap { $0.revision == frame.projectionRevision ? $0 : nil } ?? ReadingWindow(frame: frame)
                displayAnchor = frame.projectionAnchor
                anchor = target
                showingCover = placement == .cover || restoring?.isCover == true
                browseState = .preview(.init(origin: origin, viewport: originalViewport, target: target,
                    focus: end.map { TextRange(startUtf8: start, endUtf8: $0, text: "") }, history: history))
                navigation = ReadingNavigation(placement: placement, bottomObstruction: bottomObstruction, restoring: restoring)
                navigationRevision += 1
                chapter = heading
                refreshAnnotations()
            } catch is CancellationError { }
            catch { if currentNavigation(request) { self.error = ReaderMessages.error(error) } }
        }
    }

    func returnFromBrowse() async {
        guard !isLeaving, let original = browseOrigin else { return }
        let target = ReaderReadingTarget(start: original, placement: .start, restoring: browseViewport)
        toolsSession.send(.navigate(.returnToPreview(target)))
        let revision = navigationGeneration
        await navigationTask?.value
        if !isLeaving, revision == navigationGeneration, !navigating, anchor == original { clearBrowse() }
    }

    func continueReading() async {
        guard !isLeaving, !navigating, let id = readingID else { return }
        let position = showingCover ? nil : anchor
        let request = beginNavigation(.positionAdoption)
        defer { finishNavigation(request) }
        do {
            guard try await adoptReadingPosition(position, bookID: id, request: request) else { return }
            clearBrowse(); navigation = nil
        } catch { if currentNavigation(request) { self.error = ReaderMessages.error(error) } }
    }

}
