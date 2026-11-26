import Foundation

public enum SystemReadingRouteError: LocalizedError, Equatable {
    case noRecent, unavailable, reconnect, contentChanged, searchDisabled
    public var errorDescription: String? {
        switch self {
        case .noRecent: String(localized: "打开一本书后，即可在这里继续。", table: "SystemReading")
        case .unavailable: String(localized: "找不到这本书的原文件，请在书架管理中重新连接来源。", table: "SystemReading")
        case .reconnect: String(localized: "请先在书架管理中重新连接这本书的来源。", table: "SystemReading")
        case .searchDisabled: String(localized: "这本书不在系统搜索范围内，请从书架打开。", table: "SystemReading")
        case .contentChanged: String(localized: "文件内容已变化，请从书架打开。", table: "SystemReading")
        }
    }
}
