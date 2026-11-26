import FrontAM
import SwiftUI
import UIKit

@MainActor
struct ShowcaseCatalog {
    struct Album {
        let id: String
        let title: String
        let artistID: String
        let cover: Cover
        let songs: [LibrarySongItem]
    }

    struct Artist {
        let id: String
        let name: String
        let cover: Cover
    }

    struct Cover {
        let image: UIImage
        let url: URL?
        let backdrop: AlbumArtworkBackdrop?

        var artwork: Artwork {
            url.map(Artwork.file) ?? .image(Image(uiImage: image))
        }

        init(_ name: String, hue: CGFloat, variant: Int) {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let bounds = CGRect(x: 0, y: 0, width: 640, height: 640)
            let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { output in
                let context = output.cgContext
                let colors = [
                    UIColor(hue: hue, saturation: 0.7, brightness: 0.21, alpha: 1).cgColor,
                    UIColor(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.79, brightness: 0.83, alpha: 1).cgColor,
                    UIColor(hue: (hue + 0.22).truncatingRemainder(dividingBy: 1), saturation: 0.58, brightness: 0.58, alpha: 1).cgColor
                ]
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                             colors: colors as CFArray, locations: [0, 0.56, 1]) {
                    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 640, y: 640), options: [])
                }
                context.setBlendMode(.screen)
                for index in 0..<6 {
                    let size = CGFloat(110 + index * 70)
                    let center = CGFloat(200 + variant * 29 + index * 17)
                    context.setStrokeColor(UIColor(white: 1, alpha: 0.2 + Double(index) * 0.055).cgColor)
                    context.setLineWidth(CGFloat(2 + index * 3))
                    let shape = CGRect(x: center - size / 2, y: 320 - size * 0.34, width: size, height: size * 0.68)
                    context.saveGState()
                    context.translateBy(x: 320, y: 320)
                    context.rotate(by: CGFloat(variant * 2 + index) * .pi / 17)
                    context.translateBy(x: -320, y: -320)
                    if variant.isMultiple(of: 2) { context.strokeEllipse(in: shape) }
                    else { context.stroke(shape) }
                    context.restoreGState()
                }
            }
            self.image = image
            backdrop = image.cgImage.flatMap { AlbumArtworkBackdrop.extract(from: $0) }
            // Both the page thumbnail cache and the player consume the same generated file.
            let directory = URL.cachesDirectory.appending(path: "ShowcaseCovers", directoryHint: .isDirectory)
            let destination = directory.appending(path: "\(name).png")
            if let data = image.pngData(),
               (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
               (try? data.write(to: destination, options: .atomic)) != nil {
                url = destination
            } else {
                url = nil
            }
        }
    }

    let artists: [Artist]
    let albums: [Album]
    let playlistCover: Cover
    var songs: [LibrarySongItem] { albums.flatMap(\.songs) }

    init() {
        let artists = [
            Artist(id: "violet-orbit", name: "紫弧邮差", cover: Cover("violet-orbit", hue: 0.73, variant: 4)),
            Artist(id: "paper-current", name: "折纸洋流", cover: Cover("paper-current", hue: 0.51, variant: 5))
        ]
        self.artists = artists
        let releases: [(String, String, Int, CGFloat, [String])] = [
            ("lunar-station", "月背转运站", 0, 0.66, ["零号月台", "紫弧信标", "凌晨轨道"]),
            ("glass-tides", "玻璃潮汐图", 1, 0.42, ["折光航线", "潮位留白", "蓝色回流"]),
            ("noon-parallax", "正午视差", 0, 0.07, ["慢速日晷", "琥珀风向", "光穿过刻度"])
        ]
        albums = releases.enumerated().map { index, release in
            let (id, title, artistIndex, hue, titles) = release
            let artist = artists[artistIndex]
            let cover = Cover(id, hue: hue, variant: index)
            let songs = titles.enumerated().map { offset, song in
                LibrarySongItem(id: "\(id)-\(offset + 1)", title: song, artist: artist.name,
                    album: title, albumArtist: artist.name, trackNumber: offset + 1,
                    artwork: cover.artwork, albumDirectory: id, artworkURL: cover.url,
                    artworkBackdrop: cover.backdrop, duration: 48 + offset * 4,
                    addedOrder: index * 10 + offset, year: 2026, displaySource: .init())
            }
            return Album(id: "folder:" + id, title: title, artistID: artist.id, cover: cover, songs: songs)
        }
        playlistCover = Cover("night-post", hue: 0.92, variant: 3)
    }

    func track(_ song: LibrarySongItem) -> PlayerTrack {
        .init(id: song.id, title: song.title, artists: song.artist, albumTitle: song.album,
              coverURL: song.artworkURL, duration: Double(song.duration))
    }

    func image(at url: URL) -> UIImage? {
        (albums.map(\.cover) + artists.map(\.cover) + [playlistCover]).first { $0.url == url }?.image
    }

    func lyrics(trackID: String) -> PlayerLyrics {
        guard let song = songs.first(where: { $0.id == trackID }) else { return .init() }
        let lines = [
            "把「\(song.title)」写在透明信笺上",
            "一枚方形的星从屋檐升起",
            "让风经过留白的那一页",
            "我们沿着虚线抵达清晨",
            "湖面折起一封还没寄出的信",
            "听见秒针在乘下一班车",
            "夜色在窗格里分成四份",
            "每一份都照出不同的蓝",
            "把最后一格光留给远处",
            "等月亮把邮路重新点亮",
            "让这次回声停在你身旁",
            "下一站的名字由我们写下"
        ]
        return .init(lines: lines.enumerated().map {
            .init(id: $0.offset, time: 0.5 + Double($0.offset) * 3.6, text: $0.element)
        }, source: "Showcase")
    }
}
