import SwiftUI

struct MetadataImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var width
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var model: MetadataExchangeModel
    @State private var selected: String?
    @State private var confirm = false
    @State private var sharing: LibraryExport?
    let file: URL
    init(service: AppDataService, file: URL) { _model = State(initialValue: MetadataExchangeModel(service: service)); self.file = file }
    var body: some View {
        Group {
            if model.loading || model.preview == nil || model.result != nil || model.saving {
                NavigationStack { status.themedPage().navigationTitle(Text(model.result == nil ? "导入小说信息" : "导入结果", tableName: "MetadataExchange")).toolbar { closeButton } }
            } else if width == .regular && !typeSize.isAccessibilitySize {
                NavigationSplitView {
                    bookList.navigationTitle(Text("导入预览", tableName: "MetadataExchange")).toolbar { previewToolbar }
                } detail: {
                    if let selected, let binding = model.binding(selected) { MetadataFieldView(book: binding) }
                    else { ContentUnavailableView { Label { Text("选择一本小说", tableName: "MetadataExchange") } icon: { Image(systemName: "book") } }.themedPage() }
                }
                .safeAreaInset(edge: .bottom) { importButton }
            } else {
                NavigationStack {
                    bookList.navigationTitle(Text("导入预览", tableName: "MetadataExchange"))
                        .navigationDestination(for: String.self) { id in if let binding = model.binding(id) { MetadataFieldView(book: binding) } }
                        .toolbar { previewToolbar }
                        .safeAreaInset(edge: .bottom) { importButton }
                }
            }
        }
        .task { if model.preview == nil { await model.load(file) } }
        .interactiveDismissDisabled(model.saving)
        .confirmationDialog(Text("确认导入？", tableName: "MetadataExchange"), isPresented: $confirm, titleVisibility: .visible) {
            Button { Task { await model.save() } } label: { Text("导入 \(model.pending.count) 本", tableName: "MetadataExchange") }
        } message: { Text(verbatim: model.confirmation) }
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) { if let sharing { LibraryShareSheet(files: sharing) } }
    }
    private var bookList: some View {
        List(selection: $selected) {
            Section {
                Text("将更新 \(model.pending.count) 本", tableName: "MetadataExchange").font(.title2.weight(.semibold))
                Text("\(model.books.count) 本 · \(model.books.filter { $0.changedFields.isEmpty }.count) 本无变化", tableName: "MetadataExchange")
                    .foregroundStyle(Color(uiColor: theme.secondary))
                Picker(selection: $model.filter) {
                    Text("全部", tableName: "MetadataExchange").tag(0)
                    Text("将更新", tableName: "MetadataExchange").tag(1)
                    Text("未更新", tableName: "MetadataExchange").tag(2)
                } label: { Text("预览范围", tableName: "MetadataExchange") }.pickerStyle(.segmented)
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            Section {
                ForEach(model.visible) { book in
                    NavigationLink(value: book.id) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: book.title)
                            Text(book.changedFields.isEmpty ? String(localized: "无变化", table: "MetadataExchange") : String(localized: "\(book.changedFields.count) 项将更新", table: "MetadataExchange"))
                                .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                            if !book.messages.isEmpty { Text(verbatim: book.messages[0]).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)).lineLimit(2) }
                        }
                    }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                }
            }
            if let diagnostics = model.preview?.diagnostics, !diagnostics.isEmpty {
                Section {
                    NavigationLink {
                        List(model.issues) { issue in
                            let diagnostic = issue.value
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: String(localized: String.LocalizationValue(diagnostic.message), table: "MetadataExchange"))
                                Text(verbatim: diagnostic.sourceLine.map { String(localized: "第 \($0) 行", table: "MetadataExchange") } ?? diagnostic.recordIndex.map { "books[\($0 - 1)]" } ?? diagnostic.code)
                                    .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                        }.themedPage().navigationTitle(Text("未应用内容", tableName: "MetadataExchange"))
                    } label: { Text("\(diagnostics.count) 条未应用内容", tableName: "MetadataExchange") }
                    Button { do { sharing = try model.diagnosticFile() } catch { model.error = ReaderMessages.error(error) } } label: { Text("导出问题清单", tableName: "MetadataExchange") }
                }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
        }
        .searchable(text: $model.query, prompt: Text("搜索本次清单", tableName: "MetadataExchange"))
        .overlay { if model.visible.isEmpty { ContentUnavailableView.search(text: model.query) } }
        .themedPage().navigationBarTitleDisplayMode(.inline)
    }
    @ToolbarContentBuilder private var closeButton: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { SystemToolbarButton("关闭", role: .close) { dismiss() }.disabled(model.saving) }
    }
    @ToolbarContentBuilder private var previewToolbar: some ToolbarContent {
        closeButton
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { model.adopt(true) } label: { Text("采用导入值", tableName: "MetadataExchange") }
                Button { model.adopt(false) } label: { Text("全部保留现有值", tableName: "MetadataExchange") }
                Button { model.adopt(true, replaceTags: true) } label: { Text("采用导入值并替换标签", tableName: "MetadataExchange") }
                Text("批量操作不包含清空、改名或冲突字段。", tableName: "MetadataExchange")
            } label: { Label { Text("批量规则", tableName: "MetadataExchange") } icon: { Image(systemName: "ellipsis.circle") } }
        }
    }
    private var importButton: some View {
        VStack {
            if let error = model.error { Text(verbatim: error).font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)) }
            if model.invalidSelection {
                Text("所选资料超出编辑限制；请减少标签、改为替换或保留现有值。", tableName: "MetadataExchange").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive))
            }
            Button { confirm = true } label: { Text("导入 \(model.pending.count) 本", tableName: "MetadataExchange").frame(maxWidth: .infinity) }
                .buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).disabled(model.pending.isEmpty || model.invalidSelection)
                .accessibilityIdentifier("confirmMetadataImport")
        }.padding().background(Color(uiColor: theme.canvas))
    }
    @ViewBuilder private var status: some View {
        if model.loading { ProgressView { Text("正在检查信息…", tableName: "MetadataExchange") } }
        else if model.saving {
            VStack(spacing: 16) {
                ProgressView(value: Double(model.completed), total: Double(max(1, model.total)))
                Text("已保存 \(model.completed) / \(model.total) 本", tableName: "MetadataExchange")
                Button { model.cancel() } label: { Text("取消", tableName: "MetadataExchange") }
                Text("已保存的资料会保留。", tableName: "MetadataExchange").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
            }.padding()
        } else if let result = model.result {
            List {
                Section {
                    Text("已保存 \(result.outcomes.filter(\.saved).count) 本", tableName: "MetadataExchange").font(.title2.weight(.semibold))
                    if result.cancelled { Text("已取消，已保存的资料保留", tableName: "MetadataExchange") }
                }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                ForEach(result.outcomes) { outcome in
                    Section {
                        Label(outcome.title, systemImage: outcome.saved ? "checkmark.circle" : "exclamationmark.circle")
                        if let message = outcome.message { Text(verbatim: message).foregroundStyle(Color(uiColor: theme.secondary)) }
                    }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                }
                if !result.remaining.isEmpty {
                    Section {
                        ForEach(result.remaining) { item in Text(verbatim: item.title) }
                    } header: { Text("未处理", tableName: "MetadataExchange") }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { Task { await model.reviewAgain() } } label: { Text("重新预览", tableName: "MetadataExchange") }.buttonStyle(.bordered)
                    Button { dismiss() } label: { Text("完成", tableName: "MetadataExchange").frame(maxWidth: .infinity) }.buttonStyle(ThemedProminentButtonStyle())
                }.controlSize(.large).padding().background(Color(uiColor: theme.canvas))
            }
        } else {
            ContentUnavailableView {
                Label { Text("无法读取信息", tableName: "MetadataExchange") } icon: { Image(systemName: "doc.badge.ellipsis") }
            } description: { Text(verbatim: model.error ?? "") }
        }
    }
}

private struct MetadataFieldView: View {
    @Binding var book: MetadataPreviewBook
    @Environment(\.theme) private var theme
    var body: some View {
        Form {
            if !book.messages.isEmpty {
                Section {
                    ForEach(book.messages, id: \.self) { Text(verbatim: $0).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }
                }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
            if let error = book.selectionError {
                Section { Text(verbatim: error).foregroundStyle(Color(uiColor: theme.destructive)) }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
            ForEach($book.fields) { $choice in
                Section {
                    LabeledContent { Text(verbatim: book.current(choice.field)).textSelection(.enabled) } label: { Text("现有值", tableName: "MetadataExchange") }
                    if choice.options.count == 1, let option = choice.options.first {
                        Toggle(isOn: Binding(get: { choice.selected == option.id }, set: { choice.selected = $0 ? option.id : nil })) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.clearing ? "将清空" : choice.field == .title ? "修改文件名" : "采用导入值", tableName: "MetadataExchange")
                                if !option.clearing { optionValue(option, field: choice.field) }
                            }
                        }
                    } else {
                        Picker(selection: $choice.selected) {
                            Text("保留现有值", tableName: "MetadataExchange").tag(String?.none)
                            ForEach(choice.options) { option in
                                VStack(alignment: .leading) { optionValue(option, field: choice.field); Text(verbatim: option.sources.joined(separator: "、")).font(.caption) }.tag(Optional(option.id))
                            }
                        } label: { Text("清单中的值有冲突", tableName: "MetadataExchange") }.pickerStyle(.inline)
                    }
                    if choice.field == .tags && choice.chosen?.clearing != true {
                        Picker(selection: $choice.replaceTags) {
                            Text("追加", tableName: "MetadataExchange").tag(false)
                            Text("替换", tableName: "MetadataExchange").tag(true)
                        } label: { Text("标签处理", tableName: "MetadataExchange") }
                        if choice.replaceTags, let option = choice.chosen {
                            Text("将移除 \(Set(book.base?.tags ?? []).subtracting(option.tags).count) 个现有标签", tableName: "MetadataExchange")
                                .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                        }
                    }
                } header: { Text(verbatim: choice.field.title) } footer: {
                    if choice.field == .title { Text("这是对原文件的真实改名；不移动文件，不覆盖同名文件。未下载时不会触发下载。", tableName: "MetadataExchange") }
                    else if choice.options.contains(where: \.clearing) { Text("只有明确选择后才会清空。", tableName: "MetadataExchange") }
                }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
        }
        .themedPage().navigationTitle(book.title).navigationBarTitleDisplayMode(.inline)
    }
    private func optionValue(_ option: MetadataOption, field: MetadataField) -> some View {
        Text(verbatim: field == .title ? book.suggestedName(option) ?? option.display : field == .readingState ? option.text.flatMap(MetadataOption.status).map(MetadataPreviewBook.stateTitle) ?? option.display : option.display)
            .foregroundStyle(Color(uiColor: theme.secondary)).textSelection(.enabled)
    }
}
