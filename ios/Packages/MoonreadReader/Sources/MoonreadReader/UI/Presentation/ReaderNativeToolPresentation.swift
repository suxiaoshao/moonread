import MoonreadCoreBindings
import SwiftUI
import UIKit

struct ReaderModalChildProbe: UIViewControllerRepresentable {
    let host: ReaderPresentationHost
    final class Probe: UIViewController {
        weak var host: ReaderPresentationHost?
        var installationID: UUID?
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); publish() }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); publish() }
        func publish() {
            var ancestor = parent
            var hasChild = false
            while let controller = ancestor {
                if controller.presentedViewController != nil { hasChild = true; break }
                ancestor = controller.parent
            }
            guard let host, let installationID, host.token?.id == installationID, host.hasModalChild != hasChild else { return }
            Task { @MainActor [weak self, weak host] in
                guard self?.viewIfLoaded?.window != nil, host?.token?.id == installationID else { return }
                host?.hasModalChild = hasChild
            }
        }
    }
    func makeUIViewController(context: Context) -> Probe {
        let value = Probe(); value.host = host; value.installationID = host.token?.id; return value
    }
    func updateUIViewController(_ controller: Probe, context: Context) {
        controller.host = host
        controller.installationID = host.token?.id
        if controller.viewIfLoaded?.window != nil { controller.publish() }
    }
}


@MainActor struct ReaderNativeToolScope {
    let registry: ReaderNativeLayerRegistry
    let origin: ReaderPresentationOrigin
    let changed: () -> Void

    func attach(_ controller: UIViewController) {
        registry.register(controller, origin: origin)
        Task { @MainActor in changed() }
    }
}

extension EnvironmentValues {
    @Entry var readerNativeToolScope: ReaderNativeToolScope? = nil
}

private struct ReaderToolLayer: UIViewControllerRepresentable {
    let scope: ReaderNativeToolScope

    final class Probe: UIViewController {
        var scope: ReaderNativeToolScope?
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); attach() }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); attach() }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); attach() }
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if let scope { Task { @MainActor in scope.changed() } }
        }
        func attach() {
            guard let scope, let root = ReaderNativeLayerRegistry.presentedRoot(containing: self),
                  scope.registry.origin(for: root) != scope.origin else { return }
            scope.attach(root)
        }
    }

    func makeUIViewController(context: Context) -> Probe {
        let probe = Probe()
        probe.scope = scope
        return probe
    }

    func updateUIViewController(_ controller: Probe, context: Context) {
        controller.scope = scope
        controller.attach()
    }
}

private struct ReaderToolPresentation: ViewModifier {
    @Environment(\.readerNativeToolScope) private var scope
    func body(content: Content) -> some View {
        content.background {
            if let scope { ReaderToolLayer(scope: scope).allowsHitTesting(false) }
        }
    }
}

extension View {
    public func readerToolPresentation() -> some View { modifier(ReaderToolPresentation()) }
}

private struct ReaderToolConfirmation: ViewModifier {
    @Environment(\.readerNativeToolScope) private var scope
    @Binding var presented: Bool
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    let confirm: LocalizedStringResource
    let destructive: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if let scope {
            content.background {
                NativeAlert(configuration: self, scope: scope).allowsHitTesting(false)
            }
        } else {
            content.alert(Text(title), isPresented: $presented) {
                Button(role: destructive ? .destructive : nil, action: action) { Text(confirm) }
                Button("取消", role: .cancel) {}
            } message: { Text(message) }
        }
    }

    private struct NativeAlert: UIViewControllerRepresentable {
        let configuration: ReaderToolConfirmation
        let scope: ReaderNativeToolScope

        final class Anchor: UIViewController {
            var pending: NativeAlert?
            weak var alert: UIAlertController?
            override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
            override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); updatePresentation() }

            func updatePresentation() {
                guard let pending else { return }
                let configuration = pending.configuration
                guard configuration.presented else {
                    if let alert, !alert.isBeingDismissed { alert.dismiss(animated: true, completion: pending.scope.changed) }
                    return
                }
                guard alert == nil, viewIfLoaded?.window != nil else { return }
                let presenter = ReaderNativeLayerRegistry.presentedRoot(containing: self) ?? navigationController ?? parent
                guard let presenter, presenter.presentedViewController == nil else { return }
                let controller = UIAlertController(title: String(localized: configuration.title),
                    message: String(localized: configuration.message), preferredStyle: .alert)
                controller.addAction(UIAlertAction(title: String(localized: configuration.confirm),
                    style: configuration.destructive ? .destructive : .default) { _ in
                    configuration.action()
                    configuration.presented = false
                })
                controller.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel) { _ in
                    configuration.presented = false
                })
                alert = controller
                pending.scope.attach(controller)
                presenter.present(controller, animated: true, completion: pending.scope.changed)
            }
        }

        func makeUIViewController(context: Context) -> Anchor { Anchor() }
        func updateUIViewController(_ controller: Anchor, context: Context) {
            controller.pending = self
            Task { @MainActor [weak controller] in controller?.updatePresentation() }
        }
    }
}

extension View {
    public func readerToolConfirmation(_ title: LocalizedStringResource, isPresented: Binding<Bool>,
                                message: LocalizedStringResource, confirm: LocalizedStringResource,
                                destructive: Bool = false, action: @escaping () -> Void) -> some View {
        modifier(ReaderToolConfirmation(presented: isPresented, title: title, message: message,
                                        confirm: confirm, destructive: destructive, action: action))
    }
}
