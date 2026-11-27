import MoonreadDesign
import MoonreadCoreBindings
import SwiftUI

/// A unary native List row. The list can obtain its ID from ForEach without
/// constructing every chapter's text, formatters and geometry observers.
struct ReaderChapterRow<Actions: View>: View {
    let chapter: ChapterEntry
    let current: Bool
    var showsCoverage = true
    let select: () -> Void
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        let count = chapter.countComplete ? String(localized: "\(chapter.wordCount.formatted()) 字") : String(localized: "\(chapter.wordCount.formatted())+ 字")
        let summary = current ? String(localized: "当前章节，\(count)") : count
        let accessibilitySummary = chapter.level == 0 || !showsCoverage ? summary : String(localized: "\(summary)，\(chapter.coverageLabel)")
        Button(action: select) {
            let meta = [count, showsCoverage ? chapter.listCoverageLabel : nil].compactMap { $0 }.joined(separator: " · ")
            ReaderChapterLabel(
                title: Text(verbatim: chapter.title),
                titleFont: chapter.level == 0 ? .headline : .body,
                current: current,
                metadata: meta
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: LayoutTokens.hit)
            .padding(.vertical, 4)
            .modifier(ReaderChapterRowSurface(current: current))
        }
        .buttonStyle(.plain)
        .contextMenu { actions() }
        .accessibilityLabel(Text(verbatim: chapter.title))
        .accessibilityValue(accessibilitySummary)
        .accessibilityAddTraits(current ? .isSelected : [])
        .accessibilityIdentifier("chapter-\(chapter.startUtf8)")
    }
}

struct ReaderChapterLabel: View {
    let title: Text
    var titleFont: Font = .body
    let current: Bool
    var metadata: String?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            title.font(titleFont)
                .fontWeight(current ? .semibold : nil)
                .foregroundStyle(Color(uiColor: current ? theme.accent : theme.ink))
                .lineLimit(metadata == nil ? nil : 2)
            if let metadata {
                Text(verbatim: metadata).font(.caption).monospacedDigit()
                    .foregroundStyle(Color(uiColor: current ? theme.accent : theme.secondary))
            }
        }
    }
}

struct ReaderChapterRowSurface: ViewModifier {
    let current: Bool
    @Environment(\.theme) private var theme
    private let selectionInset: CGFloat = 6

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, selectionInset)
            .background {
                if current {
                    RoundedRectangle(cornerRadius: LayoutTokens.compact)
                        .fill(Color(uiColor: theme.selected))
                }
            }
            .padding(.horizontal, LayoutTokens.page - selectionInset)
            .contentShape(.rect)
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
