import SwiftUI
import AVKit
import CoreBluetooth

struct ReferenceAirPlayButton: View {
    var opacity: Double = 0.72
    @State private var route = ReferenceAudioOutputRoute()

    var body: some View {
        ReferenceAirPlayRoutePicker(opacity: route.symbol == nil ? opacity : 0)
            .scaleEffect(1.12)
            .overlay {
                if let symbol = route.symbol {
                    Image(systemName: symbol)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 70.0 / 3, height: 53.0 / 3)
                        .foregroundStyle(.white.opacity(opacity))
                        .allowsHitTesting(false)
                }
            }
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

enum HeadphoneModelSymbol {
    static func symbol(for model: String) -> String? {
        switch model.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "A1523", "A1722", "A2032", "A2031": return "airpods"
        case "A2565", "A2564", "A3053", "A3050", "A3054", "A3056", "A3055", "A3057",
             "A3439", "A3440", "A3441", "A3531", "A3532", "A3533": return "airpods.gen3"
        case "A2084", "A2083", "A2931", "A2699", "A2698", "A3047", "A3048", "A3049",
             "A3063", "A3064", "A3065": return "airpodspro"
        case "A2096", "A3184", "A3454": return "airpodsmax"
        default: return nil
        }
    }
}

@MainActor @Observable
private final class ReferenceAudioOutputRoute: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private(set) var output = ReferenceAudioOutput(outputs: [])
    private(set) var symbol: String?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var routeID = ""
    @ObservationIgnored private var bluetoothName: String?
    @ObservationIgnored private var symbols: [UUID: String] = [:]
    @ObservationIgnored private var candidates: [CBPeripheral] = []
    @ObservationIgnored private var resolvedSymbols = Set<String>()
    private let informationService = CBUUID(string: "180A")
    private let modelCharacteristic = CBUUID(string: "2A24")

    override init() {
        super.init()
        for name in [AVAudioSession.routeChangeNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        timeout?.cancel()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
    }

    func refresh() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        output = ReferenceAudioOutput(outputs: outputs.map { ($0.portType, $0.portName) })
        let newID = outputs.map { $0.uid }.joined(separator: "|")
        let bluetooth = outputs.count == 1 && [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains(outputs[0].portType)
        if newID != routeID {
            endRead()
            routeID = newID
            symbol = bluetooth || outputs.contains(where: { $0.portType == .headphones }) ? "headphones" : nil
        }
        bluetoothName = bluetooth ? outputs[0].portName : nil
        guard bluetoothName != nil else { return }
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else { identify() }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { identify() }
        else {
            endRead()
            if bluetoothName != nil { symbol = "headphones" }
        }
    }

    private func identify() {
        guard let central, central.state == .poweredOn, let bluetoothName, peripheral == nil else { return }
        candidates = central.retrieveConnectedPeripherals(withServices: [informationService])
            .filter { $0.name == bluetoothName }
        resolvedSymbols.removeAll()
        guard !candidates.isEmpty else { symbol = "headphones"; return }
        readNext()
    }

    private func readNext() {
        guard let candidate = candidates.first else {
            symbol = resolvedSymbols.count == 1 ? resolvedSymbols.first : "headphones"
            return
        }
        candidates.removeFirst()
        if let cached = symbols[candidate.identifier] {
            resolvedSymbols.insert(cached)
            readNext()
            return
        }
        peripheral = candidate
        candidate.delegate = self
        central?.connect(candidate)
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.completeRead(symbol: nil)
        }
    }

    private func completeRead(symbol: String?) {
        if let symbol { resolvedSymbols.insert(symbol) }
        releasePeripheral()
        readNext()
    }

    private func isCurrent(_ candidate: CBPeripheral) -> Bool {
        peripheral === candidate && AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.uid }.joined(separator: "|") == routeID
    }

    private func endRead() {
        candidates.removeAll()
        resolvedSymbols.removeAll()
        releasePeripheral()
    }

    private func releasePeripheral() {
        timeout?.cancel()
        timeout = nil
        if let peripheral {
            peripheral.delegate = nil
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard isCurrent(peripheral) else { return }
        peripheral.discoverServices([informationService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if isCurrent(peripheral) { completeRead(symbol: nil) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isCurrent(peripheral) else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == informationService }) else { completeRead(symbol: nil); return }
        peripheral.discoverCharacteristics([modelCharacteristic], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isCurrent(peripheral) else { return }
        guard error == nil, let field = service.characteristics?.first(where: { $0.uuid == modelCharacteristic && $0.properties.contains(.read) }) else { completeRead(symbol: nil); return }
        peripheral.readValue(for: field)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(peripheral), characteristic.uuid == modelCharacteristic else { return }
        if error == nil, let data = characteristic.value, let model = String(data: data, encoding: .utf8), !model.isEmpty {
            let resolved = HeadphoneModelSymbol.symbol(for: model) ?? "headphones"
            symbols[peripheral.identifier] = resolved
            completeRead(symbol: resolved)
        } else {
            completeRead(symbol: nil)
        }
    }
}

private struct ReferenceAirPlayRoutePicker: UIViewRepresentable {
    let opacity: Double

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {
        picker.tintColor = UIColor.white.withAlphaComponent(opacity)
        picker.activeTintColor = UIColor.white.withAlphaComponent(opacity)
    }
}
