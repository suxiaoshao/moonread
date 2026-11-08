import SwiftUI
import UIKit

extension ReaderSession {
    func retryPreparation() {
        guard !isLeaving, snapshot?.phase == .failed, let id = readingID else { return }
        error = nil
        Task {
            do { try await service.resumeImport(id); startMonitoring() }
            catch { if !isLeaving { self.error = ReaderMessages.error(error) } }
        }
    }

    func restart(encoding: String? = nil) {
        autoReading.end()
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
                history = emptyReadingHistory(); chapterDraft = nil
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

}
