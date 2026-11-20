import SwiftUI

/// App-wide reader preferences. Views and reading sessions never keep writable copies.
@MainActor @Observable
final class ReaderSettingsStore {
    static let shared = ReaderSettingsStore(service: .shared)

    private(set) var value: ReaderSettings?
    var error: String?
    var fontNotice: String?
    private var lastMissingBuiltin: ReaderFont?
    private let service: AppDataService
    @ObservationIgnored private let persist: (ReaderSettings) async throws -> Void
    private(set) var fontSaving = false
    private var pending: ReaderSettings?
    private var writeTask: Task<Void, Never>?

    init(service: AppDataService, persist: ((ReaderSettings) async throws -> Void)? = nil) {
        self.service = service
        self.persist = persist ?? { try await service.saveSettings($0) }
    }

    func load() throws {
        guard value == nil else { return }
        ReaderFontLibrary.shared.loadIfNeeded()
        value = try service.settings()
        refreshBuiltinFonts()
    }

    var binding: Binding<ReaderSettings> {
        Binding(get: { self.value ?? defaultReaderSettings() }, set: { self.update($0) })
    }

    func update(_ next: ReaderSettings) {
        guard next != value else { return }
        value = next
        pending = next
        startPendingWrite()
    }

    private func startPendingWrite() {
        guard writeTask == nil, !fontSaving, pending != nil else { return }
        writeTask = Task {
            defer { writeTask = nil }
            // Finish the in-flight write, then persist the newest pending edit.
            while let next = pending {
                pending = nil
                do { try await persist(next) }
                catch { self.error = ReaderMessages.error(error) }
            }
        }
    }

    /// Font changes publish only after durable save. Other preference edits can
    /// still coalesce, but cannot race a stale font reference back into storage.
    func selectFont(_ choice: ReaderFontChoice) async throws {
        guard !fontSaving else { throw ReaderFontFailure.busy }
        fontSaving = true
        defer { fontSaving = false; startPendingWrite() }
        await flush()
        var next = value ?? defaultReaderSettings()
        next.setFontChoice(choice)
        try await persist(next)
        var latest = value ?? next
        latest.setFontChoice(choice)
        value = latest
        if pending != nil { pending = latest }
        refreshBuiltinFonts()
    }

    func selectBuiltinFont(_ font: ReaderFont, fonts: ReaderBuiltinFonts = .shared, progress: (Double) -> Void = { _ in }) async throws {
        try await fonts.prepare(font, progress: progress)
        try Task.checkCancellation()
        try await selectFont(.builtin(font: font))
    }

    func refreshBuiltinFonts() {
        let fonts = ReaderBuiltinFonts.shared
        fonts.refresh()
        let missing: ReaderFont? = if case .builtin(let font) = value?.fontChoice, !fonts.isAvailable(font) { font } else { nil }
        if missing != lastMissingBuiltin {
            lastMissingBuiltin = missing
            fontNotice = missing == nil ? nil : String(localized: "当前字体需要重新下载，已暂用系统字体。请在阅读设置中重新选择宋体或圆体。")
        }
    }

    func flush() async { await writeTask?.value }
}
