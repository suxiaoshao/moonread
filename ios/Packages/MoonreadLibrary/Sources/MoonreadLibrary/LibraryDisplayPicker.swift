import SwiftUI

public enum LibraryLayout: String {
    case list, grid
}

public struct LibraryDisplayPicker: View {
    @Binding private var selection: LibraryLayout

    public init(selection: Binding<LibraryLayout>) { _selection = selection }

    public var body: some View {
        Picker("显示方式", selection: $selection) {
            Label("列表", systemImage: "list.bullet").tag(LibraryLayout.list)
            Label("网格", systemImage: "square.grid.3x3").tag(LibraryLayout.grid)
        }
        .pickerStyle(.inline)
    }
}
