import SwiftUI
import AISDKProvider
import AISDKProviderUtils

struct AIReadingAttachmentPreview: View {
    let attachment: AIReadingAttachment
    var owner: String? = nil
    @State private var image: UIImage?
    @State private var imageError: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(attachment.summary, systemImage: attachment.symbol).font(.headline)
                    if attachment.kind == .image {
                        Text("用于图片修改")
                            .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                        if let image { Image(uiImage: image).resizable().scaledToFit().accessibilityIdentifier("aiReferenceImagePreview") }
                        else if let imageError { Text(verbatim: imageError).foregroundStyle(Color(uiColor: theme.destructive)) }
                        else { ProgressView() }
                    }
                    if let chapter = attachment.chapter { Text(chapter).foregroundStyle(Color(uiColor: theme.secondary)) }
                    if let progress = attachment.progress { Text(progress, format: .percent.precision(.fractionLength(1))).foregroundStyle(Color(uiColor: theme.secondary)) }
                    if let text = attachment.excerpt, !text.isEmpty { Text(text).textSelection(.enabled) }
                    if let note = attachment.note, !note.isEmpty { Text(note).textSelection(.enabled) }
                    if let conflicts = attachment.conflictContents, !conflicts.isEmpty {
                        Text("批注有冲突").font(.headline)
                        ForEach(conflicts) { version in
                            VStack(alignment: .leading) {
                                if let value = version.content { Text(value.excerpt); Text(value.note) }
                                else { Text("已移除") }
                            }
                                .padding().background(Color(uiColor: theme.raised), in: .rect(cornerRadius: 12))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }.themedPage().navigationTitle("阅读附件").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { SystemToolbarButton("关闭", role: .close) { dismiss() } } }
        }.presentationDetents([.medium, .large])
            .task(id: attachment.attachmentRef) {
                guard attachment.kind == .image else { return }
                do {
                    guard let owner, let ref = attachment.attachmentRef else { throw AIToolError("not_found") }
                    let bytes = try await AIImageStore.shared.read(owner: owner, ref: ref)
                    guard let decoded = AIImageThumbnail.make(bytes, pixels: 1600) else { throw AIToolError("invalid_response") }
                    image = decoded
                } catch { imageError = String(localized: "参考图片已不可用。") }
            }
    }
}

struct AIReadingObjectPicker: View {
    @Environment(\.theme) private var theme
    let kind: AIReadingAttachment.Kind
    let conversationID: String
    @Environment(AIService.self) private var ai
    @Environment(\.dismiss) private var dismiss
    @State private var books: [AIReadingAttachment] = []
    @State private var query = ""
    @State private var error: String?
    @State private var loaded = false
    private var title: String { switch kind { case .bookmark: String(localized: "选择书签"); case .annotation: String(localized: "选择批注"); default: String(localized: "选择书籍") } }
    var body: some View {
        NavigationStack {
            let shown = books.filter { LibraryQueryRules.selectionMatches($0.title, query: query) }
            Group {
                if !loaded {
                    ProgressView("正在读取书籍…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView {
                        Label("暂时无法读取书籍", systemImage: "exclamationmark.circle")
                    } description: { Text(verbatim: error) } actions: { Button("重试") { Task { await load() } } }
                } else if books.isEmpty {
                    ContentUnavailableView("暂无书籍", systemImage: "books.vertical")
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List {
                        ForEach(shown) { book in
                            if kind == .book {
                                Button { Task { try? await ai.addReadingAttachment(conversationID, attachment: book); dismiss() } } label: { Label(book.title, systemImage: "book") }
                            } else {
                                NavigationLink { AIReadingMarkPicker(book: book, kind: kind) { attachment in
                                    Task { try? await ai.addReadingAttachment(conversationID, attachment: attachment); dismiss() }
                                } } label: { Label(book.title, systemImage: "book") }
                                .disabled(book.bookRef == nil)
                            }
                        }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                    }
                }
            }.themedPage().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "搜索书籍")
                .toolbar { ToolbarItem(placement: .cancellationAction) { SystemToolbarButton("关闭", role: .close) { dismiss() } } }
                .task { await load() }
        }
    }
    private func load() async {
        loaded = false; error = nil
        do {
            var result: [AIReadingAttachment] = []; var seen = Set<String>()
            for shelf in try await AppDataService.shared.shelves() {
                for row in try await AppDataService.shared.aiLibraryBooks(shelf.id) {
                    let bookRef = (row.metadata?.sha).flatMap { (try? parseSha256(value: $0)) != nil ? AIReadingTools.bookRef($0) : nil }
                    let fileRef = AIReadingTools.ref("f", row.id)
                    guard seen.insert(bookRef ?? fileRef).inserted else { continue }
                    result.append(.init(kind: .book, origin: "picker", bookRef: bookRef, fileRef: fileRef, title: row.title))
                }
            }
            books = result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        } catch { self.error = ReaderMessages.error(error) }
        loaded = true
    }
}
private struct AIReadingMarkPicker: View {
    @Environment(\.theme) private var theme
    let book: AIReadingAttachment
    let kind: AIReadingAttachment.Kind
    let select: (AIReadingAttachment) -> Void
    @State private var items: [AIReadingAttachment] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var query = ""
    private var shown: [AIReadingAttachment] {
        items.filter { LibraryQueryRules.selectionMatches([$0.title, $0.excerpt ?? "", $0.note ?? ""].joined(separator: " "), query: query) }
    }
    var body: some View {
        Group {
            if !loaded {
                ProgressView("正在读取记录…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView {
                    Label("暂时无法读取记录", systemImage: "exclamationmark.circle")
                } description: { Text(verbatim: error) } actions: { Button("重试") { Task { await load() } } }
            } else if items.isEmpty {
                ContentUnavailableView("暂无记录", systemImage: kind == .bookmark ? "bookmark" : "highlighter")
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    ForEach(shown) { item in
                        Button { select(item) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.excerpt ?? item.title).lineLimit(3)
                                if item.conflictContents != nil { Text("批注有冲突").font(.caption) }
                                else if let note = item.note, !note.isEmpty { Text(note).font(.caption).lineLimit(2) }
                            }
                        }
                    }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                }
            }
        }.themedPage().navigationTitle(book.title)
            .searchable(text: $query, prompt: "搜索记录")
            .task { await load() }
    }
    private func load() async {
        loaded = false; error = nil

        do {
            guard let ref = book.bookRef else { loaded = true; return }
            let groups = try await AppDataService.shared.aiMarks(sha: String(ref.dropFirst(2)))
            items = groups.compactMap { id, heads in
                let live = heads.filter { $0.content != nil }
                guard let first = live.first, let content = first.content, first.bookmark == (kind == .bookmark) else { return nil }
                var item = book; item.id = id; item.kind = kind
                item.objectRef = AIReadingTools.ref("mark", id); item.startUtf8 = content.start; item.endUtf8 = content.end
                item.excerpt = AnnotationReduction.conflicts(heads) ? String(localized: "批注有冲突") : content.excerpt
                item.note = AnnotationReduction.conflicts(heads) ? nil : content.note
                item.conflictContents = AnnotationReduction.conflicts(heads) ? heads.map { .init(id: AIReadingTools.ref("v", $0.id), content: $0.content) } : nil
                return item
            }.sorted { ($0.startUtf8 ?? 0, $0.id) < ($1.startUtf8 ?? 0, $1.id) }
        } catch { self.error = ReaderMessages.error(error) }
        loaded = true
    }
}

extension AIReadingAttachment.Kind: Identifiable { var id: String { rawValue } }
