import SwiftUI
import UIKit

/// 播放列表页的列表显示方式，用原生 `UICollectionView`：SwiftUI 的 `List` 会自己接走拖放，
/// 行上的放置目标收不到。这里由集合视图统一处理点按、长按菜单与“拖到文件夹上移入”，
/// 行内容仍由 SwiftUI 渲染。交互对照 Apple Music：长按先出菜单，接着拖动即拿起封面缩略图，
/// 拖到文件夹上整行高亮，松手移入。
struct GenericCollectionList<Item: Identifiable & Equatable>: UIViewControllerRepresentable {
    let items: [Item]
    let menu: (Item) -> UIMenu
    let open: (Item, @escaping () -> UIView?) -> Void
    let moveItem: ((_ id: String, _ folderID: String) -> Void)?
    let shelfItem: (Item) -> LibraryShelfItem
    let route: (Item) -> LibraryRoute

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UICollectionViewController {
        let coordinator = context.coordinator
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.backgroundColor = .clear
        configuration.itemSeparatorHandler = { [weak coordinator] indexPath, separator in
            coordinator?.separator(at: indexPath, base: separator) ?? separator
        }
        let controller = PlaylistListController(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        let collectionView = controller.collectionView!
        collectionView.backgroundColor = .clear
        collectionView.delegate = coordinator
        collectionView.prefetchDataSource = coordinator
        collectionView.dragDelegate = coordinator
        collectionView.dropDelegate = coordinator
        collectionView.dragInteractionEnabled = true
        coordinator.attach(to: collectionView, initial: self, environment: context.environment)
        return controller
    }

    func updateUIViewController(_ controller: UICollectionViewController, context: Context) {
        context.coordinator.update(with: self, environment: context.environment,
                                   animated: context.transaction.animation != nil && !context.transaction.disablesAnimations)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching, UICollectionViewDragDelegate, UICollectionViewDropDelegate {
        private var latest: GenericCollectionList<Item>?
        private var itemsByID: [String: Item] = [:]
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>?
        private var hasApplied = false
        private var environment = EnvironmentValues()
        private weak var collectionView: UICollectionView?
        private var configuredColorScheme: ColorScheme?
        private var configuredDynamicTypeSize: DynamicTypeSize?
        private var configuredLocale: Locale?
        private var prefetchTasks: [IndexPath: Task<Void, Never>] = [:]

        private static var separatorLeading: CGFloat { 20 + 64 + 12 }
        private static var rowHeight: CGFloat { 80 }

        func attach(to collectionView: UICollectionView, initial: GenericCollectionList<Item>, environment: EnvironmentValues) {
            self.collectionView = collectionView
            let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
                self?.configure(cell, id: id)
            }
            dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
                collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
            }
            update(with: initial, environment: environment)
        }

        func update(with list: GenericCollectionList<Item>, environment: EnvironmentValues, animated: Bool = false) {
            guard let dataSource else { return }
            self.environment = environment
            let previous = itemsByID
            latest = list
            itemsByID = Dictionary(list.items.map { ($0.id as! String, $0) }, uniquingKeysWith: { first, _ in first })

            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(list.items.map { $0.id as! String })
            let appearanceChanged = configuredColorScheme != environment.colorScheme
                || configuredDynamicTypeSize != environment.dynamicTypeSize || configuredLocale != environment.locale
            let changed = list.items.filter { item in
                previous[item.id as! String].map { $0 != item || appearanceChanged } ?? false
            }.map { $0.id as! String }
            snapshot.reconfigureItems(changed)
            if hasApplied, changed.isEmpty, dataSource.snapshot().itemIdentifiers == snapshot.itemIdentifiers { return }
            let needsLayout = configuredDynamicTypeSize != environment.dynamicTypeSize
            configuredColorScheme = environment.colorScheme
            configuredDynamicTypeSize = environment.dynamicTypeSize
            configuredLocale = environment.locale
            dataSource.apply(snapshot, animatingDifferences: hasApplied && animated && !environment.accessibilityReduceMotion) { [weak self] in
                if needsLayout { self?.collectionView?.collectionViewLayout.invalidateLayout() }
            }
            hasApplied = true
        }

        private func item(at indexPath: IndexPath) -> Item? {
            dataSource?.itemIdentifier(for: indexPath).flatMap { itemsByID[$0] }
        }

        private func configure(_ cell: UICollectionViewListCell, id: String) {
            guard let item = itemsByID[id], let latest else { return }
            let environment = environment
            cell.contentConfiguration = UIHostingConfiguration {
                PlaylistListRow(item: latest.shelfItem(item), usesCellArtwork: true)
                    .libraryHostedAppearance(environment)
                    .environment(\.nativeArtworkSurfaceEnabled, false)
            }
                .margins(.leading, 20)
                .margins(.trailing, 8)
                .margins(.vertical, 0)
                .minSize(height: Self.rowHeight)
            cell.backgroundConfiguration = cell.defaultBackgroundConfiguration()
            cell.accessories = [.disclosureIndicator()]
            cell.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
            cell.accessibilityTraits = .button
        }

        func separator(at indexPath: IndexPath, base: UIListSeparatorConfiguration) -> UIListSeparatorConfiguration {
            var separator = base
            separator.topSeparatorVisibility = .hidden
            let isLast = indexPath.item == (dataSource?.snapshot().numberOfItems ?? 0) - 1
            separator.bottomSeparatorVisibility = isLast ? .hidden : .visible
            separator.bottomSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: Self.separatorLeading, bottom: 0, trailing: 20)
            return separator
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            if let item = item(at: indexPath), let latest {
                latest.open(item) { [weak self] in
                    guard let self, let path = self.dataSource?.indexPath(for: item.id as! String),
                          let cell = self.collectionView?.cellForItem(at: path) else { return nil }
                    return cell.libraryArtworkSource()
                }
            }
        }

        func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                            point: CGPoint) -> UIContextMenuConfiguration? {
            guard indexPaths.count == 1, let indexPath = indexPaths.first, let item = item(at: indexPath),
                  let latest else { return nil }
            let shelfItem = latest.shelfItem(item)
            let environment = environment
            let traits = collectionView.traitCollection.modifyingTraits {
                $0.preferredContentSizeCategory = UIContentSizeCategory(environment.dynamicTypeSize)
            }
            return UIContextMenuConfiguration(identifier: item.id as! String as NSString) {
                let size = MenuPreviewCard.size(for: shelfItem.previewLines, compatibleWith: traits)
                let preview = UIHostingController(rootView: MenuPreviewCard(artwork: shelfItem.artwork, lines: shelfItem.previewLines)
                    .libraryHostedAppearance(environment)
                    .frame(width: size.width, height: size.height))
                preview.traitOverrides.preferredContentSizeCategory = traits.preferredContentSizeCategory
                preview.safeAreaRegions = []
                preview.preferredContentSize = size
                preview.view.backgroundColor = .clear
                return preview
            } actionProvider: { _ in
                latest.menu(item)
            }
        }

        func collectionView(_ collectionView: UICollectionView,
                            willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
                            animator: any UIContextMenuInteractionCommitAnimating) {
            guard let id = configuration.identifier as? String, let item = itemsByID[id], let latest else { return }
            animator.preferredCommitStyle = .dismiss
            animator.addCompletion { [weak self] in
                latest.open(item) { [weak self] in
                    guard let self, let path = self.dataSource?.indexPath(for: id),
                          let cell = self.collectionView?.cellForItem(at: path) else { return nil }
                    return cell.libraryArtworkSource()
                }
            }
        }

        func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession,
                            at indexPath: IndexPath) -> [UIDragItem] {
            guard let item = item(at: indexPath), let latest else { return [] }
            let shelfItem = latest.shelfItem(item)
            let dragItem = UIDragItem(itemProvider: NSItemProvider(object: item.id as! String as NSString))
            dragItem.localObject = item.id
            if let image = Self.thumbnail(for: shelfItem.artwork, scale: collectionView.traitCollection.displayScale) {
                dragItem.previewProvider = {
                    let view = UIImageView(image: image)
                    view.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
                    let parameters = UIDragPreviewParameters()
                    parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: 8)
                    return UIDragPreview(view: view, parameters: parameters)
                }
            }
            return [dragItem]
        }

        private static func thumbnail(for artwork: Artwork, scale: CGFloat) -> UIImage? {
            let renderer = ImageRenderer(content: ArtworkView(artwork: artwork, cornerRadius: 8).frame(width: 64, height: 64))
            renderer.scale = scale
            return renderer.uiImage
        }

        func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
            latest?.moveItem != nil && session.localDragSession != nil
        }

        func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                            withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
            guard let destinationIndexPath, let item = item(at: destinationIndexPath),
                  case .playlistFolder = (latest?.route(item)) else {
                return UICollectionViewDropProposal(operation: .cancel)
            }
            return UICollectionViewDropProposal(operation: .move, intent: .insertIntoDestinationIndexPath)
        }

        func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
            guard let destination = coordinator.destinationIndexPath,
                  let targetItem = item(at: destination),
                  case .playlistFolder(let folderID) = latest?.route(targetItem), let latest else { return }
            let cell = collectionView.cellForItem(at: destination)
            for item in coordinator.items {
                guard let id = item.dragItem.localObject as? String else { continue }
                if let cell {
                    let target = CGRect(x: 20 + 32 - 1, y: cell.bounds.midY - 1, width: 2, height: 2)
                    coordinator.drop(item.dragItem, intoItemAt: destination, rect: target)
                }
                latest.moveItem?(id, folderID)
            }
        }

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            guard let latest else { return }
            let pixels = LocalArtworkImages.pixelSize(64 * max(1, collectionView.traitCollection.displayScale))
            let loadAction = environment.artworkLoadAction
            for path in indexPaths where prefetchTasks[path] == nil {
                guard let item = item(at: path) else { continue }
                let artwork = latest.shelfItem(item).artwork
                switch artwork {
                case .file(let url):
                    guard LocalArtworkImages.cached(url, pixels: pixels) == nil else { continue }
                    prefetchTasks[path] = Task { [weak self] in
                        defer { self?.prefetchTasks[path] = nil }
                        _ = await LocalArtworkImages.loadThumbnail(url, pixels: pixels)
                    }
                case .deferred(let loadID, _):
                    if LocalArtworkImages.cachedResolved(loadID, pixels: pixels) != nil { continue }
                    if let resolved = LocalArtworkImages.resolvedURL(for: loadID) {
                        prefetchTasks[path] = Task { [weak self] in
                            defer { self?.prefetchTasks[path] = nil }
                            _ = await LocalArtworkImages.loadThumbnail(resolved, pixels: pixels)
                        }
                        continue
                    }
                    prefetchTasks[path] = Task { [weak self] in
                        defer { self?.prefetchTasks[path] = nil }
                        if let file = await loadAction.resolve?(loadID) {
                            guard !Task.isCancelled else { return }
                            LocalArtworkImages.registerResolvedArtwork(loadID, url: file)
                            _ = await LocalArtworkImages.loadThumbnail(file, pixels: pixels)
                            return
                        }
                        guard !Task.isCancelled else { return }
                        loadAction(loadID)
                    }
                default:
                    break
                }
            }
        }

        func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            for path in indexPaths {
                prefetchTasks.removeValue(forKey: path)?.cancel()
            }
        }
    }
}

extension PlaylistEntry {
    /// 影响行显示的内容；变化时重新配置这一行。
    var signature: String {
        let item = shelfItem
        let contents: [String]
        if case .folder(_, let playlists) = self { contents = playlists.prefix(4).map(\.id) }
        else { contents = [] }
        return ([item.title, item.subtitle ?? "", item.isFavorite ? "1" : "0"] + contents).joined(separator: "\u{1}")
    }
}

/// UIHostingConfiguration supports a view-backed cover without child controllers.
struct PlaylistCellArtwork: UIViewRepresentable {
    let artwork: Artwork
    func makeUIView(context: Context) -> LibraryArtworkSurfaceView { LibraryArtworkSurfaceView() }
    func updateUIView(_ view: LibraryArtworkSurfaceView, context: Context) {
        let configuration = UIHostingConfiguration {
            ArtworkView(artwork: artwork, cornerRadius: 6)
                .libraryHostedAppearance(context.environment)
                .environment(\.nativeArtworkSurfaceEnabled, false)
        }.margins(.all, 0)
        if let content = view.subviews.first as? (UIView & UIContentView) {
            content.configuration = configuration
        } else {
            let content = configuration.makeContentView()
            content.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                content.topAnchor.constraint(equalTo: view.topAnchor),
                content.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }
        view.layer.cornerRadius = 6
        view.clipsToBounds = true
    }
}

/// Coordinate selection fading with the containing navigation transition.
private final class PlaylistListController: UICollectionViewController {
    override func viewWillAppear(_ animated: Bool) {
        clearsSelectionOnViewWillAppear = false
        super.viewWillAppear(animated)
        let selected = collectionView.indexPathsForSelectedItems ?? []
        guard !selected.isEmpty else { return }
        guard let transitionCoordinator else {
            selected.forEach { collectionView.deselectItem(at: $0, animated: animated) }
            return
        }
        transitionCoordinator.animate(alongsideTransition: { [weak self] _ in
            guard let self else { return }
            selected.forEach { self.collectionView.deselectItem(at: $0, animated: animated) }
        }, completion: { [weak self] context in
            guard let self, context.isCancelled else { return }
            selected.forEach { self.collectionView.selectItem(at: $0, animated: false, scrollPosition: []) }
        })
    }
}
