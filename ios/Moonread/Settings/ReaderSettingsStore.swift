import SwiftUI

/// App-wide reader preferences. Views and reading sessions never keep writable copies.
@MainActor @Observable
final class ReaderSettingsStore {
    static let shared = ReaderSettingsStore(service: .shared)

    private(set) var value: ReaderSettings?
    var error: String?
    private let service: AppDataService
    private var pending: ReaderSettings?
    private var writeTask: Task<Void, Never>?

    init(service: AppDataService) { self.service = service }

    func load() throws {
        guard value == nil else { return }
        value = try service.settings()
    }

    var binding: Binding<ReaderSettings> {
        Binding(get: { self.value ?? defaultReaderSettings() }, set: { self.update($0) })
    }

    func update(_ next: ReaderSettings) {
        guard next != value else { return }
        value = next
        pending = next
        guard writeTask == nil else { return }
        writeTask = Task {
            defer { writeTask = nil }
            // Finish the in-flight write, then persist the newest pending edit.
            while let next = pending {
                pending = nil
                do { try await service.saveSettings(next) }
                catch { self.error = ReaderMessages.error(error) }
            }
        }
    }

    func flush() async { await writeTask?.value }
}
