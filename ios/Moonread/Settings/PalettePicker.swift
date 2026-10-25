import SwiftUI

func paletteDisplayName(_ value: ThemePalette) -> String {
    if value.custom { return value.name }
    switch value.id.split(separator: "-").first {
    case "apricot": return String(localized: "杏桃")
    case "mint": return String(localized: "薄荷")
    case "lilac": return String(localized: "雾紫")
    case "black": return String(localized: "纯黑夜间")
    case "white": return String(localized: "素白")
    case "bean": return String(localized: "豆沙绿")
    default: return value.name
    }
}

struct PaletteDraft: Identifiable {
    let id = UUID()
    var palette: ThemePalette
    let creating: Bool
}

struct PalettePicker: View {
    let reader: Bool
    let appearance: ThemeAppearance
    var embedded = false
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
        return ThemeSurface(plan: reader ? plan.reader : plan.app)
    }
    var body: some View {
        Group {
            if embedded { paletteList }
            else {
                paletteList.navigationTitle(appearance == .light ? "浅色时的配色" : "深色时的配色")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(item: $draft) { value in PaletteEditor(initial: value.palette, creating: value.creating) }
        .confirmationDialog("删除配色？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除并恢复默认配色", role: .destructive) {
                if let deleting { Task { await themes.deletePalette(deleting.id) } }
                deleting = nil
            }
        } message: { Text("使用此配色的应用槽位将恢复杏桃，阅读槽位将恢复跟随应用。") }
    }
    private var paletteList: some View {
        List {
            if !embedded { Section {
                PalettePreview(theme: previewTheme).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            } }
            if reader && embedded { textureSection }
            Section {
                if reader { sourceRow("跟随应用", id: "app", icon: "arrow.turn.down.right") }
                sourceRow("系统配色", id: "system", icon: "circle.lefthalf.filled")
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            Section("预设") {
                ForEach(palettes.filter { !$0.custom }, id: \.id) { palette in paletteRow(palette) }
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            Section("自定义") {
                ForEach(palettes.filter(\.custom), id: \.id) { palette in
                    paletteRow(palette)
                        .contextMenu {
                            Button("编辑", systemImage: "pencil") { edit(PaletteDraft(palette: palette, creating: false)) }
                            Button("删除", systemImage: "trash", role: .destructive) { deleting = palette }
                        }
                        .swipeActions {
                            Button("删除", systemImage: "trash", role: .destructive) { deleting = palette }.tint(Color(uiColor: theme.destructive))
                            Button("编辑", systemImage: "pencil") { edit(PaletteDraft(palette: palette, creating: false)) }.tint(Color(uiColor: theme.accent))
                        }
                }
                Button("新建配色", systemImage: "plus") {
                    guard var base = palettes.first(where: { $0.id == selected }) ?? palettes.first else { return }
                    base.name = ""; base.custom = true
                    edit(PaletteDraft(palette: base, creating: true))
                }.accessibilityIdentifier("createPalette")
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
        }
        .disabled(themes.saving).themedPage()
        .contentMargins(.top, embedded ? LayoutTokens.compact : LayoutTokens.content, for: .scrollContent)
        .accessibilityIdentifier("paletteOptions")
    }
    private var texture: ReaderTextureChoice? {
        appearance == .light ? themes.snapshot.preferences.readerLightTexture : themes.snapshot.preferences.readerDarkTexture
    }
    private func setTexture(_ choice: ReaderTextureChoice?) {
        themes.update { value in
            if appearance == .light { value.readerLightTexture = choice } else { value.readerDarkTexture = choice }
        }
    }
    private var textureSection: some View {
        Section {
            Picker("纸张纹理", selection: Binding(get: { texture?.id }, set: { id in
                var choice = id.map { readerTextureChoice(id: $0) }
                if let strength = texture?.strength { choice?.strength = strength }
                setTexture(choice)
            })) {
                Text("无").tag(ReaderTextureId?.none)
                ForEach(readerTextureIds(), id: \.self) { id in Text(id.label).tag(Optional(id)) }
            }.accessibilityIdentifier("readerTexture")
            if let texture {
                Picker("纹理强度", selection: Binding(get: { texture.strength }, set: { value in
                    var choice = texture; choice.strength = value; setTexture(choice)
                })) {
                    ForEach(readerTextureStrengths(), id: \.self) { value in Text(value.label).tag(value) }
                }.accessibilityIdentifier("readerTextureStrength")
            }
        } footer: {
            if previewTheme.plan.colors == nil {
                Text("请选择具体配色后使用纹理").accessibilityIdentifier("readerTextureUnavailable")
            }
        }
        .disabled(previewTheme.plan.colors == nil)
        .listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
    }
    private func sourceRow(_ title: LocalizedStringKey, id: String, icon: String) -> some View {
        Button { choose(id) } label: {
            HStack { Label(title, systemImage: icon); Spacer(); check(id) }
        }.foregroundStyle(Color(uiColor: theme.ink))
    }
    private func edit(_ value: PaletteDraft) {
        if let editPalette { editPalette(value) } else { draft = value }
    }
    private func paletteRow(_ value: ThemePalette) -> some View {
        Button { choose(value.id) } label: {
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
        }.accessibilityIdentifier("palette-\(value.id)")
    }
    @ViewBuilder private func check(_ id: String) -> some View {
        if selected == id { Image(systemName: "checkmark").foregroundStyle(Color(uiColor: theme.accent)).accessibilityLabel("已选择") }
    }
    private func choose(_ id: String) {
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
