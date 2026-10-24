import SwiftUI
import UIKit

enum ReaderMessages {
    static func error(_ error: Error, bundle: Bundle = .main) -> String {
        guard let error = error as? ReaderError else { return error.localizedDescription }
        switch error {
        case .Backup(let message): return String(localized: String.LocalizationValue(message), table: "DataManagement")
        case .IncompatibleStore: return String(localized: "数据早于支持的版本，暂时无法打开；原数据已保留。", bundle: bundle)
        case .StoreTooNew: return String(localized: "数据由更新版本的月读创建，请更新应用后再打开。", bundle: bundle)
        case .CloudAccountChanged: return String(localized: "账户已再次变化，请重新确认。", bundle: bundle)
        case .InvalidRange: return String(localized: "这段文字暂时无法操作，请重新选择较短的范围。", bundle: bundle)
        case .SearchPattern: return String(localized: "搜索表达式无效，请检查正则语法或改用普通文本。", bundle: bundle)
        case .SearchLineTooLong: return String(localized: "有一段文字过长，本次搜索已停止；已找到的结果仍可查看。", bundle: bundle)
        case .NotFound: return String(localized: "这条内容已不可用，请刷新后再试。", bundle: bundle)
        case .EmptyBook: return String(localized: "文件中还没有可阅读的正文。", bundle: bundle)
        case .SourceChanged: return String(localized: "原文件已变化，之前的正文和阅读位置已保留。", bundle: bundle)
        case .Decode: return String(localized: "正文编码无法识别，可以更换编码重新打开。", bundle: bundle)
        case .Storage: return String(localized: "暂时无法保存，请检查可用存储空间后重试。", bundle: bundle)
        case .Io: return String(localized: "暂时无法读取文件，请确认原目录仍可访问。", bundle: bundle)
        case .Paused: return String(localized: "准备已暂停，已读内容仍然保留。", bundle: bundle)
        case .ImportBusy: return String(localized: "正文仍在准备，请稍后再试。", bundle: bundle)
        case .InvalidSettings: return String(localized: "设置值无效，请重新选择。", bundle: bundle)
        case .TextCapacityExceeded: return String(localized: "正文超过可存储的范围，原文件和已读内容仍保留。", bundle: bundle)
        case .BinaryContent: return String(localized: "文件可能是二进制，或文字编码选择不正确；原文件已保留。", bundle: bundle)
        case .GraphemeTooLong: return String(localized: "文件中有过长的组合字符，无法安全读取。", bundle: bundle)
        }
    }
}
