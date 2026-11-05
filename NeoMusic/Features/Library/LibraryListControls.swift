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

/// 列表页的筛选：全部、喜爱、已下载。本地音乐都在本机，“下载”保留位置但不可用。
enum LibraryFilter: Hashable {
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
    func sorted(byName name: (Element) -> String) -> [Element] {
        map { element -> (isLetter: Bool, key: String, element: Element) in
            let key = TitleSection<Element>.sortKey(name(element))
            return (key.first.map { $0.isASCII && $0.isLetter } ?? false, key, element)
        }
        .sorted { lhs, rhs in
            lhs.isLetter != rhs.isLetter ? lhs.isLetter : lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
        }
        .map(\.element)
    }
}
