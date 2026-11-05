import XCTest
import Observation
@testable import NeoMusic

@MainActor final class LibraryDownloadsTests: XCTestCase {
    private func song(_ id: String) -> LibrarySongItem {
        .init(id: id, title: "歌曲", artist: "艺人", album: "专辑", albumArtist: "艺人", trackNumber: 1, artwork: .missing)
    }

    func testImportedSongsRemainPlayableButCannotBeRemovedAsDownloads() {
        let downloads = LibraryDownloads(), imported = song("Imported/song.flac")
        var removals: [[String]] = []
        downloads.isRemovable = { _ in true }
        downloads.removeAction = { removals.append($0.map(\.id)) }
        downloads.setLocalSongs([imported])
        XCTAssertEqual(downloads.state(of: imported.id), .downloaded)
        XCTAssertFalse(downloads.canRemove(imported))
        downloads.requestRemoval([imported])
        XCTAssertTrue(downloads.pendingRemoval.isEmpty)
        downloads.remove([imported])
        XCTAssertTrue(removals.isEmpty)
    }

    func testRemovingManagedFileCannotBeUndoneByStaleLocalScanCache() {
        let downloads = LibraryDownloads(), managed = song("网易云/Album/1.flac")
        downloads.setLocalSongs([managed])
        downloads.publish(states: [managed.id: .downloaded], managedSongIDs: [managed.id])
        downloads.publish(states: [:], managedSongIDs: [managed.id])
        XCTAssertNil(downloads.state(of: managed.id))
        downloads.setLocalSongs([])
        downloads.setLocalSongs([managed])
        XCTAssertNil(downloads.state(of: managed.id))
        XCTAssertFalse(downloads.isDownloaded([managed]))
    }

    func testFullCollectionRemainsIncompleteWhenLoadedPageIsDownloaded() {
        let downloads = LibraryDownloads(), route = LibraryRoute.playlist("list")
        let firstPage = [song("1"), song("2")]
        downloads.publish(states: ["1": .downloaded, "2": .downloaded], managedSongIDs: ["1", "2"])
        downloads.publishCollections([route: .init(totalCount: 20, completedCount: 2, activeCount: 0, failedCount: 1, progress: 0.1)])
        XCTAssertTrue(downloads.isDownloaded(firstPage))
        XCTAssertEqual(downloads.collectionState(of: route)?.isComplete, false)
        XCTAssertNotNil(downloads.collectionState(of: route)?.failureSummary)
        downloads.publishCollections([route: .init(totalCount: 20, completedCount: 20, activeCount: 0, failedCount: 0, progress: 1)])
        XCTAssertEqual(downloads.collectionState(of: route)?.isComplete, true)
    }

    func testTransferProgressInvalidatesOnlyTheAffectedSongStatus() {
        let downloads = LibraryDownloads()
        downloads.publish(states: ["1": .downloading(0.2), "2": .downloaded], managedSongIDs: ["1", "2"])
        let first = downloads.status(of: "1"), second = downloads.status(of: "2")
        let firstChanges = DownloadObservationCounter(), secondChanges = DownloadObservationCounter()
        withObservationTracking { _ = first.value } onChange: { firstChanges.increment() }
        withObservationTracking { _ = second.value } onChange: { secondChanges.increment() }
        downloads.publish(states: ["1": .downloading(0.5), "2": .downloaded], managedSongIDs: ["1", "2"])
        XCTAssertEqual(firstChanges.value, 1)
        XCTAssertEqual(secondChanges.value, 0)
        XCTAssertTrue(first === downloads.status(of: "1"))
        XCTAssertTrue(second === downloads.status(of: "2"))
    }

    func testCancelledRemovalDoesNotSubmitAFileOperation() {
        let downloads = LibraryDownloads(), managed = song("managed")
        var removals = 0
        downloads.publish(states: [managed.id: .downloaded], managedSongIDs: [managed.id])
        downloads.isRemovable = { _ in true }
        downloads.removeAction = { _ in removals += 1 }
        downloads.requestRemoval([managed])
        XCTAssertEqual(downloads.pendingRemoval.map(\.id), [managed.id])
        XCTAssertEqual(removals, 0)
        downloads.cancelRemoval()
        downloads.confirmRemoval()
        XCTAssertEqual(removals, 0)
        XCTAssertEqual(downloads.state(of: managed.id), .downloaded)
    }

    func testPartiallyDownloadedCollectionOffersRemovalAndRetry() {
        let downloads = LibraryDownloads(), route = LibraryRoute.playlist("list")
        downloads.publishCollections([route: .init(totalCount: 2, completedCount: 1, activeCount: 0, failedCount: 1, progress: 0.5)])
        let actions = CollectionMenuActions(isDownloaded: { _ in false }, canDownload: { _ in true },
                                            canRemoveDownload: { _ in true }, downloads: downloads)
        let item = LibraryShelfItem(id: "list", title: "歌单", artwork: .playlist, route: route)
        let titles = actions.sections(for: item, route: route).flatMap { $0.map(\.title) }
        XCTAssertTrue(titles.contains("移除下载"))
        XCTAssertTrue(titles.contains("重试下载"))
    }
}

private final class DownloadObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
