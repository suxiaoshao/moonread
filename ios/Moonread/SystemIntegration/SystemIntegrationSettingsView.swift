import AppIntents
import SwiftUI

struct SystemIntegrationSettingsView: View {
    let library: LibraryModel
    @Environment(\.theme) private var theme
    @State private var enabled = true
    @State private var excluded = Set<String>()
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                Toggle("在系统搜索中显示书籍", isOn: Binding(get: { enabled }, set: { save(enabled: $0, excluded: excluded) }))
                    .tint(Color(uiColor: theme.accent)).accessibilityIdentifier("systemSearchEnabled")
                NavigationLink {
                    Form {
                        ForEach(library.shelves, id: \.id) { shelf in
                            Toggle(shelf.builtin ? String(localized: "我的书架") : shelf.name,
                                isOn: Binding(get: { excluded.contains(shelf.id) }, set: { selected in
                                    var next = excluded
                                    if selected { next.insert(shelf.id) } else { next.remove(shelf.id) }
                                    save(enabled: enabled, excluded: next)
                                })).tint(Color(uiColor: theme.accent))
                        }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                    }.themedPage().navigationTitle("排除的书架").disabled(saving)
                } label: {
                    LabeledContent("排除的书架", value: String(localized: "\(excluded.count) 个书架"))
                }.accessibilityIdentifier("systemSearchExcludedShelves")
                if let error {
                    Text(verbatim: error).font(.footnote).foregroundStyle(Color(uiColor: theme.destructive))
                    Button("重试") { save(enabled: enabled, excluded: excluded) }
                }
            } header: { Text("系统搜索与建议") } footer: {
                Text("只使用已识别书籍的书名、作者和标签，不索引正文。读过的书可出现在系统续读建议中。排除书架不会影响在快捷指令或小组件中主动选书。")
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            Section {
                Text("可用“继续阅读”“打开书籍”和“查看阅读统计”；统计可回答今天或本周的阅读时长。")
                    .foregroundStyle(Color(uiColor: theme.secondary))
                ShortcutsLink()
            } header: { Text("Siri 与快捷指令") } footer: {
                Text("也可以在支持的控制中心、锁屏或操作按钮中添加“继续阅读”。")
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            Section {
                SystemReadingCard(book: SystemReadingWidgetModel.sample)
                    .frame(width: 150, height: 150).padding(16)
                    .foregroundStyle(Color(uiColor: theme.ink)).tint(Color(uiColor: theme.accent))
                    .background(Color(uiColor: theme.raised), in: .rect(cornerRadius: 20))
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .accessibilityLabel("小组件合成示例：月下归舟，42%")
                    .accessibilityIdentifier("systemWidgetPreview")
            } header: { Text("小组件") } footer: {
                Text("长按主屏幕或锁屏，添加月读小组件；待机沿用系统支持的布局。在小组件配置中选择最近阅读或指定书籍，默认显示书名和进度。")
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
        }
        .themedPage().navigationTitle("系统集成")
        .disabled(loading || saving)
        .overlay { if loading { ProgressView() } }
        .task {
            let policy = await library.service.systemExposurePolicy()
            enabled = policy.systemSearchEnabled; excluded = Set(policy.excludedShelfIDs)
            error = await library.service.systemReadingCatalogError(); loading = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .systemReadingCatalogChanged).receive(on: DispatchQueue.main)) { _ in
            Task { error = await library.service.systemReadingCatalogError() }
        }
    }
    private func save(enabled: Bool, excluded: Set<String>) {
        guard !saving else { return }
        self.enabled = enabled; self.excluded = excluded; saving = true; error = nil
        Task {
            defer { saving = false }
            do { await library.service.startSystemReadingCatalog(); try await library.service.setSystemSearch(enabled: enabled, excludedShelfIDs: Array(excluded)) }
            catch { self.error = ReaderMessages.error(error) }
            if error == nil { error = await library.service.systemReadingCatalogError() }
        }
    }
}
