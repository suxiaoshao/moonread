import MoonreadDesign
import SwiftUI

/// Input shared by conversations and quick tasks.
public struct AIChatComposer<ModelPicker: View>: View {
    @Environment(\.theme) private var theme
    let placement: AIChatPlacement
    let prompt: LocalizedStringKey
    @Binding var draft: String
    let attachments: [AIReadingAttachment]
    let running: Bool
    let submitting: Bool
    let deleting: Bool
    let pickingKind: Binding<AIReadingAttachment.Kind?>?
    @Binding var attachmentPreview: AIReadingAttachment?
    let inputFocused: FocusState<Bool>.Binding
    let send: (AIAgentQueueMode) -> Void
    let stop: () -> Void
    let removeAttachment: (String) -> Void
    let modelPicker: () -> ModelPicker

    public init(
        placement: AIChatPlacement, prompt: LocalizedStringKey, draft: Binding<String>, attachments: [AIReadingAttachment],
        running: Bool, submitting: Bool, deleting: Bool, pickingKind: Binding<AIReadingAttachment.Kind?>?,
        attachmentPreview: Binding<AIReadingAttachment?>, inputFocused: FocusState<Bool>.Binding,
        send: @escaping (AIAgentQueueMode) -> Void, stop: @escaping () -> Void, removeAttachment: @escaping (String) -> Void,
        @ViewBuilder modelPicker: @escaping () -> ModelPicker
    ) {
        self.placement = placement
        self.prompt = prompt
        _draft = draft
        self.attachments = attachments
        self.running = running
        self.submitting = submitting
        self.deleting = deleting
        self.pickingKind = pickingKind
        _attachmentPreview = attachmentPreview
        self.inputFocused = inputFocused
        self.send = send
        self.stop = stop
        self.removeAttachment = removeAttachment
        self.modelPicker = modelPicker
    }

    private var bottomPadding: CGFloat {
        if #available(iOS 26, *) { 0 } else { LayoutTokens.compact }
    }

    public var body: some View {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: LayoutTokens.compact) {
            if !attachments.isEmpty {
                // Chip targets are 44pt tall; the drawn pill is inset, so rows need no extra gap.
                FlowLayout(spacing: 6, lineSpacing: 0) { attachmentChips }
            }
            TextField(prompt, text: $draft, prompt: Text(prompt).foregroundStyle(Color(uiColor: theme.secondary)), axis: .vertical)
                .lineLimit(1...6).textFieldStyle(.plain).focused(inputFocused).accessibilityIdentifier("aiInput")
                .padding(.horizontal, 4).padding(.top, attachments.isEmpty ? 6 : 0)
            HStack(alignment: .center, spacing: 4) {
                if let pickingKind { Menu {
                    Button("书籍", systemImage: "book") { pickingKind.wrappedValue = .book }
                    Button("书签", systemImage: "bookmark") { pickingKind.wrappedValue = .bookmark }
                    Button("批注", systemImage: "highlighter") { pickingKind.wrappedValue = .annotation }
                } label: {
                    Image(systemName: "plus").font(.body.weight(.medium))
                        .foregroundStyle(Color(uiColor: theme.ink))
                        .frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
                }
                .accessibilityLabel("添加阅读对象").accessibilityIdentifier("addReadingAttachment") }
                Spacer(minLength: 0)
                modelPicker()
                if running && !hasText {
                    Button("停止", systemImage: "stop.fill") { stop() }
                        .buttonStyle(AIComposerActionStyle()).accessibilityIdentifier("stopAI")
                } else {
                    Button("发送", systemImage: "arrow.up") { send(.steering) }
                        .buttonStyle(AIComposerActionStyle()).disabled(!hasText || submitting).accessibilityIdentifier("sendAI")
                }
                if running && hasText {
                    Menu {
                        Button("完成后发送") { send(.followUp) }.disabled(submitting)
                        Button("停止", systemImage: "stop.fill") { stop() }
                    } label: {
                        Image(systemName: "chevron.down").font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(uiColor: theme.ink))
                            .frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
                    }
                    .accessibilityLabel("发送方式")
                }
            }
        }
        .padding(.horizontal, LayoutTokens.compact).padding(.top, attachments.isEmpty ? LayoutTokens.compact : 2).padding(.bottom, 4)
        .background(Color(uiColor: placement == .page ? theme.surface : theme.raised), in: .rect(cornerRadius: LayoutTokens.floatingRadius))
        .overlay {
            RoundedRectangle(cornerRadius: LayoutTokens.floatingRadius)
                .strokeBorder(Color(uiColor: inputFocused.wrappedValue ? theme.focus : theme.border), lineWidth: LayoutTokens.border)
        }
        .padding(.horizontal, LayoutTokens.content).padding(.bottom, bottomPadding)
        .disabled(submitting || deleting)
    }

    @ViewBuilder private var attachmentChips: some View {
        ForEach(attachments) { attachment in
            HStack(spacing: 0) {
                Button { attachmentPreview = attachment } label: {
                    Label(attachment.summary, systemImage: attachment.symbol)
                        .labelStyle(AICompactLabelStyle())
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(Color(uiColor: theme.ink))
                        .padding(.leading, LayoutTokens.compact)
                        .frame(minHeight: LayoutTokens.hit).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button { removeAttachment(attachment.id) } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(uiColor: theme.secondary))
                        .frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("移除阅读附件")
            }
            .font(.footnote)
            // Full 44pt targets; only the pill inside them is drawn.
            .background { RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: theme.input)).padding(.vertical, 6) }
            .accessibilityElement(children: .contain)
        }
    }
}

/// The composer's primary action: accent fill with its paired foreground.
private struct AIComposerActionStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 32
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.body.weight(.semibold))
            .foregroundStyle(Color(uiColor: enabled ? theme.onAccent : theme.secondary))
            .frame(width: diameter, height: diameter)
            .background(Color(uiColor: enabled ? theme.accent : theme.selected), in: .circle)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
            .contentShape(Rectangle())
    }
}
