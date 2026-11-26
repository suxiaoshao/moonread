import MoonreadDesign
import MoonreadData
import MoonreadCoreBindings
import SwiftUI

struct ReaderAnnotationDetails: View {
    let ids: [String]
    let session: ReaderSession
    let tools: ReaderToolsModel
    let close: () -> Void
    let onMeasure: (ReaderAnnotationPanelSize) -> Void

    @Environment(\.theme) private var theme
    @State private var deleting = false

    var body: some View {
        let window = session.annotationWindow
        let marks = ids.compactMap { id in window?.marks.first { $0.id == id } }
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { viewport in
                    let viewportHeight = viewport.size.height
                    ScrollView {
                        Group {
                            if let window, !marks.isEmpty {
                                VStack(alignment: .leading, spacing: LayoutTokens.content) {
                                    ForEach(marks, id: \.id) { mark in
                                        if mark.id != marks.first?.id { Divider() }
                                        entry(mark, candidates: window.candidates)
                                    }
                                }
                            } else {
                                ContentUnavailableView("暂无笔记", systemImage: "note.text")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(LayoutTokens.page)
                        .onGeometryChange(for: ReaderAnnotationPanelSize.self) { content in
                            .init(content: content.size.height, viewport: viewportHeight)
                        } action: { onMeasure($0) }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                if tools.deletedIDs != nil {
                    ReaderUndoAction(session: session, tools: tools)
                        .background(Color(uiColor: theme.surface))
                }
            }
            .navigationTitle(title(for: marks))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SystemToolbarButton("关闭", role: .close, action: close)
                }
            }
            .alert("阅读遇到问题", isPresented: Binding(get: { tools.error != nil }, set: { if !$0 { tools.error = nil } })) {
                Button("知道了", role: .cancel) { tools.error = nil }
            } message: { Text(tools.error ?? "") }
        }
    }

    private func title(for marks: [ReaderMark]) -> Text {
        if marks.count > 1 { return Text("此处的批注（\(marks.count)）") }
        if marks.first?.note.isEmpty == true { return Text("标注") }
        return Text("批注")
    }

    private func entry(_ mark: ReaderMark, candidates: NoteCandidates) -> some View {
        VStack(alignment: .leading, spacing: LayoutTokens.control) {
            Text(verbatim: mark.excerpt)
                .font(.subheadline)
                .foregroundStyle(Color(uiColor: theme.secondary))
                .padding(.leading, LayoutTokens.control)
                .background(alignment: .leading) {
                    Rectangle().fill(Color(uiColor: theme.annotation)).frame(width: 3)
                }
            if !mark.note.isEmpty {
                Text(verbatim: mark.note).font(.body)
            }
            HStack {
                Button {
                    do { try session.openAnnotation(mark, shown: candidates) }
                    catch { tools.error = ReaderMessages.error(error) }
                } label: {
                    Text(mark.note.isEmpty ? "写批注" : "编辑批注")
                }
                .foregroundStyle(Color(uiColor: theme.accent))
                Spacer(minLength: LayoutTokens.control)
                Button(role: .destructive) {
                    deleting = true
                    Task {
                        await tools.delete([mark.id], expected: candidates)
                        if tools.error == nil { session.notesChanged() }
                        deleting = false
                    }
                } label: {
                    Label("移除批注", systemImage: "trash")
                }
                .foregroundStyle(Color(uiColor: theme.destructive))
            }
            .disabled(deleting)
        }
        .accessibilityElement(children: .contain)
    }
}

struct ReaderAnnotationPanelSize: Equatable, Sendable {
    let content: CGFloat
    let viewport: CGFloat
}
