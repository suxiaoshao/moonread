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
                  let connection = ai.providers.connections.first(where: { $0.id == selection.connectionID }),
                  AINativeCapabilities.supportsText(connection: connection, model: model),
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
    @State private var completePicker = false
    @State private var panel = false
    @State private var showing = false
    @State private var detent = PresentationDetent.medium
    @State private var saveFailed = false
    var body: some View {
        Button {
            if destination.purpose != nil { showing = true } else { completePicker = false; detent = .medium; panel = true }
        } label: {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title)
                    Spacer(minLength: 8)
                    Text(verbatim: summary).font(.subheadline).multilineTextAlignment(.trailing).foregroundStyle(Color(uiColor: theme.secondary))
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color(uiColor: theme.secondary)).accessibilityHidden(true)
                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
            } else {
                modelLabel(showsThinking: true).frame(maxWidth: destination.isDefault && !compact ? .infinity : nil, alignment: .trailing).contentShape(Rectangle())
            }
        }
            .buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.ink))
            .accessibilityHint(destination.purpose == nil ? "选择模型与思考强度" : "选择模型")
            .accessibilityIdentifier("openAIModelPanel" + (destination.purpose.map { "-" + $0.rawValue } ?? ""))
            // Let the system fit top settings rows and bottom reader controls.
            .popover(isPresented: $panel, arrowEdge: nil) {
                NavigationStack {
                    quickControls
                        .navigationTitle("模型与思考强度").navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            if !completePicker {
                                ToolbarItem(placement: .cancellationAction) {
                                    SystemToolbarButton("关闭", role: .close) { panel = false }
                                        .accessibilityIdentifier("closeAIModelPanel")
                                }
                            }
                        }
                        .navigationDestination(isPresented: $completePicker) {
                            AIModelPickerContent(destination: destination, detent: $detent, close: { panel = false }, isRoot: false)
                        }
                }
                // Both pages share one native host and its scrollable viewport.
                .frame(idealWidth: 360, idealHeight: 540)
                .presentationDetents([.medium, .large], selection: $detent)
                .presentationDragIndicator(.visible)
                .environment(ai).environment(\.theme, theme).preferredColorScheme(theme.scheme)
                .presentationBackground(Color(uiColor: theme.canvas))
                .onChange(of: ai.availability.isAvailable) { _, available in if !available { panel = false } }
            }
            .sheet(isPresented: $showing, onDismiss: { detent = .medium }) {
                AIModelPicker(destination: destination, detent: $detent).environment(ai).environment(\.theme, theme).preferredColorScheme(theme.scheme)
                    .presentationDetents([.medium, .large], selection: $detent).presentationDragIndicator(.visible)
                    .presentationBackground(Color(uiColor: theme.canvas))
            }
    }
    private var quickControls: some View {
        Form {
            Section {
                Button { completePicker = true } label: {
                    HStack {
                        modelLabel(showsThinking: false)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                    }.frame(maxWidth: .infinity).contentShape(.rect)
                }.buttonStyle(.plain).accessibilityIdentifier("openAIModelPicker")
                if let value = destination.selection(ai), let model = ai.providers.model(connectionID: value.connectionID, modelID: value.modelID), model.thinking.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("思考强度")
                            Spacer(minLength: 8)
                            Text(AIThinkingLabel.label(value.thinking ?? AIModelSelection.defaultThinking(model) ?? ""))
                                .foregroundStyle(Color(uiColor: theme.secondary))
                                .accessibilityIdentifier("aiThinkingLevel")
                        }
                        AIThinkingSlider(levels: model.thinking, selection: Binding(get: { destination.selection(ai)?.thinking ?? AIModelSelection.defaultThinking(model) ?? "" }, set: { effort in
                            var selection = value; selection.thinking = effort
                            Task { saveFailed = !(await destination.apply(selection, ai)) }
                        }))
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if destination.running(ai) { Text("本次选择将在下一次请求生效") }
                    if let value = destination.selection(ai), let connection = ai.providers.connections.first(where: { $0.id == value.connectionID }), ai.providers.isUsingChatGPTPlan(connection) {
                        Text("正在使用 ChatGPT 套餐")
                        Link("管理 ChatGPT 用量", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                            .foregroundStyle(Color(uiColor: theme.accent))
                    }
                    if saveFailed { Text("模型目录已变化，请重新选择。").foregroundStyle(Color(uiColor: theme.destructive)) }
                }.foregroundStyle(Color(uiColor: theme.secondary))
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
        }.themedPage().accessibilityIdentifier("aiModelQuickControls")
    }
    private var summary: String {
        guard let value = destination.selection(ai),
              let model = ai.providers.model(connectionID: value.connectionID, modelID: value.modelID) else { return String(localized: "未设置") }
        return model.name + (value.thinking.map { " · " + AIThinkingLabel.label($0) } ?? "")
    }
    private func modelLabel(showsThinking: Bool) -> some View {
        HStack(spacing: 6) {
            if let value = destination.selection(ai), let connection = ai.providers.connections.first(where: { $0.id == value.connectionID }), let model = ai.providers.model(value.modelID, in: connection) {
                AIProviderIcon(providerID: connection.catalogID)
                Text(verbatim: model.name).font(.subheadline.weight(.semibold))
                if showsThinking, let effort = value.thinking { Text(AIThinkingLabel.label(effort)).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary)) }
            } else { Image(systemName: "sparkles"); Text("选择模型") }
        }.padding(.horizontal, 4).frame(minHeight: 44)
    }
}
/// Shared filtering for conversation, default, task-draft and native-tool pickers.
@MainActor enum AIModelSearch {
    static func filter(_ models: [AIModelOption], query: String, connection: AIConnection, _ providers: AIConnectionService) -> [AIModelOption] {
        models.filter { providers.matches($0, in: connection, query: query) }
    }
    static func offered(_ connection: AIConnection, purpose: AIModelPurpose?, keeping current: AIModelSelection?, catalog: AIModelCatalog? = nil) -> [AIModelOption] {
        connection.models.map { catalog?.option($0, providerID: connection.catalogID, authentication: connection.authMethod) ?? $0 }.filter {
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
    @Environment(\.dismiss) private var dismiss
    let destination: AIModelPickerDestination
    @Binding var detent: PresentationDetent
    var body: some View {
        NavigationStack {
            AIModelPickerContent(destination: destination, detent: $detent, close: { dismiss() })
        }
        .onChange(of: ai.availability.isAvailable) { _, available in if !available { dismiss() } }
    }
}

private struct AIModelPickerContent: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    let destination: AIModelPickerDestination
    @Binding var detent: PresentationDetent
    let close: () -> Void
    var isRoot = true
    @State private var error = false
    @State private var adding = false
    @State private var saving = false
    @State private var query = ""
    @State private var searching = false
    private var current: AIModelSelection? { destination.selection(ai) }
    private func offered(_ connection: AIConnection) -> [AIModelOption] {
        AIModelSearch.offered(connection, purpose: destination.purpose, keeping: current, catalog: ai.providers.catalog)
    }
    private func shown(_ connection: AIConnection) -> [AIModelOption] {
        AIModelSearch.filter(offered(connection), query: query, connection: connection, ai.providers)
    }
    private var running: Bool { destination.running(ai) }
    var body: some View {
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
            .safeAreaInset(edge: .top, spacing: 0) {
                if let purpose = destination.purpose {
                    Button {
                        if ai.providers.setPurpose(purpose, selection: nil) { close() }
                        else { error = true }
                    } label: {
                        HStack {
                            Text("不使用"); Spacer()
                            if current == nil { Image(systemName: "checkmark").foregroundStyle(Color(uiColor: theme.accent)) }
                        }.padding().frame(maxWidth: .infinity)
                            .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 12))
                    }.buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.ink))
                        .padding(.horizontal, 20).padding(.vertical, 8).background(Color(uiColor: theme.canvas))
                        .accessibilityIdentifier("aiPurposeNone")
                }
            }
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
                if isRoot {
                    ToolbarItem(placement: .cancellationAction) { SystemToolbarButton("关闭", role: .close, action: close).accessibilityIdentifier("cancelAIModelPicker") }
                }
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
                if saved { close() }
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
