import Combine
import SwiftUI

struct BookSearchTagRulePage: View {
    private enum Relation: CaseIterable, Hashable {
        case any, all, none, untagged

        init(_ match: BookSearchMatch) {
            switch match {
            case .any: self = .any
            case .all: self = .all
            case .none: self = .none
            }
        }

        var match: BookSearchMatch {
            switch self {
            case .any, .untagged: .any
            case .all: .all
            case .none: .none
            }
        }

        var title: String {
            self == .untagged ? String(localized: "无标签") : match.title
        }

    }

    let initial: BookSearchNode
    let onChange: (Bool) -> Void
    let complete: (BookSearchNode?) -> Void
    @State private var relation: Relation
    @State private var words: [String]
    @State private var preservesExistingUntagged: Bool

    init(initial: BookSearchNode, onChange: @escaping (Bool) -> Void,
         complete: @escaping (BookSearchNode?) -> Void) {
        self.initial = initial
        self.onChange = onChange
        self.complete = complete
        let isUntagged = initial.match == .any && initial.values == [.untagged]
        _relation = State(initialValue: isUntagged ? .untagged : Relation(initial.match))
        _words = State(initialValue: initial.values.compactMap { if case .text(let word) = $0 { word } else { nil } })
        _preservesExistingUntagged = State(initialValue: !isUntagged && initial.values.contains(.untagged))
    }

    private var node: BookSearchNode {
        var node = initial
        if !preservesExistingUntagged || relation == .untagged {
            node.kind = .rule(relation == .untagged ? .untagged : .tag(relation.match, words.map(BookSearchValue.text)))
        }
        return node
    }

    var body: some View {
        BookTagPicker(service: .shared, purpose: .filter,
                      showsChoices: relation != .untagged && !preservesExistingUntagged,
                      match: relation.match, selection: $words) {
            VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                Picker("标签关系", selection: $relation) {
                    ForEach(Relation.allCases, id: \.self) { relation in
                        Text(relation.title).tag(relation)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(preservesExistingUntagged)
                if preservesExistingUntagged {
                    // A saved mixed or negative predicate keeps its exact meaning until explicitly edited.
                    Text(node.expression { $0 }).font(.footnote)
                    Button("移除无标签选项") { preservesExistingUntagged = false }
                }
            }
            .padding(.top, LayoutTokens.compact)
        } status: {
            if relation == .untagged {
                BookTagUntaggedStatus(restorableCount: words.count)
            }
        }
        .onChange(of: node) { _, value in
            onChange(value != initial && (!value.values.isEmpty || !initial.values.isEmpty))
        }
        .onDisappear { onChange(false) }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SystemToolbarButton("完成", role: .confirm) {
                    complete(node.values.isEmpty ? nil : node)
                }
                    .accessibilityIdentifier("saveSearchCondition")
            }
        }
    }
}

private struct BookTagUntaggedStatus: View {
    let restorableCount: Int
    @State private var count: Int?
    @State private var revision = 0

    var body: some View {
        ContentUnavailableView {
            Label("筛选没有标签的小说", systemImage: "tag.slash")
        } description: {
            VStack(spacing: LayoutTokens.compact) {
                if let count {
                    if count == 0 {
                        Text("书库里还没有符合此条件的小说。")
                    } else {
                        Text("书库里有 \(count) 本小说没有标签。")
                    }
                }
                Text("无需再选标签，点右上角的 ✓ 完成。")
                if restorableCount > 0 {
                    Text("切回其他方式，将恢复这 \(restorableCount) 个标签。")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .readingContinuationInvalidated, object: AppDataService.shared)
            .receive(on: DispatchQueue.main)) { _ in
            count = nil
            revision += 1
        }
        .task(id: revision) {
            let request = revision
            if let result = try? await AppDataService.shared.untaggedBookCount(), !Task.isCancelled, request == revision {
                count = result
            }
        }
    }
}
