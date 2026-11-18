import SwiftUI

/// A unary native List row. The list can obtain its ID from ForEach without
/// constructing every chapter's text, formatters and geometry observers.
struct ReaderChapterRow<Actions: View>: View {
    let chapter: ChapterEntry
    let current: Bool
    var showsCoverage = true
    let indented: Bool
    let select: () -> Void
    @ViewBuilder let actions: () -> Actions
    @Environment(\.theme) private var theme

    var body: some View {
        let count = chapter.countComplete ? String(localized: "\(chapter.wordCount.formatted()) 字") : String(localized: "\(chapter.wordCount.formatted())+ 字")
        let summary = current ? String(localized: "当前章节，\(count)") : count
        let accessibilitySummary = chapter.level == 0 || !showsCoverage ? summary : String(localized: "\(summary)，\(chapter.coverageLabel)")
        Button(action: select) {
            let meta = [count, showsCoverage ? chapter.listCoverageLabel : nil].compactMap { $0 }.joined(separator: " · ")
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
            }
            .padding(.leading, indented ? LayoutTokens.content : 0)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { actions() }
        .accessibilityLabel(Text(verbatim: chapter.title))
        .accessibilityValue(accessibilitySummary)
        .accessibilityAddTraits(current ? .isSelected : [])
        .accessibilityIdentifier("chapter-\(chapter.startUtf8)")
    }
    private var title: some View {
        ReaderChapterTitle(chapter: chapter, current: current)
    }
    private func metadata(_ text: String) -> some View {
        Text(verbatim: text).font(.caption).monospacedDigit()
            .foregroundStyle(Color(uiColor: theme.secondary))
    }
}

struct ReaderChapterTitle: View {
    let chapter: ChapterEntry
    let current: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LayoutTokens.compact) {
            if current {
                Image(systemName: "book.fill").font(.footnote)
                    .foregroundStyle(Color(uiColor: theme.accent))
                    .accessibilityHidden(true)
            }
            Text(verbatim: chapter.title).font(chapter.level == 0 ? .headline : .body)
                .fontWeight(current ? .semibold : nil)
                .foregroundStyle(Color(uiColor: theme.ink))
        }
    }
}

struct ReaderChapterFrame: ViewModifier {
    let tracked: Bool
    let changed: (CGRect?) -> Void

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect?.self) { geometry in
                tracked ? geometry.frame(in: .named("chapterListViewport")) : nil
            } action: { changed($0) }
            .onDisappear { if tracked { changed(nil) } }
    }
}
