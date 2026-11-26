import MoonreadCoreBindings
import MoonreadDataTypes
import MoonreadDesign
import SwiftUI
import UIKit

public struct ImportFailure: Identifiable {
    public let id = UUID()
    public let file: LibraryImportFile
    public var url: URL { file.url }
    public let location: LibraryLocation
    public let message: String
    public let completion: LibraryImportCompletion

    public init(file: LibraryImportFile, location: LibraryLocation, message: String, completion: LibraryImportCompletion) {
        self.file = file; self.location = location; self.message = message; self.completion = completion
    }
}

public struct LibraryNameEditor: View {
    let canWrite: Bool
    let submitCommand: (LibraryCommand) -> Void
    let entry: LibraryEntry?
    let location: LibraryLocation

    public init(entry: LibraryEntry?, location: LibraryLocation, canWrite: Bool,
                submit: @escaping (LibraryCommand) -> Void) {
        self.entry = entry; self.location = location; self.canWrite = canWrite; self.submitCommand = submit
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var name = ""
    @FocusState private var focused: Bool
    private var isValid: Bool { (try? validateLibraryName(input: name, profile: .manualForm)) != nil }
    public var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $name).focused($focused).keyboardInputRegion()
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.done)
                    .onSubmit { submit() }.listRowBackground(Color(uiColor: theme.input)).accessibilityIdentifier("libraryItemName")
            }.themedPage().dismissKeyboardOnOutsideTap($focused).scrollDismissesKeyboard(.interactively)
                .navigationTitle(entry == nil ? "新建文件夹" : "重命名").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { SystemToolbarButton("取消", role: .cancel) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { SystemToolbarButton("完成", role: .confirm) { submit() }.disabled(!isValid || !canWrite).accessibilityIdentifier("saveLibraryName") }
                }
        }
        .presentationDetents([.medium]).presentationDragIndicator(.visible)
        .onAppear { name = entry.map { $0.directory ? $0.name : $0.title } ?? ""; focused = true }
    }
    private func submit() {
        guard isValid else { return }
        focused = false
        let command: LibraryCommand = entry.map { .rename($0, !$0.directory && !name.lowercased().hasSuffix(".txt") ? name + ".txt" : name) } ?? .create(location, name)
        submitCommand(command)
    }
}

public struct LibraryMoveDestination: View {
    public struct Actions {
        let title: (String) -> String
        let load: (LibraryLocation) async throws -> [LibraryEntry]
        let cancel: () -> Void
        let fail: (Error) -> Void
        let move: ([LibraryCommand]) -> Void

        public init(title: @escaping (String) -> String, load: @escaping (LibraryLocation) async throws -> [LibraryEntry],
                    cancel: @escaping () -> Void, fail: @escaping (Error) -> Void, move: @escaping ([LibraryCommand]) -> Void) {
            self.title = title; self.load = load; self.cancel = cancel; self.fail = fail; self.move = move
        }
    }

    let shelves: [LibraryShelf]
    let actions: Actions
    let canWrite: Bool
    let entries: [LibraryEntry]
    let location: LibraryLocation?

    public init(shelves: [LibraryShelf], entries: [LibraryEntry], location: LibraryLocation? = nil,
                canWrite: Bool, actions: Actions) {
        self.shelves = shelves; self.entries = entries; self.location = location; self.canWrite = canWrite; self.actions = actions
    }
    @Environment(\.theme) private var theme
    @State private var folders: [LibraryEntry] = []
    @State private var loading = LoadingState()
    public var body: some View {
        List {
            if location == nil {
                ForEach(shelves, id: \.id) { shelf in
                    NavigationLink { destination(LibraryLocation(shelfID: shelf.id)) } label: { ShelfRow(shelf: shelf) }
                        .disabled(shelf.error != nil).listRowBackground(Color.clear)
                }
            } else {
                ForEach(folders, id: \.id) { folder in
                    NavigationLink { destination(folder.location) } label: { Label(folder.name, systemImage: "folder") }
                        .listRowBackground(Color.clear)
                }
            }
        }.listStyle(.plain).themedPage()
        .navigationTitle(location.map { $0.path.isEmpty ? actions.title($0.shelfID) : URL(fileURLWithPath: $0.path).lastPathComponent } ?? String(localized: "移动到"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { SystemToolbarButton("取消", role: .cancel) { actions.cancel() } }
            if let location {
                ToolbarItem(placement: .confirmationAction) {
                    Button("移到这里") { actions.move(entries.map { .move($0, location) }) }
                        .disabled(!canWrite || entries.allSatisfy { $0.parent == location })
                }
            }
        }
        .task(id: location) {
            guard let location else { return }
            let request = loading.begin(); defer { loading.finish(request) }
            do {
                let excluded = Set(entries.map(\.id))
                let values = try await actions.load(location).filter { !excluded.contains($0.id) }
                try Task.checkCancellation(); folders = values
            } catch is CancellationError { } catch { actions.fail(error) }
        }
        .modifier(PageLoadingOverlay(request: loading.request, hasContent: !folders.isEmpty, label: "正在加载文件夹"))
    }

    private func destination(_ location: LibraryLocation) -> Self {
        Self(shelves: shelves, entries: entries, location: location, canWrite: canWrite, actions: actions)
    }
}

public struct LibraryExportPicker: UIViewControllerRepresentable {
    let files: LibraryExport
    public init(files: LibraryExport) { self.files = files }
    public func makeCoordinator() -> Coordinator { Coordinator(files) }
    public func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: files.urls, asCopy: true)
        controller.delegate = context.coordinator
        return controller
    }
    public func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    public final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private var files: LibraryExport?
        init(_ files: LibraryExport) { self.files = files }
        public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { files?.finish(); files = nil }
        public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { files?.finish(); files = nil }
    }
}

/// The result is a completion panel; only failures need file rows and retry actions.
public struct LibraryImportResultsView: View {
    @Environment(\.theme) private var theme
    let failures: [ImportFailure]
    let result: String?
    let retry: (ImportFailure) -> Void
    let close: () -> Void

    public init(failures: [ImportFailure], result: String?, retry: @escaping (ImportFailure) -> Void, close: @escaping () -> Void) {
        self.failures = failures; self.result = result; self.retry = retry; self.close = close
    }
    public var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if failures.isEmpty {
                    ContentUnavailableView {
                        Label("导入完成", systemImage: "checkmark.circle")
                    } description: {
                        if let result { Text(verbatim: result) }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("部分文件未导入", systemImage: "exclamationmark.circle").font(.headline)
                        if let result { Text(verbatim: result).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.top)
                    List(failures) { failure in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: failure.url.lastPathComponent).font(.headline)
                            Text(verbatim: failure.message).font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                            Button("重试", systemImage: "arrow.clockwise") {
                                retry(failure)
                            }
                        }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                    }.contentMargins(.top, 0, for: .scrollContent)
                }
            }.themedPage().navigationTitle(String(localized: "导入结果", table: "ShareReceive"))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        SystemToolbarButton("关闭", role: .close) { close() }.accessibilityIdentifier("finishImportResults")
                    }
                }
        }
    }
}
