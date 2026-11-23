import SwiftUI
import UIKit

struct NowPlayingQueueList: UIViewRepresentable {
    static let modeControlsHeight: CGFloat = 44
    static let topFadeHeight: CGFloat = 6
    static let bottomFadeHeight: CGFloat = 80
    static let historyRowHeight: CGFloat = 56
    static let historyHeaderHeight: CGFloat = 44
    private static let historyBottomInset: CGFloat = 12
    @Environment(PlayerActions.self) private var actions
    @Environment(PlayerState.self) private var player
    @Environment(\.playerVisualsActive) private var visualsActive
    @Environment(PlayerServices.self) private var services: PlayerServices?
    let entries: [PlayerQueueEntry]
    let version: PlayerQueueVersion
    var history: [PlayerHistoryEntry] = []
    var trackTransitionKey: String = ""
    var subtitle: String = "接下来播放的歌曲"
    var songHeader: NowPlayingQueueSongHeader
    var onImportLyrics: (() -> Void)? = nil
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
        let layout = UICollectionViewCompositionalLayout { [weak coordinator = context.coordinator] section, environment in
            let identifier = coordinator?.dataSource?.sectionIdentifier(for: section)
            if identifier == .history {
                let rowSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                     heightDimension: .absolute(Self.historyRowHeight))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: rowSize,
                    subitems: [NSCollectionLayoutItem(layoutSize: rowSize)])
                let history = NSCollectionLayoutSection(group: group)
                history.contentInsets.bottom = Self.historyBottomInset
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(widthDimension: .fractionalWidth(1),
                                      heightDimension: .absolute(Self.historyHeaderHeight)),
                    elementKind: UICollectionView.elementKindSectionHeader,
                    alignment: .top
                )
                header.pinToVisibleBounds = true
                header.zIndex = 2
                history.boundarySupplementaryItems = [header]
                return history
            }
            if identifier == .header {
                let headerHeight = max(coordinator?.latest?.headerHeight ?? NowPlayingQueuePage.songHeaderHeight, 1)
                let rowSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                     heightDimension: .absolute(headerHeight))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: rowSize,
                    subitems: [NSCollectionLayoutItem(layoutSize: rowSize)])
                return NSCollectionLayoutSection(group: group)
            }
            let listSection = NSCollectionLayoutSection.list(
                using: identifier == .queue ? queueConfiguration : configuration,
                layoutEnvironment: environment
            )
            if identifier == .queue {
                let queueHeader = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(widthDimension: .fractionalWidth(1),
                                      heightDimension: .estimated(100)),
                    elementKind: UICollectionView.elementKindSectionHeader,
                    alignment: .top
                )
                queueHeader.pinToVisibleBounds = true
                queueHeader.zIndex = 2
                listSection.boundarySupplementaryItems = [queueHeader]
            }
            return listSection
        }

        let collectionView = EdgeFadedCollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.alwaysBounceVertical = true
        collectionView.panGestureRecognizer.name = PlayerInteraction.queueScrollGestureName
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset.bottom = Self.bottomFadeHeight
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
        var isAnimatingTrackTransition = false
        var transitionGeneration: UInt64 = 0

        override func prepareForReuse() {
            super.prepareForReuse()
            isAnimatingTrackTransition = false
            transitionGeneration &+= 1
            transform = .identity
            alpha = 1
            contentView.transform = .identity
            contentView.alpha = 1
            contentRevision = nil
            edgeFadeCollectionView?.clearEdgeMasks(for: self)
        }

        override func layoutSublayers(of layer: CALayer) {
            super.layoutSublayers(of: layer)
            if layer === self.layer, !isAnimatingTrackTransition {
                edgeFadeCollectionView?.updateEdgeMask(for: self)
            }
        }
    }

    @objc(NeoMusicEdgeFadedCollectionView)
    final class EdgeFadedCollectionView: UICollectionView {
        var queueHeader: UICollectionViewListCell? { header(in: .queue) }
        var historyHeader: UICollectionViewListCell? { header(in: .history) }
        var historyHeight: CGFloat = 0
        var songHeaderHeight: CGFloat = 0
        var queueRestOffset: CGFloat { historyHeight - adjustedContentInset.top }

        private func header(in section: Coordinator.Section) -> UICollectionViewListCell? {
            guard let source = dataSource as? UICollectionViewDiffableDataSource<Coordinator.Section, Coordinator.Item>,
                  let index = source.index(for: section) else { return nil }
            return supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader,
                              at: IndexPath(item: 0, section: index))
                as? UICollectionViewListCell
        }

        private func section(for cell: UICollectionViewCell) -> Coordinator.Section? {
            guard let source = dataSource as? UICollectionViewDiffableDataSource<Coordinator.Section, Coordinator.Item>,
                  let indexPath = indexPath(for: cell) else { return nil }
            return source.sectionIdentifier(for: indexPath.section)
        }

        private let maskedCells = NSHashTable<UICollectionViewCell>.weakObjects()
        private var isUpdatingEdgeMasks = false

        override func layoutSubviews() {
            super.layoutSubviews()
            // Give even an empty queue enough room for its header to pin above the empty state.
            let spaceToPinQueueHeader = bounds.height + queueRestOffset + songHeaderHeight - contentSize.height
            let bottom = max(NowPlayingQueueList.bottomFadeHeight, spaceToPinQueueHeader)
            if contentInset.bottom != bottom { contentInset.bottom = bottom }
            let insets = UIEdgeInsets(
                top: max(0, topFadeStart(inHistory: bounds.minY < queueRestOffset) - bounds.minY)
                    + NowPlayingQueueList.topFadeHeight,
                left: 0, bottom: NowPlayingQueueList.bottomFadeHeight, right: 0
            )
            if verticalScrollIndicatorInsets != insets { verticalScrollIndicatorInsets = insets }
            updateEdgeMasks()
        }

        func updateEdgeMasks() {
            guard !isUpdatingEdgeMasks, bounds.height > 0 else { return }
            isUpdatingEdgeMasks = true
            defer { isUpdatingEdgeMasks = false }

            let queueMetrics = rowFadeMetrics(inHistory: false)
            let historyMetrics = historyHeight > 0 ? rowFadeMetrics(inHistory: true) : queueMetrics
            let viewportMetrics = viewportFadeMetrics()
            for cell in visibleCells {
                if (cell as? EdgeFadedListCell)?.isAnimatingTrackTransition == true { continue }
                let metrics = edgeFadeMetrics(for: cell, historyMetrics: historyMetrics,
                                              viewportMetrics: viewportMetrics, queueMetrics: queueMetrics)
                applyEdgeMask(to: cell, metrics: metrics)
            }
            if let queueHeader {
                applyEdgeMask(to: queueHeader, metrics: edgeFadeMetrics(top: bounds.minY, topFadeHeight: 0))
            }
        }

        func updateEdgeMask(for cell: UICollectionViewCell) {
            guard !isUpdatingEdgeMasks, bounds.height > 0, cell.superview != nil else { return }
            if (cell as? EdgeFadedListCell)?.isAnimatingTrackTransition == true { return }
            isUpdatingEdgeMasks = true
            defer { isUpdatingEdgeMasks = false }
            let queueMetrics = rowFadeMetrics(inHistory: false)
            let historyMetrics = historyHeight > 0 ? rowFadeMetrics(inHistory: true) : queueMetrics
            let viewportMetrics = viewportFadeMetrics()
            let metrics = edgeFadeMetrics(for: cell, historyMetrics: historyMetrics,
                                          viewportMetrics: viewportMetrics, queueMetrics: queueMetrics)
            applyEdgeMask(to: cell, metrics: metrics)
        }

        private func edgeFadeMetrics(
            for cell: UICollectionViewCell,
            historyMetrics: EdgeFadeMetrics,
            viewportMetrics: EdgeFadeMetrics,
            queueMetrics: EdgeFadeMetrics
        ) -> EdgeFadeMetrics {
            switch section(for: cell) {
            case .history:
                return historyMetrics
            case .header:
                return viewportMetrics
            case .queue:
                return queueMetrics
            case nil:
                let y = convert(cell.bounds, from: cell).minY
                if y < historyHeight {
                    return historyMetrics
                } else if y < historyHeight + songHeaderHeight {
                    return viewportMetrics
                } else {
                    return queueMetrics
                }
            }
        }

        fileprivate func prepareTransitionEdgeMask(for cell: UICollectionViewCell, deltaY: CGFloat) {
            guard bounds.height > 0, cell.superview != nil else { return }
            let queueMetrics = rowFadeMetrics(inHistory: false)
            let historyMetrics = historyHeight > 0 ? rowFadeMetrics(inHistory: true) : queueMetrics
            let viewportMetrics = viewportFadeMetrics()
            let metrics = edgeFadeMetrics(for: cell, historyMetrics: historyMetrics,
                                          viewportMetrics: viewportMetrics, queueMetrics: queueMetrics)
            // cell.transform is currently translation(0, deltaY); its final frame at t=1 is shifted by -deltaY.
            let currentFrame = convert(cell.bounds, from: cell)
            let sweepMinY = min(currentFrame.minY, currentFrame.minY - deltaY)
            let sweepMaxY = max(currentFrame.maxY, currentFrame.maxY - deltaY)
            let touchesFadeZone = sweepMinY < metrics.fadeTopEnd || sweepMaxY > metrics.fadeBottomStart
            applyEdgeMask(to: cell, metrics: metrics, forceMask: touchesFadeZone)
        }

        fileprivate func animateTransitionEdgeMask(for cell: UICollectionViewCell, matching spring: CABasicAnimation?) {
            guard bounds.height > 0, cell.superview != nil, maskedCells.contains(cell) else { return }
            let queueMetrics = rowFadeMetrics(inHistory: false)
            let historyMetrics = historyHeight > 0 ? rowFadeMetrics(inHistory: true) : queueMetrics
            let viewportMetrics = viewportFadeMetrics()
            let metrics = edgeFadeMetrics(for: cell, historyMetrics: historyMetrics,
                                          viewportMetrics: viewportMetrics, queueMetrics: queueMetrics)
            var targets: [CALayer] = []
            collectEdgeMaskTargets(in: cell.layer, targets: &targets)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for target in targets {
                let oldPosition = (target.mask as? QueueEdgeMaskLayer)?.position
                setEdgeMask(on: target, metrics: metrics)
                if let spring, let oldPosition, let maskLayer = target.mask as? QueueEdgeMaskLayer,
                   let maskAnimation = spring.copy() as? CABasicAnimation {
                    maskAnimation.isAdditive = false
                    maskAnimation.valueFunction = nil
                    maskAnimation.keyPath = "position"
                    maskAnimation.fromValue = NSValue(cgPoint: oldPosition)
                    maskAnimation.toValue = NSValue(cgPoint: maskLayer.position)
                    maskLayer.add(maskAnimation, forKey: "trackTransitionMask")
                }
            }
            CATransaction.commit()
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

        private func topFadeStart(inHistory: Bool) -> CGFloat {
            if let header = inHistory ? historyHeader : queueHeader {
                return convert(header.bounds, from: header).maxY
            }
            return bounds.minY + adjustedContentInset.top
        }

        private func rowFadeMetrics(inHistory: Bool) -> EdgeFadeMetrics {
            if inHistory, historyHeight > 0 {
                let bottomEnd = min(bounds.maxY, historyHeight)
                let bottomStart = min(
                    bounds.maxY - NowPlayingQueueList.bottomFadeHeight,
                    historyHeight - NowPlayingQueueList.historyBottomInset
                )
                return edgeFadeMetrics(
                    top: topFadeStart(inHistory: true),
                    topFadeHeight: NowPlayingQueueList.topFadeHeight,
                    bottomEnd: bottomEnd,
                    bottomFadeHeight: max(0, bottomEnd - bottomStart)
                )
            }
            return edgeFadeMetrics(top: topFadeStart(inHistory: false), topFadeHeight: NowPlayingQueueList.topFadeHeight)
        }

        private func viewportFadeMetrics() -> EdgeFadeMetrics {
            let scrolledPastSongHeader = max(0, bounds.minY - queueRestOffset)
            return edgeFadeMetrics(top: bounds.minY, topFadeHeight: min(24, scrolledPastSongHeader))
        }

        private func edgeFadeMetrics(
            top fadeTop: CGFloat,
            topFadeHeight: CGFloat,
            bottomEnd: CGFloat? = nil,
            bottomFadeHeight: CGFloat = NowPlayingQueueList.bottomFadeHeight
        ) -> EdgeFadeMetrics {
            let fadeTopEnd = fadeTop + topFadeHeight
            let fadeBottomEnd = bottomEnd ?? bounds.maxY
            let fadeBottomStart = fadeBottomEnd - bottomFadeHeight
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

        private func applyEdgeMask(to cell: UICollectionViewCell, metrics: EdgeFadeMetrics, forceMask: Bool = false) {
            let cellFrame = convert(cell.bounds, from: cell)
            if !forceMask, cellFrame.minY >= metrics.fadeTopEnd && cellFrame.maxY <= metrics.fadeBottomStart {
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
            let targetFrame = bounds.insetBy(dx: -overflow, dy: 0)
            guard collectionView.frame != targetFrame else { return }
            let hadZeroHeight = collectionView.bounds.height == 0 && targetFrame.height > 0
            let queueOffset = (collectionView as? EdgeFadedCollectionView).map {
                $0.contentOffset.y - $0.queueRestOffset
            } ?? 0
            collectionView.frame = targetFrame
            if hadZeroHeight, let faded = collectionView as? EdgeFadedCollectionView, faded.historyHeight > 0 {
                faded.layoutIfNeeded()
                let targetY = faded.queueRestOffset + max(0, queueOffset)
                if abs(faded.contentOffset.y - targetY) > 0.5 {
                    faded.setContentOffset(CGPoint(x: faded.contentOffset.x, y: targetY), animated: false)
                }
            }
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            collectionView.frame.contains(point)
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let hit = super.hitTest(point, with: event) else { return nil }
            // Keep the side margins available to the enclosing player pan.
            return bounds.contains(point) ? hit : self
        }
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
        nonisolated enum Section: Hashable, Sendable { case history, header, queue }
        nonisolated enum Item: Hashable, Sendable {
            case songHeader
            case empty
            case track(PlayerQueueEntry.ID)
            case history(PlayerHistoryEntry.ID)
        }

        private(set) var latest: NowPlayingQueueList?
        private var entriesByID: [PlayerQueueEntry.ID: PlayerQueueEntry] = [:]
        private var historyByID: [PlayerHistoryEntry.ID: PlayerHistoryEntry] = [:]
        private var displayedHistory: [PlayerHistoryEntry] = []
        private var isReturningAfterHistoryClear = false
        private(set) var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
        private weak var collectionView: EdgeFadedCollectionView?
        private var hasApplied = false
        private var requestedItemIdentifiers: [Item] = []
        private var currentItemIdentifiers: [Item] = []
        private var nativeOrderMatches = true
        private var snapshotTargetOffset: CGFloat?
        private var pendingReturnToQueueFromHistory = false
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
            scrollFeedback = UIImpactFeedbackGenerator(style: .soft, view: collectionView)
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
            ) { [weak self] header, _, indexPath in
                if self?.dataSource?.sectionIdentifier(for: indexPath.section) == .history {
                    self?.configureHistoryHeader(header)
                } else {
                    self?.configureHeader(header)
                }
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
            if !list.visualsActive || previousList?.player !== list.player
                || (isReturningAfterHistoryClear && (!list.history.isEmpty || collectionView?.isScrollAnimating != true)) {
                isReturningAfterHistoryClear = false
            }
            let previousHistory = displayedHistory
            let history = isReturningAfterHistoryClear ? previousHistory : list.history
            collectionView?.songHeaderHeight = list.headerHeight
            let trackChanged = hasApplied && !list.trackTransitionKey.isEmpty
                && previousList?.trackTransitionKey != list.trackTransitionKey
            let sameSong = previousList?.songHeader.song.id == list.songHeader.song.id
            let returnsToQueue = pendingReturnToQueueFromHistory
            pendingReturnToQueueFromHistory = false
            let entriesChanged = !hasApplied || previousList?.version != list.version
            let historyChanged = previousHistory != history
            let historyOrderChanged = hasApplied
                ? historyChanged && previousHistory.map(\.id) != history.map(\.id)
                : !history.isEmpty
            let previousContentOffset = collectionView?.contentOffset.y ?? 0
            let previousQueueOffset = previousContentOffset - (collectionView?.queueRestOffset ?? 0)
            let staysInHistory = hasApplied && !previousHistory.isEmpty
                && previousQueueOffset < -HistoryStops.restTolerance && !history.isEmpty && !returnsToQueue
            let browsingDeepInQueue = previousQueueOffset >= list.headerHeight - HistoryStops.restTolerance
                || collectionView?.isTracking == true || collectionView?.isDecelerating == true
                || collectionView?.hasActiveDrag == true
            let targetQueueOffset = (trackChanged && !browsingDeepInQueue && !sameSong) ? 0 : max(0, previousQueueOffset)
            let insetChanged = previousList?.horizontalInset != list.horizontalInset
            let headerHeightChanged = hasApplied && previousList?.headerHeight != list.headerHeight
            let headerChanged = previousList?.songHeader != list.songHeader
                || headerHeightChanged
                || (previousList?.onImportLyrics == nil) != (list.onImportLyrics == nil)
            if headerHeightChanged {
                collectionView?.collectionViewLayout.invalidateLayout()
            }
            var refreshed = false
            if (previousList?.subtitle != list.subtitle || insetChanged || previousList?.player !== list.player),
               let header = collectionView?.queueHeader {
                configureHeader(header)
                refreshed = true
            }
            let visualsChanged = previousList?.visualsActive != list.visualsActive
            let becameActive = list.visualsActive && previousList?.visualsActive == false
            let servicesChanged = previousList?.services !== list.services
            if !list.visualsActive || servicesChanged { cancelArtworkRequests() }
            if !hasApplied || visualsChanged {
                collectionView?.prefetchDataSource = list.visualsActive ? self : nil
            }
            let dependenciesChanged = previousList.map {
                $0.player !== list.player || $0.actions !== list.actions
            } ?? false
            if insetChanged, let header = collectionView?.historyHeader {
                configureHistoryHeader(header)
            }
            defer {
                if (returnsToQueue || trackChanged || historyOrderChanged), let collectionView {
                    if returnsToQueue {
                        animateReturnToQueue(in: collectionView, reason: "playFromHistory")
                    } else if staysInHistory, let target = snapshotTargetOffset {
                        collectionView.layoutIfNeeded()
                        if abs(collectionView.contentOffset.y - target) > 0.5 {
                            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: false)
                        }
                    } else if !staysInHistory && !isReturningAfterHistoryClear {
                        if historyOrderChanged { collectionView.layoutIfNeeded() }
                        let reason = trackChanged ? "trackChanged" : "historyOrderChanged"
                        setQueueOffset(targetQueueOffset, in: collectionView, reason: reason)
                    }
                    scrollViewDidScroll(collectionView)
                }
                if becameActive || entriesChanged || historyChanged || trackChanged || servicesChanged { requestVisibleArtwork() }
            }
            if let nativeOrder {
                currentItemIdentifiers = nativeOrder
                nativeOrderMatches = nativeOrder == requestedItemIdentifiers
            }
            guard entriesChanged || historyChanged || !nativeOrderMatches || insetChanged || headerChanged
                    || dependenciesChanged || servicesChanged || visualsChanged else { return refreshed }
            contentRevision &+= 1

            var changedItems: Set<Item> = []
            if entriesChanged {
                let previousEntries = entriesByID
                entriesByID = Dictionary(list.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                changedItems = Set(list.entries.compactMap { entry in
                    previousEntries[entry.id].map { $0.artworkIdentity != entry.artworkIdentity || $0.song != entry.song } == true ? .track(entry.id) : nil
                })
            }
            if historyChanged || !hasApplied {
                let previousHistory = historyByID
                displayedHistory = history
                historyByID = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) })
                changedItems.formUnion(history.compactMap { entry in
                    guard let previous = previousHistory[entry.id], previous != entry else { return nil }
                    return .history(entry.id)
                })
            }
            if entriesChanged || historyOrderChanged {
                requestedItemIdentifiers = history.map { .history($0.id) } + [.songHeader]
                    + (list.entries.isEmpty ? [.empty] : list.entries.map { .track($0.id) })
                nativeOrderMatches = currentItemIdentifiers == requestedItemIdentifiers
            }
            if headerChanged || insetChanged || dependenciesChanged || servicesChanged { changedItems.insert(.songHeader) }
            if insetChanged { changedItems.insert(.empty) }

            if !hasApplied || !nativeOrderMatches {
                cancelPrefetches()
                let previousHistoryStop = collectionView.flatMap { historyStops(in: $0)?.rest }
                let previousHistoryIDs = previousHistory.map(\.id)
                let historyIDs = history.map(\.id)
                let historyAppendedCount = (history.count > previousHistory.count
                    && Array(historyIDs.prefix(previousHistory.count)) == previousHistoryIDs)
                    ? (history.count - previousHistory.count) : 0
                let historyPoppedCount = (previousHistory.count > history.count
                    && Array(previousHistoryIDs.prefix(history.count)) == historyIDs)
                    ? (previousHistory.count - history.count) : 0
                let previousEntryIDs = previousList?.entries.map(\.id) ?? []
                let entryIDs = list.entries.map(\.id)
                let queueStep: Int = if trackChanged {
                    if let firstNew = entryIDs.first, let step = previousEntryIDs.firstIndex(of: firstNew), step > 0 {
                        step
                    } else if let firstOld = previousEntryIDs.first, let step = entryIDs.firstIndex(of: firstOld), step > 0 {
                        -step
                    } else if previousEntryIDs.count == 1, entryIDs.isEmpty {
                        1
                    } else if previousEntryIDs.isEmpty, entryIDs.count == 1 {
                        -1
                    } else {
                        0
                    }
                } else {
                    0
                }
                var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
                if !history.isEmpty {
                    snapshot.appendSections([.history])
                    snapshot.appendItems(history.map { .history($0.id) }, toSection: .history)
                }
                collectionView?.historyHeight = history.isEmpty ? 0
                    : NowPlayingQueueList.historyHeaderHeight
                        + CGFloat(history.count) * NowPlayingQueueList.historyRowHeight
                        + NowPlayingQueueList.historyBottomInset
                snapshot.appendSections([.header, .queue])
                snapshot.appendItems([.songHeader], toSection: .header)
                snapshot.appendItems(list.entries.isEmpty ? [.empty] : list.entries.map { .track($0.id) }, toSection: .queue)
                snapshot.reconfigureItems(requestedItemIdentifiers.filter(changedItems.contains))
                list.services?.diagnostics?.event("QueueSnapshot")
                snapshotTargetOffset = nil
                let historySectionToggled = previousHistory.isEmpty != history.isEmpty
                let followsNewestHistory = staysInHistory
                    && previousHistoryStop != nil
                    && previousQueueOffset >= (previousHistoryStop ?? 0) - 0.5
                    && (historyAppendedCount > 0 || historyPoppedCount > 0)
                    && collectionView?.isTracking != true
                    && collectionView?.isDecelerating != true
                if staysInHistory, let collectionView {
                    // Keep older rows in place. When viewing the newest end, keep SongHeader anchored on screen.
                    snapshotTargetOffset = min(previousContentOffset, collectionView.queueRestOffset - 0.5)
                    if followsNewestHistory {
                        snapshotTargetOffset = max(
                            -collectionView.adjustedContentInset.top,
                            collectionView.queueRestOffset + previousQueueOffset
                        )
                    }
                } else if !staysInHistory, historyOrderChanged, !historySectionToggled, let collectionView {
                    snapshotTargetOffset = collectionView.queueRestOffset + targetQueueOffset
                }
                snapshotApplicationCount += 1
                let application = snapshotApplicationCount
                let animatesDifferences = hasApplied && !returnsToQueue && !isReturningAfterHistoryClear
                    && !historyOrderChanged && !trackChanged
                if animatesDifferences {
                    dataSource.apply(snapshot, animatingDifferences: true) { [weak self] in
                        guard let self, self.snapshotApplicationCount == application else { return }
                        self.snapshotTargetOffset = nil
                    }
                } else {
                    UIView.performWithoutAnimation {
                        dataSource.apply(snapshot, animatingDifferences: false)
                        if let collectionView, !returnsToQueue {
                            if staysInHistory, let target = snapshotTargetOffset {
                                collectionView.layoutIfNeeded()
                                if abs(collectionView.contentOffset.y - target) > 0.5 {
                                    collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: false)
                                }
                            } else if !staysInHistory && !isReturningAfterHistoryClear {
                                collectionView.layoutIfNeeded()
                                let reason = trackChanged ? "trackChanged" : "historyOrderChanged"
                                setQueueOffset(targetQueueOffset, in: collectionView, reason: reason)
                            }
                            collectionView.layoutIfNeeded()
                        }
                    }
                    self.snapshotTargetOffset = nil
                    if hasApplied, !returnsToQueue, !isReturningAfterHistoryClear, let collectionView {
                        let historySlideY: CGFloat = if followsNewestHistory {
                            if historyAppendedCount > 0 {
                                CGFloat(min(historyAppendedCount, 2)) * NowPlayingQueueList.historyRowHeight
                            } else if historyPoppedCount > 0 {
                                -CGFloat(min(historyPoppedCount, 2)) * NowPlayingQueueList.historyRowHeight
                            } else {
                                0
                            }
                        } else {
                            0
                        }
                        let queueSlideY = queueStep != 0
                            ? CGFloat(max(-2, min(2, queueStep))) * NowPlayingQueueList.historyRowHeight
                            : 0
                        let insertedHistoryIDs = (followsNewestHistory && historyAppendedCount > 0)
                            ? Set(history.suffix(historyAppendedCount).map(\.id))
                            : []
                        animateTrackTransitionRows(
                            in: collectionView,
                            insertedHistoryIDs: insertedHistoryIDs,
                            historySlideY: historySlideY,
                            queueSlideY: queueSlideY,
                            animateSongHeader: trackChanged && !sameSong
                        )
                    }
                }
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
                        let needsRefresh: Bool
                        switch item {
                        case .track, .history:
                            needsRefresh = dependenciesChanged || insetChanged
                        case .songHeader:
                            needsRefresh = visualsChanged
                        case .empty:
                            needsRefresh = false
                        }
                        if changedItems.contains(item) || needsRefresh {
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
            switch item {
            case .track(let id): entriesByID[id]?.song.artworkLoadID
            case .history(let id): historyByID[id]?.song.artworkLoadID
            case .songHeader, .empty: nil
            }
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
                VStack(alignment: .leading, spacing: 8) {
                    NowPlayingQueueModeControls()
                        .padding(.vertical, 3)
                        .frame(height: NowPlayingQueueList.modeControlsHeight)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("继续播放")
                            .font(.headline.bold())
                            .nowPlayingPrimary()
                            .accessibilityAddTraits(.isHeader)
                        NowPlayingVibrantLabel(text: latest.subtitle, fontSize: 13)
                    }
                }
                .environment(latest.player)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .margins(.horizontal, latest.horizontalInset)
            .margins(.top, 0)
            .margins(.bottom, 12)
            .minSize(height: 0)
        }

        private func configureHistoryHeader(_ header: UICollectionViewListCell) {
            guard let latest else { return }
            header.backgroundConfiguration = .clear()
            header.contentConfiguration = UIHostingConfiguration {
                HStack {
                    Text("历史记录")
                        .font(.headline.bold())
                        .nowPlayingPrimary()
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { [weak self] in
                        self?.confirmHistoryClear()
                    } label: {
                        NowPlayingVibrantLabel(text: "清除", fontSize: 17)
                            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .margins(.horizontal, latest.horizontalInset)
            .margins(.vertical, 0)
            .minSize(height: 0)
        }

        private func confirmHistoryClear() {
            guard let collectionView, collectionView.window != nil,
                  let player = latest?.player, !player.playbackHistory.isEmpty else { return }
            let presenter = sequence(first: collectionView as UIResponder, next: { $0.next })
                .compactMap { $0 as? UIViewController }.first
            guard let presenter, presenter.presentedViewController == nil else { return }

            let alert = UIAlertController(title: "清除播放历史？", message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "清除", style: .destructive) { [weak self] _ in
                if let self {
                    self.clearHistory(for: player)
                } else {
                    player.clearPlaybackHistory()
                }
            })
            presenter.present(alert, animated: true)
        }

        func clearHistory(for player: PlayerState) {
            guard let collectionView, latest?.player === player, !displayedHistory.isEmpty else {
                player.clearPlaybackHistory()
                return
            }
            // Removing the section would move Continue Playing before UIKit can scroll to it.
            isReturningAfterHistoryClear = true
            player.clearPlaybackHistory()
            animateReturnToQueue(in: collectionView, reason: "clearHistory")
            if !collectionView.isScrollAnimating { finishHistoryClear() }
        }

        private func finishHistoryClear() {
            guard isReturningAfterHistoryClear, var list = latest else { return }
            isReturningAfterHistoryClear = false
            list.history = list.player.playbackHistory
            update(with: list)
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
            case .songHeader:
                let importLyrics: (() -> Void)? = latest.onImportLyrics.map { _ in
                    { [weak self] in self?.latest?.onImportLyrics?() }
                }
                cell.contentConfiguration = UIHostingConfiguration {
                    NowPlayingSongHeader(
                        song: latest.songHeader.song,
                        artworkNamespace: latest.songHeader.artworkNamespace,
                        usesReferenceLayout: true,
                        usesArtworkTransition: false,
                        showsArtwork: latest.songHeader.showsArtwork,
                        artworkDecodeSize: latest.songHeader.artworkDecodeSize,
                        onImportLyrics: importLyrics
                    )
                    .frame(height: NowPlayingSongHeader.referenceHeight)
                    .padding(.top, NowPlayingQueuePage.songHeaderTopInset)
                    .frame(height: latest.headerHeight, alignment: .top)
                    .environment(latest.player)
                    .environment(latest.actions)
                    .environment(latest.services)
                    .environment(\.playerVisualsActive, latest.visualsActive)
                }
                .margins(.horizontal, inset)
                .margins(.vertical, 0)
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
                    NowPlayingQueueRow(song: { entry.song }) { [weak self] in
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

            case .history(let id):
                guard let entry = historyByID[id] else { return }
                cell.contentConfiguration = UIHostingConfiguration {
                    NowPlayingQueueRow(song: { entry.song }) { [weak self] in
                        self?.playFromHistory(id)
                    }
                    .environment(latest.player)
                    .environment(latest.actions)
                    .environment(latest.services)
                    .listRowSeparator(.hidden)
                }
                .margins(.horizontal, inset)
                .margins(.vertical, 4)
                .minSize(height: 0)
            }
            (cell as? EdgeFadedListCell)?.contentRevision = contentRevision
        }

        func playFromHistory(_ id: PlayerHistoryEntry.ID) {
            guard let latest, !isReturningAfterHistoryClear, historyByID[id] != nil else { return }
            let previousTrack = latest.player.currentTrackTransitionKey
            pendingReturnToQueueFromHistory = true
            latest.player.playFromHistory(id)
            // A stale history row can produce no playback update.
            if pendingReturnToQueueFromHistory, latest.player.currentTrackTransitionKey == previousTrack {
                pendingReturnToQueueFromHistory = false
                if let collectionView {
                    animateReturnToQueue(in: collectionView, reason: "playFromHistory")
                }
            }
        }

        private func animateTrackTransitionRows(
            in collectionView: EdgeFadedCollectionView,
            insertedHistoryIDs: Set<PlayerHistoryEntry.ID>,
            historySlideY: CGFloat,
            queueSlideY: CGFloat,
            animateSongHeader: Bool
        ) {
            guard historySlideY != 0 || queueSlideY != 0 || animateSongHeader, let dataSource else { return }

            var animatedRows: [(cell: EdgeFadedListCell, generation: UInt64)] = []
            var songHeaderCell: UICollectionViewCell?

            UIView.performWithoutAnimation {
                for indexPath in collectionView.indexPathsForVisibleItems {
                    guard let item = dataSource.itemIdentifier(for: indexPath),
                          let cell = collectionView.cellForItem(at: indexPath) else { continue }
                    switch item {
                    case .history(let id) where historySlideY != 0:
                        guard let listCell = cell as? EdgeFadedListCell else { continue }
                        listCell.layoutIfNeeded()
                        listCell.transitionGeneration &+= 1
                        listCell.isAnimatingTrackTransition = true
                        listCell.transform = CGAffineTransform(translationX: 0, y: historySlideY)
                        listCell.alpha = insertedHistoryIDs.contains(id) ? 0.35 : 1
                        collectionView.prepareTransitionEdgeMask(for: listCell, deltaY: historySlideY)
                        animatedRows.append((listCell, listCell.transitionGeneration))

                    case .track where queueSlideY != 0:
                        guard let listCell = cell as? EdgeFadedListCell else { continue }
                        listCell.layoutIfNeeded()
                        listCell.transitionGeneration &+= 1
                        listCell.isAnimatingTrackTransition = true
                        listCell.transform = CGAffineTransform(translationX: 0, y: queueSlideY)
                        listCell.alpha = 1
                        collectionView.prepareTransitionEdgeMask(for: listCell, deltaY: queueSlideY)
                        animatedRows.append((listCell, listCell.transitionGeneration))

                    case .songHeader where animateSongHeader:
                        cell.layoutIfNeeded()
                        cell.contentView.transform = .identity
                        cell.contentView.alpha = 0.15
                        songHeaderCell = cell

                    default:
                        break
                    }
                }
            }

            if !animatedRows.isEmpty {
                UIView.animate(
                    withDuration: 0.28,
                    delay: 0,
                    usingSpringWithDamping: 1,
                    initialSpringVelocity: 0,
                    options: [.allowUserInteraction, .beginFromCurrentState]
                ) {
                    for (cell, _) in animatedRows {
                        cell.transform = .identity
                        cell.alpha = 1
                        let spring = cell.layer.animation(forKey: "transform") as? CABasicAnimation
                        collectionView.animateTransitionEdgeMask(for: cell, matching: spring)
                    }
                } completion: { _ in
                    for (cell, generation) in animatedRows where cell.transitionGeneration == generation {
                        cell.isAnimatingTrackTransition = false
                        collectionView.updateEdgeMask(for: cell)
                    }
                }
            }

            if let songHeaderCell {
                UIView.animate(
                    withDuration: 0.22,
                    delay: 0,
                    options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
                ) {
                    songHeaderCell.contentView.alpha = 1
                }
            }
        }

        private func animateReturnToQueue(in collectionView: EdgeFadedCollectionView, reason: String) {
            collectionView.layoutIfNeeded()
            setQueueOffset(0, in: collectionView, reason: reason, animated: true)
        }

        private func setQueueOffset(_ offset: CGFloat, in collectionView: EdgeFadedCollectionView,
                                    reason: String, animated: Bool = false) {
            let target = collectionView.queueRestOffset + offset
            guard abs(collectionView.contentOffset.y - target) > 0.5 else { return }
            latest?.services?.diagnostics?.queueScroll("setContentOffset reason=\(reason) targetY=\(target) currentY=\(collectionView.contentOffset.y) animated=\(animated)")
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: animated)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            targetContentOffsetForProposedContentOffset proposedContentOffset: CGPoint
        ) -> CGPoint {
            guard let snapshotTargetOffset else { return proposedContentOffset }
            return CGPoint(x: proposedContentOffset.x, y: snapshotTargetOffset)
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
            let historyHeight = collectionView?.historyHeight ?? 0
            let offset = scrollView.contentOffset.y - (historyHeight - scrollView.adjustedContentInset.top)
            if isReturningAfterHistoryClear, !scrollView.isScrollAnimating,
               offset >= -HistoryStops.restTolerance {
                finishHistoryClear()
            }
            let headerOffset = clampedHeaderOffset(for: offset, headerHeight: latest.headerHeight)
            if scrollView.isDragging, let start = dragStartOffset,
               let stops = historyStops(in: scrollView) {
                let armed = stops.isArmed(from: start, at: offset)
                if armed != isHistoryThresholdArmed {
                    isHistoryThresholdArmed = armed
                    if armed {
                        playScrollFeedback()
                    }
                }
            }
            if scrollView.isDragging, let previousOffset = pendingCollapseFeedbackOffset {
                pendingCollapseFeedbackOffset = max(Self.collapseFeedbackDeadzone, headerOffset)
                if headerOffset > previousOffset, maximumScrollOffset(in: scrollView) >= latest.headerHeight {
                    pendingCollapseFeedbackOffset = nil
                    playScrollFeedback()
                }
            }
            latest.onScroll(min(offset, latest.headerHeight))
        }

        private func clampedHeaderOffset(for offset: CGFloat, headerHeight: CGFloat) -> CGFloat {
            guard offset > 0 else { return 0 }
            guard offset < headerHeight - HistoryStops.restTolerance else { return headerHeight }
            return offset
        }

        private var scrollFeedback: UIImpactFeedbackGenerator?
        var scrollFeedbackHandler: (() -> Void)?
        private var pendingCollapseFeedbackOffset: CGFloat?
        private var dragStartOffset: CGFloat?
        private var isHistoryThresholdArmed = false
        private var releaseSnap: (offset: CGFloat, preservesVelocity: Bool)?
        // UIScrollViewDelegate reports release velocity in points per millisecond.
        private static let nativeSnapVelocity: CGFloat = 0.25
        private static let fastSnapVelocity: CGFloat = 0.75
        private static let headerSnapVelocity: CGFloat = 0.08
        private static let headerDirectionalBias: CGFloat = 16
        private static let collapseFeedbackDeadzone: CGFloat = 6

        // Positions are relative to Continue Playing.
        private struct HistoryStops {
            static let triggerDistance: CGFloat = 96
            static let minFlickDisplacement: CGFloat = 24
            static let flickVelocity: CGFloat = 0.35
            static let restTolerance: CGFloat = 0.5
            let rest: CGFloat
            let revealThreshold: CGFloat
            var exitThreshold: CGFloat { max(rest, -Self.triggerDistance) }

            init(height: CGFloat, readableHeight: CGFloat) {
                rest = -min(height, max(Self.triggerDistance, readableHeight))
                revealThreshold = -min(height, Self.triggerDistance)
            }

            func isArmed(from start: CGFloat, at offset: CGFloat) -> Bool {
                if start >= -Self.restTolerance {
                    return start <= Self.restTolerance && offset <= revealThreshold
                }
                return offset >= exitThreshold
            }

            func releaseTarget(from start: CGFloat, at offset: CGFloat, projected: CGFloat,
                               velocity: CGFloat) -> CGFloat? {
                let movingDeeper = velocity < 0 && projected < offset
                if start >= -Self.restTolerance {
                    guard min(offset, projected) < 0 else { return nil }
                    // Returning from within the queue lands here. A new drag from rest can reveal History.
                    if start > Self.restTolerance { return 0 }
                    if projected < rest, movingDeeper || offset <= rest { return nil }
                    let flickReveal = movingDeeper && velocity <= -Self.flickVelocity
                        && offset <= -Self.minFlickDisplacement && projected <= revealThreshold
                    let reveal = offset <= revealThreshold
                        || (movingDeeper && projected <= revealThreshold)
                        || flickReveal
                    return reveal ? rest : 0
                }

                // The gesture that exits History ends at Continue Playing, even if the finger passed it.
                if offset >= 0 || projected >= 0 { return 0 }
                let returning = velocity > 0 && projected > offset
                // Below the boundary magnet zone, allow free scrolling and stopping anywhere in History.
                if offset <= exitThreshold {
                    return returning && projected >= exitThreshold ? 0 : nil
                }
                if movingDeeper {
                    return projected < exitThreshold ? nil : exitThreshold
                }
                if returning {
                    return 0
                }
                return offset >= exitThreshold / 2 ? 0 : exitThreshold
            }
        }

        private func historyStops(in scrollView: UIScrollView) -> HistoryStops? {
            guard let height = collectionView?.historyHeight, height > 0 else { return nil }
            let readableHeight = scrollView.bounds.height - scrollView.adjustedContentInset.top
                - NowPlayingQueueList.bottomFadeHeight
            return HistoryStops(height: height, readableHeight: readableHeight)
        }

        private func snapTarget(in scrollView: UIScrollView, projectedY: CGFloat,
                                velocity: CGFloat) -> CGFloat? {
            let queueRest = (collectionView?.historyHeight ?? 0) - scrollView.adjustedContentInset.top
            if let start = dragStartOffset, let stops = historyStops(in: scrollView),
               let target = stops.releaseTarget(from: start, at: scrollView.contentOffset.y - queueRest,
                                                projected: projectedY - queueRest, velocity: velocity) {
                return queueRest + target
            }
            return headerDragTarget(in: scrollView, queueRest: queueRest, projectedY: projectedY, velocity: velocity)
        }

        private func playScrollFeedback() {
            if let scrollFeedbackHandler {
                scrollFeedbackHandler()
            } else {
                scrollFeedback?.impactOccurred()
            }
        }

        private func maximumScrollOffset(in scrollView: UIScrollView) -> CGFloat {
            scrollView.contentSize.height + scrollView.adjustedContentInset.bottom
                - scrollView.bounds.height + scrollView.adjustedContentInset.top - (collectionView?.historyHeight ?? 0)
        }

        private func headerDragTarget(in scrollView: UIScrollView, queueRest: CGFloat, projectedY: CGFloat,
                                      velocity: CGFloat) -> CGFloat? {
            let target = projectedY - queueRest
            let offset = scrollView.contentOffset.y - queueRest
            guard offset >= 0, target >= 0,
                  let headerHeight = latest?.headerHeight, headerHeight > 0, target <= headerHeight else { return nil }
            // Scroll velocity follows contentOffset; pan translation follows the finger.
            let fingerTranslation = scrollView.panGestureRecognizer.translation(in: scrollView).y
            let isScrollingDown = velocity > 0 || (velocity == 0 && fingerTranslation < 0)
            let isScrollingUp = velocity < 0 || (velocity == 0 && fingerTranslation > 0)
            let canHideHeader = maximumScrollOffset(in: scrollView) >= headerHeight
            let bias = min(Self.headerDirectionalBias, headerHeight / 2)

            if velocity >= Self.headerSnapVelocity, offset < headerHeight, canHideHeader {
                return queueRest + headerHeight
            }
            if velocity <= -Self.headerSnapVelocity, offset > 0 {
                return queueRest
            }
            if isScrollingDown, offset < headerHeight, canHideHeader {
                return queueRest + (target >= bias ? headerHeight : 0)
            }
            if isScrollingUp, offset > 0 {
                return queueRest + (target <= headerHeight - bias && canHideHeader ? 0 : (canHideHeader ? headerHeight : 0))
            }

            guard target > 0, target < headerHeight else { return nil }
            let hidesHeader = target >= headerHeight / 2 && canHideHeader
            return queueRest + (hidesHeader ? headerHeight : 0)
        }

        func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            let projectedY = targetContentOffset.pointee.y
            let target = snapTarget(in: scrollView, projectedY: projectedY, velocity: velocity.y)
            let offset = scrollView.contentOffset.y
            if let target {
                let displacement = target - offset
                let projectedDisplacement = projectedY - offset
                let movesTowardTarget = displacement * velocity.y > 0
                let hasMomentum = abs(velocity.y) >= Self.nativeSnapVelocity
                    && (abs(projectedDisplacement) >= abs(displacement) * 0.35 || abs(velocity.y) >= Self.fastSnapVelocity)
                let preservesVelocity = movesTowardTarget && hasMomentum
                releaseSnap = (target, preservesVelocity)
                // Hand forward-moving snaps with sufficient momentum directly to UIKit's native deceleration.
                targetContentOffset.pointee.y = preservesVelocity ? target : offset
            } else {
                releaseSnap = nil
            }
            dragStartOffset = nil
            latest?.services?.diagnostics?.queueScroll(
                "scrollViewWillEndDragging offset=\(offset) velocity.y=\(velocity.y) "
                    + "projectedY=\(projectedY) snapY=\(String(describing: target)) "
                    + "preservesVelocity=\(releaseSnap?.preservesVelocity == true)"
            )
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            pendingCollapseFeedbackOffset = nil
            let offset = scrollView.contentOffset
            let target: CGFloat? = if decelerate && releaseSnap?.preservesVelocity == true {
                nil
            } else {
                releaseSnap?.offset ?? (!decelerate && dragStartOffset != nil
                    ? snapTarget(in: scrollView, projectedY: offset.y, velocity: 0) : nil)
            }
            releaseSnap = nil
            dragStartOffset = nil
            latest?.services?.diagnostics?.queueScroll(
                "scrollViewDidEndDragging offset=\(offset.y) decelerate=\(decelerate) "
                    + "target=\(String(describing: target)) willAnimate=\(target != nil && target != offset.y)"
            )
            if let target, target != offset.y {
                scrollView.setContentOffset(CGPoint(x: offset.x, y: target), animated: true)
            }
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            finishHistoryClear()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            finishHistoryClear()
            if let collectionView {
                for case let cell as EdgeFadedListCell in collectionView.visibleCells where cell.isAnimatingTrackTransition {
                    cell.transitionGeneration &+= 1
                    cell.isAnimatingTrackTransition = false
                    collectionView.updateEdgeMask(for: cell)
                }
            }
            guard let latest else { return }
            let historyHeight = collectionView?.historyHeight ?? 0
            let offset = scrollView.contentOffset.y - (historyHeight - scrollView.adjustedContentInset.top)
            dragStartOffset = offset
            releaseSnap = nil
            isHistoryThresholdArmed = historyStops(in: scrollView)?.isArmed(from: offset, at: offset) ?? false
            let clamped = clampedHeaderOffset(for: offset, headerHeight: latest.headerHeight)
            pendingCollapseFeedbackOffset = offset >= -HistoryStops.restTolerance
                ? max(Self.collapseFeedbackDeadzone, clamped)
                : nil
            scrollFeedback?.prepare()
            latest.services?.diagnostics?.queueScroll(
                "scrollViewWillBeginDragging offset=\(scrollView.contentOffset.y) queueOffset=\(offset)"
            )
        }
    }
}
