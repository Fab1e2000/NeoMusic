// 复刻自 NeoDizzy（同一作者的项目）Core/UI/NativeCollectionContextMenu.swift。
import SwiftUI
import UIKit

struct NativeMenuDrag {
    let identifier: String
    let preview: () -> UIImage?
}

struct NativeMenuDrop {
    let perform: (String) -> Void
}

extension View {
    /// 给卡片加上系统长按菜单与自定义预览；点按卡片或点按展开后的预览都会打开它。
    /// 菜单状态与之后弹出的表单仍由 SwiftUI 调用方持有。
    func nativeContextMenu(
        identity: String,
        menu: @escaping () -> UIMenu,
        preview: @escaping () -> AnyView,
        previewSize: CGSize,
        commit: @escaping (@escaping () -> UIView?) -> Void,
        tap: (() -> Void)? = nil,
        drag: NativeMenuDrag? = nil,
        drop: NativeMenuDrop? = nil
    ) -> some View {
        NativeContextMenu(
            content: self, identity: identity, menu: menu,
            preview: preview, previewSize: previewSize, commit: commit, tap: tap,
            drag: drag, drop: drop
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { commit({ nil }) }
    }
}

/// 用本地的承载容器给 UIKit 一个真实的交互表面，既不用遮挡 SwiftUI 按钮的覆盖层，
/// 也不把交互挂到无关的祖先视图上。
private struct NativeContextMenu<Content: View>: UIViewControllerRepresentable {
    typealias Controller = NativeContextMenuController
    let content: Content
    let identity: String
    let menu: () -> UIMenu
    let preview: () -> AnyView
    let previewSize: CGSize
    let commit: (@escaping () -> UIView?) -> Void
    /// 点按内容本身时执行；为空时与点按预览一样执行 `commit`。
    let tap: (() -> Void)?
    let drag: NativeMenuDrag?
    let drop: NativeMenuDrop?

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(
            content: AnyView(content.libraryHostedAppearance(context.environment)
                .environment(\.nativeArtworkSurfaceEnabled, context.environment.nativeArtworkSurfaceEnabled)),
            identity: identity, menu: menu, preview: preview,
            previewSize: previewSize, environment: context.environment, commit: commit, tap: tap,
            drag: drag, drop: drop
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: Controller, context: Context) -> CGSize? {
        uiViewController.contentSize(fitting: proposal.replacingUnspecifiedDimensions(by: UIView.layoutFittingExpandedSize))
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.invalidate()
    }

}

private final class NativeContextMenuController: UIViewController, UIContextMenuInteractionDelegate, UIDragInteractionDelegate, UIDropInteractionDelegate {
    private let hosting = UIHostingController(rootView: AnyView(EmptyView()))
    private lazy var interaction = UIContextMenuInteraction(delegate: self)
    private lazy var dragInteraction = UIDragInteraction(delegate: self)
    private lazy var dropInteraction = UIDropInteraction(delegate: self)
    private var drag: NativeMenuDrag?
    private var drop: NativeMenuDrop?
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(openCard))
    private var identity: String?
    private var revision = UUID()
    private var menu: () -> UIMenu = { UIMenu(children: []) }
    private var preview: () -> AnyView = { AnyView(EmptyView()) }
    private var previewSize = CGSize.zero
    private var environment = EnvironmentValues()
    private var commit: (@escaping () -> UIView?) -> Void = { _ in }
    private var tapAction: (() -> Void)?
    private var menuIsPresented = false

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        hosting.safeAreaRegions = []
        addChild(hosting)
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hosting.didMove(toParent: self)
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        view.addInteraction(interaction)
    }

    func update(content: AnyView, identity: String, menu: @escaping () -> UIMenu,
                preview: @escaping () -> AnyView, previewSize: CGSize,
                environment: EnvironmentValues, commit: @escaping (@escaping () -> UIView?) -> Void, tap: (() -> Void)?,
                drag: NativeMenuDrag?, drop: NativeMenuDrop?) {
        loadViewIfNeeded()
        self.drag = drag
        self.drop = drop
        dragInteraction.isEnabled = drag != nil
        if drag != nil, !view.interactions.contains(where: { $0 === dragInteraction }) { view.addInteraction(dragInteraction) }
        if drag == nil, view.interactions.contains(where: { $0 === dragInteraction }) { view.removeInteraction(dragInteraction) }
        if drop != nil, !view.interactions.contains(where: { $0 === dropInteraction }) { view.addInteraction(dropInteraction) }
        if drop == nil, view.interactions.contains(where: { $0 === dropInteraction }) { view.removeInteraction(dropInteraction) }
        if self.identity != identity {
            revision = UUID()
            interaction.dismissMenu()
            menuIsPresented = false
        }
        self.identity = identity
        self.menu = menu
        self.preview = preview
        self.previewSize = previewSize
        self.environment = environment
        self.commit = commit
        self.tapAction = tap
        hosting.rootView = content
        hosting.view.invalidateIntrinsicContentSize()
    }

    func contentSize(fitting size: CGSize) -> CGSize {
        hosting.sizeThatFits(in: size)
    }

    func invalidate() {
        identity = nil
        revision = UUID()
        menuIsPresented = false
        interaction.dismissMenu()
        view.removeInteraction(interaction)
        view.removeInteraction(dragInteraction)
        view.removeInteraction(dropInteraction)
        drag = nil
        drop = nil
        view.removeGestureRecognizer(tap)
        commit = { _ in }
        tapAction = nil
        menu = { UIMenu(children: []) }
        preview = { AnyView(EmptyView()) }
    }

    private struct LocalPlaylistDrag {
        let identifier: String
    }

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
        guard let drag else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider(object: drag.identifier as NSString))
        item.localObject = LocalPlaylistDrag(identifier: drag.identifier)
        if let image = drag.preview() {
            item.previewProvider = {
                let imageView = UIImageView(image: image)
                imageView.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
                let parameters = UIDragPreviewParameters()
                parameters.visiblePath = UIBezierPath(roundedRect: imageView.bounds, cornerRadius: 8)
                return UIDragPreview(view: imageView, parameters: parameters)
            }
        }
        return [item]
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        drop != nil && session.localDragSession != nil && session.items.contains { $0.localObject is LocalPlaylistDrag }
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: dropInteraction(interaction, canHandle: session) ? .move : .cancel)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: any UIDropSession) {
        if dropInteraction(interaction, canHandle: session) { view.backgroundColor = .tertiarySystemFill }
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) {
        view.backgroundColor = .clear
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) {
        view.backgroundColor = .clear
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        view.backgroundColor = .clear
        guard dropInteraction(interaction, canHandle: session), let drop else { return }
        for item in session.items {
            guard let payload = item.localObject as? LocalPlaylistDrag else { continue }
            drop.perform(payload.identifier)
        }
    }

    private func artworkSourceProvider() -> () -> UIView? {
        let identity = identity
        return { [weak self] in
            guard let self, let identity, self.identity == identity else { return nil }
            return self.viewIfLoaded?.libraryArtworkSource()
        }
    }

    @objc private func openCard() {
        NavigationDiagnostics.event("Card.tap", page: identity ?? "nil")
        guard identity != nil, !menuIsPresented else { return }
        if let tapAction { tapAction() } else { commit(artworkSourceProvider()) }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let identity else { return nil }
        let revision = revision
        let configuration = UIContextMenuConfiguration(identifier: revision.uuidString as NSString) { [weak self] in
            guard let self, self.identity == identity, self.revision == revision else { return nil }
            let content = self.preview()
                .libraryHostedAppearance(self.environment)
            let preview = UIHostingController(rootView: AnyView(content))
            preview.safeAreaRegions = []
            preview.preferredContentSize = self.previewSize
            preview.view.backgroundColor = .clear
            return preview
        } actionProvider: { [weak self] _ in
            guard let self, self.identity == identity, self.revision == revision else { return nil }
            return self.menu()
        }
        configuration.preferredMenuElementOrder = .fixed
        return configuration
    }

    private func sourcePreview(for configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard identity != nil, configuration.identifier as? String == revision.uuidString,
              hosting.view.window != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .systemBackground
        parameters.visiblePath = UIBezierPath(roundedRect: hosting.view.bounds, cornerRadius: 12)
        return UITargetedPreview(view: hosting.view, parameters: parameters)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        sourcePreview(for: configuration)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        sourcePreview(for: configuration)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                animator: (any UIContextMenuInteractionAnimating)?) {
        guard configuration.identifier as? String == revision.uuidString else { return }
        menuIsPresented = true
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                willEndFor configuration: UIContextMenuConfiguration,
                                animator: (any UIContextMenuInteractionAnimating)?) {
        let revision = revision
        guard configuration.identifier as? String == revision.uuidString else { return }
        if let animator {
            animator.addCompletion { [weak self] in
                guard self?.revision == revision else { return }
                self?.menuIsPresented = false
            }
        } else {
            menuIsPresented = false
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
                                animator: any UIContextMenuInteractionCommitAnimating) {
        let revision = revision
        guard let identity, configuration.identifier as? String == revision.uuidString else { return }
        animator.preferredCommitStyle = .dismiss
        let commit = self.commit
        let sourceProvider = artworkSourceProvider()
        animator.addCompletion { [weak self] in
            guard self?.identity == identity, self?.revision == revision else { return }
            commit(sourceProvider)
        }
    }
}
