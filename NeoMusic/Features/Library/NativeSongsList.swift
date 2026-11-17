import SwiftUI
import UIKit

/// 基于 UICollectionView 的高性能歌曲列表。
struct NativeSongsList: UIViewControllerRepresentable {
    let songs: [LibrarySongItem]
    let play: (LibrarySongItem) -> Void
    let menu: (LibrarySongItem) -> UIMenu
    
    func makeUIViewController(context: Context) -> NativeSongsController {
        NativeSongsController()
    }
    
    func updateUIViewController(_ controller: NativeSongsController, context: Context) {
        controller.update(songs: songs, play: play, menu: menu)
    }
}

final class NativeSongsController: UICollectionViewController {
    private var songs: [LibrarySongItem] = []
    private var play: (LibrarySongItem) -> Void = { _ in }
    private var menu: (LibrarySongItem) -> UIMenu = { _ in UIMenu() }
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    init() {
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.backgroundColor = .clear
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .clear
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self, let song = self.songs.first(where: { $0.id == id }) else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                SongRow(song: song) { self.play(song) }
            }
            .margins(.horizontal, 20)
            .margins(.vertical, 0)
            
            cell.backgroundConfiguration = cell.defaultBackgroundConfiguration()
            cell.accessories = [.disclosureIndicator()]
        }
        
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    func update(songs: [LibrarySongItem], play: @escaping (LibrarySongItem) -> Void, menu: @escaping (LibrarySongItem) -> UIMenu) {
        self.songs = songs
        self.play = play
        self.menu = menu
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(songs.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: false)
    }
    
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if let id = dataSource.itemIdentifier(for: indexPath), let song = songs.first(where: { $0.id == id }) {
            play(song)
        }
    }
}
