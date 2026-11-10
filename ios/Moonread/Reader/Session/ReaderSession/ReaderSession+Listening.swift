import Foundation

extension ReaderSession {
    var listeningPosition: UInt64? { listeningOwnsPosition ? activeListening?.safeOffset : nil }

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
        guard let listening = activeListening, !isLeaving, listeningUIActive, listening.active, listeningOwnsPosition, listening.following == .following,
              let cursor = listening.cursor, let id = readingID else { return }
        if let heading = listening.currentChapter { chapter = heading }
        if let window, cursor.unit.startUtf8 >= window.start, cursor.unit.endUtf8 <= window.end { return }
        guard listeningWindowTask == nil else { return }
        let follow = ReaderNavigationRequest(generation: navigationGeneration, opening: opening.request?.id,
                                             intent: .listeningFollow(listening))
        listeningWindowTask = Task { [weak self, service] in
            guard let self else { return }
            defer { listeningWindowTask = nil }
            do {
                while !isLeaving, listeningUIActive, listening.active, listeningOwnsPosition, listening.following == .following, let current = listening.cursor {
                    if let window, current.unit.startUtf8 >= window.start, current.unit.endUtf8 <= window.end { break }
                    let frame = try await service.frame(id, offset: current.unit.startUtf8)
                    try Task.checkCancellation()
                    guard currentNavigation(follow), activeListening === listening, listeningUIActive, readingID == id, listening.active, listeningOwnsPosition, listening.following == .following else { return }
                    let next = ReadingWindow(frame: frame)
                    guard current.unit.startUtf8 >= next.start, current.unit.endUtf8 <= next.end else {
                        listening.pause(message: String(localized: "这部分正文还未准备好")); return
                    }
                    snapshot = frame.snapshot; window = next
                    displayAnchor = frame.projectionAnchor; surface = .body(SourceAnchor(current.unit.startUtf8))
                    refreshAnnotations()
                }
            } catch is CancellationError { }
            catch { listening.pause(message: ReaderMessages.error(error)) }
        }
    }

    @discardableResult func returnToListening() async -> Bool {
        guard !isLeaving, !navigating, let player = activeListening, player.active, player.ownsPosition,
              let initial = player.safeOffset else { return false }
        let request = beginNavigation(.returnToSpeech(player))
        defer { finishNavigation(request) }
        do {
            guard try await revealListeningPosition(initial, request: request, player: player) else { return false }
            player.returnToSpeech()
            return true
        } catch is CancellationError {
            return false
        } catch {
            if currentNavigation(request) { self.error = ReaderMessages.error(error) }
            return false
        }
    }

    func finishListeningPosition(_ offset: UInt64, reveal: Bool) {
        clearListeningBrowse(at: offset)
        cancelNavigation()
        guard reveal, !isLeaving, listeningUIActive else { return }
        let request = beginNavigation(.speechExit(offset))
        navigationTask = Task { [weak self] in
            guard let self else { return }
            defer { finishNavigation(request) }
            do {
                _ = try await revealListeningPosition(offset, request: request, player: nil)
            } catch is CancellationError { }
            catch { if currentNavigation(request) { self.error = ReaderMessages.error(error) } }
        }
    }

    private func clearListeningBrowse(at offset: UInt64) {
        clearBrowse()
        surface = .body(SourceAnchor(offset)); displayAnchor = nil
    }

    private func revealListeningPosition(_ initial: UInt64, request: ReaderNavigationRequest,
                                         player: ListeningSession?) async throws -> Bool {
        guard let id = readingID else { return false }
        var offset = initial
        var frame: ReadingFrame?
        var visibleWindow = window
        while currentNavigation(request) {
            if visibleWindow.map({ offset < $0.start || offset >= $0.end }) != false {
                let loaded = try await service.frame(id, offset: offset)
                guard currentNavigation(request), readingID == id else { return false }
                frame = loaded
                visibleWindow = ReadingWindow(frame: loaded)
            }
            if let player {
                guard activeListening === player, player.active, player.ownsPosition, let latest = player.safeOffset else { return false }
                offset = latest
                if visibleWindow.map({ offset < $0.start || offset >= $0.end }) == true { continue }
                clearListeningBrowse(at: offset)
            }
            if let frame, let visibleWindow {
                snapshot = frame.snapshot; window = visibleWindow
                displayAnchor = player == nil ? frame.projectionAnchor : offset
            }
            navigation = ReadingNavigation(placement: .context); navigationRevision += 1
            return true
        }
        return false
    }

    func makeListeningSession(defaults: UserDefaults = .standard,
        voiceAvailable: @escaping (String) -> Bool = { id in ListeningSession.voices.contains { $0.identifier == id } },
        audio: @escaping () -> any ListeningAudio = { SystemListeningAudio() }) -> ListeningSession {
        let provider = ListeningTextProvider(service: service)
        return ListeningSession(defaults: defaults, context: { [weak self] in
            guard let self, !isLeaving, let id = readingID, let snapshot, snapshot.readablePrefix == .readable else { return nil }
            return ListeningContext(bookID: id, readingKey: snapshot.book.readingKey, generation: snapshot.generation,
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
            if activeListening?.running == true { activity.update(visibility: .init(body: false), preview: browseOrigin != nil) }
            else { activity.sample() }
        }, admission: { [weak self] in
            self?.toolsSession.listeningAdmission ?? .blocked(.leaving)
        }, willStart: { [weak self] in
            guard let self else { return }
            saveTask?.cancel()
            if activeListening?.active != true || !listeningOwnsPosition { clearBrowse(keepingHistory: true) }
        }, command: { [weak self] player, command in
            self?.toolsSession.send(.remote(player, command))
        }, cursorChanged: { [weak self] in self?.followListeningPosition() },
        ended: { [weak self] offset, reveal in self?.finishListeningPosition(offset, reveal: reveal) },
        voiceAvailable: voiceAvailable, audio: audio)
    }
}
