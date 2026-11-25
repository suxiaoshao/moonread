import AISDKProvider
import Foundation
import MoonreadAI

/// Read-only presentation of the saved output. Only committed conversation rows own actions.
struct AIToolResultDetails {
    enum State: Equatable {
        case running, waiting, stopped, denied, failed, partial, empty, available, missing

        var title: String {
            switch self {
            case .running: String(localized: "执行中")
            case .waiting: String(localized: "等待确认")
            case .stopped: String(localized: "已停止")
            case .denied: String(localized: "未准备")
            case .failed: String(localized: "未完成")
            case .partial: String(localized: "部分结果")
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
            case .partial: "circle.lefthalf.filled"
            case .empty, .missing: "magnifyingglass"
            case .available: "checkmark.circle"
            }
        }
    }

    struct Row {
        let text: String
        var label: String?
        var subtitle: String?
        var source: AIResultSource?
        var web: AIWebSource?
        var image: AIImageAttachment?
        var indent: Int = 0

        static func fact(_ label: String, _ value: String?) -> Self? {
            guard let value, !value.isEmpty else { return nil }
            return .init(text: value, label: label)
        }
    }
    struct Section {
        let title: String
        let rows: [Row]
    }

    private let item: AIProcessItem
    private let outcome: AIAgentStatus
    private let hasReplyResult: Bool
    private let result: JSONValue
    private let input: [String: JSONValue]
    private let data: JSONValue
    private let bytes: Data?
    private(set) var sections: [Section] = []
    private(set) var context: [Section] = []
    private(set) var proposedMark: AINoteProposal?
    private var fact: String?
    private var empty = false
    private var incomplete = false
    private var status: String? { result.object["status"]?.string }
    private var code: String? { result.object["error"]?.object["code"]?.string }

    init(item: AIProcessItem, outcome: AIAgentStatus, hasReplyResult: Bool) {
        self.item = item
        self.outcome = outcome
        self.hasReplyResult = hasReplyResult
        result = item.output ?? .null
        input = item.input.object
        data = result.object["data"] ?? .null
        bytes = try? JSONEncoder().encode(data)
        project()
    }

    var opensDetail: Bool { !(hasReplyResult && status == "ok") }
    var paged: Bool {
        let page = result.object["page"]?.object
        return page?["complete"] == .bool(false) || input["cursor"]?.string != nil
    }
    var hasMore: Bool { result.object["page"]?.object["complete"] == .bool(false) }

    var state: State {
        switch status {
        case "denied": return .denied
        case "error": return code == "cancelled" ? .stopped : .failed
        case "partial": return .partial
        case "ok":
            if incomplete { return .partial }
            if empty && !paged { return .empty }
            return sections.isEmpty ? .missing : .available
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

    var summary: String {
        switch state {
        case .available: return fact ?? state.title
        case .partial: return [fact, state.title].compactMap { $0 }.joined(separator: " · ")
        case .failed, .denied, .stopped:
            return [state.title, fact].compactMap { $0 }.joined(separator: " · ")
        default: return state.title
        }
    }

    var explanation: String? {
        switch state {
        case .running: String(localized: "结果会在此调用完成后显示。")
        case .waiting: String(localized: "此调用需要确认后才能继续。")
        case .denied: String(localized: "未同意准备所需内容，此调用没有执行。")
        case .stopped:
            sections.isEmpty ? String(localized: "此调用停止，没有返回结果。") : String(localized: "此调用停止，下面是已取得的内容。")
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
            default: String(localized: "此次操作未能完成。")
            }
        case .partial: String(localized: "以下为本次取得的内容，结果尚不完整。")
        case .empty:
            switch item.name {
            case "search_books": String(localized: "本次查询没有找到匹配的小说。")
            case "rg": String(localized: "已搜索的范围内没有匹配的片段。")
            default: nil
            }
        case .available, .missing: nil
        }
    }

    private func decode<T: Decodable>(_ type: T.Type) -> T? {
        bytes.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private mutating func add(_ title: String, _ rows: [Row?]) {
        let values = rows.compactMap { $0 }
        if !values.isEmpty { sections.append(.init(title: title, rows: values)) }
    }

    private mutating func query() {
        if let row = Row.fact(String(localized: "关键词"), input["query"]?.string) {
            context.append(.init(title: String(localized: "查询"), rows: [row]))
        }
    }

    private mutating func project() {
        switch item.name {
        case "ls": library()
        case "search_books": books()
        case "list_filter_options": filterOptions()
        case "get_book": book()
        case "get_chapters":
            query()
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
            if let content, !content.isEmpty { add(String(localized: "结果"), [.init(text: content)]) }
        }
    }

    private mutating func library() {
        guard let value = decode(AILibraryResult.self) else { return }
        empty = value.items.isEmpty
        if value.parentRef == nil, input["parentRef"]?.string == nil {
            let count = value.items.count
            fact = String(localized: "本次返回 \(count) 个书架")
        } else {
            let folders = value.items.filter { $0.kind == "folder" }.count
            let files = value.items.filter { $0.kind == "file" }.count
            if folders + files == value.items.count {
                fact = String(localized: "本次返回 \(folders) 个文件夹、\(files) 个文件")
            } else {
                fact = returnedItems(value.items.count)
            }
        }
        add(String(localized: "目录"), value.items.map(file))
    }

    private mutating func books() {
        query()
        guard let value = decode(AIBooksResult.self) else { return }
        let count = value.items.count
        empty = count == 0
        fact = String(localized: "本次返回 \(count) 本小说")
        add(String(localized: "匹配的小说"), value.items.map { book in
            let sources = book.files.map { file in joined([file.name, availability(file.availability)]) }.compactMap { $0 }
            return .init(text: book.title, subtitle: joined([book.author, availability(book.availability), sources.isEmpty ? nil : sources.joined(separator: "\n")], separator: "\n"))
        })
    }

    private mutating func filterOptions() {
        query()
        guard let value = decode(AIFilterOptionsResult.self) else { return }
        let count = value.names.count
        empty = count == 0
        let heading: String
        switch input["field"]?.string {
        case "tag": heading = String(localized: "标签"); fact = String(localized: "本次返回 \(count) 个标签")
        case "author": heading = String(localized: "作者"); fact = String(localized: "本次返回 \(count) 位作者")
        case "shelf": heading = String(localized: "书架"); fact = String(localized: "本次返回 \(count) 个书架")
        default: heading = String(localized: "结果"); fact = returnedItems(count)
        }
        add(heading, value.names.map { .init(text: $0) })
    }

    private mutating func book() {
        guard let value = decode(AIBookResult.self) else { return }
        fact = joined([value.title, value.author])
        let words = value.wordCount.map { String(localized: "\($0) 字") }
        let chapters = value.chapterCount.map { String(localized: "\($0) 章") }
        let progress = value.progress.map { ($0.percent / 100).formatted(.percent.precision(.fractionLength(0...1))) }
        add(value.title, [
            .fact(String(localized: "作者"), value.author),
            .fact(String(localized: "标签"), value.tags?.joined(separator: String(localized: "、"))),
            .fact(String(localized: "阅读状态"), value.readingStatus.flatMap { BookSearchStatus(rawValue: $0)?.title }),
            .fact(String(localized: "正文字数"), words),
            .fact(String(localized: "章节"), chapters),
            .fact(String(localized: "阅读进度"), progress),
            .fact(String(localized: "当前章节"), value.progress?.chapterTitle),
            .fact(String(localized: "本机状态"), availability(value.availability)),
        ])
        if let synopsis = value.synopsis ?? value.synopsisSnippet, !synopsis.isEmpty {
            add(String(localized: "简介"), [.init(text: synopsis, subtitle: value.synopsisTruncated == true ? String(localized: "仅返回部分内容") : nil)])
        }
        add(String(localized: "文件来源"), value.files.map(file))
        incomplete = value.filesTruncated == true
    }

    private mutating func chapters(_ value: AIChaptersResult, statistics: Bool = false) {
        let volumes = value.items.filter { $0.level == 0 }.count
        let count = value.items.count - volumes
        fact = volumes == 0 ? String(localized: "本次返回 \(count) 章") : String(localized: "本次返回 \(volumes) 卷、\(count) 章")
        incomplete = incomplete || !value.outlineComplete
        empty = value.items.isEmpty && value.outlineComplete
        let sources = AIResultSource.all(in: result)
        add(String(localized: "章节"), value.items.map { chapter in
            let words = chapter.countComplete ? String(localized: "\(chapter.wordCount) 字") : String(localized: "\(chapter.wordCount) 字以上")
            let coverage = chapter.estimatedCoveragePercent.map { (($0 / 100).formatted(.percent.precision(.fractionLength(0...1)))) }
            return .init(text: chapter.title,
                         subtitle: statistics ? joined([words, coverage.map { String(localized: "估算覆盖 \($0)") }]) : words,
                         source: sources.first { $0.start == chapter.range.startUtf8 && $0.end == chapter.range.endUtf8 },
                         indent: chapter.parentChapterRef == nil ? 0 : 1)
        })
    }

    private mutating func read() {
        guard let value = decode(AIReadResult.self) else { return }
        if value.text.isEmpty { empty = true; return }
        let source = AIResultSource.all(in: result).first
        fact = joined([source?.title, hasMore ? String(localized: "已读取片段，还有后续内容") : String(localized: "已读取片段")])
        add(String(localized: "正文片段"), [.init(text: value.text, source: source)])
    }

    private mutating func hits() {
        query()
        guard let value = decode(AISearchResult.self) else { return }
        let count = value.hits.count
        fact = joined([input["query"]?.string, String(localized: "本次返回 \(count) 处命中")])
        incomplete = value.truncated || value.coverage.contains { !$0.complete }
        empty = count == 0 && !incomplete && !value.coverage.isEmpty
        var books: [String] = []
        for ref in value.coverage.map(\.bookRef) + value.hits.map(\.bookRef) where !books.contains(ref) { books.append(ref) }
        let sources = AIResultSource.all(in: result)
        for (index, book) in books.enumerated() {
            let group = value.hits.filter { $0.bookRef == book }
            let coverage = value.coverage.first { $0.bookRef == book }
            let heading = books.count == 1 ? String(localized: "命中片段") : String(localized: "第 \(index + 1) 本")
            var rows = group.map { hit in Row(text: hit.excerpt, label: hit.chapterTitle, source: sources.first { $0.id == hit.sourceRef }) }
            if let coverage {
                let label = coverage.complete ? String(localized: "已搜索请求范围") :
                    coverage.status == "not_scanned" ? String(localized: "尚未搜索这本书") : String(localized: "仅搜索了部分范围")
                rows.insert(.init(text: label), at: 0)
            }
            add(heading, rows)
        }
    }

    private mutating func marks() {
        let sources = AIResultSource.all(in: result)
        if item.name == "get_marks" {
            query()
            guard let value = decode(AIMarksResult.self) else { return }
            let bookmarks = value.items.filter { $0.kind == "bookmark" }.count
            let annotations = value.items.filter { $0.kind == "annotation" }.count
            fact = bookmarks + annotations == value.items.count
                ? String(localized: "本次返回 \(bookmarks) 个书签、\(annotations) 条批注")
                : returnedItems(value.items.count)
            empty = value.items.isEmpty
            add(String(localized: "书签与批注"), value.items.map { markRow($0, sources: sources) })
        } else if let mark = decode(AIMarkResult.self) {
            let variants = mark.variants ?? []
            fact = variants.isEmpty ? markKind(mark) : String(localized: "有 \(variants.count) 个版本")
            if let note = mark.noteText ?? mark.note, !note.isEmpty { add(String(localized: "批注"), [.init(text: note)]) }
            if let excerpt = mark.excerpt, !excerpt.isEmpty {
                add(String(localized: "摘录"), [.init(text: excerpt, source: sources.first { $0.id == mark.sourceRef })])
            } else {
                add(String(localized: "位置"), [markRow(mark, sources: sources)])
            }
            add(String(localized: "批注版本"), variants.enumerated().map { index, variant in
                Row(text: variant.deleted ? String(localized: "已删除") : variant.noteSnippet,
                    label: String(localized: "版本 \(index + 1)"))
            })
            incomplete = mark.noteTruncated == true || mark.excerptTruncated == true
        }
    }

    private mutating func statistics() {
        let view = input["view"]?.string
        let heading: String
        switch view {
        case "days": heading = String(localized: "逐日")
        case "books": heading = String(localized: "逐书")
        case "sessions": heading = String(localized: "阅读时段")
        case "chapters": heading = String(localized: "章节")
        default: heading = String(localized: "汇总")
        }
        let dates = joined([input["fromDate"]?.string, input["toDate"]?.string], separator: " – ")
        if let row = Row.fact(heading, dates) {
            context.append(.init(title: String(localized: "范围"), rows: [row]))
        }
        guard let value = decode(AIStatisticsResult.self) else { return }
        incomplete = value.incomplete == true
        if let value = value.chapters { chapters(value, statistics: true); return }
        if let duration = value.durationMs {
            let time = StatisticsDates.duration(duration)
            fact = joined([dates, time])
            add(heading, [
                .fact(String(localized: "阅读时长"), time),
                .fact(String(localized: "阅读日"), value.readingDays?.formatted()),
                .fact(String(localized: "小说"), value.bookCount?.formatted()),
                .fact(String(localized: "统计记录"), value.recordingEnabledOnDevice == false ? String(localized: "阅读统计已暂停") : nil),
            ])
        }
        if let rows = value.items {
            fact = joined([dates, returnedItems(rows.count)])
            empty = rows.isEmpty && !incomplete
            add(heading, rows.map { row in
                let date = row.date ?? row.recordedDate
                let duration = StatisticsDates.duration(row.durationMs)
                let zone = row.utcOffsetSeconds.flatMap { TimeZone(secondsFromGMT: Int($0)) }
                let started = row.startedAt.map { displayDate($0, zone: zone) }
                let ended = row.endedAt.map { displayDate($0, zone: zone) }
                let days = row.readingDays.map { String(localized: "\($0) 个阅读日") }
                let books = row.bookCount.map { String(localized: "\($0) 本小说") }
                let status = row.preview == true ? String(localized: "查阅") : nil
                return .init(text: joined([row.title, date, duration]) ?? duration,
                             subtitle: joined([joined([started, ended], separator: " – "), days, books, status]))
            })
        }
    }

    private mutating func environment() {
        guard let value = decode(AIEnvironmentResult.self) else { return }
        let time = value.now.map { displayDate($0, zone: value.timeZone.flatMap(TimeZone.init(identifier:))) }
        let language = value.appLanguage.map { Locale.current.localizedString(forIdentifier: $0) ?? $0 }
        let region = value.region.map { Locale.current.localizedString(forRegionCode: $0) ?? $0 }
        fact = joined([time, language])
        add(String(localized: "时间与语言"), [
            .fact(String(localized: "本地时间"), time),
            .fact(String(localized: "时区"), value.timeZone),
            .fact(String(localized: "语言"), language),
            .fact(String(localized: "地区"), region),
        ])
    }

    private mutating func web() {
        query()
        let sources = AIWebSource.committed(in: result, tool: item.name)
        let answer = data.object["answer"]?.string
        if let answer, !answer.isEmpty { add(String(localized: "搜索回答"), [.init(text: answer)]) }
        add(String(localized: "网页来源"), sources.map { .init(text: $0.title, subtitle: URL(string: $0.url)?.host, web: $0) })
        if item.name == "find_cover", let value = decode(AIFindCoverResult.self) {
            let candidates = value.candidates.count
            let count = sources.count
            fact = String(localized: "\(candidates) 张候选图片 · \(count) 个网页来源")
            add(String(localized: "封面候选"), value.candidates.map(cover))
            empty = candidates == 0 && sources.isEmpty && (answer?.isEmpty ?? true)
        } else if item.name == "web_search" {
            incomplete = data.object["truncated"] == .bool(true)
            if (try? JSONDecoder().decode(AINativeResult.self, from: JSONEncoder().encode(result))) != nil {
                let count = sources.count
                fact = joined([input["query"]?.string, String(localized: "\(count) 个网页来源")])
                empty = sources.isEmpty && (answer?.isEmpty ?? true) && !incomplete
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
        if count > 0 || attachments.isEmpty { fact = String(localized: "返回 \(count) 张图片") }
        empty = attachments.isEmpty
        add(String(localized: "图片"), images.map { .init(text: dimensions($0), image: $0) })
    }

    private mutating func filterProposal() {
        guard let suggestion = decode(AIBookFilterSuggestion.self), let configuration = try? suggestion.filter.configuration(resolveShelf: { $0 }) else { return }
        fact = String(localized: "已生成筛选建议")
        if !configuration.root.children.isEmpty {
            add(String(localized: "筛选条件"), [.init(text: configuration.root.expression { $0 })])
        }
        add(String(localized: "排序"), configuration.sorts.map {
            .init(text: $0.field.title, subtitle: $0.descending ? String(localized: "降序") : String(localized: "升序"))
        })
    }

    private mutating func proposal() {
        guard let snapshot = decode(AIProposalSnapshot.self) else { return }
        switch (item.name, snapshot) {
        case ("propose_cover", .cover(let value)):
            fact = String(localized: "建议使用 1 张封面")
            add(String(localized: "封面候选"), [cover(value)])
        case ("propose_book_metadata", .metadata(let value)):
            let changes = [
                proposalFact(String(localized: "作者"), value.author),
                proposalFact(String(localized: "简介"), value.synopsis),
                proposalFact(String(localized: "标签"), value.tags?.joined(separator: String(localized: "、"))),
                .fact(String(localized: "阅读状态"), value.readingStatus.flatMap { BookSearchStatus(rawValue: $0.rawValue)?.title }),
            ]
            let count = changes.compactMap { $0 }.count
            fact = value.rename == nil ? String(localized: "建议修改 \(count) 项资料") : String(localized: "建议修改 \(count) 项资料和文件名")
            add(String(localized: "资料变更"), changes)
            if let rename = value.rename, let target = try? rename.filename(stem: rename.name) {
                add(String(localized: "文件名变更"), [
                    .fact(String(localized: "原文件名"), rename.originalName),
                    .fact(String(localized: "建议文件名"), target),
                ])
            }
        case ("propose_note", .notes(let value)) where value.kind == .note:
            fact = String(localized: "建议添加 1 条批注")
            proposedMark = value
            add(String(localized: "批注草稿"), [.init(text: value.note)])
        case ("propose_bookmark", .notes(let value)) where value.kind == .bookmark:
            fact = String(localized: "建议添加 1 个书签")
            proposedMark = value
            add(String(localized: "书签建议"), [.init(text: String(localized: "已选定书签位置。"))])
        case ("propose_library_organization", .organization(let value)):
            let folders = value.input.folders.count
            let moves = value.input.placements.count
            fact = String(localized: "建议新建 \(folders) 个文件夹、移动 \(moves) 项")
            add(String(localized: "建议新建的文件夹"), value.input.folders.map { .init(text: $0.name) })
            add(String(localized: "建议移动的项目"), value.input.placements.enumerated().map { index, placement in
                .init(text: placement.name ?? String(localized: "第 \(index + 1) 项"),
                      subtitle: value.input.folders.first { $0.temporaryRef == placement.parentRef }?.name)
            })
        default: break
        }
    }

    private func returnedItems(_ count: Int) -> String { String(localized: "本次返回 \(count) 项") }

    private func file(_ value: AIFileResult) -> Row {
        let kind: String? = switch value.kind {
        case "folder": String(localized: "文件夹")
        case "file": String(localized: "文件")
        case "shelf": String(localized: "书架")
        default: nil
        }
        return .init(text: value.name, subtitle: joined([kind, availability(value.availability)]))
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

    private func markRow(_ value: AIMarkResult, sources: [AIResultSource]) -> Row {
        let source = sources.first { $0.id == value.sourceRef }
        let subtitle = joined([value.createdAt.map { displayDate($0) }, value.hasConflict == true ? String(localized: "有多个版本") : nil])
        let title = markKind(value) ?? String(localized: "标注")
        return .init(text: joined([value.note ?? value.noteText, value.excerpt], separator: "\n") ?? title,
                     label: title, subtitle: subtitle, source: source)
    }

    private func cover(_ value: AICoverProposal) -> Row {
        .init(text: dimensions(value.attachment), subtitle: value.origin.caption, web: value.origin.webSource, image: value.attachment)
    }

    private func dimensions(_ value: AIImageAttachment) -> String {
        String(localized: "\(value.width) × \(value.height) 像素")
    }

    private func proposalFact(_ label: String, _ value: String?) -> Row? {
        .fact(label, value.map { $0.isEmpty ? String(localized: "清空") : $0 })
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
