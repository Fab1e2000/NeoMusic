import SwiftUI
import AVKit

/// 隔空播放按钮。输出是蓝牙时图标换成 AirPods，点按仍弹出系统的输出设备选择。
struct ReferenceAirPlayButton: View {
    var opacity: Double = 0.72
    @State private var route = ReferenceAudioOutputRoute()
    @Environment(\.playerArtistEDREnabled) private var edrEnabled
    @Environment(\.nowPlayingBackdropImage) private var backdrop
    @Environment(\.nowPlayingUndimmedBackdropImage) private var undimmed
    @Environment(\.nowPlayingBackdropAnchor) private var anchor
    private var usesEDR: Bool { edrEnabled && (undimmed ?? backdrop) != nil && anchor != nil && !route.isAirPlay }

    var body: some View {
        ZStack {
            ReferenceAirPlayRoutePicker(opacity: opacity, hidesGlyph: route.symbolName != nil || usesEDR)
            if usesEDR {
                PlayerEDRControlLayer(shape: .symbol(route.symbolName ?? "airplayaudio", 18, 1), role: .buttons)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } else if let symbolName = route.symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white.opacity(opacity))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// 当前音频输出是不是蓝牙。系统拿不到耳机型号（第三方耳机更是什么都没有），所以不区分型号，
/// 蓝牙输出一律用 AirPods 图标。
@MainActor @Observable
private final class ReferenceAudioOutputRoute {
    private(set) var symbolName: String?
    private(set) var isAirPlay = false
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
        let bluetooth: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let isBluetooth = outputs.contains { bluetooth.contains($0.portType) }
        isAirPlay = outputs.contains { $0.portType == .airPlay }
        let symbol = isBluetooth ? "airpods" : nil
        if symbolName != symbol { symbolName = symbol }
    }
}

private struct ReferenceAirPlayRoutePicker: UIViewRepresentable {
    let opacity: Double
    /// 用自己画的 AirPods 图标时，把系统图标藏起来，只保留点按功能。
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
