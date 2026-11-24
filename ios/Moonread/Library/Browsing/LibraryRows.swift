import TipKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryEmptyFolder: View {
    @Environment(\.theme) private var theme
    let model: LibraryModel
    let location: LibraryLocation
    @State private var guide = false
    private var builtinRoot: Bool { location.shelfID == "builtin" && location.path.isEmpty }
    var body: some View {
        ScrollView {
            if builtinRoot && model.builtinDiscovery == .discovering {
                VStack {
                    MoonView(size: 64).accessibilityHidden(true)
                    ProgressView("正在发现云端小说").accessibilityIdentifier("builtinDiscoveryLoading")
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--ui-test-onboarding-cloud") {
                        Button { model.receiveCloudDiscovery(.init(generation: model.discoveryGeneration, revision: 1, gathered: true, items: [])) } label: { Text(verbatim: "Deliver injected discovery snapshot") }
                            .accessibilityIdentifier("onboardingDeliverSnapshot")
                    }
                    #endif
                    emptyActions
                }.padding()
            } else {
                ContentUnavailableView {
                    Label {
                        Text(builtinRoot && model.builtinDiscovery == .unavailable ? "暂未完成发现" : builtinRoot ? "还没有小说" : "空文件夹")
                            .accessibilityIdentifier(builtinRoot && model.builtinDiscovery == .unavailable ? "builtinDiscoveryUnavailable" : builtinRoot ? "builtinEmptyLibrary" : "emptyFolder")
                    } icon: { MoonView(size: 64).accessibilityHidden(true) }
                } description: {
                    if builtinRoot && model.builtinDiscovery != .unavailable { Text("导入 TXT，或从“文件”App 拖进来") }
                } actions: {
                    if builtinRoot && model.builtinDiscovery == .unavailable { Button("重试") { model.retryCloudDiscovery() } }
                    emptyActions
                }
            }
        }.sheet(isPresented: $guide) {
            NavigationStack { UsageGuideView().toolbar {
                ToolbarItem(placement: .confirmationAction) { SystemToolbarButton("关闭", role: .close) { guide = false } }
            } }
        }.allowsHitTesting(location.shelfID == "builtin")
    }
    @ViewBuilder private var emptyActions: some View {
        if location.shelfID == "builtin" {
            Button("导入小说", systemImage: "square.and.arrow.down") { model.chooseFiles(.novels(location)) }
                .buttonStyle(.borderedProminent).tint(Color(uiColor: theme.accent))
                .foregroundStyle(Color(uiColor: theme.onAccent)).accessibilityIdentifier("emptyFolderImport")
            if builtinRoot { Button("使用指南") { guide = true }.accessibilityIdentifier("emptyLibraryGuide") }
        }
    }
}

/// Editing belongs to the collection. Browsing can use any navigation host.
@MainActor
enum LibraryItemInteraction {
    case browse(LibraryBrowsingHost, beforeOpen: (() -> Void)? = nil)
    case selecting(selected: Bool)

    var isEditing: Bool {
        if case .selecting = self { return true }
        return false
    }
    var isSelected: Bool {
        if case .selecting(let selected) = self { return selected }
        return false
    }
    var menuHost: LibraryBrowsingHost? {
        if case .browse(let host, _) = self, host.allowsFileBrowsing { return host }
        return nil
    }
    func activate(_ entry: LibraryEntry, in model: LibraryModel) {
        if case .browse(let host, let beforeOpen) = self {
            beforeOpen?()
            host.open(entry, in: model)
        }
    }
}

@MainActor struct LibraryItemLabel {
    let entry: LibraryEntry
    let theme: ThemeSurface
    var match: LibraryQueryRules.SearchMatch?

    func title() -> Text {
        let range: Range<String.Index>?
        if case .title(let hit) = match { range = hit } else { range = nil }
        return Text(Self.highlight(entry.title, range: range, theme: theme))
            .foregroundColor(Color(uiColor: theme.ink))
    }

    var authorMatched: Bool {
        if case .author = match { return true }
        return false
    }

    func author() -> Text? {
        if case .author(let author, let range) = match {
            return Text(Self.highlight(author, range: range, theme: theme))
        }
        guard let author = entry.displayMetadata?.author.trimmingCharacters(in: .whitespacesAndNewlines),
              !author.isEmpty else { return nil }
        return Text(verbatim: author)
    }

    var status: Text {
        Text(verbatim: entry.directory ? entry.libraryDetail : entry.libraryProgress)
    }

    var gridStatus: Text {
        if authorMatched, let author = author() { return Text("作者 \(author)") }
        return status
    }

    func pathText(in model: LibraryModel) -> Text {
        Text(verbatim: model.shelfTitle(entry.shelfId) + (entry.parentPath.isEmpty ? "" : " / " + entry.parentPath))
    }

    @ViewBuilder func cover(compact: Bool) -> some View {
        if case .folder(let folder) = entry.item {
            LibraryFolderCover(previews: folder.coverPreviews)
        } else {
            BookCoverView(title: entry.title, compact: compact, cover: entry.displayMetadata?.cover,
                          contentSHA256: entry.readingIdentity?.formalSHA256, author: entry.displayMetadata?.author)
        }
    }

    static func highlight(_ value: String, range: Range<String.Index>?, theme: ThemeSurface) -> AttributedString {
        var text = AttributedString(value)
        if let range, let lower = AttributedString.Index(range.lowerBound, within: text),
           let upper = AttributedString.Index(range.upperBound, within: text), lower < upper {
            text[lower..<upper].backgroundColor = Color(uiColor: theme.search)
            text[lower..<upper].foregroundColor = Color(uiColor: theme.accent)
        }
        return text
    }

}

/// The hit area extends above the aligned glyph without increasing the row height.
struct LibraryItemMore<Actions: View>: View {
    let entry: LibraryEntry
    @ViewBuilder let actions: Actions
    @Environment(\.theme) private var theme

    var body: some View {
        Menu { actions } label: {
            Color.clear
                .frame(width: LayoutTokens.hit, height: LayoutTokens.hit)
                .overlay(alignment: .bottom) {
                    Text(Image(systemName: "ellipsis"))
                        .font(.caption)
                        .foregroundStyle(Color(uiColor: theme.secondary))
                }
                .contentShape(.interaction, Rectangle())
        }
        .accessibilityLabel(String(localized: "\(entry.name)的操作"))
    }
}

/// Uses the mounted cover as the native context-menu lift, independently of the tap target.
struct LibraryCoverPreviewShape: Shape {
    var size: CGSize?
    var isFolder = false

    func path(in rect: CGRect) -> Path {
        let cover = size.map {
            CGRect(x: rect.minX, y: rect.midY - $0.height / 2, width: $0.width, height: $0.height)
        } ?? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.width / 0.7)
        return RoundedRectangle(cornerRadius: isFolder ? 7 : size == nil ? 6 : 3).path(in: cover)
    }
}

/// The book's text is laid out above this button, outside the system menu's source.
struct LibraryCoverButton<Cover: View, Actions: View>: View {
    let entry: LibraryEntry
    var size: CGSize?
    let detail: Text
    let open: () -> Void
    @ViewBuilder let cover: Cover
    @ViewBuilder let actions: Actions

    var body: some View {
        Button(action: open) {
            cover
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: size == nil ? .topLeading : .leading)
                .contentShape(.interaction, .rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library-file-\(entry.name)")
        .accessibilityLabel(Text(verbatim: entry.title))
        .accessibilityValue(detail)
        .contentShape(.contextMenuPreview, LibraryCoverPreviewShape(size: size, isFolder: entry.directory))
        .contextMenu { actions }
    }
}

struct LibraryGridStatus: View {
    let status: Text
    let showsMenu: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            status.font(.caption)
                .lineLimit(1)
                .foregroundStyle(Color(uiColor: theme.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, showsMenu ? LayoutTokens.hit : 0)
                .padding(.bottom, LibraryCollectionSection.gridFooterSpacing)
        }
    }
}

private extension VerticalAlignment {
    private enum LibraryStatus: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.bottom] }
    }
    static let libraryStatus = VerticalAlignment(LibraryStatus.self)
}

struct LibraryFileRow: View {
    let model: LibraryModel
    let entry: LibraryEntry
    var showPath = false
    var recent = false
    var match: LibraryQueryRules.SearchMatch?
    let interaction: LibraryItemInteraction
    static let coverSize = CGSize(width: 56, height: 80)
    static let textLeading = coverSize.width + LayoutTokens.control
    @Environment(\.theme) private var theme

    private var label: LibraryItemLabel { .init(entry: entry, theme: theme, match: match) }
    private var showsMenu: Bool { recent || interaction.menuHost != nil }

    var body: some View {
        HStack(spacing: LayoutTokens.control) {
            Color.clear.frame(width: Self.coverSize.width, height: Self.coverSize.height)
            VStack(alignment: .leading) {
                label.title().font(.body.weight(.medium)).lineLimit(1)
                if let author = label.author() {
                    author.font(.caption).foregroundStyle(Color(uiColor: theme.secondary)).lineLimit(1)
                }
                statusLine.alignmentGuide(.libraryStatus) { $0[.bottom] }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, showsMenu ? LayoutTokens.hit : 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .background {
            LibraryCoverButton(entry: entry, size: Self.coverSize, detail: accessibilityDetail) {
                if recent { model.open(entry) }
                else { interaction.activate(entry, in: model) }
            } cover: {
                cover
            } actions: {
                actions
            }
        }
        .overlay(alignment: Alignment(horizontal: .trailing, vertical: .libraryStatus)) {
            if showsMenu { LibraryItemMore(entry: entry) { actions } }
        }
    }

    private var accessibilityDetail: Text {
        var detail = recent
            ? Text("\(RecentBookItem.chapter(entry)), \(RecentBookItem.progress(entry))")
            : label.status
        if let author = label.author() { detail = Text("\(author), \(detail)") }
        if showPath { detail = Text("\(detail), \(label.pathText(in: model))") }
        return detail
    }

    private var cover: some View {
        label.cover(compact: true)
            .frame(width: Self.coverSize.width, height: Self.coverSize.height)
            .overlay {
                if !interaction.isEditing && !entry.directory {
                    LibraryFileAvailability(entry: entry, compact: true)
                }
            }
    }

    private var statusLine: some View {
        HStack {
            if recent {
                RecentBookItem.chapter(entry)
                Spacer(minLength: 0)
                RecentBookItem.progress(entry).fixedSize()
            } else {
                label.status.layoutPriority(1)
                if showPath {
                    Text("·").accessibilityHidden(true)
                    label.pathText(in: model).truncationMode(.middle)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(Color(uiColor: theme.secondary))
        .lineLimit(1)
    }

    @ViewBuilder private var actions: some View {
        if recent {
            RecentBookActions(model: model, entry: entry)
        } else if let host = interaction.menuHost {
            LibraryItemMenu(model: model, entry: entry, host: host, showsLocation: showPath)
        }
    }
}
