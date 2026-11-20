import TipKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryFolderView: View {
    @Bindable var model: LibraryModel
    let location: LibraryLocation
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @State private var folder = FolderStore(service: .shared)
    @State private var selection = Set<String>()
    @State private var editing = EditMode.inactive
    @State private var metadataExporting = false
    private struct FolderInput: Hashable {
        let location: LibraryLocation
        let requestRevision: Int
        let discoveryGeneration: UUID?
        let discoveryRevision: Int?
        let adoptedRevision: Int?
    }

    private var entries: [LibraryEntry] { folder.snapshot ?? [] }
    private var builtinRoot: Bool { location.shelfID == "builtin" && location.path.isEmpty }
    private var folderInput: FolderInput {
        .init(location: location, requestRevision: folder.requestRevision,
              discoveryGeneration: builtinRoot ? model.discoveryGeneration : nil,
              discoveryRevision: builtinRoot ? model.discoveryRevision : nil,
              adoptedRevision: builtinRoot ? model.adoptedDiscoveryRevision : nil)
    }
    private var shelf: LibraryShelf? { model.shelves.first { $0.id == location.shelfID } }
    private var title: String { location.path.isEmpty ? model.shelfTitle(location.shelfID) : URL(fileURLWithPath: location.path).lastPathComponent }
    private var selectedEntries: [LibraryEntry] { entries.filter { selection.contains($0.id) } }
    private var allSelected: Bool { !entries.isEmpty && selection.count == entries.count }
    private var selectionTitle: String { String(localized: "已选 \(selection.count) 项") }
    private var fileActionsDisabled: Bool { !model.canAcceptFileWork }
    private var canCopySelection: Bool {
        !selectedEntries.isEmpty && selectedEntries.allSatisfy { !$0.directory && $0.shelfId != "builtin" }
    }
    var body: some View {
        browser
        .navigationTitle(editing.isEditing ? selectionTitle : title).navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(editing.isEditing)
        // The source stack combines this page's selection with reader visibility.
        .preference(key: LibrarySelectingFolders.self, value: editing.isEditing ? [location] : [])
        .toolbar {
            if editing.isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    Button(allSelected ? LocalizedStringKey("取消全选") : LocalizedStringKey("全选")) {
                        selection = allSelected ? [] : Set(entries.map(\.id))
                    }
                    .disabled(entries.isEmpty || fileActionsDisabled)
                    .accessibilityIdentifier("librarySelectAll")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if editing.isEditing {
                    SystemToolbarButton("结束选择", role: .confirm) { editing = .inactive; selection = [] }
                        .accessibilityIdentifier("librarySelectionDone")
                        .disabled(fileActionsDisabled)
                }
                else {
                    Menu {
                        Button { Task { await model.openShelfIndex(location.shelfID) } } label: { Label { Text("建立索引", tableName: "FullIndex") } icon: { Image(systemName: "text.badge.checkmark") } }.accessibilityIdentifier("buildShelfIndex")
                        Button("选择项目", systemImage: "checkmark.circle") { editing = .active }
                        Button("新建文件夹", systemImage: "folder.badge.plus") { model.sheet = .create(location) }
                        if location.shelfID == "builtin" { Button("导入小说", systemImage: "square.and.arrow.down") { model.chooseFiles(.novels(location)) } }
                        if ai.availability.isAvailable {
                            Button("整理…", systemImage: "folder.badge.gearshape") { model.shell.aiRequest = .folder(location, title: title) }
                                .accessibilityIdentifier("organizeFolder")
                        }
                        Divider()
                        LibraryDisplayPicker(selection: $model.layout)
                        Divider()
                        if !location.path.isEmpty {
                            NavigationLink(value: LibraryRoute.allBooks(location.shelfID)) {
                                Label("全部小说", systemImage: "books.vertical")
                            }
                        }
                        Button { metadataExporting = true } label: {
                            Label { Text("导出本书架信息", tableName: "MetadataExchange") } icon: { Image(systemName: "doc.text") }
                        }
                        Button("在此书架中搜索", systemImage: "magnifyingglass") { model.shell.path.append(.search(AppSearchScope(seeds: [.shelf(location.shelfID)]))) }
                            .accessibilityIdentifier("searchShelf")
                    } label: { Label("文件夹操作", systemImage: "ellipsis") }.menuOrder(.fixed).toolbarGlyph().accessibilityIdentifier("folderActions").disabled(fileActionsDisabled)
                }
            }
            if editing.isEditing {
                ToolbarItemGroup(placement: .bottomBar) {
                    Menu {
                        Button("分享", systemImage: "square.and.arrow.up") {
                            model.export(selectedEntries, sharing: true)
                        }
                        Button("导出", systemImage: "square.and.arrow.down") {
                            model.export(selectedEntries, sharing: false)
                        }
                    } label: { Label("分享与导出", systemImage: "square.and.arrow.up") }
                        .disabled(selectedEntries.isEmpty || selectedEntries.contains(where: \.directory) || fileActionsDisabled)
                        .accessibilityIdentifier("libraryShareSelection")
                    if location.shelfID != "builtin" {
                        Button("复制到我的书架", systemImage: "doc.on.doc") {
                            model.runBatch(selectedEntries.map { .copy($0) }) { command in
                                if case let .copy(entry) = command { selection.remove(entry.id) }
                            }
                        }.disabled(!canCopySelection || fileActionsDisabled).accessibilityIdentifier("libraryCopySelection")
                    }
                    Button("移动", systemImage: "folder") { model.sheet = .move(selectedEntries) }
                        .disabled(selection.isEmpty || fileActionsDisabled)
                    if ai.availability.isAvailable {
                        Menu {
                            Button("完善资料", systemImage: "sparkles") { model.shell.aiRequest = .library(selectedEntries, family: .metadata) }
                                .disabled(!selectedEntries.contains { !$0.directory })
                            Button("整理所选", systemImage: "folder.badge.gearshape") { model.shell.aiRequest = .library(selectedEntries, family: .organization) }
                                .disabled(!selectedEntries.contains { !$0.directory })
                        } label: { Label("AI 助手", systemImage: "sparkles") }
                            .disabled(selection.isEmpty || fileActionsDisabled).accessibilityIdentifier("libraryAISelection")
                    }
                    Button("删除", systemImage: "trash", role: .destructive) { model.deleteEntries(selectedEntries) }
                        .disabled(selection.isEmpty || fileActionsDisabled)
                }
                ToolbarItem(placement: .bottomBar) { Spacer() }
            }
        }
        .sheet(isPresented: $metadataExporting) {
            MetadataExportView(task: MetadataExchangeModel.shared.exportTask, shelfID: location.shelfID,
                               shelfName: model.shelfTitle(location.shelfID)).presentationSizing(.page)
        }
        .task(id: folderInput) {
            let input = folderInput
            await folder.observe(input.location) { value in
                guard input == folderInput else { return }
                selection.formIntersection(Set(value.map(\.id)))
                if let generation = input.discoveryGeneration, let revision = input.discoveryRevision {
                    model.builtinDirectoryLoaded(generation: generation, snapshotRevision: revision)
                }
            } didFail: { error in
                guard input == folderInput else { return }
                if let generation = input.discoveryGeneration { model.failCloudDiscovery(generation) }
                model.error = ReaderMessages.error(error)
            }
        }

        .modifier(PageLoadingOverlay(request: model.processingFiles || model.nativeRefreshing ? nil : model.shelfScans[location.shelfID] ?? folder.loading.request ?? model.refreshing.request,
                                     hasContent: !entries.isEmpty, label: "正在加载书架", immediate: model.explicitRefresh || model.shelfScans[location.shelfID] != nil))
    }

    private var browser: some View {
        LibraryCollection(ai: ai, model: model, location: location, entries: entries, shelf: shelf,
                          layout: model.layout, theme: theme, disabled: fileActionsDisabled,
                          retryObservation: folder.retryIfFailed,
                          showsEmpty: (folder.snapshot != nil || (builtinRoot && folder.failed)) && !folder.loading.active && !model.refreshing.active && model.shelfScans[location.shelfID] == nil && entries.isEmpty && (shelf?.error == nil || (location.shelfID == "builtin" && location.path.isEmpty && model.builtinDiscovery == .unavailable)),
                          editing: $editing, selection: $selection)
            // UIKit applies the tab/toolbar safe inset to the scroll content.
            // Let its viewport draw behind the bar, as native SwiftUI lists do.
            .ignoresSafeArea(.container, edges: .bottom)
            .themedPage()
    }
}

/// A catalogue of one real shelf, grouped by name or projected tags.
struct LibrarySelectingFolders: PreferenceKey {
    static var defaultValue: Set<LibraryLocation> { [] }
    static func reduce(value: inout Set<LibraryLocation>, nextValue: () -> Set<LibraryLocation>) {
        value.formUnion(nextValue())
    }
}
