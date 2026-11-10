#if DEBUG
import SwiftUI
import UIKit

/// Native, in-memory comparisons for the frontend review. Production screens remain independent.
struct FrontendReadabilityPreview: View {
    let page: String
    @Environment(\.dynamicTypeSize) private var systemTextSize
    @State private var candidate: Bool
    @State private var textSize: DynamicTypeSize?
    @State private var appearance: ColorScheme?
    @State private var highContrast: Bool

    init(page: String) {
        self.page = page
        _candidate = State(initialValue: Self.argument("-frontendReviewVersion") != "current")
        let requestedSize: DynamicTypeSize? = switch Self.argument("-frontendReviewTextSize") {
        case "default": .large
        case "xxxl": .xxxLarge
        case "ax5": .accessibility5
        default: nil
        }
        _textSize = State(initialValue: requestedSize)
        let requestedAppearance: ColorScheme? = switch Self.argument("-frontendReviewAppearance") {
        case "light": .light
        case "dark": .dark
        default: nil
        }
        _appearance = State(initialValue: requestedAppearance)
        _highContrast = State(initialValue: ProcessInfo.processInfo.arguments.contains("-frontendReviewHighContrast"))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("对照版本", selection: $candidate) {
                    Text("当前").tag(false)
                    Text("候选").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .dynamicTypeSize(.large)
                .accessibilityIdentifier("frontend-review.version")
                ReviewContrastHost(highContrast: highContrast) {
                    content.environment(\.dynamicTypeSize, textSize ?? systemTextSize)
                }
            }
            .background(page == "home" && !candidate ? Color.white : Color(.systemBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("预览设置", systemImage: "textformat.size") {
                        Section("文字大小") {
                            Button("跟随系统") { textSize = nil }
                            Button("默认") { textSize = .large }
                            Button("XXXL") { textSize = .xxxLarge }
                            Button("辅助功能最大") { textSize = .accessibility5 }
                        }
                        Section("外观") {
                            Button("跟随系统") { appearance = nil }
                            Button("浅色") { appearance = .light }
                            Button("深色") { appearance = .dark }
                            Toggle("提高对比度", isOn: $highContrast)
                        }
                    }
                    .accessibilityIdentifier("frontend-review.settings")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Text("隔离原生效果稿 · 示例内容")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.regularMaterial)
                    .dynamicTypeSize(.large)
            }
        }
        .preferredColorScheme(page == "home" && !candidate ? .light : appearance)
    }

    @ViewBuilder private var content: some View {
        switch page {
        case "type": ReviewTypographyPage(candidate: candidate)
        case "contrast": ReviewContrastPage(candidate: candidate)
        case "status": ReviewLibraryStatusPage(candidate: candidate)
        case "toast": ReviewToastPage(candidate: candidate)
        default: ReviewHomePage(candidate: candidate)
        }
    }

    private var title: String {
        switch page {
        case "type": "文字缩放"
        case "contrast": "封面与分类对比度"
        case "status": "资料库状态"
        case "toast": "提示条"
        default: "主页外观"
        }
    }

    private static func argument(_ key: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

/// SwiftUI exposes contrast as a read-only environment value. UIKit owns the preview override.
private struct ReviewContrastHost<Content: View>: UIViewControllerRepresentable {
    let highContrast: Bool
    let content: Content

    init(highContrast: Bool, @ViewBuilder content: () -> Content) {
        self.highContrast = highContrast
        self.content = content()
    }

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let controller = UIHostingController(rootView: content)
        controller.view.backgroundColor = .clear
        updateUIViewController(controller, context: context)
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<Content>, context: Context) {
        controller.rootView = content
        if highContrast {
            controller.traitOverrides.accessibilityContrast = .high
        } else {
            controller.traitOverrides.remove(UITraitAccessibilityContrast.self)
        }
    }
}

private struct ReviewScaledText: View {
    let text: String
    let baseSize: CGFloat
    let candidate: Bool
    let weight: Font.Weight
    @ScaledMetric private var scaledSize: CGFloat

    init(_ text: String, size: CGFloat, relativeTo: Font.TextStyle = .body,
         weight: Font.Weight = .regular, candidate: Bool) {
        self.text = text
        self.baseSize = size
        self.candidate = candidate
        self.weight = weight
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: relativeTo)
    }

    var body: some View {
        Text(text).font(.system(size: candidate ? scaledSize : baseSize, weight: weight))
    }
}

private struct ReviewHomePage: View {
    let candidate: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(spacing: 16) {
                    Text("登录，发现为你推荐的音乐").font(.subheadline).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("登录") {}.font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 20)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ReviewHeroCard(candidate: candidate, title: "每日推荐", subtitle: "每天为你挑选的音乐。", image: "AlbumSample15")
                        ReviewHeroCard(candidate: candidate, title: "私人漫游", subtitle: "让下一首，带来新的发现。", image: "AlbumSample02")
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, 20)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                VStack(alignment: .leading, spacing: 14) {
                    ReviewScaledText("根据你喜欢的歌曲推荐", size: 20, relativeTo: .title3,
                                     weight: .bold, candidate: candidate)
                    ReviewSongRow(candidate: candidate, image: "AlbumSample03", title: "在路上的那些天", artist: "晴空乐队")
                    Divider().padding(.leading, 60)
                    ReviewSongRow(candidate: candidate, image: "AlbumSample08", title: "夜晚散步", artist: "晴空乐队")
                }
                .padding(.horizontal, 20)
                VStack(alignment: .leading, spacing: 14) {
                    ReviewScaledText("推荐歌单", size: 20, relativeTo: .title3, weight: .bold, candidate: candidate)
                    HStack(alignment: .top, spacing: 12) {
                        ReviewAlbumTile(image: "AlbumSample09", title: "今天的好心情")
                        ReviewAlbumTile(image: "AlbumSample14", title: "夜色温柔")
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 15)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ReviewMiniPlayer(candidate: candidate).padding(.horizontal, 12).padding(.bottom, 8)
        }
    }
}

private struct ReviewHeroCard: View {
    let candidate: Bool
    let title: String
    let subtitle: String
    let image: String
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: candidate && textSize.isAccessibilitySize ? 90 : 180)
            ReviewScaledText("为你推荐", size: 12, relativeTo: .caption,
                             candidate: candidate)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(candidate ? nil : 1)
            Text(title).font(.title2.bold()).lineLimit(candidate ? nil : 2)
            ReviewScaledText(subtitle, size: 13, relativeTo: .footnote,
                             candidate: candidate)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(candidate ? nil : 2)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 248, height: candidate ? nil : 330, alignment: .bottomLeading)
        .frame(minHeight: 330)
        .background {
            Image(image).resizable().scaledToFill()
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                }
        }
        .clipShape(.rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

private struct ReviewSongRow: View {
    let candidate: Bool
    let image: String
    let title: String
    let artist: String

    var body: some View {
        HStack(spacing: 12) {
            Image(image).resizable().scaledToFill().frame(width: 48, height: 48)
                .clipShape(.rect(cornerRadius: 6)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline).lineLimit(candidate ? nil : 1)
                Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(candidate ? nil : 1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: candidate ? nil : 64)
        .frame(minHeight: 64)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

private struct ReviewAlbumTile: View {
    let image: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(image).resizable().scaledToFill().aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 8)).accessibilityHidden(true)
            Text(title).font(.subheadline).lineLimit(2)
            Text("晴空乐队").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct ReviewMiniPlayer: View {
    let candidate: Bool
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        Group {
            if candidate && textSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    title
                    HStack {
                        Image("AlbumSample03").resizable().scaledToFill().frame(width: 42, height: 42)
                            .clipShape(.rect(cornerRadius: 5)).accessibilityHidden(true)
                        Spacer()
                        controls
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Image("AlbumSample03").resizable().scaledToFill().frame(width: 42, height: 42)
                        .clipShape(.rect(cornerRadius: 5)).accessibilityHidden(true)
                    title
                    Spacer(minLength: 0)
                    controls
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            ReviewScaledText("在路上的那些天", size: 13, relativeTo: .footnote, candidate: candidate)
            ReviewScaledText("晴空乐队", size: 12, relativeTo: .caption, candidate: candidate)
                .foregroundStyle(.secondary)
        }
        .lineLimit(candidate ? nil : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: candidate ? nil : 36)
        .clipped()
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Button("播放", systemImage: "play.fill") {}.labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
            Button("下一首", systemImage: "forward.end.fill") {}.labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
        }
        .font(.system(size: 21))
        .buttonStyle(.plain)
    }
}

private struct ReviewTypographyPage: View {
    let candidate: Bool
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var name = "在路上的那些天"
    @State private var description = "适合散步、通勤和夜晚独处时听的音乐。"
    @ScaledMetric(relativeTo: .body) private var descriptionSize = 15.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("首页卡片").font(.headline)
                    ReviewHeroCard(candidate: candidate, title: "私人漫游", subtitle: "让下一首，带来新的发现。", image: "AlbumSample02")
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("艺人及最新发行").font(.headline)
                    ReviewScaledText("晴空乐队", size: 34, relativeTo: .largeTitle, weight: .bold, candidate: candidate)
                    HStack(alignment: .top, spacing: 12) {
                        Image("AlbumSample15").resizable().scaledToFill().frame(width: 72, height: 72)
                            .clipShape(.rect(cornerRadius: 8)).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            ReviewScaledText("最新发行", size: 14, relativeTo: .subheadline, candidate: candidate)
                                .foregroundStyle(.secondary)
                            ReviewScaledText("在路上的那些天 — EP", size: 16, relativeTo: .callout,
                                             weight: .semibold, candidate: candidate)
                                .lineLimit(candidate ? nil : 1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("迷你播放器").font(.headline)
                    ReviewMiniPlayer(candidate: candidate)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("编辑播放列表").font(.headline)
                    TextField("名称", text: $name)
                        .font(.system(size: candidate ? descriptionSize * 4 / 3 : 20, weight: .semibold))
                    Divider()
                    TextEditor(text: $description)
                        .font(.system(size: candidate ? descriptionSize : 15))
                        .scrollContentBackground(.hidden)
                        .frame(height: candidate && textSize.isAccessibilitySize ? 180 : 58)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("普通文本歌词").font(.headline)
                    ReviewScaledText("迎着风，走过长长的街\n在路上的那些天\n还有音乐陪着我", size: 36, relativeTo: .largeTitle,
                                     weight: .bold, candidate: candidate)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
    }
}

private struct ReviewRGB {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    var luminance: Double {
        0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
    var whiteContrast: Double { 1.05 / (luminance + 0.05) }
    var blackContrast: Double { (luminance + 0.05) / 0.05 }
    var readableForeground: Color { blackContrast >= whiteContrast ? .black : .white }
    var readableContrast: Double { max(blackContrast, whiteContrast) }

    private func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}

private struct ReviewContrastPage: View {
    let candidate: Bool
    private let yellow = ReviewRGB(red: 221 / 255, green: 170 / 255, blue: 0)
    private let green = ReviewRGB(red: 51 / 255, green: 176 / 255, blue: 112 / 255)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("搜索分类").font(.headline)
                category("华语", symbol: "music.note", background: yellow)
                category("轻音乐", symbol: "pianokeys", background: green)
                Text("专辑背景").font(.headline)
                ReviewAlbumContrastCard(candidate: candidate, image: nil)
                ReviewAlbumContrastCard(candidate: candidate, image: "AlbumSample15")
                ReviewAlbumContrastCard(candidate: candidate, image: "AlbumSample03")
                Text("比值按不透明 sRGB 背景与前景计算。灰色是算法输入样本，封面样本使用现有取色结果。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private func category(_ title: String, symbol: String, background: ReviewRGB) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom) {
                Text(title).font(.headline)
                Spacer(minLength: 12)
                Image(systemName: symbol).font(.system(size: 44)).accessibilityHidden(true)
            }
            .foregroundStyle(candidate ? background.readableForeground : .white)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .bottomLeading)
            .background(background.color, in: .rect(cornerRadius: 14))
            Text("文字对比度 \(candidate ? background.readableContrast : background.whiteContrast, specifier: "%.2f")∶1")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct ReviewAlbumContrastCard: View {
    let candidate: Bool
    let image: String?
    @State private var backdrop: AlbumArtworkBackdrop?

    private var rgb: ReviewRGB {
        guard let backdrop else { return ReviewRGB(red: 0.55, green: 0.55, blue: 0.55) }
        return ReviewRGB(red: backdrop.red, green: backdrop.green, blue: backdrop.blue)
    }
    private var currentUsesWhite: Bool {
        0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue < 0.58
    }
    private var foreground: Color {
        candidate ? rgb.readableForeground : currentUsesWhite ? .white : .black
    }
    private var ratio: Double {
        candidate ? rgb.readableContrast : currentUsesWhite ? rgb.whiteContrast : rgb.blackContrast
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    if let image {
                        Image(image).resizable().scaledToFill().frame(width: 76, height: 76)
                            .clipShape(.rect(cornerRadius: 8)).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(image == nil ? "中灰输入样本" : "在路上的那些天").font(.title3.bold())
                        Text("晴空乐队").font(.subheadline).opacity(candidate ? 1 : 0.65)
                    }
                }
                Divider().overlay(foreground.opacity(0.3))
                Text("1   迎着风，走过长长的街").font(.callout)
                Text("2   在路上的那些天").font(.callout)
            }
            .foregroundStyle(foreground)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rgb.color, in: .rect(cornerRadius: 14))
            Text("标题对比度 \(ratio, specifier: "%.2f")∶1")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .task(id: image) {
            guard let image, let data = UIImage(named: image)?.pngData() else { return }
            let result = await Task.detached(priority: .utility) { AlbumArtworkBackdrop.extract(from: data) }.value
            guard !Task.isCancelled else { return }
            backdrop = result
        }
    }
}

private enum ReviewScanState: String, CaseIterable, Identifiable {
    case summary = "扫描结果", failed = "扫描失败", scanning = "扫描中"
    var id: Self { self }
}

private struct ReviewLibraryStatusPage: View {
    let candidate: Bool
    @State private var scanState = ReviewScanState.summary
    @State private var showsDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("状态", selection: $scanState) {
                    ForEach(ReviewScanState.allCases) { state in Text(state.rawValue).tag(state) }
                }
                .pickerStyle(.segmented)
                Text("最近添加").font(.title2.bold())
                ZStack(alignment: .bottom) {
                    VStack(spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            ReviewAlbumTile(image: "AlbumSample15", title: "夜晚散步")
                            ReviewAlbumTile(image: "AlbumSample03", title: "在路上的那些天")
                        }
                        HStack(alignment: .top, spacing: 12) {
                            ReviewAlbumTile(image: "AlbumSample08", title: "今天的好心情")
                            ReviewAlbumTile(image: "AlbumSample14", title: "夜色温柔")
                        }
                    }
                    if !candidate {
                        Text(message).font(.caption).padding()
                    }
                }
                if candidate { status }
                ReviewMiniPlayer(candidate: candidate)
            }
            .padding(20)
        }
    }

    private var message: String {
        switch scanState {
        case .summary: "跳过 1 个不支持的音频文件。"
        case .failed: "无法读取音乐文件夹，请检查文件是否仍在此 iPhone 上。"
        case .scanning: "正在扫描音乐文件…"
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                if scanState == .scanning { ProgressView().controlSize(.small) }
                else { Image(systemName: scanState == .failed ? "exclamationmark.circle" : "info.circle") }
                Text(message).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            }
            if scanState == .summary {
                DisclosureGroup("查看详情", isExpanded: $showsDetails) {
                    Text("示例文件 ‘音乐／待整理／旧录音.txt’ 的格式暂不支持。支持 MP3、AAC、ALAC、FLAC、WAV 和 AIFF。")
                        .font(.footnote).padding(.top, 8)
                }
            } else if scanState == .failed {
                Button("重新扫描") { scanState = .scanning }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
    }
}

private enum ReviewToastKind: String, CaseIterable, Identifiable {
    case favorited = "已喜爱", unfavorited = "已取消喜爱"
    case pinned = "已置顶", unpinned = "已取消置顶"
    case playingNext = "下个播放", addedToQueue = "已添加到队列"
    case addedToPlaylist = "加入单个歌单", addedToPlaylists = "加入多个歌单", error = "错误"
    var id: Self { self }
    var toast: LibraryToast {
        switch self {
        case .favorited: .favorited
        case .unfavorited: .unfavorited
        case .pinned: .pinned
        case .unpinned: .unpinned
        case .playingNext: .playingNext
        case .addedToQueue: .addedToQueue
        case .addedToPlaylist: .addedToPlaylist(count: 12, title: "通勤路上与夜晚散步时听的音乐", artwork: .image(Image("AlbumSample03")), playlistID: "review-only")
        case .addedToPlaylists: .addedToPlaylists(count: 12, playlistCount: 3)
        case .error: .error("连接暂时中断，未能保存喜爱状态。请回到歌曲操作重试。")
        }
    }
    var hasExtendedDuration: Bool {
        switch self {
        case .addedToPlaylist, .addedToPlaylists, .error: true
        default: false
        }
    }
    var holdsForVoiceOver: Bool { self == .addedToPlaylist || self == .error }
}

private struct ReviewToastPage: View {
    let candidate: Bool
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var kind = ReviewToastKind.addedToPlaylist
    @State private var presentation = UUID()
    @State private var isShowing = true
    @State private var holdForInspection = ProcessInfo.processInfo.arguments.contains("-frontendReviewHoldToast")
    @State private var opensPlaylist = false

    private var duration: Double { candidate && kind.hasExtendedDuration ? 5 : 1.5 }
    private var keepsVisible: Bool { holdForInspection || (candidate && voiceOver && kind.holdsForVoiceOver) }
    private var lifetimeID: String { "\(presentation)-\(candidate)-\(kind.rawValue)-\(voiceOver)-\(holdForInspection)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("提示类型", selection: $kind) {
                    ForEach(ReviewToastKind.allCases) { item in Text(item.rawValue).tag(item) }
                }
                .pickerStyle(.menu)
                Toggle("保持显示以便检查", isOn: $holdForInspection)
                LabeledContent("显示时间", value: keepsVisible ? "保留至关闭或替换" : "\(duration.formatted()) 秒")
                HStack(spacing: 20) {
                    Button("显示提示") { present() }.buttonStyle(.borderedProminent)
                    Button("关闭提示") { isShowing = false }
                }
                Text("切换类型或连续点按会替换当前提示。可点按歌单提示打开隔离示例；错误恢复仍位于发起操作的页面。")
                    .font(.footnote).foregroundStyle(.secondary)
                ReviewSongRow(candidate: candidate, image: "AlbumSample03", title: "在路上的那些天", artist: "晴空乐队")
                ReviewSongRow(candidate: candidate, image: "AlbumSample08", title: "夜晚散步", artist: "晴空乐队")
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            VStack(spacing: 12) {
                if isShowing {
                    ReviewToastCard(toast: kind.toast, candidate: candidate) {
                        isShowing = false
                        opensPlaylist = true
                    }
                    .accessibilityAction(named: "关闭提示") { isShowing = false }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
                }
                ReviewMiniPlayer(candidate: candidate)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: isShowing)
        .onChange(of: kind) { _, _ in present() }
        .task(id: lifetimeID) {
            guard isShowing, !keepsVisible else { return }
            do { try await Task.sleep(for: .seconds(duration)) }
            catch { return }
            guard !Task.isCancelled else { return }
            isShowing = false
        }
        .sheet(isPresented: $opensPlaylist) {
            NavigationStack {
                List {
                    Text("通勤路上与夜晚散步时听的音乐").font(.title2.bold())
                    Text("隔离示例播放列表").foregroundStyle(.secondary)
                    Text("在路上的那些天")
                    Text("夜晚散步")
                }
                .navigationTitle("播放列表")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { opensPlaylist = false } } }
            }
        }
    }

    private func present() {
        presentation = UUID()
        isShowing = true
        if candidate && voiceOver { UIAccessibility.post(notification: .announcement, argument: kind.toast.title) }
    }
}

private struct ReviewToastCard: View {
    let toast: LibraryToast
    let candidate: Bool
    let openPlaylist: () -> Void

    var body: some View {
        content
            .frame(height: candidate ? nil : 53)
            .frame(minHeight: 53)
            .background(.regularMaterial, in: .rect(cornerRadius: 18))
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var content: some View {
        if case .addedToPlaylist(_, let title, let artwork, _) = toast {
            Button(action: openPlaylist) {
                HStack(spacing: 10) {
                    ArtworkView(artwork: artwork, cornerRadius: 4).frame(width: 33, height: 33)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(toast.title).font(.footnote).foregroundStyle(.secondary)
                        HStack(spacing: 3) {
                            Text(title).font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                    }
                    .lineLimit(candidate ? nil : 1)
                    .fixedSize(horizontal: false, vertical: candidate)
                }
                .padding(.leading, 10)
                .padding(.trailing, 18)
                .padding(.vertical, candidate ? 10 : 0)
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 12) {
                Image(systemName: toast.systemImage).font(.body.weight(.semibold)).accessibilityHidden(true)
                Text(toast.title).font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: candidate)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, candidate ? 12 : 0)
        }
    }
}

#Preview("可读性候选") {
    FrontendReadabilityPreview(page: "home")
}
#endif
