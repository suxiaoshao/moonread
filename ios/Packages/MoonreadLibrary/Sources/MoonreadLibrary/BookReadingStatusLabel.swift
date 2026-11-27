import MoonreadCoreBindings
import SwiftUI

public extension BookReadingStatus {
    var label: LocalizedStringKey {
        switch self { case .unread: "未读"; case .reading: "阅读中"; case .finished: "读完"; case .paused: "暂搁"; case .other: "其他（当前版本不支持）" }
    }
}
