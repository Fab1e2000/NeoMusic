import Foundation
import Observation

@MainActor @Observable
final class NeteaseSearchStore {
    struct Request: Hashable, Sendable { let query: String; let kind: NeteaseSearchKind }
    private(set) var request: Request?
    private(set) var page: NeteaseSearchPage?
    private(set) var suggestions = NeteaseSearchSuggestions(keywords: [], resources: [])
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var error: String?
    private(set) var moreError: String?
    private(set) var suggestionError: String?
    private(set) var history: [String] = []
    private(set) var categories: [NeteaseSearchCategory] = []
    private(set) var isLoadingCategories = false
    private(set) var categoriesError: String?
    private(set) var category: String?
    private(set) var categoryPage: NeteaseSearchPage?
    private(set) var isLoadingCategory = false
    private(set) var isLoadingMoreCategory = false
    private(set) var categoryError: String?
    private(set) var categoryMoreError: String?
    private(set) var sessionID = UUID()
    @ObservationIgnored var onArtworkChange: ((Set<URL>) -> Void)?
    @ObservationIgnored private let artworkCache = NeteaseArtworkCache.shared
    @ObservationIgnored private var artworkTasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private let client: NeteaseSearchClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var owner = "guest"
    @ObservationIgnored private var credential: NeteaseCredential?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var searchID = UUID()
    @ObservationIgnored private var suggestionID = UUID()
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var suggestionTask: Task<Void, Never>?
    @ObservationIgnored private var categoriesTask: Task<Void, Never>?
    @ObservationIgnored private var categoryTask: Task<Void, Never>?
    @ObservationIgnored private var categoryID = UUID()
    @ObservationIgnored private var categoryCache: [String: NeteaseSearchPage] = [:]
    @ObservationIgnored private var cache: [Request: NeteaseSearchPage] = [:]
    init(client: NeteaseSearchClient = .init(), defaults: UserDefaults = .standard) {
        self.client = client; self.defaults = defaults
        history = defaults.stringArray(forKey: "search.history.guest.online") ?? []
    }
    func setSession(owner: Int64?, credential: NeteaseCredential?) async {
        let nextOwner = owner.map(String.init) ?? "guest"
        guard self.owner != nextOwner || self.credential != credential else { return }
        let generation = UUID(); self.generation = generation
        let previous = [searchTask, suggestionTask, categoriesTask, categoryTask].compactMap { $0 } + Array(artworkTasks.values)
        previous.forEach { $0.cancel() }
        searchTask = nil; suggestionTask = nil; categoriesTask = nil; categoryTask = nil
        artworkTasks = [:]
        for task in previous { await task.value }
        guard self.generation == generation else { return }
        self.owner = owner.map(String.init) ?? "guest"; self.credential = credential
        request = nil; page = nil; cache = [:]; isLoading = false; isLoadingMore = false
        suggestions = .init(keywords: [], resources: []); error = nil; moreError = nil; suggestionError = nil
        history = recent(scope: "online")
        categories = []; categoriesError = nil; isLoadingCategories = false
        category = nil; categoryPage = nil; categoryCache = [:]
        isLoadingCategory = false; isLoadingMoreCategory = false; categoryError = nil; categoryMoreError = nil
        sessionID = generation
    }
    func cancelQuery() async {
        searchID = UUID(); suggestionID = UUID()
        let previous = [searchTask, suggestionTask].compactMap { $0 }
        searchTask = nil; suggestionTask = nil
        previous.forEach { $0.cancel() }
        isLoading = false; isLoadingMore = false
        suggestions = .init(keywords: [], resources: []); suggestionError = nil
        for task in previous { await task.value }
    }
    func cachedArtwork(_ remote: URL) -> URL? { artworkCache.cachedURL(for: remote, scope: owner == "guest" ? "public" : owner) }
    func requestArtwork(_ remote: URL) {
        guard artworkTasks[remote] == nil else { return }
        if cachedArtwork(remote) != nil { onArtworkChange?([remote]); return }
        let generation = generation, scope = owner == "guest" ? "public" : owner
        artworkTasks[remote] = Task {
            defer { if self.generation == generation { artworkTasks[remote] = nil } }
            do {
                _ = try await artworkCache.imageURL(for: remote, scope: scope)
                guard !Task.isCancelled, self.generation == generation else { return }
                onArtworkChange?([remote])
            } catch { }
        }
    }
    func recent(scope: String) -> [String] { defaults.stringArray(forKey: historyKey(scope)) ?? [] }
    func record(_ query: String, scope: String) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let updated = Array(([value] + recent(scope: scope).filter { $0 != value }).prefix(20))
        defaults.set(updated, forKey: historyKey(scope))
        if scope == "online" { history = updated }
    }
    func removeHistory(_ query: String?, scope: String) {
        let updated = query.map { word in recent(scope: scope).filter { $0 != word } } ?? []
        defaults.set(updated, forKey: historyKey(scope))
        if scope == "online" { history = updated }
    }
    private func historyKey(_ scope: String) -> String { "search.history.\(owner).\(scope)" }

    func loadCategories(force: Bool = false) async {
        if let categoriesTask { await categoriesTask.value; return }
        guard force || categories.isEmpty else { return }
        let generation = generation, credential = credential
        isLoadingCategories = true; categoriesError = nil
        let work = Task {
            defer { if self.generation == generation { isLoadingCategories = false } }
            do {
                let values = try await client.categories(credential: credential)
                guard !Task.isCancelled, self.generation == generation else { return }
                categories = values
            } catch is CancellationError { }
            catch { if !Task.isCancelled, self.generation == generation { categoriesError = error.localizedDescription } }
        }
        categoriesTask = work
        await work.value
        if self.generation == generation { categoriesTask = nil }
    }

    func openCategory(_ name: String, force: Bool = false) async {
        if !force, category == name, let categoryTask { await categoryTask.value; return }
        let id = UUID(); categoryID = id
        let enteredGeneration = generation
        let previous = categoryTask; previous?.cancel(); categoryTask = nil
        await previous?.value
        guard categoryID == id, generation == enteredGeneration else { return }
        if category != name { categoryPage = nil }
        category = name; categoryError = nil; categoryMoreError = nil; isLoadingMoreCategory = false
        if !force, let cached = categoryCache[name] { categoryPage = cached; isLoadingCategory = false; return }
        let generation = generation, credential = credential
        isLoadingCategory = true
        let work = Task {
            defer { if self.generation == generation, categoryID == id { isLoadingCategory = false } }
            do {
                let result = try await client.playlists(category: name, credential: credential)
                guard !Task.isCancelled, self.generation == generation, categoryID == id else { return }
                categoryPage = result; categoryCache[name] = result
            } catch is CancellationError { }
            catch { if !Task.isCancelled, self.generation == generation, categoryID == id { categoryError = error.localizedDescription } }
        }
        categoryTask = work
        await work.value
        if categoryID == id { categoryTask = nil }
    }

    func loadMoreCategory() async {
        guard categoryTask == nil, let category, let old = categoryPage, old.hasMore else { return }
        let id = UUID(); categoryID = id
        let generation = generation, credential = credential
        isLoadingMoreCategory = true; categoryMoreError = nil
        let work = Task {
            defer { if self.generation == generation, categoryID == id { isLoadingMoreCategory = false } }
            do {
                let incoming = try await client.playlists(category: category, offset: old.nextOffset, credential: credential)
                guard !Task.isCancelled, self.generation == generation, categoryID == id else { return }
                let result = Self.merging(old, incoming)
                categoryPage = result; categoryCache[category] = result
            } catch is CancellationError { }
            catch { if !Task.isCancelled, self.generation == generation, categoryID == id { categoryMoreError = error.localizedDescription } }
        }
        categoryTask = work
        await work.value
        if categoryID == id { categoryTask = nil }
    }

    func suggest(_ query: String) async {
        let id = UUID(); suggestionID = id
        let enteredGeneration = generation
        let previous = suggestionTask; previous?.cancel(); suggestionTask = nil
        await previous?.value
        guard suggestionID == id, generation == enteredGeneration else { return }
        suggestions = .init(keywords: [], resources: []); suggestionError = nil
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let generation = generation, credential = credential
        let work = Task {
            do {
                try await Task.sleep(for: .milliseconds(300))
                let result = try await client.suggestions(query, credential: credential)
                guard !Task.isCancelled, self.generation == generation, suggestionID == id else { return }
                suggestions = result
            } catch is CancellationError { }
            catch { if !Task.isCancelled, self.generation == generation, suggestionID == id { suggestionError = error.localizedDescription } }
        }
        suggestionTask = work
        await work.value
        if suggestionID == id { suggestionTask = nil }
    }

    func search(_ query: String, kind: NeteaseSearchKind, force: Bool = false) async {
        let next = Request(query: query.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind)
        if !force, request == next, let searchTask { await searchTask.value; return }
        let id = UUID(); searchID = id
        let enteredGeneration = generation
        let previous = searchTask; previous?.cancel(); searchTask = nil
        suggestionTask?.cancel()
        await previous?.value
        guard searchID == id, generation == enteredGeneration else { return }
        let changed = request != next
        if request?.query != next.query { cache = [:] }
        request = next; error = nil; moreError = nil; isLoadingMore = false
        guard !next.query.isEmpty else { page = nil; isLoading = false; return }
        if !force, let cached = cache[next] { page = cached; isLoading = false; return }
        if changed { page = nil }
        isLoading = true
        let generation = generation, credential = credential
        let work = Task {
            defer { if self.generation == generation, searchID == id { isLoading = false } }
            do {
                let result = try await client.search(next.query, kind: next.kind, credential: credential)
                guard !Task.isCancelled, self.generation == generation, searchID == id else { return }
                page = result; cache[next] = result
            } catch is CancellationError { }
            catch { if !Task.isCancelled, self.generation == generation, searchID == id { self.error = error.localizedDescription } }
        }
        searchTask = work
        await work.value
        if searchID == id { searchTask = nil }
    }

    func loadMore() async {
        guard searchTask == nil, let request, request.kind != .combined, let old = page, old.hasMore else { return }
        let id = UUID(); searchID = id
        let generation = generation, credential = credential
        isLoadingMore = true; moreError = nil
        let work = Task {
            defer { if self.generation == generation, searchID == id { isLoadingMore = false } }
            do {
                let incoming = try await client.search(request.query, kind: request.kind, offset: old.nextOffset, credential: credential)
                guard !Task.isCancelled, self.generation == generation, searchID == id else { return }
                let combined = Self.merging(old, incoming)
                page = combined; cache[request] = combined
            } catch is CancellationError { }
            catch { if !Task.isCancelled, self.generation == generation, searchID == id { moreError = error.localizedDescription } }
        }
        searchTask = work
        await work.value
        if searchID == id { searchTask = nil }
    }
    static func merging(_ old: NeteaseSearchPage, _ incoming: NeteaseSearchPage) -> NeteaseSearchPage {
        var groups = old.groups
        var added = 0
        for group in incoming.groups {
            if let index = groups.firstIndex(where: { $0.kind == group.kind }) {
                var seen = Set(groups[index].items.map(\.id))
                let items = group.items.filter { seen.insert($0.id).inserted }
                groups[index].items += items; groups[index].hasMore = group.hasMore; added += items.count
            } else { groups.append(group); added += group.items.count }
        }
        return .init(groups: groups, nextOffset: incoming.nextOffset,
                     hasMore: incoming.hasMore && incoming.nextOffset > old.nextOffset && added > 0)
    }
}
