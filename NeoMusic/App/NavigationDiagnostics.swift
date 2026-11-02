import Foundation
import SwiftUI
import UIKit

/// Temporary, passive diagnostics for the user-requested zoom timing comparison.
/// Detailed observation only; the unsuccessful cancelled-push layout experiment is removed.
/// No delegates, gestures, navigation items, insets or animation parameters are changed.
@MainActor enum NavigationDiagnostics {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-navigationDiagnostics")
    static let recorder = NavigationDiagnosticRecorder()

    static func event(_ name: String, page: String) {
        guard isEnabled else { return }
        recorder.event(name, page: page)
    }
}

final class NavigationDiagnosticFile: Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "NeoMusic.navigation-diagnostic-file", qos: .utility)

    init(directory: URL) {
        url = directory.appendingPathComponent("zoom-\(UUID().uuidString).jsonl")
    }

    func append(_ fields: [String: String]) {
        let url = url
        queue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    _ = FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                var data = try JSONEncoder().encode(fields)
                data.append(0x0A)
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                NSLog("Navigation diagnostics write failed: %@", error.localizedDescription)
            }
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}

@MainActor final class NavigationDiagnosticRecorder {
    private let file = NavigationDiagnosticFile(directory: URL.applicationSupportDirectory.appendingPathComponent("NavigationDiagnostics"))
    private let start = ProcessInfo.processInfo.systemUptime
    private var viewStates: [ObjectIdentifier: [String: String]] = [:]
    private var sequence = 0
    private weak var transitionSource: UIViewController?
    private weak var transitionTarget: UIViewController?
    private var lastHierarchyTime: TimeInterval = -.infinity
    private var knownTitles: Set<String> = ["资料库", "专辑"]
    private final class TrackedLabel {
        weak var label: UILabel?
        let token = UUID().uuidString
        init(_ label: UILabel) { self.label = label }
    }
    private var labels: [TrackedLabel] = []
    private weak var navigation: UINavigationController?
    private var timer: Timer?
    private var sampleUntil: TimeInterval = 0
    private var observedTransitions: Set<ObjectIdentifier> = []

    func attach(_ navigation: UINavigationController) { self.navigation = navigation }

    func event(_ name: String, page: String, extra: [String: String] = [:]) {
        write(name, page: page, extra: extra)
        sampleUntil = ProcessInfo.processInfo.systemUptime + 4
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func sample() {
        guard ProcessInfo.processInfo.systemUptime < sampleUntil else {
            timer?.invalidate(); timer = nil
            write("samplingEnded", page: "navigation")
            return
        }
        observeTransition()
        write("sample", page: "navigation")
    }

    private func observeTransition() {
        guard let coordinator = navigation?.transitionCoordinator else { return }
        let id = ObjectIdentifier(coordinator as AnyObject)
        guard observedTransitions.insert(id).inserted else { return }
        let transition = String(describing: id)
        // Retain coordinator until completion so a subsequent transition cannot reuse its identity.
        event("transitionObserved", page: "navigation", extra: ["transition": transition,
            "from": identity(coordinator.viewController(forKey: .from)),
            "to": identity(coordinator.viewController(forKey: .to)),
            "duration": String(coordinator.transitionDuration), "interactive": String(coordinator.isInteractive)])
        transitionSource = coordinator.viewController(forKey: .from)
        transitionTarget = coordinator.viewController(forKey: .to)
        coordinator.notifyWhenInteractionChanges { [weak self] context in
            self?.event("interactionChanged", page: "navigation", extra: ["transition": transition,
                "cancelled": String(context.isCancelled), "percent": String(describing: context.percentComplete)])
        }
        let registered = coordinator.animate(alongsideTransition: nil) { [weak self, coordinator] context in
            _ = coordinator
            self?.event("transitionCompleted", page: "navigation", extra: ["transition": transition,
                "cancelled": String(context.isCancelled)])
            self?.observedTransitions.remove(id)
        }
        if !registered { write("completionRegistrationRejected", page: "navigation", extra: ["transition": transition]) }
    }

    private func write(_ event: String, page: String, extra: [String: String] = [:]) {
        viewStates.removeAll(keepingCapacity: true)
        let captureStart = ProcessInfo.processInfo.systemUptime
        sequence += 1

        var fields = extra
        fields["schema"] = "2"
        fields["sequence"] = String(sequence)
        fields["event"] = event
        fields["page"] = page
        fields["uptime_ms"] = String(format: "%.3f", (ProcessInfo.processInfo.systemUptime - start) * 1000)
        fields["unix_ms"] = String(format: "%.3f", Date().timeIntervalSince1970 * 1000)
        if let navigation {
            let bar = navigation.navigationBar
            let controllers = navigation.viewControllers + [transitionSource, transitionTarget].compactMap { $0 }
            knownTitles.formUnion(controllers.compactMap { $0.navigationItem.title }.filter { !$0.isEmpty })
            fields["navigationItems"] = json(controllers.map { controller in
                let item = controller.navigationItem
                return ["controller": identity(controller), "item": objectID(item),
                    "trailingButtons": String(item.trailingItemGroups.flatMap(\.barButtonItems).count),
                    "title": item.title ?? "", "largeMode": String(item.largeTitleDisplayMode.rawValue),
                    "titleView": objectID(item.titleView), "search": objectID(item.searchController),
                    "view": objectID(controller.viewIfLoaded), "parent": identity(controller.parent),
                    "beingPresented": String(controller.isBeingPresented), "beingDismissed": String(controller.isBeingDismissed),
                    "movingFromParent": String(controller.isMovingFromParent), "movingToParent": String(controller.isMovingToParent)]
            })
            fields["barTopItem"] = objectID(bar.topItem)
            fields["barBackItem"] = objectID(bar.backItem)
            fields["barItemOrder"] = (bar.items ?? []).map(objectID).joined(separator: ",")
            fields["sourceController"] = identity(transitionSource)
            fields["targetController"] = identity(transitionTarget)
            fields["reduceMotion"] = String(UIAccessibility.isReduceMotionEnabled)
            fields["applicationState"] = String(UIApplication.shared.applicationState.rawValue)
            fields["interactivePopState"] = navigation.interactivePopGestureRecognizer.map { String($0.state.rawValue) } ?? "none"
            if event != "sample" || captureStart - lastHierarchyTime >= 0.2 {
                lastHierarchyTime = captureStart
                // Inspect the current window for known title labels, including reparented labels.
                // Read only; do not force layout or retain any UIKit view.
                var nodes: [[String: String]] = []
                var visited = 0
                func walk(_ view: UIView) {
                    guard visited < 3000 else { return }
                    visited += 1
                    if view === bar || view.isDescendant(of: bar) { nodes.append(viewState(view)) }
                    if let label = view as? UILabel, let text = label.text,
                       knownTitles.contains(text) || label.isDescendant(of: bar) {
                        if !labels.contains(where: { $0.label === label }) { labels.append(TrackedLabel(label)) }
                    }
                    for child in view.subviews { walk(child) }
                }
                walk(navigation.view.window ?? navigation.view)
                fields["barHierarchy"] = json(nodes)
                fields["hierarchyVisited"] = String(visited)
                fields["hierarchyLimitReached"] = String(visited >= 3000)
            }
            fields["trackedLabels"] = json(labels.map { tracked in
                guard let label = tracked.label else { return ["token": tracked.token, "state": "deallocated"] }
                var state = viewState(label)
                state["token"] = tracked.token
                state["text"] = label.text ?? label.attributedText?.string ?? ""
                state["inNavigationBar"] = String(label.isDescendant(of: bar))
                var parents: [String] = []
                var parent = label.superview
                while let current = parent { _ = viewState(current); parents.append(objectID(current)); parent = current.superview }
                state["ancestors"] = parents.joined(separator: " -> ")
                return state
            })
            labels.removeAll { $0.label == nil }
            fields["toolbarHidden"] = String(navigation.isToolbarHidden)
            fields["toolbarFrame"] = NSCoder.string(for: navigation.toolbar.frame)
            fields["navHidden"] = String(navigation.isNavigationBarHidden)
            fields["barHidden"] = String(bar.isHidden)
            fields["barAlpha"] = String(describing: bar.alpha)
            fields["barFrame"] = NSCoder.string(for: bar.frame)
            fields["barPresentationFrame"] = bar.layer.presentation().map { NSCoder.string(for: $0.frame) } ?? "none"
            fields["barPresentationOpacity"] = bar.layer.presentation().map { String($0.opacity) } ?? "none"
            fields["barAnimations"] = (bar.layer.animationKeys() ?? []).joined(separator: ",")
            fields["navSafeArea"] = NSCoder.string(for: navigation.view.safeAreaInsets)
            fields["topController"] = identity(navigation.topViewController)
            fields["visibleController"] = identity(navigation.visibleViewController)
            fields["stackCount"] = String(navigation.viewControllers.count)
            if let top = navigation.topViewController {
                fields["title"] = top.navigationItem.title ?? ""
                fields["largeTitleMode"] = String(top.navigationItem.largeTitleDisplayMode.rawValue)
                fields["topSafeArea"] = top.viewIfLoaded.map { NSCoder.string(for: $0.safeAreaInsets) } ?? "unloaded"
                fields["searchActive"] = top.navigationItem.searchController.map { String($0.isActive) } ?? "none"
                fields["searchFrame"] = top.navigationItem.searchController.map { NSCoder.string(for: $0.searchBar.frame) } ?? "none"
                if let view = top.viewIfLoaded, let scroll = firstScroll(in: view) {
                    fields["scrollOffset"] = NSCoder.string(for: scroll.contentOffset)
                    fields["scrollInsets"] = NSCoder.string(for: scroll.adjustedContentInset)
                }
            }
            // Public view properties only. Record labels as well as the bar, since a title
            // may be transparent even while the navigation bar itself remains visible.
            fields["barLabels"] = labelStates(in: bar).joined(separator: " | ")
            if let transition = navigation.transitionCoordinator {
                fields["transitionPercent"] = String(describing: transition.percentComplete)
                fields["transitionInteractive"] = String(transition.isInteractive)
                fields["transitionCancelled"] = String(transition.isCancelled)
            }
        }
        fields["viewStates"] = json(Array(viewStates.values))
        fields["capture_ms"] = String(format: "%.3f", (ProcessInfo.processInfo.systemUptime - captureStart) * 1000)
        file.append(fields)
    }

    private func objectID(_ object: AnyObject?) -> String {
        object.map { "\(type(of: $0))@\(ObjectIdentifier($0))" } ?? "none"
    }

    private func json(_ value: [[String: String]]) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private func viewState(_ view: UIView) -> [String: String] {
        let id = ObjectIdentifier(view)
        if let cached = viewStates[id] { return cached }
        let layer = view.layer
        let presentation = layer.presentation()
        var result = ["id": objectID(view), "parent": objectID(view.superview), "window": objectID(view.window),
            "hidden": String(view.isHidden), "alpha": String(describing: view.alpha),
            "frame": NSCoder.string(for: view.frame), "bounds": NSCoder.string(for: view.bounds),
            "windowFrame": NSCoder.string(for: view.convert(view.bounds, to: view.window)),
            "safeArea": NSCoder.string(for: view.safeAreaInsets), "clips": String(view.clipsToBounds),
            "transform": String(describing: view.transform), "layerOpacity": String(layer.opacity),
            "layerHidden": String(layer.isHidden), "layerMask": objectID(layer.mask),
            "presentationOpacity": presentation.map { String($0.opacity) } ?? "none",
            "presentationFrame": presentation.map { NSCoder.string(for: $0.frame) } ?? "none",
            "presentationTransform": presentation.map { String(describing: $0.transform) } ?? "none"]
        result["animations"] = json((layer.animationKeys() ?? []).compactMap { key in
            guard let animation = layer.animation(forKey: key) else { return nil }
            var info = ["key": key, "type": String(describing: type(of: animation)),
                "duration": String(animation.duration), "beginTime": String(animation.beginTime),
                "speed": String(animation.speed), "timeOffset": String(animation.timeOffset),
                "fillMode": animation.fillMode.rawValue, "removedOnCompletion": String(animation.isRemovedOnCompletion)]
            if let property = animation as? CAPropertyAnimation { info["keyPath"] = property.keyPath ?? "" }
            if let basic = animation as? CABasicAnimation {
                info["from"] = String(describing: basic.fromValue)
                info["to"] = String(describing: basic.toValue)
            }
            return info
        })
        viewStates[id] = result
        return result
    }

    private func identity(_ controller: UIViewController?) -> String {
        controller.map { "\(type(of: $0))@\(ObjectIdentifier($0))" } ?? "none"
    }

    private func firstScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for child in view.subviews { if let scroll = firstScroll(in: child) { return scroll } }
        return nil
    }

    private func labelStates(in view: UIView, inheritedAlpha: CGFloat = 1, ancestorHidden: Bool = false) -> [String] {
        let opacity = CGFloat(view.layer.presentation()?.opacity ?? Float(view.alpha)) * inheritedAlpha
        let hidden = ancestorHidden || view.isHidden
        var result: [String] = []
        if let label = view as? UILabel, let text = label.text, !text.isEmpty {
            result.append("\(text):hidden=\(hidden),opacity=\(opacity),frame=\(NSCoder.string(for: label.convert(label.bounds, to: navigation?.view)))")
        }
        for child in view.subviews {
            result += labelStates(in: child, inheritedAlpha: opacity, ancestorHidden: hidden)
        }
        return result
    }
}

struct NavigationDiagnosticProbe: UIViewControllerRepresentable {
    let page: String
    func makeUIViewController(context: Context) -> NavigationDiagnosticController { .init(page: page) }
    func updateUIViewController(_ controller: NavigationDiagnosticController, context: Context) { controller.page = page }
}

final class NavigationDiagnosticController: UIViewController {
    var page: String
    init(page: String) { self.page = page; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = UIView(); view.isUserInteractionEnabled = false; view.backgroundColor = .clear }
    private func record(_ event: String) {
        if let navigationController { NavigationDiagnostics.recorder.attach(navigationController) }
        NavigationDiagnostics.event(event, page: page)
    }
    override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); record("probeAttached") }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); record("willAppear") }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); record("didAppear") }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); record("willDisappear") }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); record("didDisappear") }
}

extension View {
    @ViewBuilder func navigationDiagnostics(_ page: String) -> some View {
        if NavigationDiagnostics.isEnabled {
            background { NavigationDiagnosticProbe(page: page).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true) }
        } else {
            self
        }
    }
}

extension LibraryRoute {
    var diagnosticPage: String {
        switch self {
        case .album: "album"
        case .playlist: "playlist"
        case .artist: "artist"
        case .category(let category): "category.\(category)"
        case .downloadedCategory(let category): "downloaded.\(category)"
        case .playlistFolder: "playlistFolder"
        }
    }
}
