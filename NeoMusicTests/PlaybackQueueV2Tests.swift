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

    private func coordinator(in view: UIView) throws -> Coordinator {
        func find(_ view: UIView) -> UICollectionView? {
            if let collection = view as? UICollectionView { return collection }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(view)?.delegate as? Coordinator)
    }

    private func markConfigurations(in view: UIView, source: UICollectionViewDiffableDataSource<Coordinator.Section, Coordinator.Item>) throws -> [Coordinator.Item: UICollectionViewListCell] {
        func find(_ view: UIView) -> UICollectionView? {
            if let collection = view as? UICollectionView { return collection }
            return view.subviews.lazy.compactMap(find).first
        }
        let collection = try XCTUnwrap(find(view))
        collection.layoutIfNeeded()
        return try Dictionary(uniqueKeysWithValues: source.snapshot().itemIdentifiers.map { item in
            let path = try XCTUnwrap(source.indexPath(for: item))
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
        XCTAssertTrue(reconfiguredCells(marked).isEmpty)
        inputs.headerHeight += 20
        try await settle(host)
        XCTAssertEqual(reconfiguredCells(marked), [.spacer])
        marked = try markConfigurations(in: host.view, source: source)
        inputs.subtitle = "Updated subtitle"
        try await settle(host)
        XCTAssertEqual(reconfiguredCells(marked), [.title])

        marked = try markConfigurations(in: host.view, source: source)
        inputs.backdrop = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
        try await settle(host)
        XCTAssertEqual(reconfiguredCells(marked),
                       Set([.title] + inputs.entries.map { Coordinator.Item.track($0.id) }))
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
        let marked = try markConfigurations(in: host.view, source: source)
        let trackCell = try XCTUnwrap(marked[.track(a.id)])
        try assertReorderAccessory(in: trackCell)
        inputs.entries[0] = UpcomingQueueEntry(id: a.id, queueIndex: 7,
            song: ReferenceTrack(id: a.song.id, title: "Updated title", artists: a.song.artists,
                                 albumTitle: a.song.albumTitle, coverURL: nil, duration: a.song.duration))
        try await settle(host)
        XCTAssertEqual(reconfiguredCells(marked), [.track(a.id)])
        try assertReorderAccessory(in: trackCell)
        XCTAssertFalse(coordinator.update(with: try XCTUnwrap(coordinator.latest)))

        // UIKit can already show a reordered snapshot while the owner still has
        // the old order. An unchanged owner input must restore the actual snapshot.
        var nativeOrder = source.snapshot()
        nativeOrder.moveItem(.track(b.id), beforeItem: .track(a.id))
        await withCheckedContinuation { continuation in
            source.apply(nativeOrder, animatingDifferences: false) { continuation.resume() }
        }
        XCTAssertTrue(coordinator.update(with: try XCTUnwrap(coordinator.latest)))
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
}

@MainActor @Observable
private final class QueueListTestInputs {
    var entries: [UpcomingQueueEntry] = ["a", "b"].enumerated().map { index, id in
        UpcomingQueueEntry(id: .init(songID: id, occurrence: 0), queueIndex: index + 1,
                           song: ReferenceTrack(id: id, title: id, artists: "Artist", albumTitle: "Album", coverURL: nil, duration: 60))
    }
    var headerHeight: CGFloat = 40
    var subtitle = "Next songs"
    var backdrop: UIImage?
    var actions = PlayerTestFixtures.actions()
    let player = PlayerTestFixtures.state(tracks: [])
    let library = PlayerTestFixtures.library()
}

private struct QueueListTestView: View {
    let inputs: QueueListTestInputs
    var body: some View {
        NowPlayingQueueList(entries: inputs.entries, subtitle: inputs.subtitle,
                            headerHeight: inputs.headerHeight, horizontalInset: 32,
                            onPlay: { _ in }, onMove: { _, _ in }, onScroll: { _ in })
            .environment(inputs.player)
            .environment(inputs.actions)
            .environment(inputs.library)
            .environment(\.nowPlayingBackdropImage, inputs.backdrop)
            .environment(\.playerArtistEDREnabled, false)
    }
}
