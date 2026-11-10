import AVFoundation
import SwiftUI

struct ListeningContext {
    let bookID: String
    let contentSHA: String?
    let generation: UInt64
    let offset: UInt64
    let indent: ReadingIndent
    let title: String
    let chapter: String
}

/// One reading opening owns one synthesizer. There is no independent listening
/// position: safe native ranges are committed through ReaderSession's existing position service/flush.
@MainActor @Observable final class ListeningSession {
    enum Phase { case idle, preparing, playing, paused }
    enum Following { case following, detached }
    private(set) var following = Following.following
    private(set) var phase = Phase.idle
    private(set) var notice: String?
    private(set) var title = ""
    private(set) var chapter = ""
    private(set) var currentChapter: ChapterInfo?
    private(set) var previewing = false
    private(set) var ownsPosition = false
    private(set) var cursor: ListeningCursor?
    private(set) var rate: Float
    private(set) var voiceID: String?
    private(set) var voiceLanguage: String?
    private(set) var timerMinutes = 0
    private(set) var deadline: Date?
    var running: Bool { phase == .playing || phase == .preparing }
    var active: Bool { phase != .idle }
    var voice: AVSpeechSynthesisVoice? { voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) }
    static var voices: [AVSpeechSynthesisVoice] { AVSpeechSynthesisVoice.speechVoices().filter { !$0.voiceTraits.contains(.isPersonalVoice) } }
    @ObservationIgnored var voiceSelectionPresented = false
    private var isBlocked: Bool { voiceSelectionPresented || previewing || blocked() }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let context: () -> ListeningContext?
    @ObservationIgnored private let read: (ListeningContext, UInt64, Bool) async throws -> ListeningRead
    @ObservationIgnored private let position: (UInt64) -> Void
    @ObservationIgnored private let cursorChanged: () -> Void
    @ObservationIgnored private let ended: (UInt64, Bool) -> Void
    @ObservationIgnored private let flush: () -> Void
    @ObservationIgnored private let readabilityChanged: () -> Void
    @ObservationIgnored private let willStart: () -> Void
    @ObservationIgnored private let blocked: () -> Bool
    @ObservationIgnored private let voiceAvailable: (String) -> Bool
    @ObservationIgnored private let makeAudio: () -> any ListeningAudio
    @ObservationIgnored private var native: (any ListeningAudio)?
    @ObservationIgnored private var source: ListeningContext?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var queue: [SpeechSegment] = []
    private(set) var safeOffset: UInt64?
    @ObservationIgnored private var publishedOffset: UInt64?
    @ObservationIgnored private var nextOffset: UInt64 = 0
    @ObservationIgnored private var endOfText = false
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var lastCheckpoint: TimeInterval = 0
    @ObservationIgnored private var previewID: UUID?
    @ObservationIgnored private var artwork: UIImage?
    @ObservationIgnored private var coverTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard,
         context: @escaping () -> ListeningContext?,
         read: @escaping (ListeningContext, UInt64, Bool) async throws -> ListeningRead,
         position: @escaping (UInt64) -> Void, flush: @escaping () -> Void,
         readabilityChanged: @escaping () -> Void, blocked: @escaping () -> Bool,
         willStart: @escaping () -> Void = {},
         cursorChanged: @escaping () -> Void = {}, ended: @escaping (UInt64, Bool) -> Void = { _,_ in },
         voiceAvailable: @escaping (String) -> Bool = { id in ListeningSession.voices.contains { $0.identifier == id } },
         audio: @escaping () -> any ListeningAudio = { SystemListeningAudio() }) {
        self.defaults = defaults; self.context = context; self.read = read
        self.position = position; self.flush = flush; self.readabilityChanged = readabilityChanged; self.blocked = blocked
        self.cursorChanged = cursorChanged; self.ended = ended
        makeAudio = audio; self.voiceAvailable = voiceAvailable; self.willStart = willStart
        let stored = defaults.object(forKey: "Moonread.listening.rate") as? NSNumber
        rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, stored?.floatValue ?? AVSpeechUtteranceDefaultSpeechRate))
        voiceID = defaults.string(forKey: "Moonread.listening.voice")
        voiceLanguage = defaults.string(forKey: "Moonread.listening.language")
        if voiceID == nil || !voiceAvailable(voiceID!) {
            let language = voiceLanguage ?? Locale.preferredLanguages.first ?? Locale.current.identifier
            let preferred = AVSpeechSynthesisVoice(language: language)
            let voices = Self.voices
            if let selected = preferred.flatMap({ preferred in voices.first { $0.identifier == preferred.identifier } })
                ?? voices.first(where: { $0.language.hasPrefix(String(language.prefix(2))) }) {
                voiceID = selected.identifier; voiceLanguage = selected.language
            }
        }
    }
    private var audio: any ListeningAudio {
        if let native { return native }
        let value = makeAudio()
        value.event = { [weak self] in self?.received($0) }
        native = value
        return value
    }
    func start() {
        guard !running else { return }
        guard let voiceID, voiceAvailable(voiceID) else {
            notice = String(localized: "声音不可用，请重新选择系统声音。"); return
        }
        guard !isBlocked else { notice = String(localized: "请先关闭当前操作再继续听书。"); return }
        willStart()
        guard let context = context() else { notice = String(localized: "这部分正文还未准备好"); return }
        let beginning = phase == .idle || !ownsPosition
        cancelQueue(); native?.silence()
        source = context; title = context.title
        if beginning { chapter = context.chapter }
        cursor = nil
        let offset = beginning ? context.offset : (safeOffset ?? context.offset)
        safeOffset = offset; publishedOffset = nil; nextOffset = offset; endOfText = false
        if beginning { following = .following }
        ownsPosition = true; notice = nil; phase = .preparing; previewing = false; previewID = nil
        if beginning { deadline = timerMinutes == 0 ? nil : Date().addingTimeInterval(Double(timerMinutes) * 60) }
        readabilityChanged()
        beginTimer()
        prepare(paragraphStart: beginning)
    }
    private func prepare(paragraphStart: Bool = false) {
        guard preparation == nil, running, let source, !endOfText, queue.count < 2 else { return }
        let generation = generation
        preparation = Task { [weak self] in
            guard let self else { return }
            var first = paragraphStart
            do {
                while running, queue.count < 2, !endOfText {
                    let result = try await read(source, nextOffset, first)
                    guard self.generation == generation, !Task.isCancelled, running else { return }
                    first = false
                    guard let segment = result.segment else {
                        endOfText = result.atEnd
                        if queue.isEmpty {
                            if endOfText { end(message: String(localized: "已到书末")) }
                            else { pause(message: String(localized: "这部分正文还未准备好")) }
                        }
                        break
                    }
                    if let expected = source.contentSHA, let actual = segment.contentSHA, expected != actual {
                        end(message: String(localized: "正文已变化，请重新打开小说。"), savePosition: false); return
                    }
                    guard segment.end > nextOffset || paragraphStart else {
                        pause(message: String(localized: "这部分正文还未准备好")); return
                    }
                    if queue.isEmpty {
                        try audio.activate()
                        phase = .playing; readabilityChanged(); publishMedia()
                    }
                    nextOffset = segment.end; queue.append(segment)
                    audio.speak(id: segment.id, text: segment.text.text, voice: voiceID!, rate: rate)
                }
            } catch is CancellationError { }
            catch { if self.generation == generation { pause(message: ReaderMessages.error(error)) } }
            if self.generation == generation { preparation = nil }
        }
    }
    func pause(message: String? = nil) {
        guard running || previewing else { if let message { notice = message }; return }
        checkpoint()
        cancelQueue(); native?.silence(); previewID = nil; previewing = false
        if active { phase = .paused }
        if let message { notice = message }
        publishMedia(); readabilityChanged(); flush()
    }
    func end(message: String? = nil, savePosition: Bool = true, returnToText: Bool = true) {
        guard active || previewing || native != nil else { return }
        if savePosition { checkpoint() }
        else { ownsPosition = false; safeOffset = nil; publishedOffset = nil }
        cancelQueue(); native?.finish(); native = nil
        phase = .idle; cursor = nil; previewID = nil; previewing = false; deadline = nil
        timer?.cancel(); timer = nil
        notice = message
        if savePosition, let safeOffset { ended(safeOffset, returnToText) }
        // The screen may still show an old page. Only explicit reader navigation
        // can hand the shared position back to that viewport, even after Stop.
        readabilityChanged(); if savePosition { flush() }
    }
    func userNavigated() {
        if previewing { pause() }
        guard ownsPosition else { return }
        if active { following = .detached }
        else { ownsPosition = false; safeOffset = nil; publishedOffset = nil }
    }
    func returnToSpeech() {
        guard active, ownsPosition else { return }
        following = .following; cursorChanged()
    }
    func sourceChanged() {
        guard active, let source else { return }
        guard let current = context(), current.bookID == source.bookID, current.generation == source.generation,
              source.contentSHA == nil || current.contentSHA == source.contentSHA else {
            end(message: String(localized: "正文已变化，请重新打开小说。"), savePosition: false); return
        }
    }
    func setRate(_ value: Float) {
        let value = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, value))
        guard value != rate else { return }
        if let segment = queue.first { safeOffset = segment.start }
        pause(message: active ? String(localized: "已调整，将从当前片段继续。") : nil)
        rate = value; defaults.set(value, forKey: "Moonread.listening.rate")
    }
    func selectVoice(_ voice: AVSpeechSynthesisVoice) {
        guard voice.identifier != voiceID else { return }
        if let segment = queue.first { safeOffset = segment.start }
        pause(message: active ? String(localized: "已调整，将从当前片段继续。") : nil)
        voiceID = voice.identifier; voiceLanguage = voice.language
        defaults.set(voiceID, forKey: "Moonread.listening.voice"); defaults.set(voiceLanguage, forKey: "Moonread.listening.language")
    }
    func setTimer(_ minutes: Int) {
        guard [0, 15, 30, 60].contains(minutes) else { return }
        timerMinutes = minutes
        deadline = active && minutes != 0 ? Date().addingTimeInterval(Double(minutes) * 60) : nil
    }
    func preview(_ voice: AVSpeechSynthesisVoice) {
        pause()
        do {
            try audio.activate()
            let id = UUID(); previewID = id; previewing = true
            // Original UI copy, never novel text. Same synthesizer and rate.
            audio.speak(id: id, text: String(localized: "你好，欢迎使用月读。愿每一个故事，都陪你度过一段好时光。"), voice: voice.identifier, rate: rate)
        } catch { notice = ReaderMessages.error(error) }
    }
    func stopPreview() { if previewing { pause() } }
    private func cancelQueue() {
        generation &+= 1; preparation?.cancel(); preparation = nil; queue.removeAll()
    }
    private func checkpoint() {
        guard ownsPosition, let safeOffset, publishedOffset != safeOffset else { return }
        publishedOffset = safeOffset; position(safeOffset)
    }
    private func beginTimer() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                tick()
            }
        }
    }
    func tick(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if let deadline, now >= deadline { end(message: String(localized: "定时已结束")); return }
        sourceChanged()
        checkPresentation()
        if running, uptime - lastCheckpoint >= 5 {
            lastCheckpoint = uptime; checkpoint()
        }
    }
    func checkPresentation() { if running && isBlocked { pause() } }
    private func publishMedia() {
        guard active else { return }
        native?.publish(ListeningMetadata(title: title, chapter: chapter, artwork: artwork), playing: phase == .playing)
    }
    func updateChapter(_ value: String) {
        guard chapter != value else { return }
        chapter = value; publishMedia()
    }
    func updateCover(title: String, sha: String?, author: String?, cover: BookCoverAsset?, service: AppDataService) {
        self.title = title; publishMedia()
        coverTask?.cancel()
        coverTask = Task { [weak self] in
            let image: UIImage?
            if let cover {
                do { image = try await service.coverImage(cover, pixels: 600) }
                catch { return } // Keep successful artwork until a replacement is ready.
            } else { image = nil }
            guard !Task.isCancelled, let self else { return }
            // This is the same cover view/rule used by reader, library and widgets.
            let renderer = ImageRenderer(content: SystemBookCover(title: title, contentSHA256: sha, author: author, userImage: image, rendersSynchronously: true).frame(width: 280, height: 392))
            renderer.scale = 2
            artwork = renderer.uiImage; publishMedia()
        }
    }
    private func received(_ event: ListeningAudioEvent) {
        if let deadline, Date() >= deadline { end(message: String(localized: "定时已结束")); return }
        switch event {
        case .command(let command):
            guard active else { return }
            switch command { case .play: start(); case .pause: pause(); case .stop: end(); case .toggle: if running { pause() } else { start() } }
        case .unavailableVoice: pause(message: String(localized: "声音不可用，请重新选择系统声音。"))
        case .interrupted: pause(message: String(localized: "播放已中断，点继续恢复。"))
        case .routeLost: pause(message: String(localized: "音频设备已断开，点继续恢复。"))
        case .reset: pause(message: String(localized: "音频服务已重置，点继续重试。"))
        case .finished(let id) where id == previewID:
            previewID = nil; previewing = false; native?.silence()
        case .cancelled(let id) where id == previewID:
            previewID = nil; previewing = false
        case .began(let id):
            guard running, let segment = queue.first, segment.id == id else { return }
            safeOffset = segment.start
            currentChapter = segment.chapter
            if let chapter = segment.chapter { updateChapter(chapter.title) }
            let length = segment.text.text.first?.utf16.count ?? 0
            if let unit = segment.sourceRange(NSRange(location: 0, length: length)) {
                cursor = ListeningCursor(sentence: SourceSpan(startUtf8: segment.start, endUtf8: segment.end), unit: unit)
                cursorChanged()
            }
        case .range(let id, let range):
            guard running, let segment = queue.first, segment.id == id, let unit = segment.sourceRange(range) else { return }
            cursor = ListeningCursor(sentence: SourceSpan(startUtf8: segment.start, endUtf8: segment.end), unit: unit)
            safeOffset = unit.startUtf8 // willSpeak is a conservative unit start, not heard coverage.
            cursorChanged()
        case .finished(let id):
            guard running, let segment = queue.first, segment.id == id else { return }
            if queue.count > 1 || !endOfText { safeOffset = segment.end }
            queue.removeFirst()
            if queue.isEmpty && endOfText { end(message: String(localized: "已到书末")) }
            else { prepare() }
        case .cancelled(let id):
            if running, queue.contains(where: { $0.id == id }) { pause(message: String(localized: "播放已中断，点继续恢复。")) }
        default: break
        }
    }
}
