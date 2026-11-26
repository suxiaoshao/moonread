import MoonreadLibrary
import MoonreadDesign
import MoonreadDataTypes
import MoonreadCoreBindings
import TipKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryManagementView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        LibraryManagementPage(
            automaticIndex: Binding(get: { model.fullIndex.automatic }, set: { model.fullIndex.automatic = $0 }),
            shelves: model.shelves, references: model.shelfRecovery.references,
            loading: loadingRequest, immediate: model.explicitRefresh, processingFiles: model.processingFiles,
            refresh: { await model.refresh(showIndicator: false, userInitiated: true) },
            add: { model.chooseFiles(.folder(nil)) }, remove: { model.removingShelf = $0 },
            open: { model.shell.path.append(.folder(LibraryLocation(shelfID: $0.id))) }
        ) { reference in
            ShelfReferenceRow(model: model, reference: reference)
        } shelfRow: { shelf, row in
            VStack(alignment: .leading, spacing: 12) {
                row
                if shelf.error != nil {
                    Button("重新连接") { model.chooseFiles(.folder(shelf.id)) }
                        .buttonStyle(ThemedSecondaryButtonStyle()).disabled(!model.canAcceptFileWork)
                        .accessibilityIdentifier("reconnectShelf-" + shelf.id)
                }
            }
            .modifier(LibraryShelfDropTarget(model: model, shelf: shelf))
            .contextMenu { ShelfMenu(model: model, shelf: shelf) }
        }
    }

    private var loadingRequest: UUID? {
        model.processingFiles || model.nativeRefreshing
            ? nil : model.loading.request ?? model.refreshing.request ?? model.shelfScans.values.first ?? model.summaries.request
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
