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
    var editPalette: ((PaletteDraft) -> Void)?
    var preservedPosition: Binding<String?>? = nil
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
            if reader && embedded { embeddedPalettes }
            else if embedded { paletteList }
            else {
                paletteList.navigationTitle(appearance == .light ? "浅色时的配色" : "深色时的配色")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(item: $draft) { value in PaletteEditor(draft: value) }
        .confirmationDialog("删除配色？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除并恢复默认配色", role: .destructive) {
                if let deleting { Task { await themes.deletePalette(deleting.id) } }
                deleting = nil
            }
        } message: { Text("使用此配色的应用槽位将恢复杏桃，阅读槽位将恢复跟随应用。") }
    }
    @ViewBuilder private var embeddedPalettes: some View {
        if let preservedPosition { paletteScrollContent.scrollPosition(id: preservedPosition, anchor: .top) }
        else { paletteScrollContent }
    }
    private var paletteScrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                textureSection.id("palette-textures")
                VStack(spacing: 0) {
                    sourceRow("跟随应用", id: "app", icon: "arrow.turn.down.right").padding(14)
                    ThemedDivider()
                    sourceRow("系统配色", id: "system", icon: "circle.lefthalf.filled").padding(14)
                }.background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 16))
                Text("预设").id("palette-presets").font(.headline).foregroundStyle(Color(uiColor: theme.secondary))
                VStack(spacing: 0) {
                    ForEach(palettes.filter { !$0.custom }, id: \.id) { palette in
                        paletteRow(palette).padding(.horizontal, 14).padding(.vertical, 6).id(palette.id)
                        if palette.id != palettes.last(where: { !$0.custom })?.id { ThemedDivider() }
                    }
                }.scrollTargetLayout().background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 16))
                Text("自定义").id("palette-custom").font(.headline).foregroundStyle(Color(uiColor: theme.secondary))
                VStack(spacing: 0) {
                    ForEach(palettes.filter(\.custom), id: \.id) { palette in
                        paletteRow(palette).padding(14).id(palette.id)
                            .contextMenu {
                                Button("编辑", systemImage: "pencil") { edit(PaletteDraft(palette: palette, creating: false)) }
                                Button("删除", systemImage: "trash", role: .destructive) { deleting = palette }
                            }
                        ThemedDivider()
                    }
                    Button("新建配色", systemImage: "plus") {
                        guard var base = palettes.first(where: { $0.id == selected }) ?? palettes.first else { return }
                        base.name = ""; base.custom = true
                        edit(PaletteDraft(palette: base, creating: true))
                    }.frame(maxWidth: .infinity, minHeight: LayoutTokens.hit).padding(6).id("palette-create").accessibilityIdentifier("createPalette")
                }.scrollTargetLayout().background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 16))
            }.scrollTargetLayout().padding(.horizontal, LayoutTokens.content).padding(.vertical, LayoutTokens.compact)
        }.pageScrollMargins().disabled(themes.saving).themedPage().accessibilityIdentifier("paletteOptions")
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
        VStack(alignment: .leading, spacing: 12) {
            Text("纸张纹理").font(.headline).foregroundStyle(Color(uiColor: theme.secondary))
            VStack(alignment: .leading, spacing: 18) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72))], spacing: 12) {
                    textureOption(nil)
                    ForEach(readerTextureIds(), id: \.self) { textureOption($0) }
                }.accessibilityIdentifier("readerTexture")
                Text("纹理强度").font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                Picker("纹理强度", selection: Binding(get: { texture?.strength ?? .medium }, set: { value in
                    guard var choice = texture else { return }
                    choice.strength = value; setTexture(choice)
                })) {
                    ForEach(readerTextureStrengths(), id: \.self) { value in Text(value.label).tag(value) }
                }.pickerStyle(.segmented).disabled(texture == nil).accessibilityIdentifier("readerTextureStrength")
            }.padding(14).background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 16))
                .disabled(previewTheme.plan.colors == nil)
            if previewTheme.plan.colors == nil {
                Text("请选择具体配色后使用纹理").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    .accessibilityIdentifier("readerTextureUnavailable")
            } else {
                Text("纹理与配色独立。选择保存在此设备。").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
            }
        }
    }
    private func textureOption(_ id: ReaderTextureId?) -> some View {
        let choice = id.map { readerTextureChoice(id: $0) }
        let surface = ThemeSurface(plan: previewTheme.plan, readerTexture: choice)
        let tile = choice.map { _ in ThemeSurface.paperTile(surface.paperInput(scale: 1)) }
        return Button {
            var next = choice
            if let strength = texture?.strength { next?.strength = strength }
            setTexture(next)
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Color(uiColor: surface.paper)
                    if let tile { Image(uiImage: tile).resizable(resizingMode: .tile) }
                }.frame(height: 50).clipShape(.rect(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color(uiColor: texture?.id == id ? theme.accent : theme.separator), lineWidth: texture?.id == id ? 2 : 1) }
                Text(id?.label ?? "无").font(.caption).foregroundStyle(Color(uiColor: theme.ink))
            }.frame(maxWidth: .infinity)
        }.buttonStyle(.plain).accessibilityIdentifier("readerTexture-\(id?.assetName ?? "none")")
            .accessibilityAddTraits(texture?.id == id ? .isSelected : [])
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
