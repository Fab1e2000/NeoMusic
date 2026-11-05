#if DEBUG
import Foundation

/// Read-only device verification; the report contains counts and error codes only.
@MainActor enum NeteaseSearchReadProbe {
    static func run(account: NeteaseAccount) async {
        guard let store = account.search else { return }
        var report: [String: Any] = ["hasSession": account.profile != nil]
        let directory = URL.applicationSupportDirectory.appendingPathComponent("SearchReadProbe")
        func save() {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
            }
        }
        await store.loadCategories()
        report["categoryCount"] = store.categories.count
        if let name = store.categories.first?.name {
            await store.openCategory(name)
            report["categoryPlaylistCount"] = store.categoryPage?.groups.flatMap(\.items).count ?? 0
            report["categoryError"] = store.categoryError
        }
        save()
        await store.suggest("洛天依")
        report["keywordCount"] = store.suggestions.keywords.count
        report["entitySuggestionCount"] = store.suggestions.resources.count
        var searches: [[String: Any]] = []
        for kind in NeteaseSearchKind.allCases {
            await store.search("洛天依", kind: kind)
            var result: [String: Any] = ["type": kind.rawValue,
                "count": store.page?.groups.flatMap(\.items).count ?? 0,
                "groupOrder": store.page?.groups.map { $0.kind.rawValue } ?? []]
            result["error"] = store.error
            if kind == .song, store.page?.hasMore == true {
                let before = store.page?.groups.flatMap(\.items).count ?? 0
                await store.loadMore()
                let items = store.page?.groups.flatMap(\.items) ?? []
                result["pageAddedCount"] = items.count - before
                result["uniqueIdentities"] = Set(items.map(\.id)).count == items.count
                result["pageError"] = store.moreError
            }
            searches.append(result); report["searches"] = searches; save()
        }
        await account.librarySearch?.synchronize()
        report["indexedCollections"] = account.librarySearch?.completed ?? 0
        report["totalCollections"] = account.librarySearch?.total ?? 0
        report["failedCollections"] = account.librarySearch?.failedCollections.count ?? 0
        do { report["libraryMatchCount"] = try await account.librarySearch?.search("洛天依").count ?? 0 }
        catch { report["libraryErrorCode"] = (error as NSError).code }
        report["completed"] = true; save()
    }
}
#endif
