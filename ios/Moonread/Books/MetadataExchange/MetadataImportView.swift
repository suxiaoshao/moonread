import SwiftUI
import UniformTypeIdentifiers

struct MetadataImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var width
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var model: MetadataExchangeModel
    @State private var selected: String?
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    @State private var confirm = false
    @State private var selectingFile = false
    @State private var sharing: LibraryExport?
    let file: URL
    init(service: AppDataService, file: URL) { _model = State(initialValue: MetadataExchangeModel(service: service)); self.file = file }
    private var wide: Bool { width == .regular && !typeSize.isAccessibilitySize }
    var body: some View {
        Group {
            if model.loading || model.preview == nil || model.books.isEmpty || model.result != nil || model.saving {
                NavigationStack { status.themedPage().navigationTitle(statusTitle).navigationBarTitleDisplayMode(.inline).toolbar { closeButton } }
            } else if wide {
                NavigationSplitView(preferredCompactColumn: $compactColumn) {
                    bookList.navigationTitle(Text("导入预览", tableName: "MetadataExchange")).toolbar { previewToolbar }
                        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
                } detail: {
                    if let selected, let binding = model.binding(selected) { MetadataFieldView(book: binding) }
                    else {
                        MetadataStatusView(symbol: "book", title: String(localized: "选择一本小说", table: "MetadataExchange"), message: String(localized: "查看资料前后变化，并决定哪些内容要采用。", table: "MetadataExchange")).themedPage()
                    }
                }.modifier(MetadataTaskBar { importButton })
            } else {
                NavigationStack {
                    bookList.navigationTitle(Text("导入预览", tableName: "MetadataExchange"))
                        .navigationDestination(item: $selected) { id in
                            if let binding = model.binding(id) { MetadataFieldView(book: binding) }
                        }
                        .toolbar { previewToolbar }
                        .modifier(MetadataTaskBar { importButton })
                }
            }
        }
        .task {
            if model.preview == nil {
                await model.load(file)
            }
        }
        .fileImporter(isPresented: $selectingFile, allowedContentTypes: UTType.metadataImportTypes) { result in
            switch result {
            case .success(let url): selected = nil; Task { await model.load(url) }
            case .failure(let error): model.error = ReaderMessages.error(error)
            }
        }
        .interactiveDismissDisabled(model.saving)
        .confirmationDialog(Text("确认导入？", tableName: "MetadataExchange"), isPresented: $confirm, titleVisibility: .visible) {
            Button { Task { await model.save() } } label: { Text("导入 \(model.pending.count) 本", tableName: "MetadataExchange") }
                .accessibilityIdentifier("executeMetadataImport")
        } message: { Text(verbatim: model.confirmation) }
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) { if let sharing { LibraryShareSheet(files: sharing) } }
    }
    private var bookList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.pending.isEmpty {
                    MetadataStatusView(symbol: "info.circle", title: String(localized: "没有待导入的改动", table: "MetadataExchange"), message: previewSummary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("将更新 \(model.pending.count) 本", tableName: "MetadataExchange").font(.title.weight(.semibold))
                        Text(verbatim: previewSummary).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    }.padding(.vertical, 8)
                }
                Picker(selection: $model.filter) {
                    Text("全部", tableName: "MetadataExchange").tag(0)
                    Text("将更新", tableName: "MetadataExchange").tag(1)
                    Text("未更新", tableName: "MetadataExchange").tag(2)
                } label: { Text("预览范围", tableName: "MetadataExchange") }.pickerStyle(.segmented)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color(uiColor: theme.secondary))
                    TextField(text: $model.query) { Text("搜索本次清单", tableName: "MetadataExchange") }
                        .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                        .accessibilityIdentifier("metadataManifestSearch")
                }.padding(10).background(Color(uiColor: theme.input), in: .rect(cornerRadius: 11))
                if model.visible.isEmpty { ContentUnavailableView.search(text: model.query) }
                else {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visible) { book in
                            Button {
                                selected = book.id
                                if wide { compactColumn = .detail }
                            } label: { bookRow(book) }
                                .buttonStyle(.plain).accessibilityIdentifier("metadataBook-" + book.id)
                            if book.id != model.visible.last?.id { ThemedDivider().padding(.leading, 16) }
                        }
                    }.background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 17)).clipShape(.rect(cornerRadius: 17))
                }
                Text("默认补空白资料、追加标签。已有不同值保留，改名需要单独选择。仅保存已选择的改动。", tableName: "MetadataExchange")
                    .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                if let diagnostics = model.preview?.diagnostics, !diagnostics.isEmpty { issues(diagnostics) }
            }.padding(20)
        }.themedPage().navigationBarTitleDisplayMode(.inline)
    }
    private var previewSummary: String {
        String(localized: "\(model.books.count) 本 · \(model.unchangedCount) 本无变化 · \(model.unmatchedCount) 本未匹配 · \(model.skippedCount) 本已跳过", table: "MetadataExchange")
    }
    private func bookRow(_ book: MetadataPreviewBook) -> some View {
        HStack(spacing: 12) {
            MetadataBookThumbnail(title: book.title, cover: book.edited?.cover, contentSHA256: book.id, author: book.edited?.author, size: CGSize(width: 44, height: 66), contentMode: .fit)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: book.title).font(.body.weight(.medium)).foregroundStyle(Color(uiColor: theme.ink))
                Text(verbatim: book.summary).font(.footnote).foregroundStyle(Color(uiColor: book.disposition == .unmatched || book.disposition == .skipped ? theme.warning : theme.secondary))
                if !book.messages.isEmpty && book.disposition == .changes {
                    Text("有未采用的内容", tableName: "MetadataExchange").font(.footnote).foregroundStyle(Color(uiColor: theme.warning))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
            .background(Color(uiColor: wide && selected == book.id ? theme.accentSurface : theme.surface))
    }
    private func issues(_ diagnostics: [MetadataDiagnostic]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink {
                List(model.issues) { issue in
                    let diagnostic = issue.value
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: String(localized: String.LocalizationValue(diagnostic.message), table: "MetadataExchange"))
                        Text(verbatim: metadataSourceDescription(sourceLine: diagnostic.sourceLine, recordIndex: diagnostic.recordIndex) ?? diagnostic.code)
                            .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                }.themedPage().navigationTitle(Text("未应用内容", tableName: "MetadataExchange"))
            } label: { Text("\(diagnostics.count) 条未应用内容", tableName: "MetadataExchange") }
            Button { do { sharing = try model.diagnosticFile() } catch { model.error = ReaderMessages.error(error) } } label: { Text("导出问题清单", tableName: "MetadataExchange") }
        }.font(.footnote).foregroundStyle(Color(uiColor: theme.accent))
    }
    @ToolbarContentBuilder private var closeButton: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { SystemToolbarButton("关闭", role: .close) { dismiss() }.toolbarGlyph().disabled(model.saving) }
    }
    @ToolbarContentBuilder private var previewToolbar: some ToolbarContent {
        closeButton
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { model.adopt(true) } label: { Text("采用导入值", tableName: "MetadataExchange") }
                Button { model.adopt(false) } label: { Text("全部保留现有值", tableName: "MetadataExchange") }
                Button { model.adopt(true, replaceTags: true) } label: { Text("采用导入值并替换标签", tableName: "MetadataExchange") }
                Text("批量操作不包含清空、改名或冲突字段。", tableName: "MetadataExchange")
            } label: { Image(systemName: "ellipsis") }
                .toolbarGlyph().accessibilityLabel(Text("批量规则", tableName: "MetadataExchange"))
        }
    }
    private var importButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.error { Text(verbatim: error).font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)) }
            if model.invalidSelection {
                Text("所选资料超出编辑限制；请减少标签、改为替换或保留现有值。", tableName: "MetadataExchange").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive))
            }
            HStack {
                if wide { Spacer(minLength: 0) }
                importAction.frame(maxWidth: wide ? 200 : .infinity)
            }
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }
    private var importAction: some View {
        Button { confirm = true } label: { Text("导入 \(model.pending.count) 本", tableName: "MetadataExchange").frame(maxWidth: .infinity) }
            .buttonStyle(MetadataActionButtonStyle(prominent: true)).disabled(model.pending.isEmpty || model.invalidSelection)
            .accessibilityIdentifier("confirmMetadataImport")
    }
    private var statusTitle: Text {
        if let result = model.result {
            return Text(result.cancelled ? "导入已取消" : result.outcomes.contains(where: { !$0.saved }) ? "导入已停止" : "导入完成", tableName: "MetadataExchange")
        }
        return Text(model.loading ? "正在准备导入" : model.saving ? "正在导入" : model.preview != nil ? "导入预览" : "无法导入", tableName: "MetadataExchange")
    }
    @ViewBuilder private var status: some View {
        if model.loading {
            VStack(spacing: 16) {
                ProgressView()
                Text("正在读取清单", tableName: "MetadataExchange").font(.title2.weight(.semibold))
                Text("正在检查格式、匹配已有索引，尚未保存任何修改。", tableName: "MetadataExchange").font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary)).multilineTextAlignment(.center)
            }.padding(24).frame(maxWidth: 430).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.saving {
            VStack(spacing: 16) {
                ProgressView()
                Text("已保存 \(model.completed) / \(model.total) 本", tableName: "MetadataExchange").font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                Text(verbatim: model.pending.dropFirst(model.completed).first?.title ?? String(localized: "正在完成", table: "MetadataExchange")).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary)).multilineTextAlignment(.center)
                ProgressView(value: Double(model.completed), total: Double(max(1, model.total))) { Text("导入进度", tableName: "MetadataExchange") }
                Text(model.cancellationRequested ? "正在完成当前这本，之后停止。" : "取消会保留已经保存的信息。", tableName: "MetadataExchange").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)).multilineTextAlignment(.center)
            }.padding(24).frame(maxWidth: 430).frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(MetadataTaskBar {
                    HStack {
                        if wide { Spacer(minLength: 0) }
                        Button { model.cancel() } label: { Text(model.cancellationRequested ? "正在停止…" : "取消导入", tableName: "MetadataExchange").frame(maxWidth: .infinity) }
                            .buttonStyle(MetadataActionButtonStyle()).disabled(model.cancellationRequested).frame(maxWidth: wide ? 240 : .infinity)
                    }.padding(.horizontal, 20).padding(.vertical, 12)
                })
        } else if let result = model.result {
            resultContent(result)
        } else if model.preview != nil {
            VStack {
                MetadataStatusView(symbol: "tray", title: String(localized: "清单中没有小说", table: "MetadataExchange"), message: String(localized: "这份清单没有可预览的书目。没有保存任何信息。", table: "MetadataExchange"))
                    .fixedSize(horizontal: false, vertical: true)
                if !model.issues.isEmpty { issues(model.preview?.diagnostics ?? []).padding(.horizontal, 20) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).modifier(MetadataTaskBar { chooseOtherFile })
        } else {
            MetadataStatusView(symbol: "exclamationmark.triangle", title: String(localized: "清单无法读取", table: "MetadataExchange"), message: model.error)
                .frame(maxWidth: .infinity, maxHeight: .infinity).modifier(MetadataTaskBar { chooseOtherFile })
        }
    }
    private var chooseOtherFile: some View {
        HStack {
            if wide { Spacer(minLength: 0) }
            Button { selectingFile = true } label: { Text("选择其他文件", tableName: "MetadataExchange").frame(maxWidth: .infinity) }
                .buttonStyle(MetadataActionButtonStyle(prominent: true)).frame(maxWidth: wide ? 240 : .infinity)
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }
    private func resultDescription(_ result: MetadataBatchResult) -> String {
        let failures = result.outcomes.filter { !$0.saved }.count
        if failures > 0 { return String(localized: "\(failures) 本失败 · \(result.remaining.count) 本未处理", table: "MetadataExchange") }
        if result.cancelled { return String(localized: "\(result.remaining.count) 本未处理", table: "MetadataExchange") }
        if result.outcomes.contains(where: { $0.message != nil }) { return String(localized: "资料已保存，请查看下方说明。", table: "MetadataExchange") }
        return String(localized: "已完成本次选择的改动", table: "MetadataExchange")
    }
    private func resultContent(_ result: MetadataBatchResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MetadataStatusView(symbol: result.outcomes.contains { !$0.saved || $0.message != nil } ? "exclamationmark.triangle" : result.cancelled ? "pause" : "checkmark", title: String(localized: "已保存 \(result.outcomes.filter(\.saved).count) 本", table: "MetadataExchange"), message: resultDescription(result))
                    .fixedSize(horizontal: false, vertical: true)
                if result.cancelled { Label { Text("已取消，已保存的资料保留", tableName: "MetadataExchange") } icon: { Image(systemName: "info.circle") }.font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }
                ForEach(result.outcomes.filter { $0.message != nil }) { outcome in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: outcome.title).font(.subheadline.weight(.semibold))
                        Label { Text(verbatim: outcome.message!) } icon: { Image(systemName: "exclamationmark.triangle") }.font(.footnote).foregroundStyle(Color(uiColor: theme.warning))
                    }
                }
                if !result.outcomes.filter(\.saved).isEmpty {
                    Text("已保存", tableName: "MetadataExchange").font(.headline)
                    VStack(spacing: 0) {
                        ForEach(result.outcomes.filter(\.saved)) { item in
                            resultRow(item)
                            if item.id != result.outcomes.filter(\.saved).last?.id { ThemedDivider().padding(.leading, 16) }
                        }
                    }.background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 17))
                } else {
                    MetadataStatusView(symbol: "tray", title: String(localized: "尚未保存任何小说", table: "MetadataExchange"), message: String(localized: "本次没有完成写入。", table: "MetadataExchange"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !result.remaining.isEmpty {
                    Text("未处理", tableName: "MetadataExchange").font(.headline)
                    VStack(spacing: 0) {
                        ForEach(result.remaining) { item in
                            resultRow(item)
                            if item.id != result.remaining.last?.id { ThemedDivider().padding(.leading, 16) }
                        }
                    }.background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 17))
                }
                VStack(alignment: .leading, spacing: 4) {
                    if model.unmatchedCount > 0 { Text("另有 \(model.unmatchedCount) 本未匹配，已跳过。", tableName: "MetadataExchange") }
                    Text("已保存且未再更改的信息，重新导入时会显示“无变化”。", tableName: "MetadataExchange")
                }.font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                Button { selected = nil; Task { await model.reviewAgain() } } label: { Text("重新预览", tableName: "MetadataExchange") }.foregroundStyle(Color(uiColor: theme.accent))
            }.padding(20).frame(maxWidth: 690, alignment: .leading).frame(maxWidth: .infinity)
        }.modifier(MetadataTaskBar {
            HStack {
                if wide { Spacer(minLength: 0) }
                Button { dismiss() } label: { Text("完成", tableName: "MetadataExchange").frame(maxWidth: .infinity) }
                    .buttonStyle(MetadataActionButtonStyle(prominent: true)).frame(maxWidth: wide ? 200 : .infinity)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }).accessibilityIdentifier("metadataImportResult")
    }
    private func resultRow(_ item: MetadataImportOutcome) -> some View {
        HStack(spacing: 12) {
            MetadataBookThumbnail(title: item.title, cover: item.cover, contentSHA256: item.id, size: CGSize(width: 44, height: 66), contentMode: .fit)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.title).font(.body.weight(.medium))
                Text(verbatim: item.summary).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
            }.frame(maxWidth: .infinity, alignment: .leading)
            if item.saved { Image(systemName: "checkmark").foregroundStyle(Color(uiColor: theme.success)).accessibilityLabel(Text("保存成功", tableName: "MetadataExchange")) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }

}

private struct MetadataFieldView: View {
    @Binding var book: MetadataPreviewBook
    @Environment(\.theme) private var theme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    MetadataBookThumbnail(title: book.title, cover: book.base?.cover, contentSHA256: book.id, author: book.base?.author)
                    VStack(alignment: .leading, spacing: 4) { Text(verbatim: book.title).font(.title2.weight(.semibold)); Text(verbatim: book.summary).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }
                }.padding(.bottom, 8)
                if book.disposition == .unmatched {
                    ContentUnavailableView { Label { Text("找不到这本书", tableName: "MetadataExchange") } icon: { Image(systemName: "book.closed") } } description: {
                        Text("请确认这本书已加入书架并建立索引。若清单由 TXT 生成，请使用与月读相同的编码；仍不匹配时可改用月读导出。", tableName: "MetadataExchange")
                    }
                } else {
                    if book.disposition == .unchanged {
                        MetadataStatusView(symbol: book.hasSuggestedChanges ? "info.circle" : "checkmark", title: String(localized: book.hasSuggestedChanges ? "未选择改动" : "无变化", table: "MetadataExchange"), message: String(localized: book.hasSuggestedChanges ? "现有信息将保留。" : "当前信息与导入文件相同，不会重复保存。", table: "MetadataExchange"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(book.messages, id: \.self) { Text(verbatim: $0).font(.footnote).foregroundStyle(Color(uiColor: theme.warning)).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color(uiColor: theme.accentSurface), in: .rect(cornerRadius: 13)) }
                }
                if let error = book.selectionError { Text(verbatim: error).font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)) }
                ForEach($book.fields) { $choice in
                    if choice.field == .cover, choice.options.contains(where: { $0.cover != nil }) {
                        MetadataCoverField(book: book, choice: $choice)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 16) {
                                if choice.options.count == 1, let option = choice.options.first {
                                    Toggle(isOn: Binding(get: { choice.selected == option.id }, set: { choice.selected = $0 ? option.id : nil })) { Text(verbatim: choice.field.title).font(.body.weight(.semibold)) }
                                } else {
                                    Text(verbatim: choice.field.title).font(.body.weight(.semibold))
                                    Picker(selection: $choice.selected) {
                                        Text("保留现有值", tableName: "MetadataExchange").tag(String?.none)
                                        ForEach(choice.options) { option in Text(option.display + " · " + option.sources.joined(separator: "、")).tag(Optional(option.id)) }
                                    } label: { Text("清单中的值有冲突", tableName: "MetadataExchange") }.pickerStyle(.menu)
                                }
                                if choice.field == .tags && choice.chosen?.clearing != true {
                                    Picker(selection: $choice.replaceTags) {
                                        Text("追加", tableName: "MetadataExchange").tag(false)
                                        Text("替换", tableName: "MetadataExchange").tag(true)
                                    } label: { Text("标签处理", tableName: "MetadataExchange") }.pickerStyle(.segmented)
                                }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("现有值", tableName: "MetadataExchange").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                                    Text(verbatim: book.current(choice.field).isEmpty ? String(localized: "未填写", table: "MetadataExchange") : book.current(choice.field)).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if let option = choice.chosen ?? (choice.options.count == 1 ? choice.options.first : nil) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("导入文件", tableName: "MetadataExchange").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                                        Text(verbatim: optionValue(option, choice: choice)).textSelection(.enabled)
                                            .foregroundStyle(Color(uiColor: choice.chosen == nil ? theme.secondary : theme.accent))
                                    }
                                }
                            }.padding(16).background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 17))
                            if choice.field == .title { Text("这是对原文件的真实改名；不移动文件，不覆盖同名文件。未下载时不会触发下载。", tableName: "MetadataExchange").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)).padding(.horizontal, 14) }
                            else if choice.options.contains(where: \.clearing) { Text("只有明确选择后才会清空。", tableName: "MetadataExchange").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)).padding(.horizontal, 14) }
                            else if choice.field == .tags { Text(choice.replaceTags ? "替换会移除未包含在导入值中的旧标签。" : "追加会保留已有标签。", tableName: "MetadataExchange").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)).padding(.horizontal, 14) }
                        }
                    }
                }
                if book.coverUnavailable {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 16) {
                            Toggle(isOn: .constant(false)) { Text("采用新封面", tableName: "MetadataExchange").font(.body.weight(.semibold)) }.disabled(true)
                            MetadataCoverComparison(book: book, option: nil)
                        }.padding(16).background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 17))
                        Text("包内图片缺失或无法读取，封面已跳过；其他信息可继续导入。这里只是预览，确认导入后才保存。", tableName: "MetadataExchange")
                            .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)).padding(.horizontal, 14)
                        if book.incomingCovers.isEmpty { MetadataCoverSources(paths: book.coverFiles) }
                    }
                }
            }.padding(20).frame(maxWidth: 620, alignment: .leading).frame(maxWidth: .infinity)
        }.themedPage().navigationTitle(Text("查看改动", tableName: "MetadataExchange")).navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("metadataFieldDetails")
    }
    private func optionValue(_ option: MetadataOption, choice: MetadataFieldChoice) -> String {
        if choice.field == .title { return book.suggestedName(option) ?? option.display }
        if choice.field == .readingState { return option.text.flatMap(MetadataOption.status).map(MetadataPreviewBook.stateTitle) ?? option.display }
        if choice.field == .tags && !option.clearing, let index = book.fields.firstIndex(where: { $0.id == choice.id }) {
            var proposed = book; proposed.fields[index].selected = option.id
            return proposed.edited?.tags.joined(separator: "、") ?? option.display
        }
        return option.display
    }
}


private struct MetadataCoverField: View {
    let book: MetadataPreviewBook
    @Binding var choice: MetadataFieldChoice
    @Environment(\.theme) private var theme
    private var same: Bool { choice.options.count == 1 && choice.options.first?.cover == book.base?.cover }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 16) {
                if same {
                    HStack { Text("采用新封面", tableName: "MetadataExchange").font(.body.weight(.semibold)); Spacer(); Text("相同", tableName: "MetadataExchange").foregroundStyle(Color(uiColor: theme.secondary)) }
                } else if choice.options.count == 1, let option = choice.options.first {
                    Toggle(isOn: Binding(get: { choice.selected == option.id }, set: { choice.selected = $0 ? option.id : nil })) { Text("采用新封面", tableName: "MetadataExchange").font(.body.weight(.semibold)) }
                } else {
                    Picker(selection: $choice.selected) {
                        Text("保留现有值", tableName: "MetadataExchange").tag(String?.none)
                        ForEach(choice.options) { option in Text(option.display + " · " + option.sources.joined(separator: "、")).tag(Optional(option.id)) }
                    } label: { Text("采用新封面", tableName: "MetadataExchange") }.pickerStyle(.menu)
                }
                ForEach(choice.options.filter { $0.cover != nil }) { option in
                    MetadataCoverComparison(book: book, option: option)
                }
            }.padding(16).background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 17))
            Text(same ? "封面相同，无需重复保存。这里只是预览，确认导入后才保存。" : book.base?.cover == nil ? "当前没有自设封面，默认采用包内新图。这里只是预览，确认导入后才保存。" : "已有自设封面，默认保留；开启后才替换。这里只是预览，确认导入后才保存。", tableName: "MetadataExchange")
                .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)).padding(.horizontal, 14)
            if choice.options.contains(where: \.clearing) {
                Text("只有明确选择后才会清空。", tableName: "MetadataExchange").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)).padding(.horizontal, 14)
            }
            MetadataCoverSources(paths: book.coverFiles)
        }
    }
}

/// Full old/new artwork comparisons are exclusive to the field page.
private struct MetadataCoverComparison: View {
    let book: MetadataPreviewBook
    let option: MetadataOption?
    @Environment(\.theme) private var theme
    private var unavailable: Bool { option == nil }
    private var same: Bool { option?.cover != nil && option?.cover == book.base?.cover }
    private var adopting: Bool { option != nil && book.fields.first { $0.field == .cover }?.selected == option?.id }
    private var outcome: String.LocalizationValue {
        if unavailable { return "图片缺失或无法读取 · 已跳过" }
        if book.fields.first(where: { $0.field == .cover })?.chosen?.clearing == true { return "将清空" }
        if same { return "与现有封面相同" }
        return adopting ? "将采用新封面" : "保留现有封面"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                side(title: book.base?.cover == nil ? "当前默认封面" : "现有封面", cover: book.base?.cover)
                Image(systemName: "arrow.right").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)).accessibilityHidden(true)
                side(title: "包内新封面", cover: option?.cover, missing: unavailable)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: String(localized: outcome, table: "MetadataExchange")).font(.footnote).foregroundStyle(Color(uiColor: unavailable ? theme.warning : theme.secondary))
        }
    }
    private func side(title: String.LocalizationValue, cover: BookCoverAsset?, missing: Bool = false) -> some View {
        VStack(spacing: 8) {
            Text(verbatim: String(localized: title, table: "MetadataExchange")).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)).multilineTextAlignment(.center)
            ZStack {
                Color(uiColor: theme.input)
                if missing {
                    VStack(spacing: 8) { Image(systemName: "exclamationmark.triangle"); Text("图片缺失或无法读取", tableName: "MetadataExchange").font(.footnote).multilineTextAlignment(.center) }.padding(8).foregroundStyle(Color(uiColor: theme.secondary))
                } else {
                    BookCoverView(title: book.title, cover: cover, contentSHA256: book.id, author: book.base?.author, contentMode: .fit)
                }
            }.frame(width: 124, height: 186)
                .clipShape(.rect(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color(uiColor: theme.separator), style: StrokeStyle(lineWidth: 1, dash: missing ? [4, 3] : [])) }
        }.frame(maxWidth: .infinity)
    }
}

private struct MetadataCoverSources: View {
    let paths: [String]
    @Environment(\.theme) private var theme
    var body: some View {
        if !paths.isEmpty {
            DisclosureGroup {
                ForEach(paths, id: \.self) { Text(verbatim: $0).font(.footnote).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            } label: { Text("封面文件", tableName: "MetadataExchange") }
                .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)).padding(.horizontal, 14)
        }
    }
}
