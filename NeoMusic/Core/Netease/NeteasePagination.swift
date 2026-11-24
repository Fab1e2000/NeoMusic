enum NeteasePagination {
    struct Page<Item: Sendable>: Sendable {
        let items: [Item]
        let hasMore: Bool
        let advance: Int
    }

    nonisolated(nonsending) static func collect<Item: Sendable>(id: (Item) -> Int64,
        fetch: (Int) async throws -> Page<Item>) async throws -> [Item] {
        var result: [Item] = []
        var seen = Set<Int64>()
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await fetch(offset)
            try Task.checkCancellation()
            let previousCount = result.count
            result += page.items.filter { seen.insert(id($0)).inserted }
            if !page.hasMore { return result }
            guard result.count > previousCount, page.advance > 0 else { throw NeteaseAccountError.invalidResponse }
            offset += page.advance
        }
    }
}
