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
        NowPlayingProgressSlider(maximum: progressMaximum)
    }

    private var timeLabels: some View {
        NowPlayingTimeLabels(fontSize: timeFontSize)
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

}

/// Only the slider and time readout subscribe to the periodic playback clock.
/// The quality control and surrounding page layout retain their existing inputs.
private struct NowPlayingProgressSlider: UIViewRepresentable {
    let maximum: TimeInterval
    @Environment(ReferencePlayerState.self) private var player

    func makeCoordinator() -> Coordinator { Coordinator(player: player) }

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        slider.sliderStyle = .thumbless
        slider.minimumTrackTintColor = UIColor.white.withAlphaComponent(0.5)
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.begin), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.end),
                         for: [.touchUpInside, .touchUpOutside, .touchCancel])
        slider.accessibilityLabel = "播放进度"
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.player = player
        slider.maximumValue = Float(maximum)
        if !slider.isTracking { slider.value = Float(min(player.progress, maximum)) }
        slider.accessibilityValue = "\(formatPlaybackTime(player.progress))，共 \(formatPlaybackTime(maximum))"
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 338, height: 44)
    }

    @MainActor final class Coordinator: NSObject {
        var player: ReferencePlayerState
        private let scrub = NowPlayingProgressScrub()
        init(player: ReferencePlayerState) { self.player = player }
        @objc func begin() { scrub.setEditing(true) }
        @objc func end() { scrub.setEditing(false) }
        @objc func changed(_ slider: UISlider) {
            // UIKit emits valueChanged for user input, including VoiceOver;
            // updating the control from the playback clock emits no event.
            scrub.setEditing(true)
            scrub.propose(Double(slider.value)) { player.seek(to: $0) }
            if !slider.isTracking { scrub.setEditing(false) }
        }
    }
}

private struct NowPlayingTimeLabels: View {
    let fontSize: CGFloat
    @Environment(ReferencePlayerState.self) private var player

    var body: some View {
        HStack {
            Text(formatPlaybackTime(player.progress))
                .modifier(PlayerEDRControlAvailable(shape: .time(formatPlaybackTime(player.progress), false, fontSize)))
            Spacer()
            Text("−\(formatPlaybackTime(max(player.duration - player.progress, 0)))")
                .modifier(PlayerEDRControlAvailable(shape: .time("−\(formatPlaybackTime(max(player.duration - player.progress, 0)))", true, fontSize)))
        }
        .font(.system(size: fontSize, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.5))
        .opacity(0.85)
    }
}

private func formatPlaybackTime(_ value: TimeInterval) -> String {
    guard value.isFinite else { return "0:00" }
    let seconds = max(0, Int(value))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

/// Forwards values only during a user-originated slider edit.
@MainActor final class NowPlayingProgressScrub {
    private(set) var isEditing = false

    func setEditing(_ editing: Bool) {
        isEditing = editing
    }

    func propose(_ value: Double, seek: (Double) -> Void) {
        guard isEditing, value.isFinite else { return }
        seek(value)
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
                .frame(width: 40, height: 23)
                .offset(y: -0.5)
                    .frame(width: 64, height: 64)
                    .contentShape(.circle)
            }
            .buttonStyle(
                NowPlayingTransportButtonStyle(
                    reducesMotion: accessibilityReduceMotion
                )
            )
            .accessibilityLabel("上一首")
            .position(x: layout.x(94.25), y: 41)

            Button {
                player.togglePlayback()
            } label: {
                ZStack {
                    NowPlayingPlayPauseIcon(
                        isPlaying: player.isPlaying,
                        reducesMotion: accessibilityReduceMotion
                    )
                    .frame(width: player.isPlaying ? 32 : 31.67, height: player.isPlaying ? 40 : 35.67)
                    .offset(x: player.isPlaying ? 0 : 1.8)
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
                .frame(width: 40, height: 23)
                .offset(y: -0.5)
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
            .position(x: layout.x(307.75), y: 41)
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
                    .position(x: layout.x(38.25), y: 21)
                SystemVolumeSlider()
                    .frame(width: layout.width(279), height: 44)
                    .position(x: layout.x(196.5), y: 21)
                    .accessibilityLabel("系统音量")
                Image(systemName: "speaker.wave.3.fill")
                    .resizable().scaledToFit()
                    .frame(width: 18, height: 14)
                    .position(x: layout.x(358.5), y: 21)
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAppearance()
    }

    private func configureAppearance() {
        for state: UIControl.State in [.normal, .highlighted, .disabled, .selected] {
            setVolumeThumbImage(hiddenThumb, for: state)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for slider in subviews.compactMap({ $0 as? UISlider }) {
            if slider.sliderStyle != .thumbless { slider.sliderStyle = .thumbless }
            slider.minimumTrackTintColor = UIColor.white.withAlphaComponent(0.5)
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
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
                    .position(x: layout.x(87), y: 25)
                ReferenceAirPlayButton(opacity: 0.5)
                    .frame(width: 44, height: 44)
                    .position(x: proxy.size.width / 2, y: 25)
                pageButton(page: .queue, systemImage: "list.bullet", accessibilityLabel: "继续播放")
                    .position(x: layout.x(315), y: 25)
            }
        }
        .frame(height: 50)
        .animation(accessibilityReduceMotion ? nil : .smooth(duration: 0.25), value: hasLyrics)
    }

    private func pageButton(
        page destination: NowPlayingPage,
        systemImage: String,
        accessibilityLabel: String
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
                    .frame(width: destination == .queue ? 20.67 : 22.5,
                           height: destination == .queue ? 15.33 : 23.5)
                    .frame(width: 44, height: 44)
                    .foregroundStyle(
                        isSelected
                            ? .black.opacity(0.68)
                            : .white.opacity(0.6)
                    )
                    .background {
                        if isSelected {
                            Circle().fill(.white.opacity(0.5))
                                .frame(width: 38, height: 38)
                        }
                    }
                    .offset(y: isSelected && destination == .lyrics ? 1 : 0)

            }
            .frame(width: 44, height: 44)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
