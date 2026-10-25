import SwiftUI

enum LibraryGrouping: String {
    case name, tags
}

extension LibraryTagGroup: Identifiable {
    public var id: String {
        switch kind {
        case .tag: "tag:" + tag
        case .untagged: "untagged"
        case .unindexed: "unindexed"
        }
    }
    var title: String {
        switch kind {
        case .tag: tag
        case .untagged: String(localized: "未加标签")
        case .unindexed: String(localized: "未建立索引")
        }
    }
}

enum LibraryLayout: String {
    case list, grid
}

/// Expose content height only in the dedicated scrolling regression. Normal
/// builds and other UI tests do not observe geometry or update view state.
struct LibraryGridTestGeometry: ViewModifier {
    #if DEBUG
    private static let enabled = ProcessInfo.processInfo.arguments.contains("--ui-test-grid-geometry")
    @State private var contentHeight = 0.0
    #endif

    @ViewBuilder func body(content: Content) -> some View {
        #if DEBUG
        if Self.enabled {
            content.onScrollGeometryChange(for: Double.self) { $0.contentSize.height } action: { _, height in
                contentHeight = height
            }.accessibilityValue(String(contentHeight))
        } else { content }
        #else
        content
        #endif
    }
}

/// Content headings scroll with the books, without List's pinned section gap.
struct LibraryListHeading: ViewModifier {
    func body(content: Content) -> some View {
        content.textCase(nil).listRowSeparator(.hidden).listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: LayoutTokens.compact, leading: LayoutTokens.page,
                                     bottom: 4, trailing: LayoutTokens.page))
    }
}

extension LibraryEntry {
    var libraryDetail: String {
        if directory { return String(localized: "\(childBookCount) 本小说") }
        if needsDownload { return String(localized: "待下载") }
        guard contentSha256 != nil, positionUtf8 > 0 else { return String(localized: "未读") }
        return libraryProgress + (chapterTitle.map { " · " + $0 } ?? "")
    }
    var libraryProgress: String {
        if needsDownload { return String(localized: "待下载") }
        guard contentSha256 != nil, positionUtf8 > 0 else { return String(localized: "未读") }
        return (Double(positionUtf8) / Double(max(1, byteCount))).formatted(.percent.precision(.fractionLength(1)))
    }
}

struct LibraryBookCover: View {
    let title: String
    var compact = false
    var cover: BookCoverAsset? = nil
    var coverLoader = CoverImageLoader.shared
    @Environment(\.theme) private var theme

    var body: some View {
        SystemTextBookCover(title: title, accent: Color(uiColor: theme.accent), surface: Color(uiColor: theme.accentSurface), compact: compact)
        .overlay { if let cover { BookCoverImage(cover: cover, pixels: compact ? 160 : 600, loader: coverLoader).clipped() } }
        .clipShape(.rect(cornerRadius: compact ? 3 : 6))
        .accessibilityHidden(true)
    }
}

/// A shelf of miniature covers, derived only from files inside this directory.
/// The fixed canvas keeps the same composition in both rows and grid tiles.
struct LibraryFolderCover: View {
    let previews: [LibraryCoverPreview]
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7).fill(Color(uiColor: theme.secondary).opacity(0.10))
                if previews.isEmpty {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 28, weight: .ultraLight))
                        .foregroundStyle(Color(uiColor: theme.secondary).opacity(0.6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // At most four miniatures; eager layout also keeps the
                    // scaled thumbnail stable when its hosting cell is reused.
                    VStack(spacing: 5) {
                        previewRow(Array(previews.prefix(2)))
                        previewRow(Array(previews.dropFirst(2).prefix(2)))
                    }.padding(7)
                }
            }.frame(width: 98, height: 137)
                .scaleEffect(x: geometry.size.width / 98, y: geometry.size.height / 137, anchor: .topLeading)
        }.accessibilityHidden(true)
    }

    private func previewRow(_ items: [LibraryCoverPreview]) -> some View {
        HStack(spacing: 5) {
            ForEach(items, id: \.fileId) { preview in
                LibraryBookCover(title: URL(fileURLWithPath: preview.name).deletingPathExtension().lastPathComponent, compact: true, cover: preview.cover)
                    .frame(width: 39.5, height: 59)
            }
            if items.count < 2 { Color.clear.frame(width: 39.5, height: 59) }
        }.frame(width: 84, height: 59, alignment: .leading)
    }
}

struct LibraryBookTile: View {
    let model: LibraryModel
    let entry: LibraryEntry
    var selected = false
    var select: (() -> Void)?
    var showPath = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { if let select { select() } else { model.open(entry) } } label: {
                VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                    Group {
                        if entry.directory {
                            LibraryFolderCover(previews: entry.coverPreviews).aspectRatio(0.7, contentMode: .fit)
                        } else { LibraryBookCover(title: entry.title, cover: entry.metadata?.cover).aspectRatio(0.7, contentMode: .fit) }
                    }
                        .overlay {
                            if selected {
                                RoundedRectangle(cornerRadius: entry.directory ? 7 : 6)
                                    .fill(Color(uiColor: theme.accent).opacity(0.12)).allowsHitTesting(false)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if select != nil {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(Color(uiColor: theme.accent))
                                    .padding(LayoutTokens.compact)
                            }
                        }
                    Text(verbatim: entry.title).font(.subheadline.weight(.medium))
                        .foregroundStyle(Color(uiColor: theme.ink)).lineLimit(2, reservesSpace: true)
                }.contentShape(.rect)
            }.buttonStyle(.plain).accessibilityIdentifier("library-file-\(entry.name)")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .overlay(alignment: .top) {
                    if select == nil && !entry.directory {
                        LibraryFileLoading(model: model, entry: entry).aspectRatio(0.7, contentMode: .fit)
                    }
                }
            HStack(spacing: 0) {
                Text(verbatim: entry.directory ? entry.libraryDetail : entry.libraryProgress).font(.caption)
                    .foregroundStyle(Color(uiColor: theme.secondary)).lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    LibraryItemMenu(model: model, entry: entry)
                    if showPath { LibraryLocationAction(model: model, entry: entry) }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Color(uiColor: theme.secondary))
                        .frame(width: LayoutTokens.hit, height: LayoutTokens.hit)
                }.accessibilityLabel(String(localized: "\(entry.name)的操作"))
                    .opacity(select == nil ? 1 : 0).disabled(select != nil).accessibilityHidden(select != nil)
            }
            if showPath {
                Text(verbatim: entry.parentPath.isEmpty ? model.shelfTitle(entry.shelfId) : entry.parentPath)
                    .font(.caption2).foregroundStyle(Color(uiColor: theme.secondary)).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Alphabet grouping is a localized platform presentation of the Rust file index.
/// Normalize Han names to pinyin so the visible letters and ordering agree.
struct LibraryNameGroup: Identifiable, Sendable {
    let id: String
    let entries: [LibraryEntry]

    static func key(_ name: String) -> String {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return (title.applyingTransform(.mandarinToLatin, reverse: false) ?? title)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .uppercased()
    }
    static func letter(_ key: String) -> String {
        guard let first = key.first, ("A"..."Z").contains(String(first)) else { return "#" }
        return String(first)
    }
    static func group(_ entries: [LibraryEntry]) -> [Self] {
        let keyed = entries.map { (entry: $0, key: key($0.title)) }
        let groups = Dictionary(grouping: keyed) { letter($0.key) }
        return groups.keys.sorted { $0 == "#" ? false : $1 == "#" ? true : $0 < $1 }.map { letter in
            let values = groups[letter, default: []].sorted {
                let order = $0.key.localizedStandardCompare($1.key)
                if order != .orderedSame { return order == .orderedAscending }
                return $0.entry.id < $1.entry.id
            }
            return Self(id: letter, entries: values.map(\.entry))
        }
    }
}

struct LibraryNativeIndexLabel: ViewModifier {
    let letter: String
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, *) { content.sectionIndexLabel(letter) }
        else { content }
    }
}
struct LibraryNativeIndexVisibility: ViewModifier {
    static var available: Bool { if #available(iOS 26, *) { true } else { false } }
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, *) { content.listSectionIndexVisibility(.visible) }
        else { content.padding(.trailing, 20) }
    }
}

/// SwiftUI's section index is List-only. Grid uses the same section destinations,
/// with tap, scrub and VoiceOver buttons in a narrow rail clear of the tiles.
struct LibraryAlphabetIndex: View {
    let letters: [String]
    let jump: (String) -> Void
    @Environment(\.theme) private var theme
    @State private var active: String?
    var body: some View {
        VStack(spacing: 0) {
            ForEach(letters, id: \.self) { letter in
                Button { jump(letter) } label: {
                    Text(verbatim: letter).font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 18)
                }.accessibilityLabel(letter).accessibilityIdentifier("library-index-\(letter)")
            }
        }.foregroundStyle(Color(uiColor: theme.accent))
            .contentShape(.rect)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    guard !letters.isEmpty else { return }
                    let index = min(letters.count - 1, max(0, Int(value.location.y / 18)))
                    if active != letters[index] { active = letters[index]; jump(letters[index]) }
                }.onEnded { _ in active = nil }
            )
            .padding(.trailing, 2)
    }
}

struct LibraryFileLoading: View {
    let model: LibraryModel
    let entry: LibraryEntry
    var compact = false
    @Environment(\.theme) private var theme
    var body: some View {
        if model.openingFileID == entry.id && model.showsFileLoading {
            Button { model.cancelOpening() } label: {
                ZStack {
                    Color(uiColor: theme.accentSurface)
                    VStack(spacing: compact ? 5 : 8) {
                        if let progress = model.fileProgress {
                            ProgressView(value: progress).progressViewStyle(.linear)
                                .tint(Color(uiColor: theme.accent))
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                                .font(compact ? .caption2 : .caption).monospacedDigit()
                                .foregroundStyle(Color(uiColor: theme.ink))
                        } else {
                            ProgressView().progressViewStyle(.circular)
                                .tint(Color(uiColor: theme.accent))
                        }
                    }.padding(.horizontal, compact ? 6 : 12).frame(maxWidth: 92)
                }.clipShape(.rect(cornerRadius: compact ? 3 : 6)).contentShape(.rect)
            }.buttonStyle(.plain).accessibilityLabel("取消下载")
                .accessibilityValue(model.fileProgress.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? String(localized: "正在获取文件"))
                .accessibilityIdentifier("library-file-loading")
        } else if entry.needsDownload {
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                Image(systemName: "icloud.and.arrow.down")
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(Color(uiColor: theme.ink))
                    .padding(4).background(Color(uiColor: theme.raised), in: .capsule)
                    .padding(compact ? 2 : 6)
            }.allowsHitTesting(false).accessibilityLabel("待下载")
        }
    }
}

struct LibraryLocationAction: View {
    let model: LibraryModel
    let entry: LibraryEntry
    var body: some View {
        Button("所在文件夹", systemImage: "folder") { model.path.append(.folder(entry.parent)) }
            .accessibilityIdentifier("library-result-path")
    }
}
