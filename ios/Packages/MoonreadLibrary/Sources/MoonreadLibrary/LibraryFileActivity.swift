import MoonreadDesign
import SwiftUI

public struct LibraryFileActivity: ViewModifier {
    let active: Bool

    public init(active: Bool) { self.active = active }

    public func body(content: Content) -> some View {
        content.toolbar {
            if active {
                ToolbarItem(placement: .topBarTrailing) {
                    InlineTaskProgress(title: Text("正在处理文件"))
                        .accessibilityIdentifier("libraryFileActivity")
                }
            }
        }
    }
}
