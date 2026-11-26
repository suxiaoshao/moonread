import SwiftUI

public struct MetadataActionButtonStyle: PrimitiveButtonStyle {
    public init(prominent: Bool = false, destructive: Bool = false) {
        self.prominent = prominent; self.destructive = destructive
    }

    var prominent = false
    var destructive = false
    @Environment(\.theme) private var theme
    public func makeBody(configuration: Configuration) -> some View {
        Group {
            if prominent { Button(configuration).buttonStyle(.borderedProminent) }
            else { Button(configuration).buttonStyle(.bordered) }
        }
        .buttonBorderShape(.roundedRectangle(radius: 13)).controlSize(.large)
        .tint(Color(uiColor: destructive ? theme.destructive : theme.accent))
        .foregroundStyle(Color(uiColor: prominent ? theme.onAccent : destructive ? theme.destructive : theme.accent))
    }
}
public struct DataExchangeExportSummary<Request: Sendable, Output: Sendable, ResultTitle: View>: View {
    public init(task: DataExchangeTask<Request, Output>, runningDetail: Text? = nil, open: @escaping () -> Void,
                @ViewBuilder resultTitle: @escaping (Output) -> ResultTitle) {
        self.task = task; self.runningDetail = runningDetail; self.open = open; self.resultTitle = resultTitle
    }

    @Environment(\.theme) private var theme
    let task: DataExchangeTask<Request, Output>
    var runningDetail: Text?
    let open: () -> Void
    @ViewBuilder let resultTitle: (Output) -> ResultTitle

    public var body: some View {
        if task.phase != .idle {
            DataExchangeTaskSummary(symbol: task.phase.symbol,
                                    iconColor: task.phase == .completed ? theme.success : task.phase == .failed ? theme.warning : theme.secondary,
                                    link: Text(task.phase == .running ? "查看" : "查看结果", tableName: "MetadataExchange"),
                                    open: open) {
                if let output = task.output { resultTitle(output) }
                else { Text(task.phase.title, tableName: "MetadataExchange") }
            } detail: {
                if task.phase == .running {
                    if let total = task.total, task.completed < total {
                        ProgressView(value: Double(task.completed), total: Double(total))
                            .tint(Color(uiColor: theme.accent)).accessibilityHidden(true)
                    }
                    (runningDetail ?? Text(task.progressText, tableName: "MetadataExchange"))
                        .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                }
            }
        }
    }
}

public struct DataExchangeTaskSummary<Title: View, Detail: View>: View {
    public init(symbol: String, iconColor: UIColor, link: Text, open: @escaping () -> Void,
                @ViewBuilder title: () -> Title, @ViewBuilder detail: () -> Detail) {
        self.symbol = symbol; self.iconColor = iconColor; self.link = link; self.open = open
        self.title = title(); self.detail = detail()
    }

    @Environment(\.theme) private var theme
    let symbol: String
    let iconColor: UIColor
    let link: Text
    let open: () -> Void
    @ViewBuilder let title: Title
    @ViewBuilder let detail: Detail

    public var body: some View {
        ThemedDivider()
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label { title } icon: { Image(systemName: symbol).foregroundStyle(Color(uiColor: iconColor)) }
                    .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                Button(action: open) { link.font(.subheadline) }
                    .buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.accent))
            }
            detail
        }
    }
}

public struct DataExchangeTaskSheet<Content: View, Footer: View>: View {
    public init(title: Text, sharing: Binding<ShareFiles?>, onShared: @escaping @MainActor @Sendable () -> Void,
                closeIdentifier: String = "closeExportTask", @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title; self._sharing = sharing; self.onShared = onShared; self.closeIdentifier = closeIdentifier
        self.content = content(); self.footer = footer()
    }

    @Environment(\.dismiss) private var dismiss
    let title: Text
    @Binding var sharing: ShareFiles?
    let onShared: @MainActor @Sendable () -> Void
    var closeIdentifier = "closeExportTask"
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    public var body: some View {
        NavigationStack {
            content.themedPage()
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        SystemToolbarButton("关闭", role: .close) { dismiss() }.toolbarGlyph()
                            .accessibilityIdentifier(closeIdentifier)
                    }
                }
                .modifier(MetadataTaskBar { footer })
        }
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
            if let sharing { ShareSheet(files: sharing, onShared: onShared) }
        }
    }
}

public struct DataExchangeRunningView<Progress: View>: View {
    public init(title: Text, stopping: Bool, symbol: String = "square.and.arrow.up", @ViewBuilder progress: () -> Progress) {
        self.title = title; self.stopping = stopping; self.symbol = symbol; self.progress = progress()
    }

    @Environment(\.theme) private var theme
    let title: Text
    let stopping: Bool
    var symbol = "square.and.arrow.up"
    @ViewBuilder let progress: Progress

    public var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: symbol).font(.largeTitle)
                        .foregroundStyle(Color(uiColor: theme.accent)).accessibilityHidden(true)
                    title.font(.title.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    progress
                    if !stopping {
                        Text("可以关闭页面，稍后查看。", tableName: "MetadataExchange")
                            .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    }
                }.multilineTextAlignment(.center).padding(24).frame(maxWidth: 430)
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height)
            }
        }
    }
}

public struct MetadataTaskActions<Content: View>: View {
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    @ViewBuilder let content: Content

    public var body: some View {
        VStack(spacing: 0) {
            ThemedDivider()
            VStack(spacing: 8) { content }
                .frame(maxWidth: 460)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
    }
}

public struct MetadataTaskBar<Bar: View>: ViewModifier {
    public init(@ViewBuilder bar: () -> Bar) { self.bar = bar() }

    @ViewBuilder let bar: Bar
    @ViewBuilder public func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: .bottom, spacing: 0) { bar }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) { bar }
        }
    }
}

public struct MetadataStatusView: View {
    public init(symbol: String, title: String, message: String? = nil) {
        self.symbol = symbol; self.title = title; self.message = message
    }

    let symbol: String
    let title: String
    var message: String? = nil
    public var body: some View {
        ContentUnavailableView {
            Label { Text(verbatim: title) } icon: { Image(systemName: symbol) }
        } description: { if let message { Text(verbatim: message) } }
    }
}
