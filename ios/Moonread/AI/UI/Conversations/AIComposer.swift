import SwiftUI
import AISDKProvider
import AISDKProviderUtils

/// Input shared by conversations and quick tasks: same draft, send modes and stop.
struct AIComposer: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    let conversation: AIConversation
    var placement: AIChatView.Placement = .page
    var prompt: LocalizedStringKey = "向月读提问"
    var modelTarget: AIModelSelectionTarget
    /// Nil hides the reading-object menu.
    var pickingKind: Binding<AIReadingAttachment.Kind?>?
    @Binding var attachmentPreview: AIReadingAttachment?
    var inputFocused: FocusState<Bool>.Binding
    var onSend: () -> Void = {}
    var body: some View {
        let hasText = !conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: LayoutTokens.compact) {
            if !conversation.readingDraft.isEmpty {
                // Chip targets are 44pt tall; the drawn pill is inset, so rows need no extra gap.
                AIFlowLayout(spacing: 6, lineSpacing: 0) { attachmentChips }
            }
            TextField(prompt, text: Binding(get: { conversation.draft }, set: { ai.updateDraft(conversation.id, text: $0) }), prompt: Text(prompt).foregroundStyle(Color(uiColor: theme.secondary)), axis: .vertical)
                .lineLimit(1...6).textFieldStyle(.plain).focused(inputFocused).accessibilityIdentifier("aiInput")
                .padding(.horizontal, 4).padding(.top, conversation.readingDraft.isEmpty ? 6 : 0)
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
                AIModelPickerButton(target: modelTarget)
                if conversation.running && !hasText {
                    Button("停止", systemImage: "stop.fill") { ai.stop(conversation.id) }
                        .buttonStyle(AIComposerActionStyle()).accessibilityIdentifier("stopAI")
                } else {
                    Button("发送", systemImage: "arrow.up") { onSend(); ai.send(conversation.id) }
                        .buttonStyle(AIComposerActionStyle()).disabled(!hasText || conversation.submitting).accessibilityIdentifier("sendAI")
                }
                if conversation.running && hasText {
                    Menu {
                        Button("完成后发送") { onSend(); ai.send(conversation.id, mode: .followUp) }.disabled(conversation.submitting)
                        Button("停止", systemImage: "stop.fill") { ai.stop(conversation.id) }
                    } label: {
                        Image(systemName: "chevron.down").font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(uiColor: theme.ink))
                            .frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
                    }
                    .accessibilityLabel("发送方式")
                }
            }
        }
        .padding(.horizontal, LayoutTokens.compact).padding(.top, conversation.readingDraft.isEmpty ? LayoutTokens.compact : 2).padding(.bottom, 4)
        .background(Color(uiColor: placement == .page ? theme.surface : theme.raised), in: .rect(cornerRadius: LayoutTokens.floatingRadius))
        .overlay {
            RoundedRectangle(cornerRadius: LayoutTokens.floatingRadius)
                .strokeBorder(Color(uiColor: inputFocused.wrappedValue ? theme.focus : theme.border), lineWidth: LayoutTokens.border)
        }
        .padding(.horizontal, LayoutTokens.content).padding(.bottom, LayoutTokens.compact)
        .disabled(conversation.submitting || conversation.deleting)
    }

    @ViewBuilder private var attachmentChips: some View {
        ForEach(conversation.readingDraft) { attachment in
            HStack(spacing: 0) {
                Button { attachmentPreview = attachment } label: {
                    Label(attachment.summary, systemImage: attachment.symbol)
                        .labelStyle(AICompactLabelStyle())
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(Color(uiColor: theme.ink))
                        .padding(.leading, LayoutTokens.compact)
                        .frame(minHeight: LayoutTokens.hit).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button { ai.removeReadingAttachment(conversation.id, attachmentID: attachment.id) } label: {
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

/// Wraps short items onto shared lines; each item is capped to the row width.
struct AIFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat? = nil
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + (lineSpacing ?? spacing) * CGFloat(max(0, rows.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + (lineSpacing ?? spacing)
        }
    }
    private struct Row { var items: [(index: Int, size: CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }
    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > width { size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width { rows.append(Row()) }
            let gap = rows[rows.count - 1].items.isEmpty ? 0 : spacing
            rows[rows.count - 1].items.append((index, size))
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
