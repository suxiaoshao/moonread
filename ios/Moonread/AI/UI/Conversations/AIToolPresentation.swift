import Foundation
import AISDKProvider

/// One mapping for process rows, details and the reading moon. Model text never supplies icons.
enum AIToolPresentation {
    static func groupTitle(_ names: [String]) -> String {
        let books: Set<String> = ["search_books", "get_book", "get_chapters", "read", "rg", "get_marks", "get_mark"]
        if names.allSatisfy({ books.contains($0) }) { return String(localized: "查询书籍") }
        if Set(names).count == 1, let name = names.first { return title(name) }
        return String(localized: "工具调用")
    }
    static func title(_ name: String, output: JSONValue? = nil) -> String {
        switch name {
        case "web_search": String(localized: "搜索网页")
        case "generate_image": String(localized: "生成图片")
        case "ls": String(localized: "浏览书架")
        case "search_books": String(localized: "查找书籍")
        case "get_book": String(localized: "查看书籍资料")
        case "get_chapters": String(localized: "查看目录")
        case "read": String(localized: "阅读正文")
        case "rg": String(localized: "搜索正文")
        case "get_marks": String(localized: "查看书签与批注")
        case "get_mark": output?.object["data"]?.object["kind"]?.string == "bookmark" ? String(localized: "查看书签") : String(localized: "查看批注")
        case "get_reading_statistics": String(localized: "查看阅读统计")
        case "get_environment": String(localized: "获取时间与语言")
        case "find_cover": String(localized: "查找封面")
        case "propose_cover": String(localized: "封面候选")
        case "propose_book_metadata": String(localized: "资料建议")
        case "propose_note": String(localized: "笔记建议")
        case "propose_bookmark": String(localized: "书签建议")
        case "propose_library_organization": String(localized: "整理方案")
        default: String(localized: "工具调用")
        }
    }
    static func symbol(_ name: String, input: JSONValue = .null, output: JSONValue? = nil) -> String {
        switch name {
        case "web_search": "globe"
        case "generate_image": "photo.badge.plus"
        case "ls": "folder"
        case "search_books": "magnifyingglass"
        case "get_book": "book.closed"
        case "get_chapters": "list.bullet"
        case "read": "book"
        case "rg": "doc.text.magnifyingglass"
        case "get_marks": input.object["kind"]?.string == "bookmark" ? "bookmark" : input.object["kind"]?.string == "annotation" ? "highlighter" : "list.bullet.rectangle"
        case "get_mark": output?.object["data"]?.object["kind"]?.string == "bookmark" ? "bookmark" : "highlighter"
        case "get_reading_statistics": "chart.bar"
        case "get_environment": input.object["fields"]?.strings == ["time"] ? "clock" : "globe"
        case "find_cover": "photo.on.rectangle.angled"
        case "propose_cover": "photo"
        case "propose_book_metadata": "text.badge.checkmark"
        case "propose_note": "highlighter"
        case "propose_bookmark": "bookmark"
        case "propose_library_organization": "folder.badge.gearshape"
        default: "wrench.and.screwdriver"
        }
    }
    static func summary(_ input: JSONValue, output: JSONValue? = nil) -> String {
        var parts = ["query", "title", "chapter", "fromDate", "toDate"].compactMap { input.object[$0]?.string }
        if let title = output?.object["data"]?.object["title"]?.string, !title.isEmpty, !parts.contains(title) { parts.insert(title, at: 0) }
        return parts.joined(separator: " · ")
    }
    static func status(_ output: JSONValue?, outcome: AIAgentStatus) -> String {
        guard let output else {
            return outcome == .waitingConfirmation ? String(localized: "等待确认") : [.stopped, .interrupted, .failed].contains(outcome) ? String(localized: "已停止") : String(localized: "执行中")
        }
        switch output.object["status"]?.string {
        case "denied": return String(localized: "未准备")
        case "error": return output.object["error"]?.object["code"]?.string == "cancelled" ? String(localized: "已停止") : String(localized: "未完成")
        case "partial": return String(localized: "部分结果")
        default: return String(localized: "已完成")
        }
    }
}

