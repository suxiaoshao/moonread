import MoonreadDesign
import SwiftUI
import UIKit

/// UIKit owns dismissal so two consecutive decisions cannot coalesce into one
/// SwiftUI alert. Queue advancement always runs after the previous alert closes.
public struct LibraryDecisionAlert: UIViewControllerRepresentable {
    let resolveDecision: (UUID, Bool) async -> Void
    let resolveIndex: (Bool) -> Void

    public init(decision: LibraryPendingDecision?, indexPrompt: IdentityInventory?, theme: ThemeSurface,
                resolveDecision: @escaping (UUID, Bool) async -> Void, resolveIndex: @escaping (Bool) -> Void) {
        self.decision = decision
        self.indexPrompt = indexPrompt
        self.theme = theme
        self.resolveDecision = resolveDecision
        self.resolveIndex = resolveIndex
    }
    let decision: LibraryPendingDecision?
    var indexPrompt: IdentityInventory? = nil
    let theme: ThemeSurface
    public func makeUIViewController(context: Context) -> Controller { Controller() }
    public func updateUIViewController(_ controller: Controller, context: Context) {
        controller.resolveDecision = resolveDecision; controller.resolveIndex = resolveIndex; controller.decision = decision; controller.indexPrompt = indexPrompt
        controller.view.tintColor = theme.accent; controller.overrideUserInterfaceStyle = theme.style
        controller.presentIfNeeded()
    }
    public final class Controller: UIViewController {
        var resolveDecision: ((UUID, Bool) async -> Void)?
        var resolveIndex: ((Bool) -> Void)?
        var decision: LibraryPendingDecision?
        var indexPrompt: IdentityInventory?
        private weak var alert: UIAlertController?
        private var resolving = false
        public override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        public override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); presentIfNeeded() }
        func presentIfNeeded() {
            guard isViewLoaded, view.window != nil, alert == nil, !resolving,
                  presentedViewController == nil, let resolveIndex, let resolveDecision else { return }
            if decision == nil, let prompt = indexPrompt {
                let alert = UIAlertController(title: String(localized: "建立索引", table: "FullIndex"), message: nil, preferredStyle: .alert)
                alert.view.tintColor = view.tintColor
                let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: prompt.local.reduce(0) { $0 + $1.size }), countStyle: .file)
                let start = UIAlertAction(title: String(localized: "现在建立索引（\(prompt.local.count) 本，约 \(size)）", table: "FullIndex"), style: .default) { [weak self, weak alert] _ in
                    self?.finish(alert: alert) { resolveIndex( true) }
                }
                start.accessibilityIdentifier = "fullIndexPromptStart"
                alert.addAction(start)
                alert.addAction(UIAlertAction(title: String(localized: "以后再说", table: "FullIndex"), style: .cancel) { [weak self, weak alert] _ in
                    self?.finish(alert: alert) { resolveIndex( false) }
                })
                self.alert = alert
                present(alert, animated: true)
                return
            }
            guard let decision else { return }
            let title: String, message: String, accept: String, cancel: String
            switch decision {
            case .replacement(let command, _):
                title = String(localized: "替换同名文件？")
                message = String(localized: "目标目录中已有“\(command.filename)”，替换后将使用新文件。")
                accept = String(localized: "替换"); cancel = String(localized: "取消")
            case .trashUnsupported:
                title = String(localized: "所在位置不支持最近删除")
                message = String(localized: "本批中不支持最近删除的项目将永久删除，无法恢复。")
                accept = String(localized: "永久删除这些项目"); cancel = String(localized: "跳过")
            }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.view.tintColor = view.tintColor
            alert.addAction(UIAlertAction(title: accept, style: .destructive) { [weak self, weak alert] _ in
                self?.finish(alert: alert) { Task { await resolveDecision(decision.id, true) } }
            })
            alert.addAction(UIAlertAction(title: cancel, style: .cancel) { [weak self, weak alert] _ in
                self?.finish(alert: alert) { Task { await resolveDecision(decision.id, false) } }
            })
            self.alert = alert
            present(alert, animated: true)
        }
        var dismissPresentation: (((@escaping () -> Void)) -> Void)?
        func finish(alert: UIAlertController?, action: @escaping () -> Void) {
            guard !resolving else { return }; resolving = true
            let completed = { [weak self] in
                self?.alert = nil; self?.resolving = false
                action()
            }
            if let dismissPresentation { dismissPresentation(completed) }
            else if let alert, alert.isBeingDismissed, let transition = alert.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { _ in completed() }
            } else if let alert, alert.presentingViewController != nil {
                alert.dismiss(animated: true, completion: completed)
            } else { completed() }
        }
    }
}
