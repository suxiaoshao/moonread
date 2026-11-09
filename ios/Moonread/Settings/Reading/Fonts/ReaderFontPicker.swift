import SwiftUI
import UniformTypeIdentifiers

struct ReaderFontPicker: View {
    @Environment(ReaderSettingsStore.self) private var settings
    @Environment(\.theme) private var theme
    @State private var library = ReaderFontLibrary.shared
    @State private var builtinFonts = ReaderBuiltinFonts.shared
    @State private var fontSelection: Task<Void, Never>?
    @State private var fontSelectionID: UUID?
    @State private var downloadingFont: ReaderFont?
    @State private var downloadProgress: Double?
    @State private var choosingFile = false
    @State private var importing: Task<Void, Never>?
    @State private var deleting: ReaderFontResource?
    @State private var message: String?
    @State private var focusedResource: String?
    @State private var importReport: ReaderFontImportReport?
    private var selection: ImportedReaderFont? { settings.value?.importedFont }
    private var working: Bool { importing != nil || library.busy || settings.fontSaving }

    var body: some View {
        ReaderFontList(sections: fontSections, theme: theme, focusedResource: focusedResource)
            .themedPage().navigationTitle("字体").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if importing != nil {
                        HStack {
                            ProgressView().accessibilityLabel("正在读取字体")
                            Button("取消") { importing?.cancel() }
                        }
                    } else {
                        Button("导入", systemImage: "square.and.arrow.down") { cancelFontSelection(); choosingFile = true }.disabled(working)
                    }
                }
            }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: ["ttf", "otf", "ttc", "otc"].compactMap { UTType(filenameExtension: $0) }, allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): importFiles(urls)
                case .failure(let error): message = error.localizedDescription
                }
            }
            .alert("删除字体文件？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { resource in
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
                        .toolbar { ToolbarItem(placement: .confirmationAction) { SystemToolbarButton("关闭", role: .close) { importReport = nil } } }
                }
            }
            .alert("字体", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) { message = nil }
            } message: { Text(verbatim: message ?? "") }
        .onAppear { library.loadIfNeeded(); settings.refreshBuiltinFonts() }
        .onDisappear { importing?.cancel(); cancelFontSelection() }
    }

    private var fontSections: [ReaderFontList.Section] {
        let builtinRows: [ReaderFontList.Row] = [
            builtin(.system, title: String(localized: "系统")),
            builtin(.serif, title: String(localized: "宋体")),
            builtin(.rounded, title: String(localized: "圆体"))
        ]
        var imported = library.resources.flatMap { resource in
            resource.faces.map { importedRow(resource, face: $0) }
        }
        if library.resources.isEmpty && selection == nil {
            imported.append(.init(id: "empty", title: String(localized: "还没有导入字体"), secondary: true))
        }
        if let selection, !library.resources.contains(where: { $0.sha256 == selection.resourceSha256 && $0.faces.contains { $0.postscriptName == selection.face } }) {
            imported.append(.init(id: "missing", title: selection.face,
                                  subtitle: String(localized: "所选字体不可用，暂用系统字体"), selected: true))
        }
        var result: [ReaderFontList.Section] = [
            .init(id: 0, title: String(localized: "内置"), rows: builtinRows),
            .init(id: 1, title: String(localized: "已导入"),
                  footer: String(localized: "字体仅保存在这台设备。支持 TTF、OTF、TTC 和 OTC；集合文件中的字体会一起删除。"), rows: imported)
        ]
        if let error = library.error { result.append(.init(id: 2, rows: [.init(id: "error", title: error, error: true)])) }
        return result
    }
    private func builtin(_ font: ReaderFont, title: String) -> ReaderFontList.Row {
        var sample = defaultReaderSettings()
        sample.font = font
        return .init(id: "readerFont-\(font)", title: title, font: ReadingTypography.font(sample),
                     selected: selection == nil && settings.value?.font == font,
                     download: !builtinFonts.isAvailable(font), downloading: downloadingFont == font,
                     progress: downloadProgress, enabled: !working, action: { selectBuiltin(font) })
    }
    private func cancelFontSelection() {
        fontSelection?.cancel(); fontSelection = nil
        fontSelectionID = nil; downloadingFont = nil; downloadProgress = nil
    }
    private func selectBuiltin(_ font: ReaderFont) {
        cancelFontSelection()
        let id = UUID(); fontSelectionID = id
        if !builtinFonts.isAvailable(font) { downloadingFont = font }
        fontSelection = Task {
            defer { if fontSelectionID == id { fontSelection = nil; downloadingFont = nil; downloadProgress = nil } }
            do {
                try await settings.selectBuiltinFont(font, fonts: builtinFonts) { progress in
                    if fontSelectionID == id { downloadProgress = progress }
                }
            } catch {
                if !Task.isCancelled, fontSelectionID == id { message = error.localizedDescription }
            }
        }
    }
    private func importedRow(_ resource: ReaderFontResource, face: ReaderFontFace) -> ReaderFontList.Row {
        let ref = ImportedReaderFont(resourceSha256: resource.sha256, face: face.postscriptName)
        let available = library.isAvailable(ref)
        var subtitle = resource.sourceName + " · " + face.postscriptName
        if !available { subtitle += "\n" + String(localized: "所选字体不可用，暂用系统字体") }
        let font = available ? UIFont(name: face.postscriptName, size: UIFont.preferredFont(forTextStyle: .body).pointSize) ?? .preferredFont(forTextStyle: .body) : .preferredFont(forTextStyle: .body)
        return .init(id: resource.sha256 + ":" + face.postscriptName, title: face.displayName,
                     subtitle: subtitle, font: font, selected: selection == ref, enabled: !working,
                     action: {
                         cancelFontSelection()
                         guard available else { message = String(localized: "所选字体不可用，暂用系统字体"); return }
                         Task {
                             do { try await settings.selectFont(.system, imported: ref) }
                             catch { message = error.localizedDescription }
                         }
                     }, remove: { cancelFontSelection(); deleting = resource })
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
