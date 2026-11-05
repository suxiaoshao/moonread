import SwiftUI

struct ReaderChapterList: View {
    @Bindable var model: ReaderToolsModel
    let session: ReaderSession
    let navigate: (UInt64, UInt64?, ReadingTargetPlacement) -> Void
    @Binding var visibleChapters: Set<UInt64>
    @Binding var chapterVisibilityKnown: Bool
    @Binding var editingOutline: Bool
    let editChapter: (ChapterEditDraft) -> Void
    @Binding var removedChapter: ChapterEntry?
    @FocusState.Binding var chapterFilterFocused: Bool
    let refreshOutline: () async -> Void
    @Environment(\.theme) private var theme
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if session.incomplete {
                    HStack {
                        Text("目录准备中").foregroundStyle(Color(uiColor: theme.secondary))
                        Spacer()
                        Button("刷新目录", systemImage: "arrow.clockwise") {
                            Task { await model.refreshChapters() }
                        }.labelStyle(.iconOnly)
                    }.font(.caption).listRowBackground(Color(uiColor: theme.surface))
                }
                if model.chapterFilter.isEmpty {
                    Button { navigate(0, nil, .cover) } label: {
                        Label("封面", systemImage: "book.closed")
                            .foregroundStyle(Color(uiColor: session.showingCover ? theme.accent : theme.ink))
                    }
                    .id("reader-cover")
                    .accessibilityIdentifier("showBookCover")
                    .accessibilityAddTraits(session.showingCover ? .isSelected : [])
                    .listRowBackground(Color(uiColor: theme.surface))
                    .listRowSeparatorTint(Color(uiColor: theme.separator))
                    ForEach(outlineGroups) { group in
                        Section {
                            if let volume = group.volume {
                                if editingOutline {
                                    chapterRow(volume)
                                    ForEach(group.chapters, id: \.startUtf8) { chapter in
                                        chapterRow(chapter)
                                    }
                                }
                                else {
                                    DisclosureGroup(isExpanded: volumeExpanded(volume.startUtf8)) {
                                        ForEach(group.chapters, id: \.startUtf8) { chapter in
                                            chapterRow(chapter)
                                        }
                                    } label: { chapterTitle(volume, current: false) }
                                    .id(volume.startUtf8)
                                    .contextMenu { chapterActions(volume) }
                                    .listRowBackground(Color(uiColor: theme.surface))
                                    .listRowSeparatorTint(Color(uiColor: theme.separator))
                                    .accessibilityIdentifier("volume-\(volume.startUtf8)")
                                }
                            } else {
                                ForEach(group.chapters, id: \.startUtf8) { chapter in
                                    chapterRow(chapter)
                                }
                            }
                        }
                    }
                } else {
                    ForEach(model.chapters, id: \.startUtf8) { chapter in
                        chapterRow(chapter)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: theme.surface))
            .coordinateSpace(name: "chapterListViewport")
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                viewportHeight = $0; chapterVisibilityKnown = $0 > 0
            }
            .scrollDismissesKeyboard(.interactively)
            .searchable(text: Binding(get: { model.chapterFilter }, set: model.filterChapters),
                        placement: .navigationBarDrawer(displayMode: .always), prompt: "查找章节")
            .searchFocused($chapterFilterFocused)
            .autocorrectionDisabled().textInputAutocapitalization(.never)
            .onSubmit(of: .search) { chapterFilterFocused = false }
            .accessibilityIdentifier("chapterList")
            .safeAreaInset(edge: .bottom) {
                if let target = returnTarget {
                    Button {
                        chapterFilterFocused = false
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
            .task(id: model.chapterJumpRevision) {
                if session.showingCover && model.chapterFilter.isEmpty { proxy.scrollTo("reader-cover", anchor: .top) }
                else if let target = model.chapterTarget {
                    proxy.scrollTo(target, anchor: model.chapterTargetCentered ? .center : .top)
                }
            }
            .overlay {
                if model.chapters.isEmpty {
                    if model.loadingChapters { LoadingActivity(fullPage: true) }
                    else { ThemedEmptyState(title: String(localized: "没有找到章节"), symbol: "list.bullet") }
                }
            }
        }
    }

    private struct OutlineGroup: Identifiable {
        let id: UInt64
        let volume: ChapterEntry?
        var chapters: [ChapterEntry]
    }
    /// Presentation only: parent offsets already come from the Rust outline.
    private var outlineGroups: [OutlineGroup] {
        var groups: [OutlineGroup] = []
        for chapter in editingOutline ? model.chapterSnapshot : model.chapters {
            if chapter.level == 0 {
                groups.append(.init(id: chapter.startUtf8, volume: chapter, chapters: []))
            } else if let last = groups.indices.last, groups[last].volume?.startUtf8 == chapter.parentUtf8 {
                groups[last].chapters.append(chapter)
            } else {
                groups.append(.init(id: chapter.startUtf8, volume: nil, chapters: [chapter]))
            }
        }
        return groups
    }
    private func volumeExpanded(_ offset: UInt64) -> Binding<Bool> {
        Binding(get: { !model.collapsedVolumes.contains(offset) }, set: { expanded in
            if expanded != !model.collapsedVolumes.contains(offset) { model.toggleVolume(offset) }
        })
    }
    private var returnTarget: UInt64? {
        guard !chapterFilterFocused, chapterVisibilityKnown, !session.showingCover,
              let target = session.chapter?.startUtf8, model.containsChapter(target) else { return nil }
        return visibleChapters.contains(target) ? nil : target
    }
    private func removeChapter(_ chapter: ChapterEntry) {
        guard let id = session.readingID else { return }
        Task {
            do {
                try await AppDataService.shared.correctChapter(id, offset: chapter.startUtf8, title: chapter.title, level: chapter.level, excluded: true)
                removedChapter = chapter; await refreshOutline()
            } catch { model.error = ReaderMessages.error(error) }
        }
    }
    @ViewBuilder private func chapterActions(_ chapter: ChapterEntry) -> some View {
        Button("从这里阅读", systemImage: "book") { navigate(chapter.startUtf8, nil, .start) }
        if !session.incomplete {
            Button("编辑目录项", systemImage: "pencil") { editChapter(ChapterEditDraft(start: chapter.startUtf8, title: chapter.title, level: chapter.level)) }
            Button("从目录移除", systemImage: "trash", role: .destructive) { removeChapter(chapter) }
        }
    }
    private func chapterRow(_ chapter: ChapterEntry) -> some View {
        let current = !session.showingCover && session.chapter?.startUtf8 == chapter.startUtf8
        return ReaderChapterRow(chapter: chapter, current: current, viewportHeight: viewportHeight) {
            chapterFilterFocused = false
            if editingOutline { editChapter(ChapterEditDraft(start: chapter.startUtf8, title: chapter.title, level: chapter.level)) }
            else if chapter.level == 0 { model.toggleVolume(chapter.startUtf8) }
            else { navigate(chapter.startUtf8, nil, .start) }
        } visibilityChanged: { visible in
            guard current else { return }
            let next: Set<UInt64> = visible ? [chapter.startUtf8] : []
            if next != visibleChapters { visibleChapters = next }
        } actions: { chapterActions(chapter) }
    }
    private func chapterTitle(_ chapter: ChapterEntry, current: Bool) -> some View {
        Text(verbatim: chapter.title).font(chapter.level == 0 ? .headline : .body)
            .foregroundStyle(Color(uiColor: current ? theme.accent : theme.ink))
    }
}
