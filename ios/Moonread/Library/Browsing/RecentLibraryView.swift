import TipKit
import SwiftUI
import UniformTypeIdentifiers

struct RecentLibraryView: View {
    @Bindable var model: LibraryModel
    @State private var loading = LoadingState()
    @State private var entries: [LibraryEntry] = []
    @State private var metadataRevision: UInt64 = 0
    var body: some View {
        List(entries, id: \.id) { entry in
            RecentBookRow(model: model, entry: entry)
                .contextMenu {
                    Button("小说详情", systemImage: "info.circle") { model.path.append(.statistics(StatisticsRoute(target: .file(fileId: entry.id), title: entry.title))) }
                    Button("从最近移除", systemImage: "minus.circle") { Task { await model.hideRecent(entry); await loadEntries() } }
                }.listRowBackground(Color.clear)
        }.listStyle(.plain).themedPage().navigationTitle("最近阅读")
            .refreshable { await model.refresh(showIndicator: false, userInitiated: true); await loadEntries() }
            .modifier(PageLoadingOverlay(request: loading.request, hasContent: !entries.isEmpty, label: "正在加载"))
            .onReceive(NotificationCenter.default.publisher(for: .bookMetadataChanged).receive(on: DispatchQueue.main)) { change in
                if change.affectsLibraryMetadata(.card, keys: loading.active ? nil : entries.displayedMetadataKeys) {
                    metadataRevision &+= 1
                }
            }
            .task(id: [model.readingInputRevision, metadataRevision]) {
                let request = loading.begin(); defer { loading.finish(request) }
                await loadEntries()
            }
    }
    private func loadEntries() async {
        do {
            let next = try await model.service.recentLibrary()
            try Task.checkCancellation()
            if next != entries { entries = next }
        } catch is CancellationError { }
        catch { model.error = ReaderMessages.error(error) }
    }
}
