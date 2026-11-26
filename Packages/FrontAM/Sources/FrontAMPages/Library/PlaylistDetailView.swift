import FrontAMCore
import FrontAMNavigation
import SwiftUI

private struct PlaylistRootChrome: ViewModifier {
    let isRoot: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if isRoot { content.libraryNavigationTitle("") } else { content }
    }
}

private struct RootArtworkName: ViewModifier {
    let title: String?
    @ViewBuilder func body(content: Content) -> some View {
        if let title { content.accessibilityElement(children: .ignore).accessibilityLabel(title) }
        else { content }
    }
}

public struct PlaylistDetailView: View {
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    public let playlistID: String
    public let library: any FrontAMPlaylistSource
    public let songs: [LibrarySongItem]
    public var availableSongs: (@MainActor () -> [LibrarySongItem])? = nil
    public var externalActions: ExternalPlaylistActions? = nil
    public var externalArtwork: AnyView? = nil
    public var recentlyPlayedSongs: [LibrarySongItem] = []
    @Environment(\.artworkLoadAction) private var loadArtwork
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeLibraryDetail) private var closeLibraryDetail
    @Environment(\.songMenuActions) private var songActions
    @Environment(\.collectionMenuActions) private var collectionActions
    @Environment(\.libraryDownloads) private var downloads
    @Environment(\.libraryNavigationPreview) private var navigationPreview
    @Environment(\.libraryNavigationChrome) private var chrome
    @Environment(\.colorScheme) private var colorScheme
    @State private var backdrop: AlbumArtworkBackdrop?
    @State private var query = ""
    @State private var sort = DetailSort.order
    @State private var projection = AsyncListProjection<TrackFilterProjectionInput, TrackFilterProjectionResult>()
    @State private var durationProjection = LibraryListProjection<[LibrarySongItem], Int>()
    @State private var showsAddMusic = false
    @State private var showsEditor = false
    @State private var showsDestinations = false
    @State private var loadedOnlinePlaylistID: String?
    @State private var pendingPlayback: PlaylistTrackSelection?
    @State private var actionFeedback = 0

    private static let coverSize: CGFloat = 266
    private static let coverTopInset: CGFloat = 14

    private var playlist: LibraryPlaylistItem? { library.playlist(playlistID) }
    private var backgroundArtwork: Artwork {
        guard let playlist else { return .missing }
        if playlist.artwork == .playlist, let preview = navigationPreview,
           preview.route == .playlist(playlistID), preview.ownerID == playlist.sourceOwnerID {
            return preview.backdropFile.map(Artwork.file) ?? preview.artwork
        }
        return playlist.artwork
    }
    private var preparedBackdrop: AlbumArtworkBackdrop? {
        loadArtwork.provider.cachedBackdrop(for: backgroundArtwork) ?? backdrop ??
            navigationPreview.flatMap { $0.route == .playlist(playlistID) && $0.ownerID == playlist?.sourceOwnerID ? $0.albumBackdrop : nil }
    }
    private var pageBackground: Color { preparedBackdrop?.color ?? Color(.systemBackground) }

    private var palette: CollectionPagePalette {
        CollectionPagePalette(
            background: UIColor(pageBackground),
            isDark: (preparedBackdrop?.colorScheme ?? colorScheme) == .dark
        )
    }

    private var resolvedSecondaryColor: Color {
        palette.secondaryColor
    }
    private var tracks: [LibrarySongItem] { library.songs(in: playlistID) }
    private var projectionInput: TrackFilterProjectionInput {
        TrackFilterProjectionInput(tracks: tracks, query: query, sort: sort)
    }

    private var displayedTracks: [LibrarySongItem] {
        let input = projectionInput
        if input.followsPlaylistOrder { return input.tracks }
        return projection.currentValue(for: input, fastPath: TrackFilterProjection.fastPath, placeholder: { _ in .empty }).tracks
    }

    public var body: some View {
        let input = projectionInput
        let requestedPlayback = pendingPlayback
        Group {
            if let playlist {
                let awaitingDetail = library.isAwaitingInitialOnlineDetail(for: playlist)
                content(playlist, awaitingDetail: awaitingDetail)
                    .libraryTitleDisplayMode(.inline)
                    .toolbarColorScheme(preparedBackdrop?.colorScheme, for: .navigationBar)
            } else {
                ContentUnavailableView("播放列表已删除", systemImage: "music.note.list")
            }
        }
        .task(id: backgroundArtwork) {
            let result = await CollectionBackdropResolver.resolve(artwork: backgroundArtwork, loadArtwork: loadArtwork)
            guard !Task.isCancelled else { return }
            if let result { backdrop = result }
        }
        .onChange(of: preparedBackdrop, initial: true) { _, value in chrome?.setBackdrop(color: value?.uiColor, colorScheme: value?.colorScheme) }
        .task(id: playlistID) {
            guard playlist?.isReadOnly == true, loadedOnlinePlaylistID != playlistID else { return }
            loadedOnlinePlaylistID = playlistID
            await library.loadOnlinePlaylist?(playlistID)
        }
        .task(id: FullCollectionRequest(playlistID: playlistID, query: query, sort: sort,
                                        hasMore: library.onlineHasMore.contains(playlistID))) {
            if !query.isEmpty || sort != .order { _ = await library.prepareCompleteCollection(playlistID) }
        }
        .task(id: input) {
            await TrackFilterProjection.update(projection, for: input)
        }
        .task(id: requestedPlayback) {
            guard let requestedPlayback else { return }
            let result = await requestedPlayback.prepare(in: library, projection: projection)
            guard !Task.isCancelled, pendingPlayback == requestedPlayback,
                  requestedPlayback.query == query, requestedPlayback.sort == sort else { return }
            pendingPlayback = nil
            finishPlayback(result)
        }
        .onChange(of: query) { _, _ in pendingPlayback = nil }
        .onChange(of: sort) { _, _ in pendingPlayback = nil }
        .onChange(of: playlistID) { _, _ in pendingPlayback = nil }
        .onDisappear { pendingPlayback = nil }
        .playlistDeletionConfirmation(library)
        .onChange(of: playlist == nil) { _, missing in
            if missing {
                if let close = closeLibraryDetail.handler { close() } else { dismiss() }
            }
        }
        .sheet(isPresented: $showsAddMusic) {
            PlaylistAddMusicContent(playlistID: playlistID, library: library, songs: availableSongsProvider,
                                    recentlyPlayedSongs: recentlyPlayedSongs)
        }
        .sheet(isPresented: $showsEditor) {
            PlaylistEditorContent(playlistID: playlistID, library: library, songs: availableSongsProvider)
        }
        .sheet(isPresented: $showsDestinations) {
            PlaylistDestinationPicker(library: library, excluding: playlistID, songs: tracks)
        }
    }

    private var availableSongsProvider: @MainActor () -> [LibrarySongItem] {
        if let availableSongs { return availableSongs }
        let songs = songs
        return { songs }
    }

    private struct FullCollectionRequest: Equatable {
        let playlistID: String
        let query: String
        let sort: DetailSort
        let hasMore: Bool
    }

    private func content(_ playlist: LibraryPlaylistItem, awaitingDetail: Bool) -> some View {
        let tracks = tracks
        let hasMore = library.onlineHasMore.contains(playlistID)
        let scheme = preparedBackdrop?.colorScheme ?? colorScheme
        let errorBanner: AnyView? = library.onlineErrors[playlistID].map { error in
            AnyView(VStack(alignment: .leading, spacing: 8) {
                Text(error).font(.subheadline).foregroundStyle(.secondary)
                Button("重试") { Task { await library.loadOnlinePlaylist?(playlistID) } }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 8))
        }
        let summaryFooter: AnyView? = (query.isEmpty && !tracks.isEmpty) ? AnyView(
            Text(hasMore
                 ? "\(library.onlineTrackCounts[playlistID] ?? tracks.count)首歌"
                 : "\(tracks.count)首歌，\(totalDuration(of: tracks) / 60)分钟")
                .font(.subheadline)
                .foregroundStyle(resolvedSecondaryColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 30)
        ) : nil
        return NativePlaylistTrackList(
            songs: awaitingDetail ? [] : displayedTracks,
            title: playlist.title,
            header: AnyView(header(playlist)
                .padding(.horizontal, 20)
                .padding(.bottom, tracks.isEmpty ? 39 : 24)),
            banner: errorBanner,
            footer: summaryFooter,
            showsAddMusicRow: query.isEmpty && !playlist.isReadOnly,
            pageColor: UIColor(pageBackground),
            scheme: scheme,
            rowCornerRadius: 5,
            headerSeparatorInset: 20,
            lastSongSeparatorLeading: 20,
            swipeMode: playlist.isReadOnly
                ? .standard(animateFavoriteRemoval: false)
                : .editablePlaylist(remove: { song in withAnimation(reducesMotion ? nil : .default) { library.removeSong(song.id, from: playlistID) } }),
            pendingPlaybackSongID: pendingPlayback?.songID,
            onPlaySong: { song, _ in requestPlayback(of: song, in: playlist) },
            onAddMusic: { showsAddMusic = true },
            onReachedEnd: {
                guard query.isEmpty, sort == .order,
                      library.onlineHasMore.contains(playlistID),
                      library.onlineErrors[playlistID] == nil else { return }
                Task { await library.loadMoreOnlinePlaylist?(playlistID) }
            }
        )
        .ignoresSafeArea(.container, edges: .vertical)
        .background(pageBackground)
        .detailLoadingMask(awaitingDetail: awaitingDetail, pageColor: pageBackground)
        .environment(\.colorScheme, scheme)
        .environment(\.collectionPagePalette, palette)
        .modifier(PlaylistRootChrome(isRoot: chrome?.isRoot == true))
        .libraryRootAccountButton()
        .modifier(PlaylistDetailSearch(query: $query, enabled: awaitingDetail || !tracks.isEmpty))
        .toolbar {
            if !awaitingDetail {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("开始协作", systemImage: "person.fill.badge.plus") {}.disabled(true)
                    Button("共享", systemImage: "square.and.arrow.up") {}.disabled(true)
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        detailMenu(playlist)
                    } label: {
                        Label("更多", systemImage: "ellipsis")
                    }
                    .menuOrder(.fixed)
                }
            }
        }
    }

    private func header(_ playlist: LibraryPlaylistItem) -> some View {
        VStack(spacing: 0) {
            LibraryArtworkSurface(content: Group {
                if let externalArtwork {
                    externalArtwork.clipShape(.rect(cornerRadius: DesignTokens.Radius.detailCover))
                } else {
                    detailArtwork(playlist)
                }
            }.environment(\.nativeArtworkSurfaceEnabled, false), cornerRadius: DesignTokens.Radius.detailCover, isZoomAlignmentTarget: true)
                .frame(width: Self.coverSize, height: Self.coverSize)
                .shadow(color: .black.opacity(0.06), radius: 12, y: 6)
                .padding(.top, Self.coverTopInset)
                .padding(.bottom, 22)
                .modifier(RootArtworkName(title: chrome?.isRoot == true ? playlist.title : nil))
            if chrome?.isRoot != true {
                Text(playlist.title).font(.title2.bold()).multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
            }
            Text(playlist.subtitle ?? "我").font(.title3).padding(.top, 4)
            if externalActions == nil, let updatedAt = playlist.updatedAt {
                Text("更新于 \(updatedAt, format: .relative(presentation: .named))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(resolvedSecondaryColor)
                    .padding(.top, 4 + 1.0 / 3)
            }
            if !tracks.isEmpty || library.canCollectPreview(playlist) {
                let actionsLayout = textSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 14))
                    : AnyLayout(HStackLayout(spacing: 14))
                actionsLayout {
                    Button {
                        guard !tracks.isEmpty else { return }
                        pendingPlayback = nil
                        actionFeedback &+= 1
                        collectionActions.play(.playlist(playlistID), true)
                    } label: {
                        Label("随机播放", systemImage: "shuffle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(CollectionCircleButtonStyle())
                    .disabled(tracks.isEmpty)
                    Button {
                        guard !tracks.isEmpty else { return }
                        pendingPlayback = nil
                        actionFeedback &+= 1
                        collectionActions.play(.playlist(playlistID), false)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill").font(.system(size: 18, weight: .semibold))
                            Text("播放")
                        }
                            .font(.headline)
                            .foregroundStyle(palette.playForeground)
                            .padding(.vertical, textSize.isAccessibilitySize ? 10 : 0)
                            .padding(.horizontal, textSize.isAccessibilitySize ? 20 : 0)
                            .frame(width: textSize.isAccessibilitySize ? nil : 160)
                            .frame(minHeight: 48)
                            .background(Color.primary, in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .disabled(tracks.isEmpty)
                    if library.canCollectPreview(playlist) {
                        Button {
                            externalActions?.collect?()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(CollectionCircleButtonStyle())
                        .accessibilityLabel("收藏歌单")
                    } else {
                        CollectionDownloadButton(route: .playlist(playlistID), songs: tracks)
                    }
                }
                .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: actionFeedback)
                .padding(.top, 15)
                if !library.canCollectPreview(playlist) { CollectionDownloadSummary(route: .playlist(playlistID)) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func detailArtwork(_ playlist: LibraryPlaylistItem) -> some View {
        let preview = navigationPreview.flatMap {
            $0.route == .playlist(playlistID) && $0.ownerID == playlist.sourceOwnerID ? $0 : nil
        }
        if case .playlist = playlist.artwork, preview == nil {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.detailCover)
                .fill(Color(.systemGray5))
                .overlay {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 266 * 0.391))
                        .foregroundStyle(Color(.systemGray2))
                }
                .overlay { RoundedRectangle(cornerRadius: DesignTokens.Radius.detailCover).strokeBorder(Color(.separator), lineWidth: 1 / displayScale) }
                .accessibilityHidden(true)
        } else {
            ArtworkView(artwork: playlist.artwork == .playlist ? preview?.artwork ?? playlist.artwork : playlist.artwork,
                        contentID: preview?.contentID ?? "\(playlist.sourceOwnerID ?? "local"):\(playlistID)",
                        previewArtwork: preview?.artwork, cornerRadius: DesignTokens.Radius.detailCover)
        }
    }

    private func totalDuration(of tracks: [LibrarySongItem]) -> Int {
        durationProjection.value(for: tracks) { tracks.reduce(0) { $0 + $1.duration } }
    }

    private func requestPlayback(of song: LibrarySongItem, in playlist: LibraryPlaylistItem) {
        let selection = PlaylistTrackSelection(playlistID: playlistID, ownerID: playlist.sourceOwnerID,
                                               songID: song.id, query: query, sort: sort)
        let input = projectionInput
        if !library.onlineHasMore.contains(playlistID),
           let ordered = selection.availableTracks(for: input, projection: projection) {
            pendingPlayback = nil
            finishPlayback(selection.outcome(in: ordered))
        } else {
            pendingPlayback = selection
            AccessibilityNotification.Announcement("正在准备播放").post()
        }
    }

    private func finishPlayback(_ result: PlaylistTrackSelection.Outcome) {
        switch result {
        case .ready(let tracks, let index):
            guard let playlist else { return }
            songActions.play(tracks, index, playlist.title)
        case .failed(let error):
            songActions.notify(.error(error))
        case .cancelled:
            break
        }
    }

    @ViewBuilder private func detailMenu(_ playlist: LibraryPlaylistItem) -> some View {
        if let actions = externalActions {
            externalMenu(playlist, actions: actions)
        } else {
            libraryMenu(playlist)
        }
        if collectionActions.canRemoveDownload(.playlist(playlistID)) {
            Section {
                Button("移除下载", systemImage: "xmark.circle") { collectionActions.removeDownload(.playlist(playlistID)) }
            }
        }
    }

    @ViewBuilder private func collectionDownloadMenuAction() -> some View {
        let route = LibraryRoute.playlist(playlistID)
        let state = downloads?.collectionState(of: route)
        if state?.isActive == true {
            Button("停止下载", systemImage: "stop.circle.fill") {
                LibraryHaptics.impact()
                collectionActions.stopDownload(route)
            }
        } else if state?.isComplete == true {
            Button("已下载", systemImage: "checkmark.circle.fill") {}.disabled(true)
        } else {
            Button((state?.failedCount ?? 0) > 0 ? "重试下载" : "下载", systemImage: "arrow.down.circle.fill") {
                LibraryHaptics.impact()
                collectionActions.download(route)
            }
            .disabled(!collectionActions.canDownload(route))
        }
    }

    @ViewBuilder private func externalMenu(_ playlist: LibraryPlaylistItem, actions: ExternalPlaylistActions) -> some View {
        collectionDownloadMenuAction()
        if let toggleFavorite = actions.toggleFavorite {
            Button(playlist.isFavorite ? "撤销喜爱" : "喜爱", systemImage: playlist.isFavorite ? "star.slash.fill" : "star.fill") {
                toggleFavorite()
            }
        }
        if let togglePin = actions.togglePin {
            Button(playlist.isPinned ? "取消置顶播放列表" : "置顶播放列表", systemImage: playlist.isPinned ? "pin.slash" : "pin") {
                togglePin()
            }
        }
        Button("添加到播放列表", systemImage: "text.badge.plus", action: actions.addSongs).disabled(tracks.isEmpty)
        if let moveToFolder = actions.moveToFolder {
            Button("移到文件夹", systemImage: "folder", action: moveToFolder)
        }
        Menu("排序方式", systemImage: "arrow.up.arrow.down") {
            Picker("排序方式", selection: $sort) {
                ForEach(DetailSort.allCases) { value in Text(value.rawValue).tag(value) }
            }
        }
        LibraryMenuContents(sections: [
            libraryQueueMenuItems(
                playbackSource: collectionActions.playbackSource(),
                isDisabled: tracks.isEmpty,
                playNext: { collectionActions.playNext(.playlist(playlistID)) },
                playLater: { collectionActions.playLater(.playlist(playlistID)) },
                notify: collectionActions.defersQueueNotice ? { _ in } : collectionActions.notify)
        ], firstSectionIsRow: false)
        if playlist.isSubscribed { Section {
            Button("从资料库删除", systemImage: "trash", role: .destructive) { library.pendingDeletion = playlist }
        } }
    }

    @ViewBuilder private func libraryMenu(_ playlist: LibraryPlaylistItem) -> some View {
        ControlGroup {
            collectionDownloadMenuAction()
            Button(playlist.isFavorite ? "撤销" : "喜爱", systemImage: playlist.isFavorite ? "star.slash.fill" : "star.fill") {
                LibraryHaptics.success()
                let removing = playlist.isFavorite
                library.toggleFavorite(playlistID)
                collectionActions.notify(removing ? .unfavorited : .favorited)
            }
            Button("共享", systemImage: "square.and.arrow.up.fill") {}.disabled(true)
        }
        Section {
            Button(playlist.isPinned ? "取消置顶播放列表" : "置顶播放列表", systemImage: playlist.isPinned ? "pin.slash" : "pin") {
                LibraryHaptics.success()
                let removing = playlist.isPinned
                library.togglePin(playlistID)
                collectionActions.notify(removing ? .unpinned : .pinned)
            }
            Button("添加到播放列表", systemImage: "text.badge.plus") { showsDestinations = true }.disabled(tracks.isEmpty)
        }
        Section {
            if !playlist.isReadOnly { Button("编辑", systemImage: "pencil") { showsEditor = true } }
            Button("开始协作", systemImage: "person.badge.plus") {}.disabled(true)
            Menu("排序方式", systemImage: "arrow.up.arrow.down") {
                Picker("排序方式", selection: $sort) {
                    ForEach(DetailSort.allCases) { value in Text(value.rawValue).tag(value) }
                }
            }
            Menu("移到文件夹", systemImage: "folder") {
                Button { library.move(playlistID: playlistID, to: nil) } label: {
                    Label("播放列表", systemImage: library.folderID(of: playlistID) == nil ? "checkmark" : "music.note.list")
                }
                ForEach(library.folders) { folder in
                    Button { library.move(playlistID: playlistID, to: folder.id) } label: {
                        Label(folder.name, systemImage: library.folderID(of: playlistID) == folder.id ? "checkmark" : "folder")
                    }
                }
            }
            .disabled(library.folders.isEmpty)
        }
        LibraryMenuContents(sections: [
            libraryQueueMenuItems(
                playbackSource: collectionActions.playbackSource(),
                isDisabled: tracks.isEmpty,
                playNext: { collectionActions.playNext(.playlist(playlistID)) },
                playLater: { collectionActions.playLater(.playlist(playlistID)) },
                notify: collectionActions.notify)
        ], firstSectionIsRow: false)
        if !playlist.isReadOnly || playlist.isSubscribed { Section {
            Button("从资料库删除", systemImage: "trash", role: .destructive) { library.pendingDeletion = playlist }
        } }
    }

    public init(playlistID: String,
                library: any FrontAMPlaylistSource,
                songs: [LibrarySongItem],
                availableSongs: (@MainActor () -> [LibrarySongItem])? = nil,
                externalActions: ExternalPlaylistActions? = nil,
                externalArtwork: AnyView? = nil,
                recentlyPlayedSongs: [LibrarySongItem] = []) {
        self.playlistID = playlistID
        self.library = library
        self.songs = songs
        self.availableSongs = availableSongs
        self.externalActions = externalActions
        self.externalArtwork = externalArtwork
        self.recentlyPlayedSongs = recentlyPlayedSongs
    }
}

public struct PlaylistTrackSelection: Equatable {
    public let id = UUID()
    public let playlistID: String
    public let ownerID: String?
    public let songID: String
    public let query: String
    public let sort: DetailSort

    public enum Outcome {
        case ready([LibrarySongItem], index: Int)
        case failed(String)
        case cancelled
    }

    @MainActor
    public func prepare(
        in library: any FrontAMPlaylistSource,
        projection: AsyncListProjection<TrackFilterProjectionInput, TrackFilterProjectionResult>
    ) async -> Outcome {
        guard isCurrent(in: library) else { return .cancelled }
        let complete = await library.prepareCompleteCollection(playlistID)
        guard isCurrent(in: library) else { return .cancelled }
        guard complete else {
            return .failed(library.onlineErrors[playlistID] ?? "播放列表尚未完整加载，请重试")
        }

        let input = TrackFilterProjectionInput(tracks: library.songs(in: playlistID), query: query, sort: sort)
        if let tracks = availableTracks(for: input, projection: projection) {
            return outcome(in: tracks)
        }
        guard let result = await TrackFilterProjection.result(for: input),
              isCurrent(in: library) else { return .cancelled }
        return outcome(in: result.tracks)
    }

    @MainActor
    private func isCurrent(in library: any FrontAMPlaylistSource) -> Bool {
        guard !Task.isCancelled, let playlist = library.playlist(playlistID) else { return false }
        return playlist.sourceOwnerID == ownerID
    }

    @MainActor
    public func availableTracks(
        for input: TrackFilterProjectionInput,
        projection: AsyncListProjection<TrackFilterProjectionInput, TrackFilterProjectionResult>
    ) -> [LibrarySongItem]? {
        if input.followsPlaylistOrder { return input.tracks }
        return projection.resolvedValue(for: input)?.tracks ?? TrackFilterProjection.fastPath(input)?.tracks
    }

    public func outcome(in tracks: [LibrarySongItem]) -> Outcome {
        guard let index = tracks.firstIndex(where: { $0.id == songID }) else {
            return .failed("歌曲已不在当前播放列表，请重试")
        }
        return .ready(tracks, index: index)
    }

    public init(playlistID: String,
                ownerID: String? = nil,
                songID: String,
                query: String,
                sort: DetailSort) {
        self.playlistID = playlistID
        self.ownerID = ownerID
        self.songID = songID
        self.query = query
        self.sort = sort
    }
}

private struct PlaylistDetailSearch: ViewModifier {
    @Binding var query: String
    let enabled: Bool
    func body(content: Content) -> some View {
        content.librarySearchable(text: $query, prompt: "搜索", enabled: enabled)
    }
}

extension View {
    public func playlistEditSheet(_ library: any FrontAMPlaylistSource, songs: @escaping @MainActor () -> [LibrarySongItem]) -> some View {
        modifier(PlaylistEditSheet(library: library, songs: songs))
    }
}

private struct PlaylistEditSheet: ViewModifier {
    let library: any FrontAMPlaylistSource
    let songs: @MainActor () -> [LibrarySongItem]

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { library.pendingEdit }, set: { library.pendingEdit = $0 })) { playlist in
            PlaylistEditorContent(playlistID: playlist.id, library: library, songs: songs)
        }
    }
}

private struct PlaylistEditorContent: View {
    let playlistID: String
    let library: any FrontAMPlaylistSource
    let songs: @MainActor () -> [LibrarySongItem]

    var body: some View {
        PlaylistEditor(playlistID: playlistID, library: library, availableSongs: songs())
    }
}

private struct PlaylistAddMusicContent: View {
    let playlistID: String
    let library: any FrontAMPlaylistSource
    let songs: @MainActor () -> [LibrarySongItem]
    let recentlyPlayedSongs: [LibrarySongItem]

    var body: some View {
        AddPlaylistMusicView(
            title: library.playlist(playlistID)?.title ?? "播放列表",
            songs: songs(),
            playlists: library.playlists,
            existingIDs: Set(library.songs(in: playlistID).map(\.id)),
            playlistLibrary: library,
            recentlyPlayedSongs: recentlyPlayedSongs
        ) { selected in
            library.addSongs(selected, to: playlistID)
        }
    }
}
