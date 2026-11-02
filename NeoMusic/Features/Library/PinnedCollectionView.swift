import SwiftUI
import UIKit

/// 首页置顶区使用单个原生集合视图；每个置顶项都是独立 cell。
/// UIKit 负责菜单与交互式重排，资料库仍是置顶状态和顺序的唯一来源。
struct PinnedCollectionView: UIViewControllerRepresentable {
    let items: [LibraryShelfItem]
    let isEditing: Bool
    @Binding var tapActions: [String: PinnedTapAction]
    let reorder: ([LibraryRoute]) -> Bool
    let remove: (LibraryShelfItem) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UICollectionViewController {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = Metrics.spacing
        layout.minimumLineSpacing = Metrics.rowSpacing
        let controller = UICollectionViewController(collectionViewLayout: layout)
        controller.installsStandardGestureForInteractiveMovement = false
        controller.loadViewIfNeeded()
        let view = controller.collectionView!
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.allowsMultipleSelection = false
        view.contentInsetAdjustmentBehavior = .never
        view.clipsToBounds = false
        view.delegate = context.coordinator
        view.dragDelegate = context.coordinator
        view.dropDelegate = context.coordinator
        view.dragInteractionEnabled = true
        context.coordinator.attach(to: view, initial: self, environment: context.environment)
        return controller
    }

    func updateUIViewController(_ controller: UICollectionViewController, context: Context) {
        context.coordinator.update(with: self, environment: context.environment)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: UICollectionViewController, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let rows = (items.count + Metrics.columns - 1) / Metrics.columns
        guard rows > 0 else { return CGSize(width: width, height: 0) }
        let height = Metrics.itemHeight(width: width, traits: uiViewController.traitCollection)
        return CGSize(width: width, height: CGFloat(rows) * height + CGFloat(rows - 1) * Metrics.rowSpacing)
    }

    private enum Metrics {
        static let columns = 3
        static let spacing: CGFloat = 12
        static let rowSpacing: CGFloat = 16
        static let titleSpacing: CGFloat = 6

        static func itemWidth(_ width: CGFloat) -> CGFloat {
            max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        }

        static func itemHeight(width: CGFloat, traits: UITraitCollection) -> CGFloat {
            let font = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits)
            return itemWidth(width) + titleSpacing + ceil(font.lineHeight)
        }
    }

    private static func identity(_ item: LibraryShelfItem) -> String {
        switch item.route {
        case .album(let id): "album:" + id
        case .playlist(let id): "playlist:" + id
        default: "other:" + item.id
        }
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout,
                             UICollectionViewDragDelegate, UICollectionViewDropDelegate {
        private weak var collectionView: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>?
        private var latest: PinnedCollectionView?
        private var environment = EnvironmentValues()
        private var itemsByID: [String: LibraryShelfItem] = [:]
        private var pendingCommittedOrder: [String]?
        private var hasApplied = false
        private var hasScheduledUpdate = false

        func attach(to view: UICollectionView, initial: PinnedCollectionView, environment: EnvironmentValues) {
            collectionView = view
            let registration = UICollectionView.CellRegistration<PinnedCollectionCell, String> { [weak self] cell, indexPath, id in
                self?.configure(cell, indexPath: indexPath, id: id)
            }
            let source = UICollectionViewDiffableDataSource<Int, String>(collectionView: view) { view, indexPath, id in
                view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
            }
            dataSource = source
            update(with: initial, environment: environment)
        }

        func update(with view: PinnedCollectionView, environment: EnvironmentValues) {
            latest = view
            self.environment = environment
            // Edit state must reach visible cells even while a drag or snapshot is settling.
            for case let cell as PinnedCollectionCell in collectionView?.visibleCells ?? [] {
                cell.setEditing(view.isEditing, phase: collectionView?.indexPath(for: cell)?.item ?? 0,
                                reduceMotion: environment.accessibilityReduceMotion)
            }
            guard hasApplied else { applyLatestSnapshot(); return }
            guard !hasScheduledUpdate else { return }
            hasScheduledUpdate = true
            // SwiftUI may suppress UIView animations during representable updates.
            // Apply the latest snapshot on the next turn so UIKit owns its animation.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hasScheduledUpdate = false
                self.applyLatestSnapshot()
            }
        }

        private func applyLatestSnapshot() {
            guard let view = latest else { return }
            let identifiers = view.items.map(PinnedCollectionView.identity)
            // Diffable snapshots require unique item identities. Never silently
            // delete or merge data when presented with an invalid input.
            guard Set(identifiers).count == identifiers.count else { return }
            itemsByID = Dictionary(uniqueKeysWithValues: zip(identifiers, view.items))
            guard let source = dataSource else { return }
            collectionView?.dragInteractionEnabled = !view.isEditing
            if collectionView?.hasActiveDrag == true { return }
            if let pending = pendingCommittedOrder {
                if Set(pending) != Set(identifiers) || pending == identifiers {
                    pendingCommittedOrder = nil
                } else {
                    // A stale parent render must not undo a just-completed drag.
                    return
                }
            }
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(identifiers)
            let existing = Set(source.snapshot().itemIdentifiers)
            snapshot.reconfigureItems(identifiers.filter { existing.contains($0) })
            source.apply(snapshot, animatingDifferences: hasApplied && !environment.accessibilityReduceMotion) { [weak self] in
                self?.collectionView?.collectionViewLayout.invalidateLayout()
            }
            hasApplied = true
        }

        private func commitOrder(from original: [String], to final: [String]) -> Bool {
            guard let latest else { return false }
            let current = latest.items.map(PinnedCollectionView.identity)
            let originalSet = Set(original)
            guard original.count == originalSet.count, final.count == original.count,
                  Set(final) == originalSet, current == original else { return false }
            let routes = final.compactMap { itemsByID[$0]?.route }
            guard routes.count == final.count else { return false }
            if final == original { return true }
            // There is one commit owner: drop validates and saves before applying its snapshot.
            pendingCommittedOrder = final
            guard latest.reorder(routes) else {
                pendingCommittedOrder = nil
                return false
            }
            return true
        }

        private func restoreLatestSnapshot() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let latest = self.latest else { return }
                self.update(with: latest, environment: self.environment)
            }
        }

        private func canReorder(_ id: String) -> Bool {
            guard let latest, !latest.isEditing, latest.items.count > 1,
                  let item = itemsByID[id] else { return false }
            switch item.route {
            case .album, .playlist: return true
            default: return false
            }
        }

        func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: any UIDragSession,
                            at indexPath: IndexPath) -> [UIDragItem] {
            guard let id = dataSource?.itemIdentifier(for: indexPath), canReorder(id) else { return [] }
            let item = UIDragItem(itemProvider: NSItemProvider(object: id as NSString))
            item.localObject = id
            session.localContext = self
            NavigationDiagnostics.event("Pinned.dragBegin", page: "library")
            return [item]
        }

        private func artworkPreviewParameters(in collectionView: UICollectionView, at indexPath: IndexPath) -> UIDragPreviewParameters? {
            guard let cell = collectionView.cellForItem(at: indexPath) else { return nil }
            cell.layoutIfNeeded()
            guard let artwork = cell.contentView.libraryArtworkSource() else { return nil }
            // Collection-view drag/drop previews snapshot the cell, so the crop
            // must use cell coordinates and exclude the caption below the artwork.
            let rect = artwork.convert(artwork.bounds, to: cell)
            guard !rect.isEmpty else { return nil }
            let parameters = UIDragPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = UIBezierPath(roundedRect: rect, cornerRadius: artwork.layer.cornerRadius)
            return parameters
        }

        func collectionView(_ collectionView: UICollectionView, dragPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
            artworkPreviewParameters(in: collectionView, at: indexPath)
        }

        func collectionView(_ collectionView: UICollectionView, dropPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
            artworkPreviewParameters(in: collectionView, at: indexPath)
        }

        func collectionView(_ collectionView: UICollectionView, dragSessionIsRestrictedToDraggingApplication session: any UIDragSession) -> Bool {
            true
        }

        func collectionView(_ collectionView: UICollectionView, dragSessionDidEnd session: any UIDragSession) {
            // Parent renders during the drag were deferred; replay the latest one after UIKit settles.
            restoreLatestSnapshot()
        }

        private func draggedID(in session: any UIDropSession) -> String? {
            guard session.localDragSession?.localContext as? Coordinator === self,
                  session.items.count == 1,
                  let id = session.items.first?.localObject as? String, canReorder(id) else { return nil }
            return id
        }

        func collectionView(_ collectionView: UICollectionView, canHandle session: any UIDropSession) -> Bool {
            draggedID(in: session) != nil
        }

        func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: any UIDropSession,
                            withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
            guard draggedID(in: session) != nil else { return UICollectionViewDropProposal(operation: .cancel) }
            return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
        }

        func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: any UICollectionViewDropCoordinator) {
            guard let id = draggedID(in: coordinator.session), let source = dataSource,
                  coordinator.items.count == 1, let item = coordinator.items.first,
                  let origin = item.sourceIndexPath, source.itemIdentifier(for: origin) == id else { return }
            let original = source.snapshot().itemIdentifiers
            guard let from = original.firstIndex(of: id) else { return }
            let proposed = coordinator.destinationIndexPath ?? IndexPath(item: original.count - 1, section: 0)
            guard proposed.section == 0 else { return }
            let target = min(max(0, proposed.item), original.count - 1)
            var order = original
            order.remove(at: from)
            order.insert(id, at: target)
            guard commitOrder(from: original, to: order) else { return }
            NavigationDiagnostics.event("Pinned.dropCommit", page: "library")
            if order != original {
                var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
                snapshot.appendSections([0])
                snapshot.appendItems(order)
                source.apply(snapshot, animatingDifferences: !environment.accessibilityReduceMotion)
            }
            coordinator.drop(item.dragItem, toItemAt: IndexPath(item: target, section: 0))
        }

        private func configure(_ cell: PinnedCollectionCell, indexPath: IndexPath, id: String) {
            guard let item = itemsByID[id], let latest else { return }
            let environment = environment
            let remove = latest.remove
            cell.setEditing(latest.isEditing, phase: indexPath.item, reduceMotion: environment.accessibilityReduceMotion)
            cell.backgroundColor = .clear
            cell.contentConfiguration = UIHostingConfiguration {
                PinnedCellContent(item: item, isEditing: latest.isEditing) {
                    withAnimation { remove(item) }
                }
                .libraryHostedAppearance(environment)
                .environment(\.nativeArtworkSurfaceEnabled, false)
            }
            .margins(.all, 0)
        }

        func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            (cell as? PinnedCollectionCell)?.setDisplayed(true)
        }

        func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            (cell as? PinnedCollectionCell)?.setDisplayed(false)
        }

        func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> CGSize {
            let width = collectionView.bounds.width
            return CGSize(width: Metrics.itemWidth(width), height: Metrics.itemHeight(width: width, traits: collectionView.traitCollection))
        }

        func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                            insetForSectionAt section: Int) -> UIEdgeInsets {
            let count = dataSource?.snapshot().numberOfItems ?? 0
            guard count > 0, count < Metrics.columns else { return .zero }
            let rowWidth = Metrics.itemWidth(collectionView.bounds.width) * CGFloat(count) + Metrics.spacing * CGFloat(count - 1)
            let side = max(0, (collectionView.bounds.width - rowWidth) / 2)
            return UIEdgeInsets(top: 0, left: side, bottom: 0, right: side)
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            collectionView.deselectItem(at: indexPath, animated: true)
            guard let id = dataSource?.itemIdentifier(for: indexPath), let item = itemsByID[id],
                  let route = item.route, let latest, !latest.isEditing else { return }
            switch latest.tapActions[id] ?? .open {
            case .open:
                open(item, id: id)
            case .play: environment.collectionMenuActions.play(route, false)
            case .shuffle: environment.collectionMenuActions.play(route, true)
            }
        }

        func collectionView(_ collectionView: UICollectionView,
                            contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
            guard indexPaths.count == 1, let indexPath = indexPaths.first,
                  let id = dataSource?.itemIdentifier(for: indexPath), let item = itemsByID[id],
                  let route = item.route, let latest, !latest.isEditing else { return nil }
            let environment = environment
            let tapAction = latest.tapActions[id] ?? .open
            let configuration = UIContextMenuConfiguration(identifier: id as NSString) {
                let size = MenuPreviewCard.size(for: item.previewLines)
                let content = MenuPreviewCard(artwork: item.artwork, lines: item.previewLines)
                    .libraryHostedAppearance(environment)
                    .frame(width: size.width, height: size.height)
                let preview = UIHostingController(rootView: content)
                preview.safeAreaRegions = []
                preview.preferredContentSize = size
                preview.view.backgroundColor = .clear
                return preview
            } actionProvider: { [weak self] _ in
                environment.collectionMenuActions.pinnedSections(for: item, route: route, tapAction: tapAction) { [weak self] action in
                    self?.setTapAction(action, for: id)
                }.nativeMenu(firstSectionIsRow: false)
            }
            configuration.preferredMenuElementOrder = .fixed
            return configuration
        }

        private func open(_ item: LibraryShelfItem, id: String) {
            guard let route = item.route else { return }
            environment.openLibraryRoute(route, sourceProvider: { [weak self] in
                guard let self, self.itemsByID[id]?.route == route,
                      let indexPath = self.dataSource?.indexPath(for: id) else { return nil }
                return self.collectionView?.cellForItem(at: indexPath)?.contentView.libraryArtworkSource()
            })
        }

        private func menuPreview(for configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
            guard let id = configuration.identifier as? String,
                  let indexPath = dataSource?.indexPath(for: id),
                  let view = collectionView?.cellForItem(at: indexPath)?.contentView,
                  let window = view.window else { return nil }
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: 8)
            let center = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: window)
            let target = UIPreviewTarget(container: window, center: center)
            return UITargetedPreview(view: view, parameters: parameters, target: target)
        }

        func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
                            highlightPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
            menuPreview(for: configuration)
        }

        func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
                            dismissalPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
            menuPreview(for: configuration)
        }

        private func setTapAction(_ action: PinnedTapAction, for id: String) {
            guard let latest, itemsByID[id] != nil else { return }
            latest.tapActions[id] = action
        }

        func collectionView(_ collectionView: UICollectionView,
                            willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
                            animator: any UIContextMenuInteractionCommitAnimating) {
            guard let id = configuration.identifier as? String, let route = itemsByID[id]?.route else { return }
            animator.preferredCommitStyle = .dismiss
            animator.addCompletion { [weak self] in
                guard let self, let item = self.itemsByID[id], item.route == route else { return }
                self.open(item, id: id)
            }
        }
    }
}

/// The cell owns its edit animation, so reconfiguration cannot leave a repeating
/// SwiftUI transaction alive after the toolbar has left editing mode.
final class PinnedCollectionCell: UICollectionViewCell {
    private static let wobbleKey = "pinnedEditingWobble"
    private var editing = false
    private var reduceMotion = false
    private var displayed = false
    private var phase = 0

    func setEditing(_ editing: Bool, phase: Int, reduceMotion: Bool) {
        self.editing = editing
        self.phase = phase
        self.reduceMotion = reduceMotion
        updateWobble()
    }

    func setDisplayed(_ displayed: Bool) {
        self.displayed = displayed
        updateWobble()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateWobble()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        editing = false
        displayed = false
        updateWobble()
    }

    private func updateWobble() {
        guard editing, !reduceMotion, displayed, window != nil else {
            contentView.layer.removeAnimation(forKey: Self.wobbleKey)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentView.layer.transform = CATransform3DIdentity
            CATransaction.commit()
            return
        }
        guard contentView.layer.animation(forKey: Self.wobbleKey) == nil else { return }
        let angle = 1.5 * Double.pi / 180
        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.values = [-angle, angle, -angle]
        animation.keyTimes = [0, 0.5, 1]
        animation.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        animation.duration = 2 * (0.13 + Double(phase % 3) * 0.015)
        animation.timeOffset = Double(phase) * 0.05
        animation.repeatCount = .infinity
        contentView.layer.add(animation, forKey: Self.wobbleKey)
    }
}

/// UIHostingConfiguration supports UIViewRepresentable, but not child view controllers.
/// Keep the original artwork drawing inside one real UIView, used by zoom and by the card.
private struct PinnedArtworkSurface: UIViewRepresentable {
    let artwork: Artwork

    func makeUIView(context: Context) -> LibraryArtworkSurfaceView {
        let view = LibraryArtworkSurfaceView()
        view.layer.cornerRadius = 8
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: LibraryArtworkSurfaceView, context: Context) {
        let configuration = UIHostingConfiguration {
            ArtworkView(artwork: artwork, cornerRadius: 8)
                .libraryHostedAppearance(context.environment)
                .environment(\.nativeArtworkSurfaceEnabled, false)
        }.margins(.all, 0)
        if let content = view.subviews.first as? any UIContentView {
            content.configuration = configuration
        } else {
            let content = configuration.makeContentView()
            content.backgroundColor = .clear
            content.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                content.topAnchor.constraint(equalTo: view.topAnchor),
                content.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }
    }
}

private struct PinnedCellContent: View {
    let item: LibraryShelfItem
    let isEditing: Bool
    let remove: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            PinnedArtworkSurface(artwork: item.artwork)
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            Text(item.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isEditing ? [] : .isButton)
        .overlay(alignment: .topLeading) {
            if isEditing {
                Button("取消置顶", systemImage: "minus", action: remove)
                    .buttonStyle(.plain)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color(.systemGray), in: .circle)
                    .offset(x: -8, y: -8)
            }
        }
    }
}
