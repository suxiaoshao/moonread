import MoonreadCoreBindings
import MoonreadDesign
import SwiftUI

public struct ShelfRow: View {
    let shelf: LibraryShelf
    public init(shelf: LibraryShelf) { self.shelf = shelf }
    @Environment(\.theme) private var theme
    public var body: some View {
        HStack(spacing: 14) {
            Group {
                Image(systemName: shelf.builtin ? "books.vertical" : "folder").font(.system(size: 29, weight: .light))
                    .foregroundStyle(Color(uiColor: theme.accent))
            }.frame(width: 46, height: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text(shelf.builtin ? String(localized: "我的书架") : shelf.name).font(.body.weight(.medium)).foregroundStyle(Color(uiColor: theme.ink))
                if shelf.error != nil { Label("需要重新连接", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Color(uiColor: theme.destructive)) }
                else {
                    Text("\(shelf.bookCount) 本 · \(shelf.location == "icloud" ? "iCloud Drive" : shelf.builtin ? String(localized: "本机") : String(localized: "文件夹"))")
                        .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                }
            }
        }.padding(.vertical, 12)
    }
}
