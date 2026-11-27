import MoonreadData
import MoonreadAI
import MoonreadLibrary
import MoonreadDesign
import MoonreadDataTypes
import MoonreadCoreBindings
import SwiftUI
import UniformTypeIdentifiers

enum LibraryFilePicker {
    case folder(String?), novels(LibraryLocation), reauthorize(ShelfReference, scope: String)
    var types: [UTType] { if case .novels = self { [.plainText] } else { [.folder] } }
    var multiple: Bool { if case .novels = self { true } else { false } }
}

enum LibrarySheet: Identifiable {
    case rename(LibraryEntry), create(LibraryLocation)
    case move([LibraryEntry]), export(ShareFiles), share(ShareFiles), importResults
    case fullIndex(String)
    var id: String {
        switch self {
        case .rename(let entry): "rename-" + entry.id
        case .create(let location): "create-" + location.id
        case .move: "move"
        case .export: "export"
        case .share: "share"
        case .fullIndex(let shelf): "full-index-" + shelf
        case .importResults: "import-results"
        }
    }
}

struct LibraryPresentations: ViewModifier {
    @Environment(AIHost.self) private var ai
    @Bindable var model: LibraryModel
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View {
        @Bindable var shell = model.shell
        content
            .fileImporter(isPresented: $model.filePickerPresented,
                          allowedContentTypes: model.filePicker?.types ?? [.plainText],
                          allowsMultipleSelection: model.filePicker?.multiple ?? false,
                          onCompletion: model.completeFilePicker,
                          onCancellation: model.cancelFilePicker)
            .sheet(item: $shell.aiRequest) { request in
                AIEntry { AIQuickTaskSheet(request: request).themeScope(theme) }
            }
            .onChange(of: ai.availability.isAvailable) { _, available in if !available { model.shell.aiRequest = nil } }
            .sheet(item: $model.sheet, onDismiss: model.sheetDidDismiss) { sheet in
                switch sheet {
                case .rename(let entry): nameEditor(entry: entry, location: entry.parent).themeScope(theme)
                case .create(let location): nameEditor(entry: nil, location: location).themeScope(theme)
                case .move(let entries): NavigationStack { moveDestination(entries) }.themeScope(theme)
                case .export(let files): LibraryExportPicker(files: files)
                case .share(let files): ShareSheet(files: files)
                case .fullIndex(let shelf): HostedFullIndexView(shelfID: shelf) { id in
                    model.runAfterSheetDismiss { model.openIndexFailure(id) }
                }.themeScope(theme)
                case .importResults:
                    LibraryImportResultsView(failures: model.importFailures, result: model.sharedImportResult,
                                             retry: { failure in model.runAfterSheetDismiss { model.retryImport(failure) } },
                                             close: { model.sheet = nil }).themeScope(theme)
                }
            }
            .onChange(of: model.shell.path) { _, _ in model.showDeferredIndexPrompt() }
            .alert("暂时无法完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("知道了", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
            .background(LibraryDecisionAlert(decision: model.pendingDecision, indexPrompt: model.indexPrompt, theme: theme,
                                              resolveDecision: { await model.resolveDecision($0, accepting: $1) },
                                              resolveIndex: { model.resolveIndexPrompt(start: $0) }).frame(width: 0, height: 0))
            .alert("移除书架？", isPresented: Binding(get: { model.removingShelf != nil }, set: { if !$0 { model.removingShelf = nil } }), presenting: model.removingShelf) { shelf in
                Button("移除书架", role: .destructive) { model.removingShelf = nil; model.removeShelf(shelf) }
                Button("取消", role: .cancel) { model.removingShelf = nil }
            } message: { shelf in Text("移除“\(shelf.name)”的入口，目录中的文件仍然保留。") }
    }

    private func nameEditor(entry: LibraryEntry?, location: LibraryLocation) -> some View {
        LibraryNameEditor(entry: entry, location: location, canWrite: model.canAcceptFileWork) { command in
            model.runAfterSheetDismiss { model.runBatch([command]) }
        }
    }

    private func moveDestination(_ entries: [LibraryEntry]) -> some View {
        LibraryMoveDestination(shelves: model.shelves, entries: entries, canWrite: model.canAcceptFileWork,
                               actions: .init(title: model.shelfTitle, load: { location in
                                   try await AppDataService.libraryTestLatency()
                                   return try await AppDataService.shared.fixedFolderDestinations(location)
                               }, cancel: { model.sheet = nil }, fail: { model.error = ReaderMessages.error($0) },
                               move: { commands in model.runAfterSheetDismiss { model.runBatch(commands) } }))
    }
}

struct LibraryItemMenu: View {
    @Environment(AIHost.self) private var ai
    let model: LibraryModel
    let entry: LibraryEntry
    let host: LibraryBrowsingHost
    let showsLocation: Bool
    @ViewBuilder var body: some View {
        Group {
            Button("重命名", systemImage: "pencil") { model.sheet = .rename(entry) }
            Button("移动", systemImage: "folder") { model.sheet = .move([entry]) }
            if !entry.directory {
                Button("小说详情", systemImage: "info.circle") {
                    host.navigate(.statistics(StatisticsRoute(target: .file(fileId: entry.id), title: entry.title)), in: model)
                }
                if ai.availability.isAvailable {
                    Button("完善资料", systemImage: "sparkles") { model.shell.aiRequest = .library([entry], family: .metadata) }
                }
                if entry.shelfId != "builtin" { Button("复制到我的书架", systemImage: "doc.on.doc") { model.runBatch([.copy(entry)]) } }
                Button("导出", systemImage: "square.and.arrow.up") { model.export([entry], sharing: false) }
                Button("分享", systemImage: "square.and.arrow.up.on.square") { model.export([entry], sharing: true) }
            }
            Divider()
            Button("删除", systemImage: "trash", role: .destructive) { model.deleteEntries([entry]) }
        }.disabled(!model.canAcceptFileWork)
        if showsLocation {
            Button("所在文件夹", systemImage: "folder") { host.navigate(.folder(entry.parent), in: model) }
                .accessibilityIdentifier("library-result-path")
        }
    }
}
