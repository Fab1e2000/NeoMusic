import SwiftUI

/// Album covers are existing bundled samples. Editorial artwork is drawn natively.
struct HomeArtwork: View {
    let artwork: HomeArtworkSource

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            switch artwork {
            case .image(let name):
                Image(name).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height).clipped()
            case .favorites:
                Color(white: 0.575)
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color(white: 0.92))
                            .overlay {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 116, weight: .regular))
                                    .foregroundStyle(Color(red: 1, green: 0.16, blue: 0.27))
                            }
                            .frame(width: size.width - 32, height: size.width - 32)
                            .padding(.top, 16)
                    }
            case .newMusic:
                MeshGradient(width: 3, height: 3, points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.7, 0.38], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1]
                ], colors: [
                    Color(red: 1, green: 0.02, blue: 0.12), .pink, Color(red: 1, green: 0.18, blue: 0.25),
                    .red, Color(red: 1, green: 0.63, blue: 0.69), Color(red: 1, green: 0.19, blue: 0.35),
                    Color(red: 1, green: 0.47, blue: 0.49), Color(red: 1, green: 0.63, blue: 0.69), Color(red: 1, green: 0.38, blue: 0.51)
                ])
                .overlay {
                    Text("音乐新发现")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.white)
                }
                .overlay(alignment: .topTrailing) { HomeMusicWordmark().padding(10) }
            case .station(let theme):
                HomeStationArtwork(theme: theme)
                    .overlay(alignment: .topTrailing) {
                        HomeMusicWordmark().scaleEffect(size.width / 248, anchor: .topTrailing)
                            .padding(10 * size.width / 248)
                    }
            case .collage(let theme):
                HomeCollageArtwork(theme: theme, size: size)
            case .mood(let mood):
                HomeMoodArtwork(mood: mood)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct HomeMusicWordmark: View {
    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "apple.logo").font(.system(size: 14, weight: .bold))
            Text("music").font(.system(size: 17, weight: .heavy, design: .rounded)).tracking(-0.7)
        }
        .foregroundStyle(.white)
    }
}

private struct HomeStationArtwork: View {
    let theme: Int
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let warm = theme == 0
            ZStack {
                LinearGradient(colors: warm ? [.pink, .red, Color(red: 0.75, green: 0, blue: 0.23)] : [.indigo, .blue, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                ForEach(0..<4) { index in
                    Path { path in
                        let shift = CGFloat(index) * size.width * 0.23
                        path.move(to: CGPoint(x: -shift, y: -size.height * 0.1))
                        path.addLine(to: CGPoint(x: size.width * 0.95 - shift, y: size.height * 0.5))
                        path.addLine(to: CGPoint(x: -shift, y: size.height * 1.1))
                        path.addLine(to: CGPoint(x: size.width * 0.15 - shift, y: size.height * 0.5))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: warm ? [.pink.opacity(0.9), .red, .orange.opacity(0.55)] : [.cyan.opacity(0.7), .indigo, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: .black.opacity(0.12), radius: 5)
                }
            }
        }
    }
}

private struct HomeCollageArtwork: View {
    let theme: Int
    let size: CGSize

    var body: some View {
        let scale = size.width / 248
        let brown = theme == 0
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: brown ? [Color(red: 0.23, green: 0.18, blue: 0.13), Color(red: 0.60, green: 0.46, blue: 0.30)] : [Color(red: 0.06, green: 0.20, blue: 0.31), Color(red: 0.12, green: 0.47, blue: 0.80)], startPoint: .top, endPoint: .bottom)
            Circle().fill(brown ? Color(red: 0.61, green: 0.55, blue: 0.48) : Color(red: 0.35, green: 0.54, blue: 0.68))
                .frame(width: 148 * scale, height: 148 * scale)
                .position(x: 91 * scale, y: 86 * scale)
            Image(brown ? "AlbumSample23" : "AlbumSample19")
                .resizable().scaledToFill()
                .frame(width: 86 * scale, height: 86 * scale).clipped()
                .shadow(color: .black.opacity(0.35), radius: 3 * scale, y: 2 * scale)
                .position(x: 91 * scale, y: 86 * scale)
            Image(brown ? "AlbumSample17" : "AlbumSample09")
                .resizable().scaledToFill()
                .frame(width: 82 * scale, height: 82 * scale).clipShape(.circle)
                .position(x: 188 * scale, y: 160 * scale)
            Image(brown ? "AlbumSample18" : "AlbumSample20")
                .resizable().scaledToFill()
                .frame(width: 74 * scale, height: 74 * scale).clipShape(.circle)
                .position(x: 114 * scale, y: 201 * scale)
        }
        .overlay(alignment: .topTrailing) {
            HomeMusicWordmark().scaleEffect(scale, anchor: .topTrailing).padding(10 * scale)
        }
    }
}

private struct HomeMoodArtwork: View {
    let mood: HomeMood
    private var background: Color {
        switch mood {
        case .happy: Color(red: 1, green: 0.70, blue: 0)
        case .heart: Color(red: 0.89, green: 0.06, blue: 0.08)
        case .love: Color(red: 0.96, green: 0.16, blue: 0.58)
        case .night: Color(red: 0.16, green: 0.19, blue: 0.68)
        case .focus: Color(red: 1, green: 0.50, blue: 0)
        case .relax: Color(red: 0.16, green: 0.66, blue: 0.94)
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack {
                background
                switch mood {
                case .happy:
                    HomeMoodDiamond().stroke(.white.opacity(0.65), lineWidth: 1.3)
                        .padding(width * 0.07)
                case .heart, .love:
                    HomeMoodHeart().stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.3, dash: mood == .heart ? [9, 4] : []))
                        .padding(width * 0.08)
                case .focus:
                    ForEach([0.85, 0.64, 0.42, 0.20], id: \.self) { ratio in
                        Circle().stroke(.white.opacity(0.58), lineWidth: 1.3)
                            .frame(width: width * ratio, height: width * ratio)
                    }
                case .night, .relax:
                    VStack(spacing: width * 0.025) {
                        ForEach([0.42, 0.66, 0.88], id: \.self) { ratio in
                            Ellipse().stroke(.white.opacity(0.55), lineWidth: 1.3)
                                .frame(width: width * ratio, height: width * ratio * 0.38)
                        }
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                HomeMusicWordmark().scaleEffect(width / 248, anchor: .topTrailing).padding(10 * width / 248)
            }
        }
    }
}

private struct HomeMoodDiamond: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: rect.width * 0.63, y: rect.height * 0.35))
            path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control: CGPoint(x: rect.width * 0.62, y: rect.height * 0.65))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.midY), control: CGPoint(x: rect.width * 0.37, y: rect.height * 0.65))
            path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: CGPoint(x: rect.width * 0.38, y: rect.height * 0.35))
        }
    }
}

private struct HomeMoodHeart: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        return Path { path in
            path.move(to: CGPoint(x: w * 0.5, y: h * 0.93))
            path.addCurve(to: CGPoint(x: w * 0.05, y: h * 0.38), control1: CGPoint(x: w * 0.34, y: h * 0.75), control2: CGPoint(x: 0, y: h * 0.6))
            path.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.17), control1: CGPoint(x: 0, y: 0), control2: CGPoint(x: w * 0.38, y: 0))
            path.addCurve(to: CGPoint(x: w * 0.95, y: h * 0.38), control1: CGPoint(x: w * 0.62, y: 0), control2: CGPoint(x: w, y: 0))
            path.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.93), control1: CGPoint(x: w, y: h * 0.6), control2: CGPoint(x: w * 0.66, y: h * 0.75))
        }
    }
}

struct HomeDailyArtwork: View {
    var body: some View {
                MeshGradient(width: 3, height: 3, points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.7, 0.38], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1]
                ], colors: [
                    Color(red: 1, green: 0.02, blue: 0.12), .pink, Color(red: 1, green: 0.18, blue: 0.25),
                    .red, Color(red: 1, green: 0.63, blue: 0.69), Color(red: 1, green: 0.19, blue: 0.35),
                    Color(red: 1, green: 0.47, blue: 0.49), Color(red: 1, green: 0.63, blue: 0.69), Color(red: 1, green: 0.38, blue: 0.51)
                ])
                .overlay {
                    Text("每日推荐")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.white)
                }

    }
}
