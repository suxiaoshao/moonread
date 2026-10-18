import CloudKit
import CoreData
import SwiftUI

@MainActor @Observable
final class CloudStore {
    private let coordinator: CloudSyncCoordinator
    var status = CloudSyncStatus()
    var confirmationAccount: String?
    init(coordinator: CloudSyncCoordinator = .shared) { self.coordinator = coordinator }
    var busy = false
    var error: String?
    var libraryStatus = String(localized: "小说保存在本机")
    var conflictPath: String?
    var settingsSummary: String {
        if !status.requested { return String(localized: "阅读数据已关闭") }
        if !status.enabled { return String(localized: "阅读数据已暂停") }
        if status.message != nil { return String(localized: "阅读数据同步异常") }
        return String(localized: "阅读数据已开启")
    }
    func refresh() async { await coordinator.resume(); await updateStatus() }
    func updateStatus() async {
        status = await coordinator.currentStatus()
        if let account = confirmationAccount, status.accountToConfirm != account { confirmationAccount = nil }
        libraryStatus = await ReaderService.shared.cloudLibraryStatus()
        conflictPath = await ReaderService.shared.cloudConflictPath()
    }
    func replaceCloudFile(_ path: String) {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                try await ReaderService.shared.updateCloudLibrary(replacing: path)
                try await ReaderService.shared.prepareLibrary()
                try await ReaderService.shared.refreshLibrary()
                NotificationCenter.default.post(name: .libraryFilesChanged, object: nil)
            } catch { self.error = ReaderMessages.error(error) }
            await updateStatus()
        }
    }
    func setEnabled(_ enabled: Bool) {
        guard !busy else { return }; busy = true; status.requested = enabled
        Task { await setEnabledAndWait(enabled) }
    }
    /// First-run completion must await this operation before writing its marker.
    /// Unlike an interactive toggle, an already chosen setup value cannot be dropped.
    func setEnabledAndWait(_ enabled: Bool) async {
        busy = true; status.requested = enabled
        defer { busy = false }
        await coordinator.setEnabled(enabled)
        await updateStatus()
        if enabled { confirmationAccount = status.accountToConfirm }
    }
    func identityChanged() async { await coordinator.identityChanged(); await updateStatus() }
    func requestConfirmation() { confirmationAccount = status.accountToConfirm }
    func confirmAccount(_ account: String) {
        guard !busy else { return }; busy = true; confirmationAccount = nil
        Task {
            defer { busy = false }
            await coordinator.confirmAccount(account)
            await updateStatus()
        }
    }
    func retry() {
        guard !busy else { return }; busy = true
        Task { defer { busy = false }; await coordinator.resume(); await updateStatus() }
    }

}
