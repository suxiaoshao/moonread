import SwiftUI
import UniformTypeIdentifiers

struct MetadataImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var width
    @Environment(\.dynamicTypeSize) private var typeSize
    let model: MetadataExchangeModel
    @State private var query = ""
    @State private var filter = 0
    @State private var selected: String?
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    @State private var confirm = false
    @State private var confirmEnd = false
    @State private var confirmContinue = false
    @State private var sharing: LibraryExport?
    private var visible: [MetadataPreviewBook] { model.visible(query: query, filter: filter) }
    private var wide: Bool { width == .regular && !typeSize.isAccessibilitySize }
    var body: some View {
        Group {
            if model.phase != .review || model.books.isEmpty {
                NavigationStack {
                    status.themedPage()
                        .navigationTitle(model.loading || model.saving ? statusTitle : Text("导入小说信息", tableName: "MetadataExchange"))
                        .navigationBarTitleDisplayMode(.inline).toolbar { closeButton }
                }
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
        .alert(Text("导入小说信息？", tableName: "MetadataExchange"), isPresented: $confirm) {
            Button { model.save() } label: { Text("导入 \(model.pending.count) 本", tableName: "MetadataExchange") }
                .accessibilityIdentifier("executeMetadataImport")
            Button("取消", role: .cancel) {}
        } message: { Text(verbatim: model.confirmation) }
        .alert(Text("结束本次导入？", tableName: "MetadataExchange"), isPresented: $confirmEnd) {
            Button(role: .destructive) { model.clear(); dismiss() } label: { Text("结束本次导入", tableName: "MetadataExchange") }
            Button("取消", role: .cancel) {}
        } message: {
            Text("未保存的选择将丢弃，已保存的资料和已完成的改名会保留。", tableName: "MetadataExchange")
        }
        .alert(Text("继续导入和改名？", tableName: "MetadataExchange"), isPresented: $confirmContinue) {
            Button { model.continueTask() } label: { Text("继续导入", tableName: "MetadataExchange") }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会继续保存未提交的资料，并处理尚未执行的改名。", tableName: "MetadataExchange")
        }
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
                Picker(selection: $filter) {
                    Text("全部", tableName: "MetadataExchange").tag(0)
                    Text("将更新", tableName: "MetadataExchange").tag(1)
                    Text("未更新", tableName: "MetadataExchange").tag(2)
                } label: { Text("预览范围", tableName: "MetadataExchange") }.pickerStyle(.segmented)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color(uiColor: theme.secondary))
                    TextField(text: $query) { Text("搜索本次清单", tableName: "MetadataExchange") }
                        .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                        .accessibilityIdentifier("metadataManifestSearch")
                }.padding(10).background(Color(uiColor: theme.input), in: .rect(cornerRadius: 11))
                if visible.isEmpty { ContentUnavailableView.search(text: query) }
                else {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { book in
                            Button {
                                selected = book.id
                                if wide { compactColumn = .detail }
                            } label: { bookRow(book) }
                                .buttonStyle(.plain).accessibilityIdentifier("metadataBook-" + book.id)
                            if book.id != visible.last?.id { ThemedDivider().padding(.leading, 16) }
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
            Button { do { sharing = try model.diagnosticFile() } catch { model.showError(ReaderMessages.error(error)) } } label: { Text("导出问题清单", tableName: "MetadataExchange") }
        }.font(.footnote).foregroundStyle(Color(uiColor: theme.accent))
    }
    @ToolbarContentBuilder private var closeButton: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            SystemToolbarButton("关闭", role: .close) { dismiss() }.toolbarGlyph()
        }
    }
    @ToolbarContentBuilder private var previewToolbar: some ToolbarContent {
        closeButton
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { model.adopt(true) } label: { Text("采用导入值", tableName: "MetadataExchange") }
                Button { model.adopt(false) } label: { Text("全部保留现有值", tableName: "MetadataExchange") }
                Button { model.adopt(true, replaceTags: true) } label: { Text("采用导入值并替换标签", tableName: "MetadataExchange") }
                Text("批量操作不包含清空、改名或冲突字段。", tableName: "MetadataExchange")
                Button(role: .destructive) { confirmEnd = true } label: { Text("结束本次导入", tableName: "MetadataExchange") }
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
    private var statusTitle: Text { Text(model.phase.title, tableName: "MetadataExchange") }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .receiving, .preparing, .saving, .renaming:
            GeometryReader { viewport in
              ScrollView {
                VStack(spacing: 16) {
                    if model.saving && model.total > 0 {
                        ProgressView(value: Double(model.completed), total: Double(model.total)) {
                            if model.phase == .renaming {
                                Text("已处理 \(model.completed) / \(model.total) 个改名", tableName: "MetadataExchange")
                            } else {
                                Text("已保存 \(model.completed) / \(model.total) 本", tableName: "MetadataExchange")
                            }
                        }
                    } else {
                        ProgressView { Text(model.phase.title, tableName: "MetadataExchange") }
                    }
                    Text("可以关闭此页，稍后回来查看进度。", tableName: "MetadataExchange")
                        .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    if model.cancellationRequested {
                        Text("正在停止；已完成的操作会保留。", tableName: "MetadataExchange")
                            .font(.footnote)
                    }
                }.multilineTextAlignment(.center).padding(24).frame(maxWidth: 430)
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height)
              }
            }.safeAreaInset(edge: .bottom) {
                HStack {
                    if wide { Spacer(minLength: 0) }
                    Button { model.cancel() } label: {
                        Text("停止导入", tableName: "MetadataExchange").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MetadataActionButtonStyle()).disabled(model.cancellationRequested)
                    .frame(maxWidth: wide ? 240 : .infinity)
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }
        case .review:
            VStack {
                MetadataStatusView(symbol: "tray", title: String(localized: "清单中没有小说", table: "MetadataExchange"),
                    message: String(localized: "这份清单没有可预览的书目。没有保存任何信息。", table: "MetadataExchange"))
                if !model.issues.isEmpty { issues(model.preview?.diagnostics ?? []).padding(.horizontal, 20) }
                Button(role: .destructive) { confirmEnd = true } label: { Text("结束本次导入", tableName: "MetadataExchange") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            resultContent
        }
    }

    private var resultSymbol: String {
        switch model.phase {
        case .completed: model.renameIssueCount == 0 ? "checkmark.circle" : "exclamationmark.circle"
        case .failed: "exclamationmark.triangle"
        case .stopped: "stop.circle"
        case .paused: "pause.circle"
        case .interrupted: "arrow.clockwise"
        default: "doc"
        }
    }

    private var resultSummary: some View {
        ContentUnavailableView {
            Label { Text(model.phase.title, tableName: "MetadataExchange") } icon: { Image(systemName: resultSymbol) }
        } description: {
            VStack(spacing: 8) {
                if model.phase == .interrupted {
                    Text(model.hasCompleteInput ? "请重新预览并确认；不会自动执行上次的选择。" : "资料包尚未接收完整，请结束本次导入后重新选择文件。", tableName: "MetadataExchange")
                } else {
                    Text("已保存 \(model.savedCount) 本", tableName: "MetadataExchange")
                    if model.remainingWrites > 0 { Text("尚有 \(model.remainingWrites) 本未保存", tableName: "MetadataExchange") }
                    if model.renamedCount > 0 { Text("已改名 \(model.renamedCount) 个文件", tableName: "MetadataExchange") }
                    if model.renameIssueCount > 0 { Text("\(model.renameIssueCount) 个改名需要查看", tableName: "MetadataExchange") }
                    if model.remainingRenames > 0 { Text("尚有 \(model.remainingRenames) 个文件未改名", tableName: "MetadataExchange") }
                    if model.phase != .completed { Text("已完成的操作会保留。", tableName: "MetadataExchange") }
                }
                if model.phase == .paused, let reason = model.pauseReason {
                    Text(reason == .expired ? "系统后台执行时间已结束。" : "系统未提供后台执行资格，导入已暂停。", tableName: "MetadataExchange")
                }
                if (model.phase == .paused || model.phase == .stopped) && !model.hasCompleteInput {
                    Text("资料包尚未接收完整，请结束本次导入后重新选择文件。", tableName: "MetadataExchange")
                }
                if model.onlyRenameIssueSummary {
                    Text("请先在书架核对实际文件。重新预览会读取当前状态，不会执行先前的改名。", tableName: "MetadataExchange")
                }
                if model.sourceScopeChanged {
                    Text("资料所属账户已变化，请结束本次导入后重新选择文件。", tableName: "MetadataExchange")
                } else if model.requiresNewPreview && model.canRepreview {
                    Text("原预览已失效，请重新预览并确认。", tableName: "MetadataExchange")
                }
                if let error = model.error { Text(verbatim: error).foregroundStyle(Color(uiColor: theme.destructive)) }
            }.multilineTextAlignment(.center)
        }
    }

    private var resultContent: some View {
        GeometryReader { viewport in
          ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                resultSummary
                Spacer(minLength: 0)
                if let result = model.result {
                    let issues = result.outcomes.filter { $0.message != nil }
                    if !issues.isEmpty || !result.remaining.isEmpty || !result.remainingRenames.isEmpty {
                        DisclosureGroup {
                            ForEach(issues) { item in
                                Label { Text(verbatim: item.title + " · " + (item.message ?? "")) } icon: {
                                    Image(systemName: "exclamationmark.triangle")
                                }.padding(.vertical, 4)
                            }
                            ForEach(result.remaining) { item in resultRow(item) }
                            ForEach(result.remainingRenames) { item in
                                Label { Text(verbatim: item.title) } icon: { Image(systemName: "pencil") }
                                    .accessibilityValue(Text("文件未改名", tableName: "MetadataExchange"))
                            }
                        } label: { Text("查看未完成的内容", tableName: "MetadataExchange") }
                    }
                }
            }.padding(.horizontal, 20).frame(maxWidth: 690)
                .frame(maxWidth: .infinity, minHeight: viewport.size.height)
          }
        }.modifier(MetadataTaskBar {
            VStack(alignment: .trailing, spacing: 10) {
                if model.canContinue {
                    Button {
                        if model.continueNeedsRenameConfirmation { confirmContinue = true }
                        else { model.continueTask() }
                    } label: { Text(model.continuingPreparation ? "继续准备" : "继续导入", tableName: "MetadataExchange").frame(maxWidth: .infinity) }
                        .buttonStyle(MetadataActionButtonStyle(prominent: true))
                } else if (model.phase == .failed || model.phase == .interrupted || model.onlyRenameIssueSummary) && model.canRepreview {
                    Button { selected = nil; model.reviewAgain() } label: { Text("重新预览", tableName: "MetadataExchange").frame(maxWidth: .infinity) }
                        .buttonStyle(MetadataActionButtonStyle(prominent: true))
                }
                if model.phase == .completed {
                    Button { dismiss() } label: { Text("完成", tableName: "MetadataExchange").frame(maxWidth: .infinity) }
                        .buttonStyle(MetadataActionButtonStyle(prominent: true))
                } else {
                    Button(role: .destructive) { confirmEnd = true } label: {
                        Text("结束本次导入", tableName: "MetadataExchange").frame(maxWidth: .infinity)
                    }.buttonStyle(MetadataActionButtonStyle())
                }
            }.frame(maxWidth: wide ? 300 : .infinity).frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 20).padding(.vertical, 12)
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
