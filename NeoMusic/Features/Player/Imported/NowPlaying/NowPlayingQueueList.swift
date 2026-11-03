import SwiftUI
import UIKit

nonisolated struct UpcomingQueueEntry: Identifiable, Hashable, Sendable {
    struct ID: Hashable {
        let songID: String
        let occurrence: Int
    }

    let id: ID
    let queueIndex: Int
    let song: ReferenceTrack
}

/// 继续播放列表。使用原生列表单元格及重排手柄，行内容由 SwiftUI 渲染。
/// 歌曲行采用透明底色的系统背景配置，交互状态变化由 UIKit 自动处理。
struct NowPlayingQueueList: UIViewRepresentable {
    @Environment(ReferencePlayerActions.self) private var actions
    @Environment(ReferencePlayerState.self) private var player
    @Environment(ReferenceLibrary.self) private var library
    @Environment(\.nowPlayingBackdropImage) private var backdropImage
    @Environment(\.nowPlayingUndimmedBackdropImage) private var undimmedBackdropImage
    @Environment(\.nowPlayingBackdropAnchor) private var backdropAnchor
    @Environment(\.playerArtistEDREnabled) private var edrEnabled
    @Environment(\.playerEDRLevels) private var edrLevels
    let entries: [UpcomingQueueEntry]
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

        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        // 收起手势由播放器的显式区域接收，列表区域始终只处理滚动和排序。
        collectionView.alwaysBounceVertical = true
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset.bottom = bottomInset
        collectionView.allowsSelection = false
        collectionView.showsVerticalScrollIndicator = true
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
            case track(UpcomingQueueEntry.ID)
        }

        private(set) var latest: NowPlayingQueueList?
        private var entriesByID: [UpcomingQueueEntry.ID: UpcomingQueueEntry] = [:]
        private(set) var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
        private var swipeActionsByID: [UpcomingQueueEntry.ID: [SongRowAction]] = [:]
        private var hasApplied = false
        private var requestedItemIdentifiers: [Item] = []

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
            let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> {
                [weak self] cell, _, item in
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
        func update(with list: NowPlayingQueueList) -> Bool {
            guard let dataSource else { return false }
            let previousList = latest
            // Keep callbacks fresh even when the rendered inputs are unchanged.
            latest = list
            let entriesChanged = previousList?.entries != list.entries
            let insetChanged = previousList?.horizontalInset != list.horizontalInset
            let headerChanged = previousList?.headerHeight != list.headerHeight
            let subtitleChanged = previousList?.subtitle != list.subtitle
            let appearanceChanged = previousList.map {
                $0.backdropImage !== list.backdropImage
                    || $0.undimmedBackdropImage !== list.undimmedBackdropImage
                    || $0.edrEnabled != list.edrEnabled
                    || $0.edrLevels != list.edrLevels
                    || $0.backdropAnchor !== list.backdropAnchor
            } ?? false
            let dependenciesChanged = previousList.map {
                $0.player !== list.player || $0.actions !== list.actions || $0.library !== list.library
            } ?? false
            // Read UIKit's actual order: a native reorder may have changed it before
            // the owner accepts or rejects the move. Equal SwiftUI inputs alone cannot skip it.
            let currentIdentifiers = dataSource.snapshot().itemIdentifiers
            if hasApplied, !entriesChanged, !insetChanged, !headerChanged, !subtitleChanged,
               !appearanceChanged, !dependenciesChanged, currentIdentifiers == requestedItemIdentifiers {
                return false
            }
            let previous = entriesByID
            if entriesChanged || !hasApplied {
                entriesByID = Dictionary(list.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            }

            var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
            snapshot.appendSections([.header, .queue])
            snapshot.appendItems([.spacer, .title], toSection: .header)
            snapshot.appendItems(
                list.entries.isEmpty ? [.empty] : list.entries.map { .track($0.id) },
                toSection: .queue
            )

            // 同一行换了曲目信息（元数据更新）时重新配置；位置变化不需要，点播时现查下标。
            var reconfigured: Set<Item> = Set(list.entries.compactMap { entry in
                previous[entry.id].map { $0.song != entry.song } == true ? .track(entry.id) : nil
            })
            // A header measurement or subtitle change doesn't change any song row.
            // Backdrop/EDR and dependency replacements still reach every affected row.
            if headerChanged || insetChanged { reconfigured.insert(.spacer) }
            if subtitleChanged || insetChanged || appearanceChanged { reconfigured.insert(.title) }
            if insetChanged { reconfigured.insert(.empty) }
            if insetChanged || appearanceChanged || dependenciesChanged {
                reconfigured.formUnion(list.entries.map { .track($0.id) })
            }
            let identifiers = snapshot.itemIdentifiers
            snapshot.reconfigureItems(identifiers.filter(reconfigured.contains))
            requestedItemIdentifiers = identifiers

            if hasApplied, reconfigured.isEmpty,
               currentIdentifiers == identifiers { return false }
            dataSource.apply(snapshot, animatingDifferences: hasApplied)
            hasApplied = true
            return true
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
                        PlayerWhiteEDRText(text: "继续播放", fontSize: 17, fontWeight: .bold)
                            .font(.headline.bold())
                            .foregroundStyle(Color.white)
                        NowPlayingVibrantLabel(text: latest.subtitle, fontSize: 13, role: .subtitle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowSeparator(.hidden)
                    .environment(\.nowPlayingBackdropImage, latest.backdropImage)
                    .environment(\.nowPlayingUndimmedBackdropImage, latest.undimmedBackdropImage)
                    .environment(\.nowPlayingBackdropAnchor, latest.backdropAnchor)
                    .environment(\.playerArtistEDREnabled, latest.edrEnabled)
                    .environment(\.playerEDRLevels, latest.edrLevels)
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
                    .environment(latest.library)
                    .listRowSeparator(.hidden)
                    .environment(\.nowPlayingBackdropImage, latest.backdropImage)
                    .environment(\.nowPlayingUndimmedBackdropImage, latest.undimmedBackdropImage)
                    .environment(\.nowPlayingBackdropAnchor, latest.backdropAnchor)
                    .environment(\.playerArtistEDREnabled, latest.edrEnabled)
                    .environment(\.playerEDRLevels, latest.edrLevels)
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
                                 options: .init(tintColor: UIColor.white.withAlphaComponent(0.45)))
                    ]
                }
            }
        }

        private func didReorder(
            _ transaction: NSDiffableDataSourceTransaction<Section, Item>
        ) {
            let initial = transaction.initialSnapshot.itemIdentifiers(inSection: .queue)
            let final = transaction.finalSnapshot.itemIdentifiers(inSection: .queue)
            for change in final.difference(from: initial).inferringMoves() {
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
            latest?.backdropAnchor?.refresh()
            guard let latest else { return }
            // 保持现有顶部边界，头部滚动与吸附不额外叠加橡皮筋位移。
            let top = -scrollView.adjustedContentInset.top
            if scrollView.contentOffset.y < top {
                scrollView.contentOffset.y = top
            }
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
