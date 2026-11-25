import MoonreadAI
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
    let conversationID: String
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
            AIProcessRow(item: block.items[0], outcome: outcome, conversationID: conversationID,
                                     hasReplyResult: expansion.replyResultCalls.contains(block.items[0].id), expanded: expansion.reasoning.contains(block.items[0].id), toggle: toggle)
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
                        AIProcessRow(item: item, outcome: outcome, conversationID: conversationID,
                                     hasReplyResult: expansion.replyResultCalls.contains(item.id), expanded: expansion.reasoning.contains(item.id), toggle: toggle)
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
    var conversationID: String? = nil
    var hasReplyResult = false
    var expanded = false
    let toggle: AIProcessExpansionHandler
    @State private var showingDetail = false
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
                let result = AIToolResultDetails(item: item, outcome: outcome, hasReplyResult: hasReplyResult)
                if result.opensDetail {
                    Button { showingDetail = true } label: { toolLabel(result) }
                        .buttonStyle(.plain).accessibilityIdentifier("aiTool-\(item.name)")
                        .sheet(isPresented: $showingDetail) {
                            AIToolDetailView(item: item, result: result, conversationID: conversationID)
                        }
                } else {
                    toolLabel(result).accessibilityIdentifier("aiTool-\(item.name)")
                }
            } else {
                rowLabel
            }
        }
    }

    private func toolLabel(_ result: AIToolResultDetails) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: AIToolPresentation.symbol(item.name, input: item.input, output: item.output))
                .foregroundStyle(Color(uiColor: result.state == .failed ? theme.destructive : theme.secondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(AIToolPresentation.title(item.name, output: item.output))
                    .foregroundStyle(Color(uiColor: theme.ink))
                Text(result.summary)
                    .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
            }.frame(maxWidth: .infinity, alignment: .leading)
            if item.isRunning { AIProcessLoading() }
            if result.opensDetail {
                Image(systemName: "chevron.right").font(.caption2)
                    .foregroundStyle(Color(uiColor: theme.secondary)).accessibilityHidden(true)
            }
        }
        .font(.subheadline).padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: LayoutTokens.hit, alignment: .leading)
        .contentShape(.rect).accessibilityElement(children: .combine)
    }

    private var rowLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
            Text(item.text.isEmpty ? (item.isRunning ? String(localized: "思考中") : String(localized: "已思考")) : item.text)
                .lineLimit(1).truncationMode(.tail)
                .foregroundStyle(Color(uiColor: item.isRunning ? theme.ink : theme.secondary))
            Spacer(minLength: 0)
            if item.isRunning { AIProcessLoading() }
        }.font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary)).frame(minHeight: 32)
    }
}

struct AIToolDetailView: View {
    let item: AIProcessItem
    let result: AIToolResultDetails
    let conversationID: String?
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var sourcePreview: AIResultSource?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutTokens.section) {
                    if result.state != .available {
                        if result.sections.isEmpty || result.state == .empty {
                            ContentUnavailableView {
                                Label(result.state.title, systemImage: result.state.symbol)
                            } description: {
                                if let explanation = result.explanation { Text(explanation) }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                                Label(result.state.title, systemImage: result.state.symbol).font(.headline)
                                if let explanation = result.explanation { Text(explanation).font(.subheadline) }
                            }.foregroundStyle(Color(uiColor: theme.secondary))
                        }
                    }
                    ForEach(Array(result.sections.enumerated()), id: \.offset) { _, section in
                        if result.state != .empty { detailSection(section) }
                    }
                    if let excerpt = proposedMarkExcerpt {
                        detailSection(.init(title: String(localized: "建议位置"), rows: [excerpt]))
                    }
                    ForEach(Array(result.context.enumerated()), id: \.offset) { _, section in
                        detailSection(section)
                    }
                    if result.paged {
                        Text(result.hasMore ? String(localized: "仅显示本次返回的内容，还有后续结果。") : String(localized: "仅显示本次返回的内容。"))
                            .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding()
                .foregroundStyle(Color(uiColor: theme.ink))
            }.themedPage().navigationTitle(AIToolPresentation.title(item.name, output: item.output))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    SystemToolbarButton("关闭", role: .close) { dismiss() }.labelStyle(.iconOnly)
                } }
                .sheet(item: $sourcePreview) { AISourcePreview(source: $0) }
        }.tint(Color(uiColor: theme.accent)).preferredColorScheme(theme.scheme)
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private var proposedMarkExcerpt: AIToolResultDetails.Row? {
        guard let mark = result.proposedMark, let conversationID, let conversation = ai.conversation(conversationID),
              let book = try? AIReadingReferences.parseBookReference(mark.bookRef) else { return nil }
        // A proposal is read-only here. Use an already returned excerpt when it actually contains the proposed position.
        let earlier = conversation.turns.flatMap(\.process).prefix { $0.id != item.id }
        for previous in earlier.reversed() where previous.resultID != nil && previous.name == "read" {
            guard let output = previous.output, let data = output.object["data"],
                  let source = AIResultSource(data), source.book.sha == book.sha,
                  mark.startUtf8 >= source.start, mark.startUtf8 < source.end, mark.endUtf8 <= source.end,
                  let text = data.object["text"]?.string else { continue }
            let bytes = text.utf8
            let offset = Int(mark.startUtf8 - source.start)
            guard offset < bytes.count else { continue }
            let firstByte = bytes.index(bytes.startIndex, offsetBy: offset)
            guard let first = String.Index(firstByte, within: text) else { continue }
            let end: String.Index
            if mark.kind == .note {
                let endOffset = min(UInt64(bytes.count), mark.endUtf8 - source.start)
                let endByte = bytes.index(bytes.startIndex, offsetBy: Int(endOffset))
                end = String.Index(endByte, within: text) ?? text.endIndex
            } else {
                end = text.endIndex
            }
            let excerpt = String(text[first..<end].prefix(160))
            return .init(text: excerpt, label: source.title.isEmpty ? nil : source.title, source: source)
        }
        return nil
    }

    private func detailSection(_ section: AIToolResultDetails.Section) -> some View {
        VStack(alignment: .leading, spacing: LayoutTokens.control) {
            Text(section.title).font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                detailRow(row).padding(.leading, CGFloat(row.indent) * LayoutTokens.content)
            }
        }
    }

    @ViewBuilder private func detailRow(_ row: AIToolResultDetails.Row) -> some View {
        if let image = row.image, let conversationID {
            VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                AIGeneratedImageView(owner: conversationID, attachment: image)
                rowText(row).textSelection(.enabled)
                if let web = row.web, let url = URL(string: web.url) {
                    Link(destination: url) { Label(web.title, systemImage: "globe") }
                }
            }
        } else if let web = row.web, let url = URL(string: web.url) {
            Link(destination: url) { rowText(row, accessory: "arrow.up.right") }
        } else if let source = row.source {
            VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                rowText(row).textSelection(.enabled)
                Button { sourcePreview = source } label: {
                    Label("查看原文", systemImage: "book")
                }
            }
        } else {
            rowText(row).textSelection(.enabled)
        }
    }

    private func rowText(_ row: AIToolResultDetails.Row, accessory: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label = row.label {
                LabeledContent {
                    Text(verbatim: row.text).foregroundStyle(Color(uiColor: theme.ink))
                } label: { Text(verbatim: label).foregroundStyle(Color(uiColor: theme.secondary)) }
            } else if let accessory {
                Label { Text(verbatim: row.text) } icon: { Image(systemName: accessory) }
            } else {
                Text(verbatim: row.text)
            }
            if let subtitle = row.subtitle {
                Text(verbatim: subtitle).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
            }
        }.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
    }
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
    init(id: String, book: ReadingToolTarget.BookReference, start: UInt64, end: UInt64, title: String) {
        self.id = id; self.book = book; self.start = start; self.end = end; self.title = title
    }
    let id: String
    let book: ReadingToolTarget.BookReference
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
        guard let id = object["sourceRef"]?.string, let rawBook = object["bookRef"]?.string,
              let book = try? AIReadingReferences.parseBookReference(rawBook),
              let start = object["range"]?.object["startUtf8"]?.int,
              let end = object["range"]?.object["endUtf8"]?.int,
              start >= 0, end > start,
              id == AIReadingTools.ref("source", "\(rawBook):\(start):\(end)") else { return nil }
        self.id = id; self.book = book; self.start = UInt64(start); self.end = UInt64(end)
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
                .toolbar { ToolbarItem(placement: .confirmationAction) { SystemToolbarButton("关闭", role: .close) { dismiss() } } }
        }.presentationDetents([.medium, .large]).task(id: source.id) {
            do {
                let reader = AppDataService.shared
                let sha = source.book.sha
                let id = try await reader.aiBookID(sha: sha)
                let snapshot = try await reader.snapshot(id)
                guard snapshot.book.readingKey.formalSHA256 == sha else { throw AIToolError("stale_reference") }
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
                    .toolbar { ToolbarItem(placement: .confirmationAction) { SystemToolbarButton("关闭", role: .close) { preview = false }.labelStyle(.iconOnly) } }
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
    let openFilter: (AIBookFilterSuggestion) -> Void
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
            case .block(let block, let outcome, let expansion): AIProcessBlockView(block: block, outcome: outcome, conversationID: conversationID,
                                   expansion: expansion, toggle: toggleProcessItem)
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
            case .result(let result, _):
                if case .bookFilter(let suggestion, let summary) = result.body {
                    AIBookFilterCard(suggestion: suggestion, configuration: summary) { openFilter(suggestion) }
                        .accessibilityIdentifier("aiResult-\(result.id)")
                } else {
                    AIResultCard(result: result)
                }
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
    func makeUIView(context: UIViewRepresentableContext<Self>) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.accessibilityIdentifier = "aiHeaderGeometry-" + id
        return view
    }
    func updateUIView(_ view: UIView, context: UIViewRepresentableContext<Self>) {}
}

#endif
