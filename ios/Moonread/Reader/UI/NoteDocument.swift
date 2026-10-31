import Foundation
import SwiftUI
import UIKit

/// Ephemeral read snapshot, never a new sync or backup format.
struct NoteCandidates: Sendable {
    let key: String
    let groups: [String: [AnnotationCandidate]]
    let blocked: Set<String>
    func checked(_ ids: Set<String>?) throws -> [String: [AnnotationCandidate]] {
        let unreadable = ids.map { blocked.intersection($0) } ?? blocked
        guard unreadable.isEmpty else { throw NoteReadError(count: unreadable.count) }
        return groups.filter { ids?.contains($0.key) ?? true }
    }
}
struct NoteReadError: LocalizedError {
    let count: Int
    var errorDescription: String? { String(localized: "有 \(count) 条记录无法读取，暂时无法完整分享或导出。请在数据管理中查看。") }
}

struct NoteDocument: Sendable {
    struct Record: Identifiable, Sendable {
        let id: String
        let mark: ReaderMark
        let chapter: String?
        var chapterStart: UInt64? = nil
        let percentage: Double?
        let version: Int?
        let deletionVersion: Bool
        var position: String {
            [chapter, percentage.map { String(format: "%.0f%%", $0) }].compactMap { $0 }.joined(separator: " · ")
        }
    }
    enum Format: String, CaseIterable { case markdown = "Markdown", text = "纯文本" }
    let title: String
    let author: String?
    let records: [Record]
    static func escape(_ value: String) -> String {
        var result = ""
        for c in value { if "\\`*_{}[]<>()#+-.!|~&".contains(c) { result.append("\\") }; result.append(c) }
        return result
    }
    func excerpt(_ record: Record) -> String {
        record.mark.excerpt + "\n\n——《" + title + "》" + [author, record.position.isEmpty ? nil : record.position].compactMap { $0 }.map { " · " + $0 }.joined()
    }
    func render(_ format: Format, file: Bool = true) -> String {
        let md = format == .markdown
        func plain(_ s: String) -> String { md ? Self.escape(s) : s }
        var lines = [(md ? "# " : "") + plain(title)]
        if let author, !author.isEmpty { lines.append(String(localized: "作者：") + plain(author)) }
        var previousChapter: UInt64?
        for r in records {
            if let start = r.chapterStart, start != previousChapter, let chapter = r.chapter {
                lines += ["", (md ? "## " : "") + plain(chapter)]
            }
            previousChapter = r.chapterStart
            let kind = r.mark.kind == .bookmark ? String(localized: "书签 · 定位摘录") : String(localized: "标注与笔记")
            lines += ["", (md ? "### " : "") + plain([r.chapterStart == nil ? r.chapter : nil, kind, r.percentage.map { String(format: "%.0f%%", $0) }].compactMap { $0 }.joined(separator: " · "))]
            if let version = r.version { lines.append(String(localized: "未合并版本") + " \(version)") }
            if r.deletionVersion { lines.append(String(localized: "另有删除版本")) }
            lines.append(md ? r.mark.excerpt.components(separatedBy: "\n").map { "> " + Self.escape($0) }.joined(separator: "\n") : r.mark.excerpt)
            if !r.mark.note.isEmpty { lines += ["", String(localized: "笔记：") + plain(r.mark.note)] }
            lines.append(String(localized: "创建于：") + Date(timeIntervalSince1970: Double(r.mark.created) / 1000).formatted(date: .numeric, time: .omitted))
        }
        if file { lines += ["", md ? "---" : "", String(localized: "月读笔记导出 · 格式 1")] }
        return lines.joined(separator: "\n")
    }
}
extension AppDataService {
    func noteCandidates(_ id: String) async throws -> NoteCandidates {
        let revision = userCloudConfigurationRevision
        let key = try userKey(id)
        let snapshot = try await userStore(for: key).noteCandidates(key: key)
        guard revision == userCloudConfigurationRevision, key == (try userKey(id)) else { throw UserDataConflict(candidates: []) }
        return snapshot
    }
    func noteDocument(_ id: String, ids: Set<String>? = nil) async throws -> NoteDocument {
        let snapshot = try await noteCandidates(id)
        let groups = try snapshot.checked(ids)
        let query = try await bookQuery(id), info = try query.bookInfo(bookId: id), core = try textCore()
        let details = try? await details(bookID: id)
        var records: [NoteDocument.Record] = []
        for (markID, heads) in groups {
            let live = heads.filter { $0.content != nil }.sorted { $0.id < $1.id }
            for (index, head) in live.enumerated() {
                guard let c = head.content else { continue }
                let mark = ReaderMark(id: markID, kind: head.bookmark ? .bookmark : .annotation, startUtf8: c.start, endUtf8: c.end, excerpt: c.excerpt, note: c.note, created: head.created)
                let chapter = try? query.chapterAt(bookId: id, offsetUtf8: c.start)
                let percent = try? core.readingDataPercentage(sha: info.contentSha256, offset: c.start)
                records.append(.init(id: head.id, mark: mark, chapter: chapter?.title, chapterStart: chapter?.startUtf8, percentage: percent, version: live.count > 1 ? index + 1 : nil, deletionVersion: heads.contains { $0.content == nil }))
            }
        }
        records.sort { ($0.mark.startUtf8, $0.mark.endUtf8, $0.mark.id, $0.id) < ($1.mark.startUtf8, $1.mark.endUtf8, $1.mark.id, $1.id) }
        let author = details?.metadata.author
        return NoteDocument(title: details?.book?.title ?? info.title, author: author?.isEmpty == false ? author : nil, records: records)
    }
    func shareExcerpt(_ id: String, range: TextRange) async throws -> String {
        let query = try await bookQuery(id), info = try query.bookInfo(bookId: id)
        let details = try? await details(bookID: id)
        let chapter = try? query.chapterAt(bookId: id, offsetUtf8: range.startUtf8)
        let percent = try? textCore().readingDataPercentage(sha: info.contentSha256, offset: range.startUtf8)
        let document = NoteDocument(title: details?.book?.title ?? info.title,
            author: details?.metadata.author.isEmpty == false ? details?.metadata.author : nil, records: [])
        let mark = ReaderMark(id: "excerpt", kind: .annotation, startUtf8: range.startUtf8,
            endUtf8: range.endUtf8, excerpt: range.text, note: "", created: 0)
        return document.excerpt(.init(id: "excerpt", mark: mark, chapter: chapter?.title, percentage: percent,
            version: nil, deletionVersion: false))
    }
    func noteLocations(_ id: String, marks: [ReaderMark]) async throws -> [String: String] {
        let query = try await bookQuery(id), info = try query.bookInfo(bookId: id), core = try textCore()
        var values: [String: String] = [:]
        for mark in marks {
            let chapter = try? query.chapterAt(bookId: id, offsetUtf8: mark.startUtf8)
            let percent = try? core.readingDataPercentage(sha: info.contentSha256, offset: mark.startUtf8)
            values[mark.id] = [chapter?.title, percent.map { String(format: "%.0f%%", $0) }].compactMap { $0 }.joined(separator: " · ")
        }
        return values
    }
    func deleteNoteSelection(_ id: String, expected: NoteCandidates, ids: Set<String>) async throws {
        try await promoteUserData(id)
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        let key = try userKey(id)
        guard key == expected.key else { throw UserDataConflict(candidates: []) }
        let groups = try expected.checked(ids)
        guard ids == Set(groups.keys) else { throw UserDataConflict(candidates: []) }
        let commands = ids.sorted().map { markID in
            MarkDeletion(id: markID, key: key, baseline: groups[markID]!, content: groups[markID]!.first(where: { $0.content != nil })?.content, deleted: true)
        }
        let result = try await userStore(for: key).applyDeletions(commands, checkingBaseline: true)
        for c in commands { if let tombstone = result[c.id] { undoCandidates[c.id] = ([tombstone], c.content) } }
        dataChanged()
    }
}

struct NoteSharePayload: Identifiable {
    let id = UUID()
    let text: String?
    let files: LibraryExport?
    var url: URL? { files?.urls.first }
    init(text: String) { self.text = text; files = nil }
    init(document: NoteDocument, format: NoteDocument.Format) throws {
        let ext = format == .markdown ? ".md" : ".txt"
        let proposed = document.title + "-" + String(localized: "笔记") + ext
        let name = (try? validateLibraryName(input: proposed, profile: .manualForm)) != nil ? proposed : String(localized: "月读笔记") + ext
        files = try LibraryExport { folder in
            let file = folder.appendingPathComponent(name)
            try document.render(format).write(to: file, atomically: true, encoding: .utf8)
            return [file]
        }
        text = nil
    }
    func clean() { files?.finish() }
}
struct NoteExportView: View {
    let bookID: String
    @Environment(\.theme) private var theme
    @State private var document: NoteDocument?
    @State private var format: NoteDocument.Format = .markdown
    @State private var error: String?
    @State private var sharing: NoteSharePayload?
    @State private var loading = false
    @State private var incompatible = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if loading { ProgressView("正在准备笔记") }
                else if let error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Color(uiColor: theme.destructive))
                    if !incompatible { Button("重试") { Task { await load() } } }
                } else if let document {
                    Text(verbatim: document.title).font(.title2.bold())
                    Text("\(Set(document.records.filter { $0.mark.kind == .annotation }.map { $0.mark.id }).count) 条标注与笔记 · \(Set(document.records.filter { $0.mark.kind == .bookmark }.map { $0.mark.id }).count) 个书签").foregroundStyle(Color(uiColor: theme.secondary))
                    Text("包含这本书的全部书签、标注和笔记").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    if document.records.isEmpty { ContentUnavailableView("这本书还没有笔记或书签", systemImage: "note.text") }
                    else {
                        Picker("格式", selection: $format) { ForEach(NoteDocument.Format.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }.pickerStyle(.segmented)
                        Text(verbatim: document.render(format)).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding()
                            .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 16))
                    }
                }
            }.padding().frame(maxWidth: 640).frame(maxWidth: .infinity)
        }.themedPage().navigationTitle("导出笔记").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let document, !document.records.isEmpty, error == nil, !loading {
                    Button("导出文件") {
                        do { sharing = try NoteSharePayload(document: document, format: format) }
                        catch { self.error = ReaderMessages.error(error) }
                    }.frame(maxWidth: 400).frame(maxWidth: .infinity).buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).padding()
                        .background(Color(uiColor: theme.canvas))
                }
            }
            .sheet(item: $sharing) { LibraryShareSheet(files: $0.files, text: $0.text) }
            .task { await load() }
    }
    private func load() async {
        loading = true; error = nil; incompatible = false; defer { loading = false }
        do { document = try await AppDataService.shared.noteDocument(bookID) }
        catch { incompatible = error is NoteReadError; self.error = ReaderMessages.error(error) }
    }
}
