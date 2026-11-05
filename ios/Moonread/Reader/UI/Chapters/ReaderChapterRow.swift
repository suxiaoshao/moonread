import SwiftUI

/// A unary native List row. The list can obtain its ID from ForEach without
/// constructing every chapter's text, formatters and geometry observers.
struct ReaderChapterRow<Actions: View>: View {
    let chapter: ChapterEntry
    let current: Bool
    let viewportHeight: CGFloat
    let select: () -> Void
    let visibilityChanged: (Bool) -> Void
    @ViewBuilder let actions: () -> Actions
    @Environment(\.theme) private var theme

    var body: some View {
        let count = chapter.countComplete ? String(localized: "\(chapter.wordCount.formatted()) 字") : String(localized: "\(chapter.wordCount.formatted())+ 字")
        let summary = current ? String(localized: "当前章节，\(count)") : count
        let accessibilitySummary = chapter.level == 0 ? summary : String(localized: "\(summary)，\(chapter.coverageLabel)")
        Button(action: select) {
            let meta = [count, chapter.listCoverageLabel].compactMap { $0 }.joined(separator: " · ")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: LayoutTokens.control) {
                    title.lineLimit(1).fixedSize()
                    Spacer(minLength: LayoutTokens.control)
                    metadata(meta).fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    title.lineLimit(2)
                    metadata(meta)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { actions() }
        .listRowBackground(Color(uiColor: theme.surface))
        .listRowSeparatorTint(Color(uiColor: theme.separator))
        .modifier(ReaderChapterVisibility(current: current, viewportHeight: viewportHeight, changed: visibilityChanged))
        .accessibilityLabel(Text(verbatim: chapter.title))
        .accessibilityValue(accessibilitySummary)
        .accessibilityAddTraits(current ? .isSelected : [])
        .accessibilityIdentifier("chapter-\(chapter.startUtf8)")
    }
    private var title: some View {
        Text(verbatim: chapter.title).font(chapter.level == 0 ? .headline : .body)
            .foregroundStyle(Color(uiColor: current ? theme.accent : theme.ink))
    }
    private func metadata(_ text: String) -> some View {
        Text(verbatim: text).font(.caption).monospacedDigit()
            .foregroundStyle(Color(uiColor: current ? theme.accent : theme.secondary))
    }
}

/// Observe the current label/row only, never a whole expanded volume's bounds.
struct ReaderChapterVisibility: ViewModifier {
    let current: Bool
    let viewportHeight: CGFloat
    let changed: (Bool) -> Void

    func body(content: Content) -> some View {
        content
        .onGeometryChange(for: Bool.self) { geometry in
            guard current else { return false }
            let frame = geometry.frame(in: .named("chapterListViewport"))
            let visible = min(frame.maxY, viewportHeight) - max(frame.minY, 0)
            return frame.height > 0 && visible >= frame.height * 0.6
        } action: { changed($0) }
        .onDisappear { changed(false) }
    }
}
