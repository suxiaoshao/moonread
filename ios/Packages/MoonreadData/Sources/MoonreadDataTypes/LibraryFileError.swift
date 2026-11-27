import Foundation

public enum LibraryFileError: LocalizedError {
    case conflict(String), invalidDestination, missingShelf, unsupportedFile, trashUnsupported, fileWorkBusy
    public var errorDescription: String? {
        switch self {
        case .conflict(let name): String(localized: "目标目录中已有“\(name)”。")
        case .invalidDestination: String(localized: "无法使用这个名称或目标目录。")
        case .missingShelf: String(localized: "书架暂时不可用，请重新连接。")
        case .unsupportedFile: String(localized: "请选择 TXT 小说文件。")
        case .trashUnsupported: String(localized: "所在位置不支持最近删除。")
        case .fileWorkBusy: String(localized: "文件操作正在进行，请稍后再试。")
        }
    }
}
