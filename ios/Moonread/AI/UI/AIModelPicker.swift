import SwiftUI

struct AIProviderIcon: View {
    @Environment(\.theme) private var theme
    var providerID: String? = nil
    private var asset: String? { providerID.flatMap { AIProviderBrand.asset(providerID: $0) } }
    var body: some View {
        Group {
            if let asset { Image(asset).resizable().scaledToFit() }
            else { Image(systemName: "sparkles").resizable().scaledToFit() }
        }.foregroundStyle(Color(uiColor: theme.accent)).frame(width: 22, height: 22).accessibilityHidden(true)
    }
}
/// Where a picker reads and writes: a stored target, or a form's local draft
/// (a quick task before Start has no session to write to).
enum AIModelPickerDestination {
    case target(AIModelSelectionTarget)
    case draft(Binding<AIModelSelection?>)
    case purpose(AIModelPurpose)
    @MainActor func selection(_ ai: AIService) -> AIModelSelection? {
        switch self {
        case .target(let target): return ai.modelSelection(for: target)
        case .draft(let value): return value.wrappedValue
        case .purpose(let purpose):
            return ai.providers.purposeDefaults[purpose].map {
                AIModelSelection(connectionID: $0.connectionID, modelID: $0.modelID, thinking: nil)
            }
        }
    }
    @MainActor func apply(_ selection: AIModelSelection, _ ai: AIService) async -> Bool {
        switch self {
        case .target(let target): return await ai.applyModelSelection(selection, to: target)
        case .purpose(let purpose):
            return ai.providers.setPurpose(purpose, selection: .init(connectionID: selection.connectionID, modelID: selection.modelID))
        case .draft(let value):
            guard let model = ai.providers.model(connectionID: selection.connectionID, modelID: selection.modelID),
                  model.capabilities?.text != false,
                  selection.thinking.map(model.thinking.contains) ?? true else { return false }
            value.wrappedValue = selection; return true
        }
    }
    @MainActor func running(_ ai: AIService) -> Bool {
        switch self {
        case .target(.conversation(let id)), .target(.session(let id)): return ai.conversation(id)?.running == true
        default: return false
        }
    }
    var isDefault: Bool { if case .target(let target) = self { target.isDefault } else { false } }
    var purpose: AIModelPurpose? { if case .purpose(let purpose) = self { purpose } else { nil } }
}
/// Shared controls write only to their caller's selection target.
struct AIModelPickerButton: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    let destination: AIModelPickerDestination
    var compact = false
    var title: LocalizedStringKey?
    init(target: AIModelSelectionTarget, compact: Bool = false, title: LocalizedStringKey? = nil) {
        destination = .target(target); self.compact = compact; self.title = title
    }
    init(draft: Binding<AIModelSelection?>) { destination = .draft(draft) }
    init(purpose: AIModelPurpose, title: LocalizedStringKey? = nil) { destination = .purpose(purpose); self.title = title }
    @State private var panel = false
    @State private var showing = false
    @State private var detent = PresentationDetent.medium
    @State private var saveFailed = false
    var body: some View {
        Button {
            if destination.purpose != nil { showing = true } else { panel = true }
        } label: {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title)
                    Spacer(minLength: 8)
                    Text(verbatim: summary).font(.subheadline).multilineTextAlignment(.trailing).foregroundStyle(Color(uiColor: theme.secondary))
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color(uiColor: theme.secondary)).accessibilityHidden(true)
                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
            } else {
                modelLabel.frame(maxWidth: destination.isDefault && !compact ? .infinity : nil, alignment: .trailing).contentShape(Rectangle())
            }
        }
            .buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.ink))
            .accessibilityHint(destination.purpose == nil ? "选择模型与思考强度" : "选择模型")
            .accessibilityIdentifier("openAIModelPanel" + (destination.purpose.map { "-" + $0.rawValue } ?? ""))
            // Let the system fit top settings rows and bottom reader controls.
            .popover(isPresented: $panel, arrowEdge: nil) {
                VStack(spacing: 8) {
                    Button { panel = false; showing = true } label: {
                        HStack { modelLabel; Image(systemName: "chevron.right").font(.caption) }
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.plain).accessibilityIdentifier("openAIModelPicker")
                    if let value = destination.selection(ai), let model = ai.providers.model(connectionID: value.connectionID, modelID: value.modelID), model.thinking.count > 1 {
                        AIThinkingSlider(levels: model.thinking, selection: Binding(get: { destination.selection(ai)?.thinking ?? AIModelSelection.defaultThinking(model) ?? "" }, set: { effort in
                            var selection = value; selection.thinking = effort
                            Task { saveFailed = !(await destination.apply(selection, ai)) }
                        }))
                    }
                    if destination.running(ai) {
                        Text("本次选择将在下一次请求生效").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                    }
                    if let value = destination.selection(ai), let connection = ai.providers.connections.first(where: { $0.id == value.connectionID }), ai.providers.isUsingChatGPTPlan(connection) {
                        Text("正在使用 ChatGPT 套餐").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                        Link("管理 ChatGPT 用量", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                            .font(.caption).foregroundStyle(Color(uiColor: theme.accent))
                    }
                    if saveFailed { Text("模型目录已变化，请重新选择。").font(.caption).foregroundStyle(Color(uiColor: theme.destructive)) }
                }.padding(16).frame(width: 290).foregroundStyle(Color(uiColor: theme.ink))
                    .tint(Color(uiColor: theme.accent))
                    .background(Color(uiColor: theme.surface))
                    .environment(\.theme, theme).preferredColorScheme(theme.scheme)
                    .presentationBackground(Color(uiColor: theme.surface))
                    .presentationCompactAdaptation(.popover)
            }
            .sheet(isPresented: $showing, onDismiss: { detent = .medium }) {
                AIModelPicker(destination: destination, detent: $detent).environment(ai).environment(\.theme, theme).preferredColorScheme(theme.scheme)
                    .presentationDetents([.medium, .large], selection: $detent).presentationDragIndicator(.visible)
                    .presentationBackground(Color(uiColor: theme.canvas))
            }
    }
    private var summary: String {
        guard let value = destination.selection(ai),
              let model = ai.providers.model(connectionID: value.connectionID, modelID: value.modelID) else { return String(localized: "未设置") }
        return model.name + (value.thinking.map { " · " + AIThinkingLabel.label($0) } ?? "")
    }
    private var modelLabel: some View {
        HStack(spacing: 6) {
            if let value = destination.selection(ai), let connection = ai.providers.connections.first(where: { $0.id == value.connectionID }), let model = ai.providers.model(value.modelID, in: connection) {
                AIProviderIcon(providerID: connection.catalogID)
                Text(verbatim: model.name).font(.subheadline.weight(.semibold))
                if let effort = value.thinking { Text(AIThinkingLabel.label(effort)).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary)) }
            } else { Image(systemName: "sparkles"); Text("选择模型") }
        }.padding(.horizontal, 4).frame(minHeight: 44)
    }
}
/// Shared filtering for conversation, default, task-draft and native-tool pickers.
@MainActor enum AIModelSearch {
    static func filter(_ models: [AIModelOption], query: String, connection: AIConnection, _ providers: AIConnectionService) -> [AIModelOption] {
        models.filter { providers.matches($0, in: connection, query: query) }
    }
    static func offered(_ connection: AIConnection, purpose: AIModelPurpose?, keeping current: AIModelSelection?) -> [AIModelOption] {
        connection.models.filter {
            AIModelAvailability.supports($0, purpose: purpose, connection: connection)
                || (current?.connectionID == connection.id && current?.modelID == $0.id)
        }
    }
    /// Names only identify a row unless the same connection repeats them.
    static func duplicateNames(_ models: [AIModelOption]) -> Set<String> {
        Set(Dictionary(grouping: models, by: \.name).filter { $0.value.count > 1 }.keys)
    }
}
/// One selectable model row: name, plus ID only for same-connection name collisions.
struct AIModelRowLabel: View {
    @Environment(\.theme) private var theme
    let model: AIModelOption
    let duplicate: Bool
    let disabled: Bool
    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.name)
                if duplicate { Text(verbatim: model.id).font(.caption).foregroundStyle(Color(uiColor: theme.secondary)) }
            }
            Spacer(minLength: 0)
            if disabled { Text("未启用").font(.caption).foregroundStyle(Color(uiColor: theme.secondary)) }
        }
        // One element, so the row's identifier is not copied onto each text.
        .accessibilityElement(children: .combine)
    }
}
struct AIModelPicker: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let destination: AIModelPickerDestination
    @Binding var detent: PresentationDetent
    @State private var error = false
    @State private var adding = false
    @State private var saving = false
    @State private var query = ""
    @State private var searching = false
    private var current: AIModelSelection? { destination.selection(ai) }
    private func offered(_ connection: AIConnection) -> [AIModelOption] {
        AIModelSearch.offered(connection, purpose: destination.purpose, keeping: current)
    }
    private func shown(_ connection: AIConnection) -> [AIModelOption] {
        AIModelSearch.filter(offered(connection), query: query, connection: connection, ai.providers)
    }
    private var running: Bool { destination.running(ai) }
    var body: some View {
        NavigationStack {
            Group {
                if ai.providers.connections.allSatisfy({ offered($0).isEmpty }) {
                    ContentUnavailableView {
                        Label("还没有可用模型", systemImage: "sparkles")
                    } description: { Text("先连接一个 AI 账户并加载模型。") } actions: {
                        Button("添加连接", systemImage: "plus") { adding = true }.accessibilityIdentifier("aiModelPickerSettings")
                    }
                } else if ai.providers.connections.allSatisfy({ shown($0).isEmpty }) {
                    ContentUnavailableView {
                        Label("没有匹配的模型", systemImage: "magnifyingglass")
                    } description: { Text("试试其他搜索词。") } actions: {
                        Button("清除搜索") { query = ""; searching = false }
                    }
                } else {
                    List {
                        if let purpose = destination.purpose {
                            Button {
                                if ai.providers.setPurpose(purpose, selection: nil) { dismiss() }
                                else { error = true }
                            } label: {
                                HStack {
                                    Text("不使用"); Spacer()
                                    if current == nil { Image(systemName: "checkmark").foregroundStyle(Color(uiColor: theme.accent)) }
                                }
                            }.buttonStyle(.plain).listRowBackground(Color(uiColor: theme.surface)).accessibilityIdentifier("aiPurposeNone")
                        }
                        ForEach(ai.providers.connections) { connection in
                            let models = shown(connection)
                            if !models.isEmpty {
                                let duplicates = AIModelSearch.duplicateNames(offered(connection))
                                Section {
                                    ForEach(models) { model in modelRow(model, connection: connection, duplicate: duplicates.contains(model.name)) }
                                } header: { AIConnectionHeader(connection: connection) }
                                    .listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                            }
                        }
                    }
                }
            }.listStyle(.insetGrouped).themedPage().accessibilityIdentifier("aiModelList")
                .searchable(text: $query, isPresented: $searching, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("搜索"))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onChange(of: searching) { _, active in if active { detent = .large } }
                .aiAddConnectionFlow(isPresented: $adding)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if running || error {
                        VStack(spacing: 8) {
                            if running { Text("本次选择将在下一次请求生效") }
                            if error { Text("模型目录已变化，请重新选择。").foregroundStyle(Color(uiColor: theme.destructive)) }
                        }.font(.footnote).padding(16).frame(maxWidth: .infinity).background(Color(uiColor: theme.canvas))
                    }
                }
                .navigationTitle(destination.purpose?.title ?? String(localized: "选择模型")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.accessibilityIdentifier("cancelAIModelPicker") }
                }
                .onChange(of: ai.availability.isAvailable) { _, available in if !available { dismiss() } }
        }
    }
    private func modelRow(_ model: AIModelOption, connection: AIConnection, duplicate: Bool) -> some View {
        let reason = AIModelAvailability.reason(model, purpose: destination.purpose, connection: connection, providers: ai.providers)
        let selected = current?.connectionID == connection.id && current?.modelID == model.id
        return Button {
            guard !saving, AIModelAvailability.reason(model, purpose: destination.purpose, connection: connection, providers: ai.providers) == nil else { return }
            saving = true
            var value = current ?? AIModelSelection(connectionID: "", modelID: "", thinking: nil)
            value.select(model, connection: connection)
            Task {
                let saved = await destination.apply(value, ai)
                saving = false; error = !saved
                if saved { dismiss() }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    AIModelRowLabel(model: model, duplicate: duplicate, disabled: false)
                    if let reason { Text(reason).font(.caption).foregroundStyle(Color(uiColor: theme.secondary)) }
                }
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").foregroundStyle(Color(uiColor: theme.accent)) }
            }.frame(minHeight: 44).contentShape(.rect).foregroundStyle(Color(uiColor: reason == nil ? theme.ink : theme.secondary))
        }.buttonStyle(.plain).disabled(reason != nil || saving)
            .accessibilityAddTraits(selected ? .isSelected : []).accessibilityIdentifier("aiModel-\(connection.id)-\(model.id)")
    }
}
/// Connection identity shared by model lists: icon, name, billing.
struct AIConnectionHeader: View {
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    let connection: AIConnection
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
            HStack(spacing: 8) { AIProviderIcon(providerID: connection.catalogID); Text(connection.name) }
            if !typeSize.isAccessibilitySize { Spacer() }
            Text(Self.billing(connection.billing)).font(.caption)
        }.foregroundStyle(Color(uiColor: theme.secondary))
    }
    static func billing(_ value: AIBilling) -> LocalizedStringKey {
        switch value { case .subscription: "订阅账户"; case .usage: "API 额度"; case .mixed: "混合额度"; case .unknown: "额度来源未指定" }
    }
}

/// Keep protocol values intact; localize only familiar display labels.
enum AIThinkingLabel {
    static func label(_ value: String) -> String {
        switch value {
        case "none": String(localized: "关闭")
        case "minimal": String(localized: "极低")
        case "low": String(localized: "低")
        case "medium": String(localized: "中")
        case "high": String(localized: "高")
        case "xhigh": String(localized: "极高")
        case "max": String(localized: "最高")
        case "ultra": String(localized: "极致")
        default: value
        }
    }
}
/// System slider handles tracking, discrete steps and accessibility.
struct AIThinkingSlider: View {
    @Environment(\.theme) private var theme
    let levels: [String]
    @Binding var selection: String
    @State private var feedbackChange = 0

    static func index(_ value: Double, count: Int) -> Int {
        max(0, min(max(0, count - 1), Int(value.rounded())))
    }

    private var value: Binding<Double> {
        Binding(get: { Double(levels.firstIndex(of: selection) ?? 0) }, set: { value in
            guard !levels.isEmpty else { return }
            let next = levels[Self.index(value, count: levels.count)]
            guard next != selection else { return }
            selection = next
            feedbackChange += 1
        })
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                Slider(value: value, in: 0...Double(max(1, levels.count - 1)), step: 1) {
                    Text("思考强度")
                } tick: { SliderTick($0) }
            } else {
                Slider(value: value, in: 0...Double(max(1, levels.count - 1)), step: 1) {
                    Text("思考强度")
                }
            }
        }
        .tint(Color(uiColor: theme.accent))
        .disabled(levels.count < 2)
        .accessibilityIdentifier("aiThinkingSlider")
        .accessibilityValue(AIThinkingLabel.label(selection))
        .sensoryFeedback(.selection, trigger: feedbackChange)
        .frame(minHeight: 44)
    }
}

struct AIModelDetailView: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let connectionID: String
    let modelID: String
    var target: AIModelSelectionTarget = .defaults
    var initialSelection: AIModelSelection?
    var onUse: ((AIModelSelection) -> Bool)?
    @State private var selection: AIModelSelection?
    @State private var initialized = false
    @State private var error = false
    @State private var editingContextBudget = false
    @State private var contextBudget = ""
    @State private var invalidContextBudget = false
    private var connection: AIConnection? { ai.providers.connections.first { $0.id == connectionID } }
    private var model: AIModelOption? { connection.flatMap { ai.providers.model(modelID, in: $0) } }
    var body: some View {
        ScrollView {
            if let connection, let model {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 14) {
                        AIProviderIcon(providerID: connection.catalogID).scaleEffect(1.5).frame(width: 38, height: 38)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: model.name).font(.title2.weight(.semibold))
                            if model.id != model.name {
                                Button { UIPasteboard.general.string = model.id } label: {
                                    Label(model.id, systemImage: "doc.on.doc").font(.caption)
                                }.buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.secondary))
                                    .accessibilityLabel(Text("复制模型 ID"))
                            }
                            Text(verbatim: connection.name).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) { status(connection) }.fixedSize(horizontal: true, vertical: false)
                                VStack(alignment: .leading, spacing: 6) { status(connection) }
                            }.font(.caption.weight(.semibold))
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("能力").font(.headline)
                        let data = ai.providers.catalog.resolve(model, providerID: connection.catalogID, authentication: connection.authMethod).capabilities
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 24) {
                            capability("文字对话", symbol: "bubble.left.and.bubble.right", supported: data.text == true)
                            capability("图片输入", symbol: "photo", supported: data.imageInput == true)
                            capability("深度思考", symbol: "brain", supported: data.reasoning == true)
                            capability("图片生成", symbol: "photo.badge.plus", supported: data.imageOutput == true)
                            capability("工具调用", symbol: "wrench", supported: data.tools == true)
                            capability("结构化输出", symbol: "list.bullet.rectangle", supported: data.structured == true)
                        }.padding(.vertical, 22).padding(.horizontal, 12)
                            .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 22))
                    }
                    if let selection, !model.thinking.isEmpty {
                        VStack(spacing: 8) {
                            HStack { Text("思考程度").font(.headline); Spacer(); Text(AIThinkingLabel.label(selection.thinking ?? "")).foregroundStyle(Color(uiColor: theme.accent)) }
                            if model.thinking.count > 1 {
                                AIThinkingSlider(levels: model.thinking, selection: Binding(get: { self.selection?.thinking ?? "" }, set: { self.selection?.thinking = $0 }))
                                HStack { Text(AIThinkingLabel.label(model.thinking.first!)); Spacer(); Text(AIThinkingLabel.label(model.thinking.last!)) }.font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                            }
                        }
                    }
                    let limits = ai.providers.catalog.resolve(model, providerID: connection.catalogID, authentication: connection.authMethod)
                    if connection.authMethod == .chatGPT, model.contextWindow == nil || model.isManual == true {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("账户目录未提供容量，请按服务说明填写").font(.subheadline)
                            Text("这是你配置的上下文预算，不代表服务端确认的模型上限。")
                                .font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                            Button("编辑上下文预算") {
                                contextBudget = model.contextWindow.map(String.init) ?? ""
                                invalidContextBudget = false; editingContextBudget = true
                            }.accessibilityIdentifier("editChatGPTContextBudget")
                        }
                    }
                    if limits.context != nil || limits.output != nil {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("容量").font(.headline)
                            HStack(spacing: 16) {
                                if let context = limits.context { capacity(context, label: "上下文 · tokens") }
                                if let output = limits.output { capacity(output, label: "最大输出 · tokens") }
                            }.padding(20).frame(maxWidth: .infinity)
                                .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 22))
                        }
                    }
                    if error { Text("模型目录已变化，请重新选择。").font(.caption).foregroundStyle(Color(uiColor: theme.destructive)) }
                    Button {
                        guard let selection else { return }
                        // Explicitly using a model is also choosing to offer it again.
                        let enable = { ai.providers.setModels([modelID], enabled: true, connectionID: connectionID) }
                        if let onUse { error = !onUse(selection); if !error { enable() } }
                        else if model.capabilities?.text == false && model.capabilities?.imageOutput == true {
                            error = !ai.providers.setPurpose(.image, selection: .init(connectionID: connectionID, modelID: modelID))
                            if !error { enable(); dismiss() }
                        }
                        else { Task { if await ai.applyModelSelection(selection, to: target) { enable(); dismiss() } else { error = true } } }
                    } label: { Text("使用此模型").frame(maxWidth: .infinity).padding(.vertical, 6) }
                        .buttonStyle(.borderedProminent).tint(Color(uiColor: theme.accent)).foregroundStyle(Color(uiColor: theme.onAccent))
                        .frame(maxWidth: .infinity).accessibilityIdentifier("applyAIModelDetail")
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            } else { ContentUnavailableView("模型不可用", systemImage: "sparkles") }
        }.accessibilityIdentifier("aiModelDetails").themedPage().navigationTitle("模型详情").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard !initialized, let connection, let model else { return }
                var value = initialSelection ?? ai.modelSelection(for: target) ?? AIModelSelection(connectionID: connectionID, modelID: modelID, thinking: nil)
                value.select(model, connection: connection); selection = value; initialized = true
            }
            .sheet(isPresented: $editingContextBudget) {
                NavigationStack {
                    Form {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("上下文 · tokens", text: $contextBudget).keyboardType(.numberPad)
                                    .accessibilityIdentifier("chatGPTContextBudget")
                                if invalidContextBudget { Label("请填写正整数。", systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)) }
                            }
                        } footer: {
                            Text("账户目录未提供容量，请按服务说明填写。这是你配置的上下文预算，不代表服务端确认的模型上限。")
                        }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                    }.themedPage().navigationTitle("上下文预算")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("取消") { editingContextBudget = false } }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("保存") {
                                    invalidContextBudget = !ai.providers.setChatGPTContextBudget(connectionID: connectionID, modelID: modelID, value: contextBudget)
                                    if !invalidContextBudget { editingContextBudget = false }
                                }.accessibilityIdentifier("saveChatGPTContextBudget")
                            }
                        }
                }
            }
    }
    @ViewBuilder private func status(_ connection: AIConnection) -> some View {
        Text(ai.providers.isLoggedIn(connection) ? "已连接" : "尚未连接").foregroundStyle(Color(uiColor: theme.secondary))
        if ai.modelSelection(for: target)?.connectionID == connectionID && ai.modelSelection(for: target)?.modelID == modelID { Text("正在使用").foregroundStyle(Color(uiColor: theme.accent)) }
    }
    private func capacity(_ value: Int, label: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Text(value.formatted(.number.notation(.compactName).precision(.significantDigits(2...4)))).font(.title.weight(.semibold)).minimumScaleFactor(0.7).lineLimit(1)
            Text(label).font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
        }.frame(maxWidth: .infinity)
    }
    private func capability(_ title: LocalizedStringKey, symbol: String, supported: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Color(uiColor: supported ? theme.accent : theme.secondary))
            Text(title).font(.subheadline).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).opacity(supported ? 1 : 0.45)
            .accessibilityElement(children: .combine)
            .accessibilityValue(Text(supported ? "支持" : "不支持"))
    }
}
