import Foundation

extension ReaderSession {
    func makeListeningSession() -> ListeningSession {
        let provider = ListeningTextProvider(service: service)
        return ListeningSession(context: { [weak self] in
            guard let self, !isLeaving, let id = readingID, let snapshot, snapshot.canRead else { return nil }
            return ListeningContext(bookID: id, contentSHA: snapshot.book.contentSha256, generation: snapshot.generation,
                offset: anchor, indent: settings?.indent ?? .original, title: snapshot.book.title, chapter: chapter?.title ?? "")
        }, read: { context, offset, beginning in
            try await provider.next(bookID: context.bookID, offset: offset, paragraphStart: beginning, indent: context.indent)
        }, position: { [weak self] offset in
            guard let self, !isLeaving else { return }
            hasEnteredBody = true; hasLocalReadingInteraction = true
            browseOrigin = nil; browseViewport = nil; focusRange = nil
            moved(to: offset, settled: true, userInitiated: false, fromListening: true)
        }, flush: { [weak self] in
            Task { [weak self] in await self?.flush() }
        }, readabilityChanged: { [weak self] in
            // Never report an audio callback as a visual interaction or coverage.
            guard let self else { return }
            if listening.running { activity.update(visibility: .init(body: false), preview: browseOrigin != nil) }
            else { activity.sample() }
        }, blocked: { [weak self] in
            guard let self else { return true }
            return isLeaving || navigating || error != nil || viewportAccess.hasBlockingPresentation(allowingReaderAccessory: listening.readerAccessoryPresented, allowAccessoryTransitions: true)
        }, willStart: { [weak self] in
            guard let self else { return }
            if autoReading.phase != .idle, let offset = viewportAccess.capture()?.offset {
                moved(to: offset, settled: true, userInitiated: false)
            }
            autoReading.end()
        })
    }
}
