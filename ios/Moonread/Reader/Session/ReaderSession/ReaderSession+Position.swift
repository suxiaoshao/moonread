import SwiftUI
import UIKit

extension ReaderSession {
    func moved(to offset: UInt64, settled: Bool, userInitiated: Bool = true) {
        guard !isLeaving, let book, let id = readingID else { return }
        if listeningOwnsPosition {
            if userInitiated { beganReadingInteraction() }
            // The visual anchor may follow a manual browse, but the audio
            // checkpoint remains the sole formal position until ownership ends.
            if listeningOwnsPosition {
                guard listening.active else { return }
                anchor = min(offset, book.byteCount)
                if listening.following == .detached { refreshChapter(at: anchor, bookID: id) }
                return
            }
        }
        guard !navigating else { return }
        showingCover = false
        if browseOrigin == nil { hasEnteredBody = true }
        displayAnchor = nil
        anchor = min(offset, book.byteCount)
        if userInitiated && browseOrigin == nil { hasLocalReadingInteraction = true }
        if let continuation, anchor >= continuation.location.offsetUtf8 { clearContinuation() }
        refreshChapter(at: anchor, bookID: id)
        guard browseOrigin == nil else { return }
        saveTask?.cancel()
        guard hasLocalReadingInteraction else { return }
        let position = anchor
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
                guard self?.isLeaving == false else { return }
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
            } catch {
                if current(id, attempt: attempt) {
                    if autoReading.phase == .preparing { autoReading.failed(ReaderMessages.error(error)) }
                    else { self.error = ReaderMessages.error(error) }
                }
            }
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

    func refreshChapter(at offset: UInt64, bookID: String) {
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

}
