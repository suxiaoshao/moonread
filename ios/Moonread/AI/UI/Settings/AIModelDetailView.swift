import SwiftUI

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
                    if model.isManual == true, model.capabilities?.text == nil {
                        Text("这是手填型号，将尝试通用文字请求；能力并未经目录确认。")
                            .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    } else if model.capabilities?.text == nil && model.capabilities?.imageOutput == nil {
                        Text("此型号已列出，能力资料尚未补齐；补齐前不会自动提供给对话或工具选择。")
                            .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    }
                    if model.isListed == false {
                        Text("此连接的目录未列出该型号，请刷新目录或重新选择。")
                            .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    }
                    if let raw = connection.models.first(where: { $0.id == modelID }), raw.isManual == true,
                       raw.contextWindow != model.contextWindow || raw.maxOutput != model.maxOutput {
                        Text("已保留你填写的预算；实际请求按预算与连接已知上限中的较小值使用。")
                            .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
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
                                if let context = limits.context { capacity(context, label: model.contextIsInputLimit == true ? "输入上限 · tokens" : "上下文 · tokens") }
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
                        .frame(maxWidth: .infinity).disabled(model.isListed == false || (!AINativeCapabilities.supportsText(connection: connection, model: model) && !AINativeCapabilities.supports(.image, connection: connection, model: model)))
                        .accessibilityIdentifier("applyAIModelDetail")
                }.padding([.horizontal, .top], 20).padding(.bottom).frame(maxWidth: .infinity, alignment: .leading)
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
                            ToolbarItem(placement: .cancellationAction) { SystemToolbarButton("取消", role: .cancel) { editingContextBudget = false } }
                            ToolbarItem(placement: .confirmationAction) {
                                SystemToolbarButton("保存", role: .confirm) {
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
