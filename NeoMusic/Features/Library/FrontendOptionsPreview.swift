#if DEBUG
import SwiftUI

/// Native design comparisons with local, memory-only examples.
struct FrontendOptionsPreview: View {
    let page: String
    @State private var candidate: Bool

    init(page: String, candidate: Bool = true) {
        self.page = page
        _candidate = State(initialValue: candidate)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("设计对照", selection: $candidate) {
                    Text("当前效果").tag(false)
                    Text("候选方案").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .accessibilityIdentifier("frontend.options.comparison")

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(page == "artists" ? .large : .inline)
            .safeAreaInset(edge: .bottom) {
                Text("隔离原生预览 · 示例状态")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.regularMaterial)
            }
        }
        .accessibilityIdentifier("frontend.options.\(page)")
    }

    @ViewBuilder private var content: some View {
        switch page {
        case "categories": OptionCategoriesPreview(candidate: candidate)
        case "artists": OptionArtistsPreview(candidate: candidate)
        case "lyrics": OptionLyricsPreview(candidate: candidate)
        case "quality": OptionPlaybackInfoPreview(candidate: candidate)
        case "editing": OptionEditingPreview(candidate: candidate)
        case "settings": OptionSettingsPreview(candidate: candidate)
        case "menus": OptionMenusPreview(candidate: candidate)
        default: OptionCategoriesPreview(candidate: candidate)
        }
    }

    private var title: String {
        switch page {
        case "artists": "艺人"
        case "lyrics": "歌词层级"
        case "quality": "正在播放"
        case "editing": "编辑播放列表"
        case "settings": candidate ? "账户与设置" : "网易云账户"
        case "menus": "播放列表菜单"
        default: "搜索分类"
        }
    }
}

private struct OptionCategory: Identifiable, Hashable {
    enum Group: Int, CaseIterable {
        case language, style, scene, emotion, theme

        var title: String {
            switch self {
            case .language: "语种"
            case .style: "风格"
            case .scene: "场景"
            case .emotion: "情感"
            case .theme: "主题"
            }
        }
    }

    let name: String
    let group: Group
    let isHot: Bool
    let colorIndex: Int
    var id: String { name }

    // A category subset with the existing catalogue's group and hot fields.
    static let samples: [Self] = [
        .init(name: "华语", group: .language, isHot: true, colorIndex: 0),
        .init(name: "流行", group: .style, isHot: true, colorIndex: 1),
        .init(name: "摇滚", group: .style, isHot: true, colorIndex: 2),
        .init(name: "民谣", group: .style, isHot: true, colorIndex: 3),
        .init(name: "电子", group: .style, isHot: true, colorIndex: 4),
        .init(name: "轻音乐", group: .style, isHot: true, colorIndex: 5),
        .init(name: "欧美", group: .language, isHot: false, colorIndex: 6),
        .init(name: "日语", group: .language, isHot: false, colorIndex: 0),
        .init(name: "古典", group: .style, isHot: false, colorIndex: 1),
        .init(name: "爵士", group: .style, isHot: false, colorIndex: 2),
        .init(name: "清晨", group: .scene, isHot: false, colorIndex: 3),
        .init(name: "夜晚", group: .scene, isHot: false, colorIndex: 4),
        .init(name: "学习", group: .scene, isHot: false, colorIndex: 5),
        .init(name: "怀旧", group: .emotion, isHot: false, colorIndex: 6),
        .init(name: "浪漫", group: .emotion, isHot: false, colorIndex: 0),
        .init(name: "影视原声", group: .theme, isHot: false, colorIndex: 1),
        .init(name: "ACG", group: .theme, isHot: false, colorIndex: 2)
    ]
}

private struct OptionCategoriesPreview: View {
    let candidate: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selected: OptionCategory?

    private var columns: [GridItem] {
        if candidate && dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if candidate {
                    categorySection("热门", items: OptionCategory.samples.filter(\.isHot))
                    ForEach(OptionCategory.Group.allCases, id: \.self) { group in
                        categorySection(group.title, items: OptionCategory.samples.filter { $0.group == group })
                    }
                } else {
                    grid(OptionCategory.samples)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .navigationDestination(item: $selected) { category in
            OptionCollectionExamples(title: category.name)
        }
    }

    private func categorySection(_ title: String, items: [OptionCategory]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            grid(items)
        }
    }

    private func grid(_ items: [OptionCategory]) -> some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(items) { item in
                Button { selected = item } label: { OptionCategoryCard(item: item) }
                    .buttonStyle(.plain)
                    .accessibilityHint("打开\(item.name)歌单")
            }
        }
    }
}

private struct OptionCategoryCard: View {
    let item: OptionCategory
    private static let colors: [Color] = [
        Color(red: 221 / 255, green: 170 / 255, blue: 0),
        Color(red: 224 / 255, green: 90 / 255, blue: 126 / 255),
        Color(red: 231 / 255, green: 81 / 255, blue: 52 / 255),
        Color(red: 202 / 255, green: 125 / 255, blue: 47 / 255),
        Color(red: 51 / 255, green: 176 / 255, blue: 112 / 255),
        Color(red: 88 / 255, green: 126 / 255, blue: 236 / 255),
        Color(red: 137 / 255, green: 104 / 255, blue: 218 / 255)
    ]

    var body: some View {
        Self.colors[item.colorIndex].aspectRatio(1.78, contentMode: .fit)
            .overlay { SearchCategorySymbol(category: item.name) }
            .overlay(alignment: .bottomLeading) {
                Text(item.name).font(.headline).foregroundStyle(.white)
                    .lineLimit(2).padding(12)
            }
            .clipShape(.rect(cornerRadius: 14))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.name)
    }
}

private struct OptionCollectionExamples: View {
    let title: String
    private let examples = ["慢慢走", "晴天的午后", "下一站", "夜色之间"]

    var body: some View {
        List {
            ForEach(examples, id: \.self) { name in
                HStack(spacing: 12) {
                    Image("AlbumSample01").resizable().scaledToFill()
                        .frame(width: 60, height: 60).clipShape(.rect(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.body)
                        Text("NeoMusic 编辑").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
    }
}

private struct OptionArtistsPreview: View {
    let candidate: Bool
    @State private var query = ""
    @State private var filter = LibraryFilter.all
    private let artists = ["RIM", "KAF", "KOKO", "Isekaijoucho"]
    private let assets = [
        "RIM": "ArtistPreviewRIM", "KAF": "ArtistPreview-kaf",
        "KOKO": "ArtistPreview-koko", "Isekaijoucho": "ArtistPreview-isekaijoucho"
    ]

    private var visibleArtists: [String] {
        artists.filter {
            (filter != .favorites || $0 == "RIM") && (!candidate || query.isEmpty || $0.localizedStandardContains(query))
        }
    }

    var body: some View {
        Group {
            if candidate {
                list.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索艺人")
            } else {
                list
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LibraryFilterMenu(filter: $filter, allTitle: "所有艺人", allImage: "music.microphone")
            }
        }
    }

    private var list: some View {
        List {
            ForEach(visibleArtists, id: \.self) { artist in
                NavigationLink {
                    OptionCollectionExamples(title: artist)
                } label: {
                    HStack(spacing: 12) {
                        Image(assets[artist] ?? "ArtistPreviewRIM").resizable().scaledToFill()
                            .frame(width: 48, height: 48).clipShape(.circle)
                            .overlay(alignment: .leading) {
                                FavoriteMark(isFavorite: artist == "RIM", color: .yellow)
                            }
                        Text(artist).font(.callout).lineLimit(1)
                    }
                    .frame(minHeight: 56)
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 60 }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay {
            if candidate && visibleArtists.isEmpty { ContentUnavailableView.search(text: query) }
        }
    }
}

private struct OptionLyricsPreview: View {
    let candidate: Bool
    @ScaledMetric(relativeTo: .title) private var originalSize = 36.0
    @ScaledMetric(relativeTo: .title3) private var translationSize = 23.0
    @State private var showsTranslation = true
    @State private var focusedLine = "morning"
    @State private var playing = false
    private let lines = [
        (id: "morning", original: "The morning finds an open window", translation: "清晨推开了一扇窗"),
        (id: "light", original: "A little light follows the rain", translation: "雨后透进一点微光"),
        (id: "road", original: "We take the road beside the river", translation: "我们沿着河边慢慢走"),
        (id: "home", original: "And carry all the quiet home", translation: "把这一刻的宁静带回家")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image("AlbumSample03").resizable().scaledToFill()
                    .frame(width: 54, height: 54).clipShape(.rect(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Window Light").font(.headline)
                    Text("NeoMusic 示例").font(.subheadline).foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 0)
                if candidate {
                    Menu {
                        Toggle("显示译文", isOn: $showsTranslation)
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("歌词选项")
                }
            }
            .padding(20)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(lines, id: \.id) { line in
                        Button { focusedLine = line.id } label: {
                            VStack(alignment: .leading, spacing: candidate ? 8 : 0) {
                                Text(line.original).font(.system(size: originalSize, weight: .bold))
                                if !candidate || showsTranslation {
                                    Text(line.translation)
                                        .font(.system(size: candidate ? translationSize : originalSize,
                                                      weight: candidate ? .semibold : .bold))
                                        .foregroundStyle(.white.opacity(candidate ? 0.76 : 1))
                                }
                            }
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .opacity(focusedLine == line.id ? 1 : 0.45)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(focusedLine == line.id ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }

            Button { playing.toggle() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 30)).frame(width: 64, height: 64)
            }
            .accessibilityLabel(playing ? "暂停示例" : "播放示例")
            .padding(.bottom, 12)
        }
        .foregroundStyle(.white)
        .background(Color(red: 0.32, green: 0.25, blue: 0.21))
    }
}

private struct OptionPlaybackInfoPreview: View {
    let candidate: Bool
    @State private var playing = false
    @State private var showsQuality = false
    @State private var actionResult = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image("AlbumSample17").resizable().scaledToFit()
                    .frame(maxWidth: 300).clipShape(.rect(cornerRadius: 10))
                    .padding(.top, 16)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Window Light").font(.title3.bold())
                        Text("NeoMusic 示例").font(.title3).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Button("喜爱", systemImage: "star") { actionResult = "已喜爱" }
                        Button("添加到播放列表", systemImage: "text.badge.plus") { actionResult = "已添加到示例播放列表" }
                        if candidate {
                            Section {
                                Text("当前音质 · 无损")
                                Button("音质设置", systemImage: "waveform") { showsQuality = true }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("歌曲菜单")
                }
                HStack(spacing: 30) {
                    Image(systemName: "backward.fill").font(.title)
                    Button { playing.toggle() } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 42)).frame(width: 64, height: 64)
                    }
                    .accessibilityLabel(playing ? "暂停示例" : "播放示例")
                    Image(systemName: "forward.fill").font(.title)
                }
                .padding(.vertical, 8)
                if candidate {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("随后播放", systemImage: "text.line.first.and.arrowtriangle.forward")
                            .font(.headline)
                        HStack(spacing: 12) {
                            Image(systemName: "infinity").foregroundStyle(.secondary)
                                .frame(width: 44, height: 38)
                                .background(.quaternary, in: .capsule)
                                .accessibilityLabel("推荐自动续播，暂不可用")
                            Text("推荐自动续播暂不可用")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Image(systemName: "infinity").foregroundStyle(.secondary)
                        .frame(width: 44, height: 38).background(.quaternary, in: .capsule)
                    Button("前往账户音质设置") { showsQuality = true }
                        .font(.footnote)
                }
                if !actionResult.isEmpty {
                    Text(actionResult).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $showsQuality) {
            NavigationStack {
                OptionQualitySettings()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showsQuality = false }
                        }
                    }
            }
        }
    }
}

private struct OptionQualitySettings: View {
    private enum Quality: String, CaseIterable {
        case standard = "标准", high = "高品质", lossless = "无损", hiRes = "Hi-Res"
    }
    private enum Resource: String, CaseIterable {
        case available = "无损可用", limited = "权限限制", offline = "离线副本"
        var quality: String { self == .limited ? "高品质" : "无损" }
    }
    @State private var wifi = Quality.lossless
    @State private var cellular = Quality.high
    @State private var resource = Resource.available

    var body: some View {
        Form {
            Section("流播放音质") {
                Picker("Wi-Fi 播放", selection: $wifi) {
                    ForEach(Quality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("蜂窝网络播放", selection: $cellular) {
                    ForEach(Quality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            Section {
                LabeledContent("当前音质", value: resource.quality)
            } footer: {
                Text(resource == .limited ? "本曲使用当前权限下可用的高品质资源。" : "实际音质来自本曲播放资源。")
            }
            Section("资源示例") {
                Picker("本曲资源", selection: $resource) {
                    ForEach(Resource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
        }
        .navigationTitle("音质")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct OptionEditingPreview: View {
    let candidate: Bool
    @State private var name = "通勤"
    @State private var description = "路上的一段音乐时间"
    @State private var cover: String? = "AlbumSample02"
    @State private var savedCover: String? = "AlbumSample02"
    @State private var savedName = "通勤"
    @State private var savedDescription = "路上的一段音乐时间"
    @State private var showsCoverPicker = false
    @State private var confirmsDeletion = false
    @State private var deleted = false
    @State private var saved = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(cover ?? "AlbumSample01").resizable().scaledToFill()
                    .frame(width: 180, height: 180)
                    .clipShape(.rect(cornerRadius: 6))
                    .overlay {
                        Menu {
                            Button("拍照", systemImage: "camera") { showsCoverPicker = true }
                            Button("选取照片", systemImage: "photo.on.rectangle") { showsCoverPicker = true }
                            Button("选取文件", systemImage: "folder") { showsCoverPicker = true }
                            if candidate && cover != nil {
                                Section {
                                    Button("恢复默认封面", systemImage: "arrow.counterclockwise") {
                                        cover = nil
                                        saved = false
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "photo").font(.system(size: 25, weight: .medium))
                                .foregroundStyle(.white).frame(width: 64, height: 64)
                                .background(.black, in: .circle)
                        }
                        .accessibilityLabel("更改播放列表封面")
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 58 + 2.0 / 3)
                TextField("播放列表标题", text: $name)
                    .font(.system(size: 20, weight: .semibold)).multilineTextAlignment(.center)
                    .frame(minHeight: 44)
                    .accessibilityLabel("播放列表标题")
                Divider()
                TextEditor(text: $description)
                    .font(.system(size: 15)).frame(height: 58)
                    .accessibilityLabel("播放列表描述")
                Divider()
                Toggle("在个人资料页和搜索中显示", isOn: .constant(false))
                    .font(.subheadline).tint(.green).frame(minHeight: 40).disabled(true)
                Text("本地播放列表暂不支持公开显示。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider().padding(.top, 10)

                VStack(alignment: .leading, spacing: 18) {
                    if candidate && cover == nil {
                        Text("默认封面使用第一首歌曲的封面。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("保存示例更改") {
                        savedCover = cover
                        savedName = name
                        savedDescription = description
                        saved = true
                    }
                    Button("放弃示例更改") {
                        cover = savedCover
                        name = savedName
                        description = savedDescription
                        saved = false
                    }
                    Button("删除播放列表", role: .destructive) { confirmsDeletion = true }
                        .disabled(deleted)
                    if deleted { Text("已删除示例播放列表。").font(.footnote).foregroundStyle(.secondary) }
                    else if saved { Text("示例更改已保存。").font(.footnote).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 24)
            }
            .padding(.horizontal, 20)
        }
        .alert("", isPresented: $confirmsDeletion) {
            Button("删除播放列表", role: .destructive) { deleted = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text(candidate ? "确定要删除“\(name)”播放列表吗？这会将播放列表从资料库删除，歌曲文件会保留。" : "确定要删除此播放列表吗？这会将播放列表从资料库删除。")
        }
        .sheet(isPresented: $showsCoverPicker) {
            NavigationStack {
                List {
                    ForEach(["AlbumSample01", "AlbumSample02", "AlbumSample03"], id: \.self) { asset in
                        Button {
                            cover = asset
                            saved = false
                            showsCoverPicker = false
                        } label: {
                            Image(asset).resizable().scaledToFit().frame(height: 120)
                                .frame(maxWidth: .infinity)
                        }
                        .accessibilityLabel("选用\(asset)封面")
                    }
                }
                .navigationTitle("选择示例封面")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showsCoverPicker = false }
                    }
                }
            }
        }
    }
}

private struct OptionSettingsPreview: View {
    let candidate: Bool

    var body: some View {
        List {
            Section {
                NavigationLink {
                    Form {
                        LabeledContent("昵称", value: "NeoMusic")
                        LabeledContent("网易云 ID", value: "123456789")
                    }
                    .navigationTitle("账户信息")
                } label: {
                    HStack(spacing: 12) {
                        Image("AccountBrandIcon").resizable().scaledToFit()
                            .frame(width: 55, height: 55).clipShape(.circle)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("NeoMusic").font(.body.weight(.semibold))
                            Text("账户信息与登录设置").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 85)
                }
            } header: {
                if candidate { Text("网易云音乐") }
            }
            Section {
                NavigationLink("音质") { OptionQualitySettings() }
            }
            Section {
                NavigationLink(candidate ? "标签栏" : "标签页") { OptionTabSettingsPreview() }
            } header: {
                if candidate { Text("应用") }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct OptionTabSettingsPreview: View {
    @State private var tabs = ["主页", "资料库"]
    @State private var showsFavorites = false

    var body: some View {
        List {
            Section {
                ForEach(tabs, id: \.self) { Text($0) }
                    .onMove { indices, destination in tabs.move(fromOffsets: indices, toOffset: destination) }
                Text("搜索").foregroundStyle(.secondary).moveDisabled(true)
            } header: {
                Text("显示的标签")
            } footer: {
                Text("搜索固定在末尾。")
            }
            Section {
                Toggle("喜爱歌曲", isOn: $showsFavorites)
                    .onChange(of: showsFavorites) { _, shown in
                        if shown { tabs.append("喜爱歌曲") }
                        else { tabs.removeAll { $0 == "喜爱歌曲" } }
                    }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("标签栏")
    }
}

private struct OptionMenusPreview: View {
    let candidate: Bool
    @State private var favorite = false
    @State private var pinned = false
    @State private var result = ""

    private var actions: CollectionMenuActions {
        CollectionMenuActions(
            play: { _, shuffled in result = shuffled ? "随机播放示例" : "播放示例" },
            playNext: { _ in result = "下个播放" },
            playLater: { _ in result = "已添加到队列" },
            toggleFavorite: { _ in favorite.toggle() },
            togglePin: { _ in pinned.toggle() },
            addToPlaylist: { _ in result = "已添加到示例播放列表" },
            requestMove: { _ in result = "已移到示例文件夹" },
            canDelete: { _ in true },
            edit: { _ in result = "编辑示例播放列表" },
            requestDelete: { _ in result = "已选择删除示例" },
            download: { _ in result = "已选择示例下载" },
            canDownload: { _ in true }
        )
    }

    private var item: LibraryShelfItem {
        LibraryShelfItem(id: "preview-playlist", title: "通勤", artwork: .image(Image("AlbumSample02")),
                         route: .playlist("preview-playlist"), isFavorite: favorite, isPinned: pinned)
    }

    private var sections: LibraryMenuSections {
        let current = actions.sections(for: item, route: .playlist("preview-playlist"))
        guard candidate else { return current }
        return current.compactMap { section in
            let available = section.filter { !$0.isDisabled }
            return available.isEmpty ? nil : available
        }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image("AlbumSample02").resizable().scaledToFill()
                        .frame(width: 80, height: 80).clipShape(.rect(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("通勤").font(.title3.bold())
                        Text("NeoMusic").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu { LibraryMenuContents(sections: sections) } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("通勤，更多")
                }
                .padding(.vertical, 8)
                .contextMenu { LibraryMenuContents(sections: sections) }
            } footer: {
                Text("点省略号或长按封面查看系统菜单。")
            }
            Section("菜单内容") {
                ForEach(sections.flatMap { $0 }) { entry in
                    Label(entry.title, systemImage: entry.systemImage)
                        .foregroundStyle(entry.isDisabled ? Color.secondary : Color.primary)
                        .padding(.vertical, 3)
                }
            }
            if !result.isEmpty {
                Section { Text(result).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .listStyle(.insetGrouped)
    }
}

#Preview("分类组织") { FrontendOptionsPreview(page: "categories") }
#Preview("歌词层级") { FrontendOptionsPreview(page: "lyrics") }
#Preview("封面与确认") { FrontendOptionsPreview(page: "editing") }
#Preview("设置分组") { FrontendOptionsPreview(page: "settings") }
#endif
