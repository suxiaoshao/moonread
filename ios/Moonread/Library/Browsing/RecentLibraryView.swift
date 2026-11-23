import SwiftUI

struct RecentLibraryView: View {
    @Bindable var model: LibraryModel
    @State private var recentUse: RecentReadingUse?
    private var entries: [RecentReadingRead.Card] { model.recentReading.value?.recentReading ?? [] }

    var body: some View {
        LibraryCollection(model: model, host: .main, sections: [
            .init(id: .recent, content: .files(entries.compactMap { try? $0.libraryEntry() }, .recent))
        ], onRefresh: {
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
    let inFullList: Bool
    @Environment(\.theme) private var theme
    var body: some View {
        Button { model.open(entry) } label: {
            HStack(spacing: inFullList ? 12 : 15) {
                LibraryItemLabel(entry: entry, theme: theme).cover(compact: true).frame(width: 44, height: 62)
                VStack(alignment: .leading, spacing: inFullList ? 4 : 7) {
                    LibraryItemLabel(entry: entry, theme: theme).title().font(.body.weight(.medium)).lineLimit(1)
                    HStack(spacing: inFullList ? 8 : nil) {
                        if inFullList {
                            chapter.frame(maxWidth: .infinity, alignment: .leading)
                            progress.fixedSize()
                        } else {
                            chapter
                            Spacer(minLength: 8)
                            progress
                        }
                    }.font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                }
            }.padding(.vertical, inFullList ? 0 : 6)
                .frame(maxWidth: inFullList ? .infinity : nil, alignment: .leading)
                .contentShape(.rect)
        }.buttonStyle(.plain).accessibilityIdentifier("library-file-\(entry.name)")
            .overlay(alignment: .leading) {
                LibraryFileAvailability(entry: entry, compact: true).frame(width: 44, height: 62)
            }
    }
    private var chapter: some View {
        Text(entry.chapterTitle ?? String(localized: "继续阅读")).lineLimit(1)
    }
    private var progress: Text {
        RecentBookItem.progress(entry)
    }
}


/// The home preview and full collection share recent-book actions and labels.
struct RecentBookItem: View {
    static let listTextLeading: CGFloat = 44 + LayoutTokens.control
    let model: LibraryModel
    let entry: LibraryEntry
    let layout: LibraryLayout
    var fullPage = false
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .body) private var coverWidth = 96.0

    var body: some View {
        if layout == .list {
            HStack(spacing: 0) {
                RecentBookRow(model: model, entry: entry, inFullList: fullPage)
                if fullPage { LibraryItemMore(entry: entry) { actions } }
            }.contextMenu { actions }
        } else if fullPage {
            VStack(alignment: .leading, spacing: 0) {
                Button { model.open(entry) } label: { coverAndTitle }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library-file-\(entry.name)")
                    .accessibilityLabel(Text(verbatim: entry.title))
                    .accessibilityValue(Self.progress(entry))
                    .overlay(alignment: .top) { availability }
                HStack(spacing: 0) {
                    Self.progress(entry).font(.caption).lineLimit(1).accessibilityHidden(true)
                    Spacer(minLength: 0)
                    LibraryItemMore(entry: entry) { actions }
                }.foregroundStyle(Color(uiColor: theme.secondary))
            }.contextMenu { actions }
        } else {
            Menu { actions } label: {
                VStack(alignment: .leading, spacing: 2) {
                    coverAndTitle
                    Self.progress(entry).font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                }.frame(width: coverWidth).contentShape(.rect)
            } primaryAction: { model.open(entry) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library-file-\(entry.name)")
                .overlay(alignment: .top) { availability }
        }
    }

    private var coverAndTitle: some View {
        let label = LibraryItemLabel(entry: entry, theme: theme)
        return VStack(alignment: .leading, spacing: LayoutTokens.compact) {
            label.cover(compact: false).aspectRatio(0.7, contentMode: .fit)
            label.title().font(.subheadline.weight(.medium)).lineLimit(2, reservesSpace: true)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
    }

    private var availability: some View {
        LibraryFileAvailability(entry: entry).aspectRatio(0.7, contentMode: .fit)
    }

    private var actions: some View { RecentBookActions(model: model, entry: entry) }

    fileprivate static func progress(_ entry: LibraryEntry) -> Text {
        Text(ReadingProgress.fraction(entry.positionUtf8, of: entry.byteCount), format: .percent.precision(.fractionLength(1)))
            .monospacedDigit()
    }
}
