import SwiftUI
import UIKit

/// 继续播放列表。使用原生列表单元格及重排手柄，行内容由 SwiftUI 渲染。
/// 歌曲行采用透明底色的系统背景配置，交互状态变化由 UIKit 自动处理。
struct NowPlayingQueueList: UIViewRepresentable {
    nonisolated static let topFadeHeight: CGFloat = 24
    static let bottomFadeHeight: CGFloat = 80
    @Environment(PlayerActions.self) private var actions
    @Environment(PlayerState.self) private var player
    @Environment(\.playerVisualsActive) private var visualsActive
    @Environment(PlayerServices.self) private var services: PlayerServices?
    let entries: [PlayerQueueEntry]
    let version: PlayerQueueVersion
    var subtitle: String = "接下来播放的歌曲"
    /// 顶部给歌曲头部和模式按钮预留的高度，头部叠在上层，随列表滚动。
    let headerHeight: CGFloat
    /// 行内容离屏幕两侧的距离；列表本身通栏，高亮才能铺满宽度。
    let horizontalInset: CGFloat
    var bottomInset: CGFloat = 50
    let onPlay: (Int) -> Void
    let onMove: (IndexSet, Int) -> Void
    /// 滚动偏移，限制在 `0...headerHeight`。
    let onScroll: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> OverflowContainer {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        configuration.backgroundColor = .clear
        configuration.trailingSwipeActionsConfigurationProvider = { [weak coordinator = context.coordinator] indexPath in
            coordinator?.trailingActions(at: indexPath)
        }
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)

        let collectionView = EdgeFadedCollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.headerHeight = headerHeight
        // 收起手势由播放器的显式区域接收，列表区域始终只处理滚动和排序。
        collectionView.alwaysBounceVertical = true
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset.bottom = bottomInset
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
        if container.collectionView.contentInset.bottom != bottomInset {
            container.collectionView.contentInset.bottom = bottomInset
        }
        context.coordinator.update(with: self)
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
    private final class EdgeFadedListCell: UICollectionViewListCell {
        weak var edgeFadeCollectionView: EdgeFadedCollectionView?
        var contentRevision: UInt64?

        override func prepareForReuse() {
            super.prepareForReuse()
            contentRevision = nil
            edgeFadeCollectionView?.clearEdgeMasks(for: self)
        }

        override func layoutSublayers(of layer: CALayer) {
            // UIView lays out its subviews here; refresh once after that work finishes.
            super.layoutSublayers(of: layer)
            if layer === self.layer {
                edgeFadeCollectionView?.updateEdgeMask(for: self)
            }
        }
    }

    /// Directly masks individual leaves and `.plusLighter` layers at top/bottom fade zones
    /// without wrapping the list in an ancestor `CALayer.mask` that would isolate `.plusLighter`.
    @objc(NeoMusicEdgeFadedCollectionView)
    final class EdgeFadedCollectionView: UICollectionView {
        var headerHeight: CGFloat = 0 {
            didSet {
                guard abs(oldValue - headerHeight) > 0.5 else { return }
                setNeedsLayout()
            }
        }

        private let maskedCells = NSHashTable<UICollectionViewCell>.weakObjects()
        private var isUpdatingEdgeMasks = false

        override func layoutSubviews() {
            super.layoutSubviews()
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

        private func edgeFadeMetrics() -> EdgeFadeMetrics {
            let scrollOffset = min(max(contentOffset.y + adjustedContentInset.top, 0), headerHeight)
            let fadeTop = bounds.minY + max(headerHeight - scrollOffset, 0) + 44
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

        /// Classify each layer once; a parent target replaces only the suffix produced by its children.
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

    /// 布局上只占页面的宽度，列表本身向左右各多出 `overflow`，高亮才能通栏。
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
    final class Coordinator: NSObject, UICollectionViewDelegate {
        nonisolated enum Section: Sendable { case header, queue }
        nonisolated enum Item: Hashable, Sendable {
            case spacer
            case title
            case empty
            case track(PlayerQueueEntry.ID)
        }

        private(set) var latest: NowPlayingQueueList?
        private var entriesByID: [PlayerQueueEntry.ID: PlayerQueueEntry] = [:]
        private(set) var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
        private var swipeActionsByID: [PlayerQueueEntry.ID: [SongRowAction]] = [:]
        private weak var collectionView: UICollectionView?
        private var hasApplied = false
        private var requestedItemIdentifiers: [Item] = []
        private var currentItemIdentifiers: [Item] = []
        private var nativeOrderMatches = true
        private var contentRevision: UInt64 = 0
        private(set) var snapshotApplicationCount = 0

        func trailingActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            guard case .track(let id) = dataSource?.itemIdentifier(for: indexPath),
                  let items = swipeActionsByID[id], !items.isEmpty else { return nil }
            let actions = items.map { item in
                let action = UIContextualAction(style: .normal, title: item.title) { [weak self] _, _, completion in
                    guard let current = self?.swipeActionsByID[id]?.first(where: { $0.id == item.id }), !current.disabled else {
                        completion(false); return
                    }
                    current.perform()
                    completion(true)
                }
                action.image = UIImage(systemName: item.systemImage)
                action.backgroundColor = item.id == "favorite" ? .systemPink : .systemBlue
                return action
            }
            return UISwipeActionsConfiguration(actions: actions)
        }

        func attach(to collectionView: UICollectionView, initial: NowPlayingQueueList) {
            latest = initial
            self.collectionView = collectionView
            let registration = UICollectionView.CellRegistration<EdgeFadedListCell, Item> {
                [weak self] cell, _, item in
                cell.edgeFadeCollectionView = self?.collectionView as? EdgeFadedCollectionView
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
            (collectionView as? EdgeFadedCollectionView)?.headerHeight = list.headerHeight
            let entriesChanged = !hasApplied || previousList?.version != list.version
            let insetChanged = previousList?.horizontalInset != list.horizontalInset
            let headerChanged = previousList?.headerHeight != list.headerHeight
            let subtitleChanged = previousList?.subtitle != list.subtitle
            let becameActive = list.visualsActive && previousList?.visualsActive == false
            let dependenciesChanged = previousList.map {
                $0.player !== list.player || $0.actions !== list.actions
            } ?? false
            defer {
                if becameActive || entriesChanged { requestVisibleArtwork() }
            }
            updateScrollIndicatorInsets()
            if let nativeOrder {
                currentItemIdentifiers = nativeOrder
                nativeOrderMatches = nativeOrder == requestedItemIdentifiers
            }
            // Ordinary page, backdrop, progress and header updates never walk the queue.
            guard entriesChanged || !nativeOrderMatches || insetChanged || headerChanged
                    || subtitleChanged || dependenciesChanged else { return false }
            contentRevision &+= 1

            var changedItems: Set<Item> = []
            if entriesChanged {
                let previousEntries = entriesByID
                entriesByID = Dictionary(list.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                requestedItemIdentifiers = [.spacer, .title]
                    + (list.entries.isEmpty ? [.empty] : list.entries.map { .track($0.id) })
                nativeOrderMatches = currentItemIdentifiers == requestedItemIdentifiers
                changedItems = Set(list.entries.compactMap { entry in
                    previousEntries[entry.id].map { $0.song != entry.song } == true ? .track(entry.id) : nil
                })
            }
            if headerChanged || insetChanged { changedItems.insert(.spacer) }
            if subtitleChanged || insetChanged { changedItems.insert(.title) }
            if insetChanged { changedItems.insert(.empty) }

            if !hasApplied || !nativeOrderMatches {
                var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
                snapshot.appendSections([.header, .queue])
                snapshot.appendItems([.spacer, .title], toSection: .header)
                snapshot.appendItems(Array(requestedItemIdentifiers.dropFirst(2)), toSection: .queue)
                snapshot.reconfigureItems(requestedItemIdentifiers.filter(changedItems.contains))
                list.services?.diagnostics?.event("QueueSnapshot")
                snapshotApplicationCount += 1
                dataSource.apply(snapshot, animatingDifferences: hasApplied)
                currentItemIdentifiers = requestedItemIdentifiers
                nativeOrderMatches = true
                hasApplied = true
                return true
            }

            // Updating a hosting configuration preserves its native cell. Rows outside
            // the viewport receive the latest metadata and environment in willDisplay.
            // A metadata update doesn't submit a structural snapshot.
            var refreshed = false
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

        private func updateScrollIndicatorInsets() {
            guard let collectionView, let latest else { return }
            let offset = max(0, collectionView.contentOffset.y + collectionView.adjustedContentInset.top)
            let insets = UIEdgeInsets(
                top: max(0, latest.headerHeight - offset) + 44 + NowPlayingQueueList.topFadeHeight,
                left: 0, bottom: NowPlayingQueueList.bottomFadeHeight, right: 0
            )
            if collectionView.verticalScrollIndicatorInsets != insets {
                collectionView.verticalScrollIndicatorInsets = insets
            }
        }

        func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                            forItemAt indexPath: IndexPath) {
            guard let cell = cell as? UICollectionViewListCell,
                  let item = dataSource?.itemIdentifier(for: indexPath) else { return }
            requestArtwork(for: item)
            // Cell registration already prepared the hosting content before display.
            // Refresh a waiting cell only if its inputs changed while it was offscreen.
            if let prepared = cell as? EdgeFadedListCell,
               prepared.contentRevision == contentRevision { return }
            configure(cell, item: item)
        }

        private func requestVisibleArtwork() {
            guard let latest, latest.visualsActive, let collectionView, let dataSource else { return }
            for indexPath in collectionView.indexPathsForVisibleItems {
                if let item = dataSource.itemIdentifier(for: indexPath) { requestArtwork(for: item) }
            }
        }

        private func requestArtwork(for item: Item) {
            guard let latest, latest.visualsActive, case .track(let id) = item,
                  let entry = entriesByID[id] else { return }
            latest.services?.artwork.prepare(entry.song.artworkLoadID)
        }

        func configure(_ cell: UICollectionViewListCell, item: Item) {
            guard let latest else { return }
            let inset = latest.horizontalInset

            // 拖动手柄默认贴着列表边缘，列表通栏所以要往里收，和行内容对齐。
            // 真机实测：手柄右缘 = 列表宽度 - 此边距 + 1.5，+1.5 让右缘正好落在内容边上。
            cell.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: 0, leading: 0, bottom: 0, trailing: inset + 1.5
            )
            cell.configurationUpdateHandler = nil
            if case .track = item {
                var background = cell.defaultBackgroundConfiguration()
                background.backgroundColor = .clear
                cell.backgroundConfiguration = background
            } else {
                // A cell reused for a header/empty row must shed its track accessory.
                if !cell.accessories.isEmpty { cell.accessories = [] }
                cell.backgroundConfiguration = .clear()
            }

            switch item {
            case .spacer:
                let height = latest.headerHeight + 44
                cell.contentConfiguration = UIHostingConfiguration {
                    Color.clear.frame(height: height)
                        .listRowSeparator(.hidden)
                }
                .margins(.all, 0)
                .minSize(height: 0)

            case .title:
                cell.contentConfiguration = UIHostingConfiguration {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("继续播放")
                            .font(.headline.bold())
                            .nowPlayingPrimary()
                        NowPlayingVibrantLabel(text: latest.subtitle, fontSize: 13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowSeparator(.hidden)
                }
                .margins(.horizontal, inset)
                .margins(.top, 14)
                .margins(.bottom, 12)
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
                    NowPlayingQueueRow(entry: entry, onSwipeActions: { [weak self] actions in
                        self?.swipeActionsByID[id] = actions.isEmpty ? nil : actions
                    }) { [weak self] in
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
                // Reconfiguration preserves the cell. Its existing reorder accessory
                // already has our fixed style; clearing it would rebuild UIKit's layout.
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
            currentItemIdentifiers = transaction.finalSnapshot.itemIdentifiers
            nativeOrderMatches = currentItemIdentifiers == requestedItemIdentifiers
            guard let section = transaction.sectionTransactions.first(where: { $0.sectionIdentifier == .queue }) else { return }
            for change in section.difference.inferringMoves() {
                guard case let .remove(source, _, associatedWith?) = change else { continue }
                latest?.onMove(IndexSet(integer: source), associatedWith > source ? associatedWith + 1 : associatedWith)
                return
            }
        }

        // MARK: UICollectionViewDelegate

        func collectionView(
            _ collectionView: UICollectionView,
            targetIndexPathForMoveOfItemAt originalIndexPath: IndexPath,
            toProposedIndexPath proposedIndexPath: IndexPath
        ) -> IndexPath {
            clampedMoveTarget(from: originalIndexPath, to: proposedIndexPath)
        }

        /// 旧名字的同一个回调，系统用哪个都按同样的规则限制。
        func collectionView(
            _ collectionView: UICollectionView,
            targetIndexPathForMoveFromItemAt originalIndexPath: IndexPath,
            toProposedIndexPath proposedIndexPath: IndexPath
        ) -> IndexPath {
            clampedMoveTarget(from: originalIndexPath, to: proposedIndexPath)
        }

        /// 只能在"继续播放"的曲目之间移动，不能落到顶部占位或标题的位置。
        private func clampedMoveTarget(from original: IndexPath, to proposed: IndexPath) -> IndexPath {
            guard proposed.section == original.section else {
                return IndexPath(item: proposed.section < original.section ? 0 : max(original.item, 0), section: original.section)
            }
            return proposed
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let latest else { return }
            // 保持现有顶部边界，头部滚动与吸附不额外叠加橡皮筋位移。
            let top = -scrollView.adjustedContentInset.top
            if scrollView.contentOffset.y < top {
                scrollView.contentOffset.y = top
            }
            updateScrollIndicatorInsets()
            // UIKit coalesces scroll and cell geometry changes before the next display update.
            (scrollView as? EdgeFadedCollectionView)?.setNeedsLayout()
            let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            latest.onScroll(min(max(offset, 0), latest.headerHeight))
            // 手指按着往下拉列表时不振。
            if let previous = previousOffset, latest.headerHeight > 0,
               !(scrollView.isTracking && offset < previous) {
                playSnapFeedbackIfReached(from: previous, to: offset, headerHeight: latest.headerHeight)
            }
            previousOffset = offset
        }

        private var previousOffset: CGFloat?
        private let snapFeedback = UIImpactFeedbackGenerator(style: .soft)

        /// 滚到两个停靠位置之一（头部完整露出、头部刚好滚出去）就振一下，
        /// 吸附、惯性经过、手指往上推过去都算；离开后再回来才会再振。
        private func playSnapFeedbackIfReached(from previous: CGFloat, to offset: CGFloat, headerHeight: CGFloat) {
            for anchor in [0, headerHeight] {
                let wasAway = abs(previous - anchor) >= 0.5
                let reached = (previous - anchor) * (offset - anchor) <= 0
                if wasAway && reached {
                    snapFeedback.impactOccurred(intensity: 1)
                    snapFeedback.prepare()
                    return
                }
            }
        }

        /// 松手后不停在歌曲头部只露出一部分的位置：要么头部完整露出，要么整个滚出去（模式按钮贴顶）。
        /// 有明显滑动方向时顺着方向吸附，否则吸到较近的一端。
        func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            guard let headerHeight = latest?.headerHeight, headerHeight > 0 else { return }
            let top = -scrollView.adjustedContentInset.top
            let target = targetContentOffset.pointee.y - top
            guard target > 0, target < headerHeight else { return }
            // 列表太短、滚不到头部完全隐藏的位置时，只能回到顶部。
            let maxOffset = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom
                - scrollView.bounds.height - top
            let canHideHeader = maxOffset >= headerHeight
            let hidesHeader: Bool
            if velocity.y > 0.2 {
                hidesHeader = true
            } else if velocity.y < -0.2 {
                hidesHeader = false
            } else {
                hidesHeader = target >= headerHeight / 2
            }
            targetContentOffset.pointee.y = top + (hidesHeader && canHideHeader ? headerHeight : 0)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            snapFeedback.prepare()
        }
    }
}
