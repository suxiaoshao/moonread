import SwiftUI

func paletteDisplayName(_ value: ThemePalette) -> String {
    if value.custom { return value.name }
    switch value.id.split(separator: "-").first {
    case "apricot": return String(localized: "纸色")
    case "mint": return String(localized: "薄荷")
    case "lilac": return String(localized: "雾紫")
    case "black": return String(localized: "纯黑夜间")
    case "white": return String(localized: "素白")
    case "bean": return String(localized: "竹绿")
    default: return value.name
    }
}

@MainActor @Observable final class PaletteDraft: Identifiable {
    let id = UUID()
    var palette: ThemePalette
    var error: String?
    let creating: Bool
    private let baseline: ThemePalette
    var saving = false
    private(set) var saved = false
    var hasUnsavedChanges: Bool { !saving && !saved && (creating || palette != baseline) }
    func markSaved() { saved = true }
    init(palette: ThemePalette, creating: Bool) { self.palette = palette; baseline = palette; self.creating = creating }
}

struct PalettePicker: View {
    let reader: Bool
    let appearance: ThemeAppearance
    var embedded = false
    var bottomContentInset: CGFloat = 0
    var editPalette: ((PaletteDraft) -> Void)?
    @Environment(ThemeStore.self) private var themes
    @Environment(\.theme) private var theme
    @State private var draft: PaletteDraft?
    @State private var deleting: ThemePalette?
    private var palettes: [ThemePalette] { themes.snapshot.palettes.filter { $0.appearance == appearance } }
    private var selected: String {
        let p = themes.snapshot.preferences
        if reader {
            switch appearance == .light ? p.readerLight : p.readerDark {
            case .app: return "app"
            case .system: return "system"
            case let .palette(id): return id
            }
        }
        switch appearance == .light ? p.appLight : p.appDark {
        case .system: return "system"
        case let .palette(id): return id
        }
    }
    private var previewTheme: ThemeSurface {
        var value = themes.snapshot
        if reader { value.preferences.readerMode = appearance == .light ? .light : .dark }
        else { value.preferences.appMode = appearance == .light ? .light : .dark }
        guard let plan = try? resolveThemes(value: value, system: themes.system, highContrast: themes.highContrast) else { return theme }
        return ThemeSurface(plan: reader ? plan.reader : plan.app, readerTexture: reader ? plan.readerTexture : nil)
    }
    var body: some View {
        Group {
            if embedded { paletteList }
            else {
                paletteList.navigationTitle(appearance == .light ? "浅色时的配色" : "深色时的配色")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(item: $draft) { value in PaletteEditor(draft: value) }
        .alert(Text("删除配色“\(deleting?.name ?? "")”？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { palette in
            Button("删除", role: .destructive) {
                Task { await themes.deletePalette(palette.id) }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { palette in
            if let message = themes.paletteDeletionImpact(palette.id).message { Text(message) }
        }
    }
    private var paletteList: some View {
        ThemedGroupedList(sections: paletteSections, theme: theme,
                          topInset: embedded ? LayoutTokens.compact : LayoutTokens.content,
                          bottomInset: bottomContentInset)
            .disabled(themes.saving).themedPage().accessibilityIdentifier("paletteOptions")
    }
    private var paletteSections: [ThemedGroupedList.Section] {
        var result: [ThemedGroupedList.Section] = []
        if !embedded {
            result.append(.init(id: "preview", rows: [.init("preview", clear: true) { PalettePreview(theme: previewTheme) }]))
        }
        if reader && previewTheme.readerTexture?.descriptor != nil {
            result.append(.init(id: "texture", title: String(localized: "纸张纹理"),
                                footer: String(localized: "此配色的纹理仅保存在此设备。"), rows: [
                .init("readerPaletteTexture") {
                    Toggle(isOn: Binding(get: { previewTheme.readerTexture?.enabled == true }, set: { enabled in
                        let id = previewTheme.plan.paletteId
                        themes.update { value in
                            if let updated = try? setReaderPaletteTexture(preferences: value, paletteId: id, enabled: enabled) { value = updated }
                        }
                    })) {
                        let name = themes.snapshot.palettes.first { $0.id == previewTheme.plan.paletteId }.map(paletteDisplayName) ?? ""
                        Text("显示\(name)纹理")
                    }.accessibilityIdentifier("readerPaletteTexture").disabled(themes.saving)
                }
            ]))
        }
        var sources: [ThemedGroupedList.Row] = []
        if reader { sources.append(.init("app", action: themes.saving ? nil : { choose("app") }) { sourceRow("跟随应用", id: "app", icon: "arrow.turn.down.right") }) }
        sources.append(.init("system", action: themes.saving ? nil : { choose("system") }) { sourceRow("系统配色", id: "system", icon: "circle.lefthalf.filled") })
        result.append(.init(id: "sources", rows: sources))
        result.append(.init(id: "presets", title: String(localized: "预设"), rows: palettes.filter { !$0.custom }.map(nativePaletteRow)))
        var custom = palettes.filter(\.custom).map(nativePaletteRow)
        let creationIssue = themes.paletteCreationIssue
        custom.append(ThemedGroupedList.Row("createPalette", action: themes.saving || creationIssue != nil ? nil : { createPalette() }) {
            Label("新建配色", systemImage: "plus")
                .foregroundStyle(Color(uiColor: themes.saving || creationIssue != nil ? theme.secondary : theme.accent))
                .disabled(themes.saving || creationIssue != nil)
        })
        result.append(.init(id: "custom", title: String(localized: "自定义"), footer: creationIssue?.errorDescription, rows: custom))
        return result
    }
    private func nativePaletteRow(_ palette: ThemePalette) -> ThemedGroupedList.Row {
        let actions: [ThemedGroupedList.Action] = palette.custom && !themes.saving ? [
            .init(title: String(localized: "删除"), symbol: "trash", destructive: true, perform: { deleting = palette }),
            .init(title: String(localized: "编辑"), symbol: "pencil", perform: { edit(PaletteDraft(palette: palette, creating: false)) })
        ] : []
        return .init("palette-" + palette.id, action: themes.saving ? nil : { choose(palette.id) }, actions: actions) {
            paletteRow(palette).disabled(themes.saving)
                .contextMenu {
                    if palette.custom && !themes.saving {
                        Button("编辑", systemImage: "pencil") { edit(PaletteDraft(palette: palette, creating: false)) }
                        Button("删除", systemImage: "trash", role: .destructive) { deleting = palette }
                    }
                }
        }
    }
    private func sourceRow(_ title: LocalizedStringKey, id: String, icon: String) -> some View {
        HStack { Label(title, systemImage: icon); Spacer(); check(id) }
            .foregroundStyle(Color(uiColor: themes.saving ? theme.secondary : theme.ink)).disabled(themes.saving)
    }
    private func createPalette() {
        guard !themes.saving, themes.paletteCreationIssue == nil,
              var base = palettes.first(where: { $0.id == selected }) ?? palettes.first else { return }
        base.name = ""; base.custom = true
        edit(PaletteDraft(palette: base, creating: true))
    }
    private func edit(_ value: PaletteDraft) {
        guard !themes.saving else { return }
        if let editPalette { editPalette(value) } else { draft = value }
    }
    private func paletteRow(_ value: ThemePalette) -> some View {
        HStack(spacing: LayoutTokens.control) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: UIColor(rgb: value.colors.paper)))
                Image(systemName: "text.alignleft").foregroundStyle(Color(uiColor: UIColor(rgb: value.colors.ink)))
            }.frame(width: 48, height: 48).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(uiColor: theme.separator), lineWidth: 1))
            Text(verbatim: paletteDisplayName(value)).foregroundStyle(Color(uiColor: theme.ink))
            Spacer()
            Circle().fill(Color(uiColor: UIColor(rgb: value.colors.accent))).frame(width: 16, height: 16)
            check(value.id)
        }.padding(.vertical, 4)
        .accessibilityIdentifier("palette-\(value.id)")
    }
    @ViewBuilder private func check(_ id: String) -> some View {
        if selected == id { Image(systemName: "checkmark").foregroundStyle(Color(uiColor: theme.accent)).accessibilityLabel("已选择") }
    }
    private func choose(_ id: String) {
        guard !themes.saving else { return }
        themes.update { p in
            if reader {
                let value: ReaderPaletteSource = id == "app" ? .app : id == "system" ? .system : .palette(id: id)
                if appearance == .light { p.readerLight = value } else { p.readerDark = value }
            } else {
                let value: AppPaletteSource = id == "system" ? .system : .palette(id: id)
                if appearance == .light { p.appLight = value } else { p.appDark = value }
            }
        }
    }
}
