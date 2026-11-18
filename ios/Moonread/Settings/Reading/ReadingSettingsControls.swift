import SwiftUI

let typographyControls = readerTypographyControls()

extension ReaderNumberControl {
    var range: ClosedRange<Double> { minimum...maximum }
}

/// Settings retain their own scroll and focus state while the preview covers them.
struct ReadingSettingsControls: View {
    @Binding var settings: ReaderSettings
    @Binding var tab: ReadingSettingsTab
    @Binding var editedAppearance: ThemeAppearance?
    let encoding: String?
    let isRestartingEncoding: Bool
    let changeEncoding: ((String?) -> Void)?
    var bottomContentInset: CGFloat = 0
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
            case .controls: ReaderControlsForm(settings: $settings, bottomContentInset: bottomContentInset)
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
            PalettePicker(reader: true, appearance: appearance, embedded: true, bottomContentInset: bottomContentInset, editPalette: editPalette)
        }
    }
    private func binding<Value>(_ key: WritableKeyPath<ReaderSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: key] }, set: { value in
            var next = settings; next[keyPath: key] = value; settings = next
        })
    }
    private var fontName: String {
        if case .imported(let font, _) = settings.fontChoice { return ReaderFontLibrary.shared.name(for: font) }
        guard case .builtin(let font) = settings.fontChoice else { return String(localized: "系统") }
        switch font {
        case .system: return String(localized: "系统")
        case .serif: return String(localized: "宋体")
        case .rounded: return String(localized: "圆体")
        }
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
                NavigationLink {
                    ReaderFontPicker()
                } label: {
                    LabeledContent("字体") {
                        Text(verbatim: fontName).foregroundStyle(Color(uiColor: theme.secondary))
                    }
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
        .contentMargins(.bottom, bottomContentInset, for: .scrollContent)
        .themedPage().accessibilityIdentifier("readerTypographyControls")
    }
    private func numberRow(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, step: Double, id: String) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(0)))
            }
        }.accessibilityIdentifier(id)
    }

}

private struct ReaderControlsForm: View {
    @Binding var settings: ReaderSettings
    var bottomContentInset: CGFloat = 0
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
            .contentMargins(.bottom, bottomContentInset, for: .scrollContent)
            .themedPage().accessibilityIdentifier("readerControlOptions")
    }
}
