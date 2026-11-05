import TipKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryManagementView: View {
    @Bindable var model: LibraryModel
    @Environment(\.theme) private var theme
    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { model.fullIndex.automatic }, set: { model.fullIndex.automatic = $0 })) { Text("新加入的书自动建立索引", tableName: "FullIndex") }.accessibilityIdentifier("automaticFullIndex")
            } header: { Text("索引", tableName: "FullIndex") }
                .listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            ShelfReferenceHints(model: model, grouped: true)
            Section {
                ForEach(model.shelves, id: \.id) { shelf in
                    Group {
                        if shelf.error != nil {
                            VStack(alignment: .leading, spacing: 12) {
                                ManagedShelfRow(shelf: shelf)
                                Button("重新连接") { model.chooseFiles(.folder(shelf.id)) }
                                    .buttonStyle(ThemedSecondaryButtonStyle()).disabled(!model.canAcceptFileWork)
                                    .accessibilityIdentifier("reconnectShelf-" + shelf.id)
                            }
                        } else {
                            NavigationLink(value: LibraryRoute.folder(LibraryLocation(shelfID: shelf.id))) {
                                ManagedShelfRow(shelf: shelf)
                            }
                        }
                    }.accessibilityIdentifier("shelf-\(shelf.id)")
                    .modifier(LibraryShelfDropTarget(model: model, shelf: shelf))
                    .contextMenu { ShelfMenu(model: model, shelf: shelf) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !shelf.builtin {
                            // Confirm before removing; a destructive swipe role
                            // would animate the row away before confirmation.
                            Button("移除", systemImage: "minus.circle") { model.removingShelf = shelf }
                                .tint(Color(uiColor: theme.destructive))
                                .accessibilityLabel("移除书架")
                                .accessibilityIdentifier("removeShelf-\(shelf.id)")
                        }
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: LayoutTokens.compact, leading: LayoutTokens.content,
                                     bottom: LayoutTokens.compact, trailing: LayoutTokens.content))
            .listRowBackground(Color(uiColor: theme.surface))
            .listRowSeparatorTint(Color(uiColor: theme.separator))
        }
        .listStyle(.insetGrouped).themedPage()
        .contentMargins(.top, LayoutTokens.content, for: .scrollContent)
        .refreshable { await model.refresh(showIndicator: false, userInitiated: true) }
        .navigationTitle("书架管理").navigationBarTitleDisplayMode(.inline)
        .modifier(PageLoadingOverlay(request: model.processingFiles || model.nativeRefreshing ? nil : model.loading.request ?? model.refreshing.request ?? model.shelfScans.values.first ?? model.summaries.request,
                                     hasContent: !model.shelves.isEmpty, label: "正在加载书架", immediate: model.explicitRefresh))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加书架", systemImage: "plus") { model.chooseFiles(.folder(nil)) }
                    .labelStyle(.iconOnly).toolbarGlyph().accessibilityIdentifier("addLibraryShelf")
            }
        }
    }
}

private struct ManagedShelfRow: View {
    let shelf: LibraryShelf
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .body) private var iconSize = 24.0

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(shelf.builtin ? String(localized: "我的书架") : shelf.name)
                    .font(.body).foregroundStyle(Color(uiColor: theme.ink))
                if shelf.error != nil {
                    Text("需要重新连接").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive))
                } else {
                    Text("\(shelf.bookCount) 本 · \(shelf.location == "icloud" ? "iCloud Drive" : shelf.builtin ? String(localized: "本机") : String(localized: "文件夹"))")
                        .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                }
            }
        } icon: {
            Group {
                Image(systemName: shelf.builtin ? "books.vertical" : "folder").resizable().scaledToFit()
                    .foregroundStyle(Color(uiColor: theme.accent))
            }.frame(width: iconSize, height: iconSize).accessibilityHidden(true)
        }
    }
}

struct ShelfMenu: View {
    let model: LibraryModel
    let shelf: LibraryShelf
    var body: some View {
        Group {
            Button { Task { await model.openShelfIndex(shelf.id) } } label: { Text("建立索引", tableName: "FullIndex") }
            Button("刷新", systemImage: "arrow.clockwise") { Task { await model.refresh(userInitiated: true) } }
            if !shelf.builtin {
                Button("重新连接", systemImage: "folder.badge.questionmark") { model.chooseFiles(.folder(shelf.id)) }
                Button("移除书架", systemImage: "minus.circle", role: .destructive) { model.removingShelf = shelf }
            }
        }.disabled(!model.canAcceptFileWork)
    }
}
