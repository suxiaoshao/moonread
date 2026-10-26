import SwiftUI

/// The object a quick task works on, shown at the top of both phases.
struct AITaskObject {
    var title: String
    var subtitle: String?
    var cover: BookCoverAsset?
    var symbol = "book.closed"
}

/// Local setup exists only until Start. Started sessions use AIChatView.
struct AITaskSetup<Setup: View>: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    let object: AITaskObject
    var canStart = true
    var starting = false
    @ViewBuilder var setup: () -> Setup
    let start: (String, AIModelSelection) -> Void
    @State private var instruction = ""
    @State private var selection: AIModelSelection?
    @FocusState private var focused: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LayoutTokens.section) {
                AITaskObjectHeader(object: object)
                HStack { Text("模型"); Spacer(); AIModelPickerButton(draft: $selection) }
                setup()
                TextField("补充要求（可选）", text: $instruction, axis: .vertical)
                    .lineLimit(2...6).focused($focused).padding(LayoutTokens.control)
                    .background(Color(uiColor: theme.input), in: .rect(cornerRadius: LayoutTokens.inputRadius))
                    .accessibilityIdentifier("aiTaskInstruction")
                Button {
                    guard !starting, let selection else { return }
                    start(instruction.trimmingCharacters(in: .whitespacesAndNewlines), selection)
                }
                    label: { Text("开始").frame(maxWidth: .infinity) }
                    .buttonStyle(ThemedProminentButtonStyle()).controlSize(.large)
                    .disabled(selection == nil || !canStart || starting).accessibilityIdentifier("startAITask")
            }.padding(LayoutTokens.content)
        }.pageScrollMargins().scrollDismissesKeyboard(.interactively)
            .onAppear { if selection == nil { selection = ai.modelSelection(for: .defaults) } }
    }
}

/// Cover, title and subtitle of the task's object; large type stacks vertically.
struct AITaskObjectHeader: View {
    @Environment(\.theme) private var theme
    let object: AITaskObject
    var body: some View {
        HStack(alignment: .top, spacing: LayoutTokens.control) {
            if let cover = object.cover {
                LibraryBookCover(title: object.title, cover: cover).frame(width: 40, height: 56).accessibilityHidden(true)
            } else {
                Image(systemName: object.symbol).font(.title2).foregroundStyle(Color(uiColor: theme.secondary))
                    .frame(width: 40, height: 56).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: object.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                if let subtitle = object.subtitle {
                    Text(verbatim: subtitle).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                }
            }
            Spacer(minLength: 0)
        }.accessibilityElement(children: .combine)
    }
}
