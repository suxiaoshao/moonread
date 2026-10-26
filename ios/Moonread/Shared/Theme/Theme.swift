import SwiftUI
import UIKit

enum LayoutTokens {
    static let compact: CGFloat = 8
    static let control: CGFloat = 12
    static let content: CGFloat = 16
    static let page: CGFloat = 20
    static let section: CGFloat = 24
    static let pageBottomSpacing: CGFloat = 32
    static let hit: CGFloat = 44
    static let inputRadius: CGFloat = 16
    static let floatingRadius: CGFloat = 20
    static let border: CGFloat = 1
}

enum MotionTokens {
    static func controls(reduced: Bool) -> Animation { .easeOut(duration: reduced ? 0.10 : 0.18) }
    static func panel(reduced: Bool) -> Animation { .easeInOut(duration: reduced ? 0.10 : 0.24) }
    static func accessoryResize(reduced: Bool) -> Animation {
        .easeInOut(duration: reduced ? 0.10 : 0.20)
    }
    static func accessoryContent(reduced: Bool) -> AnyTransition {
        // Fade through within the resizing sheet, without moving or scaling
        // the controls. SwiftUI owns interruption and reversal of transitions.
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: reduced ? 0.10 : 0.12)),
            removal: .opacity.animation(.easeOut(duration: 0.08))
        )
    }
    static let color = Animation.easeInOut(duration: 0.18)
}

struct ThemeSurface: Equatable {
    let plan: ResolvedTheme
    var readerTexture: ReaderTextureChoice? = nil
    var scheme: ColorScheme { plan.appearance == .dark ? .dark : .light }
    var style: UIUserInterfaceStyle { plan.appearance == .dark ? .dark : .light }
    func ui(_ role: KeyPath<ThemeColors, UInt32>, system: UIColor) -> UIColor {
        if let colors = plan.colors { return UIColor(rgb: colors[keyPath: role]) }
        return system.resolvedColor(with: UITraitCollection { traits in
            traits[UITraitUserInterfaceStyle.self] = style
            traits[UITraitAccessibilityContrast.self] = plan.highContrast ? .high : .normal
        })
    }
    var canvas: UIColor { ui(\.canvas, system: .systemGroupedBackground) }
    var surface: UIColor { ui(\.surface, system: .secondarySystemGroupedBackground) }
    var raised: UIColor { ui(\.raised, system: .tertiarySystemGroupedBackground) }
    var input: UIColor { ui(\.input, system: .secondarySystemBackground) }
    var paper: UIColor { ui(\.paper, system: .systemBackground) }
    var ink: UIColor { ui(\.ink, system: .label) }
    var secondary: UIColor { ui(\.secondary, system: .secondaryLabel) }
    var accent: UIColor { ui(\.accent, system: .systemBlue) }
    var onAccent: UIColor { ui(\.onAccent, system: .white) }
    var accentSurface: UIColor { ui(\.accentSurface, system: .tertiarySystemFill) }
    var border: UIColor { ui(\.border, system: .separator) }
    var separator: UIColor { ui(\.separator, system: .separator) }
    var focus: UIColor { ui(\.focus, system: .systemBlue) }
    var selected: UIColor { ui(\.selected, system: .tertiarySystemFill) }
    var annotation: UIColor { ui(\.annotation, system: .systemYellow.withAlphaComponent(0.22)) }
    var search: UIColor { ui(\.search, system: .systemBlue.withAlphaComponent(0.16)) }
    var searchCurrent: UIColor { ui(\.searchCurrent, system: .systemBlue.withAlphaComponent(0.28)) }
    var selection: UIColor { ui(\.selection, system: .systemBlue) }
    var destructive: UIColor { ui(\.destructive, system: .systemRed) }
    var warning: UIColor { ui(\.warning, system: .systemOrange) }
    var onDestructive: UIColor { ui(\.onDestructive, system: .white) }
    var success: UIColor { ui(\.success, system: .systemGreen) }
    var moon: UIColor { ui(\.moon, system: .tertiaryLabel) }
    var maria: UIColor { ui(\.maria, system: .secondaryLabel) }
    /// Statistics categorical colors, shared by every palette of one appearance.
    /// A stable key hash keeps a book's color across charts; collisions are
    /// allowed, so charts keep book titles beside their marks.
    private static let lightStatistics: [UInt32] = [0xB86652, 0xA27825, 0x539156, 0x009494, 0x4984BF, 0x996BAD]
    private static let darkStatistics: [UInt32] = [0xF0A08C, 0xD9B06B, 0x8FC990, 0x5ECBCB, 0x85BCF5, 0xD0A4E4]
    func statisticsColor(_ key: String) -> Color {
        let colors = scheme == .dark ? Self.darkStatistics : Self.lightStatistics
        let hash = key.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return Color(uiColor: UIColor(rgb: colors[Int(hash % UInt64(colors.count))]))
    }
    func floatingBackground(_ material: Material = .regularMaterial) -> AnyShapeStyle {
        // System colors keep native material; a chosen palette owns the whole
        // custom surface, including its background rather than just the text.
        plan.colors == nil ? AnyShapeStyle(material) : AnyShapeStyle(Color(uiColor: raised))
    }
    struct PaperInput: Equatable {
        let paper: UInt32
        let ink: UInt32
        let choice: ReaderTextureChoice?
        let scale: CGFloat
    }
    func paperInput(scale: CGFloat) -> PaperInput {
        PaperInput(paper: paper.opaqueRGB, ink: ink.opaqueRGB, choice: plan.colors == nil ? nil : readerTexture, scale: max(1, scale))
    }
    static func paperBackground(_ input: PaperInput) -> UIColor {
        guard input.choice != nil else { return UIColor(rgb: input.paper) }
        return UIColor(patternImage: paperTile(input))
    }
    static func paperTile(_ input: PaperInput) -> UIImage {
        let paper = UIColor(rgb: input.paper)
        let format = UIGraphicsImageRendererFormat()
        format.scale = input.scale; format.opaque = true; format.preferredRange = .standard
        let side = CGFloat(readerTextureTileSize()), bounds = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            paper.setFill(); context.fill(bounds)
            context.cgContext.interpolationQuality = .none
            if let choice = input.choice, let source = UIImage(named: choice.id.assetName) {
                source.withTintColor(UIColor(rgb: input.ink), renderingMode: .alwaysOriginal)
                    .draw(in: bounds, blendMode: .normal,
                          alpha: CGFloat(readerTextureAlpha(paper: input.paper, ink: input.ink, strength: choice.strength)))
            }
        }
    }
    static let initial = ThemeSurface(plan: try! resolveThemes(value: defaultThemeSnapshot(), system: .light, highContrast: false).app)
}

extension ReaderTextureId {
    var label: LocalizedStringKey {
        switch self { case .paper: "宣纸"; case .kraft: "牛皮纸"; case .linen: "细麻布"; case .grain: "颗粒" }
    }
    var assetName: String {
        switch self { case .paper: "ReaderTexturePaper"; case .kraft: "ReaderTextureKraft"; case .linen: "ReaderTextureLinen"; case .grain: "ReaderTextureGrain" }
    }
}
extension ReaderTextureStrength {
    var label: LocalizedStringKey { switch self { case .light: "淡"; case .medium: "中"; case .strong: "浓" } }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 255) / 255,
                  green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
    var opaqueRGB: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let converted = cgColor.converted(to: space, intent: .defaultIntent, options: nil),
           let components = converted.components, components.count >= 3 {
            r = components[0]; g = components[1]; b = components[2]
        } else { getRed(&r, green: &g, blue: &b, alpha: &a) }
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }
}

extension EnvironmentValues {
    @Entry var theme = ThemeSurface.initial
    @Entry var moonreadReduceMotion = false
}

@MainActor @Observable
final class ThemeStore {
    private(set) var snapshot: ThemeSnapshot
    private(set) var loaded = false
    // Explicit palette creation/deletion can lock its editor. Ordinary
    // preference writes must never disable or dim the surrounding controls.
    private(set) var saving = false
    var error: String?
    var system: ThemeAppearance = .light
    var highContrast = false
    private let cacheKey: String
    private var pendingPreferences: ThemePreferences?
    private var preferencesTask: Task<Void, Never>?
    private let persistPreferences: @MainActor (ThemePreferences) async throws -> ThemeSnapshot

    convenience init() {
        self.init { preferences in try await AppDataService.shared.saveThemes(preferences) }
    }

    init(persistPreferences: @escaping @MainActor (ThemePreferences) async throws -> ThemeSnapshot) {
        self.persistPreferences = persistPreferences
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        let session = args.firstIndex(of: "--ui-test-session").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        #else
        let session: String? = nil
        #endif
        cacheKey = "Moonread.appearanceCache.\(session ?? "library")"
        snapshot = UserDefaults.standard.string(forKey: cacheKey).flatMap { try? decodeThemeSnapshot(json: $0) } ?? defaultThemeSnapshot()
        #if DEBUG
        if args.contains("--ui-testing"), let index = args.firstIndex(of: "--ui-test-app-appearance"), args.indices.contains(index + 1) {
            snapshot.preferences.appMode = args[index + 1] == "dark" ? .dark : .light
            // Seed both the first frame and the normal asynchronous preferences load.
            UserDefaults.standard.set(try? encodeThemePreferences(value: snapshot.preferences), forKey: "Moonread.themePreferences")
        }
        #endif
    }

    var resolved: ResolvedThemes {
        // Preferences have already been validated by the core at load/save.
        (try? resolveThemes(value: snapshot, system: system, highContrast: highContrast))
            ?? (try! resolveThemes(value: defaultThemeSnapshot(), system: system, highContrast: highContrast))
    }
    var app: ThemeSurface { ThemeSurface(plan: resolved.app) }
    var reader: ThemeSurface {
        let plan = resolved.reader
        return ThemeSurface(plan: plan, readerTexture: plan.appearance == .light ? snapshot.preferences.readerLightTexture : snapshot.preferences.readerDarkTexture)
    }

    func load() async {
        await preferencesTask?.value
        do { accept(try await AppDataService.shared.themes()); loaded = true }
        catch { self.error = ReaderMessages.error(error) }
    }
    private func accept(_ value: ThemeSnapshot) {
        if snapshot != value { snapshot = value }
        cache(value)
    }
    private func cache(_ value: ThemeSnapshot) {
        if let json = try? encodeThemeSnapshot(value: value) { UserDefaults.standard.set(json, forKey: cacheKey) }
    }
    func update(_ edit: (inout ThemePreferences) -> Void) {
        guard !saving else { return }
        var preferences = snapshot.preferences
        edit(&preferences)
        guard preferences != snapshot.preferences else { return }
        let previous = snapshot
        let motion = UIAccessibility.isReduceMotionEnabled || preferences.reduceMotion
        withAnimation(motion ? nil : MotionTokens.color) { snapshot.preferences = preferences }
        pendingPreferences = preferences
        guard preferencesTask == nil else { return }
        preferencesTask = Task {
            defer { preferencesTask = nil }
            var persisted = previous
            while let next = pendingPreferences {
                pendingPreferences = nil
                do {
                    persisted = try await persistPreferences(next)
                    // A finished older write must not undo a newer selection.
                    if pendingPreferences == nil { accept(persisted) }
                    else { cache(persisted) }
                } catch {
                    if pendingPreferences == nil { accept(persisted) }
                    self.error = ReaderMessages.error(error)
                }
            }
        }
    }
    func flushPreferences() async { await preferencesTask?.value }
    func savePalette(_ palette: ThemePalette, creating: Bool) async throws {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        await flushPreferences()
        _ = try await AppDataService.shared.savePalette(palette, creating: creating)
        accept(try await AppDataService.shared.themes())
    }
    func deletePalette(_ id: String) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        await flushPreferences()
        do { accept(try await AppDataService.shared.deletePalette(id)) }
        catch { self.error = ReaderMessages.error(error) }
    }
}

/// Override only this hosting controller. The parent continues observing true
/// system appearance, even when the App or a reader sheet forces another mode.
struct NativeThemeHost<Content: View>: UIViewControllerRepresentable {
    let theme: ThemeSurface
    @ViewBuilder var content: () -> Content
    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let controller = UIHostingController(rootView: content())
        controller.overrideUserInterfaceStyle = theme.style
        controller.view.backgroundColor = theme.canvas
        return controller
    }
    func updateUIViewController(_ controller: UIHostingController<Content>, context: Context) {
        controller.overrideUserInterfaceStyle = theme.style
        controller.view.backgroundColor = theme.canvas
        controller.rootView = content()
    }
}

struct ThemedPage: ViewModifier {
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden)
            .background(Color(uiColor: theme.canvas))
            .foregroundStyle(Color(uiColor: theme.ink))
            .tint(Color(uiColor: theme.accent))
    }
}

/// Keep the native prominent button's interaction and shape, while pairing its
/// filled background with the palette's foreground instead of inherited ink.
struct ThemedProminentButtonStyle: PrimitiveButtonStyle {
    @Environment(\.theme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.borderedProminent)
            .tint(Color(uiColor: theme.accent))
            .foregroundStyle(Color(uiColor: theme.onAccent))
    }
}

/// Use the native secondary control with the same sizing and shape rules as
/// its prominent counterpart. Callers set controlSize on both actions together.
struct ThemedSecondaryButtonStyle: PrimitiveButtonStyle {
    @Environment(\.theme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.bordered)
            .tint(Color(uiColor: theme.accent))
    }
}

/// Bar utility, navigation and create glyphs (gear, ×, …, locate, +, compose) use the
/// theme's ink. The root tint stays accent for state, focus and prominent commits;
/// destructive items keep their role colour.
struct ToolbarGlyph: ViewModifier {
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View { content.tint(Color(uiColor: theme.ink)) }
}

struct ThemedDivider: View {
    @Environment(\.theme) private var theme
    var body: some View { Divider().overlay(Color(uiColor: theme.separator)) }
}

struct ThemedEmptyState: View {
    let title: String
    let symbol: String
    @Environment(\.theme) private var theme
    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title).foregroundStyle(Color(uiColor: theme.ink))
            } icon: {
                Image(systemName: symbol).foregroundStyle(Color(uiColor: theme.secondary))
            }
        }
    }
}

extension View {
    func themedPage() -> some View { modifier(ThemedPage()) }
    func toolbarGlyph() -> some View { modifier(ToolbarGlyph()) }
    func themeScope(_ theme: ThemeSurface) -> some View {
        environment(\.theme, theme).environment(\.colorScheme, theme.scheme)
            .foregroundStyle(Color(uiColor: theme.ink)).tint(Color(uiColor: theme.accent))
    }
}

// Opt in only at a page's scrolling container. Theme styling also wraps Lists,
// reader tools and nested content, so it must not add scroll margins globally.
extension ScrollView {
    func pageScrollMargins() -> some View {
        contentMargins(.bottom, LayoutTokens.pageBottomSpacing, for: .scrollContent)
    }
}
