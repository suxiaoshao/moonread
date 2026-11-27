import SwiftUI

/// Native toolbar semantics with the project's iOS 18 fallback. Actions and
/// their save/discard policies remain with each presenting feature.
public struct SystemToolbarButton: View {
    public enum Role { case close, cancel, confirm }
    let title: LocalizedStringKey
    let role: Role
    let action: () -> Void
    public init(_ title: LocalizedStringKey, role: Role, action: @escaping () -> Void) {
        self.title = title; self.role = role; self.action = action
    }
    public var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                Button(role: nativeRole, action: action)
            } else {
                Button(title, systemImage: role == .confirm ? "checkmark" : "xmark",
                       role: role == .cancel ? .cancel : nil, action: action)
                    .labelStyle(.iconOnly)
            }
        }.accessibilityLabel(Text(title))
    }
    @available(iOS 26.0, *) private var nativeRole: ButtonRole {
        switch role { case .close: .close; case .cancel: .cancel; case .confirm: .confirm }
    }
}
