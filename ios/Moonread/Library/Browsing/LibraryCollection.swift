import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LibraryCollectionSection {
    static let gridSpacing = LayoutTokens.content
    static var gridFooterSpacing: CGFloat {
        let spacing = ViewSpacing()
        return min(gridSpacing, spacing.distance(to: spacing, along: .vertical))
    }

    enum ID: Hashable {
        case folderOverview, folderEntries, catalogueSummary, name(String), tag(String)
        case recent, searchSummary, searchResultHeader, searchAuthors, searchBooks, searchFolders, searchConversations
        case authorSummary, authorWorks
    }
    enum Format: Equatable {
        case directory, results, folderHits, recent

        var showsPath: Bool { self == .results || self == .folderHits }
        func usesGrid(_ layout: LibraryLayout) -> Bool { layout == .grid && self != .folderHits }
    }
    struct Row {
        let id: String
        let view: AnyView

        init(_ id: String, @ViewBuilder content: () -> some View) {
            self.id = id
            view = AnyView(content())
        }
    }
    enum Content {
        case files([LibraryEntry], Format)
        case rows([Row])
    }
    enum Header {
        case title(String, detail: String? = nil, accessibilityID: String? = nil)
        case action(AnyView)
    }

    let id: ID
    let content: Content
    var header: Header?

    var letter: String? {
        if case .name(let letter) = id { return letter }
        return nil
    }

    var firstFileID: String? {
        if case .files(let entries, _) = content { return entries.first?.id }
        return nil
    }
}

/// Only a real folder has a selection and can accept file operations from the collection.
struct LibraryCollectionFolder {
    let location: LibraryLocation
    let disabled: Bool
    @Binding var editing: EditMode
    @Binding var selection: Set<String>
    var emptyView: AnyView?
}

struct LibraryCollection: View {
    let model: LibraryModel
    let host: LibraryBrowsingHost
    let sections: [LibraryCollectionSection]
    var folder: LibraryCollectionFolder?
    var matches: [String: LibraryQueryRules.SearchMatch] = [:]
    var accessibilityID: String?
    var isSearch = false
    var hasSearchDrawer = false
    var hasTopAccessory = false
    var beforeOpen: (() -> Void)?
    var onRefresh: (() async -> Void)?
    @Environment(AIHost.self) private var ai
    @Environment(\.theme) private var theme
    @State private var alphabet = LibraryCollectionAlphabet()

    var body: some View {
        let letters = sections.compactMap(\.letter)
        LibraryCollectionViewport(
            content: self, ai: ai, theme: theme, layout: model.layout, alphabet: alphabet, letters: letters
        )
        .underNavigationBar(when: !hasTopAccessory, onEarlierSystems: hasSearchDrawer)
        .overlay(alignment: .trailing) {
            if model.layout == .grid && !letters.isEmpty {
                LibraryAlphabetIndex(letters: letters, current: alphabet.current ?? letters.first) { letter in
                    alphabet.jump(to: letter)
                }
            }
        }
    }
}

@MainActor @Observable private final class LibraryCollectionAlphabet {
    var current: String?
    @ObservationIgnored weak var controller: LibraryCollectionViewport.Controller?

    func jump(to letter: String) { controller?.jump(to: letter) }
}

/// UIKit owns range selection, autoscroll, cell reuse and list swipe actions.
private struct LibraryCollectionViewport: UIViewControllerRepresentable {
    let content: LibraryCollection
    let ai: AIHost
    let theme: ThemeSurface
    let layout: LibraryLayout
    let alphabet: LibraryCollectionAlphabet
    let letters: [String]

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        alphabet.controller = controller
        return controller
    }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.update(self) }

    final class Controller: UICollectionViewController, UICollectionViewDragDelegate, UICollectionViewDropDelegate {
        typealias Section = LibraryCollectionSection.ID
        enum Item: Hashable {
            case file(Section, String)
            case row(Section, String)

            var section: Section {
                switch self { case .file(let section, _), .row(let section, _): section }
            }
        }
        private final class DataSource: UICollectionViewDiffableDataSource<Section, Item> {
            var letters: [String] = []
            override func indexTitles(for collectionView: UICollectionView) -> [String]? {
                letters.isEmpty ? nil : letters
            }
            override func collectionView(_ collectionView: UICollectionView, indexPathForIndexTitle title: String, at index: Int) -> IndexPath {
                IndexPath(item: 0, section: snapshot().indexOfSection(.name(title)) ?? 0)
            }
        }
        private final class FileCell: UICollectionViewListCell {
            private var separatorLeading: NSLayoutConstraint?

            func alignSeparator(to leading: CGFloat?) {
                separatorLeading?.isActive = false
                separatorLeading = leading.map {
                    separatorLayoutGuide.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor, constant: $0)
                }
                separatorLeading?.isActive = true
            }
        }

        private static let headerKind = UICollectionView.elementKindSectionHeader
        private var configuration: LibraryCollectionViewport?
        private var entriesByID: [String: LibraryEntry] = [:]
        private var sectionsByID: [Section: LibraryCollectionSection] = [:]
        private var rowsByID: [Item: AnyView] = [:]
        private var source: DataSource!
        private var renderedEditing = false
        private var renderedSelection = Set<String>()
        private let refresh = UIRefreshControl()
        private weak var droppingSession: (any UIDropSession)?
        private var hoverID: String?
        private var springOpenedID: String?

        init() { super.init(collectionViewLayout: UICollectionViewFlowLayout()) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            collectionView.allowsMultipleSelectionDuringEditing = true
            collectionView.alwaysBounceVertical = true
            collectionView.register(FileCell.self, forCellWithReuseIdentifier: "file")
            collectionView.register(UICollectionViewListCell.self, forSupplementaryViewOfKind: Self.headerKind, withReuseIdentifier: "header")
            source = DataSource(collectionView: collectionView) { [weak self] collection, path, item in
                let cell = collection.dequeueReusableCell(withReuseIdentifier: "file", for: path)
                self?.configure(cell, item: item)
                return cell
            }
            source.supplementaryViewProvider = { [weak self] collection, kind, path in
                let header = collection.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "header", for: path)
                self?.configureHeader(header, at: path)
                return header
            }
            let layout = UICollectionViewCompositionalLayoutConfiguration()
            layout.contentInsetsReference = .layoutMargins
            collectionView.setCollectionViewLayout(UICollectionViewCompositionalLayout(sectionProvider: { [weak self] index, environment in
                self?.makeSection(index, environment: environment)
            }, configuration: layout), animated: false)
            refresh.addTarget(self, action: #selector(refreshFiles), for: .valueChanged)
        }

        func update(_ config: LibraryCollectionViewport) {
            loadViewIfNeeded()
            let old = configuration
            let folder = config.content.folder
            let editing = folder?.editing.isEditing == true
            let selection = folder?.selection ?? []
            let oldEntries = entriesByID
            let oldSections = sectionsByID
            let layoutChanged = old?.layout != config.layout || old?.theme != config.theme
            let editabilityChanged = renderedEditing != editing || old?.content.folder?.disabled != folder?.disabled
            let selectionChanges = renderedSelection.symmetricDifference(selection)
            renderedSelection = selection
            configuration = config
            renderedEditing = editing

            collectionView.backgroundColor = config.theme.canvas
            collectionView.tintColor = config.theme.accent
            if let emptyView = folder?.emptyView {
                if collectionView.backgroundView == nil || layoutChanged || editabilityChanged || old?.content.folder?.location != folder?.location {
                    collectionView.backgroundView = UIHostingConfiguration {
                        emptyView.disabled(folder?.disabled == true || editing).environment(\.theme, config.theme)
                    }.margins(.all, 0).makeContentView()
                }
            } else { collectionView.backgroundView = nil }
            collectionView.isUserInteractionEnabled = folder?.disabled != true
            if collectionView.isEditing != editing { collectionView.isEditing = editing }
            if collectionView.allowsMultipleSelection != editing { collectionView.allowsMultipleSelection = editing }
            collectionView.dragDelegate = folder == nil ? nil : self
            collectionView.dropDelegate = folder == nil ? nil : self
            collectionView.dragInteractionEnabled = folder != nil
            collectionView.isSpringLoaded = folder != nil
            collectionView.refreshControl = config.content.onRefresh != nil && !editing ? refresh : nil
            collectionView.keyboardDismissMode = config.content.isSearch ? .onDrag : .none
            collectionView.accessibilityIdentifier = config.content.accessibilityID ?? (config.layout == .grid ? "libraryGrid" : "libraryList")
            overrideUserInterfaceStyle = config.theme.style

            var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
            var newEntries: [String: LibraryEntry] = [:]
            var newSections: [Section: LibraryCollectionSection] = [:]
            var newRows: [Item: AnyView] = [:]
            for section in config.content.sections {
                snapshot.appendSections([section.id])
                newSections[section.id] = section
                switch section.content {
                case .files(let files, _):
                    snapshot.appendItems(files.map {
                        newEntries[$0.id] = $0
                        return .file(section.id, $0.id)
                    }, toSection: section.id)
                case .rows(let rows):
                    snapshot.appendItems(rows.map {
                        let item = Item.row(section.id, $0.id)
                        newRows[item] = $0.view
                        return item
                    }, toSection: section.id)
                }
            }

            // Compositional layout can ask about existing sections during a diff.
            // Keep both sets resolvable until UIKit switches snapshots.
            sectionsByID.merge(newSections) { _, current in current }
            entriesByID.merge(newEntries) { _, current in current }
            rowsByID.merge(newRows) { _, current in current }
            let previous = source.snapshot()
            let structureChanged = previous.sectionIdentifiers != snapshot.sectionIdentifiers
                || previous.sectionIdentifiers.contains { previous.itemIdentifiers(inSection: $0) != snapshot.itemIdentifiers(inSection: $0) }
            let letters = config.layout == .list ? config.letters : []
            let indexChanged = source.letters != letters
            source.letters = letters
            if structureChanged { source.apply(snapshot, animatingDifferences: false) }
            let headersChanged = newSections.values.contains { section in
                (oldSections[section.id]?.header == nil) != (section.header == nil)
            }
            if layoutChanged || indexChanged || headersChanged || oldSections.keys != newSections.keys {
                collectionView.collectionViewLayout.invalidateLayout()
            }
            sectionsByID = newSections
            entriesByID = newEntries
            rowsByID = newRows
            synchronizeSelection()

            for path in collectionView.indexPathsForVisibleItems {
                guard let item = source.itemIdentifier(for: path), let cell = collectionView.cellForItem(at: path) else { continue }
                switch item {
                case .row:
                    configure(cell, item: item)
                case .file(let section, let id):
                    let wasFirst = oldSections[section]?.firstFileID == id
                    let isFirst = newSections[section]?.firstFileID == id
                    if layoutChanged || editabilityChanged || selectionChanges.contains(id)
                        || wasFirst != isFirst
                        || oldEntries[id] != entriesByID[id] || old?.content.matches[id] != config.content.matches[id] {
                        configure(cell, item: item)
                    }
                }
            }
            for path in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: Self.headerKind) {
                if let header = collectionView.supplementaryView(forElementKind: Self.headerKind, at: path) {
                    configureHeader(header, at: path)
                }
            }
            updateAlphabet()
        }

        private func configure(_ cell: UICollectionViewCell, item: Item) {
            guard let config = configuration, let section = sectionsByID[item.section] else { return }
            cell.configurationUpdateHandler = nil
            cell.backgroundConfiguration = .clear()
            (cell as? UICollectionViewListCell)?.accessories = []
            cell.isAccessibilityElement = false
            cell.accessibilityIdentifier = nil
            cell.accessibilityLabel = nil
            cell.accessibilityTraits = []
            switch item {
            case .row:
                guard let view = rowsByID[item] else { return }
                let hosting = UIHostingConfiguration {
                    view.environment(\.theme, config.theme).environment(config.ai)
                        .foregroundStyle(Color(uiColor: config.theme.ink)).tint(Color(uiColor: config.theme.accent))
                }.margins(.all, 0)
                switch section.id {
                case .catalogueSummary, .folderOverview, .searchResultHeader, .authorSummary, .searchAuthors:
                    cell.contentConfiguration = hosting.minSize(height: 0)
                default:
                    cell.contentConfiguration = hosting
                }
                (cell as? FileCell)?.alignSeparator(to: nil)
            case .file(_, let id):
                guard case .files(_, let format) = section.content, let entry = entriesByID[id] else { return }
                let grid = format.usesGrid(config.layout)
                let selecting = renderedEditing
                let selected = config.content.folder?.selection.contains(id) == true
                let interaction: LibraryItemInteraction = selecting ? .selecting(selected: selected)
                    : .browse(config.content.host, beforeOpen: config.content.beforeOpen)
                if config.content.folder != nil {
                    configureFolderCell(cell, id: id, grid: grid, theme: config.theme)
                }
                (cell as? FileCell)?.alignSeparator(to: grid || selecting ? nil : LibraryFileRow.textLeading)
                let hosting = UIHostingConfiguration {
                    Group {
                        if format == .recent && grid {
                            RecentBookItem(model: config.content.model, entry: entry, layout: config.layout, fullPage: true)
                        } else if grid {
                            LibraryBookTile(model: config.content.model, entry: entry, showPath: format.showsPath,
                                            match: config.content.matches[id], interaction: interaction)
                        } else {
                            LibraryFileRow(model: config.content.model, entry: entry, showPath: format.showsPath, recent: format == .recent,
                                           match: config.content.matches[id], interaction: interaction)
                        }
                    }
                    .environment(\.theme, config.theme)
                    .environment(config.ai)
                    .disabled(config.content.folder?.disabled == true)
                    .allowsHitTesting(!selecting)
                    .frame(maxHeight: grid ? .infinity : nil, alignment: .topLeading)
                }
                if grid {
                    cell.contentConfiguration = hosting.margins(.all, 0).minSize(height: 0)
                } else if section.firstFileID == id {
                    // Let the section header or navigation inset set the first item's origin.
                    cell.contentConfiguration = hosting.margins(.top, 0)
                } else {
                    cell.contentConfiguration = hosting
                }
                // Selected cells own accessibility activation during UIKit editing.
                cell.isAccessibilityElement = selecting
                cell.accessibilityIdentifier = selecting ? "library-file-\(entry.name)" : nil
                if selecting {
                    cell.accessibilityLabel = entry.title
                    cell.accessibilityTraits = selected ? [.button, .selected] : [.button]
                }
            }
        }

        private func configureFolderCell(_ cell: UICollectionViewCell, id: String, grid: Bool, theme: ThemeSurface) {
            if grid {
                var background = UIBackgroundConfiguration.clear()
                background.backgroundColor = hoverID == id ? theme.accent.withAlphaComponent(0.12) : .clear
                background.cornerRadius = 12
                cell.backgroundConfiguration = background
            } else if let listCell = cell as? UICollectionViewListCell {
                listCell.accessories = [.multiselect(options: .init(tintColor: theme.accent))]
                cell.configurationUpdateHandler = { [weak self] cell, state in
                    var background = UIBackgroundConfiguration.listCell()
                    background.cornerRadius = 0
                    background.backgroundColor = state.isSelected || self?.hoverID == id ? theme.accent.withAlphaComponent(0.12) : .clear
                    cell.backgroundConfiguration = background
                }
                cell.setNeedsUpdateConfiguration()
            }
        }

        private func configureHeader(_ view: UICollectionReusableView, at path: IndexPath) {
            guard let config = configuration, let cell = view as? UICollectionViewCell,
                  let id = source.sectionIdentifier(for: path.section), let section = sectionsByID[id],
                  let header = section.header else { return }
            let usesList: Bool
            if case .files(_, let format) = section.content { usesList = !format.usesGrid(config.layout) }
            else { usesList = false }
            let leading = usesList ? cell.directionalLayoutMargins.leading : 0
            let trailing = usesList ? cell.directionalLayoutMargins.trailing : 0
            switch header {
            case .title(let title, let detail, let accessibilityID):
                var content = UIListContentConfiguration.header()
                content.text = title
                content.secondaryText = detail
                content.prefersSideBySideTextAndSecondaryText = true
                content.textProperties.color = config.theme.secondary
                content.secondaryTextProperties.color = config.theme.secondary
                if !usesList {
                    // The custom section already applies the container's horizontal margins.
                    content.axesPreservingSuperviewLayoutMargins = .vertical
                    content.directionalLayoutMargins.leading = 0
                    content.directionalLayoutMargins.trailing = 0
                }
                cell.contentConfiguration = content
                cell.isAccessibilityElement = true
                cell.accessibilityLabel = title
                cell.accessibilityValue = detail
                cell.accessibilityIdentifier = accessibilityID
                cell.accessibilityTraits = [.header, .staticText]
            case .action(let action):
                cell.contentConfiguration = UIHostingConfiguration {
                    action.environment(\.theme, config.theme).environment(config.ai)
                        .tint(Color(uiColor: config.theme.accent))
                }.margins(.vertical, 0)
                    .margins(.leading, leading).margins(.trailing, trailing).minSize(height: 0)
                cell.isAccessibilityElement = false
                cell.accessibilityLabel = nil
                cell.accessibilityValue = nil
                cell.accessibilityIdentifier = nil
                cell.accessibilityTraits = []
            }
        }

        private func makeSection(_ index: Int, environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection? {
            guard let config = configuration, let id = source.sectionIdentifier(for: index),
                  let content = sectionsByID[id] else { return nil }
            let section: NSCollectionLayoutSection
            switch content.content {
            case .rows:
                let height: NSCollectionLayoutDimension = .estimated(LayoutTokens.hit)
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: height))
                section = NSCollectionLayoutSection(group: .vertical(layoutSize: item.layoutSize, subitems: [item]))
            case .files(_, let format) where format.usesGrid(config.layout):
                let indexWidth: CGFloat = config.letters.isEmpty ? 0 : 20
                section = gridSection(environment, indexWidth: indexWidth)
                section.contentInsets.trailing = indexWidth
            case .files:
                return listSection(environment, theme: config.theme, hasHeader: content.header != nil)
            }
            if content.header != nil {
                section.boundarySupplementaryItems = [
                    .init(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(32)),
                          elementKind: Self.headerKind, alignment: .top)
                ]
            }
            return section
        }

        private func listSection(_ environment: NSCollectionLayoutEnvironment, theme: ThemeSurface,
                                 hasHeader: Bool) -> NSCollectionLayoutSection {
            var list = UICollectionLayoutListConfiguration(appearance: .plain)
            list.backgroundColor = theme.canvas
            list.headerTopPadding = 0
            if hasHeader { list.headerMode = .supplementary }
            list.trailingSwipeActionsConfigurationProvider = { [weak self] path in
                guard let self, let config = configuration, let folder = config.content.folder,
                      !folder.editing.isEditing, !folder.disabled, let entry = entry(at: path) else { return nil }
                let delete = UIContextualAction(style: .destructive, title: String(localized: "删除")) { _, _, completion in
                    config.content.model.deleteEntries([entry]); completion(true)
                }
                delete.image = UIImage(systemName: "trash")
                delete.backgroundColor = config.theme.destructive
                let actions = UISwipeActionsConfiguration(actions: [delete]); actions.performsFirstActionWithFullSwipe = false
                return actions
            }
            let section = NSCollectionLayoutSection.list(using: list, layoutEnvironment: environment)
            section.contentInsetsReference = .safeArea
            section.supplementaryContentInsetsReference = .safeArea
            for header in section.boundarySupplementaryItems { header.pinToVisibleBounds = false }
            return section
        }

        private func gridSection(_ environment: NSCollectionLayoutEnvironment, indexWidth: CGFloat) -> NSCollectionLayoutSection {
            let width = max(1, environment.container.effectiveContentSize.width - indexWidth)
            let minimum = UIFontMetrics(forTextStyle: .body).scaledValue(for: 96, compatibleWith: environment.traitCollection)
            let gap = LibraryCollectionSection.gridSpacing
            let columns = max(1, Int((width + gap) / (minimum + gap)))
            let tileWidth = (width - CGFloat(columns - 1) * gap) / CGFloat(columns)
            let estimate = tileWidth / 0.7 + LayoutTokens.hit
            let item = NSCollectionLayoutItem(layoutSize: .init(
                widthDimension: .absolute(tileWidth), heightDimension: .uniformAcrossSiblings(estimate: estimate)
            ))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(estimate)),
                repeatingSubitem: item, count: columns
            )
            group.interItemSpacing = .fixed(gap)
            let section = NSCollectionLayoutSection(group: group)
            // The footer already contributes part of the spacing below each row.
            section.interGroupSpacing = gap - LibraryCollectionSection.gridFooterSpacing
            return section
        }

        func jump(to letter: String) {
            guard let section = source.snapshot().indexOfSection(.name(letter)),
                  source.snapshot().numberOfItems(inSection: .name(letter)) > 0 else { return }
            let path = IndexPath(item: 0, section: section)
            if let frame = collectionView.collectionViewLayout.layoutAttributesForSupplementaryView(ofKind: Self.headerKind, at: path)?.frame {
                let end = max(-collectionView.adjustedContentInset.top, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
                collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: min(end, frame.minY - collectionView.adjustedContentInset.top)), animated: false)
            } else {
                collectionView.scrollToItem(at: path, at: .top, animated: false)
            }
        }

        override func scrollViewDidScroll(_ scrollView: UIScrollView) { updateAlphabet() }

        private func updateAlphabet() {
            guard let config = configuration, config.layout == .grid,
                  !config.letters.isEmpty else { return }
            let visible = collectionView.indexPathsForVisibleItems
            let current = visible.sorted().lazy.compactMap { path -> String? in
                if case .name(let letter) = self.source.sectionIdentifier(for: path.section) { return letter }
                return nil
            }.first
            if config.alphabet.current != current {
                // The initial selection can change while the representable updates.
                Task { @MainActor [weak self] in
                    guard self?.configuration?.alphabet === config.alphabet else { return }
                    config.alphabet.current = current
                }
            }
        }

        private func entry(at path: IndexPath) -> LibraryEntry? {
            guard case let .file(.folderEntries, id) = source.itemIdentifier(for: path) else { return nil }
            return entriesByID[id]
        }
        private func synchronizeSelection() {
            guard let config = configuration, let folder = config.content.folder else { return }
            let current = Set(collectionView.indexPathsForSelectedItems ?? [])
            let wanted = Set(folder.selection.compactMap { source.indexPath(for: .file(.folderEntries, $0)) })
            for path in current.subtracting(wanted) { collectionView.deselectItem(at: path, animated: false) }
            for path in wanted.subtracting(current) { collectionView.selectItem(at: path, animated: false, scrollPosition: []) }
        }
        override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
            guard let config = configuration, let folder = config.content.folder, !folder.disabled else { return false }
            if folder.editing.isEditing { return entry(at: indexPath) != nil }
            guard let session = droppingSession, let entry = entry(at: indexPath), entry.directory else { return false }
            return canDrop(session, at: entry.location)
        }
        override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let config = configuration, let folder = config.content.folder, let entry = entry(at: indexPath) else { return }
            if folder.editing.isEditing { folder.selection.insert(entry.id) }
            else if let session = droppingSession, entry.directory, springOpenedID != entry.id, canDrop(session, at: entry.location) {
                springOpenedID = entry.id
                config.content.host.open(entry, in: config.content.model)
            }
        }
        override func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
            guard let config = configuration, let folder = config.content.folder, folder.editing.isEditing, let entry = entry(at: indexPath) else { return }
            folder.selection.remove(entry.id)
        }
        override func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
            configuration?.content.folder?.disabled == false && entry(at: indexPath) != nil
        }
        override func collectionView(_ collectionView: UICollectionView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
            collectionView.isEditing = true
            collectionView.allowsMultipleSelection = true
            if let folder = configuration?.content.folder { folder.editing = .active }
        }

        private var acceptsFiles: Bool {
            guard let config = configuration, let folder = config.content.folder else { return false }
            return !folder.disabled && !folder.editing.isEditing && config.content.model.canAcceptDrop(at: folder.location)
        }
        private func canDrop(_ session: any UIDropSession, at destination: LibraryLocation) -> Bool {
            guard acceptsFiles else { return false }
            let local = session.items.compactMap { $0.localObject as? LibraryEntry }
            if !local.isEmpty {
                return local.count == session.items.count && local.allSatisfy { LibraryDropPolicy.canMove($0, to: destination, available: true) }
            }
            return !session.items.isEmpty && session.items.allSatisfy { LibraryDropPolicy.candidate($0.itemProvider, at: destination) != nil }
        }
        private func highlight(_ id: String?) {
            guard hoverID != id else { return }
            let old = hoverID; hoverID = id
            for candidate in [old, id].compactMap({ $0 }) {
                if let path = source.indexPath(for: .file(.folderEntries, candidate)), let cell = collectionView.cellForItem(at: path) { configure(cell, item: .file(.folderEntries, candidate)) }
            }
        }
        func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: any UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
            guard acceptsFiles, let entry = entry(at: indexPath), let provider = try? LibraryDragPayload(fileID: entry.id).provider() else { return [] }
            let item = UIDragItem(itemProvider: provider); item.localObject = entry
            return [item]
        }
        func collectionView(_ collectionView: UICollectionView, dragPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
            guard let config = configuration, let entry = entry(at: indexPath),
                  let cell = collectionView.cellForItem(at: indexPath) else { return nil }
            let bounds = cell.contentView.bounds
            let cover: CGRect
            let radius: CGFloat
            if config.layout == .grid {
                cover = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.width / 0.7)
                radius = entry.directory ? 7 : 6
            } else {
                let size = LibraryFileRow.coverSize
                cover = CGRect(x: bounds.minX + LayoutTokens.page, y: bounds.midY - size.height / 2,
                               width: size.width, height: size.height)
                radius = entry.directory ? 7 : 3
            }
            let parameters = UIDragPreviewParameters()
            parameters.backgroundColor = .clear
            // Public cell geometry and the same cover layout as the hosted content.
            // UIKit uses this mask for both the lift and its continuing drag preview.
            parameters.visiblePath = UIBezierPath(roundedRect: cell.contentView.convert(cover, to: cell), cornerRadius: radius)
            return parameters
        }
        func collectionView(_ collectionView: UICollectionView, dragSessionIsRestrictedToDraggingApplication session: any UIDragSession) -> Bool { true }
        func collectionView(_ collectionView: UICollectionView, canHandle session: any UIDropSession) -> Bool {
            guard acceptsFiles, let folder = configuration?.content.folder else { return false }
            return session.items.contains { $0.localObject is LibraryEntry || LibraryDropPolicy.candidate($0.itemProvider, at: folder.location) != nil }
        }
        func collectionView(_ collectionView: UICollectionView, dropSessionDidEnter session: any UIDropSession) { droppingSession = session; springOpenedID = nil }
        func collectionView(_ collectionView: UICollectionView, dropSessionDidExit session: any UIDropSession) { droppingSession = nil; highlight(nil) }
        func collectionView(_ collectionView: UICollectionView, dropSessionDidEnd session: any UIDropSession) { droppingSession = nil; springOpenedID = nil; highlight(nil) }
        func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: any UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
            guard let folder = configuration?.content.folder else { return UICollectionViewDropProposal(operation: .forbidden) }
            droppingSession = session
            let hit = collectionView.indexPathForItem(at: session.location(in: collectionView)).flatMap { entry(at: $0) }
            let destination = hit?.directory == true ? hit!.location : folder.location
            let allowed = canDrop(session, at: destination)
            highlight(allowed && hit?.directory == true ? hit?.id : nil)
            let local = session.items.allSatisfy { $0.localObject is LibraryEntry }
            return UICollectionViewDropProposal(operation: allowed ? (local ? .move : .copy) : .forbidden, intent: .unspecified)
        }
        func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: any UICollectionViewDropCoordinator) {
            guard let config = configuration, let folder = config.content.folder else { return }
            let hit = collectionView.indexPathForItem(at: coordinator.session.location(in: collectionView)).flatMap { entry(at: $0) }
            let destination = hit?.directory == true ? hit!.location : folder.location
            guard canDrop(coordinator.session, at: destination) else { return }
            let local = coordinator.items.compactMap { $0.dragItem.localObject as? LibraryEntry }
            if !local.isEmpty {
                _ = config.content.model.acceptDrop(.moveIDs(local.map(\.id)), at: destination)
            } else { _ = config.content.model.acceptDrop(.importProviders(coordinator.items.map { $0.dragItem.itemProvider }), at: destination) }
            highlight(nil)
        }
        override func collectionView(_ collectionView: UICollectionView, shouldSpringLoadItemAt indexPath: IndexPath, with context: any UISpringLoadedInteractionContext) -> Bool {
            guard let session = droppingSession, let entry = entry(at: indexPath), entry.directory, springOpenedID != entry.id else { return false }
            return canDrop(session, at: entry.location)
        }

        @objc private func refreshFiles() {
            guard let onRefresh = configuration?.content.onRefresh else { refresh.endRefreshing(); return }
            Task { await onRefresh(); refresh.endRefreshing() }
        }
    }

}
