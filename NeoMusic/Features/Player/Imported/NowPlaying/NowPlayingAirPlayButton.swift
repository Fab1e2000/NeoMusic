import SwiftUI
import AVKit

/// 保留系统输出设备选择，当前设备名称由音频路由提供。
struct ReferenceAirPlayButton: View {
    var opacity: Double = 0.72
    @State private var route = ReferenceAudioOutputRoute()

    var body: some View {
        ReferenceAirPlayRoutePicker(opacity: opacity)
            .scaleEffect(1.27)
            .blendMode(.plusLighter)
            .overlay(alignment: .top) {
                if route.output.isExternal {
                    Text(route.output.name)
                        .font(.system(size: 13, weight: .semibold))
                        .nowPlayingPlusLighter(opacity)
                        .lineLimit(1)
                        .frame(width: 180, height: 18)
                        .offset(y: 47)
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
    let isExternal: Bool

    init(outputs: [(port: AVAudioSession.Port, name: String)]) {
        name = outputs.map(\.name).filter { !$0.isEmpty }.joined(separator: "，")
        isAirPlay = outputs.contains { $0.port == .airPlay }
        isExternal = outputs.contains { $0.port != .builtInSpeaker && $0.port != .builtInReceiver }
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

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        return picker
    }

    /// 播放页固定深色，用主题色的深色档，不随窗口外观取浅色档。
    func updateUIView(_ picker: AVRoutePickerView, context: Context) {
        picker.tintColor = UIColor.white.withAlphaComponent(opacity)
        picker.activeTintColor = UIColor.white.withAlphaComponent(opacity)
    }
}
