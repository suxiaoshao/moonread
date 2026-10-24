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
    /// Display existing facts together; this does not change coordinator state.
    var syncTitle: String {
        if busy && status.syncing { return String(localized: "正在处理并同步") }
        if busy { return String(localized: "正在处理") }
        if status.syncing { return String(localized: "正在同步") }
        if status.accountToConfirm != nil { return String(localized: "需要确认同步账户") }
        if status.requested && !status.enabled { return String(localized: "阅读数据同步已暂停") }
        if status.message != nil { return String(localized: "同步需要处理") }
        return String(localized: status.enabled ? "阅读数据同步已开启" : "阅读数据同步已关闭")
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
        guard !busy else { return }
        saveIntroductionChoice(enabled)
    }
    /// Persist before returning; activation must never hold the introduction open.
    /// A chosen setup value is not dropped when unrelated cloud work is busy.
    @discardableResult func saveIntroductionChoice(_ enabled: Bool) -> Task<Void, Never> {
        coordinator.persistIntent(enabled)
        busy = true; status.requested = enabled
        return Task {
            defer { busy = false }
            await coordinator.resume()
            await updateStatus()
            if enabled { confirmationAccount = status.accountToConfirm }
        }
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
