import SwiftUI

struct BookSearchSummaryCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        content.frame(maxWidth: .infinity, alignment: .leading)
            .padding(LayoutTokens.content)
            .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
    }
}

struct BookSearchSummaryTitle: View {
    let title: LocalizedStringKey
    @Environment(\.theme) private var theme

    var body: some View {
        Text(title).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
            .accessibilityAddTraits(.isHeader)
    }
}

struct BookSearchRuleCard<Count: View, Footer: View>: View {
    let root: BookSearchNode
    let title: LocalizedStringKey
    let shelfTitle: (String) -> String
    @ViewBuilder let count: Count
    @ViewBuilder let footer: Footer

    var body: some View {
        let displayedRule = !root.excluded && root.children.count == 1 ? root.children[0] : root
        VStack(alignment: .leading, spacing: LayoutTokens.compact) {
            if Count.self == EmptyView.self {
                BookSearchSummaryTitle(title: title)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: LayoutTokens.control) {
                        BookSearchSummaryTitle(title: title).fixedSize()
                        Spacer(minLength: 0)
                        count.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        BookSearchSummaryTitle(title: title)
                        count
                    }
                }
            }
            BookSearchSummaryCard {
                VStack(alignment: .leading, spacing: LayoutTokens.control) {
                    SavedFilterRuleTree(node: displayedRule, shelfTitle: shelfTitle)
                    footer
                }
            }
        }
    }
}

struct BookSearchSortCard: View {
    let sorts: [BookSearchSort]

    var body: some View {
        if !sorts.isEmpty {
            VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                BookSearchSummaryTitle(title: "排序")
                BookSearchSummaryCard { SavedFilterSortSummary(sorts: sorts) }
            }
        }
    }
}

/// Labels follow the original rule tree. Only a rule's value choices may add
/// visual leaves, such as the alternatives of a multi-status condition.
private struct SavedFilterRuleTree: View {
    let node: BookSearchNode
    let shelfTitle: (String) -> String
    @Environment(\.theme) private var theme

    var body: some View {
        switch node.kind {
        case .group(let relation, let children) where !children.isEmpty:
            VStack(alignment: .leading, spacing: 0) {
                heading(relation == .all ? Text("同时满足") : Text("命中任一项的小说"))
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    SavedFilterTreeBranch(continues: index < children.count - 1) {
                        SavedFilterRuleTree(node: child, shelfTitle: shelfTitle)
                    }
                }
            }
            .accessibilityElement(children: .contain)
        case .rule(.status(let states)) where states.count > 1:
            VStack(alignment: .leading, spacing: 0) {
                heading(Text("阅读状态符合任一项")).accessibilityAddTraits(.isHeader)
                ForEach(Array(states.enumerated()), id: \.element) { index, state in
                    SavedFilterTreeBranch(continues: index < states.count - 1) {
                        Text(verbatim: state.title)
                    }
                }
            }
            .accessibilityElement(children: .contain)
        case .rule(.status(let states)) where states.count == 1:
            heading(Text("阅读状态「\(states[0].title)」"))
        default:
            heading(Text(verbatim: node.expression(includingExclusion: false, shelfTitle: shelfTitle)))
        }
    }

    private func heading(_ label: Text) -> some View {
        let prefix = Text("排除").foregroundColor(Color(uiColor: theme.accent))
        return (node.excluded ? Text("\(prefix) \(label)") : label)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SavedFilterTreeBranch<Content: View>: View {
    let continues: Bool
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .body) private var labelCenter = 10.0

    var body: some View {
        content
            .padding(.leading, LayoutTokens.page)
            .padding(.top, 4)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Path { line in
                        let x = LayoutTokens.compact / 2
                        let y = min(geometry.size.height, labelCenter + 4)
                        line.move(to: CGPoint(x: x, y: 0))
                        line.addLine(to: CGPoint(x: x, y: continues ? geometry.size.height : y))
                        line.move(to: CGPoint(x: x, y: y))
                        line.addLine(to: CGPoint(x: geometry.size.width, y: y))
                    }
                    .stroke(Color(uiColor: theme.border), lineWidth: 1 / displayScale)
                    .flipsForRightToLeftLayoutDirection(true)
                }
                .frame(width: LayoutTokens.control)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

private struct SavedFilterSortSummary: View {
    let sorts: [BookSearchSort]

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutTokens.compact) {
            ForEach(Array(sorts.enumerated()), id: \.element.id) { index, sort in
                SavedFilterSortLine(priority: index + 1, sort: sort)
            }
        }
    }
}

private struct SavedFilterSortLine: View {
    let priority: Int
    let sort: BookSearchSort

    private var direction: LocalizedStringKey {
        if sort.field == .recent { return sort.descending ? "从近到远" : "从远到近" }
        return sort.descending ? "降序" : "升序"
    }

    private var number: some View {
        Text("\(priority).").monospacedDigit()
    }
    private var label: some View {
        Label {
            Text(direction)
        } icon: {
            Image(systemName: sort.descending ? "arrow.down" : "arrow.up")
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: LayoutTokens.compact) {
                number
                Text(verbatim: sort.field.title).fixedSize()
                Spacer(minLength: LayoutTokens.compact)
                label.fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: LayoutTokens.compact) {
                number
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: sort.field.title)
                    label
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("第 \(priority) 排序键，\(sort.field.title)，\(Text(direction))"))
    }
}
