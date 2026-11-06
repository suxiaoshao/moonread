import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let moonreadMetadata = UTType(exportedAs: "dev.moonread.metadata", conformingTo: .zip)
    static var metadataImportTypes: [UTType] { [.moonreadMetadata, .json, .zip, UTType(filenameExtension: "jsonl") ?? .plainText, .plainText] }
}
struct MetadataTasksSection: View {
    let service: AppDataService
    @Environment(\.theme) private var theme
    @State private var exporting = false
    @State private var picker = false
    @State private var pickerError: String?
    @State private var selectedFile: ImportFile?
    private struct ImportFile: Identifiable { let id = UUID(); let url: URL }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label { Text("小说信息", tableName: "MetadataExchange") } icon: { Image(systemName: "doc.text") }.font(.headline)
            Text("导入或导出小说信息；可编辑清单，也可从 TXT 生成。", tableName: "MetadataExchange")
                .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
            ViewThatFits(in: .horizontal) { HStack(spacing: 10) { buttons }; VStack(spacing: 10) { buttons } }
            Link(destination: URL(string: "https://suxiaoshao.github.io/moonread/metadata-format/")!) {
                HStack { Text("了解信息格式", tableName: "MetadataExchange"); Image(systemName: "chevron.right").font(.caption) }
            }.font(.subheadline).foregroundStyle(Color(uiColor: theme.accent))
            if let pickerError { Text(verbatim: pickerError).font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)) }
        }
        .fileImporter(isPresented: $picker, allowedContentTypes: UTType.metadataImportTypes) { result in
            switch result {
            case .success(let url): selectedFile = .init(url: url)
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { pickerError = ReaderMessages.error(error) }
            }
        }
        .sheet(isPresented: $exporting) { MetadataExportView(service: service).presentationSizing(.page) }
        .sheet(item: $selectedFile) { file in MetadataImportView(service: service, file: file.url).presentationSizing(.page) }
    }
    @ViewBuilder private var buttons: some View {
        Button { exporting = true } label: {
            Label { Text("导出信息", tableName: "MetadataExchange") } icon: { Image(systemName: "square.and.arrow.up") }.frame(maxWidth: .infinity)
        }.buttonStyle(MetadataActionButtonStyle()).accessibilityIdentifier("exportMetadata")
        Button { pickerError = nil; picker = true } label: {
            Label { Text("导入信息", tableName: "MetadataExchange") } icon: { Image(systemName: "square.and.arrow.down") }.frame(maxWidth: .infinity)
        }.buttonStyle(MetadataActionButtonStyle(prominent: true)).accessibilityIdentifier("importMetadata")
    }
}

struct MetadataExportView: View {
    let service: AppDataService
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var width
    @State private var scope: String
    @State private var format = MetadataFormat.jsonl
    @State private var shelves: [LibraryShelf] = []
    @State private var output: MetadataExportResult?
    @State private var busy = false
    @State private var completed = 0
    @State private var total: Int?
    @State private var work: Task<Void, Never>?
    @State private var error: String?
    @State private var sharing: LibraryExport?
    init(service: AppDataService, shelfID: String? = nil) { self.service = service; _scope = State(initialValue: shelfID ?? "") }
    var body: some View {
        NavigationStack {
            content.themedPage().navigationTitle(Text(busy ? "正在导出" : output != nil || error != nil ? "导出结果" : "导出小说信息", tableName: "MetadataExchange"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { SystemToolbarButton("关闭", role: .close) { dismiss() }.toolbarGlyph().disabled(busy) } }
                .modifier(MetadataTaskBar { footer })
        }
        .interactiveDismissDisabled(busy)
        .task { do { shelves = try await service.shelves() } catch { self.error = ReaderMessages.error(error) } }
        .onDisappear { work?.cancel() }
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) { if let sharing { LibraryShareSheet(files: sharing) } }
    }
    @ViewBuilder private var content: some View {
        if busy {
            VStack(spacing: 16) {
                if let total, total > 0 {
                    Text("正在导出 \(completed) / \(total) 本", tableName: "MetadataExchange").font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                    ProgressView(value: Double(completed), total: Double(max(1, total))) { Text("导出进度", tableName: "MetadataExchange") }
                } else { ProgressView { Text("正在准备导出…", tableName: "MetadataExchange") } }
            }.padding(24).frame(maxWidth: 430).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            MetadataStatusView(symbol: "exclamationmark.triangle", title: String(localized: "导出失败", table: "MetadataExchange"), message: error)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let output {
            if output.count == 0 {
                MetadataStatusView(symbol: "tray", title: String(localized: "没有可导出的小说信息", table: "MetadataExchange"), message: String(localized: "所选范围没有已建立索引的小说。建立索引后可再次导出。", table: "MetadataExchange"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { resultContent(output) }
        } else { configuration }
    }
    private var configuration: some View {
        Form {
            Section {
                Picker(selection: $scope) {
                    Text("全部书架", tableName: "MetadataExchange").tag("")
                    ForEach(shelves, id: \.id) { Text(verbatim: $0.id == "builtin" ? String(localized: "我的书架") : $0.name).tag($0.id) }
                } label: { Text("范围", tableName: "MetadataExchange") }
            } header: { Text("导出范围", tableName: "MetadataExchange") } footer: { Text("包含子文件夹；同一正文的信息只导出一次。", tableName: "MetadataExchange").foregroundStyle(Color(uiColor: theme.secondary)) }
            .listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            Section {
                Picker(selection: $format) {
                    Text("JSONL（推荐）", tableName: "MetadataExchange").tag(MetadataFormat.jsonl)
                    Text("JSON").tag(MetadataFormat.json)
                } label: { Text("清单格式", tableName: "MetadataExchange") }.pickerStyle(.inline)
            } footer: { Text("只导出小说信息，不包含小说原文或阅读记录。有自设封面时，清单与图片一起打包为 .moonread-metadata。", tableName: "MetadataExchange").foregroundStyle(Color(uiColor: theme.secondary)) }
            .listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
        }
    }
    private var footer: some View {
        HStack {
            if width == .regular { Spacer(minLength: 0) }
            Group {
                if busy { Button { work?.cancel() } label: { Text("取消", tableName: "MetadataExchange").frame(maxWidth: .infinity) }.buttonStyle(MetadataActionButtonStyle()) }
                else if error != nil { Button { startExport() } label: { Text("重试", tableName: "MetadataExchange").frame(maxWidth: .infinity) }.buttonStyle(MetadataActionButtonStyle(prominent: true)) }
                else if let output, output.count == 0 { Button { self.output = nil } label: { Text("返回选择范围", tableName: "MetadataExchange").frame(maxWidth: .infinity) }.buttonStyle(MetadataActionButtonStyle()) }
                else {
                    Button {
                        if let output { do { sharing = try output.shareCopy() } catch { self.error = ReaderMessages.error(error) } }
                        else { startExport() }
                    } label: { Text(output == nil ? "导出" : "分享或存储", tableName: "MetadataExchange").frame(maxWidth: .infinity) }
                        .buttonStyle(MetadataActionButtonStyle(prominent: true)).accessibilityIdentifier("metadataGenerateExport")
                }
            }.frame(maxWidth: width == .regular ? 240 : .infinity)
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }
    private func resultContent(_ output: MetadataExportResult) -> some View {
        ViewThatFits(in: .vertical) {
            exportSummary(output)
            ScrollView { exportSummary(output) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func exportSummary(_ output: MetadataExportResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            MetadataStatusView(symbol: "checkmark", title: String(localized: "已导出 \(output.count) 条小说信息", table: "MetadataExchange"), message: String(localized: "文件已生成，可以分享或存储到“文件”。", table: "MetadataExchange"))
                .fixedSize(horizontal: false, vertical: true)
            if !output.skipped.isEmpty {
                NavigationLink {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Label { Text("\(output.skipped.count) 本尚未建立索引，未导出", tableName: "MetadataExchange") } icon: { Image(systemName: "exclamationmark.triangle") }.font(.subheadline).foregroundStyle(Color(uiColor: theme.warning))
                            VStack(spacing: 0) {
                                ForEach(output.skipped) { item in
                                    VStack(alignment: .leading, spacing: 4) { Text(verbatim: item.path); Text(verbatim: item.shelf).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                                    if item.id != output.skipped.last?.id { ThemedDivider().padding(.leading, 16) }
                                }
                            }.background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 17))
                            Text("在书架完成索引后，可再次导出。本次不会读取或下载小说。", tableName: "MetadataExchange").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                        }.padding(20)
                    }.themedPage().navigationTitle(Text("未导出的小说", tableName: "MetadataExchange"))
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) { Text("查看未导出的小说", tableName: "MetadataExchange"); Text("\(output.skipped.count) 本尚未建立索引，未导出", tableName: "MetadataExchange").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }
                        Spacer(); Image(systemName: "chevron.right").font(.caption)
                    }.foregroundStyle(Color(uiColor: theme.ink)).padding(16).background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 17))
                }.buttonStyle(.plain)
            }
            ForEach(output.warnings, id: \.self) { Text(verbatim: $0).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }
            Text("已索引但未下载的小说照常导出已有资料；本次不下载正文或自动建立索引。", tableName: "MetadataExchange").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
        }.padding(20).frame(maxWidth: 690).frame(maxWidth: .infinity)
    }
    private func startExport() {
        guard !busy else { return }
        output = nil; error = nil; completed = 0; total = nil; busy = true
        let selectedScope = scope.isEmpty ? nil : scope, selectedFormat = format
        work = Task {
            do {
                let value = try await service.exportMetadata(shelfID: selectedScope, format: selectedFormat) { done, count in
                    await MainActor.run { completed = done; total = count }
                }
                try Task.checkCancellation()
                output = value
            } catch is CancellationError { output = nil }
            catch { self.error = ReaderMessages.error(error) }
            busy = false; work = nil
        }
    }
}

/// Feature-local native button styling. Do not change buttons on other pages.
struct MetadataActionButtonStyle: PrimitiveButtonStyle {
    var prominent = false
    var destructive = false
    @Environment(\.theme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if prominent { Button(configuration).buttonStyle(.borderedProminent) }
            else { Button(configuration).buttonStyle(.bordered) }
        }
        .buttonBorderShape(.roundedRectangle(radius: 13)).controlSize(.large)
        .tint(Color(uiColor: destructive ? theme.destructive : theme.accent))
        .foregroundStyle(Color(uiColor: prominent ? theme.onAccent : destructive ? theme.destructive : theme.accent))
    }
}
/// One native scroll-edge registration for this feature's task actions.
struct MetadataTaskBar<Bar: View>: ViewModifier {
    @ViewBuilder let bar: Bar
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: .bottom, spacing: 0) { bar }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) { bar }
        }
    }
}

struct MetadataBookThumbnail: View {
    let title: String
    let cover: BookCoverAsset?
    var contentSHA256: String? = nil
    var author: String? = nil
    var size = CGSize(width: 34, height: 49)
    var contentMode: ContentMode = .fill
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        BookCoverView(title: title, compact: true, cover: cover, contentSHA256: contentSHA256, author: author, pixels: Int((size.height * displayScale).rounded(.up)), contentMode: contentMode)
            .frame(width: size.width, height: size.height).clipShape(.rect(cornerRadius: 4))
    }
}
struct MetadataStatusView: View {
    let symbol: String
    let title: String
    var message: String? = nil
    var body: some View {
        ContentUnavailableView {
            Label { Text(verbatim: title) } icon: { Image(systemName: symbol) }
        } description: { if let message { Text(verbatim: message) } }
    }
}
