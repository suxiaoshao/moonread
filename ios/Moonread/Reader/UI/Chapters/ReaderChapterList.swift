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
    @State private var visibility = ChapterVisibility()

    var body: some View {
        let currentParent = !editingOutline && model.chapterFilter.isEmpty
            ? model.chapterSnapshot.first(where: isCurrent)?.parentUtf8 : nil
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
                    let groups = outlineGroups
                    let firstGroup = groups.first
                    if firstGroup == nil || firstGroup?.volume != nil {
                        Section {
                            coverRow
                        }
                        .listSectionSpacing(0)
                    }
                    ForEach(groups) { group in
                        Section {
                            if group.volume == nil, group.id == firstGroup?.id {
                                coverRow
                            }
                            if editingOutline, let volume = group.volume { chapterRow(volume) }
                            ForEach(group.chapters, id: \.startUtf8) { chapter in
                                chapterRow(chapter, occludingParent: editingOutline ? nil : group.volume?.startUtf8)
                            }
                        } header: {
                            if !editingOutline, let volume = group.volume {
                                volumeHeader(volume, occludesCurrent: volume.startUtf8 == currentParent)
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
            .listSectionSpacing(.custom(LayoutTokens.compact))
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: theme.surface))
            .coordinateSpace(name: "chapterListViewport")
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                visibility.viewportHeight = $0
                chapterVisibilityKnown = $0 > 0
                publishVisibility()
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
            .safeAreaInset(edge: .top, spacing: 0) {
                if let error = model.chapterCoverageError, !editingOutline {
                    Text(verbatim: error).font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                        .padding(.horizontal).padding(.vertical, 6)
                }
            }
            .task(id: model.chapterAccountRevision) {
                if model.chapterAccountRevision != nil { await model.refreshChapters() }
            }
            .task(id: editingOutline ? nil : model.chapterCoverageRequest) {
                model.releaseCoverage()
                if !editingOutline, let request = model.chapterCoverageRequest { await model.observeCoverage(request) }
            }
            .onDisappear { model.releaseCoverage() }
            .task(id: model.chapterJumpRevision) {
                if session.showingCover && model.chapterFilter.isEmpty { proxy.scrollTo("reader-cover", anchor: .top) }
                else if let target = model.chapterTarget {
                    proxy.scrollTo(target, anchor: model.chapterTargetCentered ? .center : .top)
                }
            }
            .overlay {
                if model.chapters.isEmpty {
                    if model.loadingChapters { LoadingActivity(fullPage: true, delay: LoadingTiming.inlineDelay) }
                    else { ThemedEmptyState(title: String(localized: "没有找到章节"), symbol: "list.bullet") }
                }
            }
        }
    }

    private var coverRow: some View {
        let current = session.showingCover
        return Button {
            chapterFilterFocused = false
            navigate(0, nil, .cover)
        } label: {
            HStack(spacing: LayoutTokens.compact) {
                Text("封面")
                    .font(.body)
                    .fontWeight(current ? .semibold : nil)
                    .foregroundStyle(Color(uiColor: theme.ink))
                Spacer(minLength: LayoutTokens.compact)
                Image(systemName: "book.closed")
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: theme.secondary))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: LayoutTokens.hit)
            .modifier(ReaderChapterRowSurface(current: current))
        }
        .buttonStyle(.plain)
        .id("reader-cover")
        .accessibilityIdentifier("showBookCover")
        .accessibilityAddTraits(current ? .isSelected : [])
        .listRowBackground(Color(uiColor: theme.surface))
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
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
    private func chapterRow(_ chapter: ChapterEntry, occludingParent: UInt64? = nil) -> some View {
        let current = isCurrent(chapter)
        return ReaderChapterRow(chapter: model.chapterWithCoverage(chapter), current: current,
                                showsCoverage: model.chapterCoverageReady) {
            chapterFilterFocused = false
            if editingOutline { editChapter(ChapterEditDraft(start: chapter.startUtf8, title: chapter.title, level: chapter.level)) }
            else if chapter.level == 0 { model.toggleVolume(chapter.startUtf8) }
            else { navigate(chapter.startUtf8, nil, .start) }
        } actions: { chapterActions(chapter) }
        .modifier(ReaderChapterFrame(tracked: current) { frame in
            reportChapterFrame(frame, for: chapter, occludingParent: occludingParent)
        })
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color(uiColor: theme.surface))
        .listRowSeparator(.hidden)
    }

    private func isCurrent(_ chapter: ChapterEntry) -> Bool {
        !session.showingCover && session.chapter?.startUtf8 == chapter.startUtf8
    }

    private func volumeHeader(_ volume: ChapterEntry, occludesCurrent: Bool) -> some View {
        let current = isCurrent(volume)
        let expanded = !model.collapsedVolumes.contains(volume.startUtf8)
        return Button {
            model.toggleVolume(volume.startUtf8)
        } label: {
            HStack(spacing: LayoutTokens.control) {
                ReaderChapterLabel(title: Text(verbatim: volume.title), titleFont: .headline, current: current)
                Spacer(minLength: LayoutTokens.control)
                Image(systemName: expanded ? "chevron.down" : "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(uiColor: theme.secondary))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: LayoutTokens.hit)
            .modifier(ReaderChapterRowSurface(current: current))
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .id(volume.startUtf8)
        .contextMenu { chapterActions(volume) }
        .accessibilityLabel(Text(verbatim: volume.title))
        .accessibilityValue(expanded ? Text("已展开") : Text("已收起"))
        .accessibilityAddTraits(current ? [.isHeader, .isSelected] : .isHeader)
        .accessibilityIdentifier("volume-\(volume.startUtf8)")
        .modifier(ReaderChapterFrame(tracked: current || occludesCurrent) { frame in
            if current { reportChapterFrame(frame, for: volume, occludingParent: nil) }
            if occludesCurrent || visibility.header?.offset == volume.startUtf8 {
                visibility.header = frame.map { .init(offset: volume.startUtf8, rect: $0) }
                publishVisibility()
            }
        })
        .listRowInsets(EdgeInsets())
    }

    // Only the current item and its own header report frames. Publish to the
    // sheet only when the result changes, so scrolling does not rebuild the list.
    private final class ChapterVisibility {
        struct Frame {
            let offset: UInt64
            let rect: CGRect
        }

        var viewportHeight: CGFloat = 0
        var item: Frame?
        var parent: UInt64?
        var header: Frame?
    }

    private func reportChapterFrame(_ frame: CGRect?, for chapter: ChapterEntry, occludingParent: UInt64?) {
        if let frame {
            guard isCurrent(chapter) else { return }
            visibility.item = .init(offset: chapter.startUtf8, rect: frame)
            visibility.parent = occludingParent
        } else if visibility.item?.offset == chapter.startUtf8 {
            visibility.item = nil
        }
        publishVisibility()
    }

    private func publishVisibility() {
        var next: Set<UInt64> = []
        if !session.showingCover, let item = visibility.item, item.offset == session.chapter?.startUtf8 {
            let top = max(item.rect.minY, 0)
            let bottom = min(item.rect.maxY, visibility.viewportHeight)
            let covered = visibility.header.flatMap { header in
                header.offset == visibility.parent
                    ? max(0, min(bottom, header.rect.maxY) - max(top, header.rect.minY)) : nil
            } ?? 0
            if item.rect.height > 0, bottom - top - covered >= item.rect.height * 0.6 { next.insert(item.offset) }
        }
        if next != visibleChapters { visibleChapters = next }
    }
}
