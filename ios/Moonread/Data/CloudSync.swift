import CloudKit
import CoreData
import SwiftUI

enum CloudConfiguration {
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
struct CloudSyncStatus: Sendable {
    var requested = false
    var enabled = false
    var accountToConfirm: String?
    var syncing = false
    var lastSync: Date?
    var message: String?
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
        await service.setSystemReadingAccountPending(true)
        operation = UUID()
        let current = operation
        do { try await service.configureUserCloud(false, account: nil) }
        catch { if operation == current { status.message = Self.message(error) } }
        guard operation == current else { return }
        status.enabled = false; status.syncing = false; status.lastSync = nil
        await resume()
    }
    func resume() async {
        operation = UUID()
        let current = operation
        status.requested = await service.cloudSyncRequested()
        guard operation == current else { return }
        publish()
        if !status.requested {
            await service.setSystemReadingAccountPending(false)
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
            try await service.configureUserCloud(true, account: target)
            await service.setSystemReadingAccountPending(false)
            guard operation == current else { return }
            status.enabled = true; status.accountToConfirm = nil; status.message = nil; publish()
        } catch {
            guard operation == current else { return }
            await pause(current, message: Self.message(error))
        }
    }
    func confirmAccount(_ target: String) async {
        guard status.requested, status.accountToConfirm == target else { return }
        operation = UUID()
        let current = operation
        do {
            guard await service.cloudSyncRequested() else { return }
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
            try await service.configureUserCloud(true, account: target, allowAccountChange: true)
            await service.setSystemReadingAccountPending(false)
            guard operation == current else { return }
            status.enabled = true; status.accountToConfirm = nil; status.message = nil; status.lastSync = nil; publish()
        } catch {
            guard operation == current else { return }
            await pause(current, message: Self.message(error))
        }
    }
    private func pause(_ current: UUID, message: String?, account: String? = nil) async {
        if account != nil { await service.setSystemReadingAccountPending(true) }
        var reason = message
        do { try await service.configureUserCloud(false, account: nil) }
        catch {
            guard operation == current else { return }
            reason = Self.message(error)
        }
        guard operation == current else { return }
        await service.setSystemReadingAccountPending(account != nil)
        guard operation == current else { return }
        status.enabled = false; status.syncing = false; status.accountToConfirm = account
        status.message = reason; publish()
    }
    private func receivedEvent(_ event: NSPersistentCloudKitContainer.Event) async {
        guard status.enabled else { return }
        status.syncing = event.endDate == nil
        if let error = event.error {
            if (error as? CKError)?.code == .notAuthenticated { await identityChanged(); return }
            status.message = Self.message(error)
        }
        else if let end = event.endDate, event.succeeded {
            status.lastSync = end; status.message = nil
            if event.type == .import {
                await service.receivedUserImport()
                NotificationCenter.default.post(name: .cloudReadingPositionsReceived, object: nil)
                NotificationCenter.default.post(name: .cloudDataReceived, object: nil)
                NotificationCenter.default.post(name: .statisticsChanged, object: nil)
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
