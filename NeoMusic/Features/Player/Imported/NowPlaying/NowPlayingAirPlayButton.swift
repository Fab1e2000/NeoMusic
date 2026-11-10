import SwiftUI
import AVKit

/// 保留系统输出设备选择，当前设备名称由音频路由提供。
struct ReferenceAirPlayButton: View {
    var opacity: Double = 0.72
    @State private var route = ReferenceAudioOutputRoute()
    @Environment(\.playerArtistEDREnabled) private var edrEnabled
    @Environment(\.nowPlayingBackdropImage) private var backdrop
    @Environment(\.nowPlayingUndimmedBackdropImage) private var undimmed
    @Environment(\.nowPlayingBackdropAnchor) private var anchor
    private var usesEDR: Bool { edrEnabled && (undimmed ?? backdrop) != nil && anchor != nil && !route.output.isAirPlay }

    var body: some View {
        ZStack {
            ReferenceAirPlayRoutePicker(opacity: opacity, hidesGlyph: usesEDR)
            if usesEDR {
                PlayerEDRControlLayer(shape: .symbol("airplayaudio", 18, 1), role: .buttons)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("音频输出")
        .accessibilityValue(route.output.name)
        .accessibilityHint("选择播放设备")
    }
}

struct ReferenceAudioOutput {
    let name: String
    let isAirPlay: Bool

    init(outputs: [(port: AVAudioSession.Port, name: String)]) {
        name = outputs.map(\.name).filter { !$0.isEmpty }.joined(separator: "，")
        isAirPlay = outputs.contains { $0.port == .airPlay }
    }
}

@MainActor @Observable
private final class ReferenceAudioOutputRoute {
    private(set) var output = ReferenceAudioOutput(outputs: [])
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func refresh() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        output = ReferenceAudioOutput(outputs: outputs.map { ($0.portType, $0.portName) })
    }
}

private struct ReferenceAirPlayRoutePicker: UIViewRepresentable {
    let opacity: Double
    /// EDR 图层负责绘制时，保留系统按钮的原有动作。
    let hidesGlyph: Bool

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        return picker
    }

    /// 播放页固定深色，用主题色的深色档，不随窗口外观取浅色档。
    func updateUIView(_ picker: AVRoutePickerView, context: Context) {
        picker.tintColor = hidesGlyph ? .clear : UIColor.white.withAlphaComponent(opacity)
        picker.activeTintColor = hidesGlyph ? .clear : UIColor(DizzyPalette.accentOnDark)
    }
}
