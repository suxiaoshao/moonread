import MoonreadCoreBindings
import SwiftUI
import UIKit

public enum LayoutTokens {
    public static let compact: CGFloat = 8
    public static let control = ControlMetrics.spacing
    public static let content: CGFloat = 16
    public static let page: CGFloat = 20
    public static let section: CGFloat = 24
    public static let hit = ControlMetrics.hitSize
    public static let inputRadius: CGFloat = 16
    public static let floatingRadius: CGFloat = 20
    public static let border: CGFloat = 1
}

public enum MotionTokens {
    public static func controls(reduced: Bool) -> Animation { .easeOut(duration: reduced ? 0.10 : 0.18) }
    public static func panel(reduced: Bool) -> Animation { .easeInOut(duration: reduced ? 0.10 : 0.24) }
    public static func accessoryResize(reduced: Bool) -> Animation {
        .easeInOut(duration: reduced ? 0.10 : 0.20)
    }
    public static func accessoryContent(reduced: Bool) -> AnyTransition {
        // Fade through within the resizing sheet, without moving or scaling
        // the controls. SwiftUI owns interruption and reversal of transitions.
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: reduced ? 0.10 : 0.12)),
            removal: .opacity.animation(.easeOut(duration: 0.08))
        )
    }
    public static let color = Animation.easeInOut(duration: 0.18)
}

public extension ResolvedTheme {
    var appearance: ThemeAppearance {
        switch surface {
        case .system(let appearance), .palette(let appearance, _, _): appearance
        }
    }
    var colors: ThemeColors? { if case .palette(_, _, let colors) = surface { colors } else { nil } }
    var paletteId: String { if case .palette(_, let id, _) = surface { id } else { "system" } }
}
public extension ResolvedReaderTexture {
    var descriptor: ReaderTextureDescriptor? {
        switch self {
        case .unsupported: nil
        case .off(let descriptor), .on(let descriptor): descriptor
        }
    }
    var enabled: Bool { if case .on = self { true } else { false } }
    var activeDescriptor: ReaderTextureDescriptor? { if case .on(let descriptor) = self { descriptor } else { nil } }
}
public struct ThemeSurface: Equatable, Sendable {
    public let plan: ResolvedTheme
    public var readerTexture: ResolvedReaderTexture?

    public init(plan: ResolvedTheme, readerTexture: ResolvedReaderTexture? = nil) {
        self.plan = plan
        self.readerTexture = readerTexture
    }
    public var scheme: ColorScheme { plan.appearance == .dark ? .dark : .light }
    public var style: UIUserInterfaceStyle { plan.appearance == .dark ? .dark : .light }
    public func ui(_ role: KeyPath<ThemeColors, UInt32>, system: UIColor) -> UIColor {
        if let colors = plan.colors { return UIColor(rgb: colors[keyPath: role]) }
        return system.resolvedColor(with: UITraitCollection { traits in
            traits[UITraitUserInterfaceStyle.self] = style
            traits[UITraitAccessibilityContrast.self] = plan.highContrast ? .high : .normal
        })
    }
    public var canvas: UIColor { ui(\.canvas, system: .systemGroupedBackground) }
    public var surface: UIColor { ui(\.surface, system: .secondarySystemGroupedBackground) }
    public var raised: UIColor { ui(\.raised, system: .tertiarySystemGroupedBackground) }
    public var input: UIColor { ui(\.input, system: .secondarySystemBackground) }
    public var paper: UIColor { ui(\.paper, system: .systemBackground) }
    public var ink: UIColor { ui(\.ink, system: .label) }
    public var secondary: UIColor { ui(\.secondary, system: .secondaryLabel) }
    public var accent: UIColor { ui(\.accent, system: .systemBlue) }
    public var onAccent: UIColor { ui(\.onAccent, system: .white) }
    public var accentSurface: UIColor { ui(\.accentSurface, system: .tertiarySystemFill) }
    public var border: UIColor { ui(\.border, system: .separator) }
    public var separator: UIColor { ui(\.separator, system: .separator) }
    public var focus: UIColor { ui(\.focus, system: .systemBlue) }
    public var selected: UIColor { ui(\.selected, system: .tertiarySystemFill) }
    public var annotation: UIColor { ui(\.annotation, system: .systemYellow.withAlphaComponent(0.22)) }
    public var search: UIColor { ui(\.search, system: .systemBlue.withAlphaComponent(0.16)) }
    public var searchCurrent: UIColor { ui(\.searchCurrent, system: .systemBlue.withAlphaComponent(0.28)) }
    public var selection: UIColor { ui(\.selection, system: .systemBlue) }
    public var destructive: UIColor { ui(\.destructive, system: .systemRed) }
    public var warning: UIColor { ui(\.warning, system: .systemOrange) }
    public var onDestructive: UIColor { ui(\.onDestructive, system: .white) }
    public var success: UIColor { ui(\.success, system: .systemGreen) }
    public var moon: UIColor { ui(\.moon, system: .tertiaryLabel) }
    public var maria: UIColor { ui(\.maria, system: .secondaryLabel) }
    public func floatingBackground(_ material: Material = .regularMaterial) -> AnyShapeStyle {
        // System colors keep native material; a chosen palette owns the whole
        // custom surface, including its background rather than just the text.
        plan.colors == nil ? AnyShapeStyle(material) : AnyShapeStyle(Color(uiColor: raised))
    }
    public static let initial = ThemeSurface(plan: try! resolveThemes(value: defaultThemeSnapshot(), system: .light, highContrast: false).app)
}

public extension EnvironmentValues {
    @Entry var theme = ThemeSurface.initial
    @Entry var moonreadReduceMotion = false
}

public struct NativeThemeHost<Content: View>: UIViewControllerRepresentable {
    let theme: ThemeSurface
    @ViewBuilder var content: () -> Content

    public init(theme: ThemeSurface, @ViewBuilder content: @escaping () -> Content) {
        self.theme = theme
        self.content = content
    }
    public func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let controller = UIHostingController(rootView: content())
        controller.overrideUserInterfaceStyle = theme.style
        controller.view.backgroundColor = theme.canvas
        return controller
    }
    public func updateUIViewController(_ controller: UIHostingController<Content>, context: Context) {
        controller.overrideUserInterfaceStyle = theme.style
        controller.view.backgroundColor = theme.canvas
        controller.rootView = content()
    }
}

public struct ThemedPage: ViewModifier {
    public init() {}
    @Environment(\.theme) private var theme
    public func body(content: Content) -> some View {
        content.modifier(SurfacePage(canvas: Color(uiColor: theme.canvas), ink: Color(uiColor: theme.ink),
                                     accent: Color(uiColor: theme.accent)))
    }
}

/// Keep the native prominent button's interaction and shape, while pairing its
/// filled background with the palette's foreground instead of inherited ink.
public struct ThemedProminentButtonStyle: PrimitiveButtonStyle {
    public init() {}
    @Environment(\.theme) private var theme
    public func makeBody(configuration: Configuration) -> some View {
        SurfaceProminentButtonStyle(accent: Color(uiColor: theme.accent), onAccent: Color(uiColor: theme.onAccent))
            .makeBody(configuration: configuration)
    }
}

/// Use the native secondary control with the same sizing and shape rules as
/// its prominent counterpart. Callers set controlSize on both actions together.
public struct ThemedSecondaryButtonStyle: PrimitiveButtonStyle {
    public init() {}
    @Environment(\.theme) private var theme
    public func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.bordered)
            .tint(Color(uiColor: theme.accent))
    }
}

/// Bar utility, navigation and create glyphs (gear, ×, …, locate, +, compose) use the
/// theme's ink. The root tint stays accent for state, focus and prominent commits;
/// destructive items keep their role colour.
public struct ToolbarGlyph: ViewModifier {
    public init() {}
    @Environment(\.theme) private var theme
    public func body(content: Content) -> some View { content.tint(Color(uiColor: theme.ink)) }
}

public struct ThemedDivider: View {
    public init() {}
    @Environment(\.theme) private var theme
    public var body: some View { SurfaceDivider(separator: Color(uiColor: theme.separator)) }
}

public struct ThemedEmptyState: View {
    let title: String
    let symbol: String

    public init(title: String, symbol: String) { self.title = title; self.symbol = symbol }

    @Environment(\.theme) private var theme
    public var body: some View {
        ContentUnavailableView {
            Label {
                Text(title).foregroundStyle(Color(uiColor: theme.ink))
            } icon: {
                Image(systemName: symbol).foregroundStyle(Color(uiColor: theme.secondary))
            }
        }
    }
}

public extension View {
    /// The UIKit scroll view keeps its content insets while its viewport reaches the bar.
    func underNavigationBar(when enabled: Bool = true, onEarlierSystems: Bool = false) -> some View {
        let extendsTop: Bool
        if #available(iOS 26, *) {
            extendsTop = enabled
        } else {
            extendsTop = enabled && onEarlierSystems
        }
        return ignoresSafeArea(.container, edges: extendsTop ? .top : [])
    }

    func themedPage() -> some View { modifier(ThemedPage()) }
    func toolbarGlyph() -> some View { modifier(ToolbarGlyph()) }
    func themeScope(_ theme: ThemeSurface) -> some View {
        environment(\.theme, theme).environment(\.colorScheme, theme.scheme)
            .foregroundStyle(Color(uiColor: theme.ink)).tint(Color(uiColor: theme.accent))
    }
}
