import SwiftUI
import UIKit

struct ReaderMoreContent: View {
    let session: ReaderSession
    let openLibrary: (ReaderLibraryTab, Bool) -> Void
    let presentPanel: (ReaderTool) -> Void
    let changeEncoding: (String?) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    ForEach(moreActions) { action in
                        moreButton(action) { label in
                            HStack { label; Spacer(minLength: 0) }
                                // The whole row is the target; the sheet draws slightly scaled.
                                .frame(minHeight: 52)
                        }
                    }
                    if session.encodingLabel != nil {
                        moreEncodingMenu.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    }
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(moreActions) { action in
                        moreButton(action) { label in
                            label.labelStyle(ReaderToolLabelStyle())
                                .frame(maxWidth: .infinity, minHeight: 56)
                        }
                    }
                    if session.encodingLabel != nil {
                        moreEncodingMenu.labelStyle(ReaderToolLabelStyle())
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                }
            }
        }
        .padding(.horizontal, 24).padding(.top, LayoutTokens.content)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("readerMorePanel")
    }

    private var moreEncodingMenu: some View {
        ReaderEncodingMenu(title: "更换编码", symbol: "character.bubble", isRestarting: session.restartingEncoding, select: changeEncoding)
            .foregroundStyle(Color(uiColor: theme.ink))
            .accessibilityIdentifier("moreTextEncoding")
    }

    private enum MoreAction: String, Identifiable {
        case bookmark, bookmarks, notes, details
        var id: Self { self }
    }

    private var moreActions: [MoreAction] { [.bookmark, .bookmarks, .notes, .details] }

    /// One 更多 action: the visible names stay short; VoiceOver and Voice Control get the full ones.
    private func moreButton(_ action: MoreAction, @ViewBuilder layout: (MoreLabel) -> some View) -> some View {
        let marked = action == .bookmark && session.bookmarked
        let symbol = switch action {
        case .bookmark: marked ? "bookmark.fill" : "bookmark"
        case .bookmarks: "list.bullet.rectangle"
        case .notes: "highlighter"
        case .details: "info.circle"
        }
        let title: LocalizedStringKey = switch action {
        case .bookmark: "书签"
        case .bookmarks: "书签列表"
        case .notes: "笔记"
        case .details: "详情"
        }
        let label = MoreLabel(title: title, symbol: symbol, bookmarked: session.bookmarked, reduceMotion: reduceMotion)
        return Button {
            switch action {
            case .bookmark: Task { await session.toggleBookmark() }
            case .bookmarks: openLibrary(.bookmarks, true)
            case .notes: openLibrary(.notes, true)
            case .details: presentPanel(.details)
            }
        } label: {
            layout(label).foregroundStyle(Color(uiColor: marked ? theme.accent : theme.ink)).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(action == .bookmark && (session.showingCover || session.changingBookmark))
        .opacity(action == .bookmark && session.showingCover ? 0.45 : 1)
        .modifier(MoreAccessibility(action: action, bookmarked: session.bookmarked, cover: session.showingCover))
    }

    /// The action's label; the surrounding label style decides the layout.
    private struct MoreLabel: View {
        let title: LocalizedStringKey
        let symbol: String
        let bookmarked: Bool
        let reduceMotion: Bool
        var body: some View {
            Label(title, systemImage: symbol)
                .contentTransition(.symbolEffect(.replace))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: bookmarked)
        }
    }

    private struct MoreAccessibility: ViewModifier {
        let action: MoreAction
        let bookmarked: Bool
        let cover: Bool
        func body(content: Content) -> some View {
            switch action {
            case .bookmark:
                content
                    .accessibilityLabel("书签")
                    .accessibilityValue(bookmarked ? Text("已添加") : Text("未添加"))
                    .accessibilityHint(cover ? Text("封面不能添加书签") : Text("添加或移除当前位置的书签"))
                    .accessibilityInputLabels([Text("书签"), Text("添加书签"), Text("移除书签")])
                    .accessibilityAddTraits(bookmarked ? .isSelected : [])
                    .accessibilityIdentifier("toggleBookmark")
            case .bookmarks:
                content.accessibilityLabel("书签列表").accessibilityHint("查看全部书签")
                    .accessibilityIdentifier("openBookmarks")
            case .notes:
                content.accessibilityLabel("标注与笔记")
                    .accessibilityInputLabels([Text("笔记"), Text("标注与笔记")])
                    .accessibilityIdentifier("openNotes")
            case .details:
                content.accessibilityLabel("小说详情")
                    .accessibilityInputLabels([Text("详情"), Text("小说详情")])
                    .accessibilityIdentifier("moreBookDetails")
            }
        }
    }

}
