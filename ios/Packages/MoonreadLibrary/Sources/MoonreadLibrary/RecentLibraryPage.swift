import MoonreadData
import MoonreadDesign
import SwiftUI

public struct RecentLibraryPage<Collection: View>: View {
    let store: RecentReadingStore
    let refresh: () async -> Void
    let collection: ([LibraryCollectionSection], Bool, @escaping () async -> Void) -> Collection
    @Binding var layout: LibraryLayout

    public init(store: RecentReadingStore, layout: Binding<LibraryLayout>, refresh: @escaping () async -> Void,
                @ViewBuilder collection: @escaping ([LibraryCollectionSection], Bool, @escaping () async -> Void) -> Collection) {
        self.store = store; self._layout = layout; self.refresh = refresh; self.collection = collection
    }
    @State private var recentUse: RecentReadingUse?
    private var entries: [RecentReadingRead.Card] { store.value?.recentReading ?? [] }

    public var body: some View {
        collection([.init(id: .recent, content: .files(entries.compactMap { try? $0.libraryEntry() }, .recent))],
                   store.failure != nil, refresh)
        .themedPage()
        .navigationTitle("最近阅读")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LibraryDisplayMenu(selection: $layout)
            }
        }
        .overlay {
            if store.value == nil, store.failure == nil {
                ProgressView("正在加载")
            }
        }
        .safeAreaInset(edge: .top) {
            if let error = store.failure {
                RecentReadingRetry(message: error) { store.retry() }
            }
        }
        .task {
            if recentUse == nil { recentUse = store.use(limit: RecentReadingStore.fullLimit) }
        }
    }
}

/// The last successful snapshot stays visible when its observation fails.
public struct RecentReadingRetry: View {
    let message: String
    let retry: () -> Void
    public init(message: String, retry: @escaping () -> Void) { self.message = message; self.retry = retry }
    @Environment(\.theme) private var theme

    public var body: some View {
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
