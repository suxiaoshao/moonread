import MoonreadDesign
import MoonreadCoreBindings
import SwiftUI

/// The object a quick task works on, shown at the top of both phases.
public struct AITaskObject {
    public var title: String
    public var subtitle: String?
    public var cover: BookCoverAsset?
    public var symbol: String
    public var contentSHA256: String?
    public var author: String?

    public init(title: String, subtitle: String? = nil, cover: BookCoverAsset? = nil,
                symbol: String = "book.closed", contentSHA256: String? = nil, author: String? = nil) {
        self.title = title; self.subtitle = subtitle; self.cover = cover; self.symbol = symbol
        self.contentSHA256 = contentSHA256; self.author = author
    }
}

/// Local setup exists only until Start. Started sessions use AIChatView.
public struct AITaskSetup<Setup: View>: View {
    public init(object: AITaskObject, canStart: Bool = true, starting: Bool = false,
                @ViewBuilder setup: @escaping () -> Setup,
                start: @escaping (String, AIModelSelection) -> Void) {
        self.object = object; self.canStart = canStart; self.starting = starting
        self.setup = setup; self.start = start
    }
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
    public var body: some View {
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
            }.padding([.horizontal, .top], LayoutTokens.content).padding(.bottom)
        }.navigationPageBackground(Color(uiColor: theme.surface))
            .scrollDismissesKeyboard(.interactively)
            .onAppear { if selection == nil { selection = ai.modelSelection(for: .defaults) } }
    }
}

/// Cover, title and subtitle of the task's object; large type stacks vertically.
public struct AITaskObjectHeader: View {
    public init(object: AITaskObject) { self.object = object }
    @Environment(\.theme) private var theme
    public let object: AITaskObject
    public var body: some View {
        HStack(alignment: .top, spacing: LayoutTokens.control) {
            if object.cover != nil || object.contentSHA256 != nil {
                MetadataCoverPreview(title: object.title, cover: object.cover, contentSHA256: object.contentSHA256, author: object.author).frame(width: 40, height: 56).accessibilityHidden(true)
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
