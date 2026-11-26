import SwiftUI
import UIKit

public struct ShareSheet: UIViewControllerRepresentable {
    let files: ShareFiles?
    var text: String? = nil
    var onShared: (@MainActor @Sendable () -> Void)? = nil
    public init(files: ShareFiles?, text: String? = nil, onShared: (@MainActor @Sendable () -> Void)? = nil) {
        self.files = files; self.text = text; self.onShared = onShared
    }
    public func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: files?.urls.map { $0 as Any } ?? [text ?? ""], applicationActivities: nil)
        // An activity can outlive the SwiftUI sheet. Keep its input alive until
        // the activity completes, or the controller itself is released.
        controller.completionWithItemsHandler = { @Sendable [files, weak controller, onShared] _, completed, _, error in
            files?.finish()
            let shared = completed && error == nil
            Task { @MainActor in
                controller?.completionWithItemsHandler = nil
                if shared { onShared?() }
            }
        }
        return controller
    }
    public func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
