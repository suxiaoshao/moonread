import SwiftUI
import UIKit

extension ReaderSession {
    func startMonitoring() {
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
                    autoReading?.updatePreparationFailure(value.phase == .failed ? value.error.map { ReaderMessages.error($0) } : nil)
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

    func refreshWindow(_ id: String, at offset: UInt64, monitor: UUID? = nil) async {
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

}
