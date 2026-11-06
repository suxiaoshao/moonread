import AVFoundation
import Combine
import MediaPlayer
import UIKit

enum ListeningCommand: Sendable { case play, pause, stop, toggle }
enum ListeningAudioEvent: Sendable {
    case began(UUID), range(UUID, NSRange), finished(UUID), cancelled(UUID)
    case interrupted, routeLost, reset, unavailableVoice, command(ListeningCommand)
}
struct ListeningMetadata {
    let title: String
    let chapter: String
    let artwork: UIImage?
}
@MainActor protocol ListeningAudio: AnyObject {
    var event: ((ListeningAudioEvent) -> Void)? { get set }
    func activate() throws
    func speak(id: UUID, text: String, voice: String, rate: Float)
    func silence()
    func publish(_ metadata: ListeningMetadata, playing: Bool)
    func finish()
}

/// Apple SDK ownership only; queue generations and source coordinates belong to
/// ListeningSession. A cancelled native utterance cannot acquire a new ID.
@MainActor final class SystemListeningAudio: NSObject, ListeningAudio, AVSpeechSynthesizerDelegate {
    var event: ((ListeningAudioEvent) -> Void)?
    private var synthesizer = AVSpeechSynthesizer()
    private var items: [ObjectIdentifier: UUID] = [:]
    private var observers: Set<AnyCancellable> = []
    private var commands: [(MPRemoteCommand, Any)] = []
    private var active = false
    private var publishesMedia = false
    override init() {
        super.init()
        configureSynthesizer()
        if #available(iOS 27, *) {
            // iOS 27 replaces interruption begin/end with session lifecycle.
            // A resumption recommendation never starts playback automatically.
            observe(AVAudioSession.didBecomeInactiveNotification) { [weak self] _ in
                MainActor.assumeIsolated { if self?.active == true { self?.event?(.interrupted) } }
            }
        } else {
            observe(AVAudioSession.interruptionNotification) { [weak self] note in
                let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
                MainActor.assumeIsolated { if began { self?.event?(.interrupted) } }
            }
        }
        observe(AVAudioSession.routeChangeNotification) { [weak self] note in
            let lost = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            MainActor.assumeIsolated { if lost { self?.event?(.routeLost) } }
        }
        observe(AVAudioSession.mediaServicesWereResetNotification) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.active = false; self.items.removeAll(); self.synthesizer = AVSpeechSynthesizer(); self.configureSynthesizer()
                self.event?(.reset)
            }
        }
    }
    private func observe(_ name: Notification.Name, receive: @escaping (Notification) -> Void) {
        NotificationCenter.default.publisher(for: name, object: AVAudioSession.sharedInstance())
            .receive(on: DispatchQueue.main).sink(receiveValue: receive).store(in: &observers)
    }
    private func configureSynthesizer() {
        synthesizer.delegate = self; synthesizer.usesApplicationAudioSession = true
    }
    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        active = true
    }
    func speak(id: UUID, text: String, voice: String, rate: Float) {
        guard let selected = AVSpeechSynthesisVoice(identifier: voice) else { event?(.unavailableVoice); return }
        let item = AVSpeechUtterance(string: text)
        item.voice = selected; item.rate = rate
        item.preUtteranceDelay = 0; item.postUtteranceDelay = 0
        items[ObjectIdentifier(item)] = id
        synthesizer.speak(item)
    }
    func silence() {
        items.removeAll(); synthesizer.stopSpeaking(at: .immediate)
        if active {
            active = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    func publish(_ metadata: ListeningMetadata, playing: Bool) {
        if commands.isEmpty { registerCommands() }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: metadata.title, MPMediaItemPropertyArtist: metadata.chapter,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if let image = metadata.artwork { info[MPMediaItemPropertyArtwork] = Self.artwork(image) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info; publishesMedia = true
    }
    // MediaPlayer calls both handlers from its own queues. Construct closures
    // outside actor isolation: artwork reads an immutable image; intents hop in.
    private nonisolated static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
    private nonisolated static func remoteHandler(_ command: ListeningCommand, owner: SystemListeningAudio) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { [weak owner] _ in
            Task { @MainActor [weak owner] in owner?.event?(.command(command)) }
            return .success
        }
    }
    private func registerCommands() {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        let center = MPRemoteCommandCenter.shared()
        for (command, intent) in [(center.playCommand, ListeningCommand.play), (center.pauseCommand, .pause), (center.stopCommand, .stop), (center.togglePlayPauseCommand, .toggle)] {
            command.isEnabled = true
            let token = command.addTarget(handler: Self.remoteHandler(intent, owner: self))
            commands.append((command, token))
        }
        for command in [center.nextTrackCommand, center.previousTrackCommand, center.skipForwardCommand, center.skipBackwardCommand, center.changePlaybackPositionCommand] { command.isEnabled = false }
    }
    func finish() {
        silence()
        for (command, token) in commands { command.removeTarget(token) }
        if !commands.isEmpty { UIApplication.shared.endReceivingRemoteControlEvents() }
        commands.removeAll()
        if publishesMedia { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; publishesMedia = false }
    }
    private nonisolated func send(_ utterance: AVSpeechUtterance, event: @escaping @MainActor (UUID) -> ListeningAudioEvent) {
        let object = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let id = items[object] else { return }
            let value = event(id)
            if case .finished = value { items[object] = nil }
            if case .cancelled = value { items[object] = nil }
            self.event?(value)
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) { send(utterance) { .began($0) } }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) { send(utterance) { .range($0, range) } }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { send(utterance) { .finished($0) } }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { send(utterance) { .cancelled($0) } }
}
