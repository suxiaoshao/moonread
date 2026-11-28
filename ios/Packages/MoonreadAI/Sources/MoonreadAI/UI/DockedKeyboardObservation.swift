import SwiftUI
import UIKit

/// Only the observer extends behind the keyboard. The chat keeps SwiftUI's own avoidance.
struct DockedKeyboardObservation: UIViewRepresentable {
    @Binding var isDocked: Bool

    func makeUIView(context: Context) -> KeyboardGuideView { KeyboardGuideView(frame: .zero) }
    func updateUIView(_ view: KeyboardGuideView, context: Context) {
        view.isDocked = $isDocked
        view.setNeedsLayout()
    }

    final class KeyboardGuideView: UIView {
        var isDocked: Binding<Bool>?
        private var lastDocked: Bool?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            // Constraining a marker makes UIKit lay out the observer as the guide moves.
            let marker = UIView()
            marker.translatesAutoresizingMaskIntoConstraints = false
            addSubview(marker)
            NSLayoutConstraint.activate([
                marker.leadingAnchor.constraint(equalTo: leadingAnchor),
                marker.widthAnchor.constraint(equalToConstant: 0),
                marker.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
                marker.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        required init?(coder: NSCoder) { return nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard window != nil else { return }
            // With the default undocked behavior, the guide starts at the safe area
            // bottom when the soft keyboard does not occupy this view's bottom edge.
            let guide = keyboardLayoutGuide.layoutFrame
            let docked = guide.height > 0 && guide.minY < safeAreaLayoutGuide.layoutFrame.maxY - 0.5
            guard lastDocked != docked else { return }
            lastDocked = docked
            Task { @MainActor [weak self] in
                guard let self, self.window != nil, let docked = self.lastDocked,
                      self.isDocked?.wrappedValue != docked else { return }
                self.isDocked?.wrappedValue = docked
            }
        }
    }
}
