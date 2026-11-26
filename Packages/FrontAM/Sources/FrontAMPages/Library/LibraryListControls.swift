import FrontAMCore
import SwiftUI

@MainActor public final class LibraryListProjection<Input: Equatable, Output> {
    private var input: Input?
    private var output: Output?

    public func value(for input: Input, calculate: () -> Output) -> Output {
        if self.input == input, let output { return output }
        let output = calculate()
        self.input = input
        self.output = output
        return output
    }
}

@MainActor @Observable
public final class AsyncListProjection<Input: Equatable, Output> {
    private(set) var committedOutput: Output?
    @ObservationIgnored private var committedInput: Input?
    @ObservationIgnored private var fallbackInput: Input?
    @ObservationIgnored private var fallbackOutput: Output?

    public func currentValue(for input: Input,
                      fastPath: (Input) -> Output?,
                      synchronousInitial: (Input) -> Output) -> Output {
        if let fast = fastPath(input) { return fast }
        if committedInput == input, let committedOutput { return committedOutput }
        if let committedOutput { return committedOutput }
        if fallbackInput == input, let fallbackOutput { return fallbackOutput }
        let initial = synchronousInitial(input)
        fallbackInput = input
        fallbackOutput = initial
        return initial
    }

    public func currentValue(for input: Input,
                      fastPath: (Input) -> Output?,
                      placeholder: (Input) -> Output) -> Output {
        if let fast = fastPath(input) { return fast }
        if let committedOutput { return committedOutput }
        return placeholder(input)
    }

    public func isResolved(for input: Input, fastPath: (Input) -> Output?) -> Bool {
        fastPath(input) != nil || resolvedValue(for: input) != nil
    }

    public func resolvedValue(for input: Input) -> Output? {
        if committedInput == input, let committedOutput { return committedOutput }
        if fallbackInput == input { return fallbackOutput }
        return nil
    }

    public func computeIfNeeded<Intermediate: Sendable>(
        for input: Input,
        fastPath: (Input) -> Output?,
        background: @escaping @Sendable () -> Intermediate,
        finish: (Intermediate) -> Output
    ) async {
        if let fast = fastPath(input) {
            guard !Task.isCancelled else { return }
            commit(fast, for: input)
            return
        }

        await computeIfNeeded(for: input) {
            let intermediate = await withTaskGroup(of: Intermediate.self) { group in
                group.addTask { background() }
                return await group.next()
            }
            guard let intermediate, !Task.isCancelled else { return nil }
            return finish(intermediate)
        }
    }

    public func computeIfNeeded(for input: Input, calculate: () async -> Output?) async {
        guard committedInput != input, !Task.isCancelled else { return }
        if fallbackInput == input, let fallback = fallbackOutput {
            commit(fallback, for: input)
            return
        }
        guard let output = await calculate(), !Task.isCancelled else { return }
        commit(output, for: input)
    }

    private func commit(_ output: Output, for input: Input) {
        committedInput = input
        committedOutput = output
        fallbackInput = nil
        fallbackOutput = nil
    }
}

public enum LibraryFilter: Hashable, Sendable {
    case all, favorites, downloaded
}

public enum LibraryLayout: Hashable {
    case grid, list
}

public struct LibrarySortOption<Sort: Hashable & Sendable>: Identifiable, Sendable {
    public let sort: Sort
    public let title: String
    public var subtitle: String?
    public var id: Sort { sort }

    public init(sort: Sort,
                title: String,
                subtitle: String? = nil) {
        self.sort = sort
        self.title = title
        self.subtitle = subtitle
    }
}

public struct LibraryFilterMenu: View {
    @Binding public var filter: LibraryFilter
    public let allTitle: String
    public let allImage: String
    public var supportsDownloads = false
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    public var body: some View {
        Menu {
            option(.all) { Label(allTitle, systemImage: allImage) }
            Section {
                option(.favorites) { Label("喜爱", systemImage: "star") }
                option(.downloaded) { Label("下载", systemImage: "arrow.down.circle") }
                    .disabled(!supportsDownloads)
            }
        } label: {
            Label("筛选", systemImage: "line.3.horizontal.decrease")
        }
        .accessibilityValue(filter == .all ? allTitle : filter == .favorites ? "喜爱" : "下载")
        .menuActionDismissBehavior(.enabled)
    }

    private func option(_ value: LibraryFilter, @ViewBuilder label: () -> some View) -> some View {
        Toggle(isOn: Binding(get: { filter == value }, set: {
            if $0 { withAnimation(reducesMotion ? nil : .default) { filter = value } }
        }), label: label)
    }

    public init(filter: Binding<LibraryFilter>,
                allTitle: String,
                allImage: String,
                supportsDownloads: Bool = false) {
        self._filter = filter
        self.allTitle = allTitle
        self.allImage = allImage
        self.supportsDownloads = supportsDownloads
    }
}

public struct LibrarySortMenu<Sort: Hashable & Sendable>: View {
    public var layout: Binding<LibraryLayout>?
    @Binding public var sort: Sort
    public let options: [LibrarySortOption<Sort>]
    public var leading: LibraryMenuSections = []
    public var trailing: LibraryMenuSections = []
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    public var body: some View {
        Menu {
            LibraryMenuContents(sections: leading, firstSectionIsRow: false)
            if let layout {
                Section {
                    toggle(isOn: layout.wrappedValue == .grid, set: { layout.wrappedValue = .grid }) {
                        Label("网格", systemImage: "square.grid.2x2")
                    }
                    toggle(isOn: layout.wrappedValue == .list, set: { layout.wrappedValue = .list }) {
                        Label("列表", systemImage: "list.bullet")
                    }
                }
            }
            Section {
                ForEach(options) { option in
                    toggle(isOn: sort == option.sort, set: { sort = option.sort }) {
                        Text(option.title)
                        if let subtitle = option.subtitle { Text(subtitle) }
                    }
                }
            }
            LibraryMenuContents(sections: trailing, firstSectionIsRow: false)
        } label: {
            Label("更多", systemImage: "ellipsis")
        }
        .accessibilityHint("调整排序或打开其他选项")
        .accessibilityValue(options.first { $0.sort == sort }?.title ?? "")
        .menuActionDismissBehavior(.enabled)
    }

    private func toggle(isOn: Bool, set: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: {
            if $0 { withAnimation(reducesMotion ? nil : .default, set) }
        }), label: label)
    }

    public init(layout: Binding<LibraryLayout>? = nil,
                sort: Binding<Sort>,
                options: [LibrarySortOption<Sort>],
                leading: LibraryMenuSections = [],
                trailing: LibraryMenuSections = []) {
        self.layout = layout
        self._sort = sort
        self.options = options
        self.leading = leading
        self.trailing = trailing
    }
}

extension Sequence {
    public func sorted(byName name: (Element) -> String) -> [Element] {
        var keyed: [(isLetter: Bool, key: String, element: Element)] = []
        keyed.reserveCapacity(underestimatedCount)
        for element in self {
            if Task.isCancelled { return [] }
            let key = TitleSection<Element>.sortKey(name(element))
            keyed.append((key.first.map { $0.isASCII && $0.isLetter } ?? false, key, element))
        }
        return keyed
            .sorted { lhs, rhs in
                lhs.isLetter != rhs.isLetter ? lhs.isLetter : lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
            .map(\.element)
    }
}
