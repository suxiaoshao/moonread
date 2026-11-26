import MoonreadReader
import MoonreadData
import SwiftUI

/// A projection of the current coordinator status, with account state first.
enum CloudSyncCard: Equatable {
    case off, checking, confirmAccount, signedOut
    case unavailable(CloudSyncIssue), error(CloudSyncIssue)
    case syncing, firstUpload(CloudInitialUploadProgress?), firstDownload(Int?), finishing
    case waitingForDevice, waiting, synced(Date)

    init(_ status: CloudSyncStatus) {
        guard status.requested else { self = .off; return }
        switch status.activation {
        case .local: self = .waiting; return
        case .checking: self = .checking; return
        case .awaitingAccountConfirmation: self = .confirmAccount; return
        case .signedOut: self = .signedOut; return
        case .unavailable(let issue): self = .unavailable(issue); return
        case .enabled: break
        }
        if let issue = status.transportIssue { self = .error(issue); return }
        if status.phase == .waitingForDevice { self = .waitingForDevice; return }
        if status.syncing {
            switch status.phase {
            case .firstUpload(let progress): self = .firstUpload(progress)
            case .firstDownload(let count): self = .firstDownload(count)
            case .finishing: self = .finishing
            default: self = .syncing
            }
        } else if let lastSync = status.lastSync { self = .synced(lastSync) }
        else { self = .waiting }
    }
}

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
        if status.transportIssue != nil { return String(localized: "阅读数据同步异常") }
        return String(localized: "阅读数据已开启")
    }
    var syncCard: CloudSyncCard { .init(status) }
    func refresh() async { await coordinator.resume(); await updateStatus() }
    func updateStatus() async {
        await updateReadingStatus()
        libraryStatus = await AppDataService.shared.cloudLibraryStatus()
        conflictPath = await AppDataService.shared.cloudConflictPath()
    }
    func updateReadingStatus() async {
        status = await coordinator.currentStatus()
        guard confirmationAccount != nil else { return }
        if case .awaitingAccountConfirmation(let account, let revision) = status.activation,
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
        guard case .awaitingAccountConfirmation(let account, let revision) = status.activation else { return }
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
