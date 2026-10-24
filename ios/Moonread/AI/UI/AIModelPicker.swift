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
    @MainActor func selection(_ ai: AIService) -> AIModelSelection? {
        switch self {
        case .target(let target): return ai.modelSelection(for: target)
        case .draft(let value): return value.wrappedValue
        }
    }
    @MainActor func apply(_ selection: AIModelSelection, _ ai: AIService) async -> Bool {
        switch self {
        case .target(let target): return await ai.applyModelSelection(selection, to: target)
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
}
/// Shared controls write only to their caller's selection target.
struct AIModelPickerButton: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    let destination: AIModelPickerDestination
    init(target: AIModelSelectionTarget) { destination = .target(target) }
    init(draft: Binding<AIModelSelection?>) { destination = .draft(draft) }
    @State private var panel = false
    @State private var showing = false
    @State private var detent = PresentationDetent.medium
    @State private var saveFailed = false
    var body: some View {
        Button { panel = true } label: {
            modelLabel.frame(maxWidth: destination.isDefault ? .infinity : nil, alignment: .trailing).contentShape(Rectangle())
        }
            .buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.ink))
            .accessibilityHint("选择模型与思考强度").accessibilityIdentifier("openAIModelPanel")
            .popover(isPresented: $panel, arrowEdge: .bottom) {
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
                        Text("本次选择将在下一次请求生效").font(.caption)
                    }
                    if let value = destination.selection(ai), let connection = ai.providers.connections.first(where: { $0.id == value.connectionID }), ai.providers.isUsingChatGPTPlan(connection) {
                        Text("正在使用 ChatGPT 套餐").font(.caption)
                        Link("管理 ChatGPT 用量", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                            .font(.caption).foregroundStyle(Color(uiColor: theme.accent))
                    }
                    if saveFailed { Text("模型目录已变化，请重新选择。").font(.caption).foregroundStyle(Color(uiColor: theme.destructive)) }
                }.padding(16).frame(width: 290).foregroundStyle(Color(uiColor: theme.ink))
                    .background(Color(uiColor: theme.canvas))
                    .presentationCompactAdaptation(.popover)
            }
            .sheet(isPresented: $showing, onDismiss: { detent = .medium }) {
                AIModelPicker(destination: destination, detent: $detent).environment(ai).environment(\.theme, theme).preferredColorScheme(theme.scheme)
                    .presentationDetents([.medium, .large], selection: $detent).presentationDragIndicator(.visible)
            }
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
private struct AIModelChoice: Hashable {
    let connectionID: String
    let modelID: String
}
/// Selection lists offer enabled models plus the target's existing value, which stays usable.
@MainActor enum AIModelSearch {
    static func filter(_ models: [AIModelOption], query: String, connection: AIConnection, _ providers: AIConnectionService) -> [AIModelOption] {
        models.filter { providers.matches($0, in: connection, query: query) }
    }
    static func offered(_ models: [AIModelOption], in connection: AIConnection, keeping current: String?, _ providers: AIConnectionService) -> [AIModelOption] {
        models.filter { providers.isEnabled(modelID: $0.id, in: connection) || $0.id == current }
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
    @State private var draft: AIModelSelection?
    @State private var current: AIModelSelection?
    @State private var initialized = false
    @State private var error = false
    @State private var adding = false
    @State private var query = ""
    @State private var searching = false
    private func eligible(_ connection: AIConnection) -> [AIModelOption] {
        connection.models.filter { model in model.capabilities?.text != false }
    }
    private func offered(_ connection: AIConnection) -> [AIModelOption] {
        AIModelSearch.offered(eligible(connection), in: connection, keeping: current?.connectionID == connection.id ? current?.modelID : nil, ai.providers)
    }
    private func shown(_ connection: AIConnection) -> [AIModelOption] {
        AIModelSearch.filter(offered(connection), query: query, connection: connection, ai.providers)
    }
    private var selectedModel: AIModelOption? {
        guard let draft else { return nil }
        return ai.providers.model(connectionID: draft.connectionID, modelID: draft.modelID)
    }
    private var running: Bool { destination.running(ai) }
    var body: some View {
        NavigationStack {
            List {
                if ai.providers.connections.allSatisfy({ eligible($0).isEmpty }) {
                    ContentUnavailableView("还没有可用模型", systemImage: "sparkles", description: Text("先连接一个 AI 账户并加载模型。")).listRowBackground(Color.clear)
                    Button("添加连接", systemImage: "plus") { adding = true }.accessibilityIdentifier("aiModelPickerSettings").listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                } else if ai.providers.connections.allSatisfy({ offered($0).isEmpty }) {
                    ContentUnavailableView("没有启用的模型", systemImage: "sparkles").listRowBackground(Color.clear)
                    Section {
                        ForEach(ai.providers.connections.filter { !eligible($0).isEmpty }) { connection in
                            NavigationLink { AIConnectionView(connectionID: connection.id, startsEditingModels: true) } label: {
                                Label { Text("管理模型 · \(connection.name)") } icon: { AIProviderIcon(providerID: connection.catalogID) }
                            }.accessibilityIdentifier("manageAIModels-\(connection.id)")
                        }
                    }.listRowBackground(Color(uiColor: theme.surface))
                } else if ai.providers.connections.allSatisfy({ shown($0).isEmpty }) {
                    ContentUnavailableView.search(text: query).listRowBackground(Color.clear)
                } else {
                    Picker("选择模型", selection: Binding<AIModelChoice?>(get: {
                        draft.map { AIModelChoice(connectionID: $0.connectionID, modelID: $0.modelID) }
                    }, set: { choice in
                        guard let choice, let connection = ai.providers.connections.first(where: { $0.id == choice.connectionID }),
                              let model = ai.providers.model(choice.modelID, in: connection) else { return }
                        var value = draft ?? AIModelSelection(connectionID: "", modelID: "", thinking: nil)
                        value.select(model, connection: connection); draft = value; error = false
                        // Active search hides the bar's Cancel/Done; a choice ends the search.
                        searching = false
                    })) {
                        ForEach(ai.providers.connections) { connection in
                            let models = shown(connection)
                            if !models.isEmpty {
                                let duplicates = AIModelSearch.duplicateNames(offered(connection))
                                Section {
                                    ForEach(models) { model in
                                        let choice = AIModelChoice(connectionID: connection.id, modelID: model.id)
                                        AIModelRowLabel(model: model, duplicate: duplicates.contains(model.name),
                                                        disabled: !ai.providers.isEnabled(modelID: model.id, in: connection))
                                            .tag(Optional(choice)).id(choice)
                                            .accessibilityIdentifier("aiModel-\(connection.id)-\(model.id)")
                                    }
                                } header: { AIConnectionHeader(connection: connection) }
                            }
                        }
                    }.pickerStyle(.inline).labelsHidden().listRowBackground(Color(uiColor: theme.surface))
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
                .navigationTitle("选择模型").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { Text("选择模型").font(.headline).foregroundStyle(Color(uiColor: theme.ink)) }
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.accessibilityIdentifier("cancelAIModelPicker") }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            guard let draft else { error = true; return }
                            Task { if await destination.apply(draft, ai) { dismiss() } else { error = true } }
                        }.disabled(selectedModel == nil).accessibilityIdentifier("applyAIModelPicker")
                    }
                }
        }.onAppear {
            if !initialized { current = destination.selection(ai); draft = current; initialized = true }
        }
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
                            TextField("上下文 · tokens", text: $contextBudget).keyboardType(.numberPad)
                                .accessibilityIdentifier("chatGPTContextBudget")
                            Text("账户目录未提供容量，请按服务说明填写")
                            Text("这是你配置的上下文预算，不代表服务端确认的模型上限。")
                                .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                            if invalidContextBudget { Text("请填写正整数。").foregroundStyle(Color(uiColor: theme.destructive)) }
                        }.listRowBackground(Color(uiColor: theme.surface))
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
