import FrontAMCore
import SwiftUI
import UIKit

public struct AlbumSongPosition: View {
    public let song: LibrarySongItem
    public var foreground: Color? = nil
    @Environment(\.songRowPlayback) private var playback
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.songPlaybackIndicatorsActive) private var indicatorsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .callout) private var positionWidth = 22.0

    public var body: some View {
        Group {
            if let playback, playback.currentSongID == song.id {
                SongPlaybackIndicator(analyzer: playback.playbackSpectrum, active: indicatorsActive && playback.isPlaying && !playback.isLoading && scenePhase == .active && !reduceMotion,
                                      samples: { [weak playback] in playback?.spectrumLevels() ?? [] })
                    .frame(width: 16, height: 20)
                    .accessibilityLabel(playback.isPlaying ? "正在播放" : "已暂停")
            } else {
                Text("\(song.trackNumber)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(foreground ?? .secondary)
            }
        }
        .frame(width: positionWidth)
        .overlay(alignment: .leading) { FavoriteMark(isFavorite: song.isFavorite, color: foreground ?? .secondary, leadingOffset: -13.5) }
    }

    public init(song: LibrarySongItem,
                foreground: Color? = nil) {
        self.song = song
        self.foreground = foreground
    }
}

public struct PlaylistSongArtwork: View {
    public let song: LibrarySongItem
    public var cornerRadius: CGFloat = DesignTokens.Radius.songRowCover

    public var body: some View {
        ArtworkView(artwork: song.artwork, cornerRadius: cornerRadius)
            .environment(\.nativeArtworkSurfaceEnabled, false)
            .songPlaybackOverlay(songID: song.id, cornerRadius: cornerRadius)
    }

    public init(song: LibrarySongItem,
                cornerRadius: CGFloat = DesignTokens.Radius.songRowCover) {
        self.song = song
        self.cornerRadius = cornerRadius
    }
}

private struct SongPlaybackOverlay: ViewModifier {
    let songID: String
    let cornerRadius: CGFloat
    @Environment(\.songRowPlayback) private var playback
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.songPlaybackIndicatorsActive) private var indicatorsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if let playback, playback.currentSongID == songID {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.black.opacity(0.4))
                        .overlay {
                            SongPlaybackIndicator(
                                analyzer: playback.playbackSpectrum,
                                active: indicatorsActive && playback.isPlaying && !playback.isLoading && scenePhase == .active && !reduceMotion,
                                samples: { [weak playback] in playback?.spectrumLevels() ?? [] },
                                color: .white
                            )
                            .frame(width: 16, height: 20)
                        }
                        .accessibilityLabel(playback.isPlaying ? "正在播放" : "已暂停")
                        .accessibilityIdentifier("playlist.playback.\(songID)")
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    public func songPlaybackOverlay(songID: String, cornerRadius: CGFloat = DesignTokens.Radius.songRowCover) -> some View {
        modifier(SongPlaybackOverlay(songID: songID, cornerRadius: cornerRadius))
    }
}

public struct SongPlaybackIndicator: UIViewRepresentable {
    public var analyzer: (any FrontAMSpectrumSource)? = nil
    public var active: Bool
    public var samples: () -> [Float]
    public var color: UIColor = .label

    public init(analyzer: (any FrontAMSpectrumSource)? = nil, active: Bool, samples: @escaping () -> [Float], color: UIColor = .label) {
        self.analyzer = analyzer
        self.active = active
        self.samples = samples
        self.color = color
    }

    public func makeUIView(context: Context) -> SpectrumBarsView { SpectrumBarsView() }
    public func updateUIView(_ view: SpectrumBarsView, context: Context) {
        view.barColor = color
        view.samples = samples
        view.analyzer = analyzer
        view.active = active
    }
    public static func dismantleUIView(_ view: SpectrumBarsView, coordinator: ()) { view.stop() }
}

public final class SpectrumBarsView: UIView {
    public var barColor: UIColor = .label { didSet { if oldValue != barColor { applyBarColor() } } }
    public var samples: () -> [Float] = { [] }
    public var active = false { didSet { updateClock() } }
    private var levels = [CGFloat](repeating: 0, count: 5)
    private let barLayers: [CALayer] = (0..<5).map { _ in
        let bar = CALayer()
        bar.cornerRadius = 1.1
        bar.cornerCurve = .circular
        return bar
    }
    public var analyzer: (any FrontAMSpectrumSource)? {
        didSet {
            if oldValue !== analyzer, displayLink != nil { subscription = analyzer?.subscribeSpectrum() }
        }
    }
    private var subscription: AnyObject?
    private var displayLink: CADisplayLink?
    public var hasActiveDisplayLink: Bool { displayLink?.isPaused == false }
    private lazy var target = DisplayTarget(view: self)

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        for bar in barLayers { layer.addSublayer(bar) }
        applyBarColor()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SpectrumBarsView, _: UITraitCollection) in view.applyBarColor() }
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func didMoveToWindow() { super.didMoveToWindow(); updateClock() }
    public override func layoutSubviews() {
        super.layoutSubviews()
        layoutBars()
    }

    private func applyBarColor() {
        let resolved = barColor.resolvedColor(with: traitCollection).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in barLayers { bar.backgroundColor = resolved }
        CATransaction.commit()
    }

    private func layoutBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in barLayers.indices {
            let height = 2 + 16 * levels[i]
            barLayers[i].frame = CGRect(
                x: CGFloat(i) * 3.4,
                y: (bounds.height - height) / 2,
                width: 2.2,
                height: height
            )
        }
        CATransaction.commit()
    }

    private func updateClock() {
        guard active, window != nil else { stop(); return }
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: target, selector: #selector(DisplayTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        subscription = analyzer?.subscribeSpectrum()
    }
    public func stop() {
        displayLink?.invalidate(); displayLink = nil
        subscription = nil
        levels = Array(repeating: 0, count: 5)
        layoutBars()
    }
    fileprivate func tick() {
        let values = samples()
        var changed = false
        for i in levels.indices {
            let value = values.indices.contains(i) ? CGFloat(values[i]) : 0
            let target = value.isFinite ? min(1, max(0, value)) : 0
            if abs(levels[i] - target) > 0.0005 {
                levels[i] = target
                changed = true
            }
        }
        if changed { layoutBars() }
    }
    @MainActor private final class DisplayTarget: NSObject {
        weak var view: SpectrumBarsView?
        init(view: SpectrumBarsView) { self.view = view }
        @objc func tick() { view?.tick() }
    }
}
