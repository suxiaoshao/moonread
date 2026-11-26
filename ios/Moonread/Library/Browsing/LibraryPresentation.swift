import MoonreadLibrary
import MoonreadDataTypes
import MoonreadCoreBindings
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

struct LibraryDisplayMenu: View {
    @Binding var selection: LibraryLayout

    var body: some View {
        Menu {
            LibraryDisplayPicker(selection: $selection)
        } label: {
            Label("显示方式", systemImage: "ellipsis")
        }
        .toolbarGlyph()
        .accessibilityIdentifier("libraryDisplayOptions")
    }
}

extension LibraryEntry {
    var libraryDetail: String {
        if case .folder(let folder) = item { return String(localized: "\(folder.childBookCount) 本小说") }
        if needsDownload { return String(localized: "待下载") }
        guard readingIdentity != nil, positionUtf8 > 0 else { return String(localized: "未读") }
        return libraryProgress + (chapterTitle.map { " · " + $0 } ?? "")
    }
    var libraryProgress: String { Self.progressLabel(needsDownload: needsDownload, fraction: libraryProgressFraction) }

    var libraryProgressFraction: Double? {
        guard readingIdentity != nil, positionUtf8 > 0 else { return nil }
        return ReadingProgress.fraction(positionUtf8, of: byteCount)
    }

    static func progressLabel(needsDownload: Bool, fraction: Double?) -> String {
        if needsDownload { return String(localized: "待下载") }
        guard let fraction else { return String(localized: "未读") }
        return fraction.formatted(.percent.precision(.fractionLength(1)))
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
                BookCoverView(title: URL(fileURLWithPath: preview.name).deletingPathExtension().lastPathComponent, compact: true, cover: preview.cover, contentSHA256: preview.readingKey?.formalSHA256, author: preview.author)
                    .frame(width: 39.5, height: 59)
            }
            if items.count < 2 { Color.clear.frame(width: 39.5, height: 59) }
        }.frame(width: 84, height: 59, alignment: .leading)
    }
}

struct LibraryBookTile: View {
    let model: LibraryModel
    let entry: LibraryEntry
    var showPath = false
    var match: LibraryQueryRules.SearchMatch?
    let interaction: LibraryItemInteraction
    @Environment(\.theme) private var theme
    private var label: LibraryItemLabel { .init(entry: entry, theme: theme, match: match) }

    var body: some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                Color.clear.aspectRatio(0.7, contentMode: .fit)
                label.title().font(.subheadline.weight(.medium)).lineLimit(2)
            }
            .fixedSize(horizontal: false, vertical: true)
            LibraryGridStatus(status: label.gridStatus, showsMenu: interaction.menuHost != nil)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .background {
            LibraryCoverButton(entry: entry, detail: label.gridStatus) {
                interaction.activate(entry, in: model)
            } cover: {
                cover
            } actions: {
                actions
            }
            .accessibilityAddTraits(interaction.isSelected ? .isSelected : [])
        }
        .overlay(alignment: .bottomTrailing) {
            if interaction.menuHost != nil {
                LibraryItemMore(entry: entry) { actions }
                    .padding(.bottom, LibraryCollectionSection.gridFooterSpacing)
            }
        }
    }

    private var cover: some View {
        label.cover(compact: false).aspectRatio(0.7, contentMode: .fit)
            .overlay {
                if interaction.isSelected {
                    RoundedRectangle(cornerRadius: entry.directory ? 7 : 6)
                        .fill(Color(uiColor: theme.accent).opacity(0.12)).allowsHitTesting(false)
                } else if !interaction.isEditing && !entry.directory {
                    LibraryFileAvailability(entry: entry)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if interaction.isEditing {
                    Image(systemName: interaction.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(Color(uiColor: theme.accent))
                        .padding(LayoutTokens.compact)
                }
            }
    }

    @ViewBuilder private var actions: some View {
        if let host = interaction.menuHost {
            LibraryItemMenu(model: model, entry: entry, host: host, showsLocation: showPath)
        }
    }
}

/// Grid uses the same section destinations as the collection's native list index,
/// with tap, scrub and VoiceOver buttons in a narrow rail clear of the tiles.
struct LibraryAlphabetIndex: View {
    let letters: [String]
    var current: String? = nil
    let jump: (String) -> Void
    @Environment(\.theme) private var theme
    @State private var active: String?
    var body: some View {
        VStack(spacing: 0) {
            ForEach(letters, id: \.self) { letter in
                Button { jump(letter) } label: {
                    Text(verbatim: letter).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(uiColor: current == letter ? theme.onAccent : theme.accent))
                        .frame(width: 18, height: 18)
                        .background { if current == letter { Circle().fill(Color(uiColor: theme.accent)) } }
                        .frame(width: 24, height: 18)
                }.accessibilityLabel(letter).accessibilityIdentifier("library-index-\(letter)")
                    .accessibilityAddTraits(current == letter ? .isSelected : [])
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

struct LibraryFileAvailability: View {
    let entry: LibraryEntry
    var compact = false
    @Environment(\.theme) private var theme
    var body: some View {
        if entry.needsDownload {
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
