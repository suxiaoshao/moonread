import MoonreadCoreBindings
import SwiftUI

/// Only mode changes rebuild the native picker. Typography updates must not
/// reconfigure its segment labels. The setter always targets live model state.
public struct ReadingModePicker: View, Equatable {
    let mode: ReadingMode
    let update: (ReadingMode) -> Void

    public nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.mode == rhs.mode }

    public init(mode: ReadingMode, update: @escaping (ReadingMode) -> Void) {
        self.mode = mode
        self.update = update
    }

    public var body: some View {
        Picker("阅读方式", selection: Binding(get: { mode }, set: { update($0) })) {
            Text("上下滚动").tag(ReadingMode.scroll).accessibilityIdentifier("modeScroll")
            Text("左右分页").tag(ReadingMode.pages).accessibilityIdentifier("modePages")
        }
    }
}
