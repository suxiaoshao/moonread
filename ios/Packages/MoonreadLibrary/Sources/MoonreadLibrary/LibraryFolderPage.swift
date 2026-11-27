import MoonreadCoreBindings
import MoonreadDataTypes
import MoonreadDesign
import SwiftUI

public enum LibraryFolderMenuAction {
    case index, create, receive, organizeFolder, catalogue, search
}

public enum LibraryFolderSelectionAction {
    case share, export, move, metadata, organize, delete
}


public struct LibraryFolderPage<Collection: View, Overview: View, EmptyFolder: View, MetadataExport: View>: View {
    public struct Status {
        let shelf: LibraryShelf?
        let title: String
        let canWrite: Bool
        let aiAvailable: Bool
        let discoveryGeneration: UUID?
        let discoveryRevision: Int?
        let adoptedDiscoveryRevision: Int?
        let discoveryUnavailable: Bool
        let scan: UUID?
        let refresh: UUID?
        let processingFiles: Bool
        let nativeRefreshing: Bool
        let explicitRefresh: Bool

        public init(shelf: LibraryShelf?, title: String, canWrite: Bool, aiAvailable: Bool,
                    discoveryGeneration: UUID?, discoveryRevision: Int?, adoptedDiscoveryRevision: Int?,
                    discoveryUnavailable: Bool, scan: UUID?, refresh: UUID?, processingFiles: Bool,
                    nativeRefreshing: Bool, explicitRefresh: Bool) {
            self.shelf = shelf; self.title = title; self.canWrite = canWrite; self.aiAvailable = aiAvailable
            self.discoveryGeneration = discoveryGeneration; self.discoveryRevision = discoveryRevision
            self.adoptedDiscoveryRevision = adoptedDiscoveryRevision; self.discoveryUnavailable = discoveryUnavailable
            self.scan = scan; self.refresh = refresh; self.processingFiles = processingFiles
            self.nativeRefreshing = nativeRefreshing; self.explicitRefresh = explicitRefresh
        }
    }

    public struct Actions {
        let menu: (LibraryFolderMenuAction) -> Void
        let selection: (LibraryFolderSelectionAction, [LibraryEntry]) -> Void
        let copy: ([LibraryEntry], @escaping (String) -> Void) -> Void
        let didLoad: (UUID, Int) -> Void
        let didFail: (Error, UUID?) -> Void
        let refresh: () async -> Void

        public init(menu: @escaping (LibraryFolderMenuAction) -> Void,
                    selection: @escaping (LibraryFolderSelectionAction, [LibraryEntry]) -> Void,
                    copy: @escaping ([LibraryEntry], @escaping (String) -> Void) -> Void,
                    didLoad: @escaping (UUID, Int) -> Void, didFail: @escaping (Error, UUID?) -> Void,
                    refresh: @escaping () async -> Void) {
            self.menu = menu; self.selection = selection; self.copy = copy
            self.didLoad = didLoad; self.didFail = didFail; self.refresh = refresh
        }
    }

    let location: LibraryLocation
    let status: Status
    let actions: Actions
    let collection: ([LibraryCollectionSection], LibraryCollectionFolder, @escaping () async -> Void) -> Collection
    let overview: () -> Overview
    let emptyFolder: () -> EmptyFolder
    let export: () -> MetadataExport
    @Binding var layout: LibraryLayout
    @State private var folder: FolderStore

    public init(location: LibraryLocation, layout: Binding<LibraryLayout>, status: Status, actions: Actions,
                folder: @autoclosure @escaping () -> FolderStore,
                @ViewBuilder collection: @escaping ([LibraryCollectionSection], LibraryCollectionFolder, @escaping () async -> Void) -> Collection,
                @ViewBuilder overview: @escaping () -> Overview, @ViewBuilder emptyFolder: @escaping () -> EmptyFolder,
                @ViewBuilder metadataExport: @escaping () -> MetadataExport) {
        self.location = location; self._layout = layout; self.status = status; self.actions = actions
        self._folder = State(initialValue: folder()); self.collection = collection
        self.overview = overview; self.emptyFolder = emptyFolder; self.export = metadataExport
    }

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
              discoveryGeneration: builtinRoot ? status.discoveryGeneration : nil,
              discoveryRevision: builtinRoot ? status.discoveryRevision : nil,
              adoptedRevision: builtinRoot ? status.adoptedDiscoveryRevision : nil)
    }
    private var shelf: LibraryShelf? { status.shelf }
    private var title: String { status.title }
    private var selectedEntries: [LibraryEntry] { entries.filter { selection.contains($0.id) } }
    private var allSelected: Bool { !entries.isEmpty && selection.count == entries.count }
    private var selectionTitle: String { String(localized: "已选 \(selection.count) 项") }
    private var fileActionsDisabled: Bool { !status.canWrite }
    private var canCopySelection: Bool {
        !selectedEntries.isEmpty && selectedEntries.allSatisfy { !$0.directory && $0.shelfId != "builtin" }
    }
    public var body: some View {
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
                        Button { actions.menu(.index) } label: { Label { Text("建立索引", tableName: "FullIndex") } icon: { Image(systemName: "text.badge.checkmark") } }.accessibilityIdentifier("buildShelfIndex")
                        Button("选择项目", systemImage: "checkmark.circle") { editing = .active }
                        Button("新建文件夹", systemImage: "folder.badge.plus") { actions.menu(.create) }
                        if location.shelfID == "builtin" { Button("导入小说", systemImage: "square.and.arrow.down") { actions.menu(.receive) } }
                        if status.aiAvailable {
                            Button("整理…", systemImage: "folder.badge.gearshape") { actions.menu(.organizeFolder) }
                                .accessibilityIdentifier("organizeFolder")
                        }
                        Divider()
                        LibraryDisplayPicker(selection: $layout)
                        Divider()
                        if !location.path.isEmpty {
                            Button("全部小说", systemImage: "books.vertical") {
                                actions.menu(.catalogue)
                            }
                        }
                        Button { metadataExporting = true } label: {
                            Label { Text("导出本书架信息", tableName: "MetadataExchange") } icon: { Image(systemName: "doc.text") }
                        }
                        Button("在此书架中搜索", systemImage: "magnifyingglass") {
                            actions.menu(.search)
                        }
                            .accessibilityIdentifier("searchShelf")
                    } label: { Label("文件夹操作", systemImage: "ellipsis") }.menuOrder(.fixed).toolbarGlyph().accessibilityIdentifier("folderActions").disabled(fileActionsDisabled)
                }
            }
            if editing.isEditing {
                ToolbarItemGroup(placement: .bottomBar) {
                    Menu {
                        Button("分享", systemImage: "square.and.arrow.up") {
                            actions.selection(.share, selectedEntries)
                        }
                        Button("导出", systemImage: "square.and.arrow.down") {
                            actions.selection(.export, selectedEntries)
                        }
                    } label: { Label("分享与导出", systemImage: "square.and.arrow.up") }
                        .disabled(selectedEntries.isEmpty || selectedEntries.contains(where: \.directory) || fileActionsDisabled)
                        .accessibilityIdentifier("libraryShareSelection")
                    if location.shelfID != "builtin" {
                        Button("复制到我的书架", systemImage: "doc.on.doc") {
                            actions.copy(selectedEntries) { id in selection.remove(id) }
                        }.disabled(!canCopySelection || fileActionsDisabled).accessibilityIdentifier("libraryCopySelection")
                    }
                    Button("移动", systemImage: "folder") { actions.selection(.move, selectedEntries) }
                        .disabled(selection.isEmpty || fileActionsDisabled)
                    if status.aiAvailable {
                        Menu {
                            Button("完善资料", systemImage: "sparkles") { actions.selection(.metadata, selectedEntries) }
                                .disabled(!selectedEntries.contains { !$0.directory })
                            Button("整理所选", systemImage: "folder.badge.gearshape") { actions.selection(.organize, selectedEntries) }
                                .disabled(!selectedEntries.contains { !$0.directory })
                        } label: { Label("AI 助手", systemImage: "sparkles") }
                            .disabled(selection.isEmpty || fileActionsDisabled).accessibilityIdentifier("libraryAISelection")
                    }
                    Button("删除", systemImage: "trash", role: .destructive) { actions.selection(.delete, selectedEntries) }
                        .disabled(selection.isEmpty || fileActionsDisabled)
                }
                ToolbarItem(placement: .bottomBar) { Spacer() }
            }
        }
        .modifier(LibraryFileActivity(active: status.processingFiles))
        .sheet(isPresented: $metadataExporting) {
            export()
        }
        .task(id: folderInput) {
            let input = folderInput
            await folder.observe(input.location) { value in
                guard input == folderInput else { return }
                selection.formIntersection(Set(value.map(\.id)))
                if let generation = input.discoveryGeneration, let revision = input.discoveryRevision {
                    actions.didLoad(generation, revision)
                }
            } didFail: { error in
                guard input == folderInput else { return }
                actions.didFail(error, input.discoveryGeneration)
            }
        }

        .modifier(PageLoadingOverlay(request: status.processingFiles || status.nativeRefreshing ? nil : status.scan ?? folder.loading.request ?? status.refresh,
                                     hasContent: !entries.isEmpty, label: "正在加载书架", immediate: status.explicitRefresh || status.scan != nil))
    }

    private var browser: some View {
        let showsEmpty = (folder.snapshot != nil || (builtinRoot && folder.failed))
            && !folder.loading.active && status.refresh == nil && status.scan == nil
            && entries.isEmpty && (shelf?.error == nil || (builtinRoot && status.discoveryUnavailable))
        var sections: [LibraryCollectionSection] = []
        if location.path.isEmpty || shelf?.error != nil {
            sections.append(.init(id: .folderOverview, content: .rows([.init("overview") {
                overview()
                    .disabled(editing.isEditing || fileActionsDisabled)
            }])))
        }
        // Keep an empty destination section for native drops.
        sections.append(.init(id: .folderEntries, content: .files(entries, .directory)))
        return collection(sections, .init(location: location, disabled: fileActionsDisabled,
                                               editing: $editing, selection: $selection,
                                               emptyView: showsEmpty ? AnyView(emptyFolder()) : nil),
                                 {
            folder.retryIfFailed()
            await actions.refresh()
        })
            // UIKit applies the tab/toolbar safe inset to the scroll content.
            // Let its viewport draw behind the bar, as native SwiftUI lists do.
            .ignoresSafeArea(.container, edges: .bottom)
            .themedPage()
    }
}

/// A catalogue of one real shelf, grouped by name or projected tags.
public struct LibrarySelectingFolders: PreferenceKey {
    public static var defaultValue: Set<LibraryLocation> { [] }
    public static func reduce(value: inout Set<LibraryLocation>, nextValue: () -> Set<LibraryLocation>) {
        value.formUnion(nextValue())
    }
}
