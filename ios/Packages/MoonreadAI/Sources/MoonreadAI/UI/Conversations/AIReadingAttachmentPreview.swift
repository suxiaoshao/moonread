import Foundation
import MoonreadDataTypes
import MoonreadDesign
import MoonreadSearchText
import MoonreadData
import MoonreadCoreBindings
import SwiftUI
import AISDKProvider
import AISDKProviderUtils

/// The attachment sheet presents existing excerpts. Only the host opens the session's image store.
public struct AIReadingAttachmentPreview: View {
    public init(attachment: AIReadingAttachment, owner: String? = nil) {
        self.attachment = attachment; self.owner = owner
    }
    public let attachment: AIReadingAttachment
    public var owner: String? = nil

    public var body: some View {
        AIChatAttachmentPreview(attachment: attachment) {
            guard let owner, let ref = attachment.attachmentRef else { throw AIToolError("not_found") }
            let bytes = try await AIImageStore.shared.read(owner: owner, ref: ref)
            guard let decoded = AIImageThumbnail.make(bytes, pixels: 1600) else { throw AIToolError("invalid_response") }
            return decoded
        }
    }
}

public struct AIReadingObjectPicker: View {
    public init(kind: AIReadingAttachment.Kind, conversationID: String) {
        self.kind = kind; self.conversationID = conversationID
    }
    @Environment(\.theme) private var theme
    public let kind: AIReadingAttachment.Kind
    public let conversationID: String
    @Environment(AIService.self) private var ai
    @Environment(\.dismiss) private var dismiss
    @State private var books: [AIReadingAttachment] = []
    @State private var query = ""
    @State private var error: String?
    @State private var loaded = false
    private var title: String { switch kind { case .bookmark: String(localized: "选择书签"); case .annotation: String(localized: "选择批注"); default: String(localized: "选择书籍") } }
    public var body: some View {
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
            for shelf in try await ai.readingAccess.shelves() {
                for row in try await ai.readingAccess.aiLibraryBooks(shelf.id) {
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
    @Environment(AIService.self) private var ai
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
            let groups = try await ai.readingAccess.aiMarks(String(ref.dropFirst(2)))
            items = groups.compactMap { id, heads in
                let live = heads.filter { $0.content != nil }
                guard let first = live.first, let content = first.content, first.bookmark == (kind == .bookmark) else { return nil }
                var item = book; item.id = id; item.kind = kind
                item.objectRef = AIReadingTools.ref("mark", id); item.startUtf8 = content.start; item.endUtf8 = content.end
                item.excerpt = AnnotationReduction.conflicts(heads) ? String(localized: "批注有冲突") : content.excerpt
                item.note = AnnotationReduction.conflicts(heads) ? nil : content.note
                item.conflictContents = AnnotationReduction.conflicts(heads) ? heads.map { .init(id: AIReadingTools.ref("v", $0.id), content: $0.content.map { .init(start: $0.start, end: $0.end, excerpt: $0.excerpt, note: $0.note) }) } : nil
                return item
            }.sorted { ($0.startUtf8 ?? 0, $0.id) < ($1.startUtf8 ?? 0, $1.id) }
        } catch { self.error = ReaderMessages.error(error) }
        loaded = true
    }
}
