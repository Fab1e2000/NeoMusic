import SwiftUI
import UIKit
import XCTest
@testable import NeoMusic

@MainActor final class IngestionTransactionTests: XCTestCase {
    func testLocalSnapshotDoesNotInheritCollectionAnimation() async throws {
        let library = SongLibrary(songs: [], defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let probe = ProbeRecorder()
        let window = try await mount(ids: { library.songs.filter(\.isPinned).map(\.id) }, recorder: probe)
        defer { window.isHidden = true }
        let song = LibrarySongItem(id: "loaded", title: "Loaded", artist: "Artist", album: "Album",
                                  albumArtist: "Artist", trackNumber: 1, artwork: .missing, isPinned: true)
        let transaction = try await update(probe, expecting: [song.id]) {
            withAnimation(.default) { library.replace([song]) }
        }
        XCTAssertTrue(transaction.disablesAnimations)
        XCTAssertNil(transaction.animation)
    }

    func testOnlineRestoreAndAccountRemovalAreImmediateWhileUserPinAnimates() async throws {
        let library = PlaylistLibrary(playlists: [])
        let probe = ProbeRecorder()
        let window = try await mount(ids: { library.playlists.filter(\.isPinned).map(\.id) }, recorder: probe)
        defer { window.isHidden = true }
        let item = LibraryPlaylistItem(id: "netease-playlist:42:1", title: "Loaded", artwork: .playlist,
                                       isPinned: true, sourceOwnerID: "42")
        let restoration = try await update(probe, expecting: [item.id]) {
            withAnimation(.default) { library.replaceOnlinePlaylists(items: [item], songs: [:], ownerID: "42") }
        }
        XCTAssertTrue(restoration.disablesAnimations)
        XCTAssertNil(restoration.animation)
        let removal = try await update(probe, expecting: []) {
            withAnimation(.default) { library.togglePin(item.id) }
        }
        XCTAssertFalse(removal.disablesAnimations)
        XCTAssertNotNil(removal.animation)
        let insertion = try await update(probe, expecting: [item.id]) {
            withAnimation(.default) { library.togglePin(item.id) }
        }
        XCTAssertFalse(insertion.disablesAnimations)
        XCTAssertNotNil(insertion.animation)
        let accountChange = try await update(probe, expecting: []) {
            withAnimation(.default) { library.replaceOnlinePlaylists(items: [], songs: [:], ownerID: nil) }
        }
        XCTAssertTrue(accountChange.disablesAnimations)
        XCTAssertNil(accountChange.animation)
    }

    private func mount(ids: @escaping () -> [String], recorder: ProbeRecorder) async throws -> UIWindow {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ProbeRoot(ids: ids, recorder: recorder))
        _ = try await update(recorder, expecting: []) { window.makeKeyAndVisible() }
        return window
    }

    private func update(_ recorder: ProbeRecorder, expecting ids: [String], action: () -> Void) async throws -> Transaction {
        let rendered = expectation(description: "Render \(ids)")
        var received: Transaction?
        recorder.onUpdate = { actual, transaction in
            guard actual == ids, received == nil else { return }
            received = transaction
            rendered.fulfill()
        }
        action()
        await fulfillment(of: [rendered], timeout: 2)
        recorder.onUpdate = nil
        return try XCTUnwrap(received)
    }
}

@MainActor private final class ProbeRecorder {
    var onUpdate: (([String], Transaction) -> Void)?
}

private struct ProbeRoot: View {
    let ids: () -> [String]
    let recorder: ProbeRecorder
    var body: some View {
        let values = ids()
        TransactionProbe(ids: values, recorder: recorder)
            .frame(height: CGFloat(20 + values.count * 60))
            .animation(.default, value: values)
    }
}

private struct TransactionProbe: UIViewRepresentable {
    let ids: [String]
    let recorder: ProbeRecorder
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) { recorder.onUpdate?(ids, context.transaction) }
}
