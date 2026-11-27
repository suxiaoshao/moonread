import Foundation
import AISDKProvider

/// One mapping for process rows, details and the reading moon. Model text never supplies icons.
public enum AIToolPresentation {
    /// Tools the reader does not need to see as their own process rows.
    public static func isHidden(_ name: String) -> Bool { name == "get_current_time" }
    public static func groupTitle(_ names: [String]) -> String {
        let books: Set<String> = ["find_books", "get_book_info", "list_chapters", "read_text", "search_text", "list_marks"]
        if names.allSatisfy({ books.contains($0) }) { return String(localized: "查询书籍") }
        if Set(names).count == 1, let name = names.first { return title(name) }
        return String(localized: "工具调用")
    }
    public static func title(_ name: String, output: JSONValue? = nil) -> String {
        switch name {
        case "web_search": String(localized: "搜索网页")
        case "generate_image": String(localized: "生成图片")
        case "list_shelf": String(localized: "浏览书架")
        case "find_books": String(localized: "查找书籍")
        case "list_filter_values": String(localized: "查找标签、作者或书架名")
        case "show_books": String(localized: "展示书单")
        case "propose_book_filter": String(localized: "建议筛选")
        case "get_book_info": String(localized: "查看书籍资料")
        case "list_chapters": String(localized: "查看目录")
        case "read_text": String(localized: "阅读正文")
        case "search_text": String(localized: "搜索正文")
        case "list_marks": String(localized: "查看书签与批注")
        case "get_reading_statistics": String(localized: "查看阅读统计")
        case "get_current_time": String(localized: "查看当前时间")
        case "search_cover": String(localized: "查找封面")
        case "propose_cover": String(localized: "建议封面")
        case "propose_book_metadata": String(localized: "建议资料")
        case "propose_note": String(localized: "建议批注")
        case "propose_bookmark": String(localized: "建议书签")
        case "propose_library_organization": String(localized: "建议整理")
        default: String(localized: "工具调用")
        }
    }
    public static func symbol(_ name: String, input: JSONValue = .null, output: JSONValue? = nil) -> String {
        switch name {
        case "web_search": "globe"
        case "generate_image": "photo.badge.plus"
        case "list_shelf": "folder"
        case "find_books": "magnifyingglass"
        case "list_filter_values": "magnifyingglass"
        case "show_books": "books.vertical"
        case "propose_book_filter": "line.3.horizontal.decrease.circle"
        case "get_book_info": "book.closed"
        case "list_chapters": "list.bullet"
        case "read_text": "book"
        case "search_text": "doc.text.magnifyingglass"
        case "list_marks": input.object["kind"]?.string == "bookmark" ? "bookmark" : input.object["kind"]?.string == "annotation" ? "highlighter" : "list.bullet.rectangle"
        case "get_reading_statistics": "chart.bar"
        case "get_current_time": "clock"
        case "search_cover": "photo.on.rectangle.angled"
        case "propose_cover": "photo"
        case "propose_book_metadata": "text.badge.checkmark"
        case "propose_note": "highlighter"
        case "propose_bookmark": "bookmark"
        case "propose_library_organization": "folder.badge.gearshape"
        default: "wrench.and.screwdriver"
        }
    }
    public static func summary(_ input: JSONValue, output: JSONValue? = nil) -> String {
        var parts = ["query", "title", "chapter", "fromDate", "toDate"].compactMap { input.object[$0]?.string }
        if let title = output?.object["data"]?.object["title"]?.string, !title.isEmpty, !parts.contains(title) { parts.insert(title, at: 0) }
        return parts.joined(separator: " · ")
    }
}
