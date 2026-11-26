import MoonreadLibrary
import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import SwiftUI

struct RecentLibraryView: View {
    @Bindable var model: LibraryModel
    @State private var recentUse: RecentReadingUse?
    private var entries: [RecentReadingRead.Card] { model.recentReading.value?.recentReading ?? [] }

    var body: some View {
        LibraryCollection(model: model, host: .main, sections: [
            .init(id: .recent, content: .files(entries.compactMap { try? $0.libraryEntry() }, .recent))
        ], hasTopAccessory: model.recentReading.failure != nil, onRefresh: {
            await model.refresh(showIndicator: false, userInitiated: true)
        })
        .themedPage()
        .navigationTitle("最近阅读")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LibraryDisplayMenu(selection: $model.layout)
            }
        }
        .overlay {
            if model.recentReading.value == nil, model.recentReading.failure == nil {
                ProgressView("正在加载")
            }
        }
        .safeAreaInset(edge: .top) {
            if let error = model.recentReading.failure {
                RecentReadingRetry(message: error) { model.recentReading.retry() }
            }
        }
        .task {
            if recentUse == nil { recentUse = model.recentReading.use(limit: RecentReadingStore.fullLimit) }
        }
    }
}

struct RecentBookActions: View {
    let model: LibraryModel
    let entry: LibraryEntry

    var body: some View {
        Button("小说详情", systemImage: "info.circle") {
            model.shell.path.append(.statistics(StatisticsRoute(target: .file(fileId: entry.id), title: entry.title)))
        }
        Button("从最近移除", systemImage: "minus.circle") {
            Task { await model.hideRecent(entry) }
        }
    }
}

/// The last successful snapshot stays visible when its observation fails.
struct RecentReadingRetry: View {
    let message: String
    let retry: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label { Text(message) } icon: { Image(systemName: "exclamationmark.circle") }
                .font(.footnote)
                .foregroundStyle(Color(uiColor: theme.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("重试", action: retry)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(uiColor: theme.canvas))
    }
}

private struct RecentBookRow: View {
    let model: LibraryModel
    let entry: LibraryEntry
    static let coverSize = CGSize(width: 44, height: 62)
    @Environment(\.theme) private var theme
    var body: some View {
        let label = LibraryItemLabel(entry: entry, theme: theme)
        let chapter = RecentBookItem.chapter(entry)
        let progress = RecentBookItem.progress(entry)
        HStack(spacing: 15) {
            Color.clear.frame(width: Self.coverSize.width, height: Self.coverSize.height)
            VStack(alignment: .leading, spacing: 7) {
                label.title().font(.body.weight(.medium)).lineLimit(1)
                HStack {
                    chapter.lineLimit(1)
                    Spacer(minLength: 8)
                    progress
                }.font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
            }
        }
        .padding(.vertical, 6)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .background {
            LibraryCoverButton(entry: entry, size: Self.coverSize, detail: Text("\(chapter), \(progress)")) {
                model.open(entry)
            } cover: {
                label.cover(compact: true)
                    .frame(width: Self.coverSize.width, height: Self.coverSize.height)
                    .overlay { LibraryFileAvailability(entry: entry, compact: true) }
            } actions: {
                RecentBookActions(model: model, entry: entry)
            }
        }
    }
}

/// The home preview and full collection share recent-book actions and labels.
struct RecentBookItem: View {
    let model: LibraryModel
    let entry: LibraryEntry
    let layout: LibraryLayout
    var fullPage = false
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .body) private var coverWidth = 96.0

    var body: some View {
        if layout == .list {
            RecentBookRow(model: model, entry: entry)
        } else {
            VStack(alignment: .leading, spacing: fullPage ? nil : 2) {
                VStack(alignment: .leading, spacing: fullPage ? nil : LayoutTokens.compact) {
                    Color.clear.aspectRatio(0.7, contentMode: .fit)
                    LibraryItemLabel(entry: entry, theme: theme).title().font(.subheadline.weight(.medium))
                        .lineLimit(2, reservesSpace: !fullPage)
                }.fixedSize(horizontal: false, vertical: true)
                if fullPage {
                    LibraryGridStatus(status: Self.progress(entry), showsMenu: true)
                } else {
                    Self.progress(entry).font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                }
            }
            .frame(width: fullPage ? nil : coverWidth)
            .frame(maxWidth: fullPage ? .infinity : nil, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .background {
                LibraryCoverButton(entry: entry, detail: Self.progress(entry)) {
                    model.open(entry)
                } cover: {
                    LibraryItemLabel(entry: entry, theme: theme).cover(compact: false)
                        .aspectRatio(0.7, contentMode: .fit)
                        .overlay { LibraryFileAvailability(entry: entry) }
                } actions: {
                    actions
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if fullPage {
                    LibraryItemMore(entry: entry) { actions }
                        .padding(.bottom, LibraryCollectionSection.gridFooterSpacing)
                }
            }
        }
    }

    private var actions: some View { RecentBookActions(model: model, entry: entry) }

    static func chapter(_ entry: LibraryEntry) -> Text {
        Text(entry.chapterTitle ?? String(localized: "继续阅读"))
    }

    static func progress(_ entry: LibraryEntry) -> Text {
        Text(ReadingProgress.fraction(entry.positionUtf8, of: entry.byteCount), format: .percent.precision(.fractionLength(1)))
            .monospacedDigit()
    }
}
