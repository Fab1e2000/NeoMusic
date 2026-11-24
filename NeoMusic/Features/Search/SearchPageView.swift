import SwiftUI

struct SearchPageView: View {
    @Bindable var model: SearchPageModel
    @Environment(\.openLibraryRoute) private var openRoute
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var mountedResultKinds: Set<MusicSearchKind> = [.combined]
    var body: some View {
        Group {
            if !model.isSearching && !model.submitted { browse }
            else if model.query.isEmpty { recent }
            else if !model.submitted { suggestions }
            else { results }
        }
        .background(Color(.systemBackground))
        .librarySearchPage(model)
        .libraryNavigationTitle("搜索")
        .libraryHomeNavigation(title: "搜索")
        .toolbarTitleDisplayMode(.inlineLarge)
    }

    private var browse: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if !model.history.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("最近搜索").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                            Spacer()
                            Button {
                                model.onRemoveHistory?(nil)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清除最近搜索")
                        }
                        SearchFlowLayout(horizontalSpacing: 10, verticalSpacing: 10,
                                         wrapsOversizedItems: dynamicTypeSize.isAccessibilitySize) {
                            ForEach(model.history, id: \.self) { value in
                                Button {
                                    model.submit(value)
                                } label: {
                                    SearchTagChip(title: value)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .accessibilityIdentifier("search.browse.history")
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.pageMargin).padding(.top, 8).padding(.bottom, 24)
        }
        .overlay {
            if model.history.isEmpty {
                ContentUnavailableView { Text("无最近搜索") } description: { Text("最近搜索内容将在此处显示。") }
            }
        }
    }

    private var recent: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView { Text("无最近搜索") } description: { Text("最近搜索内容将在此处显示。") }
            } else {
                List {
                    Section {
                        ForEach(model.history, id: \.self) { value in
                            HStack(spacing: 14) {
                                Button { model.submit(value) } label: {
                                    Label(value, systemImage: "clock")
                                        .frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? 44 : 32, alignment: .leading)
                                        .contentShape(.rect)
                                }.buttonStyle(.plain)
                                Button { model.onRemoveHistory?(value) } label: {
                                    Image(systemName: "xmark")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 44, height: 44)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, -8)
                                .padding(.trailing, -12)
                                .accessibilityLabel("移除\(value)")
                            }.padding(.vertical, 6)
                        }
                    } header: {
                        HStack {
                            Text("最近搜索").font(.title3.bold())
                            Spacer()
                            Button { model.onRemoveHistory?(nil) } label: {
                                Text("清除")
                                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                                    .contentShape(.rect)
                            }
                            .padding(.vertical, -10)
                        }
                            .textCase(nil)
                    }
                }.listStyle(.plain)
            }
        }
    }

    private var suggestions: some View {
        List {
            ForEach(model.keywords, id: \.self) { word in
                Button { model.submit(word) } label: {
                    Label(word, systemImage: "magnifyingglass")
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 7)
                        .contentShape(.rect)
                }.buttonStyle(.plain)
            }
            ForEach(model.suggestions) { item in SearchResultRow(item: item, model: model) }
            if let error = model.error { SearchInlineError(message: error) { model.onRetry?() } }
        }
        .listStyle(.plain).scrollDismissesKeyboard(.interactively)
        .overlay { if model.isLoading && model.keywords.isEmpty && model.suggestions.isEmpty { ProgressView() } }
    }

    private var results: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(MusicSearchKind.allCases) { kind in
                        Button { model.select(kind) } label: {
                            Text(kind.title).font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .foregroundStyle(model.kind == kind ? Color.white : Color.primary)
                                .background(model.kind == kind ? Color.accentColor : .clear, in: .capsule)
                        }.buttonStyle(.plain).accessibilityAddTraits(model.kind == kind ? [.isSelected] : [])
                    }
                }.padding(.horizontal, DesignTokens.Spacing.pageMargin).padding(.vertical, 8)
            }.scrollIndicators(.hidden)
            Divider()
            ZStack {
                ForEach(MusicSearchKind.allCases) { kind in
                    if kind == model.kind || mountedResultKinds.contains(kind) {
                        let active = kind == model.kind
                        SearchResultList(
                            kind: kind,
                            groups: active ? model.groups : (model.cachedGroups[kind] ?? []),
                            active: active,
                            error: active ? model.error : nil,
                            moreError: active ? model.moreError : nil,
                            hasMore: active && model.hasMore,
                            isLoading: active && model.isLoading,
                            query: active ? model.query : "",
                            submitted: active && model.submitted,
                            model: model
                        )
                        .equatable()
                        .opacity(active ? 1 : 0)
                        .allowsHitTesting(active)
                        .accessibilityHidden(!active)
                    }
                }
            }
            .onChange(of: model.kind, initial: true) { _, nextKind in
                mountedResultKinds.insert(nextKind)
            }
            .onChange(of: model.query) { _, _ in
                mountedResultKinds = [model.kind]
            }
            .onChange(of: model.submitted) { _, submitted in
                if !submitted { mountedResultKinds = [model.kind] }
            }
        }
    }

    @ViewBuilder private var availability: some View {
        if model.isLoading { ProgressView() }
        else if let error = model.error {
            ContentUnavailableView { Label("暂时无法加载", systemImage: "wifi.exclamationmark") }
                description: { Text(error) } actions: { Button("重试") { model.onRetry?() } }
        } else if model.submitted { ContentUnavailableView.search(text: model.query) }
    }
}

private struct SearchResultList: View {
    let kind: MusicSearchKind
    let groups: [MusicSearchGroup]
    let active: Bool
    let error: String?
    let moreError: String?
    let hasMore: Bool
    let isLoading: Bool
    let query: String
    let submitted: Bool
    let model: SearchPageModel

    var body: some View {
        List {
            ForEach(groups) { group in
                if kind == .combined {
                    Section {
                        ForEach(Array(group.items.prefix(3))) { item in row(item) }
                    } header: {
                        HStack {
                            Text(group.kind.title).font(.title3.bold()).foregroundStyle(Color.primary)
                            Spacer()
                            if group.hasMore || group.items.count > 3 {
                                Button { model.select(group.kind) } label: {
                                    Text("查看全部")
                                        .font(.subheadline)
                                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                                        .contentShape(.rect)
                                }
                                .padding(.vertical, -10)
                                .accessibilityLabel("查看全部\(group.kind.title)")
                            }
                        }.textCase(nil).padding(.top, 8)
                    }
                } else { ForEach(group.items) { item in row(item) } }
            }
            if active, let error, !groups.isEmpty { SearchInlineError(message: error) { model.onRetry?() } }
            if active, let moreError { SearchInlineError(message: moreError) { model.onMore?() } }
            else if active, hasMore {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
                    .onAppear { model.onMore?() }
            }
        }
        .listStyle(.plain).scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("search.results.\(kind.rawValue)")
        .overlay { if active, groups.allSatisfy({ $0.items.isEmpty }) { availability } }
        .refreshable { if active { await model.onRefresh?() } }
    }

    @ViewBuilder private func row(_ item: MusicSearchItem) -> some View {
        let base = SearchResultRow(item: item, model: model)
            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 68 }
        if let song = item.song {
            base.songListRow(song, mode: .standard(), swipeBackground: Color(.systemBackground))
        } else {
            base
        }
    }

    @ViewBuilder private var availability: some View {
        if isLoading { ProgressView() }
        else if let error {
            ContentUnavailableView { Label("暂时无法加载", systemImage: "wifi.exclamationmark") }
                description: { Text(error) } actions: { Button("重试") { model.onRetry?() } }
        } else if submitted { ContentUnavailableView.search(text: query) }
    }
}

extension SearchResultList: @MainActor Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.groups == rhs.groups && lhs.active == rhs.active
            && lhs.error == rhs.error && lhs.moreError == rhs.moreError && lhs.hasMore == rhs.hasMore
            && lhs.isLoading == rhs.isLoading && lhs.query == rhs.query && lhs.submitted == rhs.submitted
    }
}

private struct SearchTagChip: View {
    let title: String
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        Text(title)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: textSize.isAccessibilitySize ? 44 : nil)
            .background(Color(.secondarySystemFill), in: Capsule())
            .lineLimit(textSize.isAccessibilitySize ? nil : 1)
    }
}

private struct SearchFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8
    var wrapsOversizedItems = false

    private func size(of subview: LayoutSubview, fitting width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard wrapsOversizedItems, ideal.width > width else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = size(of: subview, fitting: maxWidth)
            if currentX > 0 && currentX + size.width > maxWidth {
                currentX = 0
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            currentX += size.width + horizontalSpacing
            totalWidth = max(totalWidth, currentX - horizontalSpacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? totalWidth, height: currentY + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = size(of: subview, fitting: bounds.width)
            if currentX > bounds.minX && currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct SearchResultRow: View {
    @Environment(\.dynamicTypeSize) private var textSize
    let item: MusicSearchItem
    let model: SearchPageModel
    @State private var sources = LibraryArtworkSources()
    @Environment(\.openLibraryRoute) private var openRoute
    var body: some View {
        if let song = item.song {
            SharedSongRow(
                song: song,
                subtitle: item.subtitle,
                appearance: SongRowAppearance(
                    titleFont: .body,
                    subtitleFont: .subheadline,
                    titleLineLimit: 2,
                    subtitleLineLimit: 1,
                    moreColor: .secondary,
                    moreTrailingPadding: -8,
                    minHeight: 60,
                    usesPlainButtonStyle: true
                ),
                moreAccessibilityLabel: "\(item.title)，更多",
                playButtonAccessibilityIdentifier: "search.result.\(item.id)",
                play: open
            ) {
                LibraryCardArtwork(
                    content: AnyView(ResourceArtworkView(resource: item.$artwork, contentID: item.id, cornerRadius: 0)),
                    sources: sources,
                    sourceID: item.id,
                    cornerRadius: DesignTokens.Radius.songRowCover
                )
                .songPlaybackOverlay(songID: song.id, cornerRadius: DesignTokens.Radius.songRowCover)
                .frame(width: 56, height: 56)
            }
        } else {
            HStack(spacing: 12) {
                Button { open() } label: {
                    HStack(spacing: 12) {
                        LibraryCardArtwork(content: AnyView(ResourceArtworkView(resource: item.$artwork, contentID: item.id, cornerRadius: 0)),
                            sources: sources, sourceID: item.id, cornerRadius: item.kind == .artist ? 28 : 5)
                            .frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.body).foregroundStyle(.primary).lineLimit(textSize.isAccessibilitySize ? nil : 2)
                            Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(textSize.isAccessibilitySize ? nil : 1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(.rect)
                }.buttonStyle(.plain).accessibilityIdentifier("search.result.\(item.id)")
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }.frame(minHeight: 60)
        }
    }
    private func open() {
        guard let route = item.route else { model.onOpen?(item); return }
        let preview = item.preview(ownerID: model.ownerID, route: route)
        model.onPrepareNavigation?(preview)
        openRoute(route, preview: preview, sourceProvider: { [sources, id = item.id] in sources.view(for: id) })
    }
}

struct SearchCategoryPage: View {
    @Bindable var model: SearchPageModel
    let category: String
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        SearchCategoryContent(model: model, category: category,
                              columns: Array(repeating: GridItem(.flexible(), spacing: 16),
                                             count: textSize.isAccessibilitySize ? 1 : 2),
                              titleLineLimit: textSize.isAccessibilitySize ? nil : 2,
                              subtitleLineLimit: textSize.isAccessibilitySize ? nil : 1)
    }
}

struct SearchCategoryContent: View {
    @Bindable var model: SearchPageModel
    let category: String
    let columns: [GridItem]
    let titleLineLimit: Int?
    let subtitleLineLimit: Int?
    @State private var sources = LibraryArtworkSources()
    @Environment(\.openLibraryRoute) private var openRoute
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(model.categoryItems) { item in
                    Button {
                        guard let route = item.route else { return }
                        let preview = item.preview(ownerID: model.ownerID, route: route)
                        model.onPrepareNavigation?(preview)
                        openRoute(route, preview: preview, sourceProvider: { [sources, id = item.id] in sources.view(for: id) })
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            LibraryCardArtwork(content: AnyView(ResourceArtworkView(resource: item.$artwork, contentID: item.id, cornerRadius: 0)),
                                sources: sources, sourceID: item.id, cornerRadius: DesignTokens.Radius.card).aspectRatio(1, contentMode: .fit)
                            Text(item.title).font(.subheadline).lineLimit(titleLineLimit).foregroundStyle(.primary)
                            Text(item.subtitle).font(.caption).lineLimit(subtitleLineLimit).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
            }.padding(DesignTokens.Spacing.pageMargin)
            if let error = model.categoryError, !model.categoryItems.isEmpty {
                SearchInlineError(message: error) { Task { await model.onCategoryRefresh?() } }.padding(DesignTokens.Spacing.pageMargin)
            }
            if let error = model.categoryMoreError {
                SearchInlineError(message: error) { model.onCategoryMore?() }.padding(DesignTokens.Spacing.pageMargin)
            } else if model.categoryHasMore {
                ProgressView().padding().onAppear { model.onCategoryMore?() }
            }
        }
        .overlay {
            if model.categoryItems.isEmpty {
                if model.categoryLoading { ProgressView() }
                else if let error = model.categoryError {
                    ContentUnavailableView { Label("暂时无法加载", systemImage: "wifi.exclamationmark") }
                        description: { Text(error) } actions: { Button("重试") { Task { await model.onCategoryRefresh?() } } }
                } else { ContentUnavailableView("暂无歌单", systemImage: "music.note.list") }
            }
        }
        .refreshable { await model.onCategoryRefresh?() }
        .libraryNavigationTitle(category).libraryTitleDisplayMode(.large)
    }
}

private struct SearchInlineError: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        HStack {
            Text(message).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button(action: retry) {
                Text("重试")
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(.rect)
            }
            .padding(.vertical, -8)
        }
    }
}

private extension MusicSearchItem {
    @MainActor func preview(ownerID: String?, route: LibraryRoute) -> LibraryNavigationPreview {
        var cover = artwork
        if case .file(let url) = cover, let image = LocalArtworkImages.cached(url, pixels: 0) { cover = .image(Image(uiImage: image)) }
        return .init(route: route, ownerID: ownerID, title: title, subtitle: subtitle, artwork: cover,
                     originalArtwork: artwork)
    }
}
