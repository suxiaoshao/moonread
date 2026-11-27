import SwiftUI

public enum LoadingTiming {
    // An anti-flicker choice for auxiliary feedback, not a delay on the work.
    public static let inlineDelay: Duration = .milliseconds(300)
}

/// Native progress for every wait: a large spinner for an empty page, a small
/// one inline, and a linear bar whenever the real fraction is known.
public struct LoadingActivity: View {
    var size: CGFloat = 24
    var fullPage = false
    var fraction: Double? = nil
    var showsValue = false
    var progressLabel: LocalizedStringKey = "正文准备进度"
    var waitingLabel: LocalizedStringKey = "正在准备"
    var delay: Duration? = nil

    public init(size: CGFloat = 24, fullPage: Bool = false, fraction: Double? = nil, showsValue: Bool = false,
                progressLabel: LocalizedStringKey = "正文准备进度", waitingLabel: LocalizedStringKey = "正在准备", delay: Duration? = nil) {
        self.size = size; self.fullPage = fullPage; self.fraction = fraction; self.showsValue = showsValue
        self.progressLabel = progressLabel; self.waitingLabel = waitingLabel; self.delay = delay
    }
    @Environment(\.theme) private var theme
    public var body: some View {
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
public struct DeferredLoading<Content: View>: View {
    var delay: Duration = LoadingTiming.inlineDelay
    @ViewBuilder var content: (Bool) -> Content
    public init(delay: Duration = LoadingTiming.inlineDelay, @ViewBuilder content: @escaping (Bool) -> Content) {
        self.delay = delay
        self.content = content
    }
    @State private var elapsed = false
    private var visible: Bool { delay == .zero || elapsed }
    public var body: some View {
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

public struct InlineTaskProgress: View {
    let title: Text

    public init(title: Text) { self.title = title }

    public var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            title
        }
    }
}

/// Empty pages show a large native spinner; refreshes use a small one in the navigation bar.
public struct PageLoadingOverlay: ViewModifier {
    let request: UUID?
    let hasContent: Bool
    var label: LocalizedStringKey = "正在加载"
    var immediate = false
    public init(request: UUID?, hasContent: Bool, label: LocalizedStringKey = "正在加载", immediate: Bool = false) {
        self.request = request; self.hasContent = hasContent; self.label = label; self.immediate = immediate
    }
    @Environment(\.theme) private var theme
    @State private var delayedRequest: UUID?
    private var presented: Bool { request != nil && (!hasContent || immediate || delayedRequest == request) }

    public func body(content: Content) -> some View {
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
public struct PageSpinner: View {
    let label: LocalizedStringKey

    public init(label: LocalizedStringKey) { self.label = label }
    @Environment(\.theme) private var theme
    public var body: some View {
        ProgressView().progressViewStyle(.circular).controlSize(.large)
            .tint(Color(uiColor: theme.secondary))
            .accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}
