import SwiftUI

/// Only mode changes rebuild the native picker. Typography updates must not
/// reconfigure its segment labels. The setter always targets live model state.
struct ReadingModePicker: View, Equatable {
    let mode: ReadingMode
    let update: (ReadingMode) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.mode == rhs.mode }

    var body: some View {
        Picker("阅读方式", selection: Binding(get: { mode }, set: { update($0) })) {
            Text("上下滚动").tag(ReadingMode.scroll).accessibilityIdentifier("modeScroll")
            Text("左右分页").tag(ReadingMode.pages).accessibilityIdentifier("modePages")
        }
    }
}
