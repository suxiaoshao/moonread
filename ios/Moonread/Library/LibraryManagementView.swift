import TipKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryManagementView: View {
    @Bindable var model: LibraryModel
    @Environment(\.theme) private var theme
    var body: some View {
        ThemedGroupedList(sections: managementSections, theme: theme,
                          topInset: LayoutTokens.content,
                          refresh: { await model.refresh(showIndicator: false, userInitiated: true) })
        .themedPage()
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
    private var managementSections: [ThemedGroupedList.Section] {
        var result: [ThemedGroupedList.Section] = [
            .init(id: "index", title: String(localized: "索引", table: "FullIndex"), rows: [
                .init("automaticFullIndex") {
                    Toggle(isOn: Binding(get: { model.fullIndex.automatic }, set: { model.fullIndex.automatic = $0 })) {
                        Text("新加入的书自动建立索引", tableName: "FullIndex")
                    }.accessibilityIdentifier("automaticFullIndex")
                }
            ])
        ]
        if !model.shelfRecovery.references.isEmpty {
            result.append(.init(id: "references", title: String(localized: "你之前添加过这些书架", table: "ShelfRecovery"),
                                footer: String(localized: "重新选择原来的文件夹，即可恢复对此书架的访问。"),
                                rows: model.shelfRecovery.references.map { reference in
                .init("reference-" + reference.id) {
                    ShelfReferenceRow(model: model, reference: reference)
                }
            }))
        }
        result.append(.init(id: "shelves", rows: model.shelves.map { shelf in
            let actions: [ThemedGroupedList.Action] = shelf.builtin ? [] : [
                .init(title: String(localized: "移除"), symbol: "minus.circle", destructive: true,
                      perform: { model.removingShelf = shelf })
            ]
            return .init("shelf-" + shelf.id,
                         action: shelf.error == nil ? { model.path.append(.folder(LibraryLocation(shelfID: shelf.id))) } : nil,
                         disclosure: shelf.error == nil, actions: actions, allowsFullSwipe: false) {
                VStack(alignment: .leading, spacing: 12) {
                    ManagedShelfRow(shelf: shelf)
                    if shelf.error != nil {
                        Button("重新连接") { model.chooseFiles(.folder(shelf.id)) }
                            .buttonStyle(ThemedSecondaryButtonStyle()).disabled(!model.canAcceptFileWork)
                            .accessibilityIdentifier("reconnectShelf-" + shelf.id)
                    }
                }
                .modifier(LibraryShelfDropTarget(model: model, shelf: shelf))
                .contextMenu { ShelfMenu(model: model, shelf: shelf) }
            }
        }))
        return result
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
