import SwiftUI
import UniformTypeIdentifiers

struct MetadataImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var width
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var statusIconSize = 48.0
    let model: MetadataExchangeModel
    @State private var query = ""
    @State private var filter = 0
    @State private var selected: String?
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    @State private var confirm = false
    @State private var confirmEnd = false
    @State private var confirmContinue = false
    @State private var inspectingUnchanged = false
    @State private var sharing: LibraryExport?
    private var visible: [MetadataPreviewBook] { model.visible(query: query, filter: filter) }
    private var wide: Bool { width == .regular && !typeSize.isAccessibilitySize }
    private var detailedBookID: String? { selected ?? (wide ? model.books.first?.id : nil) }
    var body: some View {
        let unchanged = !inspectingUnchanged && model.isUnchangedPreview
        Group {
            if model.phase != .review || model.books.isEmpty || unchanged {
                NavigationStack {
                    status(showUnchanged: unchanged).themedPage()
                        .navigationTitle(Text(model.phase == .review ? "导入预览" : "导入小说信息", tableName: "MetadataExchange"))
                        .navigationBarTitleDisplayMode(.inline).toolbar { statusToolbar(showUnchanged: unchanged) }
                }
            } else if wide {
                NavigationSplitView(preferredCompactColumn: $compactColumn) {
                    bookList.navigationTitle(Text("导入预览", tableName: "MetadataExchange")).toolbar { previewOptions }
                        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
                } detail: {
                    Group {
                        if let detailedBookID, let binding = model.binding(detailedBookID) { MetadataFieldView(book: binding) }
                        else {
                            MetadataStatusView(symbol: "book", title: String(localized: "选择一本小说", table: "MetadataExchange"), message: String(localized: "查看资料前后变化，并决定哪些内容要采用。", table: "MetadataExchange")).themedPage()
                        }
                    }.toolbar { closeButton }
                }.modifier(MetadataTaskBar { importButton })
            } else {
                NavigationStack {
                    bookList.navigationTitle(Text("导入预览", tableName: "MetadataExchange"))
                        .navigationDestination(item: $selected) { id in
                            if let binding = model.binding(id) {
                                MetadataFieldView(book: binding)
                                    .navigationTitle(Text("导入预览", tableName: "MetadataExchange")).toolbar { closeButton }
                            }
                        }
                        .toolbar {
                            closeButton
                            previewOptions
                        }
                        .modifier(MetadataTaskBar { importButton })
                }
            }
        }
        .onChange(of: model.phase) { _, phase in
            if phase != .review { inspectingUnchanged = false; selected = nil }
        }
        .alert(Text("导入小说信息？", tableName: "MetadataExchange"), isPresented: $confirm) {
            Button { model.save() } label: { Text("确认导入", tableName: "MetadataExchange") }
                .accessibilityIdentifier("executeMetadataImport")
            Button("取消", role: .cancel) {}
        } message: { Text(verbatim: model.confirmation) }
        .alert(Text("结束本次导入？", tableName: "MetadataExchange"), isPresented: $confirmEnd) {
            Button(role: .destructive) { model.clear(); dismiss() } label: { Text("结束导入", tableName: "MetadataExchange") }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已保存的资料和已完成的改名会保留。未保存的选择和预览将丢弃，下次导入需要重新预览。", tableName: "MetadataExchange")
        }
        .alert(Text(model.renameOnlyContinuation ? "继续剩余改名？" : "继续导入和改名？", tableName: "MetadataExchange"), isPresented: $confirmContinue) {
            Button { model.continueTask() } label: {
                Text(model.renameOnlyContinuation ? "继续改名" : "继续导入", tableName: "MetadataExchange")
            }
            Button("取消", role: .cancel) {}
        } message: {
            if model.renameOnlyContinuation {
                Text("还有 \(model.knownRemainingRenames) 个文件未处理。请核对实际文件状态后确认。", tableName: "MetadataExchange")
            } else {
                Text("会继续保存未提交的资料，并处理尚未执行的改名。", tableName: "MetadataExchange")
            }
        }
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) { if let sharing { LibraryShareSheet(files: sharing) } }
    }
    private var bookList: some View {
        let pending = model.pending
        let writeCount = pending.filter { !$0.changedMetadataFields.isEmpty }.count
        let renameCount = pending.filter { $0.renameName != nil }.count
        let kept = model.books.count - writeCount - model.unmatchedCount - model.skippedCount
        let rows = visible
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    if writeCount > 0 { Text("将更新 \(writeCount) 本", tableName: "MetadataExchange").font(.title.weight(.semibold)) }
                    else if renameCount > 0 { Text("将改名 \(renameCount) 个文件", tableName: "MetadataExchange").font(.title.weight(.semibold)) }
                    else { Text("没有待保存的改动", tableName: "MetadataExchange").font(.title.weight(.semibold)) }
                    Text("\(model.books.count) 本 · \(kept) 本保留现有资料", tableName: "MetadataExchange")
                        .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    if model.unmatchedCount > 0 || model.skippedCount > 0 {
                        Text("\(model.unmatchedCount) 本未匹配 · \(model.skippedCount) 本已跳过", tableName: "MetadataExchange")
                            .font(.footnote).foregroundStyle(Color(uiColor: theme.warning))
                    }
                }.padding(.vertical, 8)
                Picker(selection: $filter) {
                    Text("全部", tableName: "MetadataExchange").tag(0)
                    Text("将更新", tableName: "MetadataExchange").tag(1)
                    Text("未更新", tableName: "MetadataExchange").tag(2)
                } label: { Text("预览范围", tableName: "MetadataExchange") }.pickerStyle(.segmented)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color(uiColor: theme.secondary))
                    TextField(text: $query) { Text("搜索小说", tableName: "MetadataExchange") }
                        .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                        .accessibilityIdentifier("metadataManifestSearch")
                }.padding(10).background(Color(uiColor: theme.input), in: .rect(cornerRadius: 11))
                if rows.isEmpty {
                    ContentUnavailableView {
                        Label { Text("没有匹配的小说", tableName: "MetadataExchange") } icon: { Image(systemName: "magnifyingglass") }
                    }
                }
                else {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { book in
                            Button {
                                selected = book.id
                                if wide { compactColumn = .detail }
                            } label: { bookRow(book) }
                                .buttonStyle(.plain).accessibilityIdentifier("metadataBook-" + book.id)
                            if book.id != rows.last?.id { ThemedDivider().padding(.leading, 16) }
                        }
                    }.background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 17)).clipShape(.rect(cornerRadius: 17))
                }
                Text("默认补空白资料、追加标签。已有不同值保留，改名需要单独选择。", tableName: "MetadataExchange")
                    .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                if let diagnostics = model.preview?.diagnostics, !diagnostics.isEmpty { issues(diagnostics) }
            }.padding(20)
        }.themedPage().navigationBarTitleDisplayMode(.inline)
    }
    private func bookRow(_ book: MetadataPreviewBook) -> some View {
        let disposition = book.disposition
        return HStack(spacing: 12) {
            MetadataBookThumbnail(title: book.title, cover: book.edited?.cover, contentSHA256: book.id, author: book.edited?.author, size: CGSize(width: 44, height: 66), contentMode: .fit)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: book.title).font(.body.weight(.medium)).foregroundStyle(Color(uiColor: theme.ink))
                if disposition == .unchanged {
                    Text("保留现有资料", tableName: "MetadataExchange").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                } else if disposition == .changes {
                    let fields = book.changedMetadataFields.map(\.title).formatted(.list(type: .and, width: .short))
                    let rename = book.renameName != nil
                    if fields.isEmpty {
                        Text("仅修改文件名", tableName: "MetadataExchange").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    } else if rename {
                        Text("\(fields)待更新 · 已选改名", tableName: "MetadataExchange").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    } else {
                        Text("\(fields)待更新", tableName: "MetadataExchange").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    }
                } else {
                    Text(verbatim: book.summary).font(.footnote).foregroundStyle(Color(uiColor: theme.warning))
                }
                if !book.messages.isEmpty && disposition == .changes {
                    Text("有未采用的内容", tableName: "MetadataExchange").font(.footnote).foregroundStyle(Color(uiColor: theme.warning))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
            .background(Color(uiColor: wide && detailedBookID == book.id ? theme.accentSurface : theme.surface))
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
        ToolbarItem(placement: .topBarTrailing) {
            SystemToolbarButton("关闭", role: .close) { dismiss() }.toolbarGlyph()
        }
    }
    @ToolbarContentBuilder private var previewOptions: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
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
        taskFooter {
            if let error = model.error { Text(verbatim: error).font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)) }
            if model.invalidSelection {
                Text("所选资料超出编辑限制；请减少标签、改为替换或保留现有值。", tableName: "MetadataExchange").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive))
            }
            importAction
        }
    }
    private var importAction: some View {
        let pending = model.pending
        let writes = pending.filter { !$0.changedMetadataFields.isEmpty }.count
        let renames = pending.filter { $0.renameName != nil }.count
        return Button { confirm = true } label: {
            Group {
                if writes > 0 { Text("导入 \(writes) 本", tableName: "MetadataExchange") }
                else if renames > 0 { Text("确认改名 \(renames) 个文件", tableName: "MetadataExchange") }
                else { Text("没有待保存的改动", tableName: "MetadataExchange") }
            }.frame(maxWidth: .infinity)
        }
            .buttonStyle(MetadataActionButtonStyle(prominent: true)).disabled(pending.isEmpty || model.invalidSelection)
            .accessibilityIdentifier("confirmMetadataImport")
    }

    @ToolbarContentBuilder private func statusToolbar(showUnchanged: Bool) -> some ToolbarContent {
        closeButton
        if (model.canContinue || canStartFreshPreview) && model.phase != .completed {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button(role: .destructive) { confirmEnd = true } label: {
                        Text("结束本次导入", tableName: "MetadataExchange")
                    }
                } label: { Image(systemName: "ellipsis") }
                    .toolbarGlyph().accessibilityLabel(Text("更多操作", tableName: "MetadataExchange"))
            }
        } else if showUnchanged {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button { inspectingUnchanged = true } label: { Text("查看逐书预览", tableName: "MetadataExchange") }
                    Button(role: .destructive) { confirmEnd = true } label: { Text("结束本次导入", tableName: "MetadataExchange") }
                } label: { Image(systemName: "ellipsis") }
                    .toolbarGlyph().accessibilityLabel(Text("更多操作", tableName: "MetadataExchange"))
            }
        }
    }

    private func taskFooter<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            ThemedDivider()
            VStack(spacing: 8, content: content)
                .frame(maxWidth: 460)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(spacing: 16, content: content)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: 430)
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height)
            }
        }
    }

    private func note(_ text: Text) -> some View {
        text.font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
    }

    private func statusHeading(_ title: Text, symbol: String, color: UIColor, message: Text) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: statusIconSize, weight: .regular))
                .foregroundStyle(Color(uiColor: color)).accessibilityHidden(true)
            title.font(.title.weight(.semibold)).accessibilityAddTraits(.isHeader)
            message.foregroundStyle(Color(uiColor: theme.secondary))
        }
    }

    @ViewBuilder private func status(showUnchanged: Bool) -> some View {
        switch model.phase {
        case .receiving, .preparing, .saving, .renaming:
            runningStatus
        case .review where showUnchanged:
            centered {
                terminalHeading(Text("没有需要更新的资料", tableName: "MetadataExchange"),
                                symbol: "checkmark.circle", color: theme.success,
                                message: Text("所选资料与现有内容一致。", tableName: "MetadataExchange"))
                note(Text("没有重复写入资料。", tableName: "MetadataExchange"))
            }.modifier(MetadataTaskBar {
                taskFooter {
                    primary(Text("完成", tableName: "MetadataExchange")) {
                        model.clear()
                        dismiss()
                    }
                }
            })
        case .review:
            centered {
                MetadataStatusView(symbol: "tray", title: String(localized: "清单中没有小说", table: "MetadataExchange"),
                    message: String(localized: "这份清单没有可预览的书目。没有保存任何信息。", table: "MetadataExchange"))
                if let diagnostics = model.preview?.diagnostics, !diagnostics.isEmpty { issues(diagnostics) }
                if let error = model.error { note(Text(verbatim: error)) }
            }.modifier(MetadataTaskBar { taskFooter { endAction } })
        case .idle:
            Color.clear
        default:
            resultContent
        }
    }

    private var runningStatus: some View {
        let phase = model.displayPhase
        let renaming = phase == .renaming
        let saving = phase == .saving
        let (completed, total) = model.displayedProgress
        return centered {
            statusHeading(Text(phase.title, tableName: "MetadataExchange"),
                          symbol: saving ? "tray.and.arrow.down" : "doc.text", color: saving ? theme.accent : theme.secondary, message: runningMessage)
            if (saving || renaming) && total > 0 {
                VStack(spacing: 8) {
                    progressCount(completed, total: total, renaming: renaming)
                    if saving {
                        ProgressView(value: Double(completed), total: Double(total)) {
                            Text("已保存", tableName: "MetadataExchange")
                        }.labelsHidden().tint(Color(uiColor: theme.accent)).accessibilityHidden(true)
                        note(Text("已保存", tableName: "MetadataExchange")).accessibilityHidden(true)
                    }
                }
            } else {
                ProgressView().controlSize(.regular).accessibilityLabel(Text(phase.title, tableName: "MetadataExchange"))
            }
            if saving { note(Text("可以关闭此页面，保存会继续。", tableName: "MetadataExchange")) }
            else if renaming { note(Text("关闭页面不会停止任务。", tableName: "MetadataExchange")) }
            else { note(Text("可以关闭此页面，稍后从“小说信息”查看。", tableName: "MetadataExchange")) }
            if model.cancellationRequested {
                note(Text("正在停止；已完成的操作会保留。", tableName: "MetadataExchange"))
            }
        }.modifier(MetadataTaskBar {
            taskFooter {
                Button(role: .destructive) { model.cancel() } label: {
                    Label {
                        Text(renaming ? "停止后续改名" : "停止导入", tableName: "MetadataExchange")
                    } icon: { Image(systemName: "stop.circle") }
                        .frame(maxWidth: .infinity)
                }.buttonStyle(MetadataActionButtonStyle(destructive: true)).disabled(model.cancellationRequested)
            }
        })
    }

    private var runningMessage: Text {
        if model.displayPhase == .renaming {
            return Text(model.hasCommittedMetadataBeforeRenaming ? "资料已保存完成，正在处理你选择的文件名。" : "正在处理你选择的文件名。", tableName: "MetadataExchange")
        }
        switch model.phase {
        case .receiving: return Text("正在接收所选资料包。", tableName: "MetadataExchange")
        case .preparing: return Text("正在匹配小说、比较资料与封面。", tableName: "MetadataExchange")
        default: return Text("只保存已确认的资料。", tableName: "MetadataExchange")
        }
    }

    private func progressCount(_ completed: Int, total: Int, renaming: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(completed, format: .number).font(.largeTitle.weight(.semibold))
            Text(renaming ? "／\(total) 个" : "／\(total) 本", tableName: "MetadataExchange")
                .font(.title3).foregroundStyle(Color(uiColor: theme.secondary))
        }.monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(renaming ? "已处理 \(completed) / \(total) 个改名" : "已保存 \(completed) / \(total) 本", tableName: "MetadataExchange"))
    }

    private func terminalHeading(_ title: Text, symbol: String, color: UIColor, message: Text) -> some View {
        ContentUnavailableView {
            Label { title.foregroundStyle(Color(uiColor: theme.ink)) } icon: {
                Image(systemName: symbol).foregroundStyle(Color(uiColor: color))
            }
        } description: {
            message.foregroundStyle(Color(uiColor: theme.secondary))
        }.fixedSize(horizontal: false, vertical: true)
    }

    private var completedTitle: Text {
        if model.renameIssueCount == 0 { return Text("导入完成", tableName: "MetadataExchange") }
        if model.savedCount == 0 { return Text("部分文件改名需要核对", tableName: "MetadataExchange") }
        // A warning may mean the file moved but the index could not be updated.
        return Text("资料已保存，部分文件改名需要核对", tableName: "MetadataExchange")
    }

    @ViewBuilder private var resultHeading: some View {
        let warn = model.renameIssueCount > 0
        switch model.phase {
        case .completed:
            terminalHeading(completedTitle, symbol: warn ? "exclamationmark.circle" : "checkmark.circle",
                color: warn ? theme.warning : theme.success, message: Text(warn
                    ? (model.savedCount > 0 ? "文件改名问题不影响已保存的资料。" : "请在书架核对未完成的文件改名。")
                    : "可以继续阅读了。", tableName: "MetadataExchange"))
        case .stopped, .paused:
            terminalHeading(Text(model.phase.title, tableName: "MetadataExchange"), symbol: "pause.circle", color: theme.secondary,
                            message: pauseMessage)
        case .failed:
            terminalHeading(Text(model.preview == nil && model.result == nil ? "导入未完成" : "保存未完成", tableName: "MetadataExchange"),
                            symbol: "exclamationmark.circle", color: theme.warning, message: Text(model.preview == nil && model.result == nil
                                ? "没有保存任何资料。" : "本次提交未完成，此前保存的资料保留。", tableName: "MetadataExchange"))
        case .interrupted:
            terminalHeading(Text(model.phase.title, tableName: "MetadataExchange"), symbol: "exclamationmark.circle",
                color: theme.warning, message: Text(model.hasCompleteInput
                    ? "应用退出前，部分资料可能已经保存。请重新预览，核对当前资料后再确认。"
                    : "资料包尚未接收完整，请结束本次导入后重新选择文件。", tableName: "MetadataExchange"))
        default: EmptyView()
        }
    }

    private var pauseMessage: Text {
        if model.continuingPreparation && model.preview == nil && model.result == nil {
            return Text(model.phase == .paused ? "预览准备已暂停，尚未保存任何资料。" : "预览准备已停止，尚未保存任何资料。", tableName: "MetadataExchange")
        }
        if model.phase == .stopped { return Text("已停止后续操作，已保存的资料保留。", tableName: "MetadataExchange") }
        if model.pauseReason == .unavailable { return Text("系统未提供后台执行资格，导入已暂停。", tableName: "MetadataExchange") }
        return Text(model.canContinue ? "后台执行已结束。已保存的资料保留，稍后可以继续。" : "后台执行已结束。已保存的资料保留。", tableName: "MetadataExchange")
    }

    private func resultLine(_ title: Text, _ value: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            title.foregroundStyle(Color(uiColor: theme.secondary))
            Spacer(minLength: 0)
            value.monospacedDigit().multilineTextAlignment(.trailing)
        }.padding(.vertical, 10).accessibilityElement(children: .combine)
    }

    @ViewBuilder private var resultRows: some View {
        let renames = model.knownRemainingRenames
        let renamed = model.renamedCount
        let writes = model.knownRemainingWrites
        if model.phase == .completed || writes != nil || model.result != nil {
            VStack(spacing: 0) {
                ThemedDivider()
                if model.phase != .completed || model.savedCount > 0 || (renamed == 0 && model.renameIssueCount == 0) {
                    resultLine(Text(model.phase == .failed ? "已保存" : "资料已保存", tableName: "MetadataExchange"),
                               Text("\(model.savedCount) 本", tableName: "MetadataExchange"))
                    ThemedDivider()
                }
                if model.phase != .completed, let writes, !model.renameOnlyContinuation {
                    resultLine(Text("尚未保存", tableName: "MetadataExchange"), Text("\(writes) 本", tableName: "MetadataExchange"))
                    ThemedDivider()
                }
                if renamed > 0 || model.renameIssueCount > 0 || (model.knownRenameTotal ?? 0) > renames {
                    resultLine(Text("文件已改名", tableName: "MetadataExchange"),
                               model.knownRenameTotal.map { Text("\(renamed)／\($0) 个", tableName: "MetadataExchange") }
                                ?? Text("\(renamed) 个", tableName: "MetadataExchange"))
                    ThemedDivider()
                }
                if renames > 0 {
                    resultLine(Text("待处理的改名", tableName: "MetadataExchange"), Text("\(renames) 个", tableName: "MetadataExchange"))
                    ThemedDivider()
                }
            }.multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder private var resultNotes: some View {
        if model.phase == .interrupted {
            note(Text("不会自动重复保存或改名。", tableName: "MetadataExchange"))
        }
        if model.phase == .paused || model.phase == .stopped {
            if !model.hasCompleteInput {
                note(Text("资料包尚未接收完整，请结束本次导入后重新选择文件。", tableName: "MetadataExchange"))
            } else if model.canContinue && model.continuingPreparation {
                note(Text("继续后会完成比较，再由你确认保存内容。", tableName: "MetadataExchange"))
            }
        }
        if model.onlyRenameIssueSummary {
            note(Text("请先在书架核对实际文件。重新预览会读取当前状态，不会执行先前的改名。", tableName: "MetadataExchange"))
        }
        if model.sourceScopeChanged {
            note(Text("资料所属账户已变化，请结束本次导入后重新选择文件。", tableName: "MetadataExchange"))
        } else if model.requiresNewPreview && model.canRepreview {
            note(Text("原预览已失效，请重新预览并确认。", tableName: "MetadataExchange"))
        }
    }

    @ViewBuilder private var resultIssues: some View {
        let issues = model.result?.outcomes.filter { $0.message != nil } ?? []
        let unwritten = model.result?.remaining ?? []
        let unrenamed = model.result?.remainingRenames ?? []
        if model.error != nil || !issues.isEmpty || !unwritten.isEmpty || !unrenamed.isEmpty || model.onlyRenameIssueSummary {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    if let error = model.error { Text(verbatim: error).foregroundStyle(Color(uiColor: theme.destructive)) }
                    ForEach(issues) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: item.title).fontWeight(.medium)
                            if let message = item.message { Text(verbatim: message) }
                        }.padding(.vertical, 4)
                    }
                    ForEach(unwritten) { item in
                        Label { Text(verbatim: item.title) } icon: { Image(systemName: "doc.text") }
                            .accessibilityValue(Text("尚未开始保存", tableName: "MetadataExchange"))
                    }
                    ForEach(unrenamed) { item in
                        Label { Text(verbatim: item.title) } icon: { Image(systemName: "pencil") }
                            .accessibilityValue(Text("文件未改名", tableName: "MetadataExchange"))
                    }
                    if model.onlyRenameIssueSummary {
                        Text("这次只保留了结果摘要，请在书架核对文件。", tableName: "MetadataExchange")
                    }
                }.font(.footnote).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            } label: {
                if model.phase == .completed && model.renameIssueCount > 0 {
                    Text("查看 \(model.renameIssueCount) 个未完成项", tableName: "MetadataExchange")
                } else {
                    Text(model.phase == .failed ? "查看问题" : "查看未完成的内容", tableName: "MetadataExchange")
                }
            }.multilineTextAlignment(.leading)
        }
    }

    private var canStartFreshPreview: Bool {
        (model.phase == .failed || model.phase == .interrupted || model.onlyRenameIssueSummary || model.requiresNewPreview)
            && model.canRepreview
    }

    private var endAction: some View {
        Button(role: .destructive) { confirmEnd = true } label: {
            Text("结束本次导入", tableName: "MetadataExchange").frame(maxWidth: .infinity)
        }.buttonStyle(MetadataActionButtonStyle(destructive: true))
    }

    private func primary(_ title: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) { title.frame(maxWidth: .infinity) }
            .buttonStyle(MetadataActionButtonStyle(prominent: true))
    }

    private var resultContent: some View {
        centered {
            resultHeading
            resultRows
            resultIssues
            resultNotes
        }.modifier(MetadataTaskBar {
            taskFooter {
                if model.phase == .completed {
                    if canStartFreshPreview {
                        Button { model.reviewAgain() } label: { Text("重新预览", tableName: "MetadataExchange") }
                    }
                    primary(Text("完成", tableName: "MetadataExchange")) { dismiss() }
                } else if model.canContinue {
                    primary(Text(model.renameOnlyContinuation ? "查看剩余改名" : model.continuingPreparation ? "继续准备" : "继续导入", tableName: "MetadataExchange")) {
                        if model.continueNeedsRenameConfirmation { confirmContinue = true }
                        else { model.continueTask() }
                    }
                } else if canStartFreshPreview {
                    primary(Text("重新预览", tableName: "MetadataExchange")) { model.reviewAgain() }
                } else {
                    endAction
                }
            }
        }).accessibilityIdentifier("metadataImportResult")
    }
}

private struct MetadataFieldView: View {
    @Binding var book: MetadataPreviewBook
    @Environment(\.theme) private var theme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: book.title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text("只保存你选择的改动。", tableName: "MetadataExchange")
                        .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
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
                                if choice.field == .title {
                                    Text("文件名", tableName: "MetadataExchange").font(.headline)
                                    Text("改名与资料保存分别报告结果。", tableName: "MetadataExchange")
                                        .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                                    if let source = book.source {
                                        Text(verbatim: source.name).textSelection(.enabled)
                                    }
                                } else {
                                    Text(verbatim: choice.field.title).font(.headline)
                                }
                                if choice.options.count > 1 {
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
                                if choice.field != .title {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("现有资料", tableName: "MetadataExchange").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                                        Text(verbatim: book.current(choice.field).isEmpty ? String(localized: "未填写", table: "MetadataExchange") : book.current(choice.field)).textSelection(.enabled)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    if let option = choice.chosen ?? (choice.options.count == 1 ? choice.options.first : nil) {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text("导入资料", tableName: "MetadataExchange").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                                            Text(verbatim: optionValue(option, choice: choice)).textSelection(.enabled)
                                                .foregroundStyle(Color(uiColor: choice.chosen == nil ? theme.secondary : theme.accent))
                                        }
                                    }
                                }
                                if choice.options.count == 1, let option = choice.options.first {
                                    Toggle(isOn: Binding(get: { choice.selected == option.id }, set: { choice.selected = $0 ? option.id : nil })) {
                                        Text(choice.field == .title ? "同时修改文件名" : "采用导入值", tableName: "MetadataExchange")
                                    }
                                }
                                if choice.field == .title, let name = book.renameName {
                                    Text("将改为：\(name)", tableName: "MetadataExchange")
                                        .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)).textSelection(.enabled)
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
                            Text("封面", tableName: "MetadataExchange").font(.headline)
                            MetadataCoverComparison(book: book, option: nil)
                            Toggle(isOn: .constant(false)) { Text("采用新封面", tableName: "MetadataExchange").font(.body.weight(.semibold)) }.disabled(true)
                        }.padding(16).background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 17))
                        Text("包内图片缺失或无法读取，封面已跳过；其他信息可继续导入。这里只是预览，确认导入后才保存。", tableName: "MetadataExchange")
                            .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)).padding(.horizontal, 14)
                        if book.incomingCovers.isEmpty { MetadataCoverSources(paths: book.coverFiles) }
                    }
                }
            }.padding(20).frame(maxWidth: 620, alignment: .leading).frame(maxWidth: .infinity)
        }.themedPage().navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("metadataFieldDetails")
    }
    private func optionValue(_ option: MetadataOption, choice: MetadataFieldChoice) -> String {
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
                Text("封面", tableName: "MetadataExchange").font(.headline)
                ForEach(choice.options.filter { $0.cover != nil }) { option in
                    MetadataCoverComparison(book: book, option: option)
                }
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
            }.padding(16).background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 17))
            Text(same ? "封面相同，无需重复保存。" : "确认导入后才会保存。", tableName: "MetadataExchange")
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
                side(title: "当前封面", cover: book.base?.cover)
                side(title: "导入封面", cover: option?.cover, missing: unavailable)
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
            }.aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color(uiColor: theme.separator), style: StrokeStyle(lineWidth: 1, dash: missing ? [4, 3] : [])) }
        }.frame(maxWidth: 124).frame(maxWidth: .infinity)
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
