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
    private static let coverSize = CGSize(width: 44, height: 62)
    @Environment(\.theme) private var theme
    var body: some View {
        Button { model.open(entry) } label: {
            HStack(spacing: 15) {
                LibraryItemLabel(entry: entry, theme: theme).cover(compact: true)
                    .frame(width: Self.coverSize.width, height: Self.coverSize.height)
                VStack(alignment: .leading, spacing: 7) {
                    LibraryItemLabel(entry: entry, theme: theme).title().font(.body.weight(.medium)).lineLimit(1)
                    HStack {
                        chapter
                        Spacer(minLength: 8)
                        progress
                    }.font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                }
            }.padding(.vertical, 6)
                .contentShape(.rect)
        }.buttonStyle(.plain).accessibilityIdentifier("library-file-\(entry.name)")
            .overlay(alignment: .leading) {
                LibraryFileAvailability(entry: entry, compact: true)
                    .frame(width: Self.coverSize.width, height: Self.coverSize.height)
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
    let model: LibraryModel
    let entry: LibraryEntry
    let layout: LibraryLayout
    var fullPage = false
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .body) private var coverWidth = 96.0

    var body: some View {
        if layout == .list {
            RecentBookRow(model: model, entry: entry).contextMenu { actions }
        } else if fullPage {
            VStack(alignment: .leading) {
                Button { model.open(entry) } label: { coverAndTitle }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library-file-\(entry.name)")
                    .accessibilityLabel(Text(verbatim: entry.title))
                    .accessibilityValue(Self.progress(entry))
                    .overlay(alignment: .top) { availability }
                    .fixedSize(horizontal: false, vertical: true)
                LibraryGridStatus(entry: entry, status: Self.progress(entry), showsMenu: true) { actions }
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
        return VStack(alignment: .leading, spacing: fullPage ? nil : LayoutTokens.compact) {
            label.cover(compact: false).aspectRatio(0.7, contentMode: .fit)
            if fullPage {
                label.title().font(.subheadline.weight(.medium)).lineLimit(2)
            } else {
                label.title().font(.subheadline.weight(.medium)).lineLimit(2, reservesSpace: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
    }

    private var availability: some View {
        LibraryFileAvailability(entry: entry).aspectRatio(0.7, contentMode: .fit)
    }

    private var actions: some View { RecentBookActions(model: model, entry: entry) }

    static func progress(_ entry: LibraryEntry) -> Text {
        Text(ReadingProgress.fraction(entry.positionUtf8, of: entry.byteCount), format: .percent.precision(.fractionLength(1)))
            .monospacedDigit()
    }
}
