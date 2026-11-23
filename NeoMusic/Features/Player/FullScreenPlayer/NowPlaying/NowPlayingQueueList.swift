import SwiftUI
import UIKit

struct NowPlayingQueueList: UIViewRepresentable {
    static let modeControlsHeight: CGFloat = 44
    static let topFadeHeight: CGFloat = 6
    static let bottomFadeHeight: CGFloat = 80
    @Environment(PlayerActions.self) private var actions
    @Environment(PlayerState.self) private var player
    @Environment(\.playerVisualsActive) private var visualsActive
    @Environment(PlayerServices.self) private var services: PlayerServices?
    let entries: [PlayerQueueEntry]
    let version: PlayerQueueVersion
    var trackTransitionKey: String = ""
    var subtitle: String = "接下来播放的歌曲"
    let headerHeight: CGFloat
    let horizontalInset: CGFloat
    let onPlay: (Int) -> Void
    let onMove: (IndexSet, Int) -> Void
    let onScroll: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> OverflowContainer {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        configuration.backgroundColor = .clear
        configuration.trailingSwipeActionsConfigurationProvider = { [weak coordinator = context.coordinator] indexPath in
            coordinator?.trailingActions(at: indexPath)
        }
        var queueConfiguration = configuration
        // The plain list appearance pins its supplementary header.
        queueConfiguration.headerMode = .supplementary
        queueConfiguration.headerTopPadding = 0
        let layout = UICollectionViewCompositionalLayout { section, environment in
            NSCollectionLayoutSection.list(
                using: section == Coordinator.Section.queue.rawValue ? queueConfiguration : configuration,
                layoutEnvironment: environment
            )
        }

        let collectionView = EdgeFadedCollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.alwaysBounceVertical = true
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset = UIEdgeInsets(
            top: Self.modeControlsHeight, left: 0, bottom: Self.bottomFadeHeight, right: 0
        )
        collectionView.contentOffset.y = -Self.modeControlsHeight
        collectionView.topEdgeEffect.isHidden = true
        collectionView.bottomEdgeEffect.isHidden = true
        collectionView.allowsSelection = false
        collectionView.showsVerticalScrollIndicator = true
        collectionView.automaticallyAdjustsScrollIndicatorInsets = false
        collectionView.overrideUserInterfaceStyle = .dark
        collectionView.delegate = context.coordinator
        context.coordinator.attach(to: collectionView, initial: self)
        return OverflowContainer(collectionView: collectionView, overflow: horizontalInset)
    }

    func updateUIView(_ container: OverflowContainer, context: Context) {
        if container.overflow != horizontalInset { container.overflow = horizontalInset }
        context.coordinator.update(with: self)
    }

    static func dismantleUIView(_ container: OverflowContainer, coordinator: Coordinator) {
        container.collectionView.prefetchDataSource = nil
        coordinator.cancelArtworkRequests()
    }

    private final class QueueEdgeMaskLayer: CAGradientLayer {
        override init() {
            super.init()
            let clear = UIColor.clear.cgColor
            let alpha35 = UIColor.black.withAlphaComponent(0.35).cgColor
            let alpha80 = UIColor.black.withAlphaComponent(0.8).cgColor
            let opaque = UIColor.black.cgColor
            colors = [clear, alpha35, alpha80, opaque, opaque, alpha80, alpha35, clear]
        }

        override init(layer: Any) { super.init(layer: layer) }
        required init?(coder: NSCoder) { super.init(coder: coder) }
    }

    @objc(NeoMusicEdgeFadedListCell)
    final class EdgeFadedListCell: UICollectionViewListCell {
        weak var edgeFadeCollectionView: EdgeFadedCollectionView?
        var contentRevision: UInt64?

        override func prepareForReuse() {
            super.prepareForReuse()
            contentRevision = nil
            edgeFadeCollectionView?.clearEdgeMasks(for: self)
        }

        override func layoutSublayers(of layer: CALayer) {
            super.layoutSublayers(of: layer)
            if layer === self.layer {
                edgeFadeCollectionView?.updateEdgeMask(for: self)
            }
        }
    }

    @objc(NeoMusicEdgeFadedCollectionView)
    final class EdgeFadedCollectionView: UICollectionView {
        var queueHeader: UICollectionViewListCell? {
            supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader,
                              at: IndexPath(item: 0, section: Coordinator.Section.queue.rawValue))
                as? UICollectionViewListCell
        }

        private let maskedCells = NSHashTable<UICollectionViewCell>.weakObjects()
        private var isUpdatingEdgeMasks = false

        override func layoutSubviews() {
            super.layoutSubviews()
            let insets = UIEdgeInsets(
                top: max(0, topFadeStart - bounds.minY) + NowPlayingQueueList.topFadeHeight,
                left: 0, bottom: NowPlayingQueueList.bottomFadeHeight, right: 0
            )
            if verticalScrollIndicatorInsets != insets { verticalScrollIndicatorInsets = insets }
            updateEdgeMasks()
        }

        func updateEdgeMasks() {
            guard !isUpdatingEdgeMasks, bounds.height > 0 else { return }
            isUpdatingEdgeMasks = true
            defer { isUpdatingEdgeMasks = false }

            let metrics = edgeFadeMetrics()
            for cell in visibleCells {
                applyEdgeMask(to: cell, metrics: metrics)
            }
        }

        func updateEdgeMask(for cell: UICollectionViewCell) {
            guard !isUpdatingEdgeMasks, bounds.height > 0, cell.superview != nil else { return }
            isUpdatingEdgeMasks = true
            defer { isUpdatingEdgeMasks = false }
            applyEdgeMask(to: cell, metrics: edgeFadeMetrics())
        }

        fileprivate func clearEdgeMasks(for cell: UICollectionViewCell) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            clearEdgeMasks(in: cell.layer)
            CATransaction.commit()
            maskedCells.remove(cell)
        }

        private struct EdgeFadeMetrics {
            let fadeTop: CGFloat
            let fadeTopEnd: CGFloat
            let fadeBottomStart: CGFloat
            let fadeBottomEnd: CGFloat
            let viewportRect: CGRect
            let locations: [NSNumber]
        }

        private var topFadeStart: CGFloat {
            if let queueHeader { return convert(queueHeader.bounds, from: queueHeader).maxY }
            return bounds.minY + adjustedContentInset.top
        }

        private func edgeFadeMetrics() -> EdgeFadeMetrics {
            let fadeTop = topFadeStart
            let fadeTopEnd = fadeTop + NowPlayingQueueList.topFadeHeight
            let fadeBottomEnd = bounds.maxY
            let fadeBottomStart = fadeBottomEnd - NowPlayingQueueList.bottomFadeHeight
            let viewportRect = CGRect(
                x: bounds.minX - 64,
                y: fadeTop,
                width: bounds.width + 128,
                height: max(fadeBottomEnd - fadeTop, 0)
            )
            let totalHeight = max(fadeBottomEnd - fadeTop, 1)
            let topEndLoc = Double(min(max((fadeTopEnd - fadeTop) / totalHeight, 0), 1))
            let bottomStartLoc = Double(min(max((fadeBottomStart - fadeTop) / totalHeight, topEndLoc), 1))
            let bottomSpan = 1.0 - bottomStartLoc
            let locations: [NSNumber] = [
                0.0,
                NSNumber(value: 0.3 * topEndLoc),
                NSNumber(value: 0.65 * topEndLoc),
                NSNumber(value: topEndLoc),
                NSNumber(value: bottomStartLoc),
                NSNumber(value: bottomStartLoc + 0.35 * bottomSpan),
                NSNumber(value: bottomStartLoc + 0.7 * bottomSpan),
                1.0
            ]
            return EdgeFadeMetrics(
                fadeTop: fadeTop,
                fadeTopEnd: fadeTopEnd,
                fadeBottomStart: fadeBottomStart,
                fadeBottomEnd: fadeBottomEnd,
                viewportRect: viewportRect,
                locations: locations
            )
        }

        private func applyEdgeMask(to cell: UICollectionViewCell, metrics: EdgeFadeMetrics) {
            let cellFrame = convert(cell.bounds, from: cell)
            if cellFrame.minY >= metrics.fadeTopEnd && cellFrame.maxY <= metrics.fadeBottomStart {
                if maskedCells.contains(cell) {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    clearEdgeMasks(in: cell.layer)
                    CATransaction.commit()
                    maskedCells.remove(cell)
                }
                return
            }

            maskedCells.add(cell)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            var targets: [CALayer] = []
            collectEdgeMaskTargets(in: cell.layer, targets: &targets)
            for target in targets {
                setEdgeMask(on: target, metrics: metrics)
            }
            CATransaction.commit()
        }

        private func clearEdgeMasks(in layer: CALayer) {
            if layer.mask is QueueEdgeMaskLayer {
                layer.mask = nil
            }
            for sublayer in layer.sublayers ?? [] {
                clearEdgeMasks(in: sublayer)
            }
        }

        @discardableResult
        private func collectEdgeMaskTargets(in layer: CALayer, targets: inout [CALayer]) -> Bool {
            let firstChildTarget = targets.count
            let hasFilter = layer.compositingFilter != nil
            var descendantsHaveFilter = false
            for sublayer in layer.sublayers ?? [] {
                let childHasFilter = collectEdgeMaskTargets(in: sublayer, targets: &targets)
                descendantsHaveFilter = descendantsHaveFilter || childHasFilter
            }

            let hasCustomMask = layer.mask != nil && !(layer.mask is QueueEdgeMaskLayer)
            if (hasFilter || !descendantsHaveFilter) && !hasCustomMask {
                for target in targets[firstChildTarget...] where target.mask is QueueEdgeMaskLayer {
                    target.mask = nil
                }
                targets.removeSubrange(firstChildTarget...)
                targets.append(layer)
            } else if layer.mask is QueueEdgeMaskLayer {
                layer.mask = nil
            }
            return hasFilter || descendantsHaveFilter
        }

        private func setEdgeMask(on targetLayer: CALayer, metrics: EdgeFadeMetrics) {
            let maskLayer = (targetLayer.mask as? QueueEdgeMaskLayer) ?? QueueEdgeMaskLayer()
            let localRect = targetLayer.convert(metrics.viewportRect, from: self.layer)
            let topY = targetLayer.convert(CGPoint(x: 0, y: metrics.fadeTop), from: self.layer).y
            let bottomY = targetLayer.convert(CGPoint(x: 0, y: metrics.fadeBottomEnd), from: self.layer).y
            let isFlippedY = topY > bottomY
            let startPoint = CGPoint(x: 0.5, y: isFlippedY ? 1 : 0)
            let endPoint = CGPoint(x: 0.5, y: isFlippedY ? 0 : 1)
            let scale = window?.screen.scale ?? traitCollection.displayScale

            if maskLayer.frame != localRect { maskLayer.frame = localRect }
            if maskLayer.startPoint != startPoint { maskLayer.startPoint = startPoint }
            if maskLayer.endPoint != endPoint { maskLayer.endPoint = endPoint }
            if maskLayer.contentsScale != scale { maskLayer.contentsScale = scale }
            if maskLayer.locations != metrics.locations { maskLayer.locations = metrics.locations }
            if targetLayer.mask !== maskLayer { targetLayer.mask = maskLayer }
        }
    }

    final class OverflowContainer: UIView {
        let collectionView: UICollectionView
        var overflow: CGFloat {
            didSet { setNeedsLayout() }
        }

        init(collectionView: UICollectionView, overflow: CGFloat) {
            self.collectionView = collectionView
            self.overflow = overflow
            super.init(frame: .zero)
            clipsToBounds = false
            addSubview(collectionView)
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            collectionView.frame = bounds.insetBy(dx: -overflow, dy: 0)
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            collectionView.frame.contains(point)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
        nonisolated enum Section: Int, Sendable { case header, queue }
        nonisolated enum Item: Hashable, Sendable {
            case spacer
            case empty
            case track(PlayerQueueEntry.ID)
        }

        private(set) var latest: NowPlayingQueueList?
        private var entriesByID: [PlayerQueueEntry.ID: PlayerQueueEntry] = [:]
        private(set) var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
        private weak var collectionView: EdgeFadedCollectionView?
        private var hasApplied = false
        private var requestedItemIdentifiers: [Item] = []
        private var currentItemIdentifiers: [Item] = []
        private var nativeOrderMatches = true
        private var contentRevision: UInt64 = 0
        private(set) var snapshotApplicationCount = 0
        private var prefetchedArtwork: [IndexPath: Task<Void, Never>] = [:]
        private struct VisibleArtwork {
            let identity: String
            let task: Task<Void, Never>?
            let prefetch: Task<Void, Never>?

            func cancel() {
                task?.cancel()
                prefetch?.cancel()
            }
        }
        private var visibleArtwork: [ObjectIdentifier: VisibleArtwork] = [:]

        func trailingActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            guard case .track(let id) = dataSource?.itemIdentifier(for: indexPath),
                  entriesByID[id] != nil else { return nil }
            let action = UIContextualAction(style: .destructive, title: nil) { [weak self] _, _, completion in
                guard let self, let entry = self.entriesByID[id], let latest = self.latest else {
                    completion(false); return
                }
                latest.player.removeFromQueue(at: entry.queueIndex)
                completion(true)
            }
            action.image = UIImage(systemName: "minus.circle.fill")
            action.accessibilityLabel = "从继续播放列表删除"
            action.image?.accessibilityLabel = "从继续播放列表删除"
            action.backgroundColor = .systemRed
            return UISwipeActionsConfiguration(actions: [action])
        }

        func attach(to collectionView: EdgeFadedCollectionView, initial: NowPlayingQueueList) {
            latest = initial
            self.collectionView = collectionView
            collapseFeedback = UIImpactFeedbackGenerator(style: .soft, view: collectionView)
            let registration = UICollectionView.CellRegistration<EdgeFadedListCell, Item> {
                [weak self] cell, _, item in
                cell.edgeFadeCollectionView = self?.collectionView
                self?.configure(cell, item: item)
            }
            let dataSource = UICollectionViewDiffableDataSource<Section, Item>(
                collectionView: collectionView
            ) { collectionView, indexPath, item in
                collectionView.dequeueConfiguredReusableCell(
                    using: registration,
                    for: indexPath,
                    item: item
                )
            }
            let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
                elementKind: UICollectionView.elementKindSectionHeader
            ) { [weak self] header, _, _ in
                self?.configureHeader(header)
            }
            dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
                collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
            }
            dataSource.reorderingHandlers.canReorderItem = { item in
                if case .track = item { true } else { false }
            }
            dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
                self?.didReorder(transaction)
            }
            self.dataSource = dataSource
            update(with: initial)
        }

        @discardableResult
        func update(with list: NowPlayingQueueList, nativeOrder: [Item]? = nil) -> Bool {
            let interval = list.services?.diagnostics?.begin("QueueUpdate")
            defer { interval?() }
            guard let dataSource else { return false }
            let previousList = latest
            latest = list
            let trackChanged = hasApplied && !list.trackTransitionKey.isEmpty
                && previousList?.trackTransitionKey != list.trackTransitionKey
            let entriesChanged = !hasApplied || previousList?.version != list.version
            let insetChanged = previousList?.horizontalInset != list.horizontalInset
            let headerChanged = previousList?.headerHeight != list.headerHeight
            var refreshed = false
            if (previousList?.subtitle != list.subtitle || insetChanged), let header = collectionView?.queueHeader {
                configureHeader(header)
                refreshed = true
            }
            let becameActive = list.visualsActive && previousList?.visualsActive == false
            let servicesChanged = previousList?.services !== list.services
            if !list.visualsActive || servicesChanged { cancelArtworkRequests() }
            if !hasApplied || previousList?.visualsActive != list.visualsActive {
                collectionView?.prefetchDataSource = list.visualsActive ? self : nil
            }
            let dependenciesChanged = previousList.map {
                $0.player !== list.player || $0.actions !== list.actions
            } ?? false
            defer {
                if trackChanged, let collectionView {
                    let topY = -collectionView.adjustedContentInset.top
                    if abs(collectionView.contentOffset.y - topY) > 0.5 {
                        collectionView.setContentOffset(CGPoint(x: 0, y: topY), animated: false)
                    }
                    list.onScroll(0)
                }
                if becameActive || entriesChanged || trackChanged || servicesChanged { requestVisibleArtwork() }
            }
            if let nativeOrder {
                currentItemIdentifiers = nativeOrder
                nativeOrderMatches = nativeOrder == requestedItemIdentifiers
            }
            guard entriesChanged || !nativeOrderMatches || insetChanged || headerChanged
                    || dependenciesChanged else { return refreshed }
            contentRevision &+= 1

            var changedItems: Set<Item> = []
            if entriesChanged {
                let previousEntries = entriesByID
                entriesByID = Dictionary(list.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                requestedItemIdentifiers = [.spacer]
                    + (list.entries.isEmpty ? [.empty] : list.entries.map { .track($0.id) })
                nativeOrderMatches = currentItemIdentifiers == requestedItemIdentifiers
                changedItems = Set(list.entries.compactMap { entry in
                    previousEntries[entry.id].map { $0.artworkIdentity != entry.artworkIdentity || $0.song != entry.song } == true ? .track(entry.id) : nil
                })
            }
            if headerChanged || insetChanged { changedItems.insert(.spacer) }
            if insetChanged { changedItems.insert(.empty) }

            if !hasApplied || !nativeOrderMatches {
                cancelPrefetches()
                var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
                snapshot.appendSections([.header, .queue])
                snapshot.appendItems([.spacer], toSection: .header)
                snapshot.appendItems(Array(requestedItemIdentifiers.dropFirst()), toSection: .queue)
                snapshot.reconfigureItems(requestedItemIdentifiers.filter(changedItems.contains))
                list.services?.diagnostics?.event("QueueSnapshot")
                snapshotApplicationCount += 1
                dataSource.apply(snapshot, animatingDifferences: hasApplied)
                currentItemIdentifiers = requestedItemIdentifiers
                nativeOrderMatches = true
                hasApplied = true
                return true
            }

            if let collectionView {
                UIView.performWithoutAnimation {
                    for indexPath in collectionView.indexPathsForVisibleItems {
                        guard let item = dataSource.itemIdentifier(for: indexPath),
                              let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell else { continue }
                        let refreshTrack: Bool
                        if case .track = item {
                            refreshTrack = dependenciesChanged || insetChanged
                        } else { refreshTrack = false }
                        if changedItems.contains(item) || refreshTrack {
                            configure(cell, item: item)
                            refreshed = true
                        }
                    }
                }
            }
            return refreshed
        }

        func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                            forItemAt indexPath: IndexPath) {
            guard let cell = cell as? UICollectionViewListCell,
                  let item = dataSource?.itemIdentifier(for: indexPath) else { return }
            requestVisibleArtwork(for: cell, item: item, at: indexPath)
            if let prepared = cell as? EdgeFadedListCell,
               prepared.contentRevision == contentRevision { return }
            configure(cell, item: item)
        }

        private func requestVisibleArtwork() {
            guard latest?.visualsActive == true, let collectionView, let dataSource else { return }
            for indexPath in collectionView.indexPathsForVisibleItems {
                guard let item = dataSource.itemIdentifier(for: indexPath),
                      let cell = collectionView.cellForItem(at: indexPath) else { continue }
                requestVisibleArtwork(for: cell, item: item, at: indexPath)
            }
        }

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            guard let latest, latest.visualsActive, let dataSource else { return }
            for indexPath in indexPaths where prefetchedArtwork[indexPath] == nil {
                guard let item = dataSource.itemIdentifier(for: indexPath),
                      let identity = artworkIdentity(for: item) else { continue }
                prefetchedArtwork[indexPath] = latest.services?.artwork.prepareQueue(identity, foreground: false)
            }
        }

        func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            for indexPath in indexPaths { prefetchedArtwork.removeValue(forKey: indexPath)?.cancel() }
        }

        func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                            forItemAt indexPath: IndexPath) {
            visibleArtwork.removeValue(forKey: ObjectIdentifier(cell))?.cancel()
        }

        private func requestVisibleArtwork(for cell: UICollectionViewCell, item: Item, at indexPath: IndexPath) {
            guard let latest, latest.visualsActive else { return }
            let cellID = ObjectIdentifier(cell)
            let identity = artworkIdentity(for: item)
            guard visibleArtwork[cellID]?.identity != identity else { return }
            visibleArtwork.removeValue(forKey: cellID)?.cancel()
            if let identity {
                let task = latest.services?.artwork.prepareQueue(identity, foreground: true)
                let prefetch = prefetchedArtwork.removeValue(forKey: indexPath)
                visibleArtwork[cellID] = VisibleArtwork(identity: identity, task: task, prefetch: prefetch)
            }
        }

        private func artworkIdentity(for item: Item) -> String? {
            guard case .track(let id) = item else { return nil }
            return entriesByID[id]?.song.artworkLoadID
        }

        private func cancelPrefetches() {
            for task in prefetchedArtwork.values { task.cancel() }
            prefetchedArtwork.removeAll()
        }

        func cancelArtworkRequests() {
            cancelPrefetches()
            for request in visibleArtwork.values { request.cancel() }
            visibleArtwork.removeAll()
        }

        private func configureHeader(_ header: UICollectionViewListCell) {
            guard let latest else { return }
            header.backgroundConfiguration = .clear()
            header.contentConfiguration = UIHostingConfiguration {
                VStack(alignment: .leading, spacing: 0) {
                    Text("继续播放")
                        .font(.headline.bold())
                        .nowPlayingPrimary()
                        .accessibilityAddTraits(.isHeader)
                    NowPlayingVibrantLabel(text: latest.subtitle, fontSize: 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .margins(.horizontal, latest.horizontalInset)
            .margins(.top, 8)
            .margins(.bottom, 12)
            .minSize(height: 0)
        }

        func configure(_ cell: UICollectionViewListCell, item: Item) {
            guard let latest else { return }
            let inset = latest.horizontalInset

            cell.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: 0, leading: 0, bottom: 0, trailing: inset + 1.5
            )
            cell.configurationUpdateHandler = nil
            if case .track = item {
                var background = cell.defaultBackgroundConfiguration()
                background.backgroundColor = .clear
                cell.backgroundConfiguration = background
            } else {
                if !cell.accessories.isEmpty { cell.accessories = [] }
                cell.backgroundConfiguration = .clear()
            }

            switch item {
            case .spacer:
                let height = latest.headerHeight
                cell.contentConfiguration = UIHostingConfiguration {
                    Color.clear.frame(height: height)
                        .listRowSeparator(.hidden)
                }
                .margins(.all, 0)
                .minSize(height: 0)

            case .empty:
                cell.contentConfiguration = UIHostingConfiguration {
                    ContentUnavailableView(
                        "后面没有要播放的曲目了",
                        systemImage: "list.bullet"
                    )
                    .foregroundStyle(.white)
                    .listRowSeparator(.hidden)
                    .frame(maxWidth: .infinity)
                }
                .margins(.horizontal, inset)
                .margins(.vertical, 24)
                .minSize(height: 0)

            case .track(let id):
                guard let entry = entriesByID[id] else { return }
                cell.contentConfiguration = UIHostingConfiguration {
                    NowPlayingQueueRow(entry: entry) { [weak self] in
                        guard let self, let index = self.entriesByID[id]?.queueIndex else { return }
                        self.latest?.onPlay(index)
                    }
                    .environment(latest.player)
                    .environment(latest.actions)
                    .environment(latest.services)
                    .listRowSeparator(.hidden)
                }
                .margins(.leading, inset)
                .margins(.trailing, 0)
                .margins(.vertical, 4)
                .minSize(height: 0)
                if cell.accessories.count != 1 || cell.accessories.first?.accessoryType != .reorder {
                    cell.accessories = [
                        .reorder(displayed: .always,
                                 options: .init(tintColor: UIColor.white.withAlphaComponent(NowPlayingVisualHierarchy.queueReorderTintAlpha)))
                    ]
                }
            }
            (cell as? EdgeFadedListCell)?.contentRevision = contentRevision
        }

        private func didReorder(
            _ transaction: NSDiffableDataSourceTransaction<Section, Item>
        ) {
            cancelPrefetches()
            currentItemIdentifiers = transaction.finalSnapshot.itemIdentifiers
            nativeOrderMatches = currentItemIdentifiers == requestedItemIdentifiers
            guard let section = transaction.sectionTransactions.first(where: { $0.sectionIdentifier == .queue }) else { return }
            for change in section.difference.inferringMoves() {
                guard case let .remove(source, _, associatedWith?) = change else { continue }
                latest?.onMove(IndexSet(integer: source), associatedWith > source ? associatedWith + 1 : associatedWith)
                return
            }
        }


        func collectionView(
            _ collectionView: UICollectionView,
            targetIndexPathForMoveOfItemAt originalIndexPath: IndexPath,
            toProposedIndexPath proposedIndexPath: IndexPath
        ) -> IndexPath {
            clampedMoveTarget(from: originalIndexPath, to: proposedIndexPath)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            targetIndexPathForMoveFromItemAt originalIndexPath: IndexPath,
            toProposedIndexPath proposedIndexPath: IndexPath
        ) -> IndexPath {
            clampedMoveTarget(from: originalIndexPath, to: proposedIndexPath)
        }

        private func clampedMoveTarget(from original: IndexPath, to proposed: IndexPath) -> IndexPath {
            guard proposed.section == original.section else {
                return IndexPath(item: proposed.section < original.section ? 0 : max(original.item, 0), section: original.section)
            }
            return proposed
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let latest else { return }
            let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            let headerOffset = min(max(offset, 0), latest.headerHeight)
            if scrollView.isDragging, let previousOffset = pendingCollapseFeedbackOffset {
                pendingCollapseFeedbackOffset = headerOffset
                if headerOffset > previousOffset, maximumScrollOffset(in: scrollView) >= latest.headerHeight {
                    pendingCollapseFeedbackOffset = nil
                    if let collapseFeedbackHandler {
                        collapseFeedbackHandler()
                    } else {
                        collapseFeedback?.impactOccurred()
                    }
                }
            }
            latest.onScroll(headerOffset)
        }

        private var collapseFeedback: UIImpactFeedbackGenerator?
        var collapseFeedbackHandler: (() -> Void)?
        private var pendingCollapseFeedbackOffset: CGFloat?

        private func maximumScrollOffset(in scrollView: UIScrollView) -> CGFloat {
            scrollView.contentSize.height + scrollView.adjustedContentInset.bottom
                - scrollView.bounds.height + scrollView.adjustedContentInset.top
        }

        func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            pendingCollapseFeedbackOffset = nil
            guard let headerHeight = latest?.headerHeight, headerHeight > 0 else { return }
            let top = -scrollView.adjustedContentInset.top
            let target = targetContentOffset.pointee.y - top
            let offset = scrollView.contentOffset.y - top
            // Scroll velocity follows contentOffset; pan translation follows the finger.
            let fingerTranslation = scrollView.panGestureRecognizer.translation(in: scrollView).y
            let isScrollingDown = velocity.y > 0 || (velocity.y == 0 && fingerTranslation < 0)
            let isScrollingUp = velocity.y < 0 || (velocity.y == 0 && fingerTranslation > 0)
            let maxOffset = maximumScrollOffset(in: scrollView)

            if isScrollingDown, offset >= 0, offset < headerHeight, maxOffset >= headerHeight {
                if target < headerHeight {
                    targetContentOffset.pointee.y = top + headerHeight
                }
                return
            }
            if isScrollingUp, offset > 0, min(offset, target) <= headerHeight {
                targetContentOffset.pointee.y = top
                return
            }

            guard target > 0, target < headerHeight else { return }
            let hidesHeader = target >= headerHeight / 2 && maxOffset >= headerHeight
            targetContentOffset.pointee.y = top + (hidesHeader ? headerHeight : 0)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            guard let latest else { return }
            let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            pendingCollapseFeedbackOffset = min(max(offset, 0), latest.headerHeight)
            collapseFeedback?.prepare()
        }
    }
}
