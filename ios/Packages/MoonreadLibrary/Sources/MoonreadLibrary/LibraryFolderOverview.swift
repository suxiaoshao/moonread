import MoonreadDesign
import SwiftUI

public struct LibraryFolderOverview<Guidance: View>: View {
    let isRoot: Bool
    let bookCount: UInt64
    let error: String?
    let accent, secondary: Color
    let reconnect: () -> Void
    let showAll: () -> Void
    let guidance: () -> Guidance

    public init(isRoot: Bool, bookCount: UInt64, error: String?, accent: Color, secondary: Color,
                reconnect: @escaping () -> Void, showAll: @escaping () -> Void,
                @ViewBuilder guidance: @escaping () -> Guidance) {
        self.isRoot = isRoot
        self.bookCount = bookCount
        self.error = error
        self.accent = accent
        self.secondary = secondary
        self.reconnect = reconnect
        self.showAll = showAll
        self.guidance = guidance
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error {
                Button("重新连接", systemImage: "folder.badge.questionmark", action: reconnect)
                Text(verbatim: error).font(.caption).foregroundStyle(secondary)
            }
            if isRoot {
                Button(action: showAll) {
                    HStack(spacing: 8) {
                        Label("全部小说", systemImage: "books.vertical").font(.subheadline.weight(.medium)).foregroundStyle(accent)
                        Spacer()
                        Text("\(bookCount) 本小说").font(.caption).foregroundStyle(secondary)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(secondary)
                    }.frame(minHeight: ControlMetrics.hitSize).contentShape(.rect)
                }.buttonStyle(.plain).accessibilityIdentifier("library-all-books")
                guidance()
            }
        }
    }
}
