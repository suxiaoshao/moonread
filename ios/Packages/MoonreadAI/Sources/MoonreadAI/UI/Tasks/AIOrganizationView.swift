import SwiftUI

extension AIOrganizationConflict {
    var label: String {
        switch self {
        case .invalidName: String(localized: "名称不可用")
        case .outsideScope: String(localized: "超出整理范围")
        case .duplicate: String(localized: "同名项目")
        case .cycle: String(localized: "目录循环")
        case .occupied: String(localized: "目标已有同名文件")
        case .changed: String(localized: "已变化")
        case .dependency: String(localized: "所在新文件夹未包含")
        case .unavailable: String(localized: "暂时无法访问")
        }
    }
}
extension AIFileExecutionStage {
    var label: String {
        switch self {
        case .completed: String(localized: "已完成")
        case .notMoved: String(localized: "未执行")
        case .movedButIndexFailed: String(localized: "已移动，书架记录未更新")
        case .copiedSourceRemains: String(localized: "已复制，原文件仍在")
        case .uncertain: String(localized: "未能确认")
        }
    }
}
