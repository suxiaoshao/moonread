import SwiftUI
import UIKit

extension ReaderSession {
    func refreshAnnotations() -> Task<Void, Never>? {
        annotationTask?.cancel()
        guard !isLeaving, let id = readingID, let window else { return nil }
        annotationTask = Task {
            do {
                let compatibilityNotice = try await service.readingCompatibilityNotice(id)
                let values = try await service.annotationWindow(id, start: min(selectionStart ?? window.start, window.start),
                    end: max(selectionStart ?? window.end, window.end))
                let positions = try await service.bookmarkPositions(id, start: window.start, end: window.end)
                guard !isLeaving, !Task.isCancelled, readingID == id else { return }
                annotationWindow = values
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
        let admission = readingLease?.writeAdmission
        do {
            let added = try await service.toggleBookmark(id, at: position, admission: admission)
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

    func readSelection(start: UInt64, end: UInt64, finished: @escaping () -> Void = {}, perform: @escaping (TextRange) async -> Void) {
        selectionTask?.cancel()
        guard !isLeaving, let id = readingID else { finished(); return }
        toolsSession.send(.selectionChanged)
        let from = min(selectionStart ?? start, start), to = max(selectionStart ?? end, end)
        selectionTask = Task {
            defer { finished() }
            do {
                let range = try await service.displayTextRange(id, start: from, end: to, indent: (settings ?? defaultReaderSettings()).indent)
                guard !Task.isCancelled, !isLeaving, readingID == id else { return }
                await perform(range)
            } catch is CancellationError {
                // Leaving or another selection replaces the consumer, not its data.
            } catch {
                if !Task.isCancelled, !isLeaving, readingID == id { self.error = ReaderMessages.error(error) }
            }
        }
    }

    func selectText(start: UInt64, end: UInt64, action: ReaderSelectionAction) {
        guard !isLeaving, let id = readingID else { return }
        let admission = readingLease?.writeAdmission
        toolsSession.send(.selectionChanged)
        if action == .beginRange { selectionStart = start; refreshAnnotations(); return }
        Task {
            do {
                if action == .chapter {
                    guard !incomplete else { return }
                    let line = try await service.paragraph(id, at: start)
                    guard !isLeaving, line.text.trimmingCharacters(in: .whitespacesAndNewlines).count <= 80 else {
                        if !isLeaving { error = String(localized: "请选择单独的章节标题行。") }; return
                    }
                    chapterDraft = ChapterEditDraft(start: line.startUtf8, title: line.text.trimmingCharacters(in: .whitespacesAndNewlines), level: 1, creating: true)
                    return
                }
                let range: TextRange
                if action == .paragraph {
                    range = try await service.paragraph(id, at: start)
                } else {
                    let from = selectionStart.map { min($0, start) } ?? start
                    let to = selectionStart.map { max($0, end) } ?? end
                    range = try await service.textRange(id, start: from, end: to)
                }
                guard !isLeaving, readingID == id else { return }
                let draft = AnnotationEdit(id: UUID().uuidString, bookId: id, startUtf8: range.startUtf8, endUtf8: range.endUtf8,
                    excerpt: AnnotationEdit.excerpt(from: range.text), note: "", marks: [], baselines: [:],
                    writeAdmission: admission, scope: .single)
                if action == .highlight { _ = try await service.saveNote(draft, text: "") }
                else { editor = draft }
                guard !isLeaving, readingID == id else { return }
                selectionStart = nil
                marksRevision += 1; refreshAnnotations()
            } catch { if !isLeaving { self.error = ReaderMessages.error(error) } }
        }
    }

    func openAnnotation(_ id: String) {
        guard !isLeaving, let bookID = readingID else { return }
        let admission = readingLease?.writeAdmission
        toolsSession.send(.ordinaryEdit)
        Task {
            do {
                let value = try await service.mark(id)
                guard !isLeaving, readingID == bookID else { return }
                let edit = try await service.prepareAnnotation(bookID, start: value.startUtf8, end: value.endUtf8, admission: admission)
                if !isLeaving { editor = edit }
            }
            catch { if !isLeaving { self.error = ReaderMessages.error(error) } }
        }
    }

    func openAnnotation(_ mark: ReaderMark, shown snapshot: NoteCandidates) throws {
        guard !isLeaving, let bookID = readingID, editor == nil else { return }
        let baselines = try snapshot.checked([mark.id])
        toolsSession.send(.ordinaryEdit)
        editor = AnnotationEdit(id: mark.id, bookId: bookID, startUtf8: mark.startUtf8, endUtf8: mark.endUtf8,
            excerpt: mark.excerpt, note: mark.note, marks: [mark], baselines: baselines,
            writeAdmission: snapshot.admission, scope: .single)
    }

    func notesChanged() { if !isLeaving { marksRevision += 1; refreshAnnotations() } }

}
