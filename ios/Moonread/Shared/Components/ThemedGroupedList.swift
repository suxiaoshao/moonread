import SwiftUI
import UIKit

/// Native grouped cells own their shape, including while swiping. Only these
/// explicitly opted-in lists use this host; no appearance or private-view edits.
struct ThemedGroupedList: UIViewControllerRepresentable {
    struct Action {
        var title: String
        var symbol: String?
        var destructive = false
        var perform: () -> Void
    }
    struct Row {
        let id: String
        let content: AnyView
        var action: (() -> Void)?
        var disclosure: Bool
        var actions: [Action]
        var clear: Bool
        var reorderable: Bool
        var allowsFullSwipe: Bool
        var accessibilityID: String
        init<Content: View>(_ id: String, action: (() -> Void)? = nil, disclosure: Bool = false,
                            actions: [Action] = [], clear: Bool = false, reorderable: Bool = false,
                            allowsFullSwipe: Bool = true, accessibilityID: String? = nil,
                            @ViewBuilder content: () -> Content) {
            self.id = id; self.content = AnyView(content()); self.action = action
            self.disclosure = disclosure; self.actions = actions; self.clear = clear; self.reorderable = reorderable
            self.allowsFullSwipe = allowsFullSwipe; self.accessibilityID = accessibilityID ?? id
        }
    }
    struct Section {
        let id: String
        var title: String?
        var footer: String?
        var rows: [Row]
    }
    var sections: [Section]
    var theme: ThemeSurface
    var topInset: CGFloat = 16
    var bottomInset: CGFloat = 0
    var selecting = false
    var selected: Set<String> = []
    var selectionChanged: ((Set<String>) -> Void)?
    var reordered: (([String]) -> Void)?
    var refresh: (() async -> Void)?

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.update(self) }

    final class Controller: UICollectionViewController {
        private var value: ThemedGroupedList?
        private var rows: [String: Row] = [:]
        private var source: UICollectionViewDiffableDataSource<String, String>!
        init() { super.init(collectionViewLayout: UICollectionViewFlowLayout()) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidLoad() {
            super.viewDidLoad()
            collectionView.keyboardDismissMode = .interactive
            let cells = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
                self?.configure(cell, id: id)
            }
            source = UICollectionViewDiffableDataSource(collectionView: collectionView) { collection, path, id in
                collection.dequeueConfiguredReusableCell(using: cells, for: path, item: id)
            }
            let header = supplementary(footer: false), footer = supplementary(footer: true)
            source.supplementaryViewProvider = { collection, kind, path in
                collection.dequeueConfiguredReusableSupplementary(using: kind == UICollectionView.elementKindSectionFooter ? footer : header, for: path)
            }
            source.reorderingHandlers.canReorderItem = { [weak self] id in self?.rows[id]?.reorderable == true }
            source.reorderingHandlers.didReorder = { [weak self] transaction in
                guard let self else { return }
                self.value?.reordered?(transaction.finalSnapshot.itemIdentifiers.filter { self.rows[$0]?.reorderable == true })
            }
        }
        private func supplementary(footer: Bool) -> UICollectionView.SupplementaryRegistration<UICollectionViewListCell> {
            .init(elementKind: footer ? UICollectionView.elementKindSectionFooter : UICollectionView.elementKindSectionHeader) { [weak self] cell, _, path in
                guard let value = self?.value, value.sections.indices.contains(path.section) else { return }
                var content = footer ? UIListContentConfiguration.footer() : .header()
                content.text = footer ? value.sections[path.section].footer : value.sections[path.section].title
                content.textProperties.color = value.theme.secondary
                cell.contentConfiguration = content
                cell.backgroundConfiguration = .clear()
                cell.accessibilityTraits = footer ? .staticText : .header
            }
        }
        private func layout() -> UICollectionViewLayout {
            UICollectionViewCompositionalLayout { [weak self] index, environment in
                guard let self, let value = self.value, value.sections.indices.contains(index) else { return nil }
                let section = value.sections[index]
                var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
                config.backgroundColor = value.theme.canvas
                config.separatorConfiguration.color = value.theme.separator
                config.headerMode = section.title == nil ? .none : .supplementary
                config.footerMode = section.footer == nil ? .none : .supplementary
                config.trailingSwipeActionsConfigurationProvider = { [weak self] path in self?.swipes(at: path) }
                let result = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
                if index == 0 { result.contentInsets.top = value.topInset }
                return result
            }
        }
        private func swipes(at path: IndexPath) -> UISwipeActionsConfiguration? {
            guard let value, !value.selecting, let id = source.itemIdentifier(for: path), let row = rows[id], !row.actions.isEmpty else { return nil }
            let actions = row.actions.map { item in
                let action = UIContextualAction(style: item.destructive ? .destructive : .normal, title: item.title) { _, _, completion in
                    // The page owns confirmation and mutation; never remove a
                    // cell speculatively while a confirmation is still pending.
                    completion(false)
                    item.perform()
                }
                action.image = item.symbol.flatMap(UIImage.init(systemName:))
                action.backgroundColor = item.destructive ? .systemRed : value.theme.accent
                return action
            }
            let result = UISwipeActionsConfiguration(actions: actions)
            result.performsFirstActionWithFullSwipe = row.allowsFullSwipe
            return result
        }
        func update(_ value: ThemedGroupedList) {
            loadViewIfNeeded()
            let layoutChanged = self.value?.theme != value.theme || self.value?.topInset != value.topInset
                || self.value?.sections.map { [$0.id, $0.title ?? "", $0.footer ?? ""] } != value.sections.map { [$0.id, $0.title ?? "", $0.footer ?? ""] }
            self.value = value
            rows = Dictionary(uniqueKeysWithValues: value.sections.flatMap(\.rows).map { ($0.id, $0) })
            collectionView.backgroundColor = value.theme.canvas
            collectionView.tintColor = value.theme.accent
            collectionView.contentInset.bottom = value.bottomInset
            collectionView.verticalScrollIndicatorInsets.bottom = value.bottomInset
            collectionView.allowsSelectionDuringEditing = true
            collectionView.allowsMultipleSelection = value.selecting
            collectionView.allowsMultipleSelectionDuringEditing = value.selecting
            collectionView.isEditing = value.selecting || value.reordered != nil
            if layoutChanged { collectionView.setCollectionViewLayout(layout(), animated: false) }
            if value.refresh != nil, collectionView.refreshControl == nil {
                let control = UIRefreshControl(); control.addTarget(self, action: #selector(refreshRequested), for: .valueChanged)
                collectionView.refreshControl = control
            }
            var snapshot = NSDiffableDataSourceSnapshot<String, String>()
            for section in value.sections {
                snapshot.appendSections([section.id]); snapshot.appendItems(section.rows.map(\.id), toSection: section.id)
            }
            let previous = Set(source.snapshot().itemIdentifiers)
            snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { previous.contains($0) })
            source.apply(snapshot, animatingDifferences: false) { [weak self] in self?.restoreSelection() }
        }
        private func restoreSelection() {
            guard let value else { return }
            for path in collectionView.indexPathsForSelectedItems ?? [] {
                if !value.selecting || !value.selected.contains(source.itemIdentifier(for: path) ?? "") {
                    collectionView.deselectItem(at: path, animated: false)
                }
            }
            if value.selecting {
                for id in value.selected {
                    if let path = source.indexPath(for: id) { collectionView.selectItem(at: path, animated: false, scrollPosition: []) }
                }
            }
        }
        @objc private func refreshRequested() {
            Task { [weak self] in
                await self?.value?.refresh?()
                self?.collectionView.refreshControl?.endRefreshing()
            }
        }
        private func configure(_ cell: UICollectionViewListCell, id: String) {
            guard let row = rows[id], let value else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                self.hostedContent(row, selecting: value.selecting).environment(\.theme, value.theme)
                    .foregroundStyle(Color(uiColor: value.theme.ink)).tint(Color(uiColor: value.theme.accent))
            }
            cell.configurationUpdateHandler = { cell, state in
                cell.backgroundConfiguration = themedListBackground(value.theme, state: state, clear: row.clear)
            }
            cell.setNeedsUpdateConfiguration()
            cell.tintColor = value.theme.accent
            cell.accessibilityIdentifier = row.accessibilityID
            cell.accessories = value.selecting ? [.multiselect(displayed: .always)] : row.disclosure ? [.disclosureIndicator()] : []
            if row.reorderable {
                if row.actions.contains(where: \.destructive) {
                    cell.accessories.append(.delete(displayed: .always, options: .init(tintColor: .systemRed)))
                }
                cell.accessories.append(.reorder(displayed: .always))
            }
            cell.accessibilityCustomActions = row.actions.map { item in
                UIAccessibilityCustomAction(name: item.title) { _ in item.perform(); return true }
            }
        }
        @ViewBuilder private func hostedContent(_ row: Row, selecting: Bool) -> some View {
            if selecting {
                row.content.accessibilityElement(children: .combine).accessibilityIdentifier(row.accessibilityID)
            } else if let action = row.action {
                row.content.accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton).accessibilityIdentifier(row.accessibilityID)
                    .accessibilityAction { action() }
            } else { row.content }
        }
        override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
            guard let id = source.itemIdentifier(for: indexPath) else { return false }
            return value?.selecting == true || rows[id]?.action != nil
        }
        override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let id = source.itemIdentifier(for: indexPath) else { return }
            if let value, value.selecting { value.selectionChanged?(value.selected.union([id])) }
            else { collectionView.deselectItem(at: indexPath, animated: true); rows[id]?.action?() }
        }
        override func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
            guard let value, value.selecting, let id = source.itemIdentifier(for: indexPath) else { return }
            value.selectionChanged?(value.selected.subtracting([id]))
        }
        override func collectionView(_ collectionView: UICollectionView, targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath, atCurrentIndexPath currentIndexPath: IndexPath, toProposedIndexPath proposedIndexPath: IndexPath) -> IndexPath {
            // Sorting may reorder its keys, never the reset/add section.
            guard proposedIndexPath.section == originalIndexPath.section else { return currentIndexPath }
            return proposedIndexPath
        }
    }
}

func themedListBackground(_ theme: ThemeSurface, state: UICellConfigurationState, clear: Bool = false) -> UIBackgroundConfiguration {
    if clear { return .clear() }
    var background = UIBackgroundConfiguration.listCell()
    background.backgroundColor = theme.surface
    return background.updated(for: state)
}
