import SwiftUI

private let typographyControls = readerTypographyControls()

private extension ReaderNumberControl {
    var range: ClosedRange<Double> { minimum...maximum }
}

struct ReaderQuickSettings: View {
    @Binding var settings: ReaderSettings
    let showMore: () -> Void
    @Environment(ThemeStore.self) private var themes
    @Environment(\.theme) private var theme
    private var appearance: ThemeAppearance { themes.reader.plan.appearance }
    private var selected: ReaderPaletteSource {
        appearance == .light ? themes.snapshot.preferences.readerLight : themes.snapshot.preferences.readerDark
    }
    var body: some View {
        VStack(spacing: LayoutTokens.compact) {
            HStack {
                Text("阅读设置").font(.subheadline.weight(.medium))
                Spacer()
                Button(action: showMore) {
                    HStack(spacing: 4) { Text("更多"); Image(systemName: "chevron.right").font(.caption) }
                        .frame(minHeight: LayoutTokens.hit)
                }.font(.subheadline)
                    .accessibilityIdentifier("moreReadingSettings")
            }
            Stepper("字号 · \(Int(settings.fontSize)) pt", value: Binding(get: { settings.fontSize }, set: {
                var value = settings; value.fontSize = $0; settings = value
            }), in: typographyControls.fontSize.range, step: typographyControls.fontSize.step).accessibilityIdentifier("quickFontSize")
            HStack(spacing: LayoutTokens.content) {
                Menu {
                    Button("跟随应用") { choose(.app) }
                    Button("系统配色") { choose(.system) }
                } label: {
                    Label("配色", systemImage: "paintpalette").font(.subheadline)
                        .frame(minHeight: LayoutTokens.hit).contentShape(.rect)
                }.accessibilityIdentifier("quickPaletteSource")
                ScrollView(.horizontal) {
                    HStack(spacing: LayoutTokens.control) {
                        ForEach(themes.snapshot.palettes.filter { $0.appearance == appearance }, id: \.id) { palette in
                            Button { choose(.palette(id: palette.id)) } label: {
                                Text(verbatim: "Aa").font(.system(.body, design: .serif))
                                    .foregroundStyle(Color(uiColor: UIColor(rgb: palette.colors.ink)))
                                    .frame(width: 44, height: 40)
                                    .background(Color(uiColor: UIColor(rgb: palette.colors.paper)), in: .rect(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                                        Color(uiColor: selected == .palette(id: palette.id) ? theme.accent : theme.border),
                                        lineWidth: selected == .palette(id: palette.id) ? 2 : 1))
                                    .frame(minHeight: LayoutTokens.hit)
                            }.buttonStyle(.plain).accessibilityLabel(paletteDisplayName(palette))
                                .accessibilityAddTraits(selected == .palette(id: palette.id) ? .isSelected : [])
                                .accessibilityIdentifier("quickPalette-\(palette.id)")
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            ReadingModePicker(mode: settings.mode) { var value = settings; value.mode = $0; settings = value }
                .equatable().pickerStyle(.segmented).accessibilityIdentifier("quickReadingMode")
        }
        .padding(.horizontal, LayoutTokens.page).padding(.top, LayoutTokens.content)
        .padding(.bottom, LayoutTokens.compact)
        .accessibilityElement(children: .contain).accessibilityIdentifier("readerQuickSettings")
    }
    private func choose(_ source: ReaderPaletteSource) {
        themes.update { value in
            if appearance == .light { value.readerLight = source } else { value.readerDark = source }
        }
    }
}

enum ReadingSettingsTab: String, CaseIterable {
    case typography, colors, controls
    var title: LocalizedStringKey {
        switch self {
        case .typography: "排版"
        case .colors: "配色与纹理"
        case .controls: "屏幕"
        }
    }
}

@MainActor @Observable final class ReadingSettingsEditing {
    var editedAppearance: ThemeAppearance?
    var previewPresented = false
    var previewDetent = PresentationDetent.height(60)
    var restingDetent = PresentationDetent.height(60)
    var draft: PaletteDraft?
    var navigation = NavigationPresentationState()
    var previewPosition = ReadingPreviewPosition()
    var previewVisible = false
    var appeared = false
}

struct ReaderSettingsView: View {
    @Binding var settings: ReaderSettings
    let preview: ReadingPreviewSource
    let encoding: String?
    let isRestartingEncoding: Bool
    let changeEncoding: ((String?) -> Void)?
    @Environment(ThemeStore.self) private var themes
    @Environment(\.theme) private var theme
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.displayScale) private var displayScale
    @AppStorage("readingSettingsTab") private var tab = ReadingSettingsTab.typography
    @State private var localEditing = ReadingSettingsEditing()
    let editing: ReadingSettingsEditing?
    let keepsTabBar: Bool
    private var editor: ReadingSettingsEditing { editing ?? localEditing }
    private var editedAppearance: ThemeAppearance? {
        get { editor.editedAppearance }
        nonmutating set { editor.editedAppearance = newValue }
    }
    private var previewPresented: Bool {
        get { editor.previewPresented }
        nonmutating set { editor.previewPresented = newValue }
    }
    private var previewDetent: PresentationDetent {
        get { editor.previewDetent }
        nonmutating set { editor.previewDetent = newValue }
    }
    private var restingDetent: PresentationDetent {
        get { editor.restingDetent }
        nonmutating set { editor.restingDetent = newValue }
    }
    private var draft: PaletteDraft? {
        get { editor.draft }
        nonmutating set { editor.draft = newValue }
    }
    private var navigation: NavigationPresentationState {
        get { editor.navigation }
        nonmutating set { editor.navigation = newValue }
    }
    private var previewPosition: ReadingPreviewPosition {
        get { editor.previewPosition }
        nonmutating set { editor.previewPosition = newValue }
    }
    private var previewVisible: Bool {
        get { editor.previewVisible }
        nonmutating set { editor.previewVisible = newValue }
    }
    private var appeared: Bool {
        get { editor.appeared }
        nonmutating set { editor.appeared = newValue }
    }

    init(settings: Binding<ReaderSettings>, preview: ReadingPreviewSource = .sample, encoding: String? = nil, isRestartingEncoding: Bool = false, changeEncoding: ((String?) -> Void)? = nil,
         editing: ReadingSettingsEditing? = nil, keepsTabBar: Bool = false) {
        _settings = settings; self.preview = preview; self.encoding = encoding; self.isRestartingEncoding = isRestartingEncoding; self.changeEncoding = changeEncoding
        self.editing = editing; self.keepsTabBar = keepsTabBar
    }
    private var appearance: ThemeAppearance { editedAppearance ?? themes.reader.plan.appearance }
    private var previewExpanded: Bool { verticalSizeClass == .compact || previewDetent == .large }
    private var previewCollapsed: Bool { verticalSizeClass != .compact && previewDetent == .height(60) }
    private var texture: ReaderTextureChoice? {
        appearance == .light ? themes.snapshot.preferences.readerLightTexture : themes.snapshot.preferences.readerDarkTexture
    }
    private var previewTheme: ThemeSurface {
        if let draft {
            return ThemeSurface(plan: ResolvedTheme(appearance: draft.palette.appearance, highContrast: themes.highContrast,
                                                   colors: draft.palette.colors, paletteId: draft.palette.id), readerTexture: texture)
        }
        var snapshot = themes.snapshot
        snapshot.preferences.readerMode = appearance == .light ? .light : .dark
        guard let plan = try? resolveThemes(value: snapshot, system: themes.system, highContrast: themes.highContrast) else { return themes.reader }
        return ThemeSurface(plan: plan.reader, readerTexture: texture)
    }
    var body: some View {
        @Bindable var editing = editor
        GeometryReader { geometry in
            // Keep enough room for both native controls and readable text.
            let wide = geometry.size.width >= 760
            HStack(spacing: 0) {
                ReadingSettingsControls(settings: $settings, tab: $tab, editedAppearance: $editing.editedAppearance, encoding: encoding, isRestartingEncoding: isRestartingEncoding, changeEncoding: changeEncoding,
                                     editPalette: { value in
                                         if !wide && previewPresented { previewDetent = .large }
                                         draft = value
                                     })
                    .frame(width: wide ? min(400, geometry.size.width * 0.46) : nil)
                    .clipped()
                    .frame(maxHeight: .infinity, alignment: .top)
                if wide {
                    readingPreview
                        .background {
                            if let tile = previewPosition.paperTile(previewTheme.paperInput(scale: displayScale)) {
                                Image(uiImage: tile).resizable(resizingMode: .tile)
                            } else { Color(uiColor: previewTheme.paper) }
                        }
                        .clipShape(.rect(cornerRadius: 16))
                        .padding(LayoutTokens.content)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !wide && !previewPresented {
                    Button("阅读预览", systemImage: "doc.text.magnifyingglass") {
                        previewDetent = verticalSizeClass == .compact ? .large : .height(60)
                        previewPresented = true
                    }
                    .frame(maxWidth: .infinity, minHeight: LayoutTokens.hit)
                    .accessibilityIdentifier("showReadingPreview")
                }
            }
            .background(Color(uiColor: theme.canvas).ignoresSafeArea())
            .navigationTitle(keepsTabBar ? Text("阅读") : Text("阅读设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.visible, for: .navigationBar)
            .toolbarVisibility(keepsTabBar ? .automatic : .hidden, for: .tabBar)
            .statusBarHidden(false)
            .background(NavigationTransitionObserver(willLeave: { _ in
                previewPosition.capture()
                navigation.begin(hasPresentation: previewVisible)
            }, completed: { _, cancelled in navigation.finish(cancelled: cancelled) }))
            .onAppear {
                navigation.appear()
                if !appeared {
                    appeared = true
                    previewPresented = !keepsTabBar && verticalSizeClass != .compact
                }
            }
            .sheet(item: Binding(get: { !wide && previewPresented ? nil : draft }, set: { draft = $0 })) { value in
                paletteEditor(value)
            }
            .sheet(isPresented: Binding(get: { !wide && previewPresented && !navigation.isSuspended }, set: {
                if !wide && !navigation.isSuspended { previewPresented = $0 }
            }), onDismiss: {
                previewVisible = false
                navigation.presentationDismissed()
            }) {
                VStack(spacing: 0) {
                    Button {
                        if verticalSizeClass == .compact {
                            previewPresented = false
                        } else { withAnimation(MotionTokens.panel(reduced: reduceMotion)) {
                            previewDetent = previewCollapsed ? .medium : (previewDetent == .medium ? .large : .height(60))
                        } }
                    } label: {
                        HStack {
                            Text("阅读预览 · \(Int(settings.fontSize)) pt").font(.caption.weight(.medium))
                            Spacer()
                            Text(previewExpanded ? "收起" : "展开").font(.caption)
                            Image(systemName: previewExpanded ? "chevron.down" : "chevron.up")
                        }
                        .frame(minHeight: LayoutTokens.hit).contentShape(.rect)
                    }
                    .buttonStyle(.plain).padding(.horizontal, LayoutTokens.content)
                    .foregroundStyle(Color(uiColor: previewTheme.secondary))
                    .accessibilityIdentifier("toggleReadingPreview")
                    .accessibilityLabel(previewExpanded ? "收起预览" : "展开预览")
                    #if DEBUG
                    .accessibilityValue(ProcessInfo.processInfo.arguments.contains("--ui-testing")
                        ? (previewExpanded ? "full" : previewDetent == .medium ? "half" : "compact") : "")
                    #endif
                    readingPreview
                        .opacity(previewCollapsed ? 0 : 1)
                        .accessibilityHidden(previewCollapsed)
                        .allowsHitTesting(!previewCollapsed)
                }
                .clipped()
                .padding(.top, LayoutTokens.control)
                .presentationSizing(.page)
                .presentationDetents([.height(60), .medium, .large], selection: $editing.previewDetent)
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.resizes)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationBackground {
                    if let tile = previewPosition.paperTile(previewTheme.paperInput(scale: displayScale)) {
                        Image(uiImage: tile).resizable(resizingMode: .tile).ignoresSafeArea()
                    } else { Color(uiColor: previewTheme.paper) }
                }
                .preferredColorScheme(previewTheme.scheme)
                .interactiveDismissDisabled()
                .onAppear { previewVisible = true }
                .sheet(item: $editing.draft, onDismiss: {
                    if verticalSizeClass != .compact { previewDetent = .height(60) }
                }) { value in
                    paletteEditor(value)
                }
            }
            .onChange(of: previewDetent) { _, value in
                if value != .large { restingDetent = value }
            }
            .onChange(of: themes.snapshot.preferences.readerMode) { _, _ in editedAppearance = nil }
        }
    }
    private var readingPreview: some View {
        ReadingPreviewPane(source: preview, settings: settings, surface: previewTheme, position: previewPosition)
            .onDisappear { previewPosition.capture() }
    }

    private func paletteEditor(_ value: PaletteDraft) -> some View {
        PaletteEditor(draft: value, showsAppPreview: false)
        .themeScope(theme)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: theme.canvas))
    }
}

/// Settings retain their own scroll and focus state while the preview covers them.
private struct ReadingSettingsControls: View {
    @Binding var settings: ReaderSettings
    @Binding var tab: ReadingSettingsTab
    @Binding var editedAppearance: ThemeAppearance?
    let encoding: String?
    let isRestartingEncoding: Bool
    let changeEncoding: ((String?) -> Void)?
    let editPalette: (PaletteDraft) -> Void
    @Environment(ThemeStore.self) private var themes
    @Environment(\.theme) private var theme
    private var appearance: ThemeAppearance { editedAppearance ?? themes.reader.plan.appearance }

    var body: some View {
        VStack(spacing: 0) {
            Picker("阅读设置分类", selection: $tab) {
                ForEach(ReadingSettingsTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
                .padding(.horizontal, LayoutTokens.content).padding(.vertical, LayoutTokens.compact)
                .accessibilityIdentifier("readerThemeTabs")
            switch tab {
            case .colors: colors
            case .typography: typography
            case .controls: ReaderControlsForm(settings: $settings)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: theme.canvas))
    }
    private var colors: some View {
        VStack(spacing: 0) {
            HStack {
                Text("明暗模式")
                Spacer()
                Picker("明暗模式", selection: Binding(get: { themes.snapshot.preferences.readerMode }, set: { mode in themes.update { $0.readerMode = mode } })) {
                    Text("跟随应用").tag(ReaderAppearanceMode.app)
                    Text("跟随系统").tag(ReaderAppearanceMode.system)
                    Text("浅色").tag(ReaderAppearanceMode.light)
                    Text("深色").tag(ReaderAppearanceMode.dark)
                }.labelsHidden().accessibilityIdentifier("readerAppearanceMode")
            }.frame(minHeight: LayoutTokens.hit).padding(.horizontal, LayoutTokens.page)
            Picker("编辑配色", selection: Binding(get: { appearance }, set: { editedAppearance = $0 })) {
                Text("浅色时").tag(ThemeAppearance.light).accessibilityIdentifier("paletteSlot-light")
                Text("深色时").tag(ThemeAppearance.dark).accessibilityIdentifier("paletteSlot-dark")
            }.pickerStyle(.segmented).padding(.horizontal, LayoutTokens.content).padding(.bottom, LayoutTokens.compact)
                .accessibilityIdentifier("readerPaletteSlots")
            PalettePicker(reader: true, appearance: appearance, embedded: true, editPalette: editPalette)
        }
    }
    private func binding<Value>(_ key: WritableKeyPath<ReaderSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: key] }, set: { value in
            var next = settings; next[keyPath: key] = value; settings = next
        })
    }
    private var typography: some View {
        Form {
            if let encoding, let changeEncoding {
                Section("本书") {
                    ReaderEncodingMenu(title: "文字编码", value: encoding, isRestarting: isRestartingEncoding, select: changeEncoding)
                        .accessibilityIdentifier("bookTextEncoding")
                }.listRowBackground(Color(uiColor: theme.surface))
            }
            Section("文字") {
                Picker("字体", selection: binding(\.font)) {
                    Text("系统").tag(ReaderFont.system)
                    Text("宋体").tag(ReaderFont.serif)
                    Text("圆体").tag(ReaderFont.rounded)
                }.accessibilityIdentifier("readingFont")
                numberRow("字号", value: binding(\.fontSize), range: typographyControls.fontSize.range, step: typographyControls.fontSize.step, id: "fontSize")
                numberRow("行距", value: binding(\.lineSpacing), range: typographyControls.lineSpacing.range, step: typographyControls.lineSpacing.step, id: "lineSpacing")
            }.listRowBackground(Color(uiColor: theme.surface))
            Section("段落") {
                Picker("首行缩进", selection: binding(\.indent)) {
                    Text("按原文").tag(ReadingIndent.original)
                    Text("智能两字").tag(ReadingIndent.smart)
                }.accessibilityIdentifier("readingIndent")
                numberRow("段间距", value: binding(\.paragraphSpacing), range: typographyControls.paragraphSpacing.range, step: typographyControls.paragraphSpacing.step, id: "paragraphSpacing")
            }.listRowBackground(Color(uiColor: theme.surface))
            Section("页面") {
                numberRow("左右边距", value: binding(\.horizontalMargin), range: 12...48, step: 2, id: "horizontalMargin")
                numberRow("最大行宽", value: binding(\.maximumLineWidth), range: 320...1200, step: 40, id: "maximumLineWidth")
            }.listRowBackground(Color(uiColor: theme.surface))
        }
        .contentMargins(.top, LayoutTokens.compact, for: .scrollContent)
        .themedPage().accessibilityIdentifier("readerTypographyControls")
    }
    private func numberRow(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, step: Double, id: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            HStack(spacing: 8) {
                Button { value.wrappedValue = max(range.lowerBound, value.wrappedValue - step) } label: {
                    Image(systemName: "minus").frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
                }.disabled(value.wrappedValue <= range.lowerBound).accessibilityLabel("减小")
                Text("\(Int(value.wrappedValue)) pt").monospacedDigit().font(.subheadline)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Button { value.wrappedValue = min(range.upperBound, value.wrappedValue + step) } label: {
                    Image(systemName: "plus").frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
                }.disabled(value.wrappedValue >= range.upperBound).accessibilityLabel("增大")
            }.buttonStyle(.borderless)
        }.accessibilityElement(children: .contain).accessibilityIdentifier(id)
    }

}

private struct ReaderControlsForm: View {
    @Binding var settings: ReaderSettings
    @Environment(\.theme) private var theme
    private func binding<Value>(_ key: WritableKeyPath<ReaderSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: key] }, set: { value in var next = settings; next[keyPath: key] = value; settings = next })
    }
    var body: some View {
        Form {
            Section("阅读方式") {
                ReadingModePicker(mode: settings.mode) { var value = settings; value.mode = $0; settings = value }
                    .equatable().pickerStyle(.segmented).accessibilityIdentifier("readingMode")
            }.listRowBackground(Color(uiColor: theme.surface))
            Section("屏幕") {
                Picker("屏幕方向", selection: binding(\.orientation)) {
                    Text("跟随系统").tag(ReadingOrientation.system)
                    Text("竖屏").tag(ReadingOrientation.portrait)
                    Text("横屏").tag(ReadingOrientation.landscape)
                }.accessibilityIdentifier("readingOrientation")
                Toggle("阅读常亮", isOn: binding(\.keepAwake)).accessibilityIdentifier("readingKeepAwake")
            }.listRowBackground(Color(uiColor: theme.surface))
            Section("亮度") {
                Toggle("亮度跟随系统", isOn: Binding(get: { settings.brightness == nil }, set: { follows in
                    var value = settings; value.brightness = follows ? nil : 0.5; settings = value
                })).accessibilityIdentifier("brightnessFollowsSystem")
                if settings.brightness != nil {
                    HStack(spacing: LayoutTokens.content) {
                        Image(systemName: "sun.min").accessibilityHidden(true)
                        Slider(value: Binding(get: { settings.brightness ?? 0.5 }, set: { brightness in var value = settings; value.brightness = brightness; settings = value }), in: 0...1) {
                            Text("阅读亮度")
                        }.accessibilityIdentifier("readingBrightness")
                        Image(systemName: "sun.max").accessibilityHidden(true)
                    }.foregroundStyle(Color(uiColor: theme.secondary)).frame(minHeight: LayoutTokens.hit)
                }
            }.listRowBackground(Color(uiColor: theme.surface))
        }.contentMargins(.top, LayoutTokens.compact, for: .scrollContent)
            .themedPage().accessibilityIdentifier("readerControlOptions")
    }
}

#if DEBUG
/// Own only the normal settings binding for a direct, isolated screenshot route.
struct PageShotReaderSettings: View {
    @State private var settings: ReaderSettings?
    @State private var error: String?
    var body: some View {
        Group {
            if let initial = settings {
                ReaderSettingsView(settings: Binding(get: { settings ?? initial }, set: { settings = $0 }))
            } else if let error { Text(verbatim: error) }
            else { ProgressView() }
        }.task {
            do { settings = try await AppDataService.shared.settings() }
            catch { self.error = ReaderMessages.error(error) }
        }
    }
}
#endif
