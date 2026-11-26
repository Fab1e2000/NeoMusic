import Foundation

public struct FrontAMTabStorage {
    public let orderKey: String
    public let hiddenKey: String
    public let defaults: UserDefaults

    public init(orderKey: String = "frontam.tabOrder.v1", hiddenKey: String = "frontam.tabHidden.v1",
                defaults: UserDefaults = .standard) {
        self.orderKey = orderKey
        self.hiddenKey = hiddenKey
        self.defaults = defaults
    }

    public var order: String? { defaults.string(forKey: orderKey) }
    public var hidden: String? { defaults.string(forKey: hiddenKey) }
}

public struct FrontAMTabOrder<Tab: Hashable & Sendable>: Sendable {
    private let decode: @Sendable (String) -> Tab?
    private let encode: @Sendable (Tab) -> String
    private let fixed: [Tab]
    private let reorderable: [Tab]
    private let fallback: Tab
    private let maxVisible: Int
    private let defaultHidden: Set<Tab>

    public init(fixed: [Tab], reorderable: [Tab], fallback: Tab, maxVisible: Int = 4, defaultHidden: Set<Tab> = [],
                decode: @escaping @Sendable (String) -> Tab?, encode: @escaping @Sendable (Tab) -> String) {
        var seen = Set<Tab>()
        self.fixed = fixed.filter { seen.insert($0).inserted }
        self.reorderable = reorderable
        self.fallback = fallback
        self.maxVisible = max(1, maxVisible)
        self.defaultHidden = defaultHidden
        self.decode = decode
        self.encode = encode
    }

    private func decoded(_ raw: String) -> [Tab] {
        raw.split(separator: ",").compactMap { decode(String($0)) }
    }

    public func resolve(_ raw: String, additional: [Tab] = []) -> [Tab] {
        let available = (reorderable + additional).filter { !fixed.contains($0) }
        let allowed = Set(available)
        var seen = Set<Tab>()
        return (decoded(raw).filter(allowed.contains) + available).filter { seen.insert($0).inserted }
    }

    public func hidden(from stored: String?) -> Set<Tab> {
        guard let stored else { return defaultHidden }
        return Set(decoded(stored)).subtracting(fixed)
    }

    public func effectiveHidden(order: String, hidden: String?, additional: [Tab] = []) -> Set<Tab> {
        var omitted = self.hidden(from: hidden)
        let mentioned = Set(decoded(order))
        omitted.formUnion(additional.filter { !mentioned.contains($0) })
        let resolved = resolve(order, additional: additional)
        return omitted.union(resolved.filter { !omitted.contains($0) }.dropFirst(maxVisible))
    }

    public func visible(order: String, hidden: String?, additional: [Tab] = []) -> [Tab] {
        let omitted = effectiveHidden(order: order, hidden: hidden, additional: additional)
        let result = resolve(order, additional: additional).filter { !omitted.contains($0) }
        return result.isEmpty ? [fallback] : result
    }

    public func displayed(order: String, hidden: String?, additional: [Tab] = []) -> [Tab] {
        visible(order: order, hidden: hidden, additional: additional) + fixed
    }

    public func raw(_ tabs: some Sequence<Tab>) -> String {
        tabs.map(encode).joined(separator: ",")
    }
}
