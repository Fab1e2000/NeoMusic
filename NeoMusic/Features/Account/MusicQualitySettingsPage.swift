import SwiftUI

struct MusicQualitySettingsPage: View {
    @Bindable var music: NeteaseMusicStore
    var downloads: NeteaseDownloadStore? = nil
    @Environment(\.songRowPlayback) private var playback

    var body: some View {
        Form {
            Section {
                qualityPicker("Wi-Fi 播放", selection: $music.wifiQuality)
                    .accessibilityIdentifier("quality.wifi")
                qualityPicker("蜂窝网络播放", selection: $music.cellularQuality)
                    .accessibilityIdentifier("quality.cellular")
            } header: {
                Text("流播放音质")
            } footer: {
                Text("更高音质会使用更多流量。更改设置或切换网络后，将立即切换当前歌曲的音质并保留播放进度。")
            }
            if let downloads { DownloadQualitySection(downloads: downloads) }
            Section {
                LabeledContent("当前音质", value: actualQuality)
                    .accessibilityIdentifier("quality.actual")
            } footer: {
                Text("实际音质取决于歌曲和账号权限。所选音质不可用时，使用可用的较低音质；仅提供试听的歌曲会停止播放并提示。")
            }
        }
        .navigationTitle("音质")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("quality.page")
    }

    private var actualQuality: String {
        guard let value = playback?.actualQuality else { return "未在播放在线歌曲" }
        return NeteaseMusicQuality(rawValue: value)?.title ?? value
    }

    private func qualityPicker(_ title: String, selection: Binding<NeteaseMusicQuality>) -> some View {
        Picker(selection: selection) {
            ForEach(NeteaseMusicQuality.allCases, id: \.self) { quality in
                Text(quality.title).tag(quality)
            }
        } label: { Text(title) }
        .pickerStyle(.navigationLink)
    }
}

private struct DownloadQualitySection: View {
    @Bindable var downloads: NeteaseDownloadStore
    var body: some View {
        Section {
            Picker(selection: $downloads.quality) {
                ForEach(NeteaseMusicQuality.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { Text("下载音质") }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier("quality.download")
            Toggle("允许蜂窝网络下载", isOn: $downloads.allowsCellular)
                .accessibilityIdentifier("quality.download.cellular")
        } header: {
            Text("下载")
        } footer: {
            Text("更高音质会占用更多空间和流量。所选音质不可用时使用可用的较低音质。更改音质仅影响新的下载，已下载文件保持原样。")
        }
    }
}
