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

    func detail(showsChapter: Bool = false) -> Text {
        if case .author(let name, let range) = match {
            let author = Text(Self.highlight(name, range: range, theme: theme))
            return Text("作者 \(author)")
        }
        return Text(verbatim: showsChapter || entry.directory ? entry.libraryDetail : entry.libraryProgress)
    }

    func pathText(in model: LibraryModel) -> Text {
        Text(verbatim: model.shelfTitle(entry.shelfId) + (entry.parentPath.isEmpty ? "" : " / " + entry.parentPath))
    }

    func path(in model: LibraryModel) -> some View {
        let full = pathText(in: model)
        return Label {
            full.lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: "folder").accessibilityHidden(true)
        }
        .labelStyle(CompactLibraryPathLabel())
        .accessibilityLabel(full)
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

private struct CompactLibraryPathLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

struct LibraryItemMore<Actions: View>: View {
    let entry: LibraryEntry
    @ViewBuilder let actions: Actions
    @Environment(\.theme) private var theme

    var body: some View {
        Menu { actions } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(Color(uiColor: theme.secondary))
                .frame(width: LayoutTokens.hit, height: LayoutTokens.hit)
        }
        .accessibilityLabel(String(localized: "\(entry.name)的操作"))
    }
}

struct LibraryFileRow: View {
    let model: LibraryModel
    let entry: LibraryEntry
    var showPath = false
    var match: LibraryQueryRules.SearchMatch?
    let interaction: LibraryItemInteraction
    static let coverSize = CGSize(width: 32, height: 44)
    private var coverSize: CGSize { Self.coverSize }
    static let textLeading: CGFloat = 32 + LayoutTokens.control
    @ScaledMetric(relativeTo: .body) private var rowHeight = 60.0
    @Environment(\.theme) private var theme
    private var label: LibraryItemLabel { .init(entry: entry, theme: theme, match: match) }
    var body: some View {
            HStack(spacing: 4) {
                Button { interaction.activate(entry, in: model) } label: {
                    HStack(spacing: LayoutTokens.control) {
                        label.cover(compact: true).frame(width: coverSize.width, height: coverSize.height)
                        VStack(alignment: .leading, spacing: 4) {
                            label.title().font(.body.weight(.medium)).lineLimit(1)
                            if showPath {
                                HStack(spacing: 6) {
                                    label.detail().fixedSize(horizontal: !label.authorMatched, vertical: false)
                                    Text("·").accessibilityHidden(true)
                                    label.path(in: model)
                                }.font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                                    .lineLimit(1)
                            } else {
                                label.detail(showsChapter: true).font(.caption).foregroundStyle(Color(uiColor: theme.secondary)).lineLimit(1)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.vertical, LayoutTokens.compact).contentShape(.rect)
                }.buttonStyle(.plain).accessibilityIdentifier("library-file-\(entry.name)")
                    .overlay(alignment: .leading) {
                        if !interaction.isEditing && !entry.directory {
                            LibraryFileAvailability(entry: entry, compact: true).frame(width: coverSize.width, height: coverSize.height)
                        }
                    }
                if let host = interaction.menuHost {
                    LibraryItemMore(entry: entry) {
                        LibraryItemMenu(model: model, entry: entry, host: host, showsLocation: showPath)
                    }
                }
            }.frame(height: rowHeight)
                .contextMenu {
                    if let host = interaction.menuHost {
                        LibraryItemMenu(model: model, entry: entry, host: host, showsLocation: showPath)
                    }
                }
    }
}
