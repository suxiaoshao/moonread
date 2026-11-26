import MoonreadDesign
import SwiftUI

extension CatalogueTagSection {
    var title: String {
        switch kind {
        case .tag: tag
        case .untagged: String(localized: "未加标签")
        case .unindexed: String(localized: "未建立索引")
        }
    }
}

public struct LibraryDisplayMenu: View {
    @Binding var selection: LibraryLayout

    public init(selection: Binding<LibraryLayout>) { self._selection = selection }

    public var body: some View {
        Menu {
            LibraryDisplayPicker(selection: $selection)
        } label: {
            Label("显示方式", systemImage: "ellipsis")
        }
        .toolbarGlyph()
        .accessibilityIdentifier("libraryDisplayOptions")
    }
}
