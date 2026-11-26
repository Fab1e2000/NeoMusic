import SwiftUI

@MainActor @Observable
final class LibraryDownloads {
    typealias SongState = FrontAMDownloadState
    typealias CollectionState = FrontAMCollectionDownloadState
    @MainActor @Observable final class SongStatus { var value: SongState? }
    @MainActor @Observable final class CollectionStatus { var value: CollectionState? }
    @ObservationIgnored private var songStatuses: [String: SongStatus] = [:]
    @ObservationIgnored private var collectionStatuses: [LibraryRoute: CollectionStatus] = [:]
    @ObservationIgnored private var localIDs: Set<String> = []
    @ObservationIgnored private var remoteStates: [String: SongState] = [:]
    private(set) var managedSongIDs: Set<String> = []
    private(set) var pendingRemoval: [LibrarySongItem] = []
    var downloadAction: ([LibrarySongItem]) -> Void = { _ in }
    var stopAction: ([LibrarySongItem]) -> Void = { _ in }
    var removeAction: ([LibrarySongItem]) -> Void = { _ in }
    var isDownloadable: (LibrarySongItem) -> Bool = { _ in false }
    var isRemovable: (LibrarySongItem) -> Bool = { _ in false }

    var states: [String: SongState] { songStatuses.compactMapValues(\.value) }
    func status(of id: String) -> SongStatus {
        if let status = songStatuses[id] { return status }
        let status = SongStatus(); songStatuses[id] = status
        status.value = remoteStates[id] ?? (!managedSongIDs.contains(id) && localIDs.contains(id) ? .downloaded : nil)
        return status
    }
    func state(of songID: String) -> SongState? { status(of: songID).value }
    func collectionState(of route: LibraryRoute) -> CollectionState? {
        if let status = collectionStatuses[route] { return status.value }
        let status = CollectionStatus(); collectionStatuses[route] = status
        return status.value
    }
    func publish(states: [String: SongState], managedSongIDs: Set<String>) {
        let changed = Set(remoteStates.keys).union(states.keys).union(self.managedSongIDs).union(managedSongIDs)
        remoteStates = states
        if self.managedSongIDs != managedSongIDs { self.managedSongIDs = managedSongIDs }
        for id in changed {
            let value = states[id] ?? (!managedSongIDs.contains(id) && localIDs.contains(id) ? .downloaded : nil)
            let status = status(of: id)
            if status.value != value { status.value = value }
        }
    }
    func update(states: [String: SongState], collections: [LibraryRoute: CollectionState]) {
        for (id, value) in states {
            remoteStates[id] = value
            managedSongIDs.insert(id)
            let status = status(of: id)
            if status.value != value { status.value = value }
        }
        for (route, value) in collections {
            let status = collectionStatuses[route] ?? CollectionStatus()
            collectionStatuses[route] = status
            if status.value != value { status.value = value }
        }
    }
    func publishCollections(_ values: [LibraryRoute: CollectionState]) {
        for route in Set(collectionStatuses.keys).union(values.keys) {
            let status = collectionStatuses[route] ?? CollectionStatus()
            collectionStatuses[route] = status
            if status.value != values[route] { status.value = values[route] }
        }
    }
    func setLocalSongs(_ songs: [LibrarySongItem]) {
        let updated = Set(songs.map(\.id)), changed = localIDs.symmetricDifference(updated)
        localIDs = updated
        for id in changed { status(of: id).value = remoteStates[id] ?? (!managedSongIDs.contains(id) && updated.contains(id) ? .downloaded : nil) }
    }
    func isDownloaded(_ songs: [LibrarySongItem]) -> Bool {
        !songs.isEmpty && songs.allSatisfy { state(of: $0.id) == .downloaded }
    }
    func isDownloading(_ songs: [LibrarySongItem]) -> Bool { songs.contains { state(of: $0.id)?.isActive == true } }
    func progress(of songs: [LibrarySongItem]) -> Double {
        guard !songs.isEmpty else { return 0 }
        return songs.reduce(0) { total, song in
            switch state(of: song.id) {
            case .downloaded, .finishing: return total + 1
            case .downloading(let progress): return total + min(1, max(0, progress))
            default: return total
            }
        } / Double(songs.count)
    }
    func canRemove(_ song: LibrarySongItem) -> Bool { managedSongIDs.contains(song.id) && isRemovable(song) }
    func download(_ songs: [LibrarySongItem]) { downloadAction(songs.filter(isDownloadable)) }
    func stop(_ songs: [LibrarySongItem]) { stopAction(songs.filter { state(of: $0.id)?.isActive == true }) }
    func remove(_ songs: [LibrarySongItem]) {
        let removable = songs.filter(canRemove)
        if !removable.isEmpty { removeAction(removable) }
    }
    func requestRemoval(_ songs: [LibrarySongItem]) { pendingRemoval = songs.filter(canRemove) }
    func cancelRemoval() { pendingRemoval = [] }
    func confirmRemoval() {
        let songs = pendingRemoval
        pendingRemoval = []
        guard !songs.isEmpty else { return }
        LibraryHaptics.lightImpact()
        remove(songs)
    }
}

extension View {
    func downloadRemovalConfirmation() -> some View { modifier(DownloadRemovalConfirmation()) }
}
private struct DownloadRemovalConfirmation: ViewModifier {
    @Environment(\.libraryDownloads) private var downloads
    func body(content: Content) -> some View {
        content.alert("", isPresented: Binding(
            get: { downloads?.pendingRemoval.isEmpty == false },
            set: { if !$0 { downloads?.cancelRemoval() } })) {
                Button("移除下载", role: .destructive) { downloads?.confirmRemoval() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将移除所选歌曲的本机文件。使用同一文件的其他播放列表也需要联网播放，收藏和播放列表会保留。")
            }
    }
}

extension LibraryDownloads: FrontAMDownloadSource {}
