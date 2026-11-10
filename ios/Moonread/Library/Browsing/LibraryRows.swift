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

struct LibraryFileRow: View {
    let model: LibraryModel
    let entry: LibraryEntry
    var showPath = false
    var query = ""
    var select: (() -> Void)? = nil
    static let coverSize = CGSize(width: 32, height: 44)
    private var coverSize: CGSize { Self.coverSize }
    static let textLeading: CGFloat = 32 + LayoutTokens.control
    @ScaledMetric(relativeTo: .body) private var rowHeight = 60.0
    @Environment(\.theme) private var theme
    var body: some View {
            HStack(spacing: 4) {
                Button { if let select { select() } else { model.open(entry) } } label: {
                    HStack(spacing: LayoutTokens.control) {
                        if case .folder(let folder) = entry.item {
                            LibraryFolderCover(previews: folder.coverPreviews).frame(width: coverSize.width, height: coverSize.height)
                        } else { BookCoverView(title: entry.title, compact: true, cover: entry.metadata?.cover, contentSHA256: entry.contentSha256, author: entry.metadata?.author).frame(width: coverSize.width, height: coverSize.height) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(highlighted).font(.body.weight(.medium)).lineLimit(1)
                            if showPath {
                                HStack(spacing: 6) {
                                    Text(verbatim: entry.directory ? entry.libraryDetail : entry.libraryProgress)
                                        .fixedSize(horizontal: true, vertical: false)
                                    Text("·").accessibilityHidden(true)
                                    HStack(spacing: 4) {
                                        Image(systemName: "folder").accessibilityHidden(true)
                                        Text(verbatim: model.shelfTitle(entry.shelfId) + (entry.parentPath.isEmpty ? "" : " / " + entry.parentPath))
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                }.font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                                    .lineLimit(1)
                            } else {
                                Text(verbatim: entry.libraryDetail).font(.caption).foregroundStyle(Color(uiColor: theme.secondary)).lineLimit(1)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.vertical, LayoutTokens.compact).contentShape(.rect)
                }.buttonStyle(.plain).accessibilityIdentifier("library-file-\(entry.name)")
                    .overlay(alignment: .leading) {
                        if select == nil && !entry.directory {
                            LibraryFileAvailability(entry: entry, compact: true).frame(width: coverSize.width, height: coverSize.height)
                        }
                    }
                if select == nil {
                    Menu {
                        LibraryItemMenu(model: model, entry: entry)
                        if showPath { LibraryLocationAction(model: model, entry: entry) }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: LayoutTokens.hit, height: LayoutTokens.hit).foregroundStyle(Color(uiColor: theme.secondary))
                    }.accessibilityLabel(String(localized: "\(entry.name)的操作"))
                }
            }.frame(height: rowHeight)
    }
    private var highlighted: AttributedString {
        var text = AttributedString(entry.title); text.foregroundColor = Color(uiColor: theme.ink)
        if !query.isEmpty, let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].backgroundColor = Color(uiColor: theme.search); text[range].foregroundColor = Color(uiColor: theme.accent)
        }
        return text
    }
}
