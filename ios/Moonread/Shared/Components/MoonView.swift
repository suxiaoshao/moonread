import SwiftUI

enum LoadingTiming {
    // An anti-flicker choice for auxiliary feedback, not a delay on the work.
    static let inlineDelay: Duration = .milliseconds(300)
}

/// The idle moonlight disc. Empty-state and
/// preview artwork; it never indicates waiting. `size` is the body's diameter.
struct MoonView: View {
    var size: CGFloat = 48
    @Environment(\.theme) private var theme
    var body: some View {
        let unit = size / 72, palette = MoonArtwork.Palette(theme)
        Canvas { context, _ in
            MoonArtwork(pose: .idle, palette: palette, time: nil)
                .draw(in: context, unit: unit, origin: CGPoint(x: -MoonArtwork.disc.minX * unit, y: -MoonArtwork.disc.minY * unit))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The 夜读 brand mark: the app icon's night-blue square with its crescent,
/// stars and open book. Brand moments only (About, title page); fixed brand
/// colours, independent of the reading theme.
struct BrandSeal: View {
    var size: CGFloat = 80
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.169, green: 0.239, blue: 0.471), Color(red: 0.059, green: 0.090, blue: 0.212)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay { Image("BrandGlyph").resizable().scaledToFit() }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Native progress for every wait: a large spinner for an empty page, a small
/// one inline, and a linear bar whenever the real fraction is known.
struct LoadingActivity: View {
    var size: CGFloat = 24
    var fullPage = false
    var fraction: Double? = nil
    var showsValue = false
    var progressLabel: LocalizedStringKey = "正文准备进度"
    var waitingLabel: LocalizedStringKey = "正在准备"
    var delay: Duration? = nil
    @Environment(\.theme) private var theme
    var body: some View {
        DeferredLoading(delay: delay ?? (fullPage ? .zero : LoadingTiming.inlineDelay)) { visible in
            Group {
                if let fraction {
                    let progress = min(1, max(0, fraction.isFinite ? fraction : 0))
                    VStack(spacing: 8) {
                        ProgressView(value: progress).progressViewStyle(.linear)
                            .tint(Color(uiColor: theme.accent))
                            .frame(width: max(44, size), height: size)
                            .accessibilityLabel(progressLabel)
                        if showsValue {
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                                .font(.caption).monospacedDigit().accessibilityHidden(true)
                        }
                    }
                } else if fullPage {
                    PageSpinner(label: waitingLabel)
                } else {
                    VStack(spacing: 8) {
                        ProgressView().progressViewStyle(.circular)
                            .tint(Color(uiColor: theme.secondary))
                            .frame(width: size, height: size)
                            .accessibilityLabel(waitingLabel)
                        if showsValue { Text(0, format: .percent).font(.caption).hidden() }
                    }
                }
            }
        }
    }
}

/// Delay the whole loading surface, including its background. Fast work never
/// flashes a panel; completed work is never held back to finish an animation.
struct DeferredLoading<Content: View>: View {
    var delay: Duration = LoadingTiming.inlineDelay
    @ViewBuilder var content: (Bool) -> Content
    @State private var elapsed = false
    private var visible: Bool { delay == .zero || elapsed }
    var body: some View {
        content(visible)
            .opacity(visible ? 1 : 0)
            .accessibilityHidden(!visible)
            .allowsHitTesting(visible)
            .task(id: delay) {
                elapsed = false
                guard delay != .zero else { return }
                do { try await Task.sleep(for: delay); try Task.checkCancellation(); elapsed = true } catch { }
            }
            .onDisappear { elapsed = false }
    }
}

/// A superseded query cannot dismiss the next query's loading state.
@MainActor @Observable final class LoadingState {
    private(set) var request: UUID?
    var active: Bool { request != nil }
    @discardableResult func begin() -> UUID { let id = UUID(); request = id; return id }
    func finish(_ id: UUID) { if request == id { request = nil } }
}

/// Empty pages show a large native spinner; refreshes use a small one in the navigation bar.
struct PageLoadingOverlay: ViewModifier {
    let request: UUID?
    let hasContent: Bool
    var label: LocalizedStringKey = "正在加载"
    var immediate = false
    @Environment(\.theme) private var theme
    @State private var delayedRequest: UUID?
    private var presented: Bool { request != nil && (!hasContent || immediate || delayedRequest == request) }

    func body(content: Content) -> some View {
        content
            .overlay {
                ZStack {
                    if presented && !hasContent {
                        PageSpinner(label: label)
                        .accessibilityHidden(request == nil)
                        .accessibilityIdentifier("page-loading")
                        .transition(.opacity)
                        .zIndex(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
            .toolbar {
                if presented && hasContent {
                    if #available(iOS 26.0, *) {
                        ToolbarItem(placement: .topBarTrailing) { inlineIndicator }
                            .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .topBarTrailing) { inlineIndicator }
                    }
                }
            }
        .task(id: request) {
            delayedRequest = nil
            guard let request else { return }
            do {
                try await Task.sleep(for: LoadingTiming.inlineDelay)
                try Task.checkCancellation()
                delayedRequest = request
            } catch { }
        }
        .onDisappear { delayedRequest = nil }
    }

    private var inlineIndicator: some View {
        ZStack {
            ProgressView().progressViewStyle(.circular)
                .tint(Color(uiColor: theme.secondary))
        }
        .frame(width: 20, height: 20)
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
        .accessibilityHidden(request == nil)
        .accessibilityIdentifier("inline-loading")
        .allowsHitTesting(false)
    }
}

/// The empty page's indeterminate wait: the system's large spinner, unlabeled
/// on screen; the label is for VoiceOver only.
struct PageSpinner: View {
    let label: LocalizedStringKey
    @Environment(\.theme) private var theme
    var body: some View {
        ProgressView().progressViewStyle(.circular).controlSize(.large)
            .tint(Color(uiColor: theme.secondary))
            .accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}
