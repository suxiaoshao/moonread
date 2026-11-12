import CloudKit
import CoreData
import SwiftUI

enum CloudConfiguration {
    struct VerifiedAccount: Equatable, Sendable { let recordName: String }
    enum Consent: Sendable { case currentOwner, confirmedChange }
    case local
    case cloud(VerifiedAccount, Consent)

    static let containerID = "iCloud.dev.moonread.Moonread"
    static var availableInBuild: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return false }
        #endif
        return Bundle.main.object(forInfoDictionaryKey: "MoonreadCloudEnabled") as? String == "YES"
    }
}
extension Notification.Name {
    static let readingDataChanged = Notification.Name("Moonread.readingDataChanged")
    static let cloudDataReceived = Notification.Name("Moonread.cloudDataReceived")
    static let cloudStatusChanged = Notification.Name("Moonread.cloudStatusChanged")
}
enum CloudActivation: Sendable {
    case local
    case checking(revision: UUID)
    case awaitingAccountConfirmation(CloudConfiguration.VerifiedAccount, revision: UUID, message: String)
    case enabled(CloudConfiguration.VerifiedAccount, revision: UUID)
    case unavailable(String)
}
struct CloudSyncStatus: Sendable {
    var requested = false
    var activation = CloudActivation.local
    var syncing = false
    var lastSync: Date?
    var transportMessage: String?

    var enabled: Bool { if case .enabled = activation { true } else { false } }
    var accountToConfirm: String? {
        if case .awaitingAccountConfirmation(let account, _, _) = activation { account.recordName } else { nil }
    }
    var message: String? {
        switch activation {
        case .awaitingAccountConfirmation(_, _, let message), .unavailable(let message): message
        default: transportMessage
        }
    }
}

/// Device-local intent is a tiny thread-safe UserDefaults write, independent of
/// account lookup, store activation, and either service actor's work queue.
final class CloudSyncIntent: @unchecked Sendable {
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    var requested: Bool { defaults.bool(forKey: "Moonread.userCloudEnabled") }
    func set(_ enabled: Bool) { defaults.set(enabled, forKey: "Moonread.userCloudEnabled") }
}

/// Only account/configuration and framework event reporting live here. SwiftData
/// owns upload, download and retries; there is no second record transport.
actor CloudSyncCoordinator {
    static let shared = CloudSyncCoordinator()
    private let service: AppDataService
    private let available: Bool
    private let observeEvents: Bool
    private let account: @Sendable () async throws -> String?
    private var status = CloudSyncStatus()
    private var observing = false
    private var operation = UUID()

    init(service: AppDataService = .shared, available: Bool = CloudConfiguration.availableInBuild, observeEvents: Bool = true,
         account: @escaping @Sendable () async throws -> String? = {
             let container = CKContainer(identifier: CloudConfiguration.containerID)
             guard try await container.accountStatus() == .available else { throw CKError(.notAuthenticated) }
             return try await container.userRecordID().recordName
         }) {
        self.service = service; self.available = available; self.observeEvents = observeEvents; self.account = account
    }
    func currentStatus() -> CloudSyncStatus { status }
    private func publish() { NotificationCenter.default.post(name: .cloudStatusChanged, object: nil) }

    /// Only an explicit user toggle persists intent; lifecycle and errors never do.
    nonisolated func persistIntent(_ enabled: Bool) { service.cloudSyncIntent.set(enabled) }
    func setEnabled(_ enabled: Bool) async {
        persistIntent(enabled)
        await resume()
    }
    func identityChanged() async {
        operation = UUID()
        let current = operation
        status.activation = .checking(revision: current)
        status.syncing = false; status.lastSync = nil
        await service.setSystemReadingAccountPending(true)
        guard operation == current else { return }
        do { try await service.configureUserCloud(.local) }
        catch { if operation == current { status.transportMessage = Self.message(error) } }
        guard operation == current else { return }
        await resume()
    }
    func resume() async {
        operation = UUID()
        let current = operation
        let requested = await service.cloudSyncRequested()
        guard operation == current else { return }
        status.requested = requested
        status.activation = .checking(revision: current)
        status.syncing = false
        publish()
        if !status.requested {
            await pause(current, message: nil); return
        }
        guard available else {
            await pause(current, message: String(localized: "此构建不支持 iCloud 阅读数据同步。")); return
        }
        if observeEvents && !observing {
            observing = true
            Task { [weak self] in
                for await notification in NotificationCenter.default.notifications(named: NSPersistentCloudKitContainer.eventChangedNotification) {
                    guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { continue }
                    await self?.receivedEvent(event)
                }
            }
        }
        do {
            guard let target = try await account() else { throw CKError(.notAuthenticated) }
            guard operation == current else { return }
            let owner = await service.userCloudOwner()
            guard operation == current else { return }
            if let owner, owner != target {
                await pause(current, message: String(localized: "iCloud 账户已变化，阅读数据同步已暂停。"), account: target)
                return
            }
            // Recheck the concrete account immediately before enabling its mirror.
            guard try await account() == target else { throw ReaderError.CloudAccountChanged }
            guard operation == current else { return }
            try await enable(.init(recordName: target), consent: .currentOwner, revision: current)
        } catch {
            guard operation == current else { return }
            await pause(current, message: Self.message(error))
        }
    }
    func confirmAccount(_ target: String) async {
        guard status.requested, status.accountToConfirm == target else { return }
        operation = UUID()
        let current = operation
        status.activation = .checking(revision: current)
        do {
            guard await service.cloudSyncRequested(), operation == current else { return }
            let first = try await account()
            guard operation == current else { return }
            guard first == target else {
                await pause(current, message: String(localized: "账户已再次变化，请重新确认。"), account: first); return
            }
            let verified = try await account()
            guard operation == current else { return }
            guard verified == target else {
                await pause(current, message: String(localized: "账户已再次变化，请重新确认。"), account: verified); return
            }
            try await enable(.init(recordName: target), consent: .confirmedChange, revision: current)
        } catch {
            guard operation == current else { return }
            await pause(current, message: Self.message(error))
        }
    }
    private func enable(_ account: CloudConfiguration.VerifiedAccount, consent: CloudConfiguration.Consent, revision: UUID) async throws {
        guard operation == revision else { return }
        try await service.configureUserCloud(.cloud(account, consent))
        guard operation == revision else { return }
        await service.setSystemReadingAccountPending(false)
        guard operation == revision else { return }
        if case .confirmedChange = consent { status.lastSync = nil }
        status.activation = .enabled(account, revision: revision)
        status.transportMessage = nil; publish()
    }
    private func pause(_ current: UUID, message: String?, account: String? = nil) async {
        guard operation == current else { return }
        if account != nil {
            await service.setSystemReadingAccountPending(true)
            guard operation == current else { return }
        }
        var reason = message
        do { try await service.configureUserCloud(.local) }
        catch {
            guard operation == current else { return }
            reason = Self.message(error)
        }
        guard operation == current else { return }
        await service.setSystemReadingAccountPending(account != nil)
        guard operation == current else { return }
        if let account, let reason {
            status.activation = .awaitingAccountConfirmation(.init(recordName: account), revision: current, message: reason)
        } else if let reason {
            status.activation = .unavailable(reason)
        } else {
            status.activation = .local
        }
        status.syncing = false
        status.transportMessage = nil; publish()
    }
    private func receivedEvent(_ event: NSPersistentCloudKitContainer.Event) async {
        guard status.enabled else { return }
        status.syncing = event.endDate == nil
        if let error = event.error {
            if (error as? CKError)?.code == .notAuthenticated { await identityChanged(); return }
            status.transportMessage = Self.message(error)
        }
        else if let end = event.endDate, event.succeeded {
            status.lastSync = end; status.transportMessage = nil
            if event.type == .import {
                await service.receivedUserImport()
                NotificationCenter.default.post(name: .cloudReadingPositionsReceived, object: nil)
                NotificationCenter.default.post(name: .cloudDataReceived, object: nil)
                NotificationCenter.default.post(name: .statisticsChanged, object: nil, userInfo: ["reset": true])
                NotificationCenter.default.post(name: .bookMetadataChanged, object: nil)
            }
        }
        publish()
    }
    func localDataChanged() {} // Saves are already owned by the SwiftData store.
    static func message(_ error: Error) -> String {
        if let error = error as? CKError {
            switch error.code {
            case .notAuthenticated: return String(localized: "请先在系统设置中登录 iCloud。")
            case .networkFailure, .networkUnavailable: return String(localized: "暂时无法连接 iCloud，阅读数据同步未完成。")
            case .quotaExceeded: return String(localized: "iCloud 空间不足，阅读数据同步未完成。")
            default: break
            }
        }
        return ReaderMessages.error(error)
    }
}
extension AppDataService {
    func cloudSyncRequested() -> Bool { cloudSyncIntent.requested }
    func setCloudSyncRequested(_ requested: Bool) { cloudSyncIntent.set(requested) }
    func userCloudOwner() -> String? { sourceDefaults.string(forKey: "Moonread.userOwner") }
    func dataChanged() { scheduleSystemReadingCatalog(); NotificationCenter.default.post(name: .readingDataChanged, object: nil) }
}
