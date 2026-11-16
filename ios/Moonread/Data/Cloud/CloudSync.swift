import Foundation

enum CloudConfiguration {
    struct VerifiedAccount: Equatable, Sendable { let recordName: String }
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

/// Step 5 keeps the previous intent without running a transport or changing
/// the confirmed owner. iCloud Drive discovery is independent of this state.
actor CloudSyncCoordinator {
    static let shared = CloudSyncCoordinator()
    private let service: AppDataService
    private var status = CloudSyncStatus()

    init(service: AppDataService = .shared) { self.service = service }
    func currentStatus() -> CloudSyncStatus { status }

    nonisolated func persistIntent(_ enabled: Bool) { service.cloudSyncIntent.set(enabled) }

    func resume() async {
        status.requested = service.cloudSyncIntent.requested
        status.activation = status.requested
            ? .unavailable(String(localized: "此版本暂不进行阅读数据 iCloud 同步，已保存的数据仍可在本机使用。"))
            : .local
        // An earlier confirmed account remains usable in the app even
        // without verification. Do not republish that account externally
        // while its saved sync intent is waiting for the new transport.
        await service.refreshOfflineSystemReadingPolicy()
        NotificationCenter.default.post(name: .cloudStatusChanged, object: nil)
    }

    func identityChanged() async { await resume() }
}
extension AppDataService {
    func cloudSyncRequested() -> Bool { cloudSyncIntent.requested }
    func setCloudSyncRequested(_ requested: Bool) { cloudSyncIntent.set(requested) }
    func userCloudOwner() -> String? { sourceDefaults.string(forKey: "Moonread.userOwner") }
    func dataChanged() {
        NotificationCenter.default.post(name: .readingDataChanged, object: nil)
    }
}
