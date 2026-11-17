import SwiftUI

@MainActor @Observable
final class CloudStore {
    private let coordinator: CloudSyncCoordinator
    var status = CloudSyncStatus()
    var confirmationAccount: String?
    private var confirmationRevision: UUID?
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
        await updateReadingStatus()
        libraryStatus = await AppDataService.shared.cloudLibraryStatus()
        conflictPath = await AppDataService.shared.cloudConflictPath()
    }
    func updateReadingStatus() async {
        status = await coordinator.currentStatus()
        guard confirmationAccount != nil else { return }
        if case .awaitingAccountConfirmation(let account, let revision, _) = status.activation,
           revision == confirmationRevision, account.recordName == confirmationAccount { return }
        confirmationAccount = nil; confirmationRevision = nil
    }
    func replaceCloudFile(_ path: String) {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                try await AppDataService.shared.updateCloudLibrary(replacing: path)
                try await AppDataService.shared.prepareLibrary()
                try await AppDataService.shared.refreshLibrary()
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
        }
    }
    func identityChanged() async { await coordinator.identityChanged(); await updateStatus() }
    func scene(active: Bool) async { await coordinator.scene(active: active); await updateStatus() }
    func localDataChanged() async { await coordinator.localDataChanged() }
    func requestConfirmation() {
        guard case .awaitingAccountConfirmation(let account, let revision, _) = status.activation else { return }
        confirmationAccount = account.recordName; confirmationRevision = revision
    }
    func confirmAccount(_ account: String) {
        guard !busy, let revision = confirmationRevision else { return }
        busy = true; confirmationAccount = nil; confirmationRevision = nil
        Task {
            defer { busy = false }
            await coordinator.confirmAccount(account, revision: revision)
            await updateStatus()
        }
    }
    func retry() {
        guard !busy else { return }
        busy = true
        Task { defer { busy = false }; await refresh() }
    }
}
