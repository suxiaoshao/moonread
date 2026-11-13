import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let moonreadMetadata = UTType(exportedAs: "dev.moonread.metadata", conformingTo: .zip)
    static var metadataImportTypes: [UTType] { [.moonreadMetadata, .json, .zip, UTType(filenameExtension: "jsonl") ?? .plainText, .plainText] }
}
struct MetadataTasksSection: View {
    private var task: MetadataExchangeModel { .shared }
    @Environment(\.theme) private var theme
    @State private var exporting = false
    @State private var picker = false
    @State private var pickerError: String?
    @State private var showingImport = false
    @State private var confirmingRemoval = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label { Text("小说信息", tableName: "MetadataExchange") } icon: { Image(systemName: "doc.text") }.font(.headline)
            Text("导入或导出小说信息；可编辑清单，也可从 TXT 生成。", tableName: "MetadataExchange")
                .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
            ViewThatFits(in: .horizontal) { HStack(spacing: 10) { buttons }; VStack(spacing: 10) { buttons } }
            if let pickerError { Text(verbatim: pickerError).font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)) }
            if task.hasTask {
                ThemedDivider()
                if task.phase == .completed { completedTask }
                else { activeTask }
            }
            exportTaskSummary
            Link(destination: URL(string: "https://suxiaoshao.github.io/moonread/metadata-format/")!) {
                HStack { Text("了解信息格式", tableName: "MetadataExchange"); Image(systemName: "chevron.right").font(.caption) }
            }.font(.subheadline).foregroundStyle(Color(uiColor: theme.accent))
        }
        .fileImporter(isPresented: $picker, allowedContentTypes: UTType.metadataImportTypes) { result in
            switch result {
            case .success(let url): task.receive(url); showingImport = task.hasTask
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { pickerError = ReaderMessages.error(error) }
            }
        }
        .sheet(isPresented: $exporting) { MetadataExportView(task: task.exportTask).presentationSizing(.page) }
        .sheet(isPresented: $showingImport) { MetadataImportView(model: task).presentationSizing(.page) }
        .alert(Text("移除导入记录？", tableName: "MetadataExchange"), isPresented: $confirmingRemoval) {
            Button(role: .cancel) {} label: { Text("取消", tableName: "MetadataExchange") }
            Button(role: .destructive) {
                if task.phase == .completed { task.clear() }
            } label: { Text("移除记录", tableName: "MetadataExchange") }
        } message: {
            Text("只移除任务记录和临时资料包，已导入的资料不会删除。", tableName: "MetadataExchange")
        }
    }
    @ViewBuilder private var buttons: some View {
        Button {
            pickerError = nil
            picker = true
        } label: {
            Label { Text("导入信息", tableName: "MetadataExchange") }
                icon: { Image(systemName: "square.and.arrow.down") }.frame(maxWidth: .infinity)
        }.buttonStyle(MetadataActionButtonStyle()).disabled(!task.canStartNew).accessibilityIdentifier("importMetadata")
        Button { exporting = true } label: {
            Label { Text("导出信息", tableName: "MetadataExchange") }
                icon: { Image(systemName: "square.and.arrow.up") }.frame(maxWidth: .infinity)
        }.buttonStyle(MetadataActionButtonStyle()).accessibilityIdentifier("exportMetadata")
    }

    private var activeTask: some View {
        let phase = task.displayPhase
        let (completed, total) = task.displayedProgress
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Group {
                    switch phase {
                    case .receiving, .preparing:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).accessibilityHidden(true)
                            phaseTitle
                        }
                    case .saving, .renaming: phaseTitle
                    case .review: taskLabel("doc.text")
                    case .stopped: taskLabel("stop.circle")
                    case .paused: taskLabel("pause.circle")
                    case .failed: taskLabel("exclamationmark.circle")
                    case .interrupted: taskLabel("arrow.clockwise")
                    case .idle, .completed: EmptyView()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                taskAction(Text("查看", tableName: "MetadataExchange"))
            }
            switch phase {
            case .receiving, .preparing:
                detail(Text("可以关闭页面，稍后查看。", tableName: "MetadataExchange"))
            case .saving, .renaming:
                if total > 0 {
                    ProgressView(value: Double(completed), total: Double(total))
                        .tint(Color(uiColor: theme.accent)).accessibilityHidden(true)
                    if phase == .renaming {
                        detail(Text("已处理 \(completed) / \(total) 个改名", tableName: "MetadataExchange"))
                    } else {
                        detail(Text("已保存 \(completed) / \(total) 本", tableName: "MetadataExchange"))
                    }
                } else {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(phaseTitle)
                }
            case .review:
                detail(Text("预览已准备好，等待你确认。", tableName: "MetadataExchange"))
            case .stopped, .paused, .failed:
                if task.result != nil || task.knownRemainingWrites != nil {
                    detail(Text("已保存 \(task.savedCount) 本", tableName: "MetadataExchange"))
                } else if let error = task.error {
                    detail(Text(verbatim: error).lineLimit(2))
                } else if !task.hasCompleteInput {
                    detail(Text("资料包尚未接收完整", tableName: "MetadataExchange"))
                }
            case .interrupted:
                detail(Text(task.hasCompleteInput ? "请重新预览并确认。" : "资料包尚未接收完整", tableName: "MetadataExchange"))
            case .idle, .completed:
                EmptyView()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var exportTaskSummary: some View {
        let export = task.exportTask
        if export.phase != .idle {
            ThemedDivider()
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Label {
                        if let output = export.output {
                            if output.count > 0 { Text("已导出 \(output.count) 条小说信息", tableName: "MetadataExchange") }
                            else { Text("没有可导出的小说信息", tableName: "MetadataExchange") }
                        } else {
                            Text(export.phase.title, tableName: "MetadataExchange")
                        }
                    } icon: {
                        Image(systemName: export.phase.symbol)
                            .foregroundStyle(Color(uiColor: export.phase == .completed ? theme.success : export.phase == .failed ? theme.warning : theme.secondary))
                    }.font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                    Button { exporting = true } label: {
                        Text(export.phase == .running ? "查看" : "查看结果", tableName: "MetadataExchange").font(.subheadline)
                    }.buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.accent))
                }
                if export.phase == .running {
                    if let total = export.total, export.completed < total {
                        ProgressView(value: Double(export.completed), total: Double(total))
                            .tint(Color(uiColor: theme.accent)).accessibilityHidden(true)
                    }
                    detail(Text(export.progressText, tableName: "MetadataExchange"))
                }
            }
        }
    }

    private var completedTask: some View {
        let issues = task.renameIssueCount
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Label {
                    if task.savedCount == 0 && (task.renamedCount > 0 || issues > 0) {
                        Text("已改名 \(task.renamedCount) 个文件", tableName: "MetadataExchange")
                    } else {
                        Text("已导入 \(task.savedCount) 本", tableName: "MetadataExchange")
                    }
                } icon: {
                    Image(systemName: issues > 0 ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(Color(uiColor: issues > 0 ? theme.warning : theme.success))
                }.font(.subheadline.weight(.medium))
                if issues > 0 {
                    detail(Text("\(issues) 个改名需要查看", tableName: "MetadataExchange"))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            taskAction(Text("查看结果", tableName: "MetadataExchange"))
            Menu {
                Button(role: .destructive) { confirmingRemoval = true } label: {
                    Text("移除记录", tableName: "MetadataExchange")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .accessibilityLabel(Text("更多操作", tableName: "MetadataExchange"))
            }.tint(Color(uiColor: theme.accent))
        }
    }

    private var phaseTitle: Text {
        Text(task.displayPhase.title, tableName: "MetadataExchange").font(.subheadline.weight(.medium))
    }

    private func taskLabel(_ symbol: String) -> some View {
        Label { phaseTitle } icon: { Image(systemName: symbol) }
    }

    private func detail<Content: View>(_ content: Content) -> some View {
        content.font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
    }

    private func taskAction(_ title: Text) -> some View {
        Button { showingImport = true } label: { title.font(.subheadline) }
            .buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.accent))
    }
}

struct MetadataExportView: View {
    let task: MetadataExportTask
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var scope: String
    @State private var format = MetadataFormat.jsonl
    @State private var shelves: [LibraryShelf] = []
    @State private var shelvesError: String?
    @State private var loadedShelves = false
    @State private var shelvesReload = 0
    @State private var sharingError: String?
    @State private var sharing: LibraryExport?
    private let initialShelfName: String?
    private var validScope: Bool { scope.isEmpty || shelves.contains { $0.id == scope } }

    init(task: MetadataExportTask, shelfID: String? = nil, shelfName: String? = nil) {
        self.task = task
        initialShelfName = shelfName
        _scope = State(initialValue: shelfID ?? "")
    }

    var body: some View {
        NavigationStack {
            content.themedPage()
                .navigationTitle(Text(task.phase == .idle || task.phase == .running ? "导出小说信息" : "导出结果", tableName: "MetadataExchange"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        SystemToolbarButton("关闭", role: .close) { dismiss() }.toolbarGlyph()
                    }
                }
                .modifier(MetadataTaskBar { footer })
        }
        .alert(Text("无法分享导出文件", tableName: "MetadataExchange"), isPresented: Binding(
            get: { sharingError != nil }, set: { if !$0 { sharingError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            if let sharingError { Text(verbatim: sharingError) }
        }
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
            if let sharing { LibraryShareSheet(files: sharing) }
        }
    }

    @ViewBuilder private var content: some View {
        switch task.phase {
        case .idle:
            configuration.task(id: shelvesReload) { await loadShelves() }
        case .running:
            GeometryReader { viewport in
                ScrollView {
                    VStack(spacing: 16) {
                        Image(systemName: "square.and.arrow.up").font(.largeTitle)
                            .foregroundStyle(Color(uiColor: theme.accent)).accessibilityHidden(true)
                        Text("正在导出", tableName: "MetadataExchange").font(.title.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        if let total = task.total, task.completed < total {
                            ProgressView(value: Double(task.completed), total: Double(total)) {
                                Text(task.progressText, tableName: "MetadataExchange").monospacedDigit()
                            }.tint(Color(uiColor: theme.accent))
                        } else {
                            ProgressView { Text(task.progressText, tableName: "MetadataExchange") }
                        }
                        if !task.stopping {
                            Text("可以关闭页面，稍后查看。", tableName: "MetadataExchange")
                                .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                        }
                    }.multilineTextAlignment(.center).padding(24).frame(maxWidth: 430)
                        .frame(maxWidth: .infinity, minHeight: viewport.size.height)
                }
            }
        case .stopped, .failed:
            MetadataStatusView(symbol: task.phase.symbol,
                               title: String(localized: task.phase == .stopped ? "导出已停止" : "导出失败", table: "MetadataExchange"),
                               message: task.phase == .stopped ? stopMessage : task.error)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .completed:
            if let output = task.output { resultContent(output) }
        }
    }

    private var stopMessage: String {
        switch task.stopReason {
        case .unavailable:
            String(localized: "系统未提供后台执行资格。返回后可以重试导出。", table: "MetadataExchange")
        case .expired:
            String(localized: "系统后台执行时间已结束。返回后可以重试导出。", table: "MetadataExchange")
        case nil:
            String(localized: "未生成可分享的文件。", table: "MetadataExchange")
        }
    }

    private var configuration: some View {
        Form {
            Section {
                Picker(selection: $scope) {
                    Text("全部书架", tableName: "MetadataExchange").tag("")
                    ForEach(shelves, id: \.id) { Text(verbatim: $0.id == "builtin" ? String(localized: "我的书架") : $0.name).tag($0.id) }
                    if !validScope {
                        if !loadedShelves, let initialShelfName { Text(verbatim: initialShelfName).tag(scope) }
                        else { Text("所选书架已不可用", tableName: "MetadataExchange").tag(scope) }
                    }
                } label: { Text("范围", tableName: "MetadataExchange") }
                    .disabled(!loadedShelves)
                if let shelvesError {
                    Text(verbatim: shelvesError).font(.footnote).foregroundStyle(Color(uiColor: theme.destructive))
                    Button { shelvesReload += 1 } label: { Text("重试", tableName: "MetadataExchange") }
                }
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
        VStack(spacing: 0) {
            ThemedDivider()
            VStack(spacing: 8) {
                switch task.phase {
                case .idle:
                    Button { task.start(shelfID: scope.isEmpty ? nil : scope, format: format) } label: {
                        Text("导出", tableName: "MetadataExchange").frame(maxWidth: .infinity)
                    }.buttonStyle(MetadataActionButtonStyle(prominent: true))
                        .accessibilityIdentifier("metadataGenerateExport").disabled(loadedShelves && !validScope)
                case .running:
                    Button(role: .destructive) { task.cancel() } label: {
                        Label { Text("停止导出", tableName: "MetadataExchange") } icon: { Image(systemName: "stop.circle") }
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(MetadataActionButtonStyle(destructive: true)).disabled(task.stopping)
                case .stopped, .failed:
                    Button { task.retry() } label: {
                        Text("重试", tableName: "MetadataExchange").frame(maxWidth: .infinity)
                    }.buttonStyle(MetadataActionButtonStyle(prominent: true))
                    newExportButton(Text("返回选择范围", tableName: "MetadataExchange"))
                case .completed:
                    if let output = task.output, output.count > 0 {
                        Button {
                            do { sharing = try output.shareCopy() }
                            catch { sharingError = ReaderMessages.error(error) }
                        } label: {
                            Text("分享或存储", tableName: "MetadataExchange").frame(maxWidth: .infinity)
                        }.buttonStyle(MetadataActionButtonStyle(prominent: true))
                            .accessibilityIdentifier("metadataGenerateExport")
                        newExportButton(Text("重新选择导出范围", tableName: "MetadataExchange"))
                    } else {
                        newExportButton(Text("返回选择范围", tableName: "MetadataExchange"))
                    }
                }
            }.frame(maxWidth: 460).padding(.horizontal, 20).padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
    }

    private func newExportButton(_ title: Text) -> some View {
        Button { task.clear() } label: { title.frame(maxWidth: .infinity) }
            .buttonStyle(MetadataActionButtonStyle())
    }

    private func resultContent(_ output: MetadataExportResult) -> some View {
        ViewThatFits(in: .vertical) {
            exportSummary(output)
            ScrollView { exportSummary(output) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func exportSummary(_ output: MetadataExportResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            MetadataStatusView(symbol: output.count > 0 ? "checkmark.circle" : "tray",
                title: output.count > 0 ? String(localized: "已导出 \(output.count) 条小说信息", table: "MetadataExchange")
                    : String(localized: "没有可导出的小说信息", table: "MetadataExchange"),
                message: output.count > 0 ? String(localized: "文件已生成，可以分享或存储到“文件”。", table: "MetadataExchange")
                    : String(localized: "所选范围没有已建立索引的小说。建立索引后可再次导出。", table: "MetadataExchange"))
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
    private func loadShelves() async {
        shelvesError = nil
        do {
            let available = try await task.service.shelves()
            try Task.checkCancellation()
            shelves = available
            loadedShelves = true
        } catch {
            if !Task.isCancelled { shelvesError = ReaderMessages.error(error) }
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
