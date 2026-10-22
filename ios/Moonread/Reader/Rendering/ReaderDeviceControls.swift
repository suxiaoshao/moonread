import UIKit

/// Platform effects are leased only while the reader's scene is active.
@MainActor
final class ReaderDeviceControls {
    private static var orientations: [String: UIInterfaceOrientationMask] = [:]
    private static var awakeLeases: Set<UUID> = []
    private static var previousIdleSetting = false
    struct Effects {
        var awake: (Bool) -> Void
        var orientation: (ReadingOrientation?) -> Void
    }
    private let effects: Effects?
    init(effects: Effects? = nil) { self.effects = effects }
    func sceneActive(_ value: Bool) { if value { activate() } else { suspend() } }
    private let lease = UUID()
    private weak var scene: UIWindowScene?
    private var observers: [NSObjectProtocol] = []
    private var active = false
    private var originalBrightness: CGFloat?
    private var expectedBrightness: CGFloat?
    private var settings = defaultReaderSettings()
    var brightnessChanged: (Double) -> Void = { _ in }
    var orientationFailed: () -> Void = {}

    static func orientationMask(for scene: UIWindowScene?) -> UIInterfaceOrientationMask {
        if let scene, let mask = orientations[scene.session.persistentIdentifier] { return mask }
        return UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    func update(_ value: ReaderSettings) {
        let previous = settings
        settings = value
        guard active else { return }
        if previous.keepAwake != value.keepAwake { setAwake(value.keepAwake) }
        if previous.brightness != value.brightness { applyBrightness() }
        if previous.orientation != value.orientation { applyOrientation() }
    }

    func start(in scene: UIWindowScene?) {
        guard self.scene == nil, let scene else { return }
        self.scene = scene
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIScene.didActivateNotification, object: scene, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.activate() }
        })
        observers.append(center.addObserver(forName: UIScene.willDeactivateNotification, object: scene, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspend() }
        })
        observers.append(center.addObserver(forName: UIScreen.brightnessDidChangeNotification, object: scene.screen, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.observeBrightness() }
        })
        if scene.activationState == .foregroundActive { activate() }
    }

    func stop() {
        suspend()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        scene = nil
    }

    private func activate() {
        guard !active else { return }
        active = true
        setAwake(settings.keepAwake)
        applyBrightness()
        applyOrientation()
    }

    private func suspend() {
        guard active else { return }
        active = false
        setAwake(false)
        restoreBrightness()
        effects?.orientation(nil)
        if let scene {
            Self.orientations.removeValue(forKey: scene.session.persistentIdentifier)
            scene.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        }
    }

    private func setAwake(_ enabled: Bool) {
        if let effects { effects.awake(enabled); return }
        if enabled {
            if Self.awakeLeases.isEmpty { Self.previousIdleSetting = UIApplication.shared.isIdleTimerDisabled }
            Self.awakeLeases.insert(lease)
            UIApplication.shared.isIdleTimerDisabled = true
        } else if Self.awakeLeases.remove(lease) != nil, Self.awakeLeases.isEmpty {
            UIApplication.shared.isIdleTimerDisabled = Self.previousIdleSetting
        }
    }

    private func applyBrightness() {
        guard let screen = scene?.screen else { return }
        guard let brightness = settings.brightness else { restoreBrightness(); return }
        if originalBrightness == nil { originalBrightness = screen.brightness }
        expectedBrightness = CGFloat(brightness)
        if abs(screen.brightness - CGFloat(brightness)) > 0.002 { screen.brightness = CGFloat(brightness) }
    }

    private func restoreBrightness() {
        guard let screen = scene?.screen, let original = originalBrightness else { return }
        // Preserve an external adjustment even if its notification has not run yet.
        if let expected = expectedBrightness, abs(screen.brightness - expected) < 0.003 {
            expectedBrightness = original
            screen.brightness = original
        }
        originalBrightness = nil
    }

    private func observeBrightness() {
        guard let screen = scene?.screen, settings.brightness != nil else { return }
        let value = screen.brightness
        if let expectedBrightness, abs(value - expectedBrightness) < 0.003 { return }
        expectedBrightness = nil
        if active { originalBrightness = value }
        guard settings.brightness != Double(value) else { return }
        settings.brightness = Double(value)
        brightnessChanged(Double(value))
    }

    private func applyOrientation() {
        if let effects { effects.orientation(settings.orientation); return }
        guard let scene else { return }
        let mask: UIInterfaceOrientationMask
        switch settings.orientation {
        case .system: mask = UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
        case .portrait: mask = .portrait
        case .landscape: mask = .landscape
        }
        Self.orientations[scene.session.persistentIdentifier] = mask
        scene.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        let requested = settings.orientation
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active, self.settings.orientation == requested, requested != .system else { return }
                self.orientationFailed()
            }
        }
    }
}
