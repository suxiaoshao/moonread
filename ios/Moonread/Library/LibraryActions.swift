import SwiftUI
import UniformTypeIdentifiers

enum LibraryCommand {
    case rename(LibraryEntry, String), move(LibraryEntry, LibraryLocation), copy(LibraryEntry)
    case create(LibraryLocation, String), delete(LibraryEntry), receive(LibraryImportFile, LibraryLocation)
    var filename: String {
        switch self {
        case .rename(_, let name), .create(_, let name): name
        case .move(let entry, _), .copy(let entry), .delete(let entry): entry.name
        case .receive(let file, _): file.url.lastPathComponent
        }
    }
}

enum LibraryPendingDecision: Identifiable {
    case replacement(LibraryCommand, id: UUID = UUID())
    case trashUnsupported(LibraryEntry, id: UUID = UUID())
    var id: UUID {
        switch self { case .replacement(_, let id), .trashUnsupported(_, let id): id }
    }
}

enum LibraryTrashChoice { case permanentlyDelete, skip }

enum LibraryFilePicker {
    case folder(String?), novels(LibraryLocation)
    var types: [UTType] { if case .folder = self { [.folder] } else { [.plainText] } }
    var multiple: Bool { if case .novels = self { true } else { false } }
}

enum LibrarySheet: Identifiable {
    case rename(LibraryEntry), create(LibraryLocation)
    case move([LibraryEntry]), export(LibraryExport), share(LibraryExport), importResults
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

struct ImportFailure: Identifiable {
    let id = UUID()
    let file: LibraryImportFile
    var url: URL { file.url }
    let location: LibraryLocation
    let message: String
    let completion: LibraryImportCompletion
}

struct LibraryPresentations: ViewModifier {
    @Environment(AIService.self) private var ai
    @Bindable var model: LibraryModel
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $model.filePickerPresented,
                          allowedContentTypes: model.filePicker?.types ?? [.plainText],
                          allowsMultipleSelection: model.filePicker?.multiple ?? false,
                          onCompletion: model.completeFilePicker,
                          onCancellation: model.cancelFilePicker)
            .sheet(item: $model.aiRequest) { if ai.availability.isAvailable { AIQuickTaskSheet(request: $0).themeScope(theme) } }
            .onChange(of: ai.availability.isAvailable) { _, available in if !available { model.aiRequest = nil } }
            .sheet(item: $model.sheet, onDismiss: model.sheetDidDismiss) { sheet in
                switch sheet {
                case .rename(let entry): LibraryNameEditor(model: model, entry: entry, location: entry.parent).themeScope(theme)
                case .create(let location): LibraryNameEditor(model: model, entry: nil, location: location).themeScope(theme)
                case .move(let entries): NavigationStack { LibraryMoveDestination(model: model, entries: entries, location: nil) }.themeScope(theme)
                case .export(let files): LibraryExportPicker(files: files)
                case .share(let files): LibraryShareSheet(files: files)
                case .fullIndex(let shelf): FullIndexView(shelfID: shelf) { id in
                    model.runAfterSheetDismiss { model.openIndexFailure(id) }
                }.themeScope(theme)
                case .importResults:
                    NavigationStack {
                        List {
                            if let result = model.sharedImportResult {
                                Text(verbatim: result).listRowBackground(Color(uiColor: theme.surface))
                            }
                            ForEach(model.importFailures) { failure in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(verbatim: failure.url.lastPathComponent).font(.headline)
                                    Text(verbatim: failure.message).font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                                    Button("重试", systemImage: "arrow.clockwise") {
                                        model.runAfterSheetDismiss { model.retryImport(failure) }
                                    }
                                }.listRowBackground(Color(uiColor: theme.surface))
                            }
                        }.themedPage().navigationTitle(model.sharedImportResult == nil ? String(localized: "未完成的导入") : String(localized: "导入结果", table: "ShareReceive"))
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成", systemImage: "checkmark") { model.sheet = nil }.labelStyle(.titleOnly) } }
                    }.themeScope(theme)
                }
            }
            .onChange(of: model.path) { _, _ in model.showDeferredIndexPrompt() }
            .alert("暂时无法完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("知道了", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
            .background(LibraryDecisionAlert(model: model, decision: model.pendingDecision, indexPrompt: model.indexPrompt, theme: theme).frame(width: 0, height: 0))
            .confirmationDialog("移到最近删除？", isPresented: Binding(get: { model.deletion != nil }, set: { if !$0 { model.deletion = nil } }), titleVisibility: .visible, presenting: model.deletion) { entries in
                Button("移到最近删除", role: .destructive) {
                    model.deletion = nil; model.runBatch(entries.map { .delete($0) })
                }
                Button("取消", role: .cancel) { model.deletion = nil }
            } message: { _ in Text("可在‘文件’App 的‘最近删除’中恢复。书签和笔记会保留。") }
            .confirmationDialog("移除书架？", isPresented: Binding(get: { model.removingShelf != nil }, set: { if !$0 { model.removingShelf = nil } }), presenting: model.removingShelf) { shelf in
                Button("移除书架", role: .destructive) { model.removingShelf = nil; model.removeShelf(shelf) }
                Button("取消", role: .cancel) { model.removingShelf = nil }
            } message: { shelf in Text("移除“\(shelf.name)”的入口，目录中的文件仍然保留。") }
            .overlay {
                if model.processingFiles && model.path.last?.isReader != true {
                    DeferredLoading(delay: model.explicitFileWork ? .zero : LoadingTiming.inlineDelay) { _ in
                        LoadingActivity(size: 32, waitingLabel: "正在处理文件", delay: .zero).padding(24)
                            .background(theme.floatingBackground(), in: .rect(cornerRadius: 20))
                            .accessibilityLabel("正在处理文件")
                    }
                }
            }
    }
}

/// UIKit owns dismissal so two consecutive decisions cannot coalesce into one
/// SwiftUI alert. Queue advancement always runs after the previous alert closes.
struct LibraryDecisionAlert: UIViewControllerRepresentable {
    let model: LibraryModel
    let decision: LibraryPendingDecision?
    var indexPrompt: IdentityInventory? = nil
    let theme: ThemeSurface
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.model = model; controller.decision = decision; controller.indexPrompt = indexPrompt
        controller.view.tintColor = theme.accent; controller.overrideUserInterfaceStyle = theme.style
        controller.presentIfNeeded()
    }
    final class Controller: UIViewController {
        var model: LibraryModel?
        var decision: LibraryPendingDecision?
        var indexPrompt: IdentityInventory?
        private weak var alert: UIAlertController?
        private var resolving = false
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); presentIfNeeded() }
        func presentIfNeeded() {
            guard isViewLoaded, view.window != nil, alert == nil, !resolving,
                  presentedViewController == nil, let model else { return }
            if decision == nil, let prompt = indexPrompt {
                let alert = UIAlertController(title: String(localized: "建立索引", table: "FullIndex"), message: nil, preferredStyle: .alert)
                alert.view.tintColor = view.tintColor
                let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: prompt.local.reduce(0) { $0 + $1.size }), countStyle: .file)
                let start = UIAlertAction(title: String(localized: "现在建立索引（\(prompt.local.count) 本，约 \(size)）", table: "FullIndex"), style: .default) { [weak self, weak alert] _ in
                    self?.finish(alert: alert) { model.resolveIndexPrompt(start: true) }
                }
                start.accessibilityIdentifier = "fullIndexPromptStart"
                alert.addAction(start)
                alert.addAction(UIAlertAction(title: String(localized: "以后再说", table: "FullIndex"), style: .cancel) { [weak self, weak alert] _ in
                    self?.finish(alert: alert) { model.resolveIndexPrompt(start: false) }
                })
                self.alert = alert
                present(alert, animated: true)
                return
            }
            guard let decision else { return }
            let title: String, message: String, accept: String, cancel: String
            switch decision {
            case .replacement(let command, _):
                title = String(localized: "替换同名文件？")
                message = String(localized: "目标目录中已有“\(command.filename)”，替换后将使用新文件。")
                accept = String(localized: "替换"); cancel = String(localized: "取消")
            case .trashUnsupported:
                title = String(localized: "所在位置不支持最近删除")
                message = String(localized: "本批中有项目所在位置不支持最近删除，删除后无法恢复。")
                accept = String(localized: "永久删除这些项目"); cancel = String(localized: "跳过")
            }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.view.tintColor = view.tintColor
            alert.addAction(UIAlertAction(title: accept, style: .destructive) { [weak self, weak alert] _ in
                self?.finish(alert: alert) { Task { await model.resolveDecision(decision.id, accepting: true) } }
            })
            alert.addAction(UIAlertAction(title: cancel, style: .cancel) { [weak self, weak alert] _ in
                self?.finish(alert: alert) { Task { await model.resolveDecision(decision.id, accepting: false) } }
            })
            self.alert = alert
            present(alert, animated: true)
        }
        var dismissPresentation: (((@escaping () -> Void)) -> Void)?
        func finish(alert: UIAlertController?, action: @escaping () -> Void) {
            guard !resolving else { return }; resolving = true
            let completed = { [weak self] in
                self?.alert = nil; self?.resolving = false
                action()
            }
            if let dismissPresentation { dismissPresentation(completed) }
            else if let alert, alert.isBeingDismissed, let transition = alert.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { _ in completed() }
            } else if let alert, alert.presentingViewController != nil {
                alert.dismiss(animated: true, completion: completed)
            } else { completed() }
        }
    }
}

struct LibraryItemMenu: View {
    @Environment(AIService.self) private var ai
    let model: LibraryModel
    let entry: LibraryEntry
    var body: some View {
        Group {
            Button("重命名", systemImage: "pencil") { model.sheet = .rename(entry) }
            Button("移动", systemImage: "folder") { model.sheet = .move([entry]) }
            if !entry.directory {
                Button("小说详情", systemImage: "info.circle") {
                    model.path.append(.statistics(StatisticsRoute(key: entry.readingKey, bookID: entry.bookId, title: entry.title, fileID: entry.id)))
                }
                if ai.availability.isAvailable {
                    Button("完善资料", systemImage: "sparkles") { model.aiRequest = .library([entry], family: .metadata) }
                }
                if entry.shelfId != "builtin" { Button("复制到我的书架", systemImage: "doc.on.doc") { model.runBatch([.copy(entry)]) } }
                Button("导出", systemImage: "square.and.arrow.up") { model.export([entry], sharing: false) }
                Button("分享", systemImage: "square.and.arrow.up.on.square") { model.export([entry], sharing: true) }
            }
            Divider()
            Button("删除", systemImage: "trash", role: .destructive) { model.deletion = [entry] }
        }.disabled(!model.canAcceptFileWork)
    }
}

private struct LibraryNameEditor: View {
    let model: LibraryModel
    let entry: LibraryEntry?
    let location: LibraryLocation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var name = ""
    @FocusState private var focused: Bool
    private var isValid: Bool { (try? validateLibraryName(input: name, profile: .manualForm)) != nil }
    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $name).focused($focused).keyboardInputRegion()
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.done)
                    .onSubmit { submit() }.listRowBackground(Color(uiColor: theme.input)).accessibilityIdentifier("libraryItemName")
            }.themedPage().dismissKeyboardOnOutsideTap($focused).scrollDismissesKeyboard(.interactively)
                .navigationTitle(entry == nil ? "新建文件夹" : "重命名").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() }.labelStyle(.titleOnly) }
                    ToolbarItem(placement: .confirmationAction) { Button("完成", systemImage: "checkmark") { submit() }.labelStyle(.titleOnly).disabled(!isValid || !model.canAcceptFileWork).accessibilityIdentifier("saveLibraryName") }
                }
        }
        .presentationDetents([.medium]).presentationDragIndicator(.visible)
        .onAppear { name = entry.map { $0.directory ? $0.name : $0.title } ?? ""; focused = true }
    }
    private func submit() {
        guard isValid else { return }
        focused = false
        let command: LibraryCommand = entry.map { .rename($0, !$0.directory && !name.lowercased().hasSuffix(".txt") ? name + ".txt" : name) } ?? .create(location, name)
        model.runAfterSheetDismiss { model.runBatch([command]) }
    }
}

private struct LibraryMoveDestination: View {
    let model: LibraryModel
    let entries: [LibraryEntry]
    let location: LibraryLocation?
    @Environment(\.theme) private var theme
    @State private var folders: [LibraryEntry] = []
    @State private var loading = LoadingState()
    var body: some View {
        List {
            if location == nil {
                ForEach(model.shelves, id: \.id) { shelf in
                    NavigationLink { LibraryMoveDestination(model: model, entries: entries, location: LibraryLocation(shelfID: shelf.id)) } label: { ShelfRow(shelf: shelf) }
                        .disabled(shelf.error != nil).listRowBackground(Color.clear)
                }
            } else {
                ForEach(folders, id: \.id) { folder in
                    NavigationLink { LibraryMoveDestination(model: model, entries: entries, location: folder.location) } label: { Label(folder.name, systemImage: "folder") }
                        .listRowBackground(Color.clear)
                }
            }
        }.listStyle(.plain).themedPage()
        .navigationTitle(location.map { $0.path.isEmpty ? model.shelfTitle($0.shelfID) : URL(fileURLWithPath: $0.path).lastPathComponent } ?? String(localized: "移动到"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { model.sheet = nil }.labelStyle(.titleOnly) }
            if let location {
                ToolbarItem(placement: .confirmationAction) {
                    Button("移到这里") { model.runAfterSheetDismiss { model.runBatch(entries.map { .move($0, location) }) } }
                        .disabled(!model.canAcceptFileWork || entries.allSatisfy { $0.parent == location })
                }
            }
        }
        .task(id: location) {
            guard let location else { return }
            let request = loading.begin(); defer { loading.finish(request) }
            do {
                try await ReaderService.libraryTestLatency()
                let excluded = Set(entries.map(\.id))
                let values = try await ReaderService.shared.libraryEntries(location).filter { $0.directory && !excluded.contains($0.id) }
                try Task.checkCancellation(); folders = values
            } catch is CancellationError { } catch { model.error = ReaderMessages.error(error) }
        }
        .modifier(PageLoadingOverlay(request: loading.request, hasContent: !folders.isEmpty, label: "正在加载文件夹"))
    }
}

private struct LibraryExportPicker: UIViewControllerRepresentable {
    let files: LibraryExport
    func makeCoordinator() -> Coordinator { Coordinator(files) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: files.urls, asCopy: true)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private var files: LibraryExport?
        init(_ files: LibraryExport) { self.files = files }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { files?.finish(); files = nil }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { files?.finish(); files = nil }
    }
}

private struct LibraryShareSheet: UIViewControllerRepresentable {
    let files: LibraryExport
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: files.urls, applicationActivities: nil)
        // An activity can outlive the SwiftUI sheet. Keep its input alive until
        // the activity completes, or the controller itself is released.
        controller.completionWithItemsHandler = { [files, weak controller] _, _, _, _ in
            files.finish()
            controller?.completionWithItemsHandler = nil
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
