// Direct source port from MeloX (GPL-3.0), b8bc60f.
// NeoDizzy adapters are limited to track data, available playback features and localization.
import MediaPlayer
import SwiftUI

struct NowPlayingProgressControl: View {
    @Environment(ReferencePlayerState.self) private var player
    @Environment(ReferencePlayerActions.self) private var actions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var timeFontSize: CGFloat = 12.5

    @Environment(\.nowPlayingLayout) private var layout
    let song: ReferenceTrack

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                progressSlider
                timeLabels
                progressStatus
                    .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            referenceLayout
        }
    }

    private var referenceLayout: some View {
        GeometryReader { proxy in
            ZStack {
            progressSlider
            .frame(width: layout.width(338))
            .position(x: proxy.size.width / 2, y: 26 - 10.5 * layout.verticalScale)

            timeLabels
            .overlay { progressStatus }
            .frame(width: layout.width(337.5), height: timeLineHeight)
            .position(x: proxy.size.width / 2, y: 26 + 10.5 * layout.verticalScale + (timeLineHeight - 18) / 2)
            }
        }
        .frame(height: timeLineHeight + 34)
    }

    private var progressSlider: some View {
        Slider(value: Binding(get: { min(player.progress, progressMaximum) },
                              set: { player.seek(to: $0) }), in: 0...progressMaximum)
            .sliderThumbVisibility(.hidden)
            .tint(.white)
            .frame(height: 44)
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(formatTime(player.progress))，共 \(formatTime(progressMaximum))")
    }

    private var timeLabels: some View {
        HStack {
            Text(formatTime(player.progress))
                .modifier(PlayerEDRControlAvailable(shape: .time(formatTime(player.progress), false, timeFontSize)))
            Spacer()
            Text("−\(formatTime(max(player.duration - player.progress, 0)))")
                .modifier(PlayerEDRControlAvailable(shape: .time("−\(formatTime(max(player.duration - player.progress, 0)))", true, timeFontSize)))
        }
        .font(.system(size: timeFontSize, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.5))
    }

    private var timeLineHeight: CGFloat { max(18, timeFontSize * 1.3) }

    private var progressStatus: some View {
        Group {
            if player.isPreview {
                Text("试听").foregroundStyle(.white.opacity(0.8))
            } else if player.issue != nil {
                Image(systemName: "exclamationmark.circle")
            } else if let quality = actions.audioQuality(for: song) {
                NowPlayingAudioQualityControl(quality: quality,
                    openAudioQualitySettings: actions.canOpenAudioQualitySettings
                        ? { actions.openAudioQualitySettings() } : nil)
                    .accessibilityIdentifier("player.audioQuality")
            }
        }
        .font(.system(size: timeFontSize, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.5))
    }

    private var progressMaximum: TimeInterval {
        max(player.duration, song.duration, 1)
    }

    private func formatTime(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "0:00" }
        let seconds = max(0, Int(value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct NowPlayingTransportControls: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(ReferencePlayerState.self) private var player

    @Environment(\.nowPlayingLayout) private var layout

    @State private var showsLoadingIndicator = false
    /// 每点一次上一首/下一首加一，触发图标的推进动画。
    @State private var previousTrigger = 0
    @State private var nextTrigger = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack {

            Button {
                previousTrigger += 1
                player.previous()
            } label: {
                NowPlayingSkipIcon(
                    direction: .backward,
                    trigger: previousTrigger,
                    reducesMotion: accessibilityReduceMotion
                )
                .frame(width: 40.67, height: 27.39)
                    .frame(width: 64, height: 64)
                    .contentShape(.circle)
            }
            .buttonStyle(
                NowPlayingTransportButtonStyle(
                    reducesMotion: accessibilityReduceMotion
                )
            )
            .accessibilityLabel("上一首")
            .position(x: layout.x(93.75), y: 41)

            Button {
                player.togglePlayback()
            } label: {
                ZStack {
                    NowPlayingPlayPauseIcon(
                        isPlaying: player.isPlaying,
                        reducesMotion: accessibilityReduceMotion
                    )
                    .frame(width: 32, height: 40)
                    .opacity(showsLoadingIndicator ? 0 : 1)
                    .scaleEffect(showsLoadingIndicator ? 0.6 : 1)

                    if showsLoadingIndicator {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                            .transition(.opacity)
                    }
                }
                .frame(width: 64, height: 64)
                // 加载很快结束时不闪转圈：持续 0.3 秒以上才换成转圈。
                .task(id: player.isLoading) {
                    if player.isLoading {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                    }
                    withAnimation(accessibilityReduceMotion ? nil : .smooth(duration: 0.2)) {
                        showsLoadingIndicator = player.isLoading
                    }
                }
                .contentShape(.circle)
            }
            .buttonStyle(
                NowPlayingTransportButtonStyle(
                    reducesMotion: accessibilityReduceMotion,
                    springsBack: true
                )
            )
            .accessibilityLabel(
                player.isPlaying
                    ? "暂停"
                    : "播放"
            )
            .position(x: proxy.size.width / 2, y: 41)

            Button {
                nextTrigger += 1
                player.next()
            } label: {
                NowPlayingSkipIcon(
                    direction: .forward,
                    trigger: nextTrigger,
                    reducesMotion: accessibilityReduceMotion
                )
                .frame(width: 40.67, height: 27.39)
                    .frame(width: 64, height: 64)
                    .contentShape(.circle)
            }
            .buttonStyle(
                NowPlayingTransportButtonStyle(
                    reducesMotion: accessibilityReduceMotion
                )
            )
            .accessibilityLabel("下一首")
            .disabled(!player.canPlayNext)
            .position(x: layout.x(308.25), y: 41)
            }
        }
        .frame(height: 82)
    }
}

struct NowPlayingVolumeControl: View {
    @Environment(\.nowPlayingLayout) private var layout

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Image(systemName: "speaker.fill")
                    .resizable().scaledToFit()
                    .frame(width: 8, height: 13)
                    .position(x: layout.x(39.5), y: 21)
                SystemVolumeSlider()
                    .frame(width: layout.width(279), height: 44)
                    .position(x: proxy.size.width / 2, y: 21)
                    .accessibilityLabel("系统音量")
                Image(systemName: "speaker.wave.3.fill")
                    .resizable().scaledToFit()
                    .frame(width: 18, height: 14)
                    .position(x: layout.x(362.5), y: 21)
            }
        }
        .foregroundStyle(.white.opacity(0.65))
        .frame(height: 42)
    }
}

final class AlignedSystemVolumeView: MPVolumeView {
    // MPVolumeView can restore its own thumb after the inner UISlider lays out.
    // Configure its public appearance API as well, including the pressed state.
    private let hiddenThumb = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    private let filledTrack = AlignedSystemVolumeView.trackImage(alpha: 1)
    private let emptyTrack = AlignedSystemVolumeView.trackImage(alpha: 0.22)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAppearance()
    }

    private static func trackImage(alpha: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 7)).image { _ in
            UIColor.white.withAlphaComponent(alpha).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 8, height: 7), cornerRadius: 3.5).fill()
        }.resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: 3.5, bottom: 0, right: 3.5))
    }

    private func configureAppearance() {
        for state: UIControl.State in [.normal, .highlighted, .disabled, .selected] {
            setVolumeThumbImage(hiddenThumb, for: state)
            setMinimumVolumeSliderImage(filledTrack, for: state)
            setMaximumVolumeSliderImage(emptyTrack, for: state)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for slider in subviews.compactMap({ $0 as? UISlider }) {
            if slider.sliderStyle != .thumbless { slider.sliderStyle = .thumbless }
            for state: UIControl.State in [.normal, .highlighted, .disabled, .selected] {
                if slider.thumbImage(for: state) !== hiddenThumb { slider.setThumbImage(hiddenThumb, for: state) }
            }
        }
    }

    override func volumeSliderRect(forBounds bounds: CGRect) -> CGRect { bounds }
}

private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> AlignedSystemVolumeView {
        let volumeView = AlignedSystemVolumeView(
            frame: CGRect(x: 0, y: 0, width: 200, height: 32)
        )
        volumeView.backgroundColor = .clear
        volumeView.showsVolumeSlider = true
        volumeView.tintColor = .white
        return volumeView
    }

    func updateUIView(
        _ volumeView: AlignedSystemVolumeView,
        context: Context
    ) {
        volumeView.showsVolumeSlider = true
        volumeView.tintColor = .white
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: AlignedSystemVolumeView,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? 200,
            height: proposal.height ?? 32
        )
    }
}

struct NowPlayingPageSelector: View {
    @Environment(\.accessibilityReduceMotion)
    private var accessibilityReduceMotion
    @Environment(ReferencePlayerState.self) private var player

    @Environment(\.nowPlayingLayout) private var layout

    @Binding var page: NowPlayingPage
    let hasLyrics: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // A selected lyrics page remains dismissible while the next track loads.
                pageButton(page: .lyrics, systemImage: "quote.bubble", accessibilityLabel: "歌词")
                    .disabled(!hasLyrics && page != .lyrics)
                    .opacity(hasLyrics || page == .lyrics ? 1 : 0.32)
                    .position(x: layout.x(86.75), y: 25)
                ReferenceAirPlayButton(opacity: 0.72)
                    .frame(width: 44, height: 44)
                    .scaleEffect(1.27)
                    .position(x: proxy.size.width / 2, y: 25)
                pageButton(page: .queue, systemImage: "list.bullet", accessibilityLabel: "继续播放",
                           badgeSystemImage: page == .queue ? nil : player.queueModeBadgeSystemImage)
                    .position(x: layout.x(315.25), y: 25)
            }
        }
        .frame(height: 50)
        .animation(accessibilityReduceMotion ? nil : .smooth(duration: 0.25), value: hasLyrics)
    }

    private func pageButton(
        page destination: NowPlayingPage,
        systemImage: String,
        accessibilityLabel: String,
        badgeSystemImage: String? = nil
    ) -> some View {
        let isSelected = page == destination

        return Button {
            let targetPage: NowPlayingPage =
                isSelected ? .artwork : destination
            withAnimation(
                accessibilityReduceMotion
                    ? nil
                    : NowPlayingPageTransition
                        .selectionAnimation(
                            from: page,
                            to: targetPage
                        )
            ) {
                page = targetPage
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemImage)
                    .resizable()
                    .symbolVariant(isSelected ? .fill : .none)
                    .scaledToFit()
                    .frame(width: 22.5, height: 23.5)
                    .frame(width: 44, height: 44)
                    .foregroundStyle(
                        isSelected
                            ? .black.opacity(0.68)
                            : .white.opacity(0.72)
                    )
                    .modifier(PlayerEDRControlAvailable(shape: .symbol(systemImage, 22.5, 1), role: .buttons, isEnabled: !isSelected))
                    .background {
                        if isSelected {
                            Circle().fill(.white.opacity(0.68))
                                .modifier(PlayerEDRControlAvailable(shape: .circle(44), role: .buttons))
                        }
                    }
                    .scaleEffect(isSelected && destination == .queue ? 38.0 / 44.0 : 1)

                if let badgeSystemImage {
                    Image(systemName: badgeSystemImage)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(
                            isSelected
                                ? .white.opacity(0.9)
                                : .black.opacity(0.74)
                        )
                        .frame(width: 15, height: 15)
                        .background(
                            isSelected
                                ? .black.opacity(0.58)
                                : .white.opacity(0.82),
                            in: .circle
                        )
                        .offset(x: 3, y: 1)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
