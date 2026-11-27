import MoonreadDesign
import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import SwiftUI
import UIKit

public struct NoteDocument: Sendable {
    public struct Record: Identifiable, Sendable {
        public let id: String
        public let mark: ReaderMark
        public let chapter: String?
        public var chapterStart: UInt64? = nil
        public let percentage: Double?
        public let version: Int?
        public let deletionVersion: Bool
        public init(id: String, mark: ReaderMark, chapter: String?, chapterStart: UInt64? = nil,
                    percentage: Double?, version: Int?, deletionVersion: Bool) {
            self.id = id
            self.mark = mark
            self.chapter = chapter
            self.chapterStart = chapterStart
            self.percentage = percentage
            self.version = version
            self.deletionVersion = deletionVersion
        }

        var position: String {
            [chapter, percentage.map { String(format: "%.0f%%", $0) }].compactMap { $0 }.joined(separator: " · ")
        }
    }
    public enum Format: String, CaseIterable { case markdown = "Markdown", text = "纯文本" }
    public init(title: String, author: String?, records: [Record]) {
        self.title = title
        self.author = author
        self.records = records
    }

    public let title: String
    public let author: String?
    public let records: [Record]
    public func excerpt(_ record: Record) -> String {
        record.mark.excerpt + "\n\n——《" + title + "》" + [author, record.position.isEmpty ? nil : record.position].compactMap { $0 }.map { " · " + $0 }.joined()
    }
    public func render(_ format: Format, file: Bool = true) -> String {
        let md = format == .markdown
        func body(_ value: String) -> String {
            md ? value.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") : value
        }
        var lines = [(md ? "# " : "") + title]
        if let author, !author.isEmpty { lines.append(String(localized: "作者：") + author) }
        var previousChapter: UInt64?
        for r in records {
            if let start = r.chapterStart, start != previousChapter, let chapter = r.chapter {
                lines += ["", (md ? "## " : "") + chapter]
            }
            previousChapter = r.chapterStart
            let kind = r.mark.kind == .bookmark ? String(localized: "书签 · 定位摘录") : String(localized: "标注与笔记")
            lines += ["", (md ? "### " : "") + [r.chapterStart == nil ? r.chapter : nil, kind, r.percentage.map { String(format: "%.0f%%", $0) }].compactMap { $0 }.joined(separator: " · ")]
            if let version = r.version { lines.append(String(localized: "未合并版本") + " \(version)") }
            if r.deletionVersion { lines.append(String(localized: "另有删除版本")) }
            lines.append(body(r.mark.excerpt))
            if !r.mark.note.isEmpty { lines += ["", String(localized: "笔记：") + (md ? "\n" : "") + body(r.mark.note)] }
            if md { lines.append("") }
            lines.append(String(localized: "创建于：") + Date(timeIntervalSince1970: Double(r.mark.created) / 1000).formatted(date: .numeric, time: .omitted))
        }
        if file { lines += ["", md ? "---" : "", String(localized: "月读笔记导出 · 格式 1")] }
        return lines.joined(separator: "\n")
    }
}
struct NoteSharePayload: Identifiable {
    let id = UUID()
    let text: String?
    let files: ShareFiles?
    var url: URL? { files?.urls.first }
    init(text: String) { self.text = text; files = nil }
    init(document: NoteDocument, format: NoteDocument.Format) throws {
        let ext = format == .markdown ? ".md" : ".txt"
        let proposed = document.title + "-" + String(localized: "笔记") + ext
        let name = (try? validateLibraryName(input: proposed, profile: .manualForm)) != nil ? proposed : String(localized: "月读笔记") + ext
        files = try ShareFiles { folder in
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
    let service: any ReaderDataAccess
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
            .sheet(item: $sharing) { ShareSheet(files: $0.files, text: $0.text) }
            .task { await load() }
    }
    private func load() async {
        loading = true; error = nil; incompatible = false; defer { loading = false }
        do { document = try await service.noteDocument(bookID, ids: nil) }
        catch { incompatible = error is NoteReadError || error is UserSyncCompatibilityError; self.error = ReaderMessages.error(error) }
    }
}
