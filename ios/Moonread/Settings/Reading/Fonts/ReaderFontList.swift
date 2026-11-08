import SwiftUI
import UIKit

/// Font-picker-only native list. UIKit owns the grouped row shape and swipe
/// transition; the palette supplies colors, never a replacement background view.
struct ReaderFontList: UIViewControllerRepresentable {
    struct Row {
        let id: String
        let title: String
        var subtitle: String?
        var font: UIFont = .preferredFont(forTextStyle: .body)
        var selected = false
        var download = false
        var downloading = false
        var progress: Double?
        var enabled = true
        var secondary = false
        var error = false
        var action: (() -> Void)?
        var remove: (() -> Void)?
    }
    struct Section {
        let id: Int
        var title: String?
        var footer: String?
        var rows: [Row]
    }

    let sections: [Section]
    let theme: ThemeSurface
    let focusedResource: String?

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(sections: sections, theme: theme, focus: focusedResource)
    }

    final class Controller: UICollectionViewController {
        private var sections: [Section] = []
        private var rows: [String: Row] = [:]
        private var theme: ThemeSurface?
        private var focus: String?
        private var source: UICollectionViewDiffableDataSource<Int, String>!

        init() { super.init(collectionViewLayout: UICollectionViewFlowLayout()) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            collectionView.accessibilityIdentifier = "readerFontList"
            let cells = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
                self?.configure(cell, id: id)
            }
            source = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { collection, path, id in
                collection.dequeueConfiguredReusableCell(using: cells, for: path, item: id)
            }
            let header = supplementary(kind: UICollectionView.elementKindSectionHeader, footer: false)
            let footer = supplementary(kind: UICollectionView.elementKindSectionFooter, footer: true)
            source.supplementaryViewProvider = { collection, kind, path in
                collection.dequeueConfiguredReusableSupplementary(using: kind == UICollectionView.elementKindSectionFooter ? footer : header, for: path)
            }
        }

        private func supplementary(kind: String, footer: Bool) -> UICollectionView.SupplementaryRegistration<UICollectionViewListCell> {
            UICollectionView.SupplementaryRegistration(elementKind: kind) { [weak self] cell, _, path in
                guard let self, self.sections.indices.contains(path.section) else { return }
                let section = self.sections[path.section]
                var content = footer ? UIListContentConfiguration.footer() : .header()
                content.text = footer ? section.footer : section.title
                content.textProperties.color = self.theme?.secondary ?? .secondaryLabel
                cell.contentConfiguration = content
                cell.backgroundConfiguration = .clear()
                cell.accessibilityTraits = footer ? .staticText : .header
            }
        }

        private func layout() -> UICollectionViewLayout {
            UICollectionViewCompositionalLayout { [weak self] index, environment in
                guard let self, self.sections.indices.contains(index) else { return nil }
                let section = self.sections[index]
                var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
                config.backgroundColor = self.theme?.canvas
                config.separatorConfiguration.color = self.theme?.separator ?? .separator
                config.headerMode = section.title == nil ? .none : .supplementary
                config.footerMode = section.footer == nil ? .none : .supplementary
                config.trailingSwipeActionsConfigurationProvider = { [weak self] path in
                    guard let self, let id = self.source.itemIdentifier(for: path),
                          let row = self.rows[id], row.enabled, let remove = row.remove else { return nil }
                    let action = UIContextualAction(style: .destructive, title: String(localized: "删除")) { _, _, completion in
                        // The SwiftUI owner still confirms before removing a file.
                        // Do not report a deletion to UIKit while it is unconfirmed.
                        completion(false)
                        remove()
                    }
                    action.backgroundColor = .systemRed
                    let result = UISwipeActionsConfiguration(actions: [action])
                    result.performsFirstActionWithFullSwipe = false
                    return result
                }
                return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            }
        }

        func update(sections: [Section], theme: ThemeSurface, focus: String?) {
            loadViewIfNeeded()
            let layoutChanged = self.theme != theme || self.sections.map(\.id) != sections.map(\.id)
            self.sections = sections
            self.rows = Dictionary(uniqueKeysWithValues: sections.flatMap(\.rows).map { ($0.id, $0) })
            self.theme = theme
            collectionView.backgroundColor = theme.canvas
            collectionView.tintColor = theme.accent
            if layoutChanged { collectionView.setCollectionViewLayout(layout(), animated: false) }

            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            for section in sections {
                snapshot.appendSections([section.id])
                snapshot.appendItems(section.rows.map(\.id), toSection: section.id)
            }
            let previous = Set(source.snapshot().itemIdentifiers)
            snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { previous.contains($0) })
            source.apply(snapshot, animatingDifferences: false)
            if self.focus != focus {
                self.focus = focus
                if let focus, let path = source.indexPath(for: focus) {
                    collectionView.layoutIfNeeded()
                    collectionView.scrollToItem(at: path, at: .centeredVertically, animated: true)
                }
            }
        }

        private func configure(_ cell: UICollectionViewListCell, id: String) {
            guard let row = rows[id], let theme else { return }
            var content = cell.defaultContentConfiguration()
            content.text = row.title
            content.secondaryText = row.subtitle
            content.textProperties.font = row.font
            content.textProperties.color = row.error ? theme.destructive : row.secondary ? theme.secondary : theme.ink
            content.textProperties.numberOfLines = 0
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
            content.secondaryTextProperties.color = theme.secondary
            content.secondaryTextProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.tintColor = theme.accent
            cell.configurationUpdateHandler = { cell, state in
                var background = UIBackgroundConfiguration.listCell()
                background.backgroundColor = theme.surface
                cell.backgroundConfiguration = background.updated(for: state)
            }
            cell.setNeedsUpdateConfiguration()
            cell.accessories = []
            if row.downloading {
                let progress: UIView
                if let value = row.progress {
                    let bar = UIProgressView(progressViewStyle: .default)
                    bar.progress = Float(value)
                    bar.frame.size = CGSize(width: 44, height: 2)
                    progress = bar
                } else {
                    let spinner = UIActivityIndicatorView(style: .medium)
                    spinner.startAnimating()
                    progress = spinner
                }
                progress.accessibilityLabel = String(localized: "正在下载字体")
                cell.accessories = [.customView(configuration: .init(customView: progress, placement: .trailing()))]
            } else if row.download {
                let image = UIImageView(image: UIImage(systemName: "icloud.and.arrow.down"))
                image.accessibilityLabel = String(localized: "下载")
                cell.accessories = [.customView(configuration: .init(customView: image, placement: .trailing()))]
            } else if row.selected { cell.accessories = [.checkmark()] }
            cell.accessibilityIdentifier = id
            cell.accessibilityTraits = row.action == nil ? .staticText : .button
            if row.selected { cell.accessibilityTraits.insert(.selected) }
            if !row.enabled { cell.accessibilityTraits.insert(.notEnabled) }
            cell.accessibilityCustomActions = row.enabled ? row.remove.map { remove in
                [UIAccessibilityCustomAction(name: String(localized: "删除")) { _ in remove(); return true }]
            } : nil
        }

        override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
            guard let id = source.itemIdentifier(for: indexPath), let row = rows[id] else { return false }
            return row.enabled && row.action != nil
        }
        override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            collectionView.deselectItem(at: indexPath, animated: true)
            if let id = source.itemIdentifier(for: indexPath), let row = rows[id], row.enabled { row.action?() }
        }
    }
}
