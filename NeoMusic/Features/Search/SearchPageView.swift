import SwiftUI

struct SearchPageView: View {
    @Bindable var model: SearchPageModel
    @Environment(\.openLibraryRoute) private var openRoute
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
        .environment(\.artworkLoadAction, ArtworkLoadAction(handler: { model.onArtwork?($0) }))
    }

    private var browse: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(MusicSearchCategorySection.sections(for: model.categories)) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        if let title = section.title {
                            Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                        }
                        LazyVGrid(columns: categoryColumns, spacing: 12) {
                            ForEach(section.items) { item in
                                Button {
                                    model.onCategory?(item.id)
                                    openRoute(.playlistFolder("search-category:" + item.id))
                                } label: {
                                    SearchCategoryCard(item: item)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("打开\(item.title)歌单")
                            }
                        }
                    }
                    .accessibilityIdentifier("search.categories.\(section.id)")
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
            if let error = model.error, !model.categories.isEmpty {
                SearchInlineError(message: error) { model.onRetry?() }.padding(.horizontal, 20)
            }
        }
        .overlay { if model.categories.isEmpty { availability } }
        .refreshable { await model.onRefresh?() }
    }

    private var categoryColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize { return [GridItem(.flexible())] }
        return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
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
                                    Label(value, systemImage: "clock").frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                Button { model.onRemoveHistory?(value) } label: { Image(systemName: "xmark").foregroundStyle(.secondary) }
                                    .buttonStyle(.plain).accessibilityLabel("移除\(value)")
                            }.padding(.vertical, 6)
                        }
                    } header: {
                        HStack { Text("最近搜索").font(.title3.bold()); Spacer(); Button("清除") { model.onRemoveHistory?(nil) } }
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
                    Label(word, systemImage: "magnifyingglass").foregroundStyle(.primary).padding(.vertical, 7)
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
                }.padding(.horizontal, 20).padding(.vertical, 8)
            }.scrollIndicators(.hidden)
            Divider()
            if let status = model.syncStatus, model.scope == .library {
                HStack(spacing: 8) {
                    if !model.syncFailed { ProgressView().controlSize(.mini) }
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if model.syncFailed { Button("重试") { model.onRetry?() }.font(.footnote) }
                }.padding(.horizontal, 20).padding(.vertical, 9)
            }
            ZStack {
                ForEach(MusicSearchKind.allCases) { kind in
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
    }

    @ViewBuilder private var availability: some View {
        if model.isLoading { ProgressView() }
        else if let error = model.error {
            ContentUnavailableView { Label("暂时无法加载", systemImage: "wifi.exclamationmark") }
                description: { Text(error) } actions: { Button("重试") { model.onRetry?() } }
        } else if model.submitted { ContentUnavailableView.search(text: model.query) }
    }
}

/// One list per search kind. Equality skips rebuilding the hidden lists when only the selected kind changes.
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
                                Button("查看全部") { model.select(group.kind) }.font(.subheadline)
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

    private func row(_ item: MusicSearchItem) -> some View {
        SearchResultRow(item: item, model: model)
            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 68 }
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

private struct SearchCategoryCard: View {
    let item: MusicSearchCategory
    private var palette: SearchCategoryColor { SearchCategoryColor.palette[item.colorIndex % SearchCategoryColor.palette.count] }

    var body: some View {
        palette.background.aspectRatio(1.78, contentMode: .fit)
            .overlay { SearchCategorySymbol(category: item.title) }
            .overlay(alignment: .bottomLeading) {
                Text(item.title).font(.headline).foregroundStyle(palette.foreground).lineLimit(2).padding(12)
            }
            .clipShape(.rect(cornerRadius: 14))
            .accessibilityElement(children: .ignore).accessibilityLabel(item.title)
    }
}

struct SearchResultRow: View {
    let item: MusicSearchItem
    let model: SearchPageModel
    @State private var sources = LibraryArtworkSources()
    @Environment(\.openLibraryRoute) private var openRoute
    var body: some View {
        HStack(spacing: 12) {
            Button { open() } label: {
                HStack(spacing: 12) {
                    LibraryCardArtwork(content: AnyView(ArtworkView(artwork: item.artwork, contentID: item.id, cornerRadius: 0)),
                        sources: sources, sourceID: item.id, cornerRadius: item.kind == .artist ? 28 : 5)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.body).foregroundStyle(.primary).lineLimit(2)
                        Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(.rect)
            }.buttonStyle(.plain).accessibilityIdentifier("search.result.\(item.id)")
            if let song = item.song {
                Menu { SongMenuContents(song: song) } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 28, height: 44)
                }.accessibilityLabel("\(item.title)，更多")
            } else {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }.frame(minHeight: 60)
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
    @State private var sources = LibraryArtworkSources()
    @Environment(\.openLibraryRoute) private var openRoute
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 24) {
                ForEach(model.categoryItems) { item in
                    Button {
                        guard let route = item.route else { return }
                        let preview = item.preview(ownerID: model.ownerID, route: route)
                        model.onPrepareNavigation?(preview)
                        openRoute(route, preview: preview, sourceProvider: { [sources, id = item.id] in sources.view(for: id) })
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            LibraryCardArtwork(content: AnyView(ArtworkView(artwork: item.artwork, contentID: item.id, cornerRadius: 0)),
                                sources: sources, sourceID: item.id, cornerRadius: 8).aspectRatio(1, contentMode: .fit)
                            Text(item.title).font(.subheadline).lineLimit(2).foregroundStyle(.primary)
                            Text(item.subtitle).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
            }.padding(20)
            if let error = model.categoryError, !model.categoryItems.isEmpty {
                SearchInlineError(message: error) { Task { await model.onCategoryRefresh?() } }.padding(20)
            }
            if let error = model.categoryMoreError {
                SearchInlineError(message: error) { model.onCategoryMore?() }.padding(20)
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
        .environment(\.artworkLoadAction, ArtworkLoadAction(handler: { model.onArtwork?($0) }))
    }
}

private struct SearchInlineError: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        HStack { Text(message).font(.footnote).foregroundStyle(.secondary); Spacer(); Button("重试", action: retry) }
    }
}

private extension MusicSearchItem {
    @MainActor func preview(ownerID: String?, route: LibraryRoute) -> LibraryNavigationPreview {
        var cover = artwork
        if case .file(let url) = cover, let image = LocalArtworkImages.cached(url, pixels: 0) { cover = .image(Image(uiImage: image)) }
        return .init(route: route, ownerID: ownerID, title: title, subtitle: subtitle, artwork: cover)
    }
}
