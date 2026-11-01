import SwiftUI
import UniformTypeIdentifiers

struct ReaderFontPicker: View {
    @Environment(ReaderSettingsStore.self) private var settings
    @Environment(\.theme) private var theme
    @State private var library = ReaderFontLibrary.shared
    @State private var choosingFile = false
    @State private var importing: Task<Void, Never>?
    @State private var deleting: ReaderFontResource?
    @State private var message: String?
    @State private var focusedResource: String?
    @State private var importReport: ReaderFontImportReport?
    private var selection: ImportedReaderFont? { settings.value?.importedFont }
    private var working: Bool { importing != nil || library.busy || settings.fontSaving }

    var body: some View {
        ScrollViewReader { scroll in
            List {
                Section("内置") {
                    builtin(.system, title: "系统")
                    builtin(.serif, title: "宋体")
                    builtin(.rounded, title: "圆体")
                }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                Section {
                    if library.resources.isEmpty && selection == nil { Text("还没有导入字体").foregroundStyle(Color(uiColor: theme.secondary)) }
                    ForEach(library.resources, id: \.sha256) { resource in
                        ForEach(resource.faces, id: \.postscriptName) { face in
                            importedRow(resource, face: face)
                                .id(resource.sha256 + ":" + face.postscriptName)
                        }
                    }
                    if let selection, !library.resources.contains(where: { $0.sha256 == selection.resourceSha256 && $0.faces.contains { $0.postscriptName == selection.face } }) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(verbatim: selection.face)
                                Text("所选字体不可用，暂用系统字体").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                            }
                            Spacer(); Image(systemName: "checkmark").foregroundStyle(Color(uiColor: theme.accent))
                        }
                    }
                } header: { Text("已导入") } footer: {
                    Text("字体仅保存在这台设备。支持 TTF、OTF、TTC 和 OTC；集合文件中的字体会一起删除。")
                }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                if let error = library.error { Text(verbatim: error).foregroundStyle(Color(uiColor: theme.destructive)).listRowBackground(Color(uiColor: theme.surface)) }
            }
            .themedPage().navigationTitle("字体").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if importing != nil {
                        HStack {
                            ProgressView().accessibilityLabel("正在读取字体")
                            Button("取消") { importing?.cancel() }
                        }
                    } else {
                        Button("导入", systemImage: "square.and.arrow.down") { choosingFile = true }.disabled(working)
                    }
                }
            }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: ["ttf", "otf", "ttc", "otc"].compactMap { UTType(filenameExtension: $0) }, allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): importFiles(urls)
                case .failure(let error): message = error.localizedDescription
                }
            }
            .confirmationDialog("删除字体文件？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { resource in
                Button("删除", role: .destructive) { remove(resource) }
                Button("取消", role: .cancel) { deleting = nil }
            } message: { resource in
                Text(deletionMessage(resource))
            }
            .sheet(item: $importReport) { report in
                NavigationStack {
                    List(report.failures) { failure in
                        Text(verbatim: failure.message).listRowBackground(Color(uiColor: theme.surface))
                            .listRowSeparatorTint(Color(uiColor: theme.separator))
                    }.themedPage().navigationTitle("未能导入的字体").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { importReport = nil } } }
                }
            }
            .alert("字体", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) { message = nil }
            } message: { Text(verbatim: message ?? "") }
            .onChange(of: focusedResource) { _, id in
                if let id { withAnimation { scroll.scrollTo(id, anchor: .center) } }
            }
        }
        .onAppear { library.loadIfNeeded() }
        .onDisappear { importing?.cancel() }
    }

    private func builtin(_ font: ReaderFont, title: LocalizedStringKey) -> some View {
        var sample = defaultReaderSettings()
        sample.font = font
        return Button {
            Task { do { try await settings.selectFont(font, imported: nil) } catch { message = error.localizedDescription } }
        } label: {
            HStack {
                Text(title).font(Font(ReadingTypography.font(sample)))
                Spacer()
                if selection == nil && settings.value?.font == font { Image(systemName: "checkmark").foregroundStyle(Color(uiColor: theme.accent)) }
            }.foregroundStyle(Color(uiColor: theme.ink))
        }.disabled(working)
            .accessibilityAddTraits(selection == nil && settings.value?.font == font ? .isSelected : [])
            .accessibilityIdentifier("readerFont-\(font)")
    }
    private func importedRow(_ resource: ReaderFontResource, face: ReaderFontFace) -> some View {
        let ref = ImportedReaderFont(resourceSha256: resource.sha256, face: face.postscriptName)
        let available = library.isAvailable(ref)
        return Button {
            guard available else { message = String(localized: "所选字体不可用，暂用系统字体"); return }
            Task {
                do { try await settings.selectFont(.system, imported: ref) }
                catch { message = error.localizedDescription }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: face.displayName).font(available ? Font(UIFont(name: face.postscriptName, size: UIFont.preferredFont(forTextStyle: .body).pointSize) ?? .preferredFont(forTextStyle: .body)) : .body)
                    Text(verbatim: resource.sourceName + " · " + face.postscriptName).font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                    if !available { Text("所选字体不可用，暂用系统字体").font(.caption).foregroundStyle(Color(uiColor: theme.secondary)) }
                }
                Spacer()
                if selection == ref { Image(systemName: "checkmark").foregroundStyle(Color(uiColor: theme.accent)) }
            }.foregroundStyle(Color(uiColor: theme.ink))
        }
        .disabled(working)
        .accessibilityAddTraits(selection == ref ? .isSelected : [])
        .swipeActions(allowsFullSwipe: false) { Button("删除", role: .destructive) { deleting = resource }.disabled(working) }
        .accessibilityAction(named: Text("删除")) { if !working { deleting = resource } }
    }
    private func importFiles(_ urls: [URL]) {
        guard importing == nil, !urls.isEmpty else { return }
        importing = Task {
            defer { importing = nil }
            var failures: [ReaderFontImportReport.Failure] = []
            for url in urls {
                if Task.isCancelled { break }
                do {
                    let resource = try await library.importFile(url)
                    if urls.count == 1, let face = resource.faces.first {
                        try await settings.selectFont(.system, imported: ImportedReaderFont(resourceSha256: resource.sha256, face: face.postscriptName))
                    }
                    if let face = resource.faces.first {
                        focusedResource = nil
                        await Task.yield()
                        focusedResource = resource.sha256 + ":" + face.postscriptName
                    }
                } catch {
                    if Task.isCancelled { break }
                    failures.append(.init(message: url.lastPathComponent + ": " + error.localizedDescription))
                }
            }
            if failures.count > 3 { importReport = ReaderFontImportReport(failures: failures) }
            else if !failures.isEmpty { message = failures.map(\.message).joined(separator: "\n") }
        }
    }
    private func deletionMessage(_ resource: ReaderFontResource) -> String {
        let file = resource.faces.count == 1
            ? String(format: String(localized: "将删除“%@”。"), resource.sourceName)
            : String(format: String(localized: "将删除“%@”中的 %lld 个字体。"), resource.sourceName, resource.faces.count)
        return file + (selection?.resourceSha256 == resource.sha256 ? "\n" + String(localized: "删除后将改用系统字体，阅读位置和笔记保留。") : "")
    }
    private func remove(_ resource: ReaderFontResource) {
        let wasSelected = selection?.resourceSha256 == resource.sha256
        deleting = nil
        Task {
            do { try await library.remove(resource, settings: settings) }
            catch {
                let switched = wasSelected && settings.value?.importedFont == nil
                message = (switched ? String(localized: "已改用系统字体，但文件未删除。") + "\n" : "") + error.localizedDescription
            }
        }
    }
}

private struct ReaderFontImportReport: Identifiable {
    struct Failure: Identifiable { let id = UUID(); let message: String }
    let id = UUID()
    let failures: [Failure]
}
