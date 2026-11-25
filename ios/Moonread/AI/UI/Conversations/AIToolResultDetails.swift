import AISDKProvider
import Foundation
import MoonreadAI

/// Read-only presentation of the saved output. Only committed conversation rows own actions.
struct AIToolResultDetails {
    enum State: Equatable {
        case running, waiting, stopped, denied, failed, empty, available, missing

        var title: String {
            switch self {
            case .running: String(localized: "执行中")
            case .waiting: String(localized: "等待确认")
            case .stopped: String(localized: "已停止")
            case .denied: String(localized: "未准备")
            case .failed: String(localized: "未完成")
            case .empty: String(localized: "没有匹配的结果")
            case .available: String(localized: "已完成")
            case .missing: String(localized: "本次未返回可显示的内容")
            }
        }

        var symbol: String {
            switch self {
            case .running, .waiting: "clock"
            case .stopped: "stop.circle"
            case .failed, .denied: "exclamationmark.circle"
            case .empty, .missing: "magnifyingglass"
            case .available: "checkmark.circle"
            }
        }
    }

    struct Row: Identifiable {
        struct ID: Hashable {
            let section: Section.ID
            let key: [String?]
            let occurrence: Int
        }

        let key: [String?]
        let text: String
        var label: String?
        var subtitle: String?
        var web: AIWebSource?
        var image: AIImageAttachment?
        var indent: Int = 0
        fileprivate var sectionID: Section.ID = []
        fileprivate var occurrence = 0
        var id: ID { .init(section: sectionID, key: key, occurrence: occurrence) }

        static func fact(_ key: String, _ label: String, _ value: String?) -> Self? {
            guard let value, !value.isEmpty else { return nil }
            return .init(key: [key], text: value, label: label)
        }
    }

    struct Section: Identifiable {
        typealias ID = [String]
        let id: ID
        let title: String
        let rows: [Row]
        let isEntity: Bool

        init(id: ID, title: String, rows: [Row], isEntity: Bool = false) {
            self.id = id
            self.title = title
            self.isEntity = isEntity
            var occurrences: [[String?]: Int] = [:]
            self.rows = rows.map { row in
                var row = row
                let occurrence = occurrences[row.key, default: 0]
                occurrences[row.key] = occurrence + 1
                // Only indistinguishable keys need an occurrence number. Unrelated rows never shift it.
                row.sectionID = id
                row.occurrence = occurrence
                return row
            }
        }
    }

    private let item: AIProcessItem
    private let outcome: AIAgentStatus
    private let hasReplyResult: Bool
    private let result: JSONValue
    private let input: [String: JSONValue]
    private let data: JSONValue
    private let bytes: Data?
    private(set) var sections: [Section] = []
    private let names: AIToolRequestNames
    private(set) var requestSection: Section?
    var request: [Row] { requestSection?.rows ?? [] }
    private(set) var notice: String?
    private var resultRecorded = false
    private var fact: String?
    private var empty = false
    private var status: String? { result.object["status"]?.string }
    private var code: String? { result.object["error"]?.object["code"]?.string }
    /// Search and image services save a reader-facing reason (sign-in, connection, provider failure).
    private var serviceMessage: String? {
        guard ["web_search", "find_cover", "generate_image"].contains(item.name),
              let message = result.object["error"]?.object["message"]?.string, !message.isEmpty else { return nil }
        return message
    }

    init(item: AIProcessItem, outcome: AIAgentStatus, hasReplyResult: Bool, names: AIToolRequestNames = .init()) {
        self.names = names
        self.item = item
        self.outcome = outcome
        self.hasReplyResult = hasReplyResult
        result = item.output ?? .null
        input = item.input.object
        data = result.object["data"] ?? .null
        bytes = try? JSONEncoder().encode(data)
        let request = projectRequest()
        if !request.isEmpty { requestSection = .init(id: ["request"], title: String(localized: "请求"), rows: request) }
        project()
    }

    var opensDetail: Bool { !(hasReplyResult && status == "ok") }
    private var hasUnreturnedPage: Bool {
        let page = result.object["page"]?.object
        return page?["complete"] == .bool(false) || page?["nextCursor"]?.string != nil || input["cursor"]?.string != nil
    }

    var state: State {
        switch status {
        case "denied": return .denied
        case "error": return code == "cancelled" ? .stopped : .failed
        case "ok", "partial":
            if empty && !hasUnreturnedPage { return .empty }
            return sections.isEmpty && !resultRecorded && notice == nil ? .missing : .available
        default:
            if item.isRunning { return .running }
            switch outcome {
            case .waitingConfirmation, .waitingDataSharing: return .waiting
            case .stopped, .interrupted: return .stopped
            case .failed, .limitReached: return .failed
            case .running, .compacting: return .running
            default: return sections.isEmpty ? .missing : .available
            }
        }
    }

    var statusTitle: String {
        if state == .empty {
            switch item.name {
            case "search_books": return String(localized: "没有找到匹配的小说")
            case "rg": return String(localized: "已搜索范围内没有命中")
            default: break
            }
        }
        return state.title
    }

    var summary: String {
        switch state {
        case .available: return fact ?? request.first.map { Self.snippet($0.text) ?? $0.text } ?? ""
        case .failed: return explanation ?? state.title
        default: return state.title
        }
    }

    var explanation: String? {
        switch state {
        case .running: nil
        case .waiting: String(localized: "此调用需要确认后才能继续。")
        case .denied: String(localized: "未同意准备所需内容，此调用没有执行。")
        case .stopped: nil
        case .failed:
            switch code {
            case "timeout": String(localized: "等待回复超时")
            case "not_found", "stale_reference", "invalid_scope": String(localized: "所需资料已不可用。")
            case "stale_cursor": String(localized: "查询范围已变化。")
            case "needs_preparation": String(localized: "正文尚未准备完成。")
            case "permission_denied": String(localized: "无法访问所需资料。")
            case "unsupported": String(localized: "当前服务不提供这项操作。")
            case "invalid_argument": String(localized: "此次查询的条件无效。")
            case "invalid_response": String(localized: "服务返回的内容无法读取。")
            case "resource_limit": String(localized: "所需内容超出这次操作的范围。")
            case "login_required": String(localized: "登录已失效，请在 AI 设置中重新登录后再试。")
            case "network": String(localized: "网络连接失败，请稍后再试。")
            default: serviceMessage
            }
        case .empty, .available, .missing: nil
        }
    }

    private func decode<T: Decodable>(_ type: T.Type) -> T? {
        bytes.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private mutating func add(_ id: Section.ID, _ title: String, _ rows: [Row?], isEntity: Bool = false) {
        let values = rows.compactMap { $0 }.filter { !$0.text.isEmpty || $0.image != nil }
        if !values.isEmpty { sections.append(.init(id: id, title: title, rows: values, isEntity: isEntity)) }
    }

    private func projectRequest() -> [Row] {
        var rows: [Row] = []
        func put(_ key: String, _ label: String, _ value: String?) {
            if let row = Row.fact(key, label, value) { rows.append(row) }
        }
        func field(_ key: String) -> String? { input[key]?.string }
        func target(_ label: String, _ key: String) { put(key, label, names[field(key)]) }
        func limit(_ key: String, label: String) {
            if let count = input[key]?.int, count > 0 { put(key, label, count.formatted()) }
        }
        func query() { put("query", String(localized: "关键词"), field("query")) }
        func sort() {
            let value: String? = switch field("sort") {
            case "name": String(localized: "名称")
            case "recent": String(localized: "最近阅读")
            default: nil
            }
            put("sort", String(localized: "排序"), value)
        }
        let book = String(localized: "小说")
        let chapterName = names[field("chapterRef")] ?? names.chapterAtPosition
        let maximum = String(localized: "最多项数")
        switch item.name {
        case "ls":
            put("directory", String(localized: "目录"), field("parentRef") == nil ? String(localized: "书架根目录") : names[field("parentRef")])
            if field("kind") == "folders" { put("kind", String(localized: "类型"), String(localized: "文件夹")) }
            if field("kind") == "books" { put("kind", String(localized: "类型"), book) }
            sort()
            limit("limit", label: maximum)
        case "search_books":
            query()
            target(String(localized: "范围"), "scopeRef")
            put("author", String(localized: "作者"), field("author"))
            put("tags", String(localized: "同时包含的标签"), list(strings(input["tags"])))
            put("status", String(localized: "阅读状态"), readingStatus(field("readingStatus")))
            sort()
            limit("limit", label: String(localized: "最多本数"))
        case "list_filter_options":
            put("kind", String(localized: "类型"), filterField)
            query()
        case "get_book":
            target(book, "bookRef")
            target(String(localized: "文件"), "fileRef")
            if input["prepare"] == .bool(true) { put("operation", String(localized: "操作"), String(localized: "准备文件")) }
        case "get_chapters":
            query()
            target(book, "bookRef")
            limit("limit", label: maximum)
        case "read":
            target(book, "bookRef")
            put("chapter", String(localized: "章节"), chapterName)
            if input["contextOffsetUtf8"]?.int != nil {
                let before = input["beforeParagraphs"]?.int ?? 3
                let after = input["afterParagraphs"]?.int ?? 3
                put("scope", String(localized: "范围"), before == after ? String(localized: "前后各 \(before) 段") :
                    String(localized: "前 \(before) 段、后 \(after) 段"))
            }
        case "rg":
            query()
            let refs = strings(input["bookRefs"])
            let known = refs.compactMap { names[$0] }
            put("books", book, list(known) ?? (refs.count > 1 ? String(localized: "\(refs.count) 本小说") : nil))
            put("chapter", String(localized: "章节"), chapterName)
            put("mode", String(localized: "匹配方式"), field("mode") == "literal" ? String(localized: "普通文本") : String(localized: "正则表达式"))
            if field("query").map({ $0.lowercased() != $0.uppercased() }) == true {
                put("case", String(localized: "大小写"), input["caseSensitive"] == .bool(false) ?
                    String(localized: "不区分大小写") : String(localized: "区分大小写"))
            }
            limit("maxHits", label: String(localized: "最多命中数"))
        case "get_marks", "get_mark":
            target(book, "bookRef")
            if item.name == "get_marks" {
                let type = switch field("kind") {
                case "bookmark": String(localized: "书签")
                case "annotation": String(localized: "批注")
                default: String(localized: "书签与批注")
                }
                put("kind", String(localized: "类型"), type)
                query()
                put("chapter", String(localized: "章节"), chapterName)
                limit("limit", label: maximum)
            } else {
                target(String(localized: "标注"), "markRef")
                target(String(localized: "版本"), "variantRef")
            }
        case "get_reading_statistics":
            put("dates", statisticsView == "chapters" ? String(localized: "请求日期") : String(localized: "日期"), statisticsDates)
            let scope = field("bookRef") == nil ? String(localized: "全部小说") : names[field("bookRef")]
            if let scope {
                put("scope", String(localized: "范围"), joined([scope, statisticsHeading]))
            } else {
                put("view", String(localized: "视图"), statisticsHeading)
            }
            limit("limit", label: maximum)
        case "get_environment":
            let fields = Set(strings(input["fields"]))
            if fields == ["time"] { put("fields", String(localized: "内容"), String(localized: "本地时间")) }
            if fields == ["locale"] { put("fields", String(localized: "内容"), String(localized: "语言与地区")) }
        case "web_search":
            query()
            put("language", String(localized: "语言"), field("language").map { Locale.current.localizedString(forIdentifier: $0) ?? $0 })
        case "generate_image":
            put("prompt", String(localized: "提示词"), field("prompt"))
            let count = strings(input["referenceAttachmentRefs"]).count
            if count > 0 { put("referenceImages", String(localized: "参考图"), String(localized: "\(count) 张图")) }
        case "find_cover":
            query()
            target(book, "bookRef")
        case "propose_cover":
            target(book, "bookRef")
            target(String(localized: "图片来源"), "attachmentRef")
        case "propose_book_metadata":
            target(book, "bookRef")
            var fields = metadataFields(input)
            if input["tags"] != nil, let index = fields.firstIndex(of: String(localized: "标签")) {
                fields[index] = field("tagsMode") == "replace" ? String(localized: "替换标签") : String(localized: "合并标签")
            }
            put("operation", String(localized: "操作"), list(fields))
            put("sources", String(localized: "来源"), list(strings(input["sourceRefs"]).compactMap { names[$0] }))
        case "propose_note", "propose_bookmark":
            target(book, "bookRef")
            put("chapter", String(localized: "章节"), chapterName)
            put("operation", String(localized: "操作"), item.name == "propose_bookmark" ? String(localized: "添加书签") : noteAction)
            if item.name == "propose_note" {
                if case .some(.notes) = decode(AIProposalSnapshot.self) {} else {
                    put("draft", String(localized: "批注草稿"), field("note"))
                }
            }
        case "propose_library_organization":
            target(String(localized: "范围"), "scopeRef")
            let placements = input["placements"]?.array ?? []
            put("operation", String(localized: "操作"), organizationSummary(folders: input["folders"]?.array?.count ?? 0,
                                                                moves: placements.count,
                                                                includesRename: placements.contains { $0.object["name"]?.string != nil }))
            if status != "ok" {
                let folders = input["folders"]?.array ?? []
                put("folders", String(localized: "文件夹"), list(folders.compactMap { $0.object["name"]?.string }))
                put("placements", String(localized: "建议移动的项目"), list(placements.compactMap {
                    $0.object["name"]?.string ?? names[$0.object["fileRef"]?.string]
                }))
            }
        case "propose_book_filter":
            if let filter = try? JSONDecoder().decode(AIBookFilterInput.self, from: JSONEncoder().encode(item.input)),
               let configuration = try? filter.configuration(resolveShelf: { $0 }) {
                rows = filterRows(configuration)
            } else {
                let order = (input["sorts"]?.array ?? []).compactMap { entry -> BookSearchSort? in
                    guard let raw = entry.object["field"]?.string, ["name", "recent", "author"].contains(raw),
                          let field = BookSearchSortField(rawValue: raw),
                          case .some(.bool(let descending)) = entry.object["descending"] else { return nil }
                    return .init(field: field, descending: descending)
                }
                if let row = sortRow(order) { rows.append(row) }
            }
        default: break
        }
        return rows
    }

    private func strings(_ value: JSONValue?) -> [String] { value?.array?.compactMap(\.string) ?? [] }

    private var filterField: String? {
        switch input["field"]?.string {
        case "tag": String(localized: "标签")
        case "author": String(localized: "作者")
        case "shelf": String(localized: "书架")
        default: nil
        }
    }

    private var statisticsView: String { input["view"]?.string ?? "summary" }
    private var statisticsDates: String? {
        let from = input["fromDate"]?.string
        let to = input["toDate"]?.string
        guard let from, let to else { return from ?? to }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = StatisticsDates.civilCalendar
        parser.timeZone = StatisticsDates.civilCalendar.timeZone
        parser.dateFormat = "yyyy-MM-dd"
        guard let first = parser.date(from: from), let last = parser.date(from: to), first <= last else {
            return joined([from, to], separator: " – ")
        }
        let interval = DateIntervalFormatter()
        interval.calendar = parser.calendar
        interval.timeZone = parser.timeZone
        interval.dateTemplate = "yMMMd"
        return interval.string(from: first, to: last)
    }
    private var statisticsHeading: String {
        switch statisticsView {
        case "days": String(localized: "逐日")
        case "books": String(localized: "逐书")
        case "sessions": String(localized: "阅读时段")
        case "chapters": String(localized: "章节")
        default: String(localized: "汇总")
        }
    }

    private var noteAction: String {
        input["markRef"]?.string == nil ? String(localized: "添加批注") : String(localized: "编辑批注")
    }

    private func metadataFields(_ values: [String: JSONValue]) -> [String] {
        [("author", String(localized: "作者")), ("synopsis", String(localized: "简介")),
         ("tags", String(localized: "标签")), ("readingStatus", String(localized: "阅读状态")),
         ("rename", String(localized: "文件名"))].compactMap { values[$0.0] == nil ? nil : $0.1 }
    }

    private func readingStatus(_ value: String?) -> String? {
        if value == "other" { return String(localized: "其他状态") }
        return value.flatMap { BookSearchStatus(rawValue: $0)?.title }
    }

    private func list(_ values: [String]) -> String? {
        let values = values.filter { !$0.isEmpty }
        return values.isEmpty ? nil : ListFormatter.localizedString(byJoining: values)
    }

    static func snippet(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let firstLine = text.prefix { !$0.isNewline }
        let length = firstLine.firstIndex(where: { "。！？.!?".contains($0) })
            .map { firstLine.distance(from: firstLine.startIndex, to: $0) + 1 } ?? firstLine.count
        return String(firstLine.prefix(min(72, length))) + (length > 72 ? "…" : "")
    }

    private mutating func project() {
        switch item.name {
        case "ls": library()
        case "search_books": books()
        case "list_filter_options": filterOptions()
        case "get_book": book()
        case "get_chapters":
            if let value = decode(AIChaptersResult.self) { chapters(value) }
        case "read": read()
        case "rg": hits()
        case "get_marks", "get_mark": marks()
        case "get_reading_statistics": statistics()
        case "get_environment": environment()
        case "web_search", "find_cover": web()
        case "generate_image": images()
        case "propose_book_filter": filterProposal()
        case "propose_cover", "propose_book_metadata", "propose_note", "propose_bookmark", "propose_library_organization": proposal()
        default: break
        }
        if sections.isEmpty {
            // Older outputs may lack the typed fields but still have an answer or an excerpt.
            let content = data.string ?? data.object["answer"]?.string ?? data.object["text"]?.string ?? data.object["excerpt"]?.string
            if let content, !content.isEmpty { add(["fallback"], String(localized: "结果"), [.init(key: ["fallback"], text: content)]) }
        }
    }

    private mutating func library() {
        guard let value = decode(AILibraryResult.self) else { return }
        empty = value.items.isEmpty
        let folders = value.items.filter { $0.kind == "folder" }.count
        let files = value.items.filter { $0.kind == "file" }.count
        fact = folders > 0 && files > 0 ? String(localized: "\(folders) 个文件夹、\(files) 个文件") :
            list(Array(value.items.prefix(3).map(\.name)))
        add(["directory"], String(localized: "目录"), value.items.map(file))
    }

    private mutating func books() {
        guard let value = decode(AIBooksResult.self) else { return }
        let count = value.items.count
        empty = count == 0
        fact = if input["limit"]?.int != nil, count > 0 {
            joined([input["query"]?.string, String(localized: "列出 \(count) 本")])
        } else { list(Array(value.items.prefix(3).map(\.title))) }
        add(["matches"], String(localized: "匹配的小说"), value.items.map { book in
            let sources = book.files.map { file in joined([file.name, availability(file.availability)]) }.compactMap { $0 }
            let fileRefs = book.files.compactMap { $0.fileRef ?? $0.ref }.sorted()
            let key: [String?] = book.bookRef == nil && fileRefs.isEmpty ? ["name", book.title, book.author] :
                ["book", book.bookRef] + fileRefs.map(Optional.some)
            return .init(key: key, text: book.title, subtitle: joined([book.author, availability(book.availability), sources.isEmpty ? nil : sources.joined(separator: "\n")], separator: "\n"))
        })
    }

    private mutating func filterOptions() {
        guard let value = decode(AIFilterOptionsResult.self) else { return }
        empty = value.names.isEmpty
        fact = list(Array(value.names.prefix(3)))
        add(["filterOptions"], filterField ?? String(localized: "结果"), value.names.map { .init(key: ["option", $0], text: $0) })
    }

    private mutating func book() {
        guard let value = decode(AIBookResult.self) else { return }
        let status = readingStatus(value.readingStatus)
        fact = joined([value.author, status]) ?? value.title
        let words = value.wordCount.map { String(localized: "\($0) 字") }
        let chapters = value.chapterCount.map { String(localized: "\($0) 章") }
        let progress = value.progress.map { ($0.percent / 100).formatted(.percent.precision(.fractionLength(0...1))) }
        add(["book"], String(localized: "书籍资料"), [
            .init(key: ["title"], text: value.title),
            .fact("author", String(localized: "作者"), value.author),
            .fact("tags", String(localized: "标签"), value.tags?.joined(separator: String(localized: "、"))),
            .fact("status", String(localized: "阅读状态"), status),
            .fact("words", String(localized: "正文字数"), words),
            .fact("chapterCount", String(localized: "章节"), chapters),
            .fact("progress", String(localized: "阅读进度"), progress),
            .fact("chapter", String(localized: "当时所在章节"), value.progress?.chapterTitle),
            .fact("availability", String(localized: "当时的文件状态"), availability(value.availability)),
        ])
        if let synopsis = value.synopsis ?? value.synopsisSnippet, !synopsis.isEmpty {
            let abbreviated = value.synopsisTruncated == true || value.synopsis == nil
            let heading = abbreviated ? String(localized: "简介摘录") : String(localized: "简介")
            add(["synopsis"], heading, [.init(key: ["synopsis"], text: abbreviated ? abbreviatedText(synopsis) : synopsis)])
        }
        let filesTitle = value.filesTruncated == true ? String(localized: "部分文件来源") : String(localized: "文件来源")
        add(["files"], filesTitle, value.files.map(file))
        if value.filesTruncated == true && value.files.isEmpty { notice = String(localized: "部分文件来源未列出") }
    }

    private mutating func chapters(_ value: AIChaptersResult, statistics: Bool = false) {
        let volume = value.items.first { $0.level == 0 }
        let titles = list(Array(value.items.filter { $0.level != 0 }.prefix(2).map(\.title)))
        fact = statistics ? joined([statisticsDates, String(localized: "累计章节覆盖（估算）")]) :
            joined([volume?.title, titles])
        if !value.outlineComplete { notice = String(localized: "目录尚未完整") }
        empty = value.items.isEmpty && value.outlineComplete
        if statistics {
            add(["chapterStatistics"], String(localized: "累计章节覆盖（估算）"), [.init(key: ["estimate"], text: String(localized: "累计章节覆盖（估算）"))]
                + chapterRows(value, statistics: true))
        } else {
            add(["chapters"], String(localized: "章节"), chapterRows(value, statistics: false))
        }
    }

    private func chapterRows(_ value: AIChaptersResult, statistics: Bool) -> [Row] {
        value.items.map { chapter in
            if chapter.level == 0 { return .init(key: ["chapter", chapter.chapterRef], text: chapter.title) }
            let words = chapter.countComplete ? String(localized: "\(chapter.wordCount) 字") : String(localized: "至少 \(chapter.wordCount) 字")
            let coverage = chapter.estimatedCoveragePercent.map { ($0 / 100).formatted(.percent.precision(.fractionLength(0...1))) }
            return .init(key: ["chapter", chapter.chapterRef], text: chapter.title,
                         subtitle: statistics ? joined([words, coverage.map { String(localized: "估算覆盖 \($0)") }]) : words,
                         indent: chapter.parentChapterRef == nil ? 0 : 1)
        }
    }

    private mutating func read() {
        guard let value = decode(AIReadResult.self) else { return }
        if value.text.isEmpty { empty = true; return }
        let source = result.object["sources"]?.array?.first { $0.object["sourceRef"]?.string == value.sourceRef }
        let title = [data.object["title"]?.string, data.object["chapterTitle"]?.string, source?.object["title"]?.string,
                     names[input["chapterRef"]?.string], names.chapterAtPosition].compactMap { $0 }.first { !$0.isEmpty }
        fact = title ?? Self.snippet(value.text)
        add(["passage"], String(localized: "正文片段"), [.init(key: ["passage"], text: value.text)])
    }

    private mutating func hits() {
        guard let value = decode(AISearchResult.self) else { return }
        let unsearched = value.coverage.filter { $0.status == "not_scanned" }.count
        let unresolvedPartial = value.coverage.isEmpty && (value.truncated || status == "partial")
        let incomplete = unresolvedPartial || value.coverage.contains { !$0.complete }
        let query = input["query"]?.string.map { String(localized: "「\($0)」") }
        if unsearched > 0 {
            fact = joined([query, String(localized: "另 \(unsearched) 本未搜索")])
        } else {
            let match = value.hits.first
            fact = joined([query, match?.chapterTitle ?? Self.snippet(match?.excerpt)
                ?? (incomplete ? String(localized: "已搜索范围内没有命中") : nil)])
        }
        if unresolvedPartial { notice = String(localized: "搜索覆盖范围未完整记录") }
        if value.hits.isEmpty && incomplete {
            notice = joined([String(localized: "已搜索范围内没有命中"), notice])
        }
        empty = value.hits.isEmpty && notice == nil && !value.coverage.isEmpty
        var books: [String] = []
        for ref in strings(input["bookRefs"]) + value.coverage.map(\.bookRef) + value.hits.map(\.bookRef)
            where !books.contains(ref) { books.append(ref) }
        for (index, book) in books.enumerated() {
            let group = value.hits.filter { $0.bookRef == book }
            let coverage = value.coverage.first { $0.bookRef == book }
            let heading = names[book] ?? (books.count == 1 ? String(localized: "命中片段") : String(localized: "第 \(index + 1) 本"))
            var rows = group.map { hit in Row(key: ["hit", hit.sourceRef], text: hit.excerpt, label: hit.chapterTitle) }
            if let coverage, !coverage.complete {
                let message = coverage.status == "not_scanned" ? String(localized: "尚未搜索这本书") : String(localized: "仅搜索了部分范围")
                rows.insert(.init(key: ["coverage"], text: message), at: 0)
            }
            add(["hits", book], heading, rows, isEntity: names[book] != nil || books.count > 1)
        }
    }

    private mutating func marks() {
        if item.name == "get_marks" {
            guard let value = decode(AIMarksResult.self) else { return }
            let bookmarks = value.items.filter { $0.kind == "bookmark" }.count
            let annotations = value.items.filter { $0.kind == "annotation" }.count
            let onlyMark = value.items.count == 1 ? value.items.first : nil
            fact = Self.snippet(onlyMark?.note ?? onlyMark?.excerpt) ?? joined([
                bookmarks > 0 ? String(localized: "\(bookmarks) 个书签") : nil,
                annotations > 0 ? String(localized: "\(annotations) 条批注") : nil,
            ], separator: String(localized: "、"))
            empty = value.items.isEmpty
            add(["marks"], String(localized: "书签与批注"), value.items.map(markRow))
        } else if let mark = decode(AIMarkResult.self) {
            let variants = mark.variants ?? []
            let note = mark.noteText ?? mark.note
            fact = variants.isEmpty ? (Self.snippet(note) ?? Self.snippet(mark.excerpt) ?? markKind(mark)) :
                String(localized: "\(variants.count) 个批注版本")
            let type = Row.fact("kind", String(localized: "类型"), markKind(mark))
            if let note, !note.isEmpty {
                let excerpt = mark.noteTruncated == true || hasUnreturnedPage
                add(["note"], excerpt ? String(localized: "批注摘录") : String(localized: "批注"),
                    [type, .init(key: ["note"], text: excerpt ? abbreviatedText(note) : note)])
            }
            if let excerpt = mark.excerpt, !excerpt.isEmpty {
                let kind = (note?.isEmpty ?? true) ? type : nil
                add(["excerpt"], String(localized: "摘录"), [kind, .init(key: ["excerpt"], text: mark.excerptTruncated == true ? abbreviatedText(excerpt) : excerpt)])
            } else if mark.range != nil && (note?.isEmpty ?? true) {
                add(["location"], String(localized: "位置"), [markRow(mark)])
            }
            add(["variants"], String(localized: "批注版本"), variants.enumerated().map { index, variant in
                Row(key: ["variant", variant.variantRef], text: variant.noteSnippet, label: String(localized: "版本 \(index + 1)"))
            })
        }
    }

    private mutating func statistics() {
        let heading = statisticsHeading
        let dates = statisticsDates
        guard let value = decode(AIStatisticsResult.self) else { return }
        if value.incomplete == true { notice = String(localized: "部分阅读记录未计入") }
        if let value = value.chapters { chapters(value, statistics: true); return }
        if let duration = value.durationMs {
            let time = StatisticsDates.duration(duration)
            fact = joined([dates, time])
            add(["statisticsSummary"], heading, [
                .fact("duration", String(localized: "阅读时长"), time),
                .fact("dayCount", String(localized: "阅读日"), value.readingDays?.formatted()),
                .fact("bookCount", String(localized: "小说"), value.bookCount?.formatted()),
                .fact("recording", String(localized: "统计记录"), value.recordingEnabledOnDevice == false ? String(localized: "阅读统计已暂停") : nil),
            ])
        }
        if let rows = value.items {
            fact = joined([dates, heading])
            empty = rows.isEmpty && notice == nil
            add(["statisticsItems", statisticsView], heading, rows.map { row in
                let date = row.date ?? row.recordedDate
                let duration = StatisticsDates.duration(row.durationMs)
                let zone = row.utcOffsetSeconds.flatMap { TimeZone(secondsFromGMT: Int($0)) }
                let started = row.startedAt.map { displayDate($0, zone: zone) }
                let ended = row.endedAt.map { displayDate($0, zone: zone) }
                let days = row.readingDays.map { String(localized: "\($0) 个阅读日") }
                let books = row.bookCount.map { String(localized: "\($0) 本小说") }
                let status = row.preview == true ? String(localized: "查阅") : nil
                let key: [String?] = if let ref = row.sessionRef { ["session", ref] }
                else if let ref = row.bookRef { ["book", ref] }
                else if let date { ["date", date, row.startedAt, row.endedAt] }
                else { ["time", row.startedAt, row.endedAt, row.title] }
                return .init(key: key, text: joined([row.title, date, duration]) ?? duration,
                             subtitle: joined([joined([started, ended], separator: " – "), days, books, status]))
            })
        }
    }

    private mutating func environment() {
        guard let value = decode(AIEnvironmentResult.self) else { return }
        let time = value.now.map { displayDate($0, zone: value.timeZone.flatMap(TimeZone.init(identifier:))) }
        let language = value.appLanguage.map { Locale.current.localizedString(forIdentifier: $0) ?? $0 }
        let region = value.region.map { Locale.current.localizedString(forRegionCode: $0) ?? $0 }
        fact = time ?? joined([language, region])
        add(["environment"], String(localized: "时间与语言"), [
            .fact("time", String(localized: "本地时间"), time),
            .fact("zone", String(localized: "时区"), value.timeZone),
            .fact("language", String(localized: "语言"), language),
            .fact("region", String(localized: "地区"), region),
        ])
    }

    private mutating func web() {
        let sources = AIWebSource.committed(in: result, tool: item.name)
        let answer = data.object["answer"]?.string
        if let answer, !answer.isEmpty { add(["answer"], String(localized: "搜索回答"), [.init(key: ["answer"], text: answer)]) }
        add(["web"], String(localized: "网页来源"), sources.map { .init(key: ["url", $0.url], text: $0.title, subtitle: URL(string: $0.url)?.host, web: $0) })
        if item.name == "find_cover", let value = decode(AIFindCoverResult.self) {
            let candidates = value.candidates.count
            let count = sources.count
            fact = candidates > 0 ? String(localized: "\(candidates) 张候选封面") : String(localized: "\(count) 个网页来源")
            add(["covers"], String(localized: "封面候选"), value.candidates.map(cover))
            empty = candidates == 0 && sources.isEmpty && (answer?.isEmpty ?? true)
        } else if item.name == "web_search" {
            if data.object["truncated"] == .bool(true) { notice = String(localized: "搜索结果有节略") }
            if (try? JSONDecoder().decode(AINativeResult.self, from: JSONEncoder().encode(result))) != nil {
                let count = sources.count
                fact = joined([input["query"]?.string, String(localized: "\(count) 个网页来源")])
                empty = sources.isEmpty && (answer?.isEmpty ?? true) && notice == nil
            }
        }
    }

    private mutating func images() {
        guard let attachments = data.object["attachments"]?.array else { return }
        let images = attachments.compactMap { value -> AIImageAttachment? in
            guard let bytes = try? JSONEncoder().encode(value) else { return nil }
            return try? JSONDecoder().decode(AIImageAttachment.self, from: bytes)
        }
        let count = images.count
        fact = joined([Self.snippet(input["prompt"]?.string), String(localized: "\(count) 张图")])
        empty = attachments.isEmpty
        add(["images"], String(localized: "图片"), images.map { .init(key: ["attachment", $0.id], text: dimensions($0), image: $0) })
    }

    private mutating func filterProposal() {
        guard let suggestion = decode(AIBookFilterSuggestion.self), let configuration = try? suggestion.filter.configuration(resolveShelf: { $0 }) else { return }
        let rows = filterRows(configuration)
        let rule = configuration.root.children.isEmpty ? nil : configuration.root.expression { $0 }
        if let rule, rule.count > 72 {
            let groups = configuration.root.children.filter { $0.group != nil }.count
            fact = groups > 0 ? String(localized: "\(groups) 个条件组") :
                String(localized: "\(configuration.root.children.count) 项筛选条件")
        } else { fact = rule ?? rows.first?.text }
        resultRecorded = true
        if request.map(\.text) != rows.map(\.text) || request.map(\.label) != rows.map(\.label) {
            add(["filter"], String(localized: "筛选建议"), rows)
        }
    }

    private func filterRows(_ value: BookSearchConfiguration) -> [Row] {
        let rule = value.root.children.isEmpty ? nil : value.root.expression { $0 }
        return [.fact("rule", String(localized: "筛选条件"), rule), sortRow(value.sorts)].compactMap { $0 }
    }

    private func sortRow(_ sorts: [BookSearchSort]) -> Row? {
        let order = sorts.map { sort in
            [sort.field.title, sort.descending ? String(localized: "降序") : String(localized: "升序")].joined(separator: " · ")
        }
        return .fact("sort", String(localized: "排序"), order.joined(separator: "\n"))
    }

    private mutating func proposal() {
        guard let snapshot = decode(AIProposalSnapshot.self) else { return }
        switch (item.name, snapshot) {
        case ("propose_cover", .cover(let value)):
            if case .generated = value.origin { fact = String(localized: "建议使用生成的图片作封面") }
            else { fact = String(localized: "1 张候选封面") }
            add(["covers"], String(localized: "封面候选"), [cover(value)])
        case ("propose_book_metadata", .metadata(let value)):
            let changes = [
                proposalFact("author", String(localized: "作者"), value.author),
                proposalFact("synopsis", String(localized: "简介"), value.synopsis),
                proposalFact("tags", String(localized: "标签"), value.tags?.joined(separator: String(localized: "、"))),
                .fact("status", String(localized: "阅读状态"), value.readingStatus.flatMap { BookSearchStatus(rawValue: $0.rawValue)?.title }),
            ]
            var fields = changes.compactMap { $0?.label }
            if value.rename != nil { fields.append(String(localized: "文件名")) }
            if let fields = list(fields) { fact = String(localized: "建议修改\(fields)") }
            add(["metadata"], String(localized: "资料变更"), changes)
            if let rename = value.rename, let target = try? rename.filename(stem: rename.name) {
                add(["rename"], String(localized: "文件名变更"), [
                    .fact("originalFilename", String(localized: "原文件名"), rename.originalName),
                    .fact("proposedFilename", String(localized: "建议文件名"), target),
                ])
            }
        case ("propose_note", .notes(let value)) where value.kind == .note:
            fact = Self.snippet(value.note) ?? noteAction
            add(["draft"], String(localized: "批注草稿"), [.init(key: ["draft"], text: value.note)])
        case ("propose_bookmark", .notes(let value)) where value.kind == .bookmark:
            fact = joined([String(localized: "建议添加书签"), names.chapterAtPosition])
            resultRecorded = true
        case ("propose_library_organization", .organization(let value)):
            let folders = value.input.folders.count
            let moves = value.input.placements.count
            fact = organizationSummary(folders: folders, moves: moves, includesRename: value.input.placements.contains { $0.name != nil })
            add(["folders"], String(localized: "建议新建的文件夹"), value.input.folders.map { .init(key: ["folder", $0.temporaryRef], text: $0.name) })
            add(["placements"], String(localized: "建议移动的项目"), value.input.placements.enumerated().map { index, placement in
                .init(key: ["placement", placement.fileRef], text: placement.name ?? names[placement.fileRef] ?? String(localized: "第 \(index + 1) 项"),
                      subtitle: value.input.folders.first { $0.temporaryRef == placement.parentRef }?.name ?? names[placement.parentRef])
            })
        default: break
        }
    }

    private func organizationSummary(folders: Int, moves: Int, includesRename: Bool) -> String? {
        joined([folders > 0 ? String(localized: "新建 \(folders) 个文件夹") : nil,
                moves > 0 ? (includesRename ? String(localized: "移动或改名 \(moves) 项") : String(localized: "移动 \(moves) 项")) : nil], separator: String(localized: "、"))
    }

    private func abbreviatedText(_ value: String) -> String {
        value.hasSuffix("…") ? value : value + "…"
    }

    private func file(_ value: AIFileResult) -> Row {
        let kind: String? = switch value.kind {
        case "folder": String(localized: "文件夹")
        case "file": String(localized: "文件")
        case "shelf": String(localized: "书架")
        default: nil
        }
        let children = value.kind == "folder" || value.kind == "shelf" ? value.childBookCount.map { String(localized: "\($0) 本小说") } : nil
        let key: [String?] = if let ref = value.ref ?? value.fileRef { ["file", ref] }
        else { ["name", value.parentRef, value.kind, value.name] }
        return .init(key: key, text: value.name, subtitle: joined([kind, children, availability(value.availability)]))
    }

    private func availability(_ raw: String) -> String? {
        switch raw {
        case "ready": String(localized: "可用")
        case "needs_download": String(localized: "待下载")
        case "needs_parse": String(localized: "正文尚未准备")
        case "unavailable": String(localized: "暂不可用")
        default: nil
        }
    }

    private func markKind(_ value: AIMarkResult) -> String? {
        switch value.kind {
        case "bookmark": String(localized: "书签")
        case "annotation": String(localized: "批注")
        default: nil
        }
    }

    private func markRow(_ value: AIMarkResult) -> Row {
        let subtitle = joined([value.createdAt.map { displayDate($0) }, value.hasConflict == true ? String(localized: "有多个版本") : nil])
        let title = markKind(value) ?? String(localized: "标注")
        let note = (value.noteText ?? value.note).map { value.noteTruncated == true && !$0.isEmpty ? abbreviatedText($0) : $0 }
        let excerpt = value.excerpt.map { value.excerptTruncated == true && !$0.isEmpty ? abbreviatedText($0) : $0 }
        return .init(key: ["mark", value.markRef], text: joined([note, excerpt], separator: "\n") ?? title,
                     label: title, subtitle: subtitle)
    }

    private func cover(_ value: AICoverProposal) -> Row {
        .init(key: ["attachment", value.attachment.id], text: dimensions(value.attachment), subtitle: value.origin.caption, web: value.origin.webSource, image: value.attachment)
    }

    private func dimensions(_ value: AIImageAttachment) -> String {
        String(localized: "\(value.width) × \(value.height) 像素")
    }

    private func proposalFact(_ key: String, _ label: String, _ value: String?) -> Row? {
        .fact(key, label, value.map { $0.isEmpty ? String(localized: "清空") : $0 })
    }

    private func joined(_ values: [String?], separator: String = " · ") -> String? {
        let parts = values.compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    private func displayDate(_ value: String, zone: TimeZone? = nil) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: zone ?? .current))
    }
}

/// Display names already established by earlier committed tools within this turn.
struct AIToolRequestNames: Equatable {
    var references: [String: String] = [:]
    var chapterAtPosition: String?
    subscript(_ reference: String?) -> String? { reference.flatMap { references[$0] } }

    static func preceding(_ items: [AIProcessItem]) -> [String: Self] {
        var history: [String: String] = [:]
        var chapters: [String: [String: AIChapterResult]] = [:]
        var result: [String: Self] = [:]

        func remember(_ ref: String?, _ name: String?) {
            if let ref, let name, !name.isEmpty { history[ref] = name }
        }
        func file(_ value: JSONValue) {
            let entry = value.object
            remember(entry["ref"]?.string, entry["name"]?.string)
            remember(entry["fileRef"]?.string, entry["name"]?.string)
            if let book = entry["bookRef"]?.string, history[book] == nil { remember(book, entry["name"]?.string) }
        }
        func book(_ value: JSONValue) {
            for source in value.object["files"]?.array ?? [] { file(source) }
            remember(value.object["bookRef"]?.string, value.object["title"]?.string)
        }

        func record(_ item: AIProcessItem) {
            guard let output = item.output,
                  ["ok", "partial"].contains(output.object["status"]?.string ?? "") else { return }
            let data = output.object["data"] ?? .null
            let rows = data.object["items"]?.array ?? []
            switch item.name {
            case "ls": rows.forEach(file)
            case "search_books": rows.forEach(book)
            case "get_book": book(data)
            case "get_chapters":
                if let bytes = try? JSONEncoder().encode(data), let saved = try? JSONDecoder().decode(AIChaptersResult.self, from: bytes) {
                    for chapter in saved.items {
                        remember(chapter.chapterRef, chapter.title)
                        chapters[saved.bookRef, default: [:]][chapter.chapterRef] = chapter
                    }
                }
            case "get_marks", "get_mark":
                for mark in item.name == "get_marks" ? rows : [data] {
                    let fields = mark.object
                    remember(fields["markRef"]?.string, AIToolResultDetails.snippet(fields["noteText"]?.string ?? fields["note"]?.string ?? fields["excerpt"]?.string))
                    for variant in fields["variants"]?.array ?? [] {
                        remember(variant.object["variantRef"]?.string, AIToolResultDetails.snippet(variant.object["noteSnippet"]?.string))
                    }
                }
            case "generate_image":
                for image in data.object["attachments"]?.array ?? [] {
                    remember(image.object["attachmentRef"]?.string, String(localized: "生成的图片"))
                }
            case "find_cover":
                for cover in data.object["candidates"]?.array ?? [] {
                    remember(cover.object["attachment"]?.object["attachmentRef"]?.string, String(localized: "候选封面"))
                }
            default: break
            }
            for source in AIWebSource.committed(in: output, tool: item.name) { remember(source.id, source.title) }
            for source in output.object["sources"]?.array ?? [] {
                remember(source.object["sourceRef"]?.string, source.object["title"]?.string)
            }
        }

        let saved: [(sequence: Int, item: AIProcessItem)] = items.compactMap { item in
            item.resultSequence.map { (sequence: $0, item: item) }
        }
        var pending = saved.sorted { $0.sequence < $1.sequence }[...]
        for item in items where item.kind == .tool {
            // Tool calls in one assistant entry may run in parallel. Only use
            // outputs persisted before this request, regardless of completion order.
            while let saved = pending.first, saved.sequence < (item.callSequence ?? .max) {
                record(saved.item)
                pending = pending.dropFirst()
            }
            let input = item.input.object
            let referenceKeys = ["bookRef", "fileRef", "chapterRef", "parentRef", "scopeRef", "markRef", "variantRef", "attachmentRef"]
            var values = referenceKeys.compactMap { input[$0]?.string }
            for key in ["bookRefs", "sourceRefs"] { values += input[key]?.array?.compactMap(\.string) ?? [] }
            for placement in input["placements"]?.array ?? [] {
                values += ["fileRef", "parentRef"].compactMap { placement.object[$0]?.string }
            }
            if let ref = input["rename"]?.object["fileRef"]?.string { values.append(ref) }
            var names = Self()
            for ref in values { names.references[ref] = history[ref] }
            let books = input["bookRefs"]?.array ?? []
            if let book = input["bookRef"]?.string ?? (books.count == 1 ? books.first?.string : nil),
               let offset = (input["contextOffsetUtf8"] ?? input["offsetUtf8"]
                   ?? (input["endUtf8"] == nil ? nil : input["startUtf8"]))?.int, offset >= 0,
               let saved = chapters[book] {
                let matches = saved.values.filter { chapter in
                    chapter.level != 0 && chapter.range.startUtf8 <= UInt64(offset) && UInt64(offset) < chapter.range.endUtf8
                        && (input["endUtf8"]?.int.map { $0 >= 0 && UInt64($0) <= chapter.range.endUtf8 } ?? true)
                }
                if matches.count == 1 { names.chapterAtPosition = matches.first?.title }
            }
            if names != Self() { result[item.id] = names }
        }
        return result
    }
}
