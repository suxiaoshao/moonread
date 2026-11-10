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
        guard !isLeaving, listeningUIActive, listening.active, listeningOwnsPosition, listening.following == .following,
              let cursor = listening.cursor, let id = readingID else { return }
        if let heading = listening.currentChapter { chapter = heading }
        if let window, cursor.unit.startUtf8 >= window.start, cursor.unit.endUtf8 <= window.end { return }
        guard listeningWindowTask == nil else { return }
        listeningWindowTask = Task { [weak self, service] in
            guard let self else { return }
            defer { listeningWindowTask = nil }
            do {
                while !isLeaving, listeningUIActive, listening.active, listeningOwnsPosition, listening.following == .following, let current = listening.cursor {
                    if let window, current.unit.startUtf8 >= window.start, current.unit.endUtf8 <= window.end { break }
                    let frame = try await service.frame(id, offset: current.unit.startUtf8)
                    try Task.checkCancellation()
                    guard !isLeaving, listeningUIActive, readingID == id, listening.active, listeningOwnsPosition, listening.following == .following else { return }
                    let next = ReadingWindow(frame: frame)
                    guard current.unit.startUtf8 >= next.start, current.unit.endUtf8 <= next.end else {
                        listening.pause(message: String(localized: "这部分正文还未准备好")); return
                    }
                    snapshot = frame.snapshot; window = next
                    displayAnchor = frame.projectionAnchor; anchor = current.unit.startUtf8
                    refreshAnnotations()
                }
            } catch is CancellationError { }
            catch { listening.pause(message: ReaderMessages.error(error)) }
        }
    }

    @discardableResult func returnToListening() async -> Bool {
        guard !isLeaving, !navigating, listening.active, listeningOwnsPosition, let offset = listening.safeOffset else { return false }
        navigationTask?.cancel(); navigationGeneration += 1
        let generation = navigationGeneration
        navigating = true
        defer { if generation == navigationGeneration { navigating = false } }
        do {
            guard try await revealListeningPosition(offset, generation: generation, returning: true) else { return false }
            listening.returnToSpeech()
            return true
        } catch is CancellationError {
            return false
        } catch {
            if !isLeaving, generation == navigationGeneration { self.error = ReaderMessages.error(error) }
            return false
        }
    }

    func finishListeningPosition(_ offset: UInt64, reveal: Bool) {
        clearListeningBrowse(at: offset)
        navigationTask?.cancel(); navigationGeneration += 1
        navigating = false
        guard reveal, !isLeaving, listeningUIActive else { return }
        let generation = navigationGeneration
        navigationTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await revealListeningPosition(offset, generation: generation, returning: false)
            } catch is CancellationError { }
            catch { if !isLeaving, generation == navigationGeneration { self.error = ReaderMessages.error(error) } }
        }
    }

    private func clearListeningBrowse(at offset: UInt64) {
        browseOrigin = nil; browseViewport = nil; focusRange = nil
        history = emptyReadingHistory(); anchor = offset; displayAnchor = nil; showingCover = false
    }

    private func revealListeningPosition(_ offset: UInt64, generation: Int, returning: Bool) async throws -> Bool {
        guard let id = readingID else { return false }
        let attempt = opening.request?.id
        let frame: ReadingFrame? = if window.map({ offset < $0.start || offset >= $0.end }) != false {
            try await service.frame(id, offset: offset)
        } else { nil }
        try Task.checkCancellation()
        guard current(id, attempt: attempt), generation == navigationGeneration,
              !returning || listening.active && listeningOwnsPosition else { return false }
        if returning { clearListeningBrowse(at: offset) }
        if let frame {
            snapshot = frame.snapshot; window = ReadingWindow(frame: frame); displayAnchor = frame.projectionAnchor
        }
        navigation = ReadingNavigation(placement: .context); navigationRevision += 1
        return true
    }

    func makeListeningSession(defaults: UserDefaults = .standard,
        voiceAvailable: @escaping (String) -> Bool = { id in ListeningSession.voices.contains { $0.identifier == id } },
        audio: @escaping () -> any ListeningAudio = { SystemListeningAudio() }) -> ListeningSession {
        let provider = ListeningTextProvider(service: service)
        return ListeningSession(defaults: defaults, context: { [weak self] in
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
            // Real jumps pause at their entry point. An in-flight return to the
            // speech position may keep playing, but cannot start paused speech.
            return isLeaving || (navigating && !listening.running) || error != nil || selectionStart != nil
                || viewportAccess.controller?.selectedSourceRange() != nil
                || viewportAccess.hasBlockingListeningPresentation(opening: opening.request?.id,
                    awaitingToolContent: listening.running)
        }, willStart: { [weak self] in
            guard let self else { return }
            if autoReading.phase != .idle, let offset = viewportAccess.capture()?.offset {
                moved(to: offset, settled: true, userInitiated: false)
            }
            autoReading.end(); saveTask?.cancel()
            if !listening.active || !listeningOwnsPosition { browseOrigin = nil; browseViewport = nil; focusRange = nil }
        }, cursorChanged: { [weak self] in self?.followListeningPosition() },
        ended: { [weak self] offset, reveal in self?.finishListeningPosition(offset, reveal: reveal) },
        voiceAvailable: voiceAvailable, audio: audio)
    }
}
