import XCTest
import SwiftUI
@testable import NeoMusic

final class PlaybackQueueV2Tests: XCTestCase {
    func testRepeatedFilesKeepIndependentEntryIdentity() {
        var state = PlaybackQueueState(ids: ["a", "a", "b"])
        let original = state.entryIDs!
        state.removeUpcoming(original[1])
        XCTAssertEqual(state.ids, ["a", "b"])
        XCTAssertEqual(state.entryIDs, [original[0], original[2]])
    }
    func testShuffleRestoresOriginalOrderAndCurrentEntry() {
        var state = PlaybackQueueState(ids: ["a", "b", "a", "c"])
        state.index = 2
        let entries = state.entryIDs!
        state.setShuffle(true)
        XCTAssertEqual(state.entryIDs![state.index], entries[2])
        state.setShuffle(false)
        XCTAssertEqual(state.entryIDs, entries)
        XCTAssertEqual(state.index, 2)
    }
    func testLegacyRecordWithoutEntryIDsDecodesAndNormalizes() throws {
        let data = Data(#"{"ids":["a","a"],"index":99,"elapsed":12,"repeatMode":"all","shuffled":false}"#.utf8)
        var state = try JSONDecoder().decode(PlaybackQueueState.self, from: data)
        state.normalize()
        XCTAssertEqual(state.index, 1)
        XCTAssertEqual(Set(state.entryIDs!).count, 2)
        XCTAssertEqual(state.elapsed, 12)
    }
    func testUpcomingMovePreservesCurrentAndManualMarker() {
        var state = PlaybackQueueState(ids: ["a", "b", "c"])
        state.append("d", next: false)
        let ids = state.entryIDs!
        state.moveUpcoming(ids[3], before: ids[1])
        XCTAssertEqual(state.ids, ["a", "d", "b", "c"])
        XCTAssertEqual(state.userQueuedIDs, [ids[3]])
        state.moveUpcoming(ids[0], before: ids[2])
        XCTAssertEqual(state.ids.first, "a")
    }
}

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
            // The real cell provider clears this handler when it configures a cell.
            // UIKit's current snapshot does not retain already-applied reconfigure marks.
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
        // The Swift accessory is a value; bridged object identity is not its contract.
        // Read the style through the public Objective-C accessory properties.
        let accessories = try XCTUnwrap(cell.value(forKey: "accessories") as? [NSObject])
        XCTAssertEqual(accessories.count, 1)
        let accessory = try XCTUnwrap(accessories.first)
        // UICellAccessoryDisplayedAlways is 0 in UIKit's public UICellAccessory.h.
        XCTAssertEqual(accessory.value(forKey: "displayedState") as? NSNumber, NSNumber(value: 0))
        XCTAssertEqual(accessory.value(forKey: "tintColor") as? UIColor, UIColor.white.withAlphaComponent(0.45))
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
        XCTAssertEqual(reconfiguredCells(marked), [.spacer])
        marked = try markConfigurations(in: host.view, source: source)
        inputs.subtitle = "Updated subtitle"
        try await settle(host)
        XCTAssertEqual(reconfiguredCells(marked), [.title])

        marked = try markConfigurations(in: host.view, source: source)
        inputs.visualsActive = false
        try await settle(host)
        XCTAssertTrue(reconfiguredCells(marked).isEmpty)
        marked = try markConfigurations(in: host.view, source: source)
        inputs.actions = PlayerTestFixtures.actions()
        try await settle(host)
        XCTAssertEqual(reconfiguredCells(marked), Set(inputs.entries.map { Coordinator.Item.track($0.id) }))
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
        inputs.entries[0] = UpcomingQueueEntry(id: a.id, queueIndex: 7,
            song: ReferenceTrack(id: a.song.id, title: "Updated title", artists: a.song.artists,
                                 albumTitle: a.song.albumTitle, coverURL: nil, duration: a.song.duration))
        try await settle(host)
        XCTAssertEqual(reconfiguredCells(marked), [.track(a.id)])
        XCTAssertEqual(coordinator.snapshotApplicationCount, applications)
        try assertReorderAccessory(in: trackCell)
        XCTAssertFalse(coordinator.update(with: try XCTUnwrap(coordinator.latest)))

        // UIKit can already show a reordered snapshot while the owner still has
        // the old order. An unchanged owner input must restore the actual snapshot.
        var nativeOrder = source.snapshot()
        nativeOrder.moveItem(.track(b.id), beforeItem: .track(a.id))
        await withCheckedContinuation { continuation in
            source.apply(nativeOrder, animatingDifferences: false) { continuation.resume() }
        }
        XCTAssertTrue(coordinator.update(with: try XCTUnwrap(coordinator.latest),
                                         nativeOrder: nativeOrder.itemIdentifiers))
        XCTAssertEqual(source.snapshot().itemIdentifiers(inSection: .queue), [.track(a.id), .track(b.id)])

        // An accepted move changes the owner input; it must reach UIKit as well.
        inputs.entries.reverse()
        try await settle(host)
        XCTAssertEqual(source.snapshot().itemIdentifiers(inSection: .queue), [.track(b.id), .track(a.id)])
        XCTAssertFalse(coordinator.update(with: try XCTUnwrap(coordinator.latest)))

        // Exercise the real cell provider with the same native cell changing roles,
        // as it does when UIKit reuses a cell for a different item.
        coordinator.configure(trackCell, item: .title)
        XCTAssertTrue(trackCell.accessories.isEmpty)
        coordinator.configure(trackCell, item: .track(b.id))
        try assertReorderAccessory(in: trackCell)
        coordinator.configure(trackCell, item: .track(a.id))
        try assertReorderAccessory(in: trackCell)
        coordinator.configure(trackCell, item: .spacer)
        XCTAssertTrue(trackCell.accessories.isEmpty)
        coordinator.configure(trackCell, item: .track(a.id))
        try assertReorderAccessory(in: trackCell)
        coordinator.configure(trackCell, item: .empty)
        XCTAssertTrue(trackCell.accessories.isEmpty)
    }

    func testNativeInteractiveMovementInLongQueueCommitsStableOccurrencesOnce() async throws {
        let tracks = (0..<2_000).map { index in
            ReferenceTrack(id: "song-\(index % 50)", title: "Song \(index % 50)", artists: "Artist",
                           albumTitle: "Album", coverURL: nil, duration: 60)
        }
        let owner = PlayerTestFixtures.owner(tracks: tracks)
        let player = ReferencePlayerState(model: owner)
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

        XCTAssertNotNil(coordinator.trailingActions(at: from))
        collectionView.contentOffset.y = 320
        try await settle(host)
        collectionView.contentOffset.y = 0
        try await settle(host)
        XCTAssertNotNil(coordinator.trailingActions(at: from),
                        "A prepared row must restore swipe actions when it returns onscreen")
    }

    func testPageVisibilityChangesKeepListAndSnapshotForAllQueueLengths() async throws {
        for count in [50, 500, 2_000] {
            let inputs = QueueListTestInputs()
            inputs.entries = (0..<count).map { index in
                UpcomingQueueEntry(id: UUID(), queueIndex: index,
                    song: ReferenceTrack(id: "song-\(index % 50)", title: "Song", artists: "Artist",
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
            let marked = try markConfigurations(in: host.view, source: source)
            for _ in 0..<10 {
                inputs.artworkRequests.removeAll()
                inputs.visualsActive.toggle()
                try await settle(host)
                XCTAssertTrue(collection(in: host.view) === list)
                XCTAssertEqual(coordinator.snapshotApplicationCount, applications,
                               "Visibility must not submit the \(count)-entry snapshot")
                XCTAssertTrue(reconfiguredCells(marked).isEmpty,
                              "Page visibility must preserve prepared hosting content")
                XCTAssertEqual(Set(inputs.artworkRequests), inputs.visualsActive ? visibleArtworkIDs() : [])
            }
            XCTAssertEqual(coordinator.dataSource?.snapshot().numberOfItems(inSection: .queue), count)

            inputs.artworkRequests.removeAll()
            let entry = inputs.entries[0]
            var updated = entry.song
            updated.artworkLoadID = "updated-cover"
            inputs.entries[0] = UpcomingQueueEntry(id: entry.id, queueIndex: entry.queueIndex, song: updated)
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

    func testScrollIndicatorTracksVisibleViewportWithoutChangingContent() async throws {
        for count in [0, 3, 50, 2_000] {
            let inputs = QueueListTestInputs()
            inputs.entries = (0..<count).map { index in
                UpcomingQueueEntry(id: UUID(), queueIndex: index,
                    song: ReferenceTrack(id: "song-\(index)", title: "Song", artists: "Artist",
                                         albumTitle: "Album", coverURL: nil, duration: 60))
            }
            let (window, host) = try mount(inputs)
            defer { window.isHidden = true }
            try await settle(host)
            let list = try XCTUnwrap(collection(in: host.view))
            let coordinator = try coordinator(in: host.view)
            let contentInset = list.contentInset
            let size = list.contentSize
            let offsets: [CGFloat] = count > 3
                ? [0, inputs.headerHeight - 1, inputs.headerHeight, 300, max(0, size.height - list.bounds.height)]
                : [0]
            for offset in offsets {
                list.contentOffset.y = offset
                // UIKit aligns the requested position to device pixels.
                let position = list.contentOffset
                coordinator.scrollViewDidScroll(list)
                XCTAssertEqual(list.verticalScrollIndicatorInsets.top,
                               max(0, inputs.headerHeight - position.y) + 44 + 24)
                XCTAssertEqual(list.verticalScrollIndicatorInsets.bottom, 80)
                XCTAssertEqual(list.contentOffset, position)
                XCTAssertEqual(list.contentInset, contentInset)
                XCTAssertEqual(list.contentSize, size)
            }
        }
    }

    func testEdgeMasksFollowChangingCompositingLayersWithoutReplacingCustomMasks() throws {
        let list = NowPlayingQueueList.EdgeFadedCollectionView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 400),
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        let cell = UICollectionViewCell(frame: CGRect(x: 0, y: 20, width: 320, height: 60))
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

        // Hosting content can rebuild its compositing hierarchy after a metadata or state update.
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
}

@MainActor @Observable
private final class QueueListTestInputs {
    var revision: UInt64 = 0
    var entries: [UpcomingQueueEntry] = ["a", "b"].enumerated().map { index, id in
        UpcomingQueueEntry(id: UUID(), queueIndex: index + 1,
                           song: ReferenceTrack(id: id, title: id, artists: "Artist", albumTitle: "Album", coverURL: nil, duration: 60))
    } { didSet { revision &+= 1 } }
    var headerHeight: CGFloat = 40
    var subtitle = "Next songs"
    var visualsActive = true
    var actions = PlayerTestFixtures.actions()
    var player = PlayerTestFixtures.state(tracks: [])
    var onMove: (IndexSet, Int) -> Void = { _, _ in }
    @ObservationIgnored var artworkRequests: [String] = []
    let library = PlayerTestFixtures.library()
}

private struct QueueListTestView: View {
    let inputs: QueueListTestInputs
    var body: some View {
        NowPlayingQueueList(entries: inputs.entries,
                            version: UpcomingQueueVersion(revision: inputs.revision, index: 0, repeatMode: .all),
                            subtitle: inputs.subtitle,
                            headerHeight: inputs.headerHeight, horizontalInset: 32,
                            onPlay: { _ in }, onMove: inputs.onMove, onScroll: { _ in })
            .environment(inputs.player)
            .environment(inputs.actions)
            .environment(inputs.library)
            .environment(\.playerVisualsActive, inputs.visualsActive)
            .environment(\.artworkLoadAction, ArtworkLoadAction(handler: { inputs.artworkRequests.append($0) }))
    }
}
