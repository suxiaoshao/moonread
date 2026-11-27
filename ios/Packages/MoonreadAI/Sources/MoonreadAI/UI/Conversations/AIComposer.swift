import MoonreadDesign
import MoonreadCoreBindings
import SwiftUI
import AISDKProvider
import AISDKProviderUtils

/// Input shared by conversations and quick tasks: same draft, send modes and stop.
struct AIComposer: View {
    @Environment(AIService.self) private var ai
    let conversation: AIConversation
    var placement: AIChatPlacement = .page
    var prompt: LocalizedStringKey = "向月读提问"
    var modelTarget: AIModelSelectionTarget
    /// Nil hides the reading-object menu.
    var pickingKind: Binding<AIReadingAttachment.Kind?>?
    @Binding var attachmentPreview: AIReadingAttachment?
    var inputFocused: FocusState<Bool>.Binding
    var onSend: () -> Void = {}
    var body: some View {
        AIChatComposer(
            placement: placement, prompt: prompt,
            draft: Binding(get: { conversation.draft }, set: { ai.updateDraft(conversation.id, text: $0) }),
            attachments: conversation.readingDraft, running: conversation.running, submitting: conversation.submitting,
            deleting: conversation.deleting, pickingKind: pickingKind, attachmentPreview: $attachmentPreview,
            inputFocused: inputFocused, send: { mode in onSend(); ai.send(conversation.id, mode: mode) },
            stop: { ai.stop(conversation.id) }, removeAttachment: { ai.removeReadingAttachment(conversation.id, attachmentID: $0) }
        ) {
            AIModelPickerButton(target: modelTarget)
        }
    }
}
