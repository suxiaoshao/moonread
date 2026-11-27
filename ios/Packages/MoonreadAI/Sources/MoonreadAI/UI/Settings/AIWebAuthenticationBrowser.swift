import AuthenticationServices
import SwiftUI

/// The browser never consumes OAuth callbacks: only the validated loopback listener can finish sign-in.
@MainActor protocol AIWebAuthenticationSession: AnyObject {
    var prefersEphemeralWebBrowserSession: Bool { get set }
    var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)? { get set }
    func start() -> Bool
    func cancel()
}
extension ASWebAuthenticationSession: AIWebAuthenticationSession {}

public struct AIWebAuthenticationBrowser: UIViewRepresentable {
    let url: URL
    let onFailure: (Error) -> Void
    public init(url: URL, onFailure: @escaping (Error) -> Void) {
        self.url = url; self.onFailure = onFailure
    }
    public func makeCoordinator() -> Coordinator { Coordinator(url: url, onFailure: onFailure) }
    public func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.attached = { [weak coordinator = context.coordinator] window in coordinator?.start(in: window) }
        return view
    }
    public func updateUIView(_ view: AnchorView, context: Context) {}
    public static func dismantleUIView(_ view: AnchorView, coordinator: Coordinator) {
        view.attached = nil
        coordinator.stop()
    }
    public final class AnchorView: UIView {
        var attached: ((UIWindow) -> Void)?
        public override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { attached?(window) }
        }
    }
    @MainActor public final class Coordinator {
        // No authorization request uses this scheme. It keeps ASWebAuth alive until loopback settles.
        static let callback = ASWebAuthenticationSession.Callback.customScheme("moonread-auth-session-unused")
        typealias Factory = (URL, @escaping ASWebAuthenticationSession.CompletionHandler) -> any AIWebAuthenticationSession
        private let url: URL
        private let makeSession: Factory
        private let onFailure: (Error) -> Void
        private var session: (any AIWebAuthenticationSession)?
        private var presentation: (any ASWebAuthenticationPresentationContextProviding)?
        private let makePresentation: (AnyObject) -> any ASWebAuthenticationPresentationContextProviding
        private var stopped = false
        init(url: URL, makeSession: @escaping Factory = { url, completion in
            ASWebAuthenticationSession(url: url, callback: Coordinator.callback, completionHandler: completion)
        }, makePresentation: @escaping (AnyObject) -> any ASWebAuthenticationPresentationContextProviding = { Presentation(window: $0 as! UIWindow) }, onFailure: @escaping (Error) -> Void) {
            self.makePresentation = makePresentation
            self.url = url; self.makeSession = makeSession; self.onFailure = onFailure
        }
        func start(in anchor: AnyObject) {
            guard session == nil, !stopped else { return }
            let session = makeSession(url) { @Sendable [weak self] _, error in
                Task { @MainActor [weak self] in self?.finished(error) }
            }
            presentation = makePresentation(anchor)
            session.presentationContextProvider = presentation
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() { finished(AIError.invalidResponse) }
        }
        func stop() {
            stopped = true
            let session = session; self.session = nil
            session?.cancel()
            presentation = nil
        }
        private func finished(_ error: Error?) {
            guard !stopped else { return }
            stop()
            let value = error as NSError?
            if value?.domain == ASWebAuthenticationSessionErrorDomain,
               value?.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                onFailure(AIChatGPTError.loginCancelled)
            } else { onFailure(error ?? AIError.invalidResponse) }
        }
        final class Presentation: NSObject, ASWebAuthenticationPresentationContextProviding {
            let window: UIWindow
            init(window: UIWindow) { self.window = window }
            func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
        }
    }
}
