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
            Stepper("字号 · \(Int(settings.fontSize))", value: Binding(get: { settings.fontSize }, set: {
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
