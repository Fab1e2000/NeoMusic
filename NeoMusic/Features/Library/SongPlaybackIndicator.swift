import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var songRowPlayback: NowPlayingModel? = nil
}

/// Only the small current-track slot observes transport state. Audio samples are
/// read by its UIView, so display frames never invalidate the list or its rows.
struct AlbumSongPosition: View {
    let song: LibrarySongItem
    @Environment(\.songRowPlayback) private var playback
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let playback, playback.hasCurrent, playback.current.id == song.id {
                SongPlaybackIndicator(active: playback.isPlaying && !playback.isLoading && scenePhase == .active && !reduceMotion,
                                      samples: { [weak playback] in playback?.spectrumLevels() ?? [] })
                    .frame(width: 16, height: 20)
                    .accessibilityLabel(playback.isPlaying ? "正在播放" : "已暂停")
            } else {
                Text("\(song.trackNumber)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 22)
        .overlay(alignment: .leading) { FavoriteMark(isFavorite: song.isFavorite) }
    }
}

struct SongPlaybackIndicator: UIViewRepresentable {
    var active: Bool
    var samples: () -> [Float]

    func makeUIView(context: Context) -> SpectrumBarsView { SpectrumBarsView() }
    func updateUIView(_ view: SpectrumBarsView, context: Context) {
        view.samples = samples
        view.active = active
    }
    static func dismantleUIView(_ view: SpectrumBarsView, coordinator: ()) { view.stop() }
}

final class SpectrumBarsView: UIView {
    var samples: () -> [Float] = { [] }
    var active = false { didSet { updateClock() } }
    private var levels = [CGFloat](repeating: 0, count: 5)
    private var displayLink: CADisplayLink?
    private lazy var target = DisplayTarget(view: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SpectrumBarsView, _: UITraitCollection) in view.setNeedsDisplay() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() { super.didMoveToWindow(); updateClock() }

    private func updateClock() {
        guard active, window != nil else { stop(); return }
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: target, selector: #selector(DisplayTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
    func stop() {
        displayLink?.invalidate(); displayLink = nil
        levels = Array(repeating: 0, count: 5)
        setNeedsDisplay()
    }
    fileprivate func tick() {
        let values = samples()
        for i in levels.indices {
            let value = values.indices.contains(i) ? CGFloat(values[i]) : 0
            let target = value.isFinite ? min(1, max(0, value)) : 0
            levels[i] = target // Demo C attack/release already happens in the analyzer.
        }
        setNeedsDisplay()
    }
    override func draw(_ rect: CGRect) {
        UIColor.label.setFill()
        for i in levels.indices {
            let height = 2 + 16 * levels[i]
            UIBezierPath(roundedRect: CGRect(x: CGFloat(i) * 3.4, y: (bounds.height - height) / 2,
                                             width: 2.2, height: height), cornerRadius: 1.1).fill()
        }
    }
    @MainActor private final class DisplayTarget: NSObject {
        weak var view: SpectrumBarsView?
        init(view: SpectrumBarsView) { self.view = view }
        @objc func tick() { view?.tick() }
    }
}
