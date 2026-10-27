import SwiftUI
import UIKit

struct ReaderChapterList: View {
    @Bindable var model: ReaderToolsModel
    let session: ReaderSession
    let navigate: (UInt64, UInt64?, ReadingTargetPlacement) -> Void
    @Binding var visibleChapters: Set<UInt64>
    @Binding var chapterVisibilityKnown: Bool
    @Binding var editingOutline: Bool
    @Binding var chapterEdit: ChapterEditDraft?
    @Binding var removedChapter: ChapterEntry?
    @FocusState.Binding var chapterFilterFocused: Bool
    let refreshOutline: () async -> Void
    var restoringOffset: UInt64? = nil
    @State private var restoredViewport = false
    @Environment(\.theme) private var theme
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                chapterSearchField
                .padding(.horizontal, LayoutTokens.content)
                .padding(.bottom, LayoutTokens.compact)
                if session.incomplete {
                    HStack {
                        Text("目录准备中").foregroundStyle(Color(uiColor: theme.secondary))
                        Button("刷新目录", systemImage: "arrow.clockwise") {
                            Task { await model.refreshChapters() }
                        }.labelStyle(.iconOnly).frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
                        Spacer()
                    }
                    .font(.caption).padding(.horizontal, LayoutTokens.content)
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if model.chapterFilter.isEmpty {
                            Button { navigate(0, nil, .cover) } label: {
                                VStack(spacing: 0) {
                                    HStack(spacing: LayoutTokens.control) {
                                        Image(systemName: "book.closed")
                                        Text("封面")
                                        Spacer()
                                    }.font(.body)
                                        .foregroundStyle(Color(uiColor: session.showingCover ? theme.accent : theme.ink))
                                        .padding(.vertical, LayoutTokens.content).frame(minHeight: LayoutTokens.hit)
                                    Rectangle().fill(Color(uiColor: theme.separator)).frame(height: 0.5)
                                }
                                .padding(.horizontal, LayoutTokens.content).contentShape(.rect)
                            }.buttonStyle(.plain).id("reader-cover")
                                .accessibilityIdentifier("showBookCover")
                                .accessibilityAddTraits(session.showingCover ? .isSelected : [])
                        }
                        if let first = model.chapters.first, let parent = first.parentUtf8, let title = first.parentTitle {
                            Button { toggleVolume(parent) } label: {
                                HStack { Text(title).font(.headline); Spacer(); Image(systemName: "chevron.down") }
                                    .padding(LayoutTokens.content).frame(minHeight: 44)
                            }.id("parent-\(parent)")
                        }
                        ForEach(model.chapters, id: \.startUtf8) { chapter in
                            chapterRow(chapter).id(chapter.startUtf8)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("chapterList")
                .onScrollTargetVisibilityChange(idType: UInt64.self, threshold: 0.6) { ids in
                    visibleChapters = Set(ids); chapterVisibilityKnown = true
                }
                // Reserved below the list, so the last rows scroll clear of the action.
                .safeAreaInset(edge: .bottom) {
                    if let target = returnTarget {
                        Button {
                            chapterFilterFocused = false
                            // Moves the directory only; reading stays where it is.
                            if model.chapterFilter.isEmpty, model.chapters.contains(where: { $0.startUtf8 == target }) {
                                withAnimation(reduceMotion ? nil : MotionTokens.panel(reduced: false)) { proxy.scrollTo(target, anchor: .center) }
                            } else { model.showChapter(target) }
                        } label: {
                            Label("回到当前章", systemImage: "scope").font(.subheadline.weight(.medium))
                                .padding(.horizontal, LayoutTokens.content).frame(minHeight: LayoutTokens.hit)
                                .background(Color(uiColor: theme.raised), in: .capsule)
                                .overlay { Capsule().strokeBorder(Color(uiColor: theme.border), lineWidth: LayoutTokens.border) }
                        }
                        .buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.ink))
                        .accessibilityIdentifier("returnToCurrentChapter")
                        .padding(.vertical, LayoutTokens.compact)
                    }
                }
                .onChange(of: model.chapterJumpRevision, initial: true) { _, _ in
                    if !restoredViewport, let restoringOffset { proxy.scrollTo(restoringOffset, anchor: .top) }
                    else if session.showingCover && model.chapterFilter.isEmpty { proxy.scrollTo("reader-cover", anchor: .top) }
                    else if let target = model.chapterTarget {
                        proxy.scrollTo(target, anchor: model.chapterTargetCentered ? .center : .top)
                    }
                    restoredViewport = true
                }
                .overlay {
                    if model.chapters.isEmpty {
                        if model.loadingChapters { LoadingActivity(fullPage: true) }
                        else { ThemedEmptyState(title: String(localized: "没有找到章节"), symbol: "list.bullet") }
                    }
                }
            }
        }
    }

    /// The current chapter, when it is a real outline entry hidden by scrolling, a
    /// filter or a folded volume, and the keyboard is not up. The cover needs none.
    private var returnTarget: UInt64? {
        guard !chapterFilterFocused, chapterVisibilityKnown, !session.showingCover,
              let target = session.chapter?.startUtf8, model.containsChapter(target) else { return nil }
        let listed = model.chapters.contains { $0.startUtf8 == target }
        return listed && visibleChapters.contains(target) ? nil : target
    }

    private var chapterSearchField: some View {
        HStack(spacing: LayoutTokens.compact) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color(uiColor: theme.secondary))
            TextField("查找章节", text: Binding(get: { model.chapterFilter }, set: model.filterChapters))
                .textFieldStyle(.plain).foregroundStyle(Color(uiColor: theme.ink))
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .focused($chapterFilterFocused).submitLabel(.search)
                .onSubmit { chapterFilterFocused = false }
                .accessibilityIdentifier("chapterFilter")
            if !model.chapterFilter.isEmpty {
                Button("清除章节搜索", systemImage: "xmark.circle.fill") { model.filterChapters("") }
                    .labelStyle(.iconOnly).foregroundStyle(Color(uiColor: theme.secondary))
                    .frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
            }
        }
        .padding(.leading, LayoutTokens.content).padding(.trailing, 4)
        .frame(minHeight: LayoutTokens.hit)
        .background(Color(uiColor: theme.input), in: .rect(cornerRadius: LayoutTokens.inputRadius))
        .overlay(RoundedRectangle(cornerRadius: LayoutTokens.inputRadius)
            .strokeBorder(Color(uiColor: chapterFilterFocused ? theme.focus : theme.border), lineWidth: LayoutTokens.border))
        .keyboardInputRegion()
    }

    private func toggleVolume(_ offset: UInt64) { model.toggleVolume(offset) }

    private func removeChapter(_ chapter: ChapterEntry) {
        guard let id = session.readingID else { return }
        Task {
            do {
                try await AppDataService.shared.correctChapter(id, offset: chapter.startUtf8, title: chapter.title, level: chapter.level, excluded: true)
                removedChapter = chapter; await refreshOutline()
            } catch { model.error = ReaderMessages.error(error) }
        }
    }

    private func chapterRow(_ chapter: ChapterEntry) -> some View {
        let current = !session.showingCover && session.chapter?.startUtf8 == chapter.startUtf8
        let count = chapter.countComplete ? String(localized: "\(chapter.wordCount.formatted()) 字") : String(localized: "\(chapter.wordCount.formatted())+ 字")
        let summary = current ? String(localized: "当前章节，\(count)") : count
        let accessibilitySummary = chapter.level == 0 ? summary : String(localized: "\(summary)，\(chapter.coverageLabel)")
        return Button {
            chapterFilterFocused = false
            if editingOutline { chapterEdit = ChapterEditDraft(start: chapter.startUtf8, title: chapter.title, level: chapter.level) }
            else if chapter.level == 0 { toggleVolume(chapter.startUtf8) }
            else { navigate(chapter.startUtf8, nil, .start) }
        } label: {
            VStack(spacing: 0) {
                // Short titles keep their data on the same line; a title that would not fit
                // wraps to two lines with the data beneath, never squeezed by it.
                HStack(alignment: .firstTextBaseline, spacing: LayoutTokens.control) {
                    if chapter.level == 0 {
                        chapterTitle(chapter, current: current).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: model.collapsedVolumes.contains(chapter.startUtf8) ? "chevron.right" : "chevron.down")
                    } else {
                        let meta = [count, chapter.listCoverageLabel].compactMap { $0 }.joined(separator: " · ")
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: LayoutTokens.control) {
                                chapterTitle(chapter, current: current).lineLimit(1).fixedSize()
                                Spacer(minLength: LayoutTokens.control)
                                chapterMeta(meta, current: current).fixedSize()
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                chapterTitle(chapter, current: current).lineLimit(2)
                                chapterMeta(meta, current: current)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.leading, chapter.parentUtf8 == nil ? 0 : 12)
                .padding(.vertical, LayoutTokens.content).frame(minHeight: LayoutTokens.hit)
                Rectangle().fill(Color(uiColor: theme.separator)).frame(height: 0.5)
            }
            .padding(.horizontal, LayoutTokens.content).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("从这里阅读", systemImage: "book") { navigate(chapter.startUtf8, nil, .start) }
            if !session.incomplete {
                Button("编辑目录项", systemImage: "pencil") { chapterEdit = ChapterEditDraft(start: chapter.startUtf8, title: chapter.title, level: chapter.level) }
                Button("从目录移除", systemImage: "trash", role: .destructive) { removeChapter(chapter) }
            }
        }
        .accessibilityLabel(Text(verbatim: chapter.title))
        .accessibilityValue(accessibilitySummary)
        .accessibilityAddTraits(current ? .isSelected : [])
        .accessibilityIdentifier("chapter-\(chapter.startUtf8)")
    }

    private func chapterTitle(_ chapter: ChapterEntry, current: Bool) -> some View {
        Text(verbatim: chapter.title)
            .font(chapter.level == 0 ? .headline : .body)
            .foregroundStyle(Color(uiColor: current ? theme.accent : theme.ink))
    }
    private func chapterMeta(_ text: String, current: Bool) -> some View {
        Text(verbatim: text).font(.caption).monospacedDigit()
            .foregroundStyle(Color(uiColor: current ? theme.accent : theme.secondary))
    }

}
