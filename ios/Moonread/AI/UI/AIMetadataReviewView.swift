import SwiftUI

enum AIProposalSources {
    enum Item: Identifiable {
        case text(AIResultSource), web(AIWebSource)
        var id: String { switch self { case .text(let s): s.id; case .web(let s): s.id } }
    }
    @MainActor static func resolve(_ refs: [String], session: String, _ ai: AIService) async -> [Item] {
        guard !refs.isEmpty, let values = try? await ai.resolveSources(refs, session: session) else { return [] }
        return values.map { value in
            switch value {
            case .text(let bookRef, let start, let end, let title):
                .text(AIResultSource(id: value.id, bookRef: bookRef, start: start, end: end, title: title))
            case .web(let source): .web(source)
            }
        }
    }
}

/// The sources behind one suggestion: original text opens the read-only preview, web pages open in Safari.
struct AIProposalSourcesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.theme) private var theme
    let items: [AIProposalSources.Item]
    @State private var preview: AIResultSource?
    var body: some View {
        NavigationStack {
            List(items) { item in
                switch item {
                case .text(let source):
                    Button { preview = source } label: {
                        Label(source.title.isEmpty ? String(localized: "原文") : source.title, systemImage: "text.quote")
                    }.foregroundStyle(Color(uiColor: theme.ink)).listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                case .web(let source):
                    Button { if let url = URL(string: source.url) { openURL(url) } } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(source.title, systemImage: "safari")
                            Text(verbatim: URL(string: source.url)?.host ?? source.url).font(.caption)
                                .foregroundStyle(Color(uiColor: theme.secondary))
                        }
                    }.foregroundStyle(Color(uiColor: theme.ink)).listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                }
            }
            .themedPage().navigationTitle("来源").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭", systemImage: "xmark") { dismiss() } } }
            .sheet(item: $preview) { AISourcePreview(source: $0).themeScope(theme) }
        }.presentationDetents([.medium, .large])
    }
}

extension AIMetadataFieldKind {
    var label: LocalizedStringKey {
        switch self { case .author: "作者"; case .synopsis: "简介"; case .tags: "标签"; case .readingStatus: "阅读状态" }
    }
}

struct AIMetadataResultReview: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let result: AIResultValue
    private var resultID: String { result.id }
    @State private var sources: [AIProposalSources.Item] = []
    @State private var showSources = false
    @State private var editor: AIMetadataTextEdit?
    private var review: AIReviewValue? { ai.proposals.review(resultID) }
    private var saving: Bool { ai.proposals.inFlight.contains(resultID) }
    var body: some View {
        NavigationStack {
            ScrollView {
                if let review, case .metadata(let metadata) = review.body {
                    VStack(alignment: .leading, spacing: LayoutTokens.section) {
                        HStack(alignment: .top, spacing: LayoutTokens.content) {
                            LibraryBookCover(title: metadata.rename.map { $0.selected ? $0.draft : ($0.currentName as NSString).deletingPathExtension } ?? metadata.title, cover: ai.proposals.liveMetadata[resultID]?.cover)
                                .frame(width: 64, height: 90)
                            VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                                if let rename = metadata.rename {
                                    renameContent(rename)
                                } else { Text(verbatim: metadata.title).font(.title3.weight(.semibold)) }
                                if let author = metadata.fields.first(where: { $0.kind == .author }) {
                                    textContent(author)
                                } else if let author = ai.proposals.liveMetadata[resultID]?.author, !author.isEmpty {
                                    Text(verbatim: author).font(.subheadline)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let tags = metadata.fields.first(where: { $0.kind == .tags }) { tagContent(tags) }
                        else if let tags = ai.proposals.liveMetadata[resultID]?.tags, !tags.isEmpty {
                            AIFlowLayout { ForEach(tags, id: \.self) { tag in chip(tag, badge: nil, removed: false, changed: false, dashed: false) } }
                        }
                        ForEach(metadata.fields.filter { $0.kind == .synopsis || $0.kind == .readingStatus }) { textContent($0) }
                        if !metadata.fields.contains(where: { $0.kind == .synopsis }), let synopsis = ai.proposals.liveMetadata[resultID]?.synopsis, !synopsis.isEmpty {
                            Text(verbatim: synopsis).font(.subheadline)
                        }
                        AIResultFeedback(resultID: resultID)
                    }.padding(LayoutTokens.content).disabled(saving)
                } else if let error = ai.proposals.lastErrors[resultID] { Text(verbatim: error).padding() }
                else { ProgressView().padding() }
            }.pageScrollMargins().accessibilityIdentifier("aiMetadataReviewScroll").themedPage().navigationTitle("资料建议").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭", systemImage: "xmark") { dismiss() }.disabled(saving) } }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let review, case .metadata(let metadata) = review.body {
                    let count = ai.proposals.metadataChangeCount(resultID, metadata)
                    Button { Task { await ai.proposals.applyMetadata([resultID]) } } label: {
                        Text("应用 \(count) 项更改").frame(maxWidth: .infinity)
                    }.buttonStyle(ThemedProminentButtonStyle()).disabled(count == 0 || saving)
                        .accessibilityIdentifier("applyMetadata-\(resultID)")
                        .padding(LayoutTokens.content).background(Color(uiColor: theme.canvas))
                }
            }
            .interactiveDismissDisabled(saving)
            .task { await ai.proposals.openResult(result) }
            .sheet(isPresented: $showSources) { AIProposalSourcesSheet(items: sources).themeScope(theme) }
            .sheet(item: $editor) { edit in
                AIMetadataTextEditor(edit: edit) { text in
                    if let kind = edit.kind { ai.proposals.editMetadata(resultID, kind: kind, text: text) }
                    else { ai.proposals.editRename(resultID, text: text) }
                }.themeScope(theme)
            }
        }
    }
    private func renameContent(_ rename: AIMetadataRenameReview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: rename.selected ? rename.draft : (rename.currentName as NSString).deletingPathExtension).font(.title3.weight(.semibold))
            if rename.currentName != rename.targetName {
                changeControl(selected: rename.selected, edited: rename.edited, label: "书名") {
                    ai.proposals.editRename(resultID, selected: !rename.selected)
                }.disabled(rename.unavailable != nil)
                Text(verbatim: rename.currentName + " → " + rename.targetName).font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                Button("编辑书名", systemImage: "pencil") { editor = .init(kind: nil, text: rename.draft) }
                    .font(.caption).disabled(rename.unavailable != nil)
            }
            if let unavailable = rename.unavailable { Text(verbatim: unavailable).font(.caption).foregroundStyle(Color(uiColor: theme.destructive)) }
        }
    }
    private func changeControl(selected: Bool, edited: Bool, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if selected { Circle().frame(width: 5, height: 5) }
                Text(selected ? (edited ? "已编辑" : "已修改") : "原内容")
                Image(systemName: "arrow.left.arrow.right")
            }.font(.caption).frame(minHeight: LayoutTokens.hit)
        }.buttonStyle(.plain).foregroundStyle(Color(uiColor: selected ? theme.accent : theme.secondary))
            .accessibilityLabel(Text(label) + Text(selected ? "，显示建议，点按显示原内容" : "，显示原内容，点按显示建议"))
    }
    private func textContent(_ field: AIMetadataFieldReview) -> some View {
        let current = ai.proposals.metadataCurrent(resultID, field: field)
        let changed = current != field.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = field.selected ? field.draft : current
        return VStack(alignment: .leading, spacing: LayoutTokens.compact) {
            if changed || field.kind != .author {
                HStack {
                    Text(field.kind.label).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    if changed {
                        changeControl(selected: field.selected, edited: field.edited, label: field.kind.label) {
                            ai.proposals.editMetadata(resultID, kind: field.kind, selected: !field.selected)
                        }.accessibilityIdentifier("aiMetadataSwitch-\(field.id)")
                    }
                }
            }
            Text(verbatim: display(text, kind: field.kind)).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            if changed {
                Button("编辑", systemImage: "pencil") { editor = .init(kind: field.kind, text: field.draft) }
                    .font(.caption).frame(minHeight: LayoutTokens.hit).accessibilityIdentifier("aiMetadataEdit-\(field.id)")
            }
            if !field.sourceRefs.isEmpty { sourceLine(field.sourceRefs) }
        }
    }
    private func display(_ value: String, kind: AIMetadataFieldKind) -> String {
        if value.isEmpty { return String(localized: "（保持空白）") }
        if kind == .readingStatus {
            switch value { case "unread": return String(localized: "未读"); case "reading": return String(localized: "阅读中"); case "finished": return String(localized: "读完"); case "paused": return String(localized: "暂搁"); default: break }
        }
        return value
    }
    private func tagContent(_ field: AIMetadataFieldReview) -> some View {
        let current = Set(ai.proposals.metadataCurrent(resultID, field: field).split(separator: "\n").map(String.init))
        let offered = Set(field.draft.split(separator: "\n").map(String.init))
        return VStack(alignment: .leading, spacing: LayoutTokens.compact) {
            Text("标签").font(.subheadline.weight(.semibold))
            AIFlowLayout {
                ForEach(current.sorted() + offered.subtracting(current).sorted(), id: \.self) { tag in
                    let added = !current.contains(tag)
                    let removal = field.tagsMode == .replace && !offered.contains(tag)
                    let selected = field.selectedTags.contains(tag)
                    if added || removal {
                        Button { ai.proposals.editMetadata(resultID, kind: .tags, tag: tag) } label: {
                            chip(tag, badge: added ? "新" : "建议移除", removed: added ? !selected : selected, changed: selected, dashed: removal && !selected)
                        }.buttonStyle(.plain).accessibilityIdentifier("aiTag-\(tag)")
                            .accessibilityLabel(Text(verbatim: tag) + Text(added ? (selected ? "，新增，将添加，点按取消" : "，新增，不添加，点按恢复") : (selected ? "，建议移除，将移除，点按保留" : "，建议移除，将保留，点按移除")))
                    } else { chip(tag, badge: nil, removed: false, changed: false, dashed: false) }
                }
            }
            if !field.sourceRefs.isEmpty { sourceLine(field.sourceRefs) }
        }
    }
    private func chip(_ tag: String, badge: LocalizedStringKey?, removed: Bool, changed: Bool, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: tag).strikethrough(removed)
            if let badge { Text(badge).font(.caption2) }
        }.font(.subheadline).foregroundStyle(Color(uiColor: removed ? theme.secondary : (changed ? theme.accent : theme.ink)))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(uiColor: changed ? theme.selected : theme.surface), in: .capsule)
            .overlay { Capsule().strokeBorder(Color(uiColor: changed ? theme.accent : theme.border), style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : [])) }
    }
    private func sourceLine(_ refs: [String]) -> some View {
        AIMetadataSourceLine(refs: refs, session: result.sessionID) { values in sources = values; showSources = true }
    }
}

private struct AIMetadataSourceLine: View {
    @Environment(AIService.self) private var ai
    let refs: [String]
    let session: String
    let open: ([AIProposalSources.Item]) -> Void
    @State private var items: [AIProposalSources.Item] = []
    var body: some View {
        Button { open(items) } label: {
            HStack(spacing: 4) {
                Text("来源")
                Text(verbatim: items.map { item in
                    switch item { case .text: String(localized: "原文"); case .web(let source): URL(string: source.url)?.host ?? source.title }
                }.joined(separator: "、"))
                Image(systemName: "chevron.right")
            }.font(.caption).frame(minHeight: LayoutTokens.hit)
        }.buttonStyle(.plain).disabled(items.isEmpty)
            .task(id: refs) { items = await AIProposalSources.resolve(refs, session: session, ai) }
    }
}
private struct AIMetadataTextEdit: Identifiable {
    let id = UUID()
    var kind: AIMetadataFieldKind?
    var text: String
}
private struct AIMetadataTextEditor: View {
    @Environment(\.dismiss) private var dismiss
    let edit: AIMetadataTextEdit
    let save: (String) -> Void
    @State private var text = ""
    var body: some View {
        NavigationStack {
            Group {
                if edit.kind == .readingStatus {
                    Picker("阅读状态", selection: $text) {
                        Text("未读").tag("unread"); Text("阅读中").tag("reading"); Text("读完").tag("finished"); Text("暂搁").tag("paused")
                    }.pickerStyle(.inline)
                } else { TextEditor(text: $text).padding().accessibilityIdentifier("aiMetadataEditor") }
            }.themedPage().navigationTitle(edit.kind?.label ?? "书名").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { save(text); dismiss() } }
                }.onAppear { text = edit.text }
        }
    }
}

struct AIResultFeedback: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    let resultID: String
    var body: some View {
        if let text = ai.proposals.feedback[resultID] { Text(verbatim: text).font(.footnote).foregroundStyle(Color(uiColor: theme.success)) }
        if let text = ai.proposals.lastErrors[resultID] { Text(verbatim: text).font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)) }
        if let text = ai.proposals.renameFeedback[resultID] { Text(verbatim: text).font(.footnote).foregroundStyle(Color(uiColor: theme.success)) }
        if let text = ai.proposals.renameErrors[resultID] { Text("重命名：\(text)").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)) }
    }
}

struct AITrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.title; configuration.icon.font(.caption) }
    }
}
