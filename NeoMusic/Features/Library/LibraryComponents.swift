import SwiftUI

extension View {
    /// Animate collection membership/order at its owner, including changes coming
    /// from another hosting controller. Titles and artwork updates alone do not reflow.
    func libraryCollectionAnimation<Value: Equatable>(value: Value) -> some View {
        modifier(LibraryCollectionAnimation(value: value))
    }
}

private struct LibraryCollectionAnimation<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    func body(content: Content) -> some View {
        content.animation(reducesMotion ? nil : .smooth(duration: 0.3), value: value)
    }
}

/// 列表页标题下方的“播放 / 随机播放”两个胶囊按钮。
struct PlayShuffleButtons: View {
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            button("播放", systemImage: "play.fill", action: play)
            button("随机播放", systemImage: "shuffle", action: shuffle)
        }
    }

    private func button(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color(.tertiarySystemFill), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

/// 专辑网格中的一项：封面、标题与副标题。
struct AlbumCard: View {
    let item: LibraryShelfItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ArtworkView(artwork: item.artwork, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(item.title).lineLimit(1)
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .imageScale(.small)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("已喜爱")
                    }
                }
                .font(.footnote.weight(.medium))
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 在资料库导航栈中推入一页，由持有导航路径的宿主提供。
struct OpenLibraryRouteAction {
    let handler: (LibraryRoute) -> Void
    var sourceHandler: ((LibraryRoute, UIView?) -> Void)?
    var sourceProviderHandler: ((LibraryRoute, @escaping () -> UIView?) -> Void)?
    func callAsFunction(_ route: LibraryRoute, source: UIView? = nil) {
        if let sourceHandler { sourceHandler(route, source) } else { handler(route) }
    }
    /// Reusable cells resolve the current artwork again on both zoom in and zoom out.
    func callAsFunction(_ route: LibraryRoute, sourceProvider: @escaping () -> UIView?) {
        if let sourceProviderHandler { sourceProviderHandler(route, sourceProvider) }
        else { callAsFunction(route, source: sourceProvider()) }
    }
}

extension EnvironmentValues {
    @Entry var openLibraryRoute = OpenLibraryRouteAction { _ in }
}

/// 喜爱的条目在行首留白处显示的小星标，不挤动封面与文字。
struct FavoriteMark: View {
    let isFavorite: Bool
    var color: Color = .secondary

    var body: some View {
        if isFavorite {
            Image(systemName: "star.fill")
                .font(.system(size: 9))
                .foregroundStyle(color)
                .frame(width: 10, height: 12)
                .offset(x: -15)
                .accessibilityHidden(true)
        }
    }
}

/// 按标题首字母（中文取拼音首字母）分组；非字母开头归入“#”，排在最后。
struct TitleSection<Item>: Identifiable {
    let letter: String
    let items: [Item]
    var id: String { letter }

    /// 排序用的键：中文转为拼音，去掉声调，小写。
    static func sortKey(_ title: String) -> String {
        let latin = title.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? title
        return latin.lowercased()
    }

    static func group(_ items: [Item], by title: (Item) -> String) -> [TitleSection] {
        let keyed = items.map { item in (sortKey: sortKey(title(item)), item: item) }
        .sorted { $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending }
        let grouped = Dictionary(grouping: keyed) { entry in
            entry.sortKey.first.map { $0.isASCII && $0.isLetter ? String($0).uppercased() : "#" } ?? "#"
        }
        return grouped.keys
            .sorted { lhs, rhs in lhs == "#" ? false : rhs == "#" ? true : lhs < rhs }
            .map { TitleSection(letter: $0, items: grouped[$0]!.map(\.item)) }
    }
}

/// Detail actions (for example deleting the current album) use the owning navigator.
/// Sheets keep their own standard SwiftUI dismiss action.
struct CloseLibraryDetailAction {
    var handler: (() -> Void)?
}

extension EnvironmentValues {
    @Entry var closeLibraryDetail = CloseLibraryDetailAction()
}
