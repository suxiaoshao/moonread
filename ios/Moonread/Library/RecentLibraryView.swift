import TipKit
import SwiftUI
import UniformTypeIdentifiers

struct RecentLibraryView: View {
    @Bindable var model: LibraryModel
    @State private var loading = LoadingState()
    @State private var entries: [LibraryEntry] = []
    var body: some View {
        List(entries, id: \.id) { entry in
            RecentBookRow(model: model, entry: entry)
                .contextMenu {
                    Button("小说详情", systemImage: "info.circle") { model.path.append(.statistics(StatisticsRoute(key: entry.readingKey, bookID: entry.bookId, title: entry.title, fileID: entry.id))) }
                    Button("从最近移除", systemImage: "minus.circle") { Task { await model.hideRecent(entry); await loadEntries() } }
                }.listRowBackground(Color.clear)
        }.listStyle(.plain).themedPage().navigationTitle("最近阅读")
            .refreshable { await model.refresh(showIndicator: false, userInitiated: true); await loadEntries() }
            .modifier(PageLoadingOverlay(request: loading.request, hasContent: !entries.isEmpty, label: "正在加载"))
            .task { let request = loading.begin(); defer { loading.finish(request) }; await loadEntries() }
            .onChange(of: model.recents) { _, recents in updateEntries(recents) }
    }
    private func updateEntries(_ recents: [LibraryEntry]) {
        let updates = Dictionary(uniqueKeysWithValues: recents.map { ($0.id, $0) })
        var next = entries.map { updates[$0.id] ?? $0 }
        next.sort { a, b in a.lastRead == b.lastRead ? a.id < b.id : a.lastRead > b.lastRead }
        if next != entries { entries = next }
    }
    private func loadEntries() async {
        do { let next = try await AppDataService.shared.recentLibrary(); if next != entries { entries = next } }
        catch { model.error = ReaderMessages.error(error) }
    }
}
