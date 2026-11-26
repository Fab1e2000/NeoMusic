import SwiftUI
import UIKit

public struct FrontAMSearchPresentation {
    public let query: Binding<String>
    public let prompt: String
    let isSearching: () -> Bool
    let isSubmitted: () -> Bool
    let onPresent: () -> Void
    let onDismiss: () -> Void
    let onSubmit: () -> Void
    let onResumeEditing: () -> Void

    public init(query: Binding<String>, prompt: String, isSearching: @escaping () -> Bool,
                isSubmitted: @escaping () -> Bool, onPresent: @escaping () -> Void,
                onDismiss: @escaping () -> Void, onSubmit: @escaping () -> Void,
                onResumeEditing: @escaping () -> Void) {
        self.query = query
        self.prompt = prompt
        self.isSearching = isSearching
        self.isSubmitted = isSubmitted
        self.onPresent = onPresent
        self.onDismiss = onDismiss
        self.onSubmit = onSubmit
        self.onResumeEditing = onResumeEditing
    }
}

@MainActor @Observable
public final class FrontAMNavigationChrome: NSObject, UISearchResultsUpdating, UISearchBarDelegate, UISearchControllerDelegate {
    public var isActive = false
    public var hasAppeared = false
    @ObservationIgnored public weak var controller: UIViewController?
    @ObservationIgnored public var title = ""
    @ObservationIgnored public var mode: UINavigationItem.LargeTitleDisplayMode
    @ObservationIgnored public let isRoot: Bool
    public private(set) var colorScheme: ColorScheme?
    @ObservationIgnored private var search: UISearchController?
    @ObservationIgnored private var query: Binding<String>?
    @ObservationIgnored private var searchPrompt = ""
    @ObservationIgnored private var searchPage: FrontAMSearchPresentation?
    @ObservationIgnored var onColorSchemeChange: (ColorScheme?) -> Void = { _ in }

    public init(isRoot: Bool, title: String, mode: UINavigationItem.LargeTitleDisplayMode) {
        self.isRoot = isRoot
        self.title = title
        self.mode = mode
    }
    public func apply() {
        guard let item = controller?.navigationItem else { return }
        if item.title != title { item.title = title }
        if item.largeTitleDisplayMode != mode { item.largeTitleDisplayMode = mode }
        item.navigationBarMinimization.minimizationBehavior = isRoot ? .onScrollDown : .never
        item.navigationBarMinimization.restorationBehavior = isRoot ? .atScrollEdge : .automatic
        item.navigationBarMinimization.safeAreaAdjustment = .disabled
    }
    public func setColorScheme(_ scheme: ColorScheme?) {
        colorScheme = scheme
        controller?.overrideUserInterfaceStyle = scheme.map { UIUserInterfaceStyle($0) } ?? .unspecified
        guard let controller, let navigation = controller.navigationController,
              navigation.topViewController === controller else { return }
        onColorSchemeChange(scheme)
    }
    public func setBackdrop(color: UIColor?, colorScheme: ColorScheme?) {
        controller?.view.backgroundColor = color ?? .systemBackground
        setColorScheme(colorScheme)
    }
    public func attach(_ controller: UIViewController) {
        guard self.controller !== controller else { return }
        self.controller = controller
        apply()
        setSearch(query, prompt: searchPrompt)
    }
    public func setSearch(_ binding: Binding<String>?, prompt: String, usesStackedPlacement: Bool = false) {
        query = binding
        searchPrompt = prompt
        guard let controller else { return }
        guard let binding else {
            search?.isActive = false
            controller.navigationItem.searchController = nil
            search = nil
            return
        }
        if search == nil {
            let search = UISearchController(searchResultsController: nil)
            search.searchResultsUpdater = self
            search.obscuresBackgroundDuringPresentation = false
            self.search = search
        }
        if controller.navigationItem.searchController !== search {
            controller.navigationItem.searchController = search
            controller.navigationItem.hidesSearchBarWhenScrolling = true
            controller.definesPresentationContext = true
        }
        if usesStackedPlacement { controller.navigationItem.preferredSearchBarPlacement = .stacked }
        search?.searchBar.placeholder = prompt
        if search?.searchBar.text != binding.wrappedValue { search?.searchBar.text = binding.wrappedValue }
    }
    public func updateSearchResults(for searchController: UISearchController) {
        if let searchPage {
            guard searchPage.isSearching() else { return }
            guard searchController.searchBar.searchTextField.markedTextRange == nil else { return }
            searchPage.query.wrappedValue = (searchController.searchBar.text ?? "")
            return
        }
        let text = searchController.searchBar.text ?? ""
        if query?.wrappedValue != text { query?.wrappedValue = text }
    }

    public func setSearchPage(_ presentation: FrontAMSearchPresentation) {
        searchPage = presentation
        setSearch(presentation.query, prompt: presentation.prompt)
        guard let search else { return }
        search.delegate = self
        search.searchBar.delegate = self
        controller?.navigationItem.preferredSearchBarPlacement = .stacked
        controller?.navigationItem.hidesSearchBarWhenScrolling = false
    }
    public func activateSearchPageIfNeeded() {
        guard hasAppeared, searchPage?.isSearching() == true, search?.isActive == false else { return }
        search?.isActive = true
    }
    public func willPresentSearchController(_ searchController: UISearchController) {
        guard searchController === search else { return }
        searchPage?.onPresent()
    }
    public func didPresentSearchController(_ searchController: UISearchController) {
        guard searchController === search, searchPage?.isSearching() == true, searchPage?.isSubmitted() == false else { return }
        searchController.searchBar.becomeFirstResponder()
    }
    public func willDismissSearchController(_ searchController: UISearchController) {
        guard searchController === search else { return }
        searchPage?.onDismiss()
    }
    public func completeSearchSubmission() {
        guard searchPage?.isSubmitted() == true, let search,
              search.searchBar.searchTextField.isFirstResponder else { return }
        search.searchBar.resignFirstResponder()
    }
    public func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchPage?.onSubmit()
        completeSearchSubmission()
    }
    public func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        guard searchPage?.isSearching() == true else { return }
        searchPage?.onResumeEditing()
    }
}

extension EnvironmentValues {
    @Entry public var libraryNavigationChrome: FrontAMNavigationChrome?
}

public extension View {
    func libraryNavigationTitle(_ title: String) -> some View { modifier(LibraryTitle(title: title)) }
    func libraryTitleDisplayMode(_ mode: NavigationBarItem.TitleDisplayMode) -> some View { modifier(LibraryTitleMode(mode: mode)) }
    func libraryHomeNavigation(title: String) -> some View { modifier(LibraryHomeChrome(title: title)) }
    func librarySearchable(text: Binding<String>, prompt: String, enabled: Bool = true, usesStackedPlacement: Bool = false) -> some View {
        modifier(LibrarySearch(query: text, prompt: prompt, enabled: enabled, usesStackedPlacement: usesStackedPlacement))
    }
    func frontAMSearchPage(_ presentation: FrontAMSearchPresentation, submitted: Bool) -> some View {
        modifier(FrontAMSearchPage(presentation: presentation, submitted: submitted))
    }
}

private struct FrontAMSearchPage: ViewModifier {
    let presentation: FrontAMSearchPresentation
    let submitted: Bool
    @Environment(\.libraryNavigationChrome) private var chrome
    func body(content: Content) -> some View {
        content.background {
            LibraryChromeUpdate { chrome?.setSearchPage(presentation) }.frame(width: 0, height: 0)
        }
        .onChange(of: submitted) { _, submitted in
            if submitted { chrome?.completeSearchSubmission() }
        }
    }
}

private struct LibraryChromeUpdate: UIViewRepresentable {
    let update: () -> Void
    func makeUIView(context: Context) -> UIView { let view = UIView(); view.isUserInteractionEnabled = false; return view }
    func updateUIView(_ view: UIView, context: Context) { update() }
}
private struct LibraryTitle: ViewModifier {
    let title: String
    @Environment(\.libraryNavigationChrome) private var chrome
    @ViewBuilder func body(content: Content) -> some View {
        if let chrome { content.background { LibraryChromeUpdate { chrome.title = title; chrome.apply() }.frame(width: 0, height: 0) } }
        else { content.navigationTitle(title) }
    }
}
private struct LibraryTitleMode: ViewModifier {
    let mode: NavigationBarItem.TitleDisplayMode
    @Environment(\.libraryNavigationChrome) private var chrome
    @ViewBuilder func body(content: Content) -> some View {
        if let chrome {
            content.background { LibraryChromeUpdate {
                chrome.mode = mode == .large ? .always : .never
                chrome.apply()
            }.frame(width: 0, height: 0) }
        } else { content.navigationBarTitleDisplayMode(mode) }
    }
}
private struct LibraryHomeChrome: ViewModifier {
    let title: String
    @Environment(\.libraryNavigationChrome) private var chrome
    @ViewBuilder func body(content: Content) -> some View {
        if chrome != nil {
            content
                .toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)
                .toolbarMinimizationRestoration(.atScrollEdge, for: .navigationBar)
                .toolbarMinimizationSafeAreaAdjustment(.disabled, for: .navigationBar)
        }
        else {
            content.navigationTitle(title).toolbarTitleDisplayMode(.inlineLarge)
                .toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)
                .toolbarMinimizationRestoration(.atScrollEdge, for: .navigationBar)
                .toolbarMinimizationSafeAreaAdjustment(.disabled, for: .navigationBar)
        }
    }
}
private struct LibrarySearch: ViewModifier {
    @Binding var query: String
    let prompt: String
    let enabled: Bool
    let usesStackedPlacement: Bool
    @Environment(\.libraryNavigationChrome) private var chrome
    @ViewBuilder func body(content: Content) -> some View {
        if let chrome {
            content.background {
                LibraryChromeUpdate { chrome.setSearch(enabled ? $query : nil, prompt: prompt, usesStackedPlacement: usesStackedPlacement) }
                    .frame(width: 0, height: 0)
            }
        } else if enabled { content.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text(prompt)) }
        else { content }
    }
}
