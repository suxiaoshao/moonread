import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// UIKit owns range selection, autoscroll, cell reuse and list swipe actions.
/// SwiftUI still draws the same themed book covers and file rows.
struct LibraryCollection: UIViewControllerRepresentable {
    // Resolve this dependency in the SwiftUI parent, before UIKit retains the configuration.
    let ai: AIService
    let model: LibraryModel
    let location: LibraryLocation
    let entries: [LibraryEntry]
    let shelf: LibraryShelf?
    let layout: LibraryLayout
    let theme: ThemeSurface
    let disabled: Bool
    var showsEmpty = false
    @Binding var editing: EditMode
    @Binding var selection: Set<String>

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.update(self) }

    final class Controller: UICollectionViewController, UICollectionViewDragDelegate, UICollectionViewDropDelegate {
        enum Section: Hashable { case overview, entries }
        enum Item: Hashable { case overview, file(String) }
        private var configuration: LibraryCollection?
        private var entriesByID: [String: LibraryEntry] = [:]
        private var source: UICollectionViewDiffableDataSource<Section, Item>!
        private var sections: [Section] = []
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
            collectionView.dragDelegate = self; collectionView.dropDelegate = self
            collectionView.dragInteractionEnabled = true; collectionView.isSpringLoaded = true
            collectionView.register(UICollectionViewListCell.self, forCellWithReuseIdentifier: "file")
            source = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collection, path, item in
                let cell = collection.dequeueReusableCell(withReuseIdentifier: "file", for: path)
                self?.configure(cell, item: item)
                return cell
            }
            collectionView.setCollectionViewLayout(UICollectionViewCompositionalLayout { [weak self] index, environment in
                self?.makeSection(index, environment: environment)
            }, animated: false)
            refresh.addTarget(self, action: #selector(refreshFiles), for: .valueChanged)
        }

        func update(_ config: LibraryCollection) {
            loadViewIfNeeded()
            let oldLayout = configuration?.layout
            let oldTheme = configuration?.theme
            let oldLocation = configuration?.location
            let contentChanged = configuration?.entries != config.entries
                || renderedEditing != config.editing.isEditing
                || configuration?.disabled != config.disabled
                || oldLayout != config.layout || oldTheme != config.theme
            let selectionChanges = renderedSelection.symmetricDifference(config.selection)
            renderedSelection = config.selection
            configuration = config
            renderedEditing = config.editing.isEditing
            if contentChanged { entriesByID = Dictionary(uniqueKeysWithValues: config.entries.map { ($0.id, $0) }) }
            collectionView.backgroundColor = config.theme.canvas
            collectionView.tintColor = config.theme.accent
            if config.showsEmpty {
                if collectionView.backgroundView == nil || oldTheme != config.theme || oldLocation != config.location
                    || contentChanged {
                    collectionView.backgroundView = UIHostingConfiguration {
                        LibraryEmptyFolder(model: config.model, location: config.location)
                            .disabled(config.disabled || config.editing.isEditing)
                            .environment(\.theme, config.theme)
                    }.margins(.all, 0).makeContentView()
                }
            } else { collectionView.backgroundView = nil }
            collectionView.isUserInteractionEnabled = !config.disabled
            if collectionView.isEditing != config.editing.isEditing { collectionView.isEditing = config.editing.isEditing }
            if collectionView.allowsMultipleSelection != config.editing.isEditing { collectionView.allowsMultipleSelection = config.editing.isEditing }
            collectionView.refreshControl = config.editing.isEditing ? nil : refresh
            collectionView.accessibilityIdentifier = config.layout == .grid ? "libraryGrid" : "libraryList"
            overrideUserInterfaceStyle = config.theme.style

            var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
            if config.location.path.isEmpty || config.shelf?.error != nil {
                snapshot.appendSections([.overview]); snapshot.appendItems([.overview])
            }
            // An empty folder still needs a destination section for native drops.
            snapshot.appendSections([.entries])
            snapshot.appendItems(config.entries.map { Item.file($0.id) })
            sections = snapshot.sectionIdentifiers
            let previous = source.snapshot()
            if previous.sectionIdentifiers != sections || previous.itemIdentifiers != snapshot.itemIdentifiers {
                source.apply(snapshot, animatingDifferences: false)
            }
            if oldLayout != config.layout || oldTheme != config.theme { collectionView.collectionViewLayout.invalidateLayout() }
            synchronizeSelection()
            for path in collectionView.indexPathsForVisibleItems {
                // Native list accessories/backgrounds follow UIKit selection.
                // Do not replace their hosted content during a range gesture.
                if let item = source.itemIdentifier(for: path),
                   (contentChanged || { if case let .file(id) = item { return selectionChanges.contains(id) }; return false }()), let cell = collectionView.cellForItem(at: path) { configure(cell, item: item) }
            }
        }

        private func configure(_ cell: UICollectionViewCell, item: Item) {
            guard let config = configuration else { return }
            cell.configurationUpdateHandler = nil
            var background = UIBackgroundConfiguration.clear()
            background.backgroundColor = hoverID == { if case .file(let id) = item { return id }; return "" }() ? config.theme.accent.withAlphaComponent(0.12) : .clear
            background.cornerRadius = 12
            cell.backgroundConfiguration = background
            (cell as? UICollectionViewListCell)?.accessories = []
            if case .overview = item {
                cell.contentConfiguration = UIHostingConfiguration {
                    FolderOverview(model: config.model, location: config.location, shelf: config.shelf)
                        .disabled(config.editing.isEditing || config.disabled).environment(\.theme, config.theme)
                }.margins(.all, 0)
                cell.isAccessibilityElement = false
                return
            }
            guard case let .file(id) = item, let entry = entriesByID[id] else { return }
            let selecting = config.editing.isEditing, selected = config.selection.contains(id)
            if config.layout == .list, let listCell = cell as? UICollectionViewListCell {
                listCell.accessories = [.multiselect(options: .init(tintColor: config.theme.accent))]
                cell.configurationUpdateHandler = { [weak self] cell, state in
                    var background = UIBackgroundConfiguration.listCell()
                    background.cornerRadius = 0
                    background.backgroundColor = state.isSelected || self?.hoverID == id ? config.theme.accent.withAlphaComponent(0.12) : .clear
                    cell.backgroundConfiguration = background
                }
                cell.setNeedsUpdateConfiguration()
            }
            cell.contentConfiguration = UIHostingConfiguration {
                Group {
                    if config.layout == .grid {
                        LibraryBookTile(model: config.model, entry: entry, selected: selected, select: selecting ? {} : nil)
                    } else {
                        LibraryFileRow(model: config.model, entry: entry, select: selecting ? {} : nil)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in LibraryFileRow.textLeading }
                    }
                }
                .environment(\.theme, config.theme)
                .disabled(config.disabled)
                .allowsHitTesting(!selecting)
                .contextMenu { if !selecting { LibraryItemMenu(model: config.model, entry: entry) } }
                .environment(config.ai)
            }.margins(.vertical, 0).margins(.horizontal, config.layout == .list ? LayoutTokens.page : 0)
            // A selected cell is one accessible control; hosted buttons must not
            // compete with UIKit for the two-finger interaction or double-toggle.
            cell.isAccessibilityElement = selecting
            cell.accessibilityIdentifier = selecting ? "library-file-\(entry.name)" : nil
            cell.accessibilityLabel = entry.title
            cell.accessibilityTraits = selected ? [.button, .selected] : [.button]
        }

        private func makeSection(_ index: Int, environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection? {
            guard let config = configuration, sections.indices.contains(index) else { return nil }
            let section: NSCollectionLayoutSection
            if sections[index] == .overview {
                // The root overview includes optional index guidance and must self-size.
                let height: NSCollectionLayoutDimension = .estimated(LayoutTokens.hit)
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: height))
                section = NSCollectionLayoutSection(group: .vertical(layoutSize: item.layoutSize, subitems: [item]))
            } else if config.layout == .list {
                var list = UICollectionLayoutListConfiguration(appearance: .plain)
                list.backgroundColor = config.theme.canvas
                list.trailingSwipeActionsConfigurationProvider = { [weak self] path in
                    guard let self, let current = configuration, !current.editing.isEditing, !current.disabled,
                          let entry = entry(at: path) else { return nil }
                    let delete = UIContextualAction(style: .destructive, title: String(localized: "删除")) { _, _, completion in
                        current.model.deletion = [entry]; completion(true)
                    }
                    delete.image = UIImage(systemName: "trash")
                    delete.backgroundColor = current.theme.destructive
                    let actions = UISwipeActionsConfiguration(actions: [delete]); actions.performsFirstActionWithFullSwipe = false
                    return actions
                }
                section = .list(using: list, layoutEnvironment: environment)
            } else {
                let width = environment.container.effectiveContentSize.width - 2 * LayoutTokens.page
                let minimum = UIFontMetrics(forTextStyle: .body).scaledValue(for: 96, compatibleWith: environment.traitCollection)
                let columns = max(1, Int((width + LayoutTokens.content) / (minimum + LayoutTokens.content)))
                let tileWidth = (width - CGFloat(columns - 1) * LayoutTokens.content) / CGFloat(columns)
                let title = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: environment.traitCollection)
                let detail = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: environment.traitCollection)
                // Known cover ratio + two reserved title lines + metadata row.
                // Fixed row geometry keeps the scroll indicator stable offscreen.
                let height = ceil(tileWidth / 0.7 + LayoutTokens.compact + 2 * title.lineHeight + max(LayoutTokens.hit, detail.lineHeight))
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(tileWidth), heightDimension: .fractionalHeight(1)))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)), repeatingSubitem: item, count: columns)
                group.interItemSpacing = .fixed(LayoutTokens.content)
                section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = LayoutTokens.section
            }
            let horizontal = config.layout == .list && sections[index] != .overview ? 0 : LayoutTokens.page
            section.contentInsets = .init(top: 0, leading: horizontal, bottom: LayoutTokens.control, trailing: horizontal)
            return section
        }

        private func entry(at path: IndexPath) -> LibraryEntry? {
            guard case let .file(id) = source.itemIdentifier(for: path) else { return nil }
            return entriesByID[id]
        }
        private func synchronizeSelection() {
            guard let config = configuration else { return }
            let current = Set(collectionView.indexPathsForSelectedItems ?? [])
            let wanted = Set(config.selection.compactMap { source.indexPath(for: .file($0)) })
            for path in current.subtracting(wanted) { collectionView.deselectItem(at: path, animated: false) }
            for path in wanted.subtracting(current) { collectionView.selectItem(at: path, animated: false, scrollPosition: []) }
        }
        override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
            guard let config = configuration, !config.disabled else { return false }
            if config.editing.isEditing { return entry(at: indexPath) != nil }
            guard let session = droppingSession, let entry = entry(at: indexPath), entry.directory else { return false }
            return canDrop(session, at: entry.location)
        }
        override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let config = configuration, let entry = entry(at: indexPath) else { return }
            if config.editing.isEditing { config.selection.insert(entry.id) }
            else if let session = droppingSession, entry.directory, springOpenedID != entry.id, canDrop(session, at: entry.location) {
                springOpenedID = entry.id
                config.model.open(entry)
            }
        }
        override func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
            guard let config = configuration, config.editing.isEditing, let entry = entry(at: indexPath) else { return }
            config.selection.remove(entry.id)
        }
        override func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
            configuration?.disabled == false && entry(at: indexPath) != nil
        }
        override func collectionView(_ collectionView: UICollectionView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
            collectionView.isEditing = true
            collectionView.allowsMultipleSelection = true
            configuration?.editing = .active
        }

        private var acceptsFiles: Bool {
            guard let config = configuration else { return false }
            return !config.disabled && !config.editing.isEditing && config.model.canAcceptDrop(at: config.location)
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
                if let path = source.indexPath(for: .file(candidate)), let cell = collectionView.cellForItem(at: path) { configure(cell, item: .file(candidate)) }
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
            guard acceptsFiles, let config = configuration else { return false }
            return session.items.contains { $0.localObject is LibraryEntry || LibraryDropPolicy.candidate($0.itemProvider, at: config.location) != nil }
        }
        func collectionView(_ collectionView: UICollectionView, dropSessionDidEnter session: any UIDropSession) { droppingSession = session; springOpenedID = nil }
        func collectionView(_ collectionView: UICollectionView, dropSessionDidExit session: any UIDropSession) { droppingSession = nil; highlight(nil) }
        func collectionView(_ collectionView: UICollectionView, dropSessionDidEnd session: any UIDropSession) { droppingSession = nil; springOpenedID = nil; highlight(nil) }
        func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: any UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
            guard let config = configuration else { return UICollectionViewDropProposal(operation: .forbidden) }
            droppingSession = session
            let hit = collectionView.indexPathForItem(at: session.location(in: collectionView)).flatMap { entry(at: $0) }
            let destination = hit?.directory == true ? hit!.location : config.location
            let allowed = canDrop(session, at: destination)
            highlight(allowed && hit?.directory == true ? hit?.id : nil)
            let local = session.items.allSatisfy { $0.localObject is LibraryEntry }
            return UICollectionViewDropProposal(operation: allowed ? (local ? .move : .copy) : .forbidden, intent: .unspecified)
        }
        func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: any UICollectionViewDropCoordinator) {
            guard let config = configuration else { return }
            let hit = collectionView.indexPathForItem(at: coordinator.session.location(in: collectionView)).flatMap { entry(at: $0) }
            let destination = hit?.directory == true ? hit!.location : config.location
            guard canDrop(coordinator.session, at: destination) else { return }
            let local = coordinator.items.compactMap { $0.dragItem.localObject as? LibraryEntry }
            if !local.isEmpty {
                _ = config.model.acceptDrop(.moveIDs(local.map(\.id)), at: destination)
            } else { _ = config.model.acceptDrop(.importProviders(coordinator.items.map { $0.dragItem.itemProvider }), at: destination) }
            highlight(nil)
        }
        override func collectionView(_ collectionView: UICollectionView, shouldSpringLoadItemAt indexPath: IndexPath, with context: any UISpringLoadedInteractionContext) -> Bool {
            guard let session = droppingSession, let entry = entry(at: indexPath), entry.directory, springOpenedID != entry.id else { return false }
            return canDrop(session, at: entry.location)
        }

        @objc private func refreshFiles() {
            guard let config = configuration else { refresh.endRefreshing(); return }
            Task { await config.model.refresh(showIndicator: false); refresh.endRefreshing() }
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-grid-geometry") {
                collectionView.accessibilityValue = String(Double(collectionView.contentSize.height))
            }
            #endif
        }
    }

}

private struct FolderOverview: View {
    let model: LibraryModel
    let location: LibraryLocation
    let shelf: LibraryShelf?
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: LayoutTokens.compact) {
            if let error = shelf?.error {
                Button("重新连接", systemImage: "folder.badge.questionmark") { model.chooseFiles(.folder(location.shelfID)) }
                Text(verbatim: error).font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
            }
            if location.path.isEmpty {
                Button { model.path.append(.allBooks(location.shelfID)) } label: {
                    HStack(spacing: LayoutTokens.compact) {
                        Label("全部小说", systemImage: "books.vertical").font(.subheadline.weight(.medium)).foregroundStyle(Color(uiColor: theme.accent))
                        Spacer()
                        Text("\(shelf?.bookCount ?? 0) 本小说").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color(uiColor: theme.secondary))
                    }.frame(minHeight: LayoutTokens.hit).contentShape(.rect)
                }.buttonStyle(.plain).accessibilityIdentifier("library-all-books")
                ShelfIndexGuidance(model: model, shelfID: location.shelfID)
            }
        }
    }
}
