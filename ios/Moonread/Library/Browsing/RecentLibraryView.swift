import SwiftUI

struct RecentLibraryView: View {
    @Bindable var model: LibraryModel
    @State private var recentUse: RecentReadingUse?
    private var entries: [RecentReadingRead.Card] { model.recentReading.value?.recentReading ?? [] }

    @ScaledMetric(relativeTo: .body) private var minimumBookWidth = 96.0

    var body: some View {
        Group {
            if model.layout == .grid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumBookWidth), spacing: LayoutTokens.content)],
                              alignment: .leading, spacing: LayoutTokens.section) {
                        ForEach(entries, id: \.file.id) { card in
                            if let entry = try? card.libraryEntry() {
                                RecentCoverTile(model: model, entry: entry, fillsColumn: true) {
                                    RecentBookActions(model: model, entry: entry)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, LayoutTokens.page)
                    .padding(.vertical, LayoutTokens.compact)
                }
            } else {
                List(entries, id: \.file.id) { card in
                    if let entry = try? card.libraryEntry() {
                        RecentBookRow(model: model, entry: entry, inFullList: true)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 56 } // 44-point cover + 12-point gap
                            .contextMenu { RecentBookActions(model: model, entry: entry) }
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
            }
        }
        .themedPage()
        .navigationTitle("最近阅读")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LibraryDisplayMenu(selection: $model.layout)
            }
        }
        .refreshable { await model.refresh(showIndicator: false, userInitiated: true) }
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
