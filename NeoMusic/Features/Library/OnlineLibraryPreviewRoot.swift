#if DEBUG
import SwiftUI

/// New settings only; existing library and player pages use OnlineLibraryShellPreview.
struct OnlineLibraryPreviewRoot: View {
    @State private var wifiQuality = "无损"
    @State private var cellularQuality = "高品质"
    private let qualities = ["标准", "高品质", "无损", "Hi-Res"]

    var body: some View {
        NavigationStack { qualityPage }
            .tint(.primary)
    }

    private var qualityPage: some View {
        Form {
            Section {
                qualityPicker("Wi-Fi 播放", selection: $wifiQuality)
                qualityPicker("蜂窝网络播放", selection: $cellularQuality)
            } header: { Text("流播放音质") } footer: {
                Text("更高音质会使用更多流量。更改设置或切换网络后，将立即切换当前歌曲的音质并保留播放进度。")
            }
            Section {
                LabeledContent("当前音质", value: "无损")
            } footer: {
                Text("实际音质取决于歌曲和账号权限。所选音质不可用时，使用可用的较低音质；仅提供试听的歌曲会停止播放并提示。")
            }
        }.navigationTitle("音质").navigationBarTitleDisplayMode(.inline)
    }

    private func qualityPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(selection: selection) {
            ForEach(qualities, id: \.self) { Text($0) }
        } label: { Text(title) }
        .pickerStyle(.navigationLink)
    }

}

#Preview("在线音质") { OnlineLibraryPreviewRoot() }
#endif
