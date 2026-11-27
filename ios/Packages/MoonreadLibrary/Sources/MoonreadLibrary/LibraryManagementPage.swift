import MoonreadCoreBindings
import MoonreadData
import MoonreadDesign
import SwiftUI

public struct LibraryManagementPage<ReferenceRow: View, ShelfRow: View>: View {
    @Binding var automaticIndex: Bool
    let shelves: [LibraryShelf]
    let references: [ShelfReference]
    let loading: UUID?
    let immediate: Bool
    let processingFiles: Bool
    let refresh: () async -> Void
    let add: () -> Void
    let remove: (LibraryShelf) -> Void
    let open: (LibraryShelf) -> Void
    let referenceRow: (ShelfReference) -> ReferenceRow
    let shelfRow: (LibraryShelf, ManagedShelfRow) -> ShelfRow

    public init(automaticIndex: Binding<Bool>, shelves: [LibraryShelf], references: [ShelfReference],
                loading: UUID?, immediate: Bool, processingFiles: Bool, refresh: @escaping () async -> Void, add: @escaping () -> Void,
                remove: @escaping (LibraryShelf) -> Void, open: @escaping (LibraryShelf) -> Void,
                @ViewBuilder referenceRow: @escaping (ShelfReference) -> ReferenceRow,
                @ViewBuilder shelfRow: @escaping (LibraryShelf, ManagedShelfRow) -> ShelfRow) {
        _automaticIndex = automaticIndex
        self.shelves = shelves
        self.references = references
        self.loading = loading
        self.immediate = immediate
        self.processingFiles = processingFiles
        self.refresh = refresh
        self.add = add
        self.remove = remove
        self.open = open
        self.referenceRow = referenceRow
        self.shelfRow = shelfRow
    }
    @Environment(\.theme) private var theme
    public var body: some View {
        ThemedGroupedList(sections: managementSections, theme: theme,
                          topInset: LayoutTokens.content,
                          refresh: refresh)
        .underNavigationBar()
        .themedPage()
        .navigationTitle("书架管理").navigationBarTitleDisplayMode(.inline)
        .modifier(PageLoadingOverlay(request: loading,
                                     hasContent: !shelves.isEmpty, label: "正在加载书架", immediate: immediate))
        .modifier(LibraryFileActivity(active: processingFiles))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加书架", systemImage: "plus", action: add)
                    .labelStyle(.iconOnly).toolbarGlyph().accessibilityIdentifier("addLibraryShelf")
            }
        }
    }
    private var managementSections: [ThemedGroupedList.Section] {
        var result: [ThemedGroupedList.Section] = [
            .init(id: "index", title: String(localized: "索引", table: "FullIndex"), rows: [
                .init("automaticFullIndex") {
                    Toggle(isOn: $automaticIndex) {
                        Text("新加入的书自动建立索引", tableName: "FullIndex")
                    }.accessibilityIdentifier("automaticFullIndex")
                }
            ])
        ]
        if !references.isEmpty {
            result.append(.init(id: "references", title: String(localized: "你之前添加过这些书架", table: "ShelfRecovery"),
                                footer: String(localized: "重新选择原来的文件夹，即可恢复对此书架的访问。"),
                                rows: references.map { reference in
                .init("reference-" + reference.id) {
                    referenceRow(reference)
                }
            }))
        }
        result.append(.init(id: "shelves", rows: shelves.map { shelf in
            let actions: [ThemedGroupedList.Action] = shelf.builtin ? [] : [
                .init(title: String(localized: "移除"), symbol: "minus.circle", destructive: true,
                      perform: { remove(shelf) })
            ]
            return .init("shelf-" + shelf.id,
                         action: shelf.error == nil ? { open(shelf) } : nil,
                         disclosure: shelf.error == nil, actions: actions, allowsFullSwipe: false) {
                shelfRow(shelf, ManagedShelfRow(shelf: shelf))
            }
        }))
        return result
    }
}

public struct ManagedShelfRow: View {
    let shelf: LibraryShelf
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .body) private var iconSize = 24.0

    public var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(shelf.builtin ? String(localized: "我的书架") : shelf.name)
                    .font(.body).foregroundStyle(Color(uiColor: theme.ink))
                if shelf.error != nil {
                    Text("需要重新连接").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive))
                } else {
                    Text("\(shelf.bookCount) 本 · \(shelf.location == "icloud" ? "iCloud Drive" : shelf.builtin ? String(localized: "本机") : String(localized: "文件夹"))")
                        .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                }
            }
        } icon: {
            Group {
                Image(systemName: shelf.builtin ? "books.vertical" : "folder").resizable().scaledToFit()
                    .foregroundStyle(Color(uiColor: theme.accent))
            }.frame(width: iconSize, height: iconSize).accessibilityHidden(true)
        }
    }
}
