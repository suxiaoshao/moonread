import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let moonreadMetadata = UTType(exportedAs: "dev.moonread.metadata", conformingTo: .zip)
}
struct MetadataTasksSection: View {
    let service: AppDataService
    @Environment(\.theme) private var theme
    @State private var picker = false
    @State private var pickerError: String?
    @State private var selectedFile: ImportFile?
    private struct ImportFile: Identifiable { let id = UUID(); let url: URL }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label { Text("小说信息", tableName: "MetadataExchange") } icon: { Image(systemName: "doc.text") }.font(.headline)
            Text("整理书名、作者、标签、简介与封面，再带回书架。", tableName: "MetadataExchange")
                .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
            ViewThatFits(in: .horizontal) {
                HStack { buttons }
                VStack { buttons }
            }
            Link(destination: URL(string: "https://suxiaoshao.github.io/moonread/metadata-format/")!) {
                Label { Text("了解信息格式", tableName: "MetadataExchange") } icon: { Image(systemName: "info.circle") }
            }.font(.footnote)
            if let pickerError { Text(verbatim: pickerError).font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)) }
        }
        .fileImporter(isPresented: $picker, allowedContentTypes: [.moonreadMetadata, .json, .zip, UTType(filenameExtension: "jsonl") ?? .plainText, .plainText]) { result in
            switch result {
            case .success(let url): selectedFile = .init(url: url)
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { pickerError = ReaderMessages.error(error) }
            }
        }
        .sheet(item: $selectedFile) { file in MetadataImportView(service: service, file: file.url) }
    }
    @ViewBuilder private var buttons: some View {
        Button { pickerError = nil; picker = true } label: {
            Label { Text("导入", tableName: "MetadataExchange") } icon: { Image(systemName: "square.and.arrow.down") }.frame(maxWidth: .infinity)
        }.buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).accessibilityIdentifier("importMetadata")
        NavigationLink { MetadataExportView(service: service) } label: {
            Label { Text("导出", tableName: "MetadataExchange") } icon: { Image(systemName: "square.and.arrow.up") }.frame(maxWidth: .infinity)
        }.buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("exportMetadata")
    }
}

struct MetadataExportView: View {
    let service: AppDataService
    @Environment(\.theme) private var theme
    @State private var scope: String
    @State private var format = MetadataFormat.jsonl
    @State private var shelves: [LibraryShelf] = []
    @State private var output: MetadataExportResult?
    @State private var busy = false
    @State private var error: String?
    @State private var sharing: LibraryExport?
    init(service: AppDataService, shelfID: String? = nil) {
        self.service = service; _scope = State(initialValue: shelfID ?? "")
    }
    var body: some View {
        List {
            if let output {
                Section {
                    Label(String(localized: "已导出 \(output.count) 条小说信息", table: "MetadataExchange"), systemImage: "checkmark.circle")
                    if !output.skipped.isEmpty {
                        Text("\(output.skipped.count) 本尚未建立索引，未导出", tableName: "MetadataExchange").foregroundStyle(Color(uiColor: theme.secondary))
                        NavigationLink { List(output.skipped) { item in
                            VStack(alignment: .leading) { Text(verbatim: item.path); Text(verbatim: item.shelf).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                        }.themedPage().navigationTitle(Text("未导出的小说", tableName: "MetadataExchange")) } label: {
                            Text("查看未导出的小说", tableName: "MetadataExchange")
                        }
                    }
                    ForEach(output.warnings, id: \.self) { Text(verbatim: $0).foregroundStyle(Color(uiColor: theme.secondary)) }
                }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            } else {
                Section {
                    Picker(selection: $scope) {
                        Text("全部书架", tableName: "MetadataExchange").tag("")
                        ForEach(shelves, id: \.id) { Text(verbatim: $0.name).tag($0.id) }
                    } label: { Text("范围", tableName: "MetadataExchange") }
                } header: { Text("导出范围", tableName: "MetadataExchange") } footer: { Text("包含子文件夹；同一正文的信息只导出一次。", tableName: "MetadataExchange").foregroundStyle(Color(uiColor: theme.secondary)) }
                .listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                Section {
                    Picker(selection: $format) {
                        Text("JSONL（推荐）", tableName: "MetadataExchange").tag(MetadataFormat.jsonl)
                        Text("JSON").tag(MetadataFormat.json)
                    } label: { Text("清单格式", tableName: "MetadataExchange") }.pickerStyle(.inline)
                } footer: {
                    Text("只导出小说信息，不包含小说原文或阅读记录。有自设封面时，清单与图片一起打包为 .moonread-metadata。", tableName: "MetadataExchange").foregroundStyle(Color(uiColor: theme.secondary))
                }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
        }
        .themedPage().navigationTitle(Text(output == nil ? "导出小说信息" : "导出结果", tableName: "MetadataExchange"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if busy { ProgressView().padding().background(theme.floatingBackground(), in: .rect(cornerRadius: 12)) } }
        .safeAreaInset(edge: .bottom) {
            VStack {
                if let error { Text(verbatim: error).font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)) }
                Button { if let output { do { sharing = try output.shareCopy() } catch { self.error = ReaderMessages.error(error) } } else { Task { await export() } } } label: {
                    Text(output == nil ? "导出" : "分享或存储", tableName: "MetadataExchange").frame(maxWidth: .infinity)
                }.buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).disabled(busy)
            }.padding().background(Color(uiColor: theme.canvas))
        }
        .task { do { shelves = try await service.shelves() } catch { self.error = ReaderMessages.error(error) } }
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) { if let sharing { LibraryShareSheet(files: sharing) } }
    }
    private func export() async {
        busy = true; error = nil; defer { busy = false }
        do { output = try await service.exportMetadata(shelfID: scope.isEmpty ? nil : scope, format: format) }
        catch { self.error = ReaderMessages.error(error) }
    }
}
