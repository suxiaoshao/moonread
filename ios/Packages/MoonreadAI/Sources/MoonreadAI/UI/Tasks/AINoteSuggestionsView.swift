import MoonreadDesign
import SwiftUI

struct AINoteSuggestionsCard: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @State private var legacyPreview: AINotePreview?
    @State private var reviewing = false
    let notes: [AINoteSuggestion]
    let noteEditor: AIProposalNoteEditor

    var body: some View {
        if let first = notes.first {
            let preview = first.result.notePreview ?? legacyPreview
            Button { reviewing = true } label: {
                VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                    HStack {
                        Label("笔记建议", systemImage: "note.text").font(.headline)
                        Text("\(notes.count) 条").font(.caption)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).accessibilityHidden(true)
                    }
                    AINoteSuggestionChapter(kind: first.proposal.kind, chapter: preview?.chapter)
                        .font(.subheadline.weight(.medium)).lineLimit(1, reservesSpace: true)
                    Text(verbatim: preview?.excerpt ?? " ")
                        .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                        .lineLimit(2, reservesSpace: true)
                    (notes.count > 1 ? remainingNotes(notes.dropFirst()) : Text(verbatim: " "))
                        .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                        .lineLimit(1, reservesSpace: true).accessibilityHidden(notes.count == 1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(AIResultButtonStyle())
            .accessibilityIdentifier("aiNoteSuggestions")
            .task(id: first.id) {
                guard first.result.notePreview == nil else { return }
                let preview = try? await ai.proposals.legacyNotePreview(first.proposal)
                guard !Task.isCancelled else { return }
                legacyPreview = preview
            }
            .sheet(isPresented: $reviewing) {
                AINoteSuggestionsReview(notes: notes, noteEditor: noteEditor).themeScope(theme)
            }
        }
    }

    private func remainingNotes(_ rest: ArraySlice<AINoteSuggestion>) -> Text {
        let bookmarks = rest.filter { $0.proposal.kind == .bookmark }.count
        let notes = rest.count - bookmarks
        if bookmarks == 0 { return Text("另有 \(notes) 条批注") }
        if notes == 0 { return Text("另有 \(bookmarks) 个书签") }
        return Text("另有 \(notes) 条批注、\(bookmarks) 个书签")
    }
}

private struct AINoteSuggestionChapter: View {
    @Environment(\.theme) private var theme
    let kind: AINoteProposal.Kind
    let chapter: String?

    var body: some View {
        let title = chapter ?? String(localized: "原文")
        let type = kind == .bookmark ? String(localized: "书签") : String(localized: "批注")
        HStack(alignment: .firstTextBaseline, spacing: LayoutTokens.compact) {
            Image(systemName: kind == .bookmark ? "bookmark" : "highlighter")
                .foregroundStyle(Color(uiColor: theme.accent))
                .accessibilityHidden(true)
            Text(verbatim: title)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(type) \(title)"))
    }
}

private struct AINoteSuggestionsReview: View {
    @Environment(AIService.self) private var ai
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var loaded = false
    @State private var source: AINoteSuggestion?
    @State private var editor: AINoteEditorRequest?
    @State private var editorQueue: [AINoteEditorRequest] = []
    @State private var saveRequest: UUID?
    let notes: [AINoteSuggestion]
    let noteEditor: AIProposalNoteEditor

    private var registry: AIProposalRegistry { ai.proposals }
    private var busy: Bool { saveRequest != nil || editor != nil || !editorQueue.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                if loaded {
                    VStack(alignment: .leading, spacing: LayoutTokens.content) {
                        ForEach(notes) { suggestion in
                            if let review = note(suggestion.id) {
                                AINoteSuggestionRow(
                                    suggestion: suggestion, review: review, multiple: notes.count > 1, busy: busy,
                                    select: { registry.editNote(suggestion.id, selected: !review.selected) },
                                    edit: { registry.editNote(suggestion.id, text: $0) },
                                    openSource: { source = suggestion })
                                if suggestion.id != notes.last?.id { ThemedDivider() }
                            }
                        }
                    }.padding(LayoutTokens.content)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
            .themedPage()
            .navigationTitle("笔记建议").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SystemToolbarButton("关闭", role: .close) { dismiss() }
                        .accessibilityIdentifier("closeAINoteSuggestions")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .sheet(item: $source) { suggestion in
                AISourceExcerptSheet(id: suggestion.id, title: note(suggestion.id)?.preview?.chapter ?? "") {
                    try await registry.noteText(suggestion.proposal)
                }.themeScope(theme)
            }
            .sheet(item: $editor, onDismiss: nextEditor) { request in
                if let result = notes.first(where: { $0.id == request.id })?.result {
                    noteEditor(request.edit, registry.annotationHooks(result)) { editor = nil }
                        .themeScope(theme).preferredColorScheme(theme.scheme)
                }
            }
        }
        .task {
            for suggestion in notes {
                guard !Task.isCancelled else { return }
                await registry.openResult(suggestion.result)
            }
            guard !Task.isCancelled else { return }
            loaded = true
        }
        .task(id: saveRequest) {
            guard saveRequest != nil else { return }
            await saveSelected()
        }
        .onDisappear {
            saveRequest = nil
            editorQueue.removeAll()
            for suggestion in notes { registry.closeResult(suggestion.id) }
        }
    }

    private func note(_ id: String) -> AINoteReviewValue? {
        if case .note(let note) = registry.review(id)?.body { return note }
        return nil
    }

    private var footer: some View {
        let counts = AINoteReviewCounts(notes.compactMap { note($0.id) })
        return VStack(alignment: .leading, spacing: LayoutTokens.compact) {
            if let error = notes.lazy.compactMap({ registry.lastErrors[$0.id] }).first {
                Text(verbatim: error).font(.footnote).foregroundStyle(Color(uiColor: theme.destructive))
            }
            Button { saveRequest = UUID() } label: {
                saveLabel(counts.selected).frame(maxWidth: .infinity, minHeight: LayoutTokens.hit)
            }
            .buttonStyle(ThemedProminentButtonStyle())
            .disabled(!loaded || counts.selected == 0 || busy)
            .accessibilityIdentifier("saveAINoteSuggestions")
        }
        .padding(LayoutTokens.content)
        .background(Color(uiColor: theme.surface))
        .overlay(alignment: .top) { ThemedDivider() }
    }

    private func saveLabel(_ count: Int) -> Text {
        if notes.count > 1 { return Text("保存所选（\(count)）") }
        return notes.first?.proposal.kind == .bookmark ? Text("保存书签") : Text("保存批注")
    }

    private func saveSelected() async {
        defer { saveRequest = nil }
        let selected = notes.filter { suggestion in
            guard let review = note(suggestion.id) else { return false }
            return review.canSave && review.selected
        }
        var requests: [AINoteEditorRequest] = []
        for suggestion in selected {
            guard !Task.isCancelled else { return }
            if let request = await registry.saveNote(suggestion.id) { requests.append(request) }
        }
        guard !Task.isCancelled else { return }
        editorQueue = requests
        nextEditor()
    }

    private func nextEditor() {
        guard !editorQueue.isEmpty else { return }
        editor = editorQueue.removeFirst()
    }
}

private struct AINoteSuggestionRow: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    let suggestion: AINoteSuggestion
    let review: AINoteReviewValue
    let multiple: Bool
    let busy: Bool
    let select: () -> Void
    let edit: (String) -> Void
    let openSource: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: LayoutTokens.compact) {
            if multiple && review.canSave {
                Button(action: select) {
                    Image(systemName: review.selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.accent))
                .accessibilityLabel("选择")
                .accessibilityAddTraits(review.selected ? .isSelected : [])
                .disabled(busy)
            }
            VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                HStack {
                    sourceButton
                    Spacer(minLength: 0)
                    status
                }
                if let excerpt = review.preview?.excerpt, !excerpt.isEmpty {
                    Text(verbatim: excerpt)
                        .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, LayoutTokens.control)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color(uiColor: theme.separator)).frame(width: 2)
                        }
                }
                if case .unavailable(let reason) = review.status {
                    Text(verbatim: reason).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                }
                if suggestion.proposal.kind == .note {
                    TextField("评论", text: Binding(get: {
                        guard case .note(let current) = ai.proposals.review(suggestion.id)?.body else { return review.draft }
                        return current.draft
                    }, set: edit), axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(2...8)
                    .padding(.vertical, 8).padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: theme.input), in: .rect(cornerRadius: 10))
                    .disabled(!review.canSave || busy)
                    .accessibilityIdentifier("aiNoteDraft-\(suggestion.id)")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sourceButton: some View {
        Button(action: openSource) {
            HStack {
                AINoteSuggestionChapter(kind: suggestion.proposal.kind, chapter: review.preview?.chapter)
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.right").font(.caption2).accessibilityHidden(true)
            }.frame(minHeight: LayoutTokens.hit, alignment: .leading).contentShape(.rect)
        }
        .buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.accent))
        .disabled(review.preview == nil || busy)
        .accessibilityHint("打开原文")
    }

    @ViewBuilder private var status: some View {
        switch review.status {
        case .pending: EmptyView()
        case .existingBookmark: Text("已有书签").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
        case .saved: Text("已保存").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
        case .unavailable: Text("暂不可用").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
        }
    }
}
