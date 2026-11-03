import SwiftUI
import UIKit

/// 播放列表页的列表显示方式，用原生 `UICollectionView`：SwiftUI 的 `List` 会自己接走拖放，
/// 行上的放置目标收不到。这里由集合视图统一处理点按、长按菜单与“拖到文件夹上移入”，
/// 行内容仍由 SwiftUI 渲染。交互对照 Apple Music：长按先出菜单，接着拖动即拿起封面缩略图，
/// 拖到文件夹上整行高亮，松手移入。
struct PlaylistCollectionList: UIViewControllerRepresentable {
    let entries: [PlaylistEntry]
    let menu: (PlaylistEntry) -> UIMenu
    let open: (LibraryRoute, @escaping () -> UIView?) -> Void
    let movePlaylist: (_ playlistID: String, _ folderID: String) -> Void

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
        collectionView.dragDelegate = coordinator
        collectionView.dropDelegate = coordinator
        collectionView.dragInteractionEnabled = true
        coordinator.attach(to: collectionView, initial: self)
        return controller
    }

    func updateUIViewController(_ controller: UICollectionViewController, context: Context) {
        context.coordinator.update(with: self)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDragDelegate, UICollectionViewDropDelegate {
        private var latest: PlaylistCollectionList?
        private var entriesByID: [String: PlaylistEntry] = [:]
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>?
        private var hasApplied = false
        private weak var collectionView: UICollectionView?

        /// 分隔线从标题起点画到右边距，最后一行不画；与 SwiftUI 版本及 Apple Music 一致。
        private static let separatorLeading: CGFloat = 20 + 64 + 12
        private static let rowHeight: CGFloat = 80

        func attach(to collectionView: UICollectionView, initial: PlaylistCollectionList) {
            self.collectionView = collectionView
            let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
                self?.configure(cell, id: id)
            }
            dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
                collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
            }
            update(with: initial)
        }

        func update(with list: PlaylistCollectionList) {
            guard let dataSource else { return }
            let previous = entriesByID
            latest = list
            entriesByID = Dictionary(list.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(list.entries.map(\.id))
            // 标题、数量、喜爱等变化后重新配置对应的行。
            let changed = list.entries.filter { entry in
                previous[entry.id].map { $0.signature != entry.signature } ?? false
            }.map(\.id)
            snapshot.reconfigureItems(changed)
            if hasApplied, changed.isEmpty, dataSource.snapshot().itemIdentifiers == snapshot.itemIdentifiers { return }
            dataSource.apply(snapshot, animatingDifferences: hasApplied)
            hasApplied = true
        }

        private func entry(at indexPath: IndexPath) -> PlaylistEntry? {
            dataSource?.itemIdentifier(for: indexPath).flatMap { entriesByID[$0] }
        }

        private func configure(_ cell: UICollectionViewListCell, id: String) {
            guard let entry = entriesByID[id] else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                PlaylistListRow(item: entry.shelfItem, usesCellArtwork: true)
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

        // MARK: 点按

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            if let entry = entry(at: indexPath) { open(entry) }
        }

        private func open(_ entry: PlaylistEntry) {
            let id = entry.id
            latest?.open(entry.route) { [weak self] in
                guard let self, let path = self.dataSource?.indexPath(for: id),
                      let cell = self.collectionView?.cellForItem(at: path) else { return nil }
                return cell.libraryArtworkSource()
            }
        }

        // MARK: 长按菜单

        func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                            point: CGPoint) -> UIContextMenuConfiguration? {
            guard indexPaths.count == 1, let indexPath = indexPaths.first, let entry = entry(at: indexPath),
                  let latest else { return nil }
            let item = entry.shelfItem
            return UIContextMenuConfiguration(identifier: entry.id as NSString) {
                let size = MenuPreviewCard.size(for: item.previewLines)
                let preview = UIHostingController(rootView: MenuPreviewCard(artwork: item.artwork, lines: item.previewLines)
                    .frame(width: size.width, height: size.height))
                preview.safeAreaRegions = []
                preview.preferredContentSize = size
                preview.view.backgroundColor = .clear
                return preview
            } actionProvider: { _ in
                latest.menu(entry)
            }
        }

        /// 点按菜单上方的预览卡片进入详情。
        func collectionView(_ collectionView: UICollectionView,
                            willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
                            animator: any UIContextMenuInteractionCommitAnimating) {
            guard let id = configuration.identifier as? String, let entry = entriesByID[id] else { return }
            animator.preferredCommitStyle = .dismiss
            animator.addCompletion { [weak self] in self?.open(entry) }
        }

        // MARK: 拖动

        func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession,
                            at indexPath: IndexPath) -> [UIDragItem] {
            guard case .playlist(let playlist) = entry(at: indexPath) else { return [] }
            let item = UIDragItem(itemProvider: NSItemProvider(object: playlist.id as NSString))
            item.localObject = playlist.id
            // 拖动时只显示封面缩略图，与 Apple Music 一致。
            if let image = Self.thumbnail(for: playlist.artwork, scale: collectionView.traitCollection.displayScale) {
                item.previewProvider = {
                    let view = UIImageView(image: image)
                    view.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
                    let parameters = UIDragPreviewParameters()
                    parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: 8)
                    return UIDragPreview(view: view, parameters: parameters)
                }
            }
            return [item]
        }

        private static func thumbnail(for artwork: Artwork, scale: CGFloat) -> UIImage? {
            let renderer = ImageRenderer(content: ArtworkView(artwork: artwork, cornerRadius: 8).frame(width: 64, height: 64))
            renderer.scale = scale
            return renderer.uiImage
        }

        // MARK: 放置

        func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
            session.localDragSession != nil
        }

        /// 只能放进文件夹：手指在文件夹行上时整行高亮，其他位置不接收。
        func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                            withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
            guard let destinationIndexPath, case .folder = entry(at: destinationIndexPath) else {
                return UICollectionViewDropProposal(operation: .cancel)
            }
            return UICollectionViewDropProposal(operation: .move, intent: .insertIntoDestinationIndexPath)
        }

        func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
            guard let destination = coordinator.destinationIndexPath,
                  case .folder(let folder, _) = entry(at: destination), let latest else { return }
            let cell = collectionView.cellForItem(at: destination)
            for item in coordinator.items {
                guard let id = item.dragItem.localObject as? String else { continue }
                // 缩略图落进文件夹那一行的封面处后消失。
                if let cell {
                    let target = CGRect(x: 20 + 32 - 1, y: cell.bounds.midY - 1, width: 2, height: 2)
                    coordinator.drop(item.dragItem, intoItemAt: destination, rect: target)
                }
                latest.movePlaylist(id, folder.id)
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
