import SwiftUI
import ImageIO
import AISDKProvider
import AISDKProviderUtils

/// The person's own words: trailing and content-hugging on the accent tint.
/// The leading reserve shrinks at accessibility sizes so long text stays comfortable.
struct AIUserMessage: View {
    let id: String
    let text: String
    let attachments: [AIReadingAttachment]
    let preview: (AIReadingAttachment) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    init(entry: AIAgentEntry, preview: @escaping (AIReadingAttachment) -> Void) {
        id = entry.id; text = entry.userText ?? AIConversationTurn.text(entry.message.object["content"])
        attachments = entry.readingAttachments; self.preview = preview
    }
    init(input: AIAgentInput, preview: @escaping (AIReadingAttachment) -> Void) {
        id = input.id; text = input.text; attachments = input.readingAttachments; self.preview = preview
    }
    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: typeSize.isAccessibilitySize ? LayoutTokens.content : 48)
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .textSelection(.enabled).foregroundStyle(Color(uiColor: theme.ink))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("aiUserMessage-\(id)")
                ForEach(attachments) { attachment in
                    Button { preview(attachment) } label: {
                        Label(attachment.summary, systemImage: attachment.symbol).labelStyle(AICompactLabelStyle())
                            .font(.footnote).lineLimit(2).multilineTextAlignment(.leading)
                            .foregroundStyle(Color(uiColor: theme.secondary))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, LayoutTokens.control).padding(.vertical, 10)
            .background(Color(uiColor: theme.accentSurface), in: .rect(cornerRadius: LayoutTokens.inputRadius))
        }
    }
}

private struct AIProcessLoading: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if reduceMotion { Image(systemName: "hourglass").font(.caption) }
            else { ProgressView().controlSize(.mini) }
        }.frame(width: 16, height: 16).accessibilityLabel("进行中")
    }
}

typealias AIProcessExpansionHandler = @MainActor @Sendable (AIProcessExpansionID) -> Void

private struct AIProcessBlockView: View {
    let block: AIProcessBlock
    let outcome: AIAgentStatus
    @Environment(\.theme) private var theme
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    let expansion: AIProcessExpansionState
    let toggle: AIProcessExpansionHandler
    private var tools: [AIProcessItem] { block.items.filter { $0.kind == .tool } }
    private var runningItem: AIProcessItem? { block.items.last(where: \.isRunning) }
    private var title: String {
        if let item = runningItem {
            return item.kind == .reasoning ? (item.text.isEmpty ? (item.isRunning ? String(localized: "思考中") : String(localized: "已思考")) : item.text) : AIToolPresentation.title(item.name)
        }
        if tools.isEmpty { return block.items.last?.text ?? "" }
        return AIToolPresentation.groupTitle(tools.map(\.name))
    }
    var body: some View {
        if block.isMessage {
            VStack(alignment: .leading, spacing: 4) {
                if block.items[0].kind == .input { Label("补充消息", systemImage: "bubble.left").font(.caption).foregroundStyle(Color(uiColor: theme.secondary)) }
                Text(block.items[0].text).textSelection(.enabled)
            }
        } else if block.items.count == 1 {
            AIProcessRow(item: block.items[0], outcome: outcome, expanded: expansion.reasoning.contains(block.items[0].id), toggle: toggle)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button { toggle(.group(block.id)) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: runningItem.map { $0.kind == .reasoning ? "sparkles" : AIToolPresentation.symbol($0.name, input: $0.input, output: $0.output) } ?? (tools.isEmpty ? "sparkles" : "list.bullet"))
                        Text(title).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(Color(uiColor: runningItem == nil ? theme.secondary : theme.ink))
                            .fontWeight(runningItem == nil ? nil : .medium)
                        Spacer(minLength: 0)
                        if runningItem != nil { AIProcessLoading() }
                        else if tools.contains(where: { $0.output?.object["status"]?.string == "error" }) { Image(systemName: "exclamationmark.circle").foregroundStyle(Color(uiColor: theme.destructive)) }
                        else if !tools.isEmpty { Text("\(tools.count) 次调用").font(.footnote).monospacedDigit() }
                        Image(systemName: "chevron.right").font(.caption2)
                            .rotationEffect(.degrees(expansion.group ? 90 : 0))
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: expansion.group)
                    }.font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary)).frame(minHeight: 32)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(expansion.group ? String(localized: "已展开") : String(localized: "已收起"))
                    .accessibilityIdentifier("aiProcessGroup-\(block.id)")
                    .aiProcessHeaderGeometry("group-" + block.id)
                if expansion.group {
                    ForEach(block.items) { item in
                        AIProcessRow(item: item, outcome: outcome, expanded: expansion.reasoning.contains(item.id), toggle: toggle)
                    }
                }
            }.accessibilityElement(children: .contain)
        }
    }
}

struct AIProcessRow: View {
    let item: AIProcessItem
    let outcome: AIAgentStatus
    @Environment(\.theme) private var theme
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    var expanded = false
    let toggle: AIProcessExpansionHandler
    @State private var detail: AIProcessItem?
    var body: some View {
        Group {
            if item.kind == .reasoning && !item.text.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Button { toggle(.reasoning(item.id)) } label: {
                        HStack(spacing: 8) {
                            rowLabel
                            Image(systemName: "chevron.right").font(.caption2)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: expanded)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).fixedSize(horizontal: false, vertical: true).foregroundStyle(Color(uiColor: theme.secondary))
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(expanded ? String(localized: "已展开") : String(localized: "已收起"))
                        .accessibilityIdentifier("aiReasoning-\(item.id)")
                        .aiProcessHeaderGeometry("reasoning-" + item.id)
                    if expanded {
                        Text(item.text).textSelection(.enabled).font(.subheadline)
                            .foregroundStyle(Color(uiColor: theme.ink))
                    }
                }.accessibilityElement(children: .contain)
            } else if item.kind == .tool {
                Button { detail = item } label: {
                    HStack(spacing: 8) {
                        rowLabel
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Color(uiColor: theme.secondary))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("aiTool-\(item.name)")
            } else {
                rowLabel
            }
        }.sheet(item: $detail) { _ in AIToolDetailView(item: item, outcome: outcome) }
    }
    private var rowLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind == .reasoning ? "sparkles" : AIToolPresentation.symbol(item.name, input: item.input, output: item.output))
            Text(item.kind == .reasoning ? (item.text.isEmpty ? (item.isRunning ? String(localized: "思考中") : String(localized: "已思考")) : item.text) : AIToolPresentation.title(item.name, output: item.output))
                .lineLimit(1).truncationMode(.tail)
                .foregroundStyle(Color(uiColor: failed ? theme.destructive : item.isRunning ? theme.ink : theme.secondary))
            Spacer(minLength: 0)
            if item.isRunning { AIProcessLoading() }
            else if item.kind == .tool && item.output?.object["status"]?.string != "ok" {
                Text(AIToolPresentation.status(item.output, outcome: outcome)).font(.footnote)
            }
        }.font(.subheadline).foregroundStyle(Color(uiColor: failed ? theme.destructive : theme.secondary)).frame(minHeight: 32)
    }
    private var failed: Bool { item.output?.object["status"]?.string == "error" }
}

struct AIToolDetailView: View {
    static func webSources(_ output: JSONValue, tool: String) -> [AIWebSource] {
        AIWebSource.committed(in: output, tool: tool)
    }
    let item: AIProcessItem
    let outcome: AIAgentStatus
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var sourcePreview: AIResultSource?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 8) {
                        if item.isRunning { AIProcessLoading() }
                        Text(AIToolPresentation.status(item.output, outcome: outcome))
                    }.font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("调用参数").font(.headline)
                        AIValueView(value: item.input)
                    }
                    if let output = item.output, item.name == "find_cover", output.object["status"]?.string != "error" {
                        AIFindCoverDetail(output: output)
                    } else if let output = item.output {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("结果").font(.headline)
                            AIValueView(value: output)
                            // web_search lists sources at the top level; find_cover nests them in data.
                            ForEach(Self.webSources(output, tool: item.name)) { source in
                                if let url = URL(string: source.url), ["https", "http"].contains(url.scheme) {
                                    Link(destination: url) { Label(source.title, systemImage: "globe") }
                                }
                            }
                            ForEach(AIResultSource.all(in: output)) { source in
                                Button { sourcePreview = source } label: {
                                    Label(source.title.isEmpty ? String(localized: "查看原文") : source.title, systemImage: "book")
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .top], 20).padding(.bottom)
                    .foregroundStyle(Color(uiColor: theme.ink))
            }.themedPage().navigationTitle(AIToolPresentation.title(item.name, output: item.output))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("关闭", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                } }
                .sheet(item: $sourcePreview) { AISourcePreview(source: $0) }
        }.tint(Color(uiColor: theme.accent)).preferredColorScheme(theme.scheme)
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}

/// Cover search reads as a search: the service's answer and the pages it cited first, then what
/// became candidates. Candidates themselves are reviewed in the cover result, not here.
private struct AIFindCoverDetail: View {
    @Environment(\.theme) private var theme
    let output: JSONValue
    var body: some View {
        let data = output.object["data"]?.object ?? [:]
        let candidates = data["candidates"]?.array ?? []
        let sources = AIToolDetailView.webSources(output, tool: "find_cover")
        VStack(alignment: .leading, spacing: 20) {
            if let answer = data["answer"]?.string, !answer.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("搜索回答").font(.headline)
                    Text(verbatim: answer).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("网页来源").font(.headline)
                if sources.isEmpty {
                    Text("没有网页来源").foregroundStyle(Color(uiColor: theme.secondary))
                } else {
                    ForEach(sources) { source in
                        if let url = URL(string: source.url), ["https", "http"].contains(url.scheme) {
                            Link(destination: url) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(source.title, systemImage: "globe")
                                    Text(verbatim: url.host ?? source.url).font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                                }.frame(maxWidth: .infinity, minHeight: LayoutTokens.hit, alignment: .leading).contentShape(Rectangle())
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("封面候选").font(.headline)
                Text(candidates.isEmpty ? String(localized: "没有图片候选") : String(localized: "\(candidates.count) 张图片可在封面结果中查看"))
                    .foregroundStyle(Color(uiColor: theme.secondary))
            }
        }
    }
}

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

private struct AIValueView: View {
    let value: JSONValue
    var body: some View {
        // A selectable structured document, without an extra hierarchy of disclosure controls.
        Text(Self.describe(value)).textSelection(.enabled).font(.subheadline)
    }
    private static func describe(_ value: JSONValue, depth: Int = 0) -> String {
        switch value {
        case .object(let object): object.keys.sorted().filter { !["sourceRef", "bookRef", "fileRef", "markRef", "chapterRef", "ref", "attachmentRef", "proposalRef", "previewRef", "nextCursor", "parentRef", "cursor", "startUtf8", "endUtf8", "contextOffsetUtf8", "range", "visibleRange", "maxBytes"].contains($0) }.map { key in
            let label = labels[key] ?? key
            return label + ": " + describe(object[key]!, depth: depth + 1)
        }.joined(separator: "\n")
        case .array(let values): values.map { describe($0, depth: depth + 1) }.joined(separator: "\n\n")
        case .string(let text): text
        case .number(let value): value.formatted()
        case .bool(let value): value ? String(localized: "是") : String(localized: "否")
        case .null: "—"
        }
    }
    private static let labels = ["title": String(localized: "书名"), "text": String(localized: "正文"), "query": String(localized: "搜索"), "note": String(localized: "批注"), "excerpt": String(localized: "摘录"), "sources": String(localized: "来源"), "status": String(localized: "状态"), "items": String(localized: "条目"), "total": String(localized: "总计")]
}
extension AIConversation {
    var activityTitle: String {
        switch activity.status {
        case .waitingDataSharing: return String(localized: "等待数据共享确认")
        case .waitingConfirmation: return String(localized: "等待确认")
        case .compacting: return String(localized: "整理上下文")
        default:
            let pending = head.pendingCalls.filter { $0.output == nil }
            if pending.count > 1 { return String(localized: "正在执行 \(pending.count) 项操作") }
            return pending.first.map { AIToolPresentation.title($0.name) } ?? (activity.reasoningActive ? String(localized: "正在思考") : String(localized: "正在回复"))
        }
    }
    /// All tools and reasoning share one working state; activityTitle retains
    /// the precise operation for VoiceOver.
    var moonSnapshot: AIMoonSnapshot {
        AIMoonSnapshot(conversationID: id, running: running, status: activity.status,
            pose: .live(running: running, status: activity.status,
                        hasTools: head.pendingCalls.contains { $0.output == nil }, reasoning: activity.reasoningActive),
            label: running ? activityTitle : "")
    }
    /// Whether the latest turn left a proposal for the person to review.
    var latestTurnProposes: Bool {
        turns.last?.process.contains { item in
            guard item.kind == .tool, item.name.hasPrefix("propose_"), let output = item.output else { return false }
            return !["denied", "error"].contains(output.object["status"]?.string ?? "")
        } ?? false
    }
}

struct AIResultSource: Identifiable {
    init(id: String, bookRef: String, start: UInt64, end: UInt64, title: String) {
        self.id = id; self.bookRef = bookRef; self.start = start; self.end = end; self.title = title
    }
    let id: String
    let bookRef: String
    let start: UInt64
    let end: UInt64
    let title: String
    static func all(in output: JSONValue) -> [AIResultSource] {
        let data = output.object["data"] ?? .null
        let items = (data.object["items"]?.array ?? []).map { item -> JSONValue in
            var value = item.object
            value["bookRef"] = value["bookRef"] ?? data.object["bookRef"]
            return .object(value)
        }
        let values = [data] + (output.object["sources"]?.array ?? [])
            + (data.object["hits"]?.array ?? []) + items
        var seen = Set<String>()
        return values.compactMap(Self.init).filter { seen.insert($0.id).inserted }
    }
    init?(_ value: JSONValue) {
        let object = value.object
        guard let id = object["sourceRef"]?.string, let book = object["bookRef"]?.string,
              (try? AIReadingReferences.parseBookReference(book)) != nil,
              let start = object["range"]?.object["startUtf8"]?.int,
              let end = object["range"]?.object["endUtf8"]?.int,
              start >= 0, end > start,
              id == AIReadingTools.ref("source", "\(book):\(start):\(end)") else { return nil }
        self.id = id; bookRef = book; self.start = UInt64(start); self.end = UInt64(end)
        title = object["title"]?.string ?? object["chapterTitle"]?.string ?? ""
    }
}
struct AISourcePreview: View {
    let source: AIResultSource
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                if let text { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                else if let error { Text(error).padding() }
                else { ProgressView().padding() }
            }.themedPage().navigationTitle(source.title.isEmpty ? String(localized: "原文") : source.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium, .large]).task(id: source.id) {
            do {
                let reader = AppDataService.shared
                let sha = String(source.bookRef.dropFirst(2))
                let id = try await reader.aiBookID(sha: sha)
                let snapshot = try await reader.snapshot(id)
                guard snapshot.book.contentSha256 == sha else { throw AIToolError("stale_reference") }
                // Inspect the exact, bounded, SHA-keyed source; never write reading position/statistics.
                guard source.end - source.start <= 65_536 else { throw AIToolError("resource_limit") }
                let range = try await reader.textRange(id, start: source.start, end: source.end)
                text = range.text
            } catch { self.error = String(localized: "此处原文暂时不可用。") }
        }
    }
}

private struct AIGeneratedImageView: View {
    let owner: String
    let attachment: AIImageAttachment
    @State private var image: UIImage?
    @State private var failed = false
    @State private var preview = false
    var body: some View {
        Group {
            if let image {
                Button { preview = true } label: {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 320)
                        .clipShape(.rect(cornerRadius: 12))
                }.buttonStyle(.plain).accessibilityLabel("查看生成图片")
            } else if failed { Label("图片无法读取", systemImage: "photo") }
            else { ProgressView() }
        }.task(id: attachment.id) {
            do {
                let data = try await AIImageStore.shared.read(owner: owner, ref: attachment.id)
                let thumbnail = await Task.detached {
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return Optional<CGImage>.none }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1600,
                        kCGImageSourceCreateThumbnailWithTransform: true
                    ] as CFDictionary)
                }.value
                if let thumbnail { image = UIImage(cgImage: thumbnail) } else { failed = true }
            } catch { failed = true }
        }.sheet(isPresented: $preview) {
            NavigationStack {
                if let image { Image(uiImage: image).resizable().scaledToFit().padding().themedPage()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭", systemImage: "xmark") { preview = false }.labelStyle(.iconOnly) } }
                }
            }
        }
    }
}

/// One hosting cell is one presentation block. Navigation and previews remain SwiftUI.
struct AIMessageRowView: View {
    let row: AIMessageRow
    let conversationID: String
    let taskObject: AITaskObject?
    let preview: (AIReadingAttachment) -> Void
    let loadEarlier: () -> Void
    let toggleProcessItem: AIProcessExpansionHandler
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    var body: some View {
        Group {
            switch row.content {
            case .header:
                if let taskObject { AITaskObjectHeader(object: taskObject) }
            case .earlier:
                Button("加载较早消息", action: loadEarlier).frame(maxWidth: .infinity, minHeight: LayoutTokens.hit)
                    .accessibilityIdentifier("aiLoadEarlier")
            case .later:
                Button("加载较新消息") { ai.loadLater(conversationID) }.frame(maxWidth: .infinity, minHeight: LayoutTokens.hit)
                    .accessibilityIdentifier("aiLoadLater")
            case .user(let entry): AIUserMessage(entry: entry, preview: preview)
            case .queued(let input):
                AIUserMessage(input: input, preview: preview).opacity(0.6)
                    .accessibilityValue(input.mode == .steering ? "排队中，调整当前任务" : "排队中，完成后发送")
                    .accessibilityAction(named: "取消发送") { ai.cancelQueued(conversationID, inputID: input.id) }
                    .contextMenu { Button("取消发送", systemImage: "xmark") { ai.cancelQueued(conversationID, inputID: input.id) } }
            case .block(let block, let outcome, let expansion): AIProcessBlockView(block: block, outcome: outcome, expansion: expansion, toggle: toggleProcessItem)
            case .processToggle(let expanded):
                Button { if let turn = row.turnID { ai.conversation(conversationID)?.toggleProcess(turn) } } label: {
                    Label("查看过程", systemImage: expanded ? "chevron.down" : "chevron.right")
                        .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary)).frame(minHeight: LayoutTokens.hit)
                }.buttonStyle(.plain).accessibilityIdentifier("aiTurnProcess")
            case .waiting(let status):
                HStack(spacing: LayoutTokens.compact) {
                    if status == .compacting {
                        Image(systemName: "archivebox")
                        Text("整理上下文")
                        AIProcessLoading()
                    } else {
                        AIProcessLoading().accessibilityLabel("等待回复")
                    }
                }.font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary)).frame(minHeight: 32)
            case .generating: AIProcessLoading()
            case .confirmation(let confirmation):
                VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                    Text("准备正文？").font(.headline)
                    Text(confirmation.reason).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: LayoutTokens.compact) { Spacer(minLength: 0); confirmationActions(confirmation) }
                        VStack(alignment: .trailing, spacing: LayoutTokens.compact) { confirmationActions(confirmation) }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }.padding(LayoutTokens.content)
                    .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: LayoutTokens.inputRadius))
            case .image(let image): AIGeneratedImageView(owner: conversationID, attachment: image)
            case .result(let result, _): AIResultCard(result: result)
            case .error(let text): Label(text, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(Color(uiColor: theme.destructive))
            case .actions(let answer, let outcome):
                HStack(spacing: LayoutTokens.compact) {
                    if !answer.isEmpty {
                        Button("复制回复", systemImage: "doc.on.doc") { UIPasteboard.general.string = answer }
                            .labelStyle(.iconOnly).frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit, alignment: .leading)
                            .accessibilityIdentifier("aiCopyReply")
                    }
                    if [.stopped, .interrupted].contains(outcome) {
                        Text(outcome == .stopped ? "已停止" : "回复已中断").font(.footnote)
                    }
                }.foregroundStyle(Color(uiColor: theme.secondary))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Color(uiColor: theme.ink)).tint(Color(uiColor: theme.accent))
    }
    @ViewBuilder private func confirmationActions(_ confirmation: AIAgentConfirmation) -> some View {
        Button("暂不准备") { ai.answer(conversationID, confirmationID: confirmation.id, approved: false) }.buttonStyle(.bordered)
        Button("准备正文") { ai.answer(conversationID, confirmationID: confirmation.id, approved: true) }.buttonStyle(ThemedProminentButtonStyle())
    }
}

private extension View {
    @ViewBuilder func aiProcessHeaderGeometry(_ id: String) -> some View {
#if DEBUG
        background(AIProcessHeaderGeometry(id: id))
#else
        self
#endif
    }
}

#if DEBUG
// The transparent marker exposes the actual header bounds to local frame diagnostics.
private struct AIProcessHeaderGeometry: UIViewRepresentable {
    let id: String
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.accessibilityIdentifier = "aiHeaderGeometry-" + id
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
}

#endif
