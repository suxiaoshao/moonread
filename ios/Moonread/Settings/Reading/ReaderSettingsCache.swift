import Foundation

/// Only tiny, validated reading settings cross this lock. Opening never queues behind database work.
final class ReaderSettingsCache: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: UserDefaults
    private var value: Result<ReaderSettings, Error>
    private var observer: NSObjectProtocol?
    init(defaults: UserDefaults) {
        self.defaults = defaults
        value = Result { try defaults.string(forKey: "Moonread.readerSettings").map { try decodeReaderSettings(json: $0) } ?? defaultReaderSettings() }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { @Sendable [weak self] _ in self?.reload() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func reload() {
        let next = Result { try defaults.string(forKey: "Moonread.readerSettings").map { try decodeReaderSettings(json: $0) } ?? defaultReaderSettings() }
        lock.lock(); value = next; lock.unlock()
    }
    func get() throws -> ReaderSettings { lock.lock(); defer { lock.unlock() }; return try value.get() }
    func set(_ settings: ReaderSettings) { lock.lock(); value = .success(settings); lock.unlock() }
}
