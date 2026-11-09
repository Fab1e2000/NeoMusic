#if DEBUG
import SwiftUI
import UIKit

/// Isolated layout study. All changes stay in memory and never call music services.
struct ArtistPagePreview: View {
    @State private var path: [String] = []
    @State private var selectedTab = 2
    @State private var pageShade: CGFloat = 96
    @State private var showsBiography = false
    @State private var favorite = false
    @State private var collected = true
    @State private var playing = false
    @State private var selectedSong: String?
    @State private var favoriteSongs: Set<String> = []
    private let background = Color(white: 0.37)
    private let releases = ArtistPreviewRelease.samples
    private var initialPage: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-artistPagePreview"), arguments.indices.contains(index + 1) else { return "home" }
        return arguments[index + 1]
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("主页", systemImage: "house.fill", value: 0) { previewNavigation }
            Tab("资料库", systemImage: "square.stack.fill", value: 1) { previewNavigation }
            Tab("搜索", systemImage: "magnifyingglass", value: 2) { previewNavigation }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            ArtistPreviewMiniPlayer(playing: $playing, selectedSong: $selectedSong)
        }
        .preferredColorScheme(path.isEmpty ? .dark : .light)
        .tint(.blue)
        .task {
            if initialPage == "songs" { path = ["歌曲排行"] }
            if initialPage == "singles" { path = ["单曲与 EP"] }
            if initialPage == "similar" { path = ["类似艺人"] }
            if initialPage == "info" { showsBiography = true }
        }
        .sheet(isPresented: $showsBiography) {
            ArtistBiographyPreview()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(.black)
                .preferredColorScheme(.dark)
        }
    }

    // Each tab exposes the same isolated artist study; no production destinations are changed.
    private var previewNavigation: some View {
        NavigationStack(path: $path) {
            artistPage.navigationDestination(for: String.self) { title in
                if title == "歌曲排行" { songList }
                else if title == "类似艺人" { similarList }
                else { releaseGrid(title) }
            }
        }
    }

    private var artistPage: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                latestRelease.padding(.horizontal, 20).padding(.top, 24)
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeading("歌曲排行")
                    VStack(spacing: 0) {
                        ForEach(ArtistPreviewSong.samples.prefix(5)) { song in
                            songRow(song, dark: true)
                        }
                    }
                }.padding(.horizontal, 20).padding(.top, 24)
                releaseShelf("专辑", items: [releases[0]])
                releaseShelf("单曲与 EP", items: Array(releases.dropFirst()))
                similarShelf
            }.padding(.bottom, 24)
                .background {
                    ArtistPreviewBackdrop(
                        imageName: initialPage == "local" ? "AlbumSample17" : "ArtistPreviewRIM"
                    )
                }
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            let upward = max(0, geometry.contentOffset.y + geometry.contentInsets.top)
            return max(44, 96 - max(0, upward - 192) * 0.047)
        } action: { _, shade in
            pageShade = shade
        }
        .background {
            Color(red: pageShade / 255, green: (pageShade - 1) / 255, blue: (pageShade - 2) / 255)
                .ignoresSafeArea()
        }
        .ignoresSafeArea(edges: .top)
        .scrollEdgeEffectHidden(true, for: .top)
        .foregroundStyle(.white)
        .toolbarColorScheme(.dark, for: .navigationBar, .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // A preview root has no parent route; expose the native catalog entry.
                Menu {
                    Button("艺人主页") { path = [] }
                    Button("歌曲排行") { path.append("歌曲排行") }
                    Button("单曲与 EP") { path.append("单曲与 EP") }
                    Button("简介") { showsBiography = true }
                } label: { Image(systemName: "chevron.left").foregroundStyle(.white) }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: URL(string: "https://kamitsubaki.jp/artist/rim/")!) { Image(systemName: "square.and.arrow.up").foregroundStyle(.white) }
                Menu {
                    Button(favorite ? "取消喜爱" : "喜爱", systemImage: favorite ? "star.fill" : "star") { favorite.toggle() }
                    ShareLink(item: URL(string: "https://kamitsubaki.jp/artist/rim/")!) { Label("分享", systemImage: "square.and.arrow.up") }
                } label: { Image(systemName: "ellipsis").foregroundStyle(.white) }
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 398)
            Text("RIM").font(.system(size: 34, weight: .bold)).padding(.top, -43)
            HStack(spacing: 24) {
                Button { showsBiography = true } label: {
                    Image(systemName: "info").font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.32))
                        .frame(width: 48, height: 48).background(.white.opacity(0.10), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1))
                }.accessibilityLabel("艺人简介")
                Button { playing.toggle() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 36)).foregroundStyle(Color(white: 0.49))
                        .frame(width: 72, height: 72).background(.white, in: Circle())
                }.accessibilityLabel(playing ? "暂停预览" : "播放预览")
                Button { favorite.toggle() } label: {
                    Image(systemName: favorite ? "star.fill" : "star").font(.system(size: 20))
                        .frame(width: 48, height: 48).background(.white.opacity(0.10), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1))
                }.accessibilityLabel(favorite ? "取消喜爱" : "喜爱")
            }.buttonStyle(.plain).padding(.top, 34.0 / 3)
        }
    }

    private var latestRelease: some View {
        HStack(spacing: 12) {
            artwork(releases[1].image).frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 2) {
                Text("2026年10月28日").font(.system(size: 14))
                Text(releases[1].title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Text("1 首歌曲").font(.system(size: 14))
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { collected.toggle() } label: {
                Image(systemName: collected ? "arrow.down" : "plus")
                    .font(.system(size: 20, weight: .semibold)).frame(width: 32, height: 32)
                    .background(.white.opacity(0.2), in: Circle())
            }.accessibilityLabel(collected ? "移出预览资料库" : "加入预览资料库")
        }
        .padding(12).padding(.trailing, 8).background(.white.opacity(0.13), in: .rect(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.17), lineWidth: 0.7))
    }

    private func sectionHeading(_ title: String) -> some View {
        NavigationLink(value: title) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 20, weight: .bold))
                Image(systemName: "chevron.right").font(.system(size: 16, weight: .semibold))
            }
        }.buttonStyle(.plain)
    }

    private func releaseShelf(_ title: String, items: [ArtistPreviewRelease]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(title).padding(.horizontal, 20)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(items) { release in releaseCard(release).frame(width: 160) }
                }.scrollTargetLayout()
            }.contentMargins(.horizontal, 20, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
        }.padding(.top, 28)
    }

    private func releaseCard(_ release: ArtistPreviewRelease) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            artwork(release.image).aspectRatio(1, contentMode: .fit)
            Text(release.title).font(.system(size: 14)).lineLimit(1)
            Text(release.year).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private func releaseGrid(_ title: String) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], alignment: .leading, spacing: 16) {
                ForEach(title == "专辑" ? [releases[0]] : Array(releases.dropFirst())) { release in releaseCard(release) }
            }.padding(.horizontal, 20).padding(.bottom, 24)
        }.background(Color(uiColor: .systemBackground))
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
    }

    private let similarArtists = ["kaf", "isekaijoucho", "koko"]
    private func artistName(_ id: String) -> String {
        ["kaf": "KAF", "isekaijoucho": "Isekaijoucho", "koko": "KOKO"][id] ?? id
    }
    private var similarShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("类似艺人").padding(.horizontal, 20)
            ScrollView(.horizontal) {
                HStack(spacing: 16) {
                    ForEach(similarArtists, id: \.self) { id in
                        NavigationLink(value: "类似艺人") {
                            VStack(spacing: 8) {
                                Image("ArtistPreview-" + id).resizable().scaledToFill()
                                    .frame(width: 120, height: 120).clipShape(.circle)
                                Text(artistName(id)).font(.system(size: 14))
                            }
                        }.buttonStyle(.plain)
                    }
                }.scrollTargetLayout()
            }.contentMargins(.horizontal, 20, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
        }.padding(.top, 28)
    }
    private var similarList: some View {
        List(similarArtists, id: \.self) { id in
            HStack(spacing: 12) {
                Image("ArtistPreview-" + id).resizable().scaledToFill()
                    .frame(width: 64, height: 64).clipShape(.circle)
                Text(artistName(id)).font(.system(size: 17))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
            }.padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                .alignmentGuide(.listRowSeparatorLeading) { _ in 76 }
                .listRowSeparator(.hidden, edges: .top)
        }.listStyle(.plain).navigationTitle("类似艺人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
    }

    private var songList: some View {
        List(ArtistPreviewSong.samples) { song in
            songRow(song, dark: false)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowSeparator(.hidden)
        }.listStyle(.plain).navigationTitle("歌曲排行")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
    }

    private func songRow(_ song: ArtistPreviewSong, dark: Bool) -> some View {
        HStack(spacing: 12) {
            Button { selectedSong = song.title; playing = true } label: {
                HStack(spacing: 12) {
                    artwork(song.image).frame(width: 48, height: 48)
                        .overlay {
                            if selectedSong == song.title {
                                RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.3))
                                Image(systemName: "waveform").foregroundStyle(.white)
                            }
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.title).font(.system(size: 17)).lineLimit(1)
                        Text(song.subtitle).font(.system(size: 13)).foregroundStyle(dark ? .white.opacity(0.72) : .secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(.rect)
            }.buttonStyle(.plain)
            Menu("歌曲选项", systemImage: "ellipsis") {
                Button(favoriteSongs.contains(song.id) ? "取消喜爱" : "喜爱", systemImage: favoriteSongs.contains(song.id) ? "star.fill" : "star") {
                    if favoriteSongs.contains(song.id) { favoriteSongs.remove(song.id) }
                    else { favoriteSongs.insert(song.id) }
                }
            }.labelStyle(.iconOnly).foregroundStyle(dark ? .white.opacity(0.8) : .secondary)
                .frame(width: 44, height: 44).padding(.trailing, 2)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(dark ? .white.opacity(0.2) : .black.opacity(0.18)).frame(height: 0.33).padding(.leading, 60) }
    }

    private func artwork(_ name: String) -> some View {
        Image(name).resizable().aspectRatio(contentMode: .fill).clipShape(.rect(cornerRadius: 6))
    }
}

/// The backdrop follows native scroll geometry; labels and controls remain in the scroll content.
/// The image and its gradient share one transform; text scrolls independently.
private struct ArtistPreviewBackdrop: View {
    let imageName: String
    @State private var diffuseImage: UIImage?
    @State private var sharpImage: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            let y = geometry.frame(in: .scrollView).minY
            let upward = max(0, -y)
            // Blur and color loss are one image transition, independent of the page shade.
            let imageProgress = min(1, max(0, (upward - 150) / 330))
            let imageHeight: CGFloat = 400
            let extent: CGFloat = 520
            let pull = max(0, y)
            let magnification = 1 + pull / 500

            ZStack(alignment: .top) {
                // The diffuse image extends behind the title, buttons and release card.
                if let diffuseImage {
                    Image(uiImage: diffuseImage).resizable()
                        .frame(width: geometry.size.width, height: extent)
                        .blur(radius: 22, opaque: true)
                    Image(uiImage: diffuseImage).resizable()
                        .frame(width: geometry.size.width, height: extent)
                        .blur(radius: 7, opaque: true)
                        .mask(LinearGradient(stops: [
                            .init(color: .black, location: 0.59),
                            .init(color: .clear, location: 0.76)
                        ], startPoint: .top, endPoint: .bottom))
                }
                Image(uiImage: sharpImage ?? UIImage()).resizable()
                    .frame(width: geometry.size.width, height: imageHeight)
                    .clipped()
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.72),
                            .init(color: .clear, location: 0.86)
                        ], startPoint: .top, endPoint: .bottom)
                    }
            }
            .frame(width: geometry.size.width, height: extent, alignment: .top)
            .compositingGroup()
            .blur(radius: 60 * imageProgress)
            .mask {
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.68),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .scaleEffect(magnification, anchor: .top)
            .offset(y: upward * 0.6 - pull)
            .opacity(1 - imageProgress)
            .task(id: geometry.size.width) {
                let images = makeImages(width: geometry.size.width)
                sharpImage = images?.sharp
                diffuseImage = images?.diffuse
            }
        }
        .allowsHitTesting(false)
    }

    private func makeImages(width: CGFloat) -> (sharp: UIImage, diffuse: UIImage)? {
        guard width > 0, let image = UIImage(named: imageName) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = displayScale
        format.opaque = true
        let ratio = width / 402
        // Matched artwork landmarks in the reference: 355 pt high, origin (-328, 21).
        let rect: CGRect
        if imageName == "ArtistPreviewRIM" {
            rect = CGRect(x: -328.14 * ratio, y: 20.63 * ratio,
                          width: image.size.width * 0.5917 * ratio, height: image.size.height * 0.5917 * ratio)
        } else {
            let scale = max(width / image.size.width, 400 / image.size.height)
            rect = CGRect(x: width - image.size.width * scale, y: 0,
                          width: image.size.width * scale, height: image.size.height * scale)
        }
        let source = UIGraphicsImageRenderer(size: CGSize(width: width, height: 400), format: format).image { context in
            if rect.minY > 0, let top = UIImage(named: "ArtistPreviewRIMTop") {
                top.draw(in: CGRect(x: 0, y: 0, width: width, height: rect.minY))
            }
            image.draw(in: rect)
            if rect.maxY < 400 {
                context.cgContext.saveGState()
                context.cgContext.clip(to: CGRect(x: 0, y: rect.maxY, width: width, height: 400 - rect.maxY))
                context.cgContext.translateBy(x: 0, y: rect.maxY * 2)
                context.cgContext.scaleBy(x: 1, y: -1)
                image.draw(in: rect)
                context.cgContext.restoreGState()
            }
        }
        let extended = UIGraphicsImageRenderer(size: CGSize(width: width, height: 520), format: format).image { context in
            source.draw(at: .zero)
            context.cgContext.saveGState()
            context.cgContext.clip(to: CGRect(x: 0, y: 400, width: width, height: 120))
            context.cgContext.translateBy(x: 0, y: 800)
            context.cgContext.scaleBy(x: 1, y: -1)
            source.draw(at: .zero)
            context.cgContext.restoreGState()
        }
        return (source, extended)
    }
}

private struct ArtistPreviewMiniPlayer: View {
    @Binding var playing: Bool
    @Binding var selectedSong: String?
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        HStack(spacing: 10) {
            Image("AlbumSample17").resizable().scaledToFill()
                .frame(width: 30, height: 30).clipShape(.rect(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 1) {
                Text(selectedSong ?? "NEUROMANCE").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text("RIM").font(.system(size: 13))
            }
            Spacer(minLength: 6)
            Button(playing ? "暂停预览" : "播放预览", systemImage: playing ? "pause.fill" : "play.fill") { playing.toggle() }
                .labelStyle(.iconOnly).font(.system(size: 22)).frame(width: 36)
            if placement != .inline {
                Button("下一首预览", systemImage: "forward.end.fill") {
                    let songs = ArtistPreviewSong.samples
                    let current = songs.firstIndex { $0.title == (selectedSong ?? "NEUROMANCE") } ?? 0
                    selectedSong = songs[(current + 1) % songs.count].title
                }.labelStyle(.iconOnly).font(.system(size: 22)).frame(width: 36)
            }
        }.padding(.horizontal, 16).foregroundStyle(.white).buttonStyle(.plain)
    }
}

private struct ArtistPreviewRelease: Identifiable {
    var id: String { image }
    let image: String
    let title: String
    let year: String
    static let samples = [
        Self(image: "AlbumSample17", title: "NEW ROMANCER", year: "2021年"),
        Self(image: "ArtistPreviewKotowari", title: "kotowari - Single", year: "2026年"),
        Self(image: "ArtistPreviewLove", title: "Love Me, Own Me - Single", year: "2026年"),
        Self(image: "ArtistPreviewHow", title: "How Many? - Single", year: "2026年"),
        Self(image: "ArtistPreviewPrayer", title: "ぷれいや - Single", year: "2026年"),
        Self(image: "ArtistPreviewMoney", title: "ノマネ - Single", year: "2025年")
    ]
}

private struct ArtistPreviewSong: Identifiable {
    var id: String { title }
    let title: String
    let subtitle: String
    let image: String
    static let samples = [
        Self(title: "食虫植物", subtitle: "NEW ROMANCER · 2020年", image: "AlbumSample17"),
        Self(title: "Love Me, Own Me", subtitle: "Love Me, Own Me - Single · 2026年", image: "ArtistPreviewLove"),
        Self(title: "さみしいひと", subtitle: "NEW ROMANCER · 2021年", image: "AlbumSample17"),
        Self(title: "NEUROMANCE", subtitle: "NEW ROMANCER · 2021年", image: "AlbumSample17"),
        Self(title: "ラヴソング", subtitle: "NEW ROMANCER · 2021年", image: "AlbumSample17"),
        Self(title: "How Many?", subtitle: "How Many? - Single · 2026年", image: "ArtistPreviewHow"),
        Self(title: "ぷれいや", subtitle: "ぷれいや - Single · 2026年", image: "ArtistPreviewPrayer"),
        Self(title: "ノマネ", subtitle: "ノマネ - Single · 2025年", image: "ArtistPreviewMoney")
    ]
}

private struct ArtistBiographyPreview: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image("ArtistPreviewRIM").resizable().scaledToFill()
                    .frame(height: 350).containerRelativeFrame(.horizontal, alignment: .trailing).clipped()
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.65), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                VStack(alignment: .leading, spacing: 24) {
                    Text("RIM").font(.system(size: 28, weight: .bold))
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) { Text("类型").foregroundStyle(.secondary); Text("J-Pop") }
                        Spacer()
                    }.font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 10) {
                        Text("简介").font(.system(size: 17, weight: .semibold))
                        Text("日本語の歌、英語の歌、韓国語の歌が好きな謎めいた目をした女の子。\n\n透明感と艶やかさが同居する不思議な歌声を持つ、ジャンルと国境を横断する可能性を秘めた次世代バーチャルシンガー。")
                            .font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(5)
                    }
                }.padding(.horizontal, 20).padding(.top, -65)
            }.padding(.bottom, 30)
        }.background(.black).ignoresSafeArea(edges: .top)
            .overlay(alignment: .topLeading) {
                Button("关闭", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
                    .padding(16)
            }
    }
}

#Preview("艺人主页") { ArtistPagePreview() }
#endif
