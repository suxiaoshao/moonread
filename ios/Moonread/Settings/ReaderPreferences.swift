import SwiftUI

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
            }), in: 12...48).accessibilityIdentifier("quickFontSize")
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

private enum ReadingSettingsTab: String, CaseIterable {
    case typography = "排版", colors = "配色", controls = "阅读控制"
}

struct ReaderSettingsView: View {
    @Binding var settings: ReaderSettings
    let preview: ReadingPreviewSource
    @Environment(ThemeStore.self) private var themes
    @Environment(\.theme) private var theme
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage("readingSettingsTab") private var tab = ReadingSettingsTab.typography
    @State private var editedAppearance: ThemeAppearance?
    @State private var previewPresented = false
    @State private var previewDetent = PresentationDetent.height(60)
    @State private var restingDetent = PresentationDetent.height(60)
    @State private var draft: PaletteDraft?
    @State private var navigation = NavigationPresentationState()
    @State private var previewPosition = ReadingPreviewPosition()
    @State private var previewVisible = false
    @State private var appeared = false

    init(settings: Binding<ReaderSettings>, preview: ReadingPreviewSource = .sample) {
        _settings = settings; self.preview = preview
    }
    private var appearance: ThemeAppearance { editedAppearance ?? themes.reader.plan.appearance }
    private var previewExpanded: Bool { verticalSizeClass == .compact || previewDetent == .large }
    private var previewCollapsed: Bool { verticalSizeClass != .compact && previewDetent == .height(60) }
    private var previewTheme: ThemeSurface {
        if let draft {
            return ThemeSurface(plan: ResolvedTheme(appearance: draft.palette.appearance, highContrast: themes.highContrast,
                                                   colors: draft.palette.colors, paletteId: draft.palette.id))
        }
        var snapshot = themes.snapshot
        snapshot.preferences.readerMode = appearance == .light ? .light : .dark
        guard let plan = try? resolveThemes(value: snapshot, system: themes.system, highContrast: themes.highContrast) else { return themes.reader }
        return ThemeSurface(plan: plan.reader)
    }
    var body: some View {
        GeometryReader { geometry in
            // The medium sheet covers half the window, including the navigation
            // bar above this page. Reserving half of just the content is too short.
            let frame = geometry.frame(in: .global)
            let mediumHeight = max(0, (frame.maxY + geometry.safeAreaInsets.bottom) / 2 - frame.minY - LayoutTokens.control)
            ReadingSettingsControls(settings: $settings, tab: $tab, editedAppearance: $editedAppearance,
                                 editPalette: { value in
                                     if previewPresented { previewDetent = .large }
                                     draft = value
                                 })
                .frame(height: previewPresented
                    ? (restingDetent == .medium ? mediumHeight : max(0, geometry.size.height - 76))
                    : geometry.size.height)
                .clipped()
                .frame(maxHeight: .infinity, alignment: .top)
        }
            .safeAreaInset(edge: .bottom) {
                if !previewPresented {
                    Button("阅读预览", systemImage: "doc.text.magnifyingglass") {
                        previewDetent = verticalSizeClass == .compact ? .large : .height(60)
                        previewPresented = true
                    }
                    .frame(maxWidth: .infinity, minHeight: LayoutTokens.hit)
                    .accessibilityIdentifier("showReadingPreview")
                }
            }
            .background(Color(uiColor: theme.canvas).ignoresSafeArea())
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.visible, for: .navigationBar)
            .toolbarVisibility(.hidden, for: .tabBar)
            .statusBarHidden(false)
            .background(NavigationTransitionObserver(willLeave: { _ in
                previewPosition.capture()
                navigation.begin(hasPresentation: previewVisible)
            }, completed: { _, cancelled in navigation.finish(cancelled: cancelled) }))
            .onAppear {
                navigation.appear()
                if !appeared {
                    appeared = true
                    previewPresented = verticalSizeClass != .compact
                }
            }
            .sheet(item: Binding(get: { previewPresented ? nil : draft }, set: { draft = $0 })) { value in
                paletteEditor(value)
            }
            .sheet(isPresented: Binding(get: { previewPresented && !navigation.isSuspended }, set: {
                if !navigation.isSuspended { previewPresented = $0 }
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
                            Text("阅读预览").font(.caption.weight(.medium))
                            Spacer()
                            Image(systemName: previewExpanded ? "chevron.down" : "chevron.up")
                        }
                        .frame(minHeight: LayoutTokens.hit).contentShape(.rect)
                    }
                    .buttonStyle(.plain).padding(.horizontal, LayoutTokens.content)
                    .foregroundStyle(Color(uiColor: previewTheme.secondary))
                    .accessibilityIdentifier("toggleReadingPreview")
                    .accessibilityLabel(previewExpanded ? "收起预览" : "展开预览")
                    .accessibilityValue(ProcessInfo.processInfo.arguments.contains("--ui-testing")
                        ? (previewExpanded ? "full" : previewDetent == .medium ? "half" : "compact") : "")
                    ReadingPreviewPane(source: preview, settings: settings, surface: previewTheme, position: previewPosition)
                        .opacity(previewCollapsed ? 0 : 1)
                        .accessibilityHidden(previewCollapsed)
                        .allowsHitTesting(!previewCollapsed)
                }
                .clipped()
                .padding(.top, LayoutTokens.control)
                .presentationSizing(.page)
                .presentationDetents([.height(60), .medium, .large], selection: $previewDetent)
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.resizes)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationBackground(Color(uiColor: previewTheme.paper))
                .preferredColorScheme(previewTheme.scheme)
                .interactiveDismissDisabled()
                .onAppear { previewVisible = true }
                .sheet(item: $draft, onDismiss: {
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
    private func paletteEditor(_ value: PaletteDraft) -> some View {
        PaletteEditor(initial: value.palette, creating: value.creating, showsAppPreview: false) { palette in
            draft?.palette = palette
        }
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
    let editPalette: (PaletteDraft) -> Void
    @Environment(ThemeStore.self) private var themes
    @Environment(\.theme) private var theme
    private var appearance: ThemeAppearance { editedAppearance ?? themes.reader.plan.appearance }

    var body: some View {
        VStack(spacing: 0) {
            Picker("阅读设置分类", selection: $tab) {
                ForEach(ReadingSettingsTab.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
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
            Section {
                Picker("字体", selection: binding(\.font)) {
                    Text("系统").tag(ReaderFont.system)
                    Text("宋体").tag(ReaderFont.serif)
                    Text("圆体").tag(ReaderFont.rounded)
                }.accessibilityIdentifier("readingFont")
                Stepper("字号 · \(Int(settings.fontSize)) pt", value: binding(\.fontSize), in: 12...48).accessibilityIdentifier("fontSize")
                Stepper("行距 · \(Int(settings.lineSpacing)) pt", value: binding(\.lineSpacing), in: 0...32, step: 2).accessibilityIdentifier("lineSpacing")
            }.listRowBackground(Color(uiColor: theme.surface))
            Section("段落") {
                Picker("首行缩进", selection: binding(\.indent)) {
                    Text("按原文").tag(ReadingIndent.original)
                    Text("智能两字").tag(ReadingIndent.smart)
                }.accessibilityIdentifier("readingIndent")
                Stepper("段间距 · \(Int(settings.paragraphSpacing)) pt", value: binding(\.paragraphSpacing), in: 0...32).accessibilityIdentifier("paragraphSpacing")
            }.listRowBackground(Color(uiColor: theme.surface))
            Section("页面") {
                Stepper("左右边距 · \(Int(settings.horizontalMargin)) pt", value: binding(\.horizontalMargin), in: 12...48, step: 2).accessibilityIdentifier("horizontalMargin")
                Stepper("最大行宽 · \(Int(settings.maximumLineWidth)) pt", value: binding(\.maximumLineWidth), in: 320...1200, step: 40).accessibilityIdentifier("maximumLineWidth")
            }.listRowBackground(Color(uiColor: theme.surface))
        }
        .contentMargins(.top, LayoutTokens.compact, for: .scrollContent)
        .themedPage().accessibilityIdentifier("readerTypographyControls")
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
            Section {
                ReadingModePicker(mode: settings.mode) { var value = settings; value.mode = $0; settings = value }
                    .equatable().pickerStyle(.segmented).accessibilityIdentifier("readingMode")
                Toggle("阅读常亮", isOn: binding(\.keepAwake)).accessibilityIdentifier("readingKeepAwake")
                Picker("屏幕方向", selection: binding(\.orientation)) {
                    Text("跟随系统").tag(ReadingOrientation.system)
                    Text("竖屏").tag(ReadingOrientation.portrait)
                    Text("横屏").tag(ReadingOrientation.landscape)
                }.accessibilityIdentifier("readingOrientation")
            }.listRowBackground(Color(uiColor: theme.surface))
            Section("亮度") {
                Toggle("亮度跟随系统", isOn: Binding(get: { settings.brightness == nil }, set: { follows in
                    var value = settings; value.brightness = follows ? nil : 0.5; settings = value
                })).accessibilityIdentifier("brightnessFollowsSystem")
                if settings.brightness != nil {
                    HStack(spacing: LayoutTokens.content) {
                        Image(systemName: "sun.min")
                        Slider(value: Binding(get: { settings.brightness ?? 0.5 }, set: { brightness in var value = settings; value.brightness = brightness; settings = value }), in: 0...1) {
                            Text("阅读亮度")
                        }.accessibilityIdentifier("readingBrightness")
                        Image(systemName: "sun.max")
                    }.foregroundStyle(Color(uiColor: theme.secondary)).frame(minHeight: LayoutTokens.hit)
                }
            }.listRowBackground(Color(uiColor: theme.surface))
        }.contentMargins(.top, LayoutTokens.compact, for: .scrollContent)
            .themedPage().accessibilityIdentifier("readerControlOptions")
    }
}
