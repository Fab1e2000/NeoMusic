import SwiftUI

/// Each page keeps only its last projection. Unrelated presentation updates reuse it,
/// while changed data and controls produce their result in the same render pass.
@MainActor final class LibraryListProjection<Input: Equatable, Output> {
    private var input: Input?
    private var output: Output?

    func value(for input: Input, calculate: () -> Output) -> Output {
        if self.input == input, let output { return output }
        let output = calculate()
        self.input = input
        self.output = output
        return output
    }
}

/// Runs heavy list filtering and Pinyin sorting off the main thread while browsing,
/// preserving the previous valid snapshot until background computation finishes.
@MainActor @Observable
final class AsyncListProjection<Input: Equatable, Output> {
    private(set) var committedOutput: Output?
    @ObservationIgnored private var committedInput: Input?
    @ObservationIgnored private var fallbackInput: Input?
    @ObservationIgnored private var fallbackOutput: Output?

    func currentValue(for input: Input,
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

    /// Returns fast-path results immediately, retains the last committed output while recomputing
    /// subsequent changes, and supplies `placeholder` on first appearance so navigation pushes never block.
    func currentValue(for input: Input,
                      fastPath: (Input) -> Output?,
                      placeholder: (Input) -> Output) -> Output {
        if let fast = fastPath(input) { return fast }
        if let committedOutput { return committedOutput }
        return placeholder(input)
    }

    /// True only for the current input: it either hits the synchronous fast path or its own
    /// background projection has committed. A retained snapshot for a previous input stays
    /// visible through `currentValue`, but must never make the new input look resolved.
    func isResolved(for input: Input, fastPath: (Input) -> Output?) -> Bool {
        fastPath(input) != nil
            || (committedInput == input && committedOutput != nil)
            || (fallbackInput == input && fallbackOutput != nil)
    }

    func computeIfNeeded<Intermediate: Sendable>(
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
        guard committedInput != input else { return }
        if fallbackInput == input, let fallback = fallbackOutput {
            guard !Task.isCancelled else { return }
            commit(fallback, for: input)
            return
        }
        // The child of a task group inherits cancellation from the `.task(id:)` that owns this
        // call, unlike `Task.detached`. When the controls change, the superseded filter/sort can
        // observe `Task.isCancelled` and stop instead of running to completion.
        let intermediate = await withTaskGroup(of: Intermediate?.self) { group -> Intermediate? in
            group.addTask { background() }
            for await value in group { return value }
            return nil
        }
        // A cancelled task must never publish a result for an input the user already replaced.
        guard let intermediate, !Task.isCancelled else { return }
        commit(finish(intermediate), for: input)
    }

    private func commit(_ output: Output, for input: Input) {
        committedInput = input
        committedOutput = output
        fallbackInput = nil
        fallbackOutput = nil
    }
}

/// 列表页的筛选：全部、喜爱、已下载。本地音乐都在本机，“下载”保留位置但不可用。
enum LibraryFilter: Hashable, Sendable {
    case all, favorites, downloaded
}

/// 专辑、播放列表页的显示方式。
enum LibraryLayout: Hashable {
    case grid, list
}

/// 排序菜单里的一项；副标题显示在标题下方（例如“艺人”下的“A-Z”）。
struct LibrarySortOption<Sort: Hashable & Sendable>: Identifiable, Sendable {
    let sort: Sort
    let title: String
    var subtitle: String?
    var id: Sort { sort }
}

/// 右上角“≡”按钮：筛选。首项为“所有…”，其下为喜爱与下载。对照 Apple Music。
struct LibraryFilterMenu: View {
    @Binding var filter: LibraryFilter
    let allTitle: String
    let allImage: String
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        Menu {
            option(.all) { Label(allTitle, systemImage: allImage) }
            Section {
                option(.favorites) { Label("喜爱", systemImage: "star") }
                option(.downloaded) { Label("下载", systemImage: "arrow.down.circle") }
                    .disabled(true)
            }
        } label: {
            Label("筛选", systemImage: "line.3.horizontal.decrease")
        }
        .menuActionDismissBehavior(.enabled)
    }

    private func option(_ value: LibraryFilter, @ViewBuilder label: () -> some View) -> some View {
        Toggle(isOn: Binding(get: { filter == value }, set: {
            if $0 { withAnimation(reducesMotion ? nil : .default) { filter = value } }
        }), label: label)
    }
}

/// 右上角“…”按钮：显示方式（网格、列表）与排序。对照 Apple Music。
struct LibrarySortMenu<Sort: Hashable & Sendable>: View {
    var layout: Binding<LibraryLayout>?
    @Binding var sort: Sort
    let options: [LibrarySortOption<Sort>]
    /// 页面自身的操作，分别排在显示方式之前与排序之后（例如文件夹页的重新命名与删除）。
    var leading: LibraryMenuSections = []
    var trailing: LibraryMenuSections = []
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
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
        .menuActionDismissBehavior(.enabled)
    }

    private func toggle(isOn: Bool, set: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: {
            if $0 { withAnimation(reducesMotion ? nil : .default, set) }
        }), label: label)
    }
}

extension Sequence {
    /// 按字符串排序；中文按拼音，非字母开头的排在最后，与资料库字母分组（“#”在最后）一致。
    /// A cancelled caller (a superseded background projection) stops building sort keys early;
    /// its partial result is discarded by `AsyncListProjection`.
    func sorted(byName name: (Element) -> String) -> [Element] {
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
