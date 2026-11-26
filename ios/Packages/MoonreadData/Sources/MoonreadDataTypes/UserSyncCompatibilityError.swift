import Foundation

/// A read barrier, not a lossy repair. Quarantined records remain in SwiftData unchanged.
public struct UserSyncCompatibilityError: LocalizedError, Sendable {
    public enum Reason: Sendable { case newerFormat, unreadable }
    public var statistics = false
    public let reason: Reason
    public init(statistics: Bool = false, reason: Reason = .unreadable) {
        self.statistics = statistics
        self.reason = reason
    }

    public var errorDescription: String? {
        if reason == .unreadable { return String(localized: "阅读数据无法读取，原始记录已保留。", table: "DataManagement") }
        return statistics ? String(localized: "统计数据来自更新版本，请更新 App。") :
            String(localized: "部分阅读数据当前版本无法理解，已保留并设为只读，请更新 App。")
    }
}
