import XCTest
import SwiftUI
@testable import NeoMusic
@testable import FrontAMPlayer
@testable import FrontAMPopup

@MainActor
final class NowPlayingQueueListUpdateTests: XCTestCase {
    private typealias Coordinator = NowPlayingQueueList.Coordinator

    private func mount(_ inputs: QueueListTestInputs) throws -> (UIWindow, UIViewController) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: QueueListTestView(inputs: inputs))
        window.rootViewController = host
        window.makeKeyAndVisible()
        return (window, host)
    }

    private func settle(_ host: UIViewController) async throws {
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.view.layoutIfNeeded()
    }

    private func collection(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView { return collection }
        return view.subviews.lazy.compactMap(collection).first
    }

    private func coordinator(in view: UIView) throws -> Coordinator {
        try XCTUnwrap(collection(in: view)?.delegate as? Coordinator)
    }

    private func markConfigurations(in view: UIView, source: UICollectionViewDiffableDataSource<Coordinator.Section, Coordinator.Item>) throws -> [Coordinator.Item: UICollectionViewListCell] {
        func find(_ view: UIView) -> UICollectionView? {
            if let collection = view as? UICollectionView { return collection }
            return view.subviews.lazy.compactMap(find).first
        }
        let collection = try XCTUnwrap(find(view))
        collection.layoutIfNeeded()
        return try Dictionary(uniqueKeysWithValues: collection.indexPathsForVisibleItems.map { path in
            let item = try XCTUnwrap(source.itemIdentifier(for: path))
            let cell = try XCTUnwrap(collection.cellForItem(at: path) as? UICollectionViewListCell)
            cell.configurationUpdateHandler = { _, _ in }
            return (item, cell)
        })
    }

    private func reconfiguredCells(_ marked: [Coordinator.Item: UICollectionViewListCell]) -> Set<Coordinator.Item> {
        for cell in marked.values { XCTAssertNotNil(cell.window, "Reconfiguration must keep the existing visible cells") }
        return Set(marked.compactMap { item, cell in cell.configurationUpdateHandler == nil ? item : nil })
    }

    private func assertReorderAccessory(in cell: UICollectionViewListCell) throws {
        XCTAssertEqual(cell.accessories.map(\.accessoryType), [.reorder])
        let accessories = try XCTUnwrap(cell.value(forKey: "accessories") as? [NSObject])
        XCTAssertEqual(accessories.count, 1)
        let accessory = try XCTUnwrap(accessories.first)
        XCTAssertEqual(accessory.value(forKey: "displayedState") as? NSNumber, NSNumber(value: 0))
        XCTAssertEqual(accessory.value(forKey: "tintColor") as? UIColor, UIColor.white.withAlphaComponent(0.45))
    }

    func testHandoffHidesHeaderWithoutReplacingMaskedContent() async throws {
        let (window, host) = try mount(QueueListTestInputs())
        defer { window.isHidden = true }
        try await settle(host)
        let coordinator = try coordinator(in: host.view)
        var list = try XCTUnwrap(coordinator.latest)
        let source = try XCTUnwrap(coordinator.dataSource)
        let marked = try markConfigurations(in: host.view, source: source)
        let header = try XCTUnwrap(marked[.songHeader])
        let content = header.contentView
        for visible in [false, true] {
            list.showsSongHeader = visible
            XCTAssertTrue(coordinator.update(with: list))
            XCTAssertTrue(content === header.contentView)
            XCTAssertEqual(content.isHidden, !visible)
            XCTAssertTrue(reconfiguredCells(marked).isEmpty)
        }
    }

    func testUnchangedInputsSkipApplyAndHeaderChangesLeaveRowsAlone() async throws {
        let inputs = QueueListTestInputs()
        let (window, host) = try mount(inputs)
        defer { window.isHidden = true }
        try await settle(host)
        let coordinator = try coordinator(in: host.view)
        let source = try XCTUnwrap(coordinator.dataSource)
        XCTAssertFalse(coordinator.update(with: try XCTUnwrap(coordinator.latest)))

        var marked = try markConfigurations(in: host.view, source: source)
        XCTAssertFalse(coordinator.update(with: try XCTUnwrap(coordinator.latest)))
        let list = try XCTUnwrap(collection(in: host.view))
        for (item, cell) in marked {
            let path = try XCTUnwrap(source.indexPath(for: item))
            coordinator.collectionView(list, willDisplay: cell, forItemAt: path)
        }
        XCTAssertTrue(reconfiguredCells(marked).isEmpty,
                      "Displaying an already prepared cell must preserve its hosting configuration")
        inputs.headerHeight += 20
        try await settle(host)
        XCTAssertEqual(reconfiguredCells(marked), [.songHeader])
        marked = try markConfigurations(in: host.view, source: source)
        inputs.subtitle = "Updated subtitle"
        try await settle(host)
        XCTAssertTrue(reconfiguredCells(marked).isEmpty)
        XCTAssertNotNil((list as? NowPlayingQueueList.EdgeFadedCollectionView)?.queueHeader)

        marked = try markConfigurations(in: host.view, source: source)
        inputs.visualsActive = false
        try await settle(host)
        XCTAssertEqual(reconfiguredCells(marked), [.songHeader])
        marked = try markConfigurations(in: host.view, source: source)
        marked = try markConfigurations(in: host.view, source: source)
        inputs.actions = PlayerTestFixtures.actions()
        try await settle(host)
        XCTAssertEqual(reconfiguredCells(marked), Set(inputs.entries.map { Coordinator.Item.track($0.id) } + [.songHeader]))
        XCTAssertFalse(coordinator.update(with: try XCTUnwrap(coordinator.latest)))
    }

    func testMetadataUpdatesAndNativeReorderStaySynchronized() async throws {
        let inputs = QueueListTestInputs()
        let (window, host) = try mount(inputs)
        defer { window.isHidden = true }
        try await settle(host)
        let coordinator = try coordinator(in: host.view)
        let source = try XCTUnwrap(coordinator.dataSource)
        let a = inputs.entries[0], b = inputs.entries[1]
        let applications = coordinator.snapshotApplicationCount
        let marked = try markConfigurations(in: host.view, source: source)
        let trackCell = try XCTUnwrap(marked[.track(a.id)])
        try assertReorderAccessory(in: trackCell)
        inputs.entries[0] = PlayerQueueEntry(id: a.id, queueIndex: 7,
            song: PlayerTrack(id: a.song.id, title: "Updated title", artists: a.song.artists,
                                 albumTitle: a.song.albumTitle, coverURL: nil, duration: a.song.duration))
        try await settle(host)
        XCTAssertEqual(reconfiguredCells(marked), [.track(a.id)])
        XCTAssertEqual(coordinator.snapshotApplicationCount, applications)
        try assertReorderAccessory(in: trackCell)
        XCTAssertFalse(coordinator.update(with: try XCTUnwrap(coordinator.latest)))

        var nativeOrder = source.snapshot()
        nativeOrder.moveItem(.track(b.id), beforeItem: .track(a.id))
        await withCheckedContinuation { continuation in
            source.apply(nativeOrder, animatingDifferences: false) { continuation.resume() }
        }
        XCTAssertTrue(coordinator.update(with: try XCTUnwrap(coordinator.latest),
                                         nativeOrder: nativeOrder.itemIdentifiers))
        XCTAssertEqual(source.snapshot().itemIdentifiers(inSection: .queue), [.track(a.id), .track(b.id)])

        inputs.entries.reverse()
        try await settle(host)
        XCTAssertEqual(source.snapshot().itemIdentifiers(inSection: .queue), [.track(b.id), .track(a.id)])
        XCTAssertFalse(coordinator.update(with: try XCTUnwrap(coordinator.latest)))

        coordinator.configure(trackCell, item: .track(a.id))
        try assertReorderAccessory(in: trackCell)
        coordinator.configure(trackCell, item: .songHeader)
        XCTAssertTrue(trackCell.accessories.isEmpty)
        coordinator.configure(trackCell, item: .track(a.id))
        try assertReorderAccessory(in: trackCell)
        coordinator.configure(trackCell, item: .empty)
        XCTAssertTrue(trackCell.accessories.isEmpty)
    }

    func testNativeInteractiveMovementInLongQueueCommitsStableOccurrencesOnce() async throws {
        let tracks = (0..<2_000).map { index in
            PlayerTrack(id: "song-\(index % 50)", title: "Song \(index % 50)", artists: "Artist",
                           albumTitle: "Album", coverURL: nil, duration: 60)
        }
        let owner = PlayerTestFixtures.owner(tracks: tracks)
        let player = PlayerState(model: owner)
        player.skip(toQueueIndex: 900)
        let hidden = Array(owner.entryIDs[921...]) + Array(owner.entryIDs[..<900])
        let inputs = QueueListTestInputs()
        inputs.player = player
        inputs.entries = player.upcomingQueueEntries
        let moved = expectation(description: "UIKit commits its native reorder transaction")
        inputs.onMove = { [weak inputs] offsets, destination in
            player.moveUpcomingQueueItems(fromOffsets: offsets, toOffset: destination)
            inputs?.entries = player.upcomingQueueEntries
            moved.fulfill()
        }
        let current = owner.entryIDs[owner.currentIndex]
        let revision = owner.queueRevision
        var expected = inputs.entries.map(\.id)
        expected.move(fromOffsets: IndexSet(integer: 0), toOffset: 4)
        let (window, host) = try mount(inputs)
        defer { window.isHidden = true }
        try await settle(host)
        let collectionView = try XCTUnwrap(collection(in: host.view))
        let coordinator = try coordinator(in: host.view)
        let source = try XCTUnwrap(coordinator.dataSource)
        XCTAssertEqual(source.snapshot().numberOfItems(inSection: .queue), 20)
        let from = IndexPath(item: 0, section: 1)
        let to = IndexPath(item: 3, section: 1)
        let target = try XCTUnwrap(collectionView.layoutAttributesForItem(at: to)).center

        XCTAssertTrue(collectionView.beginInteractiveMovementForItem(at: from))
        collectionView.updateInteractiveMovementTargetPosition(target)
        collectionView.endInteractiveMovement()
        await fulfillment(of: [moved], timeout: 3)
        try await settle(host)

        XCTAssertEqual(owner.queueRevision, revision + 1)
        XCTAssertEqual(player.upcomingQueueEntries.map(\.id), expected)
        XCTAssertEqual(source.snapshot().itemIdentifiers(inSection: .queue), expected.map(Coordinator.Item.track))
        XCTAssertEqual(owner.entryIDs[owner.currentIndex], current)
        XCTAssertEqual(Array(owner.entryIDs[921...]) + Array(owner.entryIDs[..<900]), hidden)
        XCTAssertFalse(coordinator.update(with: try XCTUnwrap(coordinator.latest)),
                       "The accepted native order needs no second snapshot application")

        let swipe = try XCTUnwrap(coordinator.trailingActions(at: from))
        XCTAssertEqual(swipe.actions.count, 1)
        XCTAssertEqual(swipe.actions.first?.style, .destructive)
        XCTAssertNil(swipe.actions.first?.title)
        XCTAssertEqual(swipe.actions.first?.image?.accessibilityLabel, "从继续播放列表删除")
        collectionView.contentOffset.y = 320
        try await settle(host)
        collectionView.contentOffset.y = 0
        try await settle(host)
        XCTAssertNotNil(coordinator.trailingActions(at: from),
                        "A prepared row must restore swipe actions when it returns onscreen")
        let entryToRemove = player.upcomingQueueEntries[0].id
        let removal = try XCTUnwrap(coordinator.trailingActions(at: from)?.actions.first)
        var succeeded = false
        removal.handler(removal, UIView()) { succeeded = $0 }
        XCTAssertTrue(succeeded)
        XCTAssertFalse(owner.entryIDs.contains(entryToRemove))
        XCTAssertEqual(owner.entryIDs.count, 1_999)
        XCTAssertEqual(owner.entryIDs[owner.currentIndex], current)

    }

    func testPageVisibilityChangesKeepListAndSnapshotForAllQueueLengths() async throws {
        for count in [50, 500, 2_000] {
            let inputs = QueueListTestInputs()
            inputs.entries = (0..<count).map { index in
                PlayerQueueEntry(id: UUID(), queueIndex: index,
                    song: PlayerTrack(id: "song-\(index % 50)", title: "Song", artists: "Artist",
                                         albumTitle: "Album", coverURL: nil, duration: 60,
                                         artworkLoadID: "cover-\(index)"))
            }
            let (window, host) = try mount(inputs)
            defer { window.isHidden = true }
            try await settle(host)
            let list = try XCTUnwrap(collection(in: host.view))
            let coordinator = try coordinator(in: host.view)
            let source = try XCTUnwrap(coordinator.dataSource)
            let applications = coordinator.snapshotApplicationCount
            func visibleArtworkIDs() -> Set<String> {
                let visible = Set(list.indexPathsForVisibleItems.compactMap { path -> UUID? in
                    guard case .track(let id) = source.itemIdentifier(for: path) else { return nil }
                    return id
                })
                return Set(inputs.entries.filter { visible.contains($0.id) }.compactMap { $0.song.artworkLoadID })
            }
            XCTAssertFalse(inputs.artworkRequests.isEmpty, "Initial visible rows request their deferred covers")
            XCTAssertTrue(Set(inputs.artworkRequests).isSubset(of: visibleArtworkIDs()))
            let marked = try markConfigurations(in: host.view, source: source).filter { $0.key != .songHeader }
            for _ in 0..<10 {
                inputs.artworkRequests.removeAll()
                inputs.visualsActive.toggle()
                try await settle(host)
                XCTAssertTrue(collection(in: host.view) === list)
                XCTAssertEqual(coordinator.snapshotApplicationCount, applications,
                               "Visibility must not submit the \(count)-entry snapshot")
                XCTAssertTrue(reconfiguredCells(marked).isEmpty,
                              "Page visibility must preserve prepared queue rows")
                XCTAssertEqual(Set(inputs.artworkRequests), inputs.visualsActive ? visibleArtworkIDs() : [])
            }
            XCTAssertEqual(coordinator.dataSource?.snapshot().numberOfItems(inSection: .queue), count)

            inputs.artworkRequests.removeAll()
            let entry = inputs.entries[0]
            var updated = entry.song
            updated.artworkLoadID = "updated-cover"
            inputs.entries[0] = PlayerQueueEntry(id: entry.id, queueIndex: entry.queueIndex, song: updated)
            try await settle(host)
            XCTAssertTrue(inputs.artworkRequests.contains("updated-cover"),
                          "A visible row must request its replacement artwork without another appearance")

            inputs.artworkRequests.removeAll()
            inputs.visualsActive = false
            try await settle(host)
            list.contentOffset.y = 320
            try await settle(host)
            XCTAssertTrue(inputs.artworkRequests.isEmpty, "An inactive page must not request newly displayed rows")
            inputs.visualsActive = true
            try await settle(host)
            XCTAssertEqual(Set(inputs.artworkRequests), visibleArtworkIDs())
            inputs.artworkRequests.removeAll()
            list.contentOffset.y = 0
            try await settle(host)
            XCTAssertTrue(inputs.artworkRequests.contains("updated-cover"),
                          "Returning rows must request deferred artwork while active")
        }
    }

    func testPinnedHeaderAndScrollIndicatorTrackViewportWithoutChangingContent() async throws {
        for count in [0, 3, 50, 2_000] {
            let inputs = QueueListTestInputs()
            inputs.entries = (0..<count).map { index in
                PlayerQueueEntry(id: UUID(), queueIndex: index,
                    song: PlayerTrack(id: "song-\(index)", title: "Song", artists: "Artist",
                                         albumTitle: "Album", coverURL: nil, duration: 60))
            }
            let (window, host) = try mount(inputs)
            defer { window.isHidden = true }
            try await settle(host)
            let list = try XCTUnwrap(collection(in: host.view) as? NowPlayingQueueList.EdgeFadedCollectionView)
            let contentInset = list.contentInset
            let size = list.contentSize
            let top = -list.adjustedContentInset.top
            let bottom = max(top, size.height + list.adjustedContentInset.bottom - list.bounds.height)
            let collapsed = top + inputs.headerHeight
            XCTAssertGreaterThanOrEqual(bottom, collapsed - 1)
            let offsets: [CGFloat] = count > 3
                ? [top, collapsed - 1, collapsed, 300, bottom]
                : [top, collapsed]
            for rawOffset in offsets {
                list.contentOffset.y = rawOffset
                list.layoutIfNeeded()
                let offset: CGFloat
                if rawOffset == bottom, count > 3 {
                    offset = max(top, list.contentSize.height + list.adjustedContentInset.bottom - list.bounds.height)
                    list.contentOffset.y = offset
                    list.layoutIfNeeded()
                } else {
                    offset = rawOffset
                }
                let position = list.contentOffset
                let settledSize = list.contentSize
                list.layoutIfNeeded()
                let header = try XCTUnwrap(list.queueHeader)
                let frame = list.convert(header.bounds, from: header).offsetBy(dx: 0, dy: -list.bounds.minY)
                XCTAssertEqual(frame.minY, contentInset.top + max(0, inputs.headerHeight - (offset - top)),
                               accuracy: 1)
                XCTAssertEqual(list.verticalScrollIndicatorInsets.top, frame.maxY + NowPlayingQueueList.topFadeHeight,
                               accuracy: 1)
                XCTAssertEqual(list.verticalScrollIndicatorInsets.bottom, NowPlayingQueueList.bottomFadeHeight)
                XCTAssertEqual(list.contentOffset, position)
                XCTAssertEqual(list.contentInset, contentInset)
                XCTAssertEqual(list.contentSize, settledSize)
                XCTAssertEqual(list.contentSize.width, size.width)
            }
            if count > 3 {
                let last = IndexPath(item: count - 1, section: 1)
                let row = try XCTUnwrap(list.layoutAttributesForItem(at: last))
                XCTAssertLessThanOrEqual(row.frame.maxY, list.bounds.maxY - NowPlayingQueueList.bottomFadeHeight + 1)
            }
        }
    }

    func testUpwardSwipeSnapsShortProjectionAndPreservesMomentumPastSongHeader() async throws {
        let inputs = QueueListTestInputs()
        inputs.entries = (0..<30).map { index in
            PlayerQueueEntry(id: UUID(), queueIndex: index,
                song: PlayerTrack(id: "song-\(index)", title: "Song", artists: "Artist",
                                 albumTitle: "Album", coverURL: nil, duration: 60))
        }
        let (window, host) = try mount(inputs)
        defer { window.isHidden = true }
        try await settle(host)
        let list = try XCTUnwrap(collection(in: host.view))
        let coordinator = try coordinator(in: host.view)
        let top = -list.adjustedContentInset.top
        let scroll = QueueDragTestScrollView(matching: list)

        func target(afterReleasingAt offset: CGFloat, velocity: CGFloat,
                    projectedOffset: CGFloat? = nil) -> CGFloat {
            scroll.contentOffset.y = top + offset
            coordinator.scrollViewWillBeginDragging(scroll)
            return scroll.release(using: coordinator, projectedY: top + (projectedOffset ?? offset),
                                  velocity: velocity, willDecelerate: velocity != 0)
        }

        let collapsed = top + inputs.headerHeight
        XCTAssertEqual(target(afterReleasingAt: 1, velocity: 0.001), top,
                       "Micro-nudges below the 16pt directional bias settle back to expanded")
        XCTAssertEqual(scroll.animatedContentOffset?.y, top)
        XCTAssertEqual(target(afterReleasingAt: 16, velocity: 0.001), collapsed)
        XCTAssertEqual(scroll.animatedContentOffset?.y, collapsed)
        XCTAssertEqual(target(afterReleasingAt: 1, velocity: 0.5, projectedOffset: inputs.headerHeight), collapsed)
        XCTAssertNil(scroll.animatedContentOffset, "Forward thumb flicks preserve velocity into the collapsed header")
        XCTAssertEqual(target(afterReleasingAt: 1, velocity: 0.5, projectedOffset: 200), top + 200)
        XCTAssertNil(scroll.animatedContentOffset)
        XCTAssertEqual(target(afterReleasingAt: -10, velocity: 0.5, projectedOffset: 200), top + 200)
        XCTAssertEqual(target(afterReleasingAt: inputs.headerHeight - 1, velocity: -0.001), collapsed,
                       "Micro-nudges near collapsed settle back to collapsed")
        XCTAssertEqual(target(afterReleasingAt: inputs.headerHeight - 16, velocity: -0.001), top)
        XCTAssertEqual(scroll.animatedContentOffset?.y, top)
        XCTAssertEqual(target(afterReleasingAt: 200, velocity: 0.5, projectedOffset: 300), top + 300)
        XCTAssertEqual(target(afterReleasingAt: 200, velocity: -0.5, projectedOffset: 100), top + 100)
        XCTAssertEqual(target(afterReleasingAt: 200, velocity: -0.5, projectedOffset: inputs.headerHeight - 1), top)
        XCTAssertNil(scroll.animatedContentOffset, "Returning from the queue preserves downward momentum into expanded")

        let midpoint = inputs.headerHeight / 2
        let shortProjection = inputs.headerHeight / 4
        let longProjection = inputs.headerHeight * 3 / 4
        XCTAssertEqual(target(afterReleasingAt: midpoint, velocity: 0.5, projectedOffset: shortProjection),
                       collapsed)
        XCTAssertEqual(target(afterReleasingAt: midpoint, velocity: -0.5, projectedOffset: longProjection),
                       top)
        XCTAssertEqual(target(afterReleasingAt: -10, velocity: 0.5, projectedOffset: shortProjection),
                       top + shortProjection, "Top overscroll stays with UIKit when there is no History")

        scroll.panGestureRecognizer.setTranslation(CGPoint(x: 0, y: -1), in: scroll)
        XCTAssertEqual(target(afterReleasingAt: 16, velocity: 0), collapsed)
        scroll.contentOffset.y = top + 16
        coordinator.scrollViewWillBeginDragging(scroll)
        coordinator.scrollViewDidEndDragging(scroll, willDecelerate: false)
        XCTAssertEqual(scroll.animatedContentOffset?.y, collapsed)
    }

    func testHistorySnapsAtTheRestBoundariesAndScrollsNormallyBeyondThem() async throws {
        let inputs = QueueListTestInputs()
        inputs.entries = (0..<30).map { index in
            PlayerQueueEntry(id: UUID(), queueIndex: index + 1, song: inputs.song)
        }
        inputs.history = (0..<24).map { _ in PlayerHistoryEntry(id: UUID(), song: inputs.entries[0].song) }
        let (window, host) = try mount(inputs)
        defer { window.isHidden = true }
        try await settle(host)
        let list = try XCTUnwrap(collection(in: host.view) as? NowPlayingQueueList.EdgeFadedCollectionView)
        let coordinator = try coordinator(in: host.view)
        let source = try XCTUnwrap(coordinator.dataSource)
        let rest = list.queueRestOffset
        XCTAssertEqual(list.contentOffset.y, rest, accuracy: 1)
        XCTAssertEqual(source.snapshot().sectionIdentifiers, [.history, .header, .queue])
        XCTAssertEqual(source.snapshot().itemIdentifiers(inSection: .history),
                       inputs.history.map { .history($0.id) })
        let songPath = try XCTUnwrap(source.indexPath(for: .songHeader))
        let songCell = try XCTUnwrap(list.cellForItem(at: songPath))
        XCTAssertEqual(list.convert(songCell.bounds, from: songCell).minY, list.bounds.minY, accuracy: 1)
        XCTAssertEqual(list.adjustedContentInset.top, 4, accuracy: 0.01,
                       "The artwork has four extra visible points above the unchanged pinning edge")
        XCTAssertEqual(songCell.bounds.height - list.adjustedContentInset.top, inputs.headerHeight, accuracy: 1,
                       "Extending the cell must not extend its scroll-to-collapse distance")
        XCTAssertNil(coordinator.trailingActions(at: songPath))
        let queueHeader = try XCTUnwrap(list.queueHeader)
        XCTAssertEqual(list.convert(queueHeader.bounds, from: queueHeader).minY,
                       list.convert(songCell.bounds, from: songCell).maxY, accuracy: 1)

        let scroll = QueueDragTestScrollView(matching: list)
        func release(from start: CGFloat, at offset: CGFloat, projected: CGFloat,
                     velocity: CGFloat = 0, willDecelerate: Bool = true) -> CGFloat {
            scroll.contentOffset.y = rest + start
            coordinator.scrollViewWillBeginDragging(scroll)
            scroll.contentOffset.y = rest + offset
            return scroll.release(using: coordinator, projectedY: rest + projected,
                                  velocity: velocity, willDecelerate: willDecelerate)
        }

        let readableHeight = list.bounds.height - list.adjustedContentInset.top - NowPlayingQueueList.bottomFadeHeight
        let reveal = min(list.historyHeight, max(96, readableHeight))
        let historyRest = -reveal
        XCTAssertGreaterThan(list.historyHeight - reveal, 20)
        XCTAssertEqual(release(from: 0, at: -20, projected: -30), rest)
        XCTAssertEqual(scroll.animatedContentOffset?.y, rest)
        XCTAssertEqual(release(from: 0, at: -20, projected: 200, velocity: 1.8), rest)
        XCTAssertNil(scroll.animatedContentOffset, "Forward return to Continue Playing preserves release velocity")
        XCTAssertEqual(release(from: 0, at: -25, projected: max(historyRest, -200), velocity: -0.8), rest + historyRest)
        XCTAssertNil(scroll.animatedContentOffset, "UIKit carries the downward flick into History")
        XCTAssertEqual(release(from: 0, at: -25, projected: -96, velocity: -0.75), rest + historyRest)
        XCTAssertNil(scroll.animatedContentOffset)
        XCTAssertEqual(release(from: 0, at: -96, projected: -96, velocity: -0.1), rest + historyRest)
        XCTAssertEqual(scroll.animatedContentOffset?.y, rest + historyRest)
        XCTAssertEqual(release(from: 0, at: -20, projected: -95, velocity: -0.1), rest)
        XCTAssertEqual(release(from: 0, at: -20, projected: -60, velocity: -0.2), rest)
        XCTAssertEqual(release(from: 80, at: 20, projected: -600, velocity: -2.66), rest)
        XCTAssertEqual(release(from: 300, at: 200, projected: -600, velocity: -0.5), rest)
        XCTAssertNil(scroll.animatedContentOffset, "Returning from deep in the queue preserves release velocity to Continue Playing")
        XCTAssertEqual(release(from: 0.33, at: -96, projected: -200, velocity: -0.8), rest + historyRest,
                       "Sub-point pixel rounding at Continue Playing rest still reveals History")
        XCTAssertEqual(release(from: 80, at: 0, projected: -600, velocity: -2.66), rest)
        XCTAssertEqual(release(from: 80, at: -170, projected: -600, velocity: -2.66), rest)
        XCTAssertEqual(release(from: 0, at: -170, projected: -600, velocity: -2.66), rest + min(historyRest, -600))
        XCTAssertEqual(release(from: 0, at: historyRest - 10, projected: historyRest - 20, velocity: -1.8),
                       rest + historyRest - 20)
        XCTAssertEqual(release(from: 0, at: historyRest, projected: historyRest - 200), rest + historyRest - 200)
        XCTAssertEqual(release(from: 0, at: -96, projected: -60, velocity: 0.5), rest + historyRest)
        XCTAssertEqual(release(from: 0, at: -96, projected: -97), rest + historyRest)

        // Plan A: Free stopping anywhere inside History below the -96pt boundary magnet zone.
        XCTAssertEqual(release(from: historyRest, at: -220, projected: -180, velocity: 0.2), rest - 180,
                       "Users can stop freely in mid-History to view recent history alongside Continue Playing")
        XCTAssertNil(scroll.animatedContentOffset)
        XCTAssertEqual(release(from: historyRest, at: -200, projected: -96, velocity: 0.4), rest,
                       "Upward flicks projecting into the -96pt boundary magnet snap cleanly to Continue Playing")
        XCTAssertNil(scroll.animatedContentOffset)
        XCTAssertEqual(release(from: historyRest, at: -95, projected: -90, velocity: 0.1), rest)
        XCTAssertEqual(scroll.animatedContentOffset?.y, rest)
        XCTAssertEqual(release(from: historyRest, at: -10, projected: 200, velocity: 0.4), rest)
        XCTAssertNil(scroll.animatedContentOffset, "UIKit carries the upward release into Continue Playing")
        XCTAssertEqual(release(from: historyRest, at: -10, projected: 200,
                               velocity: 1.8, willDecelerate: false), rest)
        XCTAssertEqual(scroll.animatedContentOffset?.y, rest)
        XCTAssertEqual(release(from: historyRest, at: -10, projected: -20, velocity: -0.1), rest - 96,
                       "Pulling back downward inside the boundary magnet settles at the -96pt boundary")
        XCTAssertEqual(scroll.animatedContentOffset?.y, rest - 96)
        XCTAssertEqual(release(from: historyRest, at: 200, projected: 300, velocity: 1.8), rest)
        XCTAssertEqual(scroll.animatedContentOffset?.y, rest, "An overshoot returns with the short snap")
        XCTAssertEqual(release(from: historyRest, at: 0, projected: 300, velocity: 1.8), rest)
        XCTAssertNil(scroll.animatedContentOffset)
        XCTAssertEqual(release(from: historyRest, at: 0, projected: 0, velocity: 0.1), rest)
        XCTAssertEqual(release(from: historyRest, at: -40, projected: -40), rest)
        XCTAssertEqual(release(from: historyRest, at: -60, projected: -60), rest - 96)
        XCTAssertEqual(release(from: historyRest - 20, at: historyRest - 10, projected: historyRest + 10),
                       rest + historyRest + 10)
        XCTAssertEqual(release(from: historyRest, at: historyRest - 10, projected: historyRest - 20),
                       rest + historyRest - 20)
        XCTAssertEqual(release(from: 0, at: 1, projected: 120, velocity: 0.5), rest + 120)
        XCTAssertEqual(release(from: 80, at: 20, projected: -100), rest)

        list.contentOffset.y = 80
        try await settle(host)
        let header = try XCTUnwrap(list.historyHeader)
        // History still pins at the original screen edge, below the extra artwork viewport.
        XCTAssertEqual(list.convert(header.bounds, from: header).minY,
                       list.bounds.minY + list.adjustedContentInset.top, accuracy: 1)
        let path = try XCTUnwrap(list.indexPathsForVisibleItems.first {
            if case .history = source.itemIdentifier(for: $0) { return true }
            return false
        })
        let row = try XCTUnwrap(list.cellForItem(at: path) as? UICollectionViewListCell)
        XCTAssertTrue(row.accessories.isEmpty)
        XCTAssertNil(coordinator.trailingActions(at: path))
        inputs.history = []
        try await settle(host)
        XCTAssertEqual(source.snapshot().sectionIdentifiers, [.header, .queue])
        XCTAssertEqual(list.contentOffset.y, -list.adjustedContentInset.top, accuracy: 1)
    }

    func testHistoryTrackChangesKeepBrowsingAndHistorySelectionReturnsToQueue() async throws {
        let inputs = QueueListTestInputs()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try PlayerTestFixtures.silentAudio(at: directory.appendingPathComponent("history.wav"), seconds: 10)
        let engine = LocalPlaybackEngine(activateSession: { true })
        let model = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false, makeAudioEngine: { engine })
        defer { model.shutdownPlayback() }
        model.configurePlayback(resolveURL: { _ in url }, persistenceURL: directory.appendingPathComponent("queue.json"))
        let songs = PlayerTestFixtures.owner(tracks: inputs.entries.map(\.song)).queue
        model.play(songs, from: "Album", shuffled: false)
        for _ in 0..<100 where !engine.isPlaybackConfirmed {
            try await Task.sleep(for: .milliseconds(20))
        }
        model.select(1)
        inputs.player = PlayerState(model: model)
        let selectableHistoryEntry = try XCTUnwrap(inputs.player.playbackHistory.first)
        inputs.history = (0..<24).map { _ in PlayerHistoryEntry(id: UUID(), song: inputs.song) }
        let (window, host) = try mount(inputs)
        defer { window.isHidden = true }
        try await settle(host)
        let list = try XCTUnwrap(collection(in: host.view) as? NowPlayingQueueList.EdgeFadedCollectionView)
        let coordinator = try coordinator(in: host.view)
        let source = try XCTUnwrap(coordinator.dataSource)
        var update = try XCTUnwrap(coordinator.latest)

        let olderOffset: CGFloat = 80
        list.contentOffset.y = olderOffset
        update.trackTransitionKey = "next-while-browsing"
        update.history.append(PlayerHistoryEntry(id: UUID(), song: inputs.song))
        coordinator.update(with: update)
        try await settle(host)
        XCTAssertEqual(list.contentOffset.y, olderOffset, accuracy: 1)

        let readableHeight = list.bounds.height - list.adjustedContentInset.top - NowPlayingQueueList.bottomFadeHeight
        let latestOffset = list.queueRestOffset - max(160, readableHeight)
        list.contentOffset.y = latestOffset
        update.trackTransitionKey = "next-at-history-rest"
        update.history.append(selectableHistoryEntry)
        coordinator.update(with: update)
        XCTAssertEqual(source.snapshot().itemIdentifiers(inSection: .history).last, .history(selectableHistoryEntry.id))
        try await settle(host)
        XCTAssertEqual(list.contentOffset.y, latestOffset + NowPlayingQueueList.historyRowHeight, accuracy: 1)
        XCTAssertLessThan(list.contentOffset.y, list.queueRestOffset)

        let midHistoryOffset = list.queueRestOffset - 292
        list.contentOffset.y = midHistoryOffset
        list.layoutIfNeeded()
        let songHeaderPath = try XCTUnwrap(source.indexPath(for: .songHeader))
        let songCellBefore = try XCTUnwrap(list.cellForItem(at: songHeaderPath))
        let screenYBefore = songCellBefore.frame.minY - list.contentOffset.y
        update.trackTransitionKey = "next-at-mid-history"
        update.history.append(PlayerHistoryEntry(id: UUID(), song: inputs.song))
        coordinator.update(with: update)
        let songCellImmediate = try XCTUnwrap(list.cellForItem(at: songHeaderPath))
        XCTAssertNil(songCellImmediate.layer.animation(forKey: "position"),
                     "SongHeader must not animate its layout position when a history row is appended")
        let screenYImmediate = songCellImmediate.frame.minY - list.contentOffset.y
        XCTAssertEqual(screenYImmediate, screenYBefore, accuracy: 0.5,
                       "SongHeader must not jump upward and slide back down when a history row is appended")
        func verifyMaskAnimations(in layer: CALayer) {
            if let mask = layer.mask,
               let anim = mask.animation(forKey: "trackTransitionMask") as? CABasicAnimation {
                XCTAssertTrue(anim.isAdditive, "Scroll updates must be able to move the mask's base frame")
                XCTAssertEqual((anim.fromValue as? NSValue)?.cgPointValue.x, 0)
                XCTAssertEqual((anim.toValue as? NSValue)?.cgPointValue, .zero)
            }
            for sub in layer.sublayers ?? [] { verifyMaskAnimations(in: sub) }
        }
        for cell in list.visibleCells { verifyMaskAnimations(in: cell.layer) }

        coordinator.playFromHistory(selectableHistoryEntry.id)
        XCTAssertEqual(inputs.player.currentTrack?.id, selectableHistoryEntry.song.id)
        // A coalesced presentation can carry a different key from the one observed at the tap.
        update.trackTransitionKey = "coalesced-after-history-selection"
        update.history.append(PlayerHistoryEntry(id: UUID(), song: inputs.song))
        coordinator.update(with: update)
        XCTAssertTrue(list.isScrollAnimating)
        XCTAssertLessThan(list.contentOffset.y, list.queueRestOffset)
        for _ in 0..<40 where list.isScrollAnimating {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(list.contentOffset.y, list.queueRestOffset, accuracy: 1)

        list.contentOffset.y = list.queueRestOffset - 160
        XCTAssertFalse(inputs.player.playbackHistory.isEmpty)
        coordinator.clearHistory(for: inputs.player)
        XCTAssertTrue(inputs.player.playbackHistory.isEmpty)
        inputs.history = []
        update.history = []
        coordinator.update(with: update)
        XCTAssertTrue(list.isScrollAnimating)
        XCTAssertLessThan(list.contentOffset.y, list.queueRestOffset)
        XCTAssertTrue(source.snapshot().sectionIdentifiers.contains(.history))
        for _ in 0..<40 where list.isScrollAnimating {
            try await Task.sleep(for: .milliseconds(25))
        }
        try await settle(host)
        XCTAssertEqual(source.snapshot().sectionIdentifiers, [.header, .queue])
        XCTAssertEqual(list.contentOffset.y, list.queueRestOffset, accuracy: 1)

        let deepQueueOffset = list.queueRestOffset + inputs.headerHeight + 120
        list.contentOffset.y = deepQueueOffset
        update.trackTransitionKey = "passive-switch-while-browsing-queue"
        update.songHeader = NowPlayingQueueSongHeader(
            song: PlayerTrack(id: "next-current", title: "Next", artists: "Artist", albumTitle: "Album", coverURL: nil, duration: 60),
            artworkNamespace: update.songHeader.artworkNamespace
        )
        coordinator.update(with: update)
        XCTAssertEqual(list.contentOffset.y, deepQueueOffset, accuracy: 1,
                       "A track change while browsing deep in the queue must preserve the user's scroll position")
        await model.flushQueuePersistence()
    }

    func testHistoryRevealThresholdControlsLiveFeedbackAndRelease() async throws {
        let inputs = QueueListTestInputs()
        let (window, host) = try mount(inputs)
        defer { window.isHidden = true }
        try await settle(host)
        let coordinator = try coordinator(in: host.view)
        let list = try XCTUnwrap(collection(in: host.view) as? NowPlayingQueueList.EdgeFadedCollectionView)
        let scroll = QueueDragTestScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        scroll.contentInset.top = 8
        scroll.contentSize.height = 800

        for (rowCount, threshold): (Int, CGFloat) in [(10, 96), (2, 96), (1, 96)] {
            inputs.history = (0..<rowCount).map { _ in PlayerHistoryEntry(id: UUID(), song: inputs.song) }
            try await settle(host)
            let rest = list.historyHeight - scroll.adjustedContentInset.top
            var feedbackCount = 0
            coordinator.scrollFeedbackHandler = { feedbackCount += 1 }

            func didScroll(revealing distance: CGFloat) {
                scroll.contentOffset.y = rest - distance
                coordinator.scrollViewDidScroll(scroll)
            }

            func beginDrag(revealing distance: CGFloat = 0) {
                didScroll(revealing: distance)
                coordinator.scrollViewWillBeginDragging(scroll)
                scroll.isSimulatingDrag = true
            }

            func release(projectedReveal: CGFloat, velocity: CGFloat = 0) -> CGFloat {
                scroll.release(using: coordinator, projectedY: rest - projectedReveal, velocity: velocity)
            }

            let reveal = min(list.historyHeight, 312)
            let historyRest = rest - reveal
            beginDrag()
            didScroll(revealing: threshold - 1)
            XCTAssertEqual(feedbackCount, 0)
            XCTAssertEqual(release(projectedReveal: threshold, velocity: -0.8), historyRest)
            XCTAssertNil(scroll.animatedContentOffset)
            didScroll(revealing: threshold)
            XCTAssertEqual(feedbackCount, 0, "Scroll updates after release are silent")

            beginDrag()
            didScroll(revealing: threshold)
            XCTAssertEqual(feedbackCount, 1, "Feedback fires at the threshold while dragging")
            didScroll(revealing: threshold - 1)
            didScroll(revealing: threshold + 1)
            XCTAssertEqual(feedbackCount, 2, "Pulling back and re-crossing the threshold fires reversible feedback")
            XCTAssertEqual(release(projectedReveal: threshold - 1, velocity: 0.001), historyRest)

            beginDrag()
            didScroll(revealing: threshold)
            XCTAssertEqual(feedbackCount, 3)
            didScroll(revealing: threshold - 1)
            XCTAssertEqual(release(projectedReveal: threshold), rest, "Release uses the current distance")

            beginDrag()
            didScroll(revealing: threshold)
            XCTAssertEqual(feedbackCount, 4)
            XCTAssertEqual(release(projectedReveal: threshold), historyRest, "A stationary release settles in History")

            beginDrag()
            didScroll(revealing: threshold)
            scroll.isSimulatingDrag = false
            coordinator.scrollViewDidEndDragging(scroll, willDecelerate: false)
            let animatedTarget = reveal == threshold ? nil : CGPoint(x: 0, y: historyRest)
            XCTAssertEqual(scroll.animatedContentOffset, animatedTarget)
            scroll.animatedContentOffset = nil

            beginDrag()
            didScroll(revealing: threshold)
            didScroll(revealing: threshold - 1)
            var projected = CGPoint(x: 0, y: historyRest)
            coordinator.scrollViewWillEndDragging(scroll, withVelocity: .zero, targetContentOffset: &projected)
            XCTAssertEqual(projected.y, scroll.contentOffset.y)
            scroll.isSimulatingDrag = false
            coordinator.scrollViewDidEndDragging(scroll, willDecelerate: false)
            XCTAssertEqual(scroll.animatedContentOffset, CGPoint(x: 0, y: rest))
            scroll.animatedContentOffset = nil

            let exitThreshold = min(reveal, 96)
            beginDrag(revealing: reveal)
            didScroll(revealing: exitThreshold + 1)
            XCTAssertEqual(feedbackCount, 6)
            XCTAssertEqual(release(projectedReveal: -120, velocity: 0.5), rest)

            beginDrag(revealing: reveal)
            didScroll(revealing: exitThreshold)
            XCTAssertEqual(feedbackCount, 7, "Entering the 96pt boundary magnet zone triggers return feedback")
            didScroll(revealing: exitThreshold + 1)
            didScroll(revealing: exitThreshold)
            XCTAssertEqual(feedbackCount, 8, "Re-entering the boundary magnet zone fires feedback again")
            XCTAssertEqual(release(projectedReveal: exitThreshold - 1, velocity: 0.1), rest)
            didScroll(revealing: 0)
            XCTAssertEqual(feedbackCount, 8)

            beginDrag()
            didScroll(revealing: threshold - 1)
            XCTAssertEqual(scroll.release(using: coordinator, projectedY: rest - threshold,
                                          velocity: -1.8, willDecelerate: false), historyRest)
            XCTAssertEqual(scroll.animatedContentOffset?.y, historyRest)
        }
    }

    func testArtworkTransitionKeepsTheOutgoingQueueAndReturnsToTheCurrentSong() async throws {
        let inputs = QueueListTestInputs()
        inputs.history = (0..<24).map { _ in PlayerHistoryEntry(id: UUID(), song: inputs.song) }
        let (window, host) = try mount(inputs)
        defer { window.isHidden = true }
        try await settle(host)
        let list = try XCTUnwrap(collection(in: host.view) as? NowPlayingQueueList.EdgeFadedCollectionView)
        let coordinator = try coordinator(in: host.view)
        let rest = list.queueRestOffset
        XCTAssertGreaterThan(rest, list.bounds.height)

        for y in [-list.adjustedContentInset.top, rest + 24, rest + NowPlayingSongHeader.referenceHeight * 2] {
            list.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            coordinator.preparePageTransition(returningToQueue: false)
            XCTAssertEqual(list.contentOffset.y, y, accuracy: 0.5)
            coordinator.preparePageTransition(returningToQueue: true)
            XCTAssertEqual(list.contentOffset.y, rest, accuracy: 0.5)
            XCTAssertFalse(list.isScrollAnimating)
        }
    }

    func testPopupDismissalAcceptsEitherMarginAtAnyQueueOffset() async throws {
        let inputs = QueueListTestInputs()
        inputs.history = [PlayerHistoryEntry(id: UUID(), song: inputs.entries[0].song)]
        let (window, host) = try mount(inputs)
        defer { window.isHidden = true }
        try await settle(host)
        let list = try XCTUnwrap(collection(in: host.view) as? NowPlayingQueueList.EdgeFadedCollectionView)
        let container = try XCTUnwrap(list.superview as? NowPlayingQueueList.OverflowContainer)
        let rowContent = UIView()
        list.addSubview(rowContent)

        let popup = PlayerPopupInteractionDelegate()
        let popupPan = UIPanGestureRecognizer()
        let queuePan = list.panGestureRecognizer
        let top = -list.adjustedContentInset.top
        func canHandOffToPopup() -> Bool {
            popup.gestureRecognizer(popupPan, shouldRecognizeSimultaneouslyWith: queuePan)
        }
        func assertMarginsAllowDismissal() {
            for x in [container.bounds.minX - 8, container.bounds.maxX + 8] {
                let hit = container.hitTest(CGPoint(x: x, y: container.bounds.midY), with: nil)
                XCTAssertTrue(hit === container)
                XCTAssertTrue(popup.shouldReceiveTouch(in: hit))
                XCTAssertFalse(canHandOffToPopup(), "The margin goes directly to the popup pan")
            }
        }

        XCTAssertGreaterThan(list.queueRestOffset, top)
        assertMarginsAllowDismissal()
        XCTAssertFalse(popup.shouldReceiveTouch(in: rowContent))
        XCTAssertFalse(canHandOffToPopup(), "Continue Playing has History above it")

        list.contentOffset.y = top + 10
        assertMarginsAllowDismissal()
        XCTAssertFalse(popup.shouldReceiveTouch(in: rowContent))
        list.contentOffset.y = top
        XCTAssertFalse(canHandOffToPopup(), "The same drag stays with the list when it reaches the top")
        XCTAssertFalse(popup.shouldReceiveTouch(in: rowContent))
        XCTAssertTrue(canHandOffToPopup(), "A fresh drag at the top of History can dismiss")
        assertMarginsAllowDismissal()

        inputs.history = []
        try await settle(host)
        XCTAssertEqual(list.contentOffset.y, -list.adjustedContentInset.top, accuracy: 0.01)
        XCTAssertFalse(popup.shouldReceiveTouch(in: rowContent))
        XCTAssertTrue(canHandOffToPopup(), "Continue Playing is the top when History is empty")
        assertMarginsAllowDismissal()
        list.contentOffset.y = list.queueRestOffset + inputs.headerHeight
        assertMarginsAllowDismissal()

        XCTAssertTrue(popup.shouldReceiveTouch(in: host.view))
        XCTAssertFalse(canHandOffToPopup())
    }

    func testCollapseFeedbackFiresOnFirstUpwardMovementOncePerDrag() async throws {
        let inputs = QueueListTestInputs()
        let (window, host) = try mount(inputs)
        defer { window.isHidden = true }
        try await settle(host)
        let coordinator = try coordinator(in: host.view)
        let scroll = QueueDragTestScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        scroll.contentInset.top = NowPlayingQueueList.modeControlsHeight
        scroll.contentSize.height = 800
        let top = -scroll.adjustedContentInset.top
        var feedbackCount = 0
        coordinator.scrollFeedbackHandler = { feedbackCount += 1 }

        func didScroll(to offset: CGFloat) {
            scroll.contentOffset.y = top + offset
            coordinator.scrollViewDidScroll(scroll)
        }

        didScroll(to: 0)
        coordinator.scrollViewWillBeginDragging(scroll)
        scroll.isSimulatingDrag = true
        didScroll(to: -5)
        didScroll(to: 0)
        XCTAssertEqual(feedbackCount, 0, "Returning from top overscroll does not collapse the header")
        didScroll(to: 1)
        didScroll(to: 5)
        XCTAssertEqual(feedbackCount, 0, "Touch-down micro-jitter within the 6pt deadzone is silent")
        didScroll(to: 7)
        XCTAssertEqual(feedbackCount, 1, "Crossing the 6pt collapse deadzone triggers feedback once per drag")
        didScroll(to: 0)
        didScroll(to: 16)
        XCTAssertEqual(feedbackCount, 1)

        XCTAssertEqual(scroll.release(using: coordinator, projectedY: scroll.contentOffset.y, velocity: 0.1),
                       top + inputs.headerHeight)
        didScroll(to: inputs.headerHeight)
        XCTAssertEqual(feedbackCount, 1, "The snap does not trigger feedback again")

        coordinator.scrollViewWillBeginDragging(scroll)
        scroll.isSimulatingDrag = true
        didScroll(to: 100)
        didScroll(to: 80)
        didScroll(to: inputs.headerHeight - 1)
        XCTAssertEqual(feedbackCount, 1, "Scrolling past the header or revealing it is silent")
        didScroll(to: 100)
        XCTAssertEqual(feedbackCount, 2, "A new drag can collapse the header even in one scroll update")
    }

    func testEdgeMasksFollowChangingCompositingLayersWithoutReplacingCustomMasks() throws {
        let list = NowPlayingQueueList.EdgeFadedCollectionView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 400),
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        let cell = UICollectionViewCell(frame: CGRect(x: 0, y: 2, width: 320, height: 60))
        list.addSubview(cell)
        let group = CALayer(), vibrant = CALayer(), nested = CALayer(), plain = CALayer()
        let custom = CALayer(), customChild = CALayer(), customMask = CAShapeLayer()
        cell.contentView.layer.addSublayer(group)
        group.addSublayer(vibrant)
        group.addSublayer(plain)
        group.addSublayer(custom)
        vibrant.addSublayer(nested)
        custom.addSublayer(customChild)
        for layer in [group, vibrant, nested, plain, custom, customChild] { layer.frame = cell.bounds }
        vibrant.compositingFilter = "plusL"
        customChild.compositingFilter = "plusL"
        custom.mask = customMask

        list.updateEdgeMask(for: cell)
        let vibrantMask = try XCTUnwrap(vibrant.mask as? CAGradientLayer)
        XCTAssertNil(cell.layer.mask, "An ancestor mask would isolate the additive text layers")
        XCTAssertNil(group.mask)
        XCTAssertNil(nested.mask, "A compositing subtree must be faded only once")
        XCTAssertTrue(plain.mask is CAGradientLayer)
        XCTAssertTrue(custom.mask === customMask)
        XCTAssertTrue(customChild.mask is CAGradientLayer)

        list.updateEdgeMask(for: cell)
        XCTAssertTrue(vibrant.mask === vibrantMask, "Unchanged layer targets reuse their gradient")

        vibrant.compositingFilter = nil
        customChild.compositingFilter = nil
        list.updateEdgeMask(for: cell)
        XCTAssertTrue(cell.layer.mask is CAGradientLayer)
        XCTAssertNil(vibrant.mask)
        XCTAssertNil(plain.mask)
        XCTAssertNil(customChild.mask)
        XCTAssertTrue(custom.mask === customMask)

        cell.frame.origin.y = 100
        list.updateEdgeMask(for: cell)
        XCTAssertNil(cell.layer.mask, "A row inside the unfaded viewport releases its edge mask")
        XCTAssertTrue(custom.mask === customMask)
    }

    func testEdgeMasksKeepRoundedArtworkCoveredAcrossSublayerReplacement() throws {
        let list = NowPlayingQueueList.EdgeFadedCollectionView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 400),
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        let cell = NowPlayingQueueList.EdgeFadedListCell(frame: CGRect(x: 0, y: 2, width: 320, height: 60))
        cell.edgeFadeCollectionView = list
        list.addSubview(cell)

        let rowContainer = CALayer()
        let artwork = NowPlayingQueueArtworkSurface.Surface.EdgeFadeLayer()
        let placeholderArtwork = CALayer()
        let vibrantArtist = CALayer()
        rowContainer.frame = cell.bounds
        artwork.frame = CGRect(x: 0, y: 6, width: 48, height: 48)
        placeholderArtwork.frame = artwork.bounds
        vibrantArtist.frame = CGRect(x: 60, y: 30, width: 120, height: 18)
        vibrantArtist.compositingFilter = "plusL"
        cell.contentView.layer.addSublayer(rowContainer)
        rowContainer.addSublayer(artwork)
        artwork.addSublayer(placeholderArtwork)
        rowContainer.addSublayer(vibrantArtist)

        list.updateEdgeMask(for: cell)
        let edgeMask = try XCTUnwrap(artwork.mask as? CAGradientLayer)
        XCTAssertNil(cell.layer.mask)
        XCTAssertTrue(vibrantArtist.mask is CAGradientLayer)

        placeholderArtwork.removeFromSuperlayer()
        let loadedArtwork = CALayer()
        loadedArtwork.frame = artwork.bounds
        let relativeMask = CAShapeLayer()
        relativeMask.frame = loadedArtwork.bounds
        relativeMask.path = UIBezierPath(roundedRect: loadedArtwork.bounds, cornerRadius: 6).cgPath
        loadedArtwork.mask = relativeMask
        artwork.addSublayer(loadedArtwork)

        // An image can arrive with no cell layout or scroll update.
        XCTAssertTrue(loadedArtwork.superlayer?.mask === edgeMask)
        XCTAssertTrue(loadedArtwork.mask === relativeMask)
        XCTAssertEqual(artwork.convert(edgeMask.frame, to: list.layer).minY, list.bounds.minY, accuracy: 0.01)
        XCTAssertTrue(vibrantArtist.mask is CAGradientLayer)
    }

    func testAsyncQueueArtworkStaysClippedAtPinnedHeader() async throws {
        let inputs = QueueListTestInputs()
        let url = try XCTUnwrap(URL(string: "https://example.invalid/queue-artwork"))
        inputs.entries = (0..<12).map { index in
            PlayerQueueEntry(id: UUID(), queueIndex: index + 1, song: PlayerTrack(
                id: "queue-\(index)", title: "Song", artists: "Artist", albumTitle: "Album",
                coverURL: index == 0 ? url : nil, duration: 60
            ))
        }
        let request = expectation(description: "Queue artwork decode started")
        request.assertForOverFulfill = false
        let (images, loader) = AsyncStream<UIImage>.makeStream()
        defer { loader.finish() }
        inputs.services = PlayerServices(actions: inputs.actions, lyrics: inputs.library.source,
            artwork: PlayerArtworkProvider(cached: { _ in nil }, load: { _ in
                request.fulfill()
                var iterator = images.makeAsyncIterator()
                guard let image = await iterator.next() else { throw CancellationError() }
                return image
            }))
        let (window, host) = try mount(inputs)
        defer { window.isHidden = true }
        await fulfillment(of: [request], timeout: 3)
        try await settle(host)

        let list = try XCTUnwrap(collection(in: host.view) as? NowPlayingQueueList.EdgeFadedCollectionView)
        let source = try XCTUnwrap((list.delegate as? Coordinator)?.dataSource)
        let path = try XCTUnwrap(source.indexPath(for: .track(inputs.entries[0].id)))
        // Leave part of the first row under the pinned title and part in the readable area.
        list.contentOffset.y = list.queueRestOffset + inputs.headerHeight + 18
        try await settle(host)
        let cell = try XCTUnwrap(list.cellForItem(at: path))
        func artwork(in view: UIView) -> NowPlayingQueueArtworkSurface.Surface? {
            (view as? NowPlayingQueueArtworkSurface.Surface) ?? view.subviews.lazy.compactMap(artwork).first
        }
        let surface = try XCTUnwrap(artwork(in: cell))
        let mask = try XCTUnwrap(surface.layer.mask as? CAGradientLayer)
        let header = try XCTUnwrap(list.queueHeader)
        let coveredHeight = list.convert(header.bounds, from: header).maxY
            - list.convert(surface.bounds, from: surface).minY
        XCTAssertGreaterThan(coveredHeight, 2)
        XCTAssertLessThan(coveredHeight + NowPlayingQueueList.topFadeHeight, surface.bounds.height - 5)
        let offset = list.contentOffset

        func isRed(x: CGFloat, y: CGFloat) -> Bool {
            let point = surface.convert(CGPoint(x: x, y: y), to: host.view)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            let snapshot = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { _ in
                host.view.drawHierarchy(in: host.view.bounds.offsetBy(dx: -point.x, dy: -point.y), afterScreenUpdates: true)
            }
            guard let image = snapshot.cgImage else { return false }
            var pixel = [UInt8](repeating: 0, count: 4)
            return pixel.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                              bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return bytes[0] > 220 && bytes[1] < 35 && bytes[2] < 35
            }
        }
        let middleX = surface.bounds.midX
        let readableY = surface.bounds.maxY - 5
        XCTAssertFalse(isRed(x: middleX, y: readableY))
        loader.yield(UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        })
        for _ in 0..<10 {
            try await settle(host)
            if isRed(x: middleX, y: readableY) { break }
        }
        XCTAssertTrue(isRed(x: middleX, y: readableY))
        XCTAssertFalse(isRed(x: middleX, y: 1))
        XCTAssertFalse(isRed(x: 0, y: surface.bounds.maxY - 1))
        XCTAssertTrue(artwork(in: cell) === surface)
        XCTAssertTrue(surface.layer.mask === mask)
        XCTAssertEqual(list.contentOffset, offset)
    }

    func testEdgeMasksRebaseAtBothEdgesDuringTrackTransitionAndClearOnReuse() throws {
        let list = NowPlayingQueueList.EdgeFadedCollectionView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 400),
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        list.contentSize.height = 900
        let cell = NowPlayingQueueList.EdgeFadedListCell(frame: CGRect(x: 0, y: 300, width: 320, height: 60))
        cell.edgeFadeCollectionView = list
        list.addSubview(cell)
        let artwork = NowPlayingQueueArtworkSurface.Surface.EdgeFadeLayer()
        artwork.frame = CGRect(x: 0, y: 6, width: 48, height: 48)
        cell.contentView.layer.addSublayer(artwork)

        cell.isAnimatingTrackTransition = true
        let spring = CASpringAnimation(keyPath: "transform")
        spring.duration = 0.28
        spring.beginTime = CACurrentMediaTime()
        list.animateTransitionEdgeMask(for: cell, deltaY: 56, matching: spring)
        let mask = try XCTUnwrap(artwork.mask as? CAGradientLayer)
        let animation = try XCTUnwrap(mask.animation(forKey: "trackTransitionMask") as? CASpringAnimation)
        XCTAssertTrue(animation.isAdditive)
        XCTAssertEqual((animation.fromValue as? NSValue)?.cgPointValue, CGPoint(x: 0, y: -56))
        XCTAssertEqual((animation.toValue as? NSValue)?.cgPointValue, .zero)
        XCTAssertEqual(animation.duration, spring.duration)

        for offset: CGFloat in [0, 315] {
            list.contentOffset.y = offset
            list.updateEdgeMask(for: cell)
            XCTAssertTrue(artwork.mask === mask)
            let maskFrame = artwork.convert(mask.frame, to: list.layer)
            XCTAssertEqual(maskFrame.minY, offset, accuracy: 0.01)
            XCTAssertEqual(maskFrame.maxY, offset + list.bounds.height, accuracy: 0.01)
            XCTAssertEqual(mask.animation(forKey: "trackTransitionMask")?.beginTime, animation.beginTime)
        }

        cell.transform = CGAffineTransform(translationX: 0, y: 56)
        cell.alpha = 0.35
        cell.prepareForReuse()
        XCTAssertNil(artwork.mask)
        XCTAssertFalse(cell.isAnimatingTrackTransition)
        XCTAssertEqual(cell.transform, .identity)
        XCTAssertEqual(cell.alpha, 1)

        list.updateEdgeMask(for: cell)
        let reusedMask = try XCTUnwrap(artwork.mask as? CAGradientLayer)
        XCTAssertNil(reusedMask.animation(forKey: "trackTransitionMask"))
        XCTAssertEqual(artwork.convert(reusedMask.frame, to: list.layer).minY, list.bounds.minY, accuracy: 0.01)
    }
}

private final class QueueDragTestPanGestureRecognizer: UIPanGestureRecognizer {
    private var simulatedTranslation: CGPoint = .zero

    override func setTranslation(_ translation: CGPoint, in view: UIView?) {
        simulatedTranslation = translation
        super.setTranslation(translation, in: view)
    }

    override func translation(in view: UIView?) -> CGPoint {
        state == .possible ? simulatedTranslation : super.translation(in: view)
    }
}

private final class QueueDragTestScrollView: UIScrollView {
    var isSimulatingDrag = false
    var animatedContentOffset: CGPoint?
    private let simulatedPan = QueueDragTestPanGestureRecognizer()
    override var isDragging: Bool { isSimulatingDrag }
    override var panGestureRecognizer: UIPanGestureRecognizer { simulatedPan }

    convenience init(matching scrollView: UIScrollView) {
        self.init(frame: scrollView.bounds)
        contentSize = scrollView.contentSize
        contentInset = scrollView.adjustedContentInset
    }

    func release(using coordinator: NowPlayingQueueList.Coordinator, projectedY: CGFloat,
                 velocity: CGFloat, willDecelerate: Bool = true) -> CGFloat {
        animatedContentOffset = nil
        let releaseOffset = contentOffset
        var target = CGPoint(x: releaseOffset.x, y: projectedY)
        coordinator.scrollViewWillEndDragging(self, withVelocity: CGPoint(x: 0, y: velocity),
                                              targetContentOffset: &target)
        XCTAssertEqual(contentOffset, releaseOffset)
        XCTAssertNil(animatedContentOffset)
        isSimulatingDrag = false
        coordinator.scrollViewDidEndDragging(self, willDecelerate: willDecelerate)
        XCTAssertEqual(contentOffset, releaseOffset, "Release must not jump before the snap animation")
        if let animatedContentOffset {
            if willDecelerate {
                XCTAssertEqual(target, releaseOffset, "The short snap takes over at the release offset")
            }
            return animatedContentOffset.y
        }
        return target.y
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        if animated {
            animatedContentOffset = contentOffset
        } else {
            super.setContentOffset(contentOffset, animated: false)
        }
    }
}

@MainActor @Observable
private final class QueueListTestInputs {
    var revision: UInt64 = 0
    var entries: [PlayerQueueEntry] = ["a", "b"].enumerated().map { index, id in
        PlayerQueueEntry(id: UUID(), queueIndex: index + 1,
                           song: PlayerTrack(id: id, title: id, artists: "Artist", albumTitle: "Album", coverURL: nil, duration: 60))
    } { didSet { revision &+= 1 } }
    let song = PlayerTrack(id: "current", title: "Current song", artists: "Artist",
                           albumTitle: "Album", coverURL: nil, duration: 60)
    var headerHeight: CGFloat = NowPlayingQueuePage.songHeaderHeight
    var history: [PlayerHistoryEntry] = []
    var subtitle = "Next songs"
    var visualsActive = true
    var actions = PlayerTestFixtures.actions()
    var player = PlayerTestFixtures.state(tracks: [])
    var onMove: (IndexSet, Int) -> Void = { _, _ in }
    @ObservationIgnored var artworkRequests: [String] = []
    let library = PlayerTestFixtures.library()
    @ObservationIgnored lazy var services = NeoMusicPlayerServices.make(actions: actions, library: library,
        prepareArtwork: { [weak self] in self?.artworkRequests.append($0) })
}

private struct QueueListTestView: View {
    @Namespace private var artworkNamespace
    let inputs: QueueListTestInputs
    var body: some View {
        NowPlayingQueueList(entries: inputs.entries,
                            version: PlayerQueueVersion(revision: inputs.revision, index: 0, repeatMode: .all),
                            history: inputs.history,
                            subtitle: inputs.subtitle,
                            songHeader: NowPlayingQueueSongHeader(song: inputs.song, artworkNamespace: artworkNamespace),
                            headerHeight: inputs.headerHeight, horizontalInset: 32,
                            onPlay: { _ in }, onMove: inputs.onMove, onScroll: { _ in })
            .environment(inputs.player)
            .environment(inputs.actions)
            .environment(inputs.services)
            .environment(\.playerVisualsActive, inputs.visualsActive)
            .environment(\.artworkLoadAction, ArtworkLoadAction(handler: { inputs.artworkRequests.append($0) }))
    }
}
