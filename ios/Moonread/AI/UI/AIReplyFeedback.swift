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
    var mailURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"; components.path = recipient
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        // Some mail clients interpret a literal plus as a space in query values.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

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
        let model = connection?.models.first { $0.id == entry.model }?.name ?? entry.model
        self.init(provider: connection?.name ?? String(localized: "已删除的连接"), model: model, text: text)
    }
    init(provider: String, model: String, text: String, version: String? = nil) {
        self.provider = provider; self.model = model; self.text = text
        self.version = version ?? "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))"
    }
}

/// One route for production and tests: native composer, default mail app, then manual copy.
enum AIReplyFeedbackDelivery {
    enum Route: Equatable { case composer, defaultMailApp, copyFallback }
    @MainActor static func route(_ feedback: AIReplyFeedback, canCompose: Bool,
                                openURL: (URL) async -> Bool) async -> Route {
        if canCompose { return .composer }
        if let url = feedback.mailURL, await openURL(url) { return .defaultMailApp }
        return .copyFallback
    }
}

@MainActor final class AIReplyFeedbackPresenter: NSObject, @preconcurrency MFMailComposeViewControllerDelegate {
    func present(_ feedback: AIReplyFeedback, from controller: UIViewController, theme: ThemeSurface) {
        guard controller.presentedViewController == nil else { return }
        Task { [weak controller] in
            #if DEBUG
            let forceCopy = ProcessInfo.processInfo.arguments.contains("--ui-testing")
                && ProcessInfo.processInfo.arguments.contains("--ui-test-feedback-copy")
            #else
            let forceCopy = false
            #endif
            let route = await AIReplyFeedbackDelivery.route(feedback, canCompose: !forceCopy && MFMailComposeViewController.canSendMail()) { url in
                if forceCopy { return false }
                return await UIApplication.shared.open(url, options: [:])
            }
            guard let controller, controller.viewIfLoaded?.window != nil, controller.presentedViewController == nil else { return }
            switch route {
            case .composer:
                let compose = MFMailComposeViewController()
                compose.mailComposeDelegate = self
                compose.setToRecipients([feedback.recipient])
                compose.setSubject(feedback.subject)
                compose.setMessageBody(feedback.body, isHTML: false)
                controller.present(compose, animated: true)
            case .defaultMailApp: break
            case .copyFallback:
                controller.present(UIHostingController(rootView: AIReplyFeedbackFallback(feedback: feedback).themeScope(theme)), animated: true)
            }
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
    @State private var copiedFields: Set<String> = []
    @State private var copiedAll = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutTokens.section) {
                    Text("无法打开邮件应用。可分别复制收件人、主题和正文，粘贴到邮件应用，检查并编辑后发送。")
                    field("recipient", title: "收件人", copyLabel: "复制收件人", text: feedback.recipient)
                    field("subject", title: "主题", copyLabel: "复制主题", text: feedback.subject)
                    field("body", title: "邮件正文", copyLabel: "复制正文", text: feedback.body)
                }.padding()
            }.themedPage().navigationTitle("反馈这条回复").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    Button {
                        UIPasteboard.general.string = feedback.copyText; copiedAll = true
                    } label: {
                        Label(copiedAll ? LocalizedStringKey("已复制") : LocalizedStringKey("复制全部"), systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(ThemedProminentButtonStyle()).padding().accessibilityIdentifier("aiFeedbackCopy")
                        .frame(maxWidth: .infinity).background(Color(uiColor: theme.surface))
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭", systemImage: "xmark") { dismiss() }.toolbarGlyph() } }
        }
    }
    private func field(_ id: String, title: LocalizedStringKey, copyLabel: LocalizedStringKey, text: String) -> some View {
        VStack(alignment: .leading, spacing: LayoutTokens.control) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button {
                    UIPasteboard.general.string = text; copiedFields.insert(id)
                } label: {
                    Label(copiedFields.contains(id) ? LocalizedStringKey("已复制") : copyLabel, systemImage: "doc.on.doc")
                        .font(.subheadline).frame(minHeight: LayoutTokens.hit)
                }.accessibilityIdentifier("aiFeedbackCopy-" + id)
            }
            Text(verbatim: text).textSelection(.enabled).accessibilityIdentifier(id == "body" ? "aiFeedbackBody" : "aiFeedback-" + id)
        }
    }
}
