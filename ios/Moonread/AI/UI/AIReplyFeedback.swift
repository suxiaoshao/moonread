import Foundation
import MessageUI
import SwiftUI

/// Capture only the selected reply and its own persisted request identity, never the conversation.
struct AIReplyFeedback: Equatable {
    let provider: String
    let model: String
    let text: String
    let version: String
    var recipient: String { AppLinks.supportEmail }
    var subject: String { String(localized: "月读回复反馈") }
    var body: String {
        [String(localized: "应用版本：\(version)"), String(localized: "服务商：\(provider)"),
         String(localized: "模型：\(model)"), "", String(localized: "所选回复："), text, "",
         String(localized: "请在发送前检查并移除不希望分享的内容。")].joined(separator: "\n")
    }
    var copyText: String { "\(recipient)\n\(subject)\n\n\(body)" }

    @MainActor init?(row: AIMessageRow, conversation: AIConversation, connections: [AIConnection]) {
        guard let turn = row.turnID else { return nil }
        let text: String
        if let native = row.nativeText, !native.streaming { text = native.text }
        else if case .actions(let answer, _) = row.content { text = answer }
        else { return nil }
        guard !text.isEmpty, let entry = conversation.entries.last(where: {
            $0.turn == turn && $0.message.object["role"]?.string == "assistant"
                && (row.id == turn + "/actions" || row.id.hasPrefix("\(turn)/s\($0.step)/"))
        }) else { return nil }
        let connection = connections.first { entry.provider == $0.id || entry.provider.hasPrefix($0.id + ":") }
        self.init(provider: connection?.name ?? entry.provider, model: entry.model, text: text)
    }
    init(provider: String, model: String, text: String, version: String? = nil) {
        self.provider = provider; self.model = model; self.text = text
        self.version = version ?? "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))"
    }
}

@MainActor final class AIReplyFeedbackPresenter: NSObject, @preconcurrency MFMailComposeViewControllerDelegate {
    func present(_ feedback: AIReplyFeedback, from controller: UIViewController, theme: ThemeSurface) {
        guard controller.presentedViewController == nil else { return }
        if MFMailComposeViewController.canSendMail() {
            let compose = MFMailComposeViewController()
            compose.mailComposeDelegate = self
            compose.setToRecipients([feedback.recipient])
            compose.setSubject(feedback.subject)
            compose.setMessageBody(feedback.body, isHTML: false)
            controller.present(compose, animated: true)
        } else {
            controller.present(UIHostingController(rootView: AIReplyFeedbackFallback(feedback: feedback).themeScope(theme)), animated: true)
        }
    }
    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        controller.dismiss(animated: true)
    }
}

private struct AIReplyFeedbackFallback: View {
    let feedback: AIReplyFeedback
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var copied = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutTokens.content) {
                    Text("此设备尚未配置邮件账户。可复制以下内容，粘贴到你使用的邮件应用，检查并编辑后发送。")
                    Text(verbatim: feedback.recipient).foregroundStyle(Color(uiColor: theme.accent))
                    Text(verbatim: feedback.subject).font(.headline)
                    Text(verbatim: feedback.body).textSelection(.enabled).accessibilityIdentifier("aiFeedbackBody")
                }.padding()
            }.themedPage().navigationTitle("反馈这条回复").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    Button {
                        UIPasteboard.general.string = feedback.copyText; copied = true
                    } label: {
                        Label(copied ? LocalizedStringKey("已复制") : LocalizedStringKey("复制邮件内容"), systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(ThemedProminentButtonStyle()).padding().accessibilityIdentifier("aiFeedbackCopy")
                        .frame(maxWidth: .infinity).background(Color(uiColor: theme.surface))
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭", systemImage: "xmark") { dismiss() }.toolbarGlyph() } }
        }
    }
}
