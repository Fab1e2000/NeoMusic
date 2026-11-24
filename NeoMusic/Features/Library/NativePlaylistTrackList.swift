import SwiftUI
import UIKit

@MainActor @Observable
final class PlaylistScrollDistance {
    var distance: CGFloat = 0
}

extension EnvironmentValues {
    @Entry var playlistScrollDistance: PlaylistScrollDistance? = nil
}

enum NativePlaylistSwipeMode {
    case standard(animateFavoriteRemoval: Bool)
    case editablePlaylist(remove: (LibrarySongItem) -> Void)
}

@MainActor
enum CollectionTrackUI {
    static func translucentCellBackground(for cell: UICollectionViewListCell,
                                          state: UICellConfigurationState,
                                          traitCollection: UITraitCollection,
                                          palette: CollectionPagePalette? = nil) -> UIBackgroundConfiguration {
        var background = cell.defaultBackgroundConfiguration().updated(for: state)
        let isDark = traitCollection.userInterfaceStyle == .dark
        let overlay: UIColor = isDark ? .white : .black
        if state.isSwiped {
            background.backgroundColor = overlay.withAlphaComponent(0.06)
        } else if state.isSelected {
            if let palette {
                background.backgroundColor = palette.highlight
            } else {
                let selectionOverlay: UIColor = isDark ? .white : .black
                background.backgroundColor = selectionOverlay.withAlphaComponent(isDark ? 0.10 : 0.06)
            }
        } else {
            background.backgroundColor = .clear
        }
        background.cornerRadius = state.isSwiped ? 26 : 0
        return background
    }

    static func songAccessibilityLabel(for song: LibrarySongItem) -> String {
        var components = [song.title, song.artist]
        if let reason = song.unavailabilityReason, !reason.isEmpty {
            components.append(reason)
        }
        return components.joined(separator: ", ")
    }

    static func leadingSwipeConfiguration(for song: LibrarySongItem,
                                          songActions: SongMenuActions,
                                          notify: @escaping (LibraryToast) -> Void) -> UISwipeActionsConfiguration {
        let next = UIContextualAction(style: .normal, title: nil) { _, _, done in
            songActions.playNext(song)
            if !songActions.defersQueueNotice { notify(.playingNext) }
            done(true)
        }
        next.image = UIImage(systemName: "text.line.first.and.arrowtriangle.forward")
        next.backgroundColor = .systemIndigo
        next.accessibilityLabel = "插播"
        next.image?.accessibilityLabel = "插播"

        let later = UIContextualAction(style: .normal, title: nil) { _, _, done in
            songActions.playLater(song)
            if !songActions.defersQueueNotice { notify(.addedToQueue) }
            done(true)
        }
        later.image = UIImage(systemName: "text.line.last.and.arrowtriangle.forward")
        later.backgroundColor = .systemOrange
        later.accessibilityLabel = "添加到队列"
        later.image?.accessibilityLabel = "添加到队列"

        return UISwipeActionsConfiguration(actions: [next, later])
    }

    static func trailingSwipeConfiguration(for song: LibrarySongItem,
                                           mode: NativePlaylistSwipeMode,
                                           downloads: LibraryDownloads?,
                                           songActions: SongMenuActions,
                                           notify: @escaping (LibraryToast) -> Void) -> UISwipeActionsConfiguration? {
        switch mode {
        case .editablePlaylist(let remove):
            let removeAction = UIContextualAction(style: .normal, title: nil) { _, _, done in
                done(true)
                CenteredActionSheet.confirmRemoveFromPlaylist { remove(song) }
            }
            removeAction.image = UIImage(systemName: "minus.circle.fill")
            removeAction.backgroundColor = .systemRed
            removeAction.accessibilityLabel = "移除"
            removeAction.image?.accessibilityLabel = "移除"
            let configuration = UISwipeActionsConfiguration(actions: [removeAction])
            configuration.performsFirstActionWithFullSwipe = true
            return configuration

        case .standard(let animateFavoriteRemoval):
            let chosen = OnlineSongTrailingSwipe.actions(
                isFavorite: song.isFavorite,
                downloadState: downloads?.state(of: song.id),
                canDownload: downloads?.isDownloadable(song) == true
            )
            let items = chosen.map { action in
                standardTrailingAction(action, song: song, animateFavoriteRemoval: animateFavoriteRemoval,
                                       downloads: downloads, songActions: songActions, notify: notify)
            }
            guard !items.isEmpty else { return nil }
            let configuration = UISwipeActionsConfiguration(actions: items)
            configuration.performsFirstActionWithFullSwipe = true
            return configuration
        }
    }

    private static func standardTrailingAction(_ action: OnlineSongTrailingSwipe,
                                               song: LibrarySongItem,
                                               animateFavoriteRemoval: Bool,
                                               downloads: LibraryDownloads?,
                                               songActions: SongMenuActions,
                                               notify: @escaping (LibraryToast) -> Void) -> UIContextualAction {
        switch action {
        case .like:
            let like = UIContextualAction(style: .normal, title: nil) { _, _, done in
                done(true)
                let asyncFavorite = songActions.isAsynchronousFavorite(song)
                if !asyncFavorite { LibraryHaptics.success() }
                songActions.toggleFavorite(song)
                if !asyncFavorite { notify(.favorited) }
            }
            like.image = UIImage(systemName: "heart.fill")
            like.backgroundColor = .systemPink
            like.accessibilityLabel = "喜欢"
            like.image?.accessibilityLabel = "喜欢"
            return like
        case .download, .stopDownload:
            let active = action == .stopDownload
            let download = UIContextualAction(style: .normal, title: nil) { _, _, done in
                done(true)
                LibraryHaptics.impact()
                if active { downloads?.stop([song]) } else { downloads?.download([song]) }
            }
            download.image = UIImage(systemName: active ? "stop.fill" : "arrow.down")
            download.backgroundColor = .systemBlue
            download.accessibilityLabel = active ? "停止下载" : "下载"
            download.image?.accessibilityLabel = active ? "停止下载" : "下载"
            return download
        case .removeFromLiked:
            let remove = UIContextualAction(style: .normal, title: nil) { _, _, done in
                done(true)
                let asyncFavorite = songActions.isAsynchronousFavorite(song)
                CenteredActionSheet.confirmRemoveFromLiked {
                    if animateFavoriteRemoval {
                        withAnimation { songActions.removeFromFavorites(song) }
                    } else {
                        songActions.removeFromFavorites(song)
                    }
                    if !asyncFavorite { notify(.unfavorited) }
                }
            }
            remove.image = UIImage(systemName: "trash")
            remove.backgroundColor = .systemRed
            remove.accessibilityLabel = "从喜欢歌曲移除"
            remove.image?.accessibilityLabel = "从喜欢歌曲移除"
            return remove
        }
    }

    static func contextMenuConfiguration(for song: LibrarySongItem,
                                         traits: UITraitCollection,
                                         menuProvider: @escaping () -> UIMenu) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(identifier: song.id as NSString) {
            let lines = [song.title, song.artist, song.album]
            let size = MenuPreviewCard.size(for: lines, compatibleWith: traits)
            let host = UIHostingController(rootView: MenuPreviewCard(artwork: song.artwork, lines: lines)
                .frame(width: size.width, height: size.height))
            host.traitOverrides.preferredContentSizeCategory = traits.preferredContentSizeCategory
            host.safeAreaRegions = []
            host.preferredContentSize = size
            host.view.backgroundColor = .clear
            return host
        } actionProvider: { _ in
            menuProvider()
        }
    }
}

enum NativeTrackRowStyle {
    case artwork, trackNumber
}

struct NativeTrackSection: Equatable {
    let title: String
    let songIDs: [String]
}

struct NativePlaylistTrackList: UIViewControllerRepresentable {
    let songs: [LibrarySongItem]
    let title: String
    let header: AnyView?
    let banner: AnyView?
    let footer: AnyView?
    let showsAddMusicRow: Bool
    let pageColor: UIColor
    let scheme: ColorScheme
    var rowStyle: NativeTrackRowStyle = .artwork
    var indexedSections: [NativeTrackSection]? = nil
    var usesLibrarySongAppearance = false
    var rowCornerRadius: CGFloat = 5
    var headerSeparatorInset: CGFloat = 0
    var lastSongSeparatorLeading: CGFloat = 20
    var swipeMode: NativePlaylistSwipeMode = .standard(animateFavoriteRemoval: false)
    var scrollDistance: PlaylistScrollDistance? = nil
    var pendingPlaybackSongID: String? = nil
    let onPlaySong: (LibrarySongItem, Int) -> Void
    var onAddMusic: (() -> Void)? = nil
    var onReachedEnd: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> PlaylistTracksController {
        PlaylistTracksController()
    }

    func updateUIViewController(_ controller: PlaylistTracksController, context: Context) {
        controller.update(self, environment: context.environment)
    }
}

@MainActor
final class PlaylistTracksController: UICollectionViewController, UICollectionViewDataSourcePrefetching {
    private enum Section: Hashable {
        case main, indexed(String)
    }

    private enum Item: Hashable {
        case header, banner, sectionHeading(String), song(String), addMusic, footer
    }

    private var model: NativePlaylistTrackList?
    private var environment = EnvironmentValues()
    private var uniqueSongIDs: [String] = []
    private var songsByID: [String: LibrarySongItem] = [:]
    private var indexByID: [String: Int] = [:]
    private final class TrackDataSource: UICollectionViewDiffableDataSource<Section, Item> {
        override func indexTitles(for collectionView: UICollectionView) -> [String]? {
            let titles = snapshot().sectionIdentifiers.compactMap { section -> String? in
                if case .indexed(let title) = section { return title }
                return nil
            }
            return titles.isEmpty ? nil : titles
        }

        override func collectionView(_ collectionView: UICollectionView, indexPathForIndexTitle title: String,
                                     at index: Int) -> IndexPath {
            IndexPath(item: 0, section: snapshot().indexOfSection(.indexed(title)) ?? 0)
        }
    }

    private var source: TrackDataSource!
    private let headerHost = UIHostingController(rootView: AnyView(EmptyView()))
    private let bannerHost = UIHostingController(rootView: AnyView(EmptyView()))
    private var prefetchTasks: [IndexPath: Task<Void, Never>] = [:]
    private var observedSongID: String?
    private weak var observedAnalyzer: ThreadSafeSpectrumAnalyzer?
    private var observedActive = false
    private var playbackObservationToken = 0
    private var lastReachedEndCount: Int?

    init() {
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: .init(appearance: .plain)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.delaysContentTouches = false
        collectionView.clipsToBounds = false
        collectionView.prefetchDataSource = self
        collectionView.register(PlaylistTrackCell.self, forCellWithReuseIdentifier: "song")
        collectionView.register(AlbumSelectionCell.self, forCellWithReuseIdentifier: "trackNumber")
        collectionView.register(UICollectionViewListCell.self, forCellWithReuseIdentifier: "sectionHeading")
        collectionView.register(PlaylistAddMusicCell.self, forCellWithReuseIdentifier: "addMusic")
        collectionView.register(UICollectionViewListCell.self, forCellWithReuseIdentifier: "header")
        collectionView.register(UICollectionViewListCell.self, forCellWithReuseIdentifier: "banner")
        collectionView.register(UICollectionViewListCell.self, forCellWithReuseIdentifier: "footer")

        configureHostedController(headerHost)
        configureHostedController(bannerHost)

        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.backgroundColor = .clear
        configuration.separatorConfiguration.color = currentPalette.separator
        configuration.itemSeparatorHandler = { [weak self] path, separator in
            guard let self, let item = source?.itemIdentifier(for: path) else { return separator }
            var result = separator
            result.color = currentPalette.separator
            switch item {
            case .header:
                let inset = model?.headerSeparatorInset ?? 0
                result.topSeparatorVisibility = .hidden
                let hasRows = model?.songs.isEmpty == false || model?.showsAddMusicRow == true
                result.bottomSeparatorVisibility = hasRows && model?.usesLibrarySongAppearance != true ? .automatic : .hidden
                result.bottomSeparatorInsets = .init(top: 0, leading: inset, bottom: 0, trailing: inset)
            case .banner, .sectionHeading:
                result.topSeparatorVisibility = .hidden
                result.bottomSeparatorVisibility = .hidden
            case .footer:
                if model?.rowStyle != .trackNumber { result.topSeparatorVisibility = .hidden }
                result.bottomSeparatorVisibility = .hidden
            case .song(let id):
                result.topSeparatorVisibility = .automatic
                result.bottomSeparatorVisibility = .automatic
                let isLastSong = id == uniqueSongIDs.last
                let leading: CGFloat = (isLastSong && model?.showsAddMusicRow == false)
                    ? (model?.lastSongSeparatorLeading ?? 20)
                    : (model?.rowStyle == .trackNumber ? 51 : 80)
                result.bottomSeparatorInsets = .init(top: 0, leading: leading, bottom: 0, trailing: 20)
            case .addMusic:
                result.topSeparatorVisibility = .automatic
                result.bottomSeparatorVisibility = model?.songs.isEmpty == false ? .automatic : .hidden
                result.bottomSeparatorInsets = .init(top: 0, leading: 20, bottom: 0, trailing: 20)
            }
            return result
        }
        configuration.leadingSwipeActionsConfigurationProvider = { [weak self] path in
            guard let self, let song = song(at: path) else { return nil }
            return CollectionTrackUI.leadingSwipeConfiguration(
                for: song,
                songActions: environment.songMenuActions,
                notify: environment.collectionMenuActions.notify
            )
        }
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] path in
            guard let self, let model, let song = song(at: path) else { return nil }
            return CollectionTrackUI.trailingSwipeConfiguration(
                for: song,
                mode: model.swipeMode,
                downloads: environment.libraryDownloads,
                songActions: environment.songMenuActions,
                notify: environment.collectionMenuActions.notify
            )
        }
        collectionView.setCollectionViewLayout(UICollectionViewCompositionalLayout { section, environment in
            var sectionConfiguration = configuration
            if section > 0 { sectionConfiguration.headerMode = .firstItemInSection }
            return NSCollectionLayoutSection.list(using: sectionConfiguration, layoutEnvironment: environment)
        }, animated: false)

        source = TrackDataSource(collectionView: collectionView) { [weak self] collection, path, item in
            guard let self else { return nil }
            switch item {
            case .song(let id):
                if model?.rowStyle == .trackNumber {
                    let cell = collection.dequeueReusableCell(withReuseIdentifier: "trackNumber", for: path) as! AlbumSelectionCell
                    configureTrackNumberCell(cell, id: id)
                    return cell
                }
                let cell = collection.dequeueReusableCell(withReuseIdentifier: "song", for: path) as! PlaylistTrackCell
                configureSongCell(cell, id: id)
                return cell
            case .addMusic:
                let cell = collection.dequeueReusableCell(withReuseIdentifier: "addMusic", for: path) as! PlaylistAddMusicCell
                return cell
            case .header:
                return hostedCell(in: collection, at: path, identifier: "header", host: headerHost)
            case .banner:
                return hostedCell(in: collection, at: path, identifier: "banner", host: bannerHost)
            case .sectionHeading(let title):
                let cell = collection.dequeueReusableCell(withReuseIdentifier: "sectionHeading", for: path) as! UICollectionViewListCell
                var content = UIListContentConfiguration.plainHeader()
                content.text = title
                content.textProperties.color = .label
                content.textProperties.font = UIFontMetrics(forTextStyle: .subheadline)
                    .scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
                content.directionalLayoutMargins = .init(top: path.section == 1 ? 8 : 18, leading: 20, bottom: 6, trailing: 20)
                cell.contentConfiguration = content
                cell.backgroundConfiguration = .clear()
                cell.accessibilityTraits = .header
                return cell
            case .footer:
                let cell = collection.dequeueReusableCell(withReuseIdentifier: "footer", for: path) as! UICollectionViewListCell
                cell.backgroundConfiguration = .clear()
                cell.contentConfiguration = UIHostingConfiguration {
                    hosted(model?.footer)
                }.margins(.all, 0)
                return cell
            }
        }
        observePlayback()
    }

    private func configureHostedController(_ host: UIHostingController<AnyView>) {
        addChild(host)
        host.safeAreaRegions = []
        host.sizingOptions = .intrinsicContentSize
        host.view.backgroundColor = .clear
        host.view.clipsToBounds = false
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.didMove(toParent: self)
    }

    private func hostedCell(in collection: UICollectionView,
                            at path: IndexPath,
                            identifier: String,
                            host: UIHostingController<AnyView>) -> UICollectionViewListCell {
        let cell = collection.dequeueReusableCell(withReuseIdentifier: identifier, for: path) as! UICollectionViewListCell
        cell.backgroundConfiguration = .clear()
        if model?.rowStyle != .trackNumber {
            cell.clipsToBounds = false
            cell.contentView.clipsToBounds = false
        }
        if host.view.superview !== cell.contentView {
            cell.contentView.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor)
            ])
        }
        return cell
    }

    private func hosted<V: View>(_ content: V) -> some View {
        content
            .environment(\.songMenuActions, environment.songMenuActions)
            .environment(\.collectionMenuActions, environment.collectionMenuActions)
            .environment(\.libraryDownloads, environment.libraryDownloads)
            .environment(\.songRowPlayback, environment.songRowPlayback)
            .environment(\.songPlaybackIndicatorsActive, model?.rowStyle == .trackNumber ? environment.songPlaybackIndicatorsActive : true)
            .environment(\.collectionPagePalette, model?.rowStyle == .trackNumber ? environment.collectionPagePalette : nil)
            .environment(\.playlistScrollDistance, model?.scrollDistance)
            .environment(\.colorScheme, model?.scheme ?? environment.colorScheme)
            .environment(\.locale, environment.locale)
            .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
            .environment(\.scenePhase, environment.scenePhase)
            .environment(\.artworkLoadAction, environment.artworkLoadAction)
            .environment(\.nativeArtworkSurfaceEnabled, true)
    }

    func update(_ model: NativePlaylistTrackList, environment: EnvironmentValues) {
        loadViewIfNeeded()
        let previousSongs = songsByID
        let previousScheme = self.model?.scheme
        let previousColor = self.model?.pageColor
        let previousBanner = self.model?.banner != nil
        let previousAddMusic = self.model?.showsAddMusicRow
        let previousFooter = self.model?.footer != nil
        let previousHeader = self.model?.header != nil
        let previousTitle = self.model?.title
        let sectionsChanged = self.model?.indexedSections != model.indexedSections
        let previousLastID = uniqueSongIDs.last
        let previousPendingSongID = self.model?.pendingPlaybackSongID
        let songsChanged = self.model?.songs != model.songs
        let backgroundChanged = previousColor != model.pageColor
        let schemeChanged = previousScheme != model.scheme
        let playbackVisualsChanged = self.environment.scenePhase != environment.scenePhase
            || self.environment.songPlaybackIndicatorsActive != environment.songPlaybackIndicatorsActive
        let environmentChanged = self.environment.dynamicTypeSize != environment.dynamicTypeSize
            || self.environment.songRowPlayback !== environment.songRowPlayback
            || self.environment.libraryDownloads !== environment.libraryDownloads
            || self.environment.accessibilityReduceMotion != environment.accessibilityReduceMotion

        self.model = model
        self.environment = environment

        if songsChanged {
            var ids: [String] = []
            var byID: [String: LibrarySongItem] = [:]
            var indices: [String: Int] = [:]
            ids.reserveCapacity(model.songs.count)
            byID.reserveCapacity(model.songs.count)
            indices.reserveCapacity(model.songs.count)
            for (offset, song) in model.songs.enumerated() where byID[song.id] == nil {
                ids.append(song.id)
                byID[song.id] = song
                indices[song.id] = offset
            }
            if uniqueSongIDs.count != ids.count { lastReachedEndCount = nil }
            uniqueSongIDs = ids
            songsByID = byID
            indexByID = indices
        }
        if previousBanner && model.banner == nil { lastReachedEndCount = nil }
        let ids = uniqueSongIDs

        overrideUserInterfaceStyle = model.scheme == .dark ? .dark : .light
        collectionView.backgroundColor = model.pageColor
        collectionView.clipsToBounds = model.rowStyle == .trackNumber
        headerHost.rootView = model.header.map { AnyView(hosted($0)) } ?? AnyView(EmptyView())
        bannerHost.rootView = model.banner.map { AnyView(hosted($0)) } ?? AnyView(EmptyView())

        if previousPendingSongID != model.pendingPlaybackSongID {
            for path in collectionView.indexPathsForVisibleItems {
                guard case .song(let id) = source.itemIdentifier(for: path),
                      id == previousPendingSongID || id == model.pendingPlaybackSongID,
                      let cell = collectionView.cellForItem(at: path) as? PlaylistTrackCell else { continue }
                cell.setPreparingPlayback(id == model.pendingPlaybackSongID)
            }
        }

        let structureChanged = previousBanner != (model.banner != nil)
            || previousFooter != (model.footer != nil)
            || previousHeader != (model.header != nil)
            || previousAddMusic != model.showsAddMusicRow
            || previousSongs.count != ids.count
            || sectionsChanged
        let globalAppearanceChanged = schemeChanged || backgroundChanged || environmentChanged
        let albumTitleChanged = model.rowStyle == .trackNumber && previousTitle != model.title
        let albumPlaybackChanged = model.rowStyle == .trackNumber && playbackVisualsChanged
        guard songsChanged || structureChanged || globalAppearanceChanged || albumTitleChanged || albumPlaybackChanged
            || (ids.isEmpty && model.footer != nil) else {
            if playbackVisualsChanged { observePlayback() }
            return
        }

        let previous = source.snapshot()
        let oldIDs = previous.itemIdentifiers
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.main])
        var items: [Item] = model.header == nil ? [] : [.header]
        if model.banner != nil { items.append(.banner) }
        if model.indexedSections == nil { items.append(contentsOf: ids.map(Item.song)) }
        if model.showsAddMusicRow { items.append(.addMusic) }
        if model.footer != nil { items.append(.footer) }
        snapshot.appendItems(items)
        var groupedIDs: Set<String> = []
        for group in model.indexedSections ?? [] {
            let songs = group.songIDs.filter { songsByID[$0] != nil && groupedIDs.insert($0).inserted }
            guard !songs.isEmpty else { continue }
            let section = Section.indexed(group.title)
            snapshot.appendSections([section])
            snapshot.appendItems([.sectionHeading(group.title)] + songs.map(Item.song), toSection: section)
        }

        var reconfigured: [Item] = []
        let isNewAppearance = oldIDs.isEmpty
        if !isNewAppearance {
            if structureChanged || globalAppearanceChanged || albumTitleChanged {
                if model.header != nil && previousHeader { reconfigured.append(.header) }
                if model.banner != nil && previousBanner { reconfigured.append(.banner) }
                if model.footer != nil && previousFooter { reconfigured.append(.footer) }
            } else if ids.isEmpty, model.footer != nil, previousFooter {
                reconfigured.append(.footer)
            }
            for id in ids {
                guard let current = songsByID[id], let old = previousSongs[id] else { continue }
                let separatorChanged = (id == previousLastID) != (id == ids.last) || previousAddMusic != model.showsAddMusicRow
                let visualMetadataChanged = old.title != current.title
                    || old.artist != current.artist
                    || old.isFavorite != current.isFavorite
                    || old.unavailabilityReason != current.unavailabilityReason
                    || old.artwork != current.artwork
                    || old.trackNumber != current.trackNumber
                let playbackRowAffected = albumPlaybackChanged && environment.songRowPlayback?.hasCurrent == true
                    && environment.songRowPlayback?.current.id == id
                if visualMetadataChanged || globalAppearanceChanged || separatorChanged || playbackRowAffected {
                    reconfigured.append(.song(id))
                }
            }
        }
        let snapshotChanged = sectionsChanged || oldIDs != snapshot.itemIdentifiers
        guard snapshotChanged || !reconfigured.isEmpty else {
            if environmentChanged || playbackVisualsChanged || isNewAppearance { observePlayback() }
            return
        }
        let present = Set(snapshot.itemIdentifiers)
        snapshot.reconfigureItems(reconfigured.filter { present.contains($0) })
        let isSmallShrink = !isNewAppearance
            && ids.count < previousSongs.count
            && (previousSongs.count - ids.count) <= 2
            && !collectionView.isDragging
            && !collectionView.isDecelerating
        let wasAtTop = model.rowStyle == .artwork && !model.usesLibrarySongAppearance && !isNewAppearance
            && !collectionView.isDragging
            && !collectionView.isDecelerating
            && collectionView.contentOffset.y <= -collectionView.adjustedContentInset.top + 1
        let animateAlbumChanges = model.rowStyle == .trackNumber && !isNewAppearance && snapshotChanged
            && !collectionView.isDragging && !collectionView.isDecelerating && !environment.accessibilityReduceMotion
        source.apply(snapshot, animatingDifferences: model.rowStyle == .trackNumber ? animateAlbumChanges : isSmallShrink)
        if wasAtTop {
            collectionView.layoutIfNeeded()
            let topOffset = -collectionView.adjustedContentInset.top
            if abs(collectionView.contentOffset.y - topOffset) > 0.5 {
                collectionView.contentOffset.y = topOffset
            }
        }
        if environmentChanged || isNewAppearance { observePlayback() }
    }

    private var currentPalette: CollectionPagePalette {
        CollectionPagePalette(
            background: model?.pageColor ?? .systemBackground,
            isDark: model?.scheme == .dark
        )
    }

    private func secondaryColor() -> UIColor {
        currentPalette.secondary
    }

    private func configureSongCell(_ cell: PlaylistTrackCell, id: String) {
        guard let song = songsByID[id], let model else { return }
        let secondary = secondaryColor()
        let isCurrent = observedSongID == id
        cell.palette = currentPalette
        cell.configure(
            song: song,
            cornerRadius: model.rowCornerRadius,
            subtitleColor: secondary,
            favoriteColor: model.usesLibrarySongAppearance ? .systemYellow : secondary,
            downloadColor: secondary,
            moreColor: model.usesLibrarySongAppearance ? .label : secondary,
            isCurrent: isCurrent,
            isPlayingActive: isCurrent && observedActive,
            analyzer: environment.songRowPlayback?.spectrumAnalyzer,
            samples: { [weak self] in self?.environment.songRowPlayback?.spectrumLevels() ?? [] },
            downloads: environment.libraryDownloads,
            loadAction: environment.artworkLoadAction,
            menuProvider: { [weak self] in self?.menu(for: id) ?? UIMenu(children: []) }
        )
        cell.setPreparingPlayback(id == model.pendingPlaybackSongID)
    }

    private func configureTrackNumberCell(_ cell: AlbumSelectionCell, id: String) {
        guard let song = songsByID[id] else { return }
        let secondary = currentPalette.secondary
        cell.palette = currentPalette
        cell.more.tintColor = secondary
        cell.contentConfiguration = UIHostingConfiguration {
            hosted(NativeAlbumRowContent(song: song, secondary: Color(secondary)))
        }.margins(.all, 0).margins(.leading, 20).margins(.trailing, 2)
        cell.more.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.menu(for: id).children ?? [])
        }])
        cell.accessibilityLabel = CollectionTrackUI.songAccessibilityLabel(for: song)
        cell.accessibilityTraits.insert(.button)
        cell.setNeedsUpdateConfiguration()
    }

    private func song(at path: IndexPath) -> LibrarySongItem? {
        guard case .song(let id) = source.itemIdentifier(for: path) else { return nil }
        return songsByID[id]
    }

    private func observePlayback() {
        playbackObservationToken &+= 1
        let token = playbackObservationToken
        let playback = environment.songRowPlayback
        let sceneActive = environment.scenePhase == .active
        let indicatorsActive = environment.songPlaybackIndicatorsActive
        let reduceMotion = environment.accessibilityReduceMotion
        let (hasCurrent, currentID, isPlaying, isLoading, analyzer) = withObservationTracking {
            (playback?.hasCurrent == true, playback?.current.id, playback?.isPlaying == true, playback?.isLoading == true, playback?.spectrumAnalyzer)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.playbackObservationToken == token else { return }
                self.observePlayback()
            }
        }
        let nextID = hasCurrent ? currentID : nil
        let nextActive = indicatorsActive && isPlaying && !isLoading && sceneActive && !reduceMotion
        let oldID = observedSongID
        let oldActive = observedActive
        let analyzerChanged = analyzer !== observedAnalyzer
        observedAnalyzer = analyzer
        observedSongID = nextID
        observedActive = nextActive
        guard oldID != nextID || oldActive != nextActive || analyzerChanged else { return }
        for path in collectionView.indexPathsForVisibleItems {
            guard case .song(let id) = source.itemIdentifier(for: path),
                  id == oldID || id == nextID,
                  let cell = collectionView.cellForItem(at: path) as? PlaylistTrackCell else { continue }
            let isCurrent = nextID == id
            cell.updatePlaybackState(isCurrent: isCurrent, isActive: isCurrent && nextActive, analyzer: analyzer) { [weak self] in
                self?.environment.songRowPlayback?.spectrumLevels() ?? []
            }
        }
    }

    private func menu(for id: String) -> UIMenu {
        guard let song = songsByID[id] else { return UIMenu(children: []) }
        let removeAction: (() -> Void)?
        if case .editablePlaylist(let remove) = model?.swipeMode {
            removeAction = { remove(song) }
        } else {
            removeAction = nil
        }
        let open = environment.openLibraryRoute
        if model?.rowStyle == .trackNumber {
            let downloads = environment.libraryDownloads
            let sections = environment.songMenuActions.albumTrackSections(for: song,
                isDownloaded: downloads?.state(of: id) == .downloaded,
                download: { downloads?.download([song]) }, removeDownload: { downloads?.requestRemoval([song]) },
                notify: environment.collectionMenuActions.notify, open: { open($0) })
            return sections.nativeMenu(firstSectionIsRow: (sections.first?.count ?? 0) > 1)
        }
        let sections = environment.songMenuActions.rowMenuSections(
            for: song,
            inAlbum: false,
            removeFromPlaylist: removeAction,
            open: { [actions = environment.songMenuActions] route in open(route, preview: actions.albumPreview(song, route)) }
        )
        return sections.nativeMenu(firstSectionIsRow: (sections.first?.count ?? 0) > 1)
    }

    override func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch source.itemIdentifier(for: indexPath) {
        case .song, .addMusic: true
        default: false
        }
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch source.itemIdentifier(for: indexPath) {
        case .song, .addMusic: true
        default: false
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        defer { collectionView.deselectItem(at: indexPath, animated: true) }
        switch source.itemIdentifier(for: indexPath) {
        case .song(let id):
            guard let song = songsByID[id], let index = indexByID[id] else { return }
            model?.onPlaySong(song, index)
        case .addMusic:
            model?.onAddMusic?()
        default:
            break
        }
    }

    override func collectionView(_ collectionView: UICollectionView,
                                 contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                                 point: CGPoint) -> UIContextMenuConfiguration? {
        guard let path = indexPaths.first, let song = song(at: path) else { return nil }
        return CollectionTrackUI.contextMenuConfiguration(for: song, traits: collectionView.traitCollection) { [weak self] in
            self?.menu(for: song.id) ?? UIMenu(children: [])
        }
    }

    override func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if let cell = cell as? PlaylistTrackCell, case .song(let id) = source.itemIdentifier(for: indexPath) {
            cell.setSpectrumDisplayed(true)
            cell.updatePlaybackState(isCurrent: observedSongID == id, isActive: observedActive,
                                     analyzer: observedAnalyzer) { [weak self] in
                self?.environment.songRowPlayback?.spectrumLevels() ?? []
            }
        }
        let prefetchThreshold = min(15, max(3, uniqueSongIDs.count / 4))
        guard let onReachedEnd = model?.onReachedEnd, !uniqueSongIDs.isEmpty,
              case .song(let id) = source.itemIdentifier(for: indexPath),
              uniqueSongIDs.suffix(prefetchThreshold).contains(id),
              lastReachedEndCount != uniqueSongIDs.count else { return }
        lastReachedEndCount = uniqueSongIDs.count
        onReachedEnd()
    }

    override func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? PlaylistTrackCell)?.setSpectrumDisplayed(false)
    }

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let scrollDistance = model?.scrollDistance else { return }
        let next = min(scrollView.contentOffset.y + scrollView.adjustedContentInset.top, 500)
        if abs(scrollDistance.distance - next) > 0.25 {
            scrollDistance.distance = next
        }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard model?.rowStyle != .trackNumber else { return }
        let pixels = LocalArtworkImages.pixelSize(48 * max(1, traitCollection.displayScale))
        let loadAction = environment.artworkLoadAction
        for path in indexPaths {
            guard case .song(let id) = source.itemIdentifier(for: path),
                  let song = songsByID[id],
                  prefetchTasks[path] == nil else { continue }
            switch song.artwork {
            case .file(let url):
                guard LocalArtworkImages.cached(url, pixels: pixels) == nil else { continue }
                prefetchTasks[path] = Task { [weak self] in
                    defer { self?.prefetchTasks[path] = nil }
                    _ = await LocalArtworkImages.loadThumbnail(url, pixels: pixels)
                }
            case .deferred(let loadID, _):
                if LocalArtworkImages.cachedResolved(loadID, pixels: pixels) != nil { continue }
                if let resolved = LocalArtworkImages.resolvedURL(for: loadID) {
                    prefetchTasks[path] = Task { [weak self] in
                        defer { self?.prefetchTasks[path] = nil }
                        _ = await LocalArtworkImages.loadThumbnail(resolved, pixels: pixels)
                    }
                    continue
                }
                prefetchTasks[path] = Task { [weak self] in
                    defer { self?.prefetchTasks[path] = nil }
                    if let file = await loadAction.resolve?(loadID) {
                        guard !Task.isCancelled else { return }
                        LocalArtworkImages.registerResolvedArtwork(loadID, url: file)
                        _ = await LocalArtworkImages.loadThumbnail(file, pixels: pixels)
                        return
                    }
                    guard !Task.isCancelled else { return }
                    loadAction(loadID)
                }
            default:
                break
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for path in indexPaths {
            prefetchTasks.removeValue(forKey: path)?.cancel()
        }
    }
}

private final class PlaylistTrackCell: UICollectionViewListCell {
    private let favoriteStar = UIImageView()
    private let artworkContainer = UIView()
    private let placeholderView = UIView()
    private let placeholderIcon = UIImageView()
    private let artworkImageView = UIImageView()
    private let playbackOverlay = UIView()
    private let spectrumView = SpectrumBarsView()
    private var spectrumDisplayed = false
    func setSpectrumDisplayed(_ displayed: Bool) {
        spectrumDisplayed = displayed
        if !displayed { spectrumView.active = false }
    }
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let textStack = UIStackView()
    private let downloadBadge = PlaylistDownloadBadgeView()
    private let moreButton = UIButton(type: .system)
    private var isPreparingPlayback = false
    private lazy var playbackPreparationIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.backgroundColor = .systemBackground.withAlphaComponent(0.9)
        indicator.layer.cornerRadius = 15
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.isUserInteractionEnabled = false
        artworkContainer.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: artworkContainer.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: artworkContainer.centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 30),
            indicator.heightAnchor.constraint(equalToConstant: 30)
        ])
        return indicator
    }()

    private var song: LibrarySongItem?
    private var downloads: LibraryDownloads?
    private var loadAction = ArtworkLoadAction()
    private var menuProvider: () -> UIMenu = { UIMenu(children: []) }
    private var artworkGeneration = 0
    private var downloadObservationToken = 0
    private var artworkObservationToken = 0
    private var artworkLoadTask: Task<Void, Never>?
    private var loadedImageURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        automaticallyUpdatesBackgroundConfiguration = false

        let starConfig = UIImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        favoriteStar.image = UIImage(systemName: "star.fill", withConfiguration: starConfig)
        favoriteStar.contentMode = .center
        favoriteStar.translatesAutoresizingMaskIntoConstraints = false
        favoriteStar.isHidden = true
        contentView.addSubview(favoriteStar)

        artworkContainer.clipsToBounds = true
        artworkContainer.layer.borderColor = UIColor.black.withAlphaComponent(0.06).cgColor
        artworkContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(artworkContainer)

        placeholderView.backgroundColor = .secondarySystemFill
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.addSubview(placeholderView)

        placeholderIcon.tintColor = .tertiaryLabel
        placeholderIcon.contentMode = .scaleAspectFit
        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false
        placeholderView.addSubview(placeholderIcon)

        artworkImageView.contentMode = .scaleAspectFill
        artworkImageView.clipsToBounds = true
        artworkImageView.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.addSubview(artworkImageView)

        playbackOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        playbackOverlay.isHidden = true
        playbackOverlay.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.addSubview(playbackOverlay)

        spectrumView.barColor = .white
        spectrumView.translatesAutoresizingMaskIntoConstraints = false
        playbackOverlay.addSubview(spectrumView)

        titleLabel.font = .preferredFont(forTextStyle: .callout)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label

        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.adjustsFontForContentSizeCategory = true

        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)
        contentView.addSubview(textStack)

        downloadBadge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(downloadBadge)

        let moreConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        moreButton.setImage(UIImage(systemName: "ellipsis", withConfiguration: moreConfig), for: .normal)
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.accessibilityLabel = "更多"
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(moreButton)

        moreButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.menuProvider().children ?? [])
        }])

        let starCenterConstraint = favoriteStar.centerXAnchor.constraint(equalTo: artworkContainer.leadingAnchor, constant: -10.5)
        let artworkTop = artworkContainer.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 4)
        let artworkBottom = artworkContainer.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -4)
        let textTop = textStack.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 4)
        let textBottom = textStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -4)

        NSLayoutConstraint.activate([
            artworkContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            artworkContainer.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            artworkContainer.widthAnchor.constraint(equalToConstant: 48),
            artworkContainer.heightAnchor.constraint(equalToConstant: 48),
            artworkTop, artworkBottom,

            starCenterConstraint,
            favoriteStar.centerYAnchor.constraint(equalTo: artworkContainer.centerYAnchor),
            favoriteStar.widthAnchor.constraint(equalToConstant: 10),
            favoriteStar.heightAnchor.constraint(equalToConstant: 12),

            placeholderView.leadingAnchor.constraint(equalTo: artworkContainer.leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: artworkContainer.trailingAnchor),
            placeholderView.topAnchor.constraint(equalTo: artworkContainer.topAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor),

            placeholderIcon.centerXAnchor.constraint(equalTo: placeholderView.centerXAnchor),
            placeholderIcon.centerYAnchor.constraint(equalTo: placeholderView.centerYAnchor),
            placeholderIcon.widthAnchor.constraint(equalToConstant: 18),
            placeholderIcon.heightAnchor.constraint(equalToConstant: 18),

            artworkImageView.leadingAnchor.constraint(equalTo: artworkContainer.leadingAnchor),
            artworkImageView.trailingAnchor.constraint(equalTo: artworkContainer.trailingAnchor),
            artworkImageView.topAnchor.constraint(equalTo: artworkContainer.topAnchor),
            artworkImageView.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor),

            playbackOverlay.leadingAnchor.constraint(equalTo: artworkContainer.leadingAnchor),
            playbackOverlay.trailingAnchor.constraint(equalTo: artworkContainer.trailingAnchor),
            playbackOverlay.topAnchor.constraint(equalTo: artworkContainer.topAnchor),
            playbackOverlay.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor),

            spectrumView.centerXAnchor.constraint(equalTo: playbackOverlay.centerXAnchor),
            spectrumView.centerYAnchor.constraint(equalTo: playbackOverlay.centerYAnchor),
            spectrumView.widthAnchor.constraint(equalToConstant: 16),
            spectrumView.heightAnchor.constraint(equalToConstant: 20),

            textStack.leadingAnchor.constraint(equalTo: artworkContainer.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textTop, textBottom,

            moreButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            moreButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 44),
            moreButton.heightAnchor.constraint(equalToConstant: 44),

            downloadBadge.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: 2),
            downloadBadge.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            textStack.trailingAnchor.constraint(lessThanOrEqualTo: downloadBadge.leadingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkGeneration &+= 1
        artworkObservationToken &+= 1
        downloadObservationToken &+= 1
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        loadedImageURL = nil
        artworkImageView.image = nil
        playbackOverlay.isHidden = true
        setSpectrumDisplayed(false)
        setPreparingPlayback(false)
        song = nil
        downloads = nil
    }

    func configure(song: LibrarySongItem,
                   cornerRadius: CGFloat,
                   subtitleColor: UIColor,
                   favoriteColor: UIColor,
                   downloadColor: UIColor,
                   moreColor: UIColor,
                   isCurrent: Bool,
                   isPlayingActive: Bool,
                   analyzer: ThreadSafeSpectrumAnalyzer? = nil,
                   samples: @escaping () -> [Float],
                   downloads: LibraryDownloads?,
                   loadAction: ArtworkLoadAction,
                   menuProvider: @escaping () -> UIMenu) {
        let sameSong = self.song?.id == song.id
        self.song = song
        self.downloads = downloads
        self.loadAction = loadAction
        self.menuProvider = menuProvider

        let scale = max(1, traitCollection.displayScale)
        artworkContainer.layer.cornerRadius = cornerRadius
        artworkContainer.layer.borderWidth = 1 / scale
        playbackOverlay.layer.cornerRadius = cornerRadius

        let isAccessibility = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        titleLabel.numberOfLines = isAccessibility ? 0 : 1
        subtitleLabel.numberOfLines = isAccessibility ? 0 : 1
        titleLabel.text = song.title
        titleLabel.textColor = song.unavailabilityReason == nil ? .label : .secondaryLabel
        subtitleLabel.text = song.unavailabilityReason ?? song.artist
        subtitleLabel.textColor = subtitleColor

        favoriteStar.isHidden = !song.isFavorite
        favoriteStar.tintColor = favoriteColor
        moreButton.tintColor = moreColor
        downloadBadge.secondaryColor = downloadColor
        isAccessibilityElement = false
        accessibilityLabel = CollectionTrackUI.songAccessibilityLabel(for: song)
        accessibilityTraits.insert(.button)

        updatePlaybackState(isCurrent: isCurrent, isActive: isPlayingActive, analyzer: analyzer, samples: samples)
        observeArtwork(retainingImage: sameSong)
        observeDownloads()
        setNeedsUpdateConfiguration()
    }

    func setPreparingPlayback(_ preparing: Bool) {
        guard isPreparingPlayback != preparing else { return }
        isPreparingPlayback = preparing
        accessibilityValue = preparing ? "正在准备播放" : nil
        if preparing { playbackPreparationIndicator.startAnimating() }
        else { playbackPreparationIndicator.stopAnimating() }
    }

    func updatePlaybackState(isCurrent: Bool, isActive: Bool, analyzer: ThreadSafeSpectrumAnalyzer? = nil, samples: @escaping () -> [Float]) {
        spectrumView.analyzer = analyzer
        playbackOverlay.isHidden = !isCurrent
        if isCurrent {
            spectrumView.samples = samples
            spectrumView.active = isActive && spectrumDisplayed
        } else {
            spectrumView.active = false
            spectrumView.stop()
        }
    }

    var palette: CollectionPagePalette? {
        didSet { if oldValue != palette { setNeedsUpdateConfiguration() } }
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        backgroundConfiguration = CollectionTrackUI.translucentCellBackground(for: self, state: state, traitCollection: traitCollection, palette: palette)
    }

    private func observeArtwork(retainingImage: Bool) {
        artworkObservationToken &+= 1
        let token = artworkObservationToken
        guard let song else { return }
        let artwork = withObservationTracking { song.artwork } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.artworkObservationToken == token else { return }
                self.observeArtwork(retainingImage: true)
            }
        }
        applyArtwork(artwork, retainingImage: retainingImage)
    }

    private func applyArtwork(_ artwork: Artwork, retainingImage: Bool) {
        artworkGeneration &+= 1
        let generation = artworkGeneration
        artworkLoadTask?.cancel()
        artworkLoadTask = nil

        let pixels = LocalArtworkImages.pixelSize(48 * max(1, traitCollection.displayScale))
        placeholderView.isHidden = false
        switch artwork {
        case .favorites:
            placeholderView.backgroundColor = UIColor(Artwork.favoritesBackground)
            placeholderIcon.image = UIImage(systemName: "star.fill")
            placeholderIcon.tintColor = UIColor(Artwork.favoritesRed)
            artworkImageView.image = nil
            loadedImageURL = nil
        case .playlist:
            configurePlaceholder(symbol: "music.note.list")
            artworkImageView.image = nil
            loadedImageURL = nil
        case .missing, .folder:
            configurePlaceholder(symbol: "music.note")
            artworkImageView.image = nil
            loadedImageURL = nil
        case .deferred(let loadID, let kind):
            configurePlaceholder(symbol: kind == .playlist ? "music.note.list" : "music.note")
            if let cached = LocalArtworkImages.cachedResolved(loadID, pixels: pixels) {
                loadedImageURL = LocalArtworkImages.resolvedURL(for: loadID)
                artworkImageView.image = cached
                placeholderView.isHidden = true
                return
            }
            if let resolved = LocalArtworkImages.resolvedURL(for: loadID) {
                if !retainingImage || loadedImageURL != resolved {
                    artworkImageView.image = nil
                    loadedImageURL = nil
                }
                artworkLoadTask = Task { [weak self] in
                    let loaded = await self?.loadFileImage(resolved, pixels: pixels, generation: generation) ?? true
                    guard !loaded, !Task.isCancelled else { return }
                    if let file = await self?.loadAction.resolve?(loadID) {
                        guard !Task.isCancelled else { return }
                        LocalArtworkImages.registerResolvedArtwork(loadID, url: file)
                        _ = await self?.loadFileImage(file, pixels: pixels, generation: generation)
                        return
                    }
                    guard !Task.isCancelled else { return }
                    self?.loadAction(loadID)
                }
                return
            }
            if !retainingImage {
                artworkImageView.image = nil
                loadedImageURL = nil
            }
            guard let resolve = loadAction.resolve else {
                loadAction(loadID)
                return
            }
            artworkLoadTask = Task { [weak self] in
                if let file = await resolve(loadID) {
                    guard !Task.isCancelled else { return }
                    LocalArtworkImages.registerResolvedArtwork(loadID, url: file)
                    await self?.loadFileImage(file, pixels: pixels, generation: generation)
                    return
                }
                guard !Task.isCancelled else { return }
                self?.loadAction(loadID)
            }
        case .file(let url):
            configurePlaceholder(symbol: "music.note")
            if let cached = LocalArtworkImages.cached(url, pixels: pixels) {
                loadedImageURL = url
                artworkImageView.image = cached
                placeholderView.isHidden = true
                return
            }
            if !retainingImage || loadedImageURL != url {
                artworkImageView.image = nil
                loadedImageURL = nil
            }
            artworkLoadTask = Task { [weak self] in
                await self?.loadFileImage(url, pixels: pixels, generation: generation)
            }
        case .image(let swiftUIImage):
            configurePlaceholder(symbol: "music.note")
            let renderer = ImageRenderer(content: swiftUIImage.resizable().scaledToFill().frame(width: 48, height: 48))
            renderer.scale = max(1, traitCollection.displayScale)
            artworkImageView.image = renderer.uiImage
            placeholderView.isHidden = artworkImageView.image != nil
        }
    }

    private func configurePlaceholder(symbol: String) {
        placeholderView.backgroundColor = .secondarySystemFill
        placeholderIcon.image = UIImage(systemName: symbol)
        placeholderIcon.tintColor = .tertiaryLabel
    }

    @discardableResult
    private func loadFileImage(_ url: URL, pixels: Int, generation: Int) async -> Bool {
        let image = await LocalArtworkImages.loadThumbnail(url, pixels: pixels)
        guard !Task.isCancelled, artworkGeneration == generation else { return true }
        guard let image else { return false }
        let shouldCrossDissolve = artworkImageView.image == nil
            && !traitCollection.accessibilityContrast.isHigh
            && !UIAccessibility.isReduceMotionEnabled
        loadedImageURL = url
        if shouldCrossDissolve {
            UIView.transition(with: artworkImageView, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.artworkImageView.image = image
            }
        } else {
            artworkImageView.image = image
        }
        placeholderView.isHidden = true
        return true
    }

    private func observeDownloads() {
        downloadObservationToken &+= 1
        let token = downloadObservationToken
        guard let song else {
            downloadBadge.configure(state: nil, visible: false, onTap: nil)
            return
        }
        guard let downloads, song.isOnline || downloads.managedSongIDs.contains(song.id) else {
            downloadBadge.configure(state: nil, visible: false, onTap: nil)
            return
        }
        let state = withObservationTracking {
            downloads.state(of: song.id)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.downloadObservationToken == token else { return }
                self.observeDownloads()
            }
        }
        downloadBadge.configure(state: state, visible: state != nil) { [weak self] in
            guard let self, let song = self.song, let downloads = self.downloads else { return }
            if case .failed = state {
                guard downloads.isDownloadable(song) else { return }
                LibraryHaptics.impact()
                downloads.download([song])
            } else if state?.isActive == true {
                LibraryHaptics.impact()
                downloads.stop([song])
            }
        }
    }
}

private extension UIAccessibilityContrast {
    var isHigh: Bool { self == .high }
}

private final class PlaylistDownloadBadgeView: UIView {
    var secondaryColor: UIColor = UIColor.label.withAlphaComponent(0.26) {
        didSet { imageView.tintColor = secondaryColor }
    }
    private let button = UIButton(type: .system)
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private var widthConstraint: NSLayoutConstraint!
    private var tapHandler: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: 44)
        ])

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        spinner.isUserInteractionEnabled = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        let ringRect = CGRect(x: 15, y: 16, width: 12, height: 12)
        let ringPath = UIBezierPath(arcCenter: CGPoint(x: ringRect.midX, y: ringRect.midY),
                                    radius: 6, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true).cgPath
        trackLayer.path = ringPath
        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.lineWidth = 1.7
        trackLayer.strokeColor = UIColor.label.withAlphaComponent(0.3).cgColor
        trackLayer.isHidden = true
        layer.addSublayer(trackLayer)

        progressLayer.path = ringPath
        progressLayer.fillColor = UIColor.clear.cgColor
        progressLayer.lineWidth = 1.7
        progressLayer.lineCap = .round
        progressLayer.strokeColor = UIColor.label.cgColor
        progressLayer.strokeEnd = 0
        progressLayer.isHidden = true
        layer.addSublayer(progressLayer)

        button.addAction(UIAction { [weak self] _ in self?.tapHandler?() }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        NSLayoutConstraint.activate([
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 14),
            imageView.heightAnchor.constraint(equalToConstant: 14),

            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 3),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),

            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (_: PlaylistDownloadBadgeView, _: UITraitCollection) in
            self?.trackLayer.strokeColor = UIColor.label.withAlphaComponent(0.3).cgColor
            self?.progressLayer.strokeColor = UIColor.label.cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if button.isUserInteractionEnabled {
            return bounds.inset(by: UIEdgeInsets(top: 0, left: -12, bottom: 0, right: 0)).contains(point)
        }
        return super.point(inside: point, with: event)
    }

    func configure(state: LibraryDownloads.SongState?, visible: Bool, onTap: (() -> Void)?) {
        tapHandler = onTap
        imageView.isHidden = true
        spinner.stopAnimating()
        spinner.isHidden = true
        trackLayer.isHidden = true
        progressLayer.isHidden = true
        button.isUserInteractionEnabled = false

        guard visible, let state else {
            widthConstraint.constant = 0
            isHidden = true
            return
        }

        isHidden = false
        switch state {
        case .downloaded:
            widthConstraint.constant = 14
            imageView.image = UIImage(systemName: "arrow.down.circle.fill",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
            imageView.tintColor = secondaryColor
            imageView.isHidden = false
            accessibilityLabel = "已下载"
        case .failed:
            widthConstraint.constant = 28
            imageView.image = UIImage(systemName: "exclamationmark.circle",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14))
            imageView.tintColor = .label
            imageView.isHidden = false
            button.isUserInteractionEnabled = true
            button.accessibilityLabel = "下载失败，轻点重试"
        case .queued, .waiting, .downloading:
            widthConstraint.constant = 28
            let progress: CGFloat = if case .downloading(let value) = state { CGFloat(min(1, max(0, value))) } else { 0 }
            trackLayer.isHidden = false
            progressLayer.isHidden = false
            progressLayer.strokeEnd = progress
            button.isUserInteractionEnabled = true
            button.accessibilityLabel = state == .waiting ? "等待 Wi-Fi，轻点停止下载" : "停止下载"
        case .finishing:
            widthConstraint.constant = 28
            spinner.isHidden = false
            spinner.startAnimating()
            button.isUserInteractionEnabled = true
            button.accessibilityLabel = "停止下载"
        }
    }
}

private final class PlaylistAddMusicCell: UICollectionViewListCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        automaticallyUpdatesBackgroundConfiguration = false

        let iconBox = UIView()
        iconBox.backgroundColor = .tertiarySystemFill
        iconBox.layer.cornerRadius = 5
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(iconBox)

        let plusIcon = UIImageView(image: UIImage(systemName: "plus",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)))
        plusIcon.tintColor = .label
        plusIcon.contentMode = .scaleAspectFit
        plusIcon.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(plusIcon)

        let label = UILabel()
        label.text = "添加音乐"
        label.font = .systemFont(ofSize: 16)
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)

        NSLayoutConstraint.activate([
            iconBox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            iconBox.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            iconBox.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            iconBox.widthAnchor.constraint(equalToConstant: 48),
            iconBox.heightAnchor.constraint(equalToConstant: 48),

            plusIcon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            plusIcon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),

            label.leadingAnchor.constraint(equalTo: iconBox.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var palette: CollectionPagePalette? {
        didSet { if oldValue != palette { setNeedsUpdateConfiguration() } }
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        backgroundConfiguration = CollectionTrackUI.translucentCellBackground(for: self, state: state, traitCollection: traitCollection, palette: palette)
    }
}

private struct NativeAlbumRowContent: View {
    let song: LibrarySongItem
    let secondary: Color
    @Environment(\.libraryDownloads) private var downloads
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        HStack(spacing: 9) {
            AlbumSongPosition(song: song, foreground: secondary)
            Text(song.title).font(.callout).foregroundStyle(.primary)
                .lineLimit(textSize.isAccessibilitySize ? nil : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            SongDownloadStatus(song: song, secondaryStyle: AnyShapeStyle(secondary))
        }
        .frame(minHeight: 52 + 1.0 / 3)
    }
}

final class AlbumSelectionCell: UICollectionViewListCell {
    let more = UIButton(type: .system)
    var palette: CollectionPagePalette? {
        didSet { if oldValue != palette { setNeedsUpdateConfiguration() } }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        automaticallyUpdatesBackgroundConfiguration = false
        more.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        more.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
        more.tintColor = .label
        more.showsMenuAsPrimaryAction = true
        more.accessibilityLabel = "更多"
        accessories = [.customView(configuration: .init(customView: more, placement: .trailing(),
            reservedLayoutWidth: .custom(44), maintainsFixedSize: true))]
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        backgroundConfiguration = CollectionTrackUI.translucentCellBackground(for: self, state: state, traitCollection: traitCollection, palette: palette)
    }
}
