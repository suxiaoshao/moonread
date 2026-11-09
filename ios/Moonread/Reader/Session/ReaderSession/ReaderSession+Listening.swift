import Foundation

extension ReaderSession {
    var listeningPosition: UInt64? { listeningOwnsPosition ? listening.safeOffset : nil }

    func commitListeningPosition(_ offset: UInt64) {
        guard !isLeaving, let id = readingID else { return }
        hasEnteredBody = true; hasLocalReadingInteraction = true
        saveTask?.cancel()
        saveTask = Task { [weak self, service] in
            do { try Task.checkCancellation(); try await service.savePosition(bookID: id, offset: offset) }
            catch is CancellationError { }
            catch { self?.reportAutomaticReadingError(error) }
        }
    }

    func followListeningPosition() {
        guard !isLeaving, listeningUIActive, listening.following == .following,
              let cursor = listening.cursor, let id = readingID else { return }
        if let window, cursor.unit.startUtf8 >= window.start, cursor.unit.endUtf8 <= window.end { return }
        guard listeningWindowTask == nil else { return }
        listeningWindowTask = Task { [weak self, service] in
            guard let self else { return }
            defer { listeningWindowTask = nil }
            do {
                while !isLeaving, listeningUIActive, listening.following == .following, let current = listening.cursor {
                    if let window, current.unit.startUtf8 >= window.start, current.unit.endUtf8 <= window.end { break }
                    let frame = try await service.frame(id, offset: current.unit.startUtf8)
                    try Task.checkCancellation()
                    guard !isLeaving, readingID == id, listening.following == .following else { return }
                    snapshot = frame.snapshot; window = ReadingWindow(frame: frame)
                    displayAnchor = frame.projectionAnchor; anchor = current.unit.startUtf8
                    refreshAnnotations()
                }
            } catch is CancellationError { }
            catch { listening.pause(message: ReaderMessages.error(error)) }
        }
    }

    func returnToListening() {
        listening.returnToSpeech()
        followListeningPosition()
    }

    func finishListeningPosition(_ offset: UInt64, reveal: Bool) {
        browseOrigin = nil; browseViewport = nil; focusRange = nil
        history = emptyReadingHistory(); anchor = offset; displayAnchor = nil; showingCover = false
        guard reveal, !isLeaving else { return }
        navigationTask?.cancel(); navigationGeneration += 1
        let generation = navigationGeneration
        navigationTask = Task { [weak self, service] in
            guard let self, let id = readingID else { return }
            do {
                if window.map({ offset < $0.start || offset >= $0.end }) != false {
                    let frame = try await service.frame(id, offset: offset)
                    try Task.checkCancellation()
                    guard !isLeaving, generation == navigationGeneration else { return }
                    snapshot = frame.snapshot; window = ReadingWindow(frame: frame); displayAnchor = frame.projectionAnchor
                }
                guard !isLeaving, generation == navigationGeneration else { return }
                navigation = ReadingNavigation(placement: .context); navigationRevision += 1
            } catch is CancellationError { }
            catch { self.error = ReaderMessages.error(error) }
        }
    }

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
            commitListeningPosition(offset)
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
            autoReading.end(); saveTask?.cancel()
            browseOrigin = nil; browseViewport = nil; focusRange = nil
        }, cursorChanged: { [weak self] in self?.followListeningPosition() },
        ended: { [weak self] offset, reveal in self?.finishListeningPosition(offset, reveal: reveal) })
    }
}
