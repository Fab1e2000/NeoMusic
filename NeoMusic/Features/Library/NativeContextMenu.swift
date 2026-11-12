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
        previewSize: @escaping @MainActor (UITraitCollection) -> CGSize,
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
private struct NativeContextMenu<Content: View>: UIViewRepresentable {
    typealias Surface = NativeContextMenuView
    let content: Content
    let identity: String
    let menu: () -> UIMenu
    let preview: () -> AnyView
    let previewSize: @MainActor (UITraitCollection) -> CGSize
    let commit: (@escaping () -> UIView?) -> Void
    /// 点按内容本身时执行；为空时与点按预览一样执行 `commit`。
    let tap: (() -> Void)?
    let drag: NativeMenuDrag?
    let drop: NativeMenuDrop?

    func makeUIView(context: Context) -> Surface { Surface() }

    func updateUIView(_ view: Surface, context: Context) {
        view.update(
            content: AnyView(content.libraryHostedAppearance(context.environment)
                .environment(\.nativeArtworkSurfaceEnabled, context.environment.nativeArtworkSurfaceEnabled)),
            identity: identity, menu: menu, preview: preview,
            previewSize: previewSize, environment: context.environment, commit: commit, tap: tap,
            drag: drag, drop: drop
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Surface, context: Context) -> CGSize? {
        uiView.contentSize(fitting: proposal.replacingUnspecifiedDimensions(by: UIView.layoutFittingExpandedSize))
    }

    static func dismantleUIView(_ view: Surface, coordinator: ()) {
        view.invalidate()
    }

}

private final class NativeContextMenuView: UIView, UIContextMenuInteractionDelegate, UIDragInteractionDelegate, UIDropInteractionDelegate {
    private let hosted = UIHostingConfiguration { AnyView(EmptyView()) }.margins(.all, 0).makeContentView()
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
    private var previewSize: @MainActor (UITraitCollection) -> CGSize = { _ in .zero }
    private var environment = EnvironmentValues()
    private var commit: (@escaping () -> UIView?) -> Void = { _ in }
    private var tapAction: (() -> Void)?
    private var menuIsPresented = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        hosted.backgroundColor = .clear
        hosted.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosted.topAnchor.constraint(equalTo: topAnchor),
            hosted.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
        addInteraction(interaction)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(content: AnyView, identity: String, menu: @escaping () -> UIMenu,
                preview: @escaping () -> AnyView, previewSize: @escaping @MainActor (UITraitCollection) -> CGSize,
                environment: EnvironmentValues, commit: @escaping (@escaping () -> UIView?) -> Void, tap: (() -> Void)?,
                drag: NativeMenuDrag?, drop: NativeMenuDrop?) {
        self.drag = drag
        self.drop = drop
        dragInteraction.isEnabled = drag != nil
        if drag != nil, !interactions.contains(where: { $0 === dragInteraction }) { addInteraction(dragInteraction) }
        if drag == nil, interactions.contains(where: { $0 === dragInteraction }) { removeInteraction(dragInteraction) }
        if drop != nil, !interactions.contains(where: { $0 === dropInteraction }) { addInteraction(dropInteraction) }
        if drop == nil, interactions.contains(where: { $0 === dropInteraction }) { removeInteraction(dropInteraction) }
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
        hosted.configuration = UIHostingConfiguration { content }.margins(.all, 0)
        hosted.invalidateIntrinsicContentSize()
    }

    func contentSize(fitting size: CGSize) -> CGSize {
        hosted.systemLayoutSizeFitting(CGSize(width: size.width, height: UIView.layoutFittingCompressedSize.height),
                                      withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
    }

    func invalidate() {
        identity = nil
        revision = UUID()
        menuIsPresented = false
        interaction.dismissMenu()
        removeInteraction(interaction)
        removeInteraction(dragInteraction)
        removeInteraction(dropInteraction)
        drag = nil
        drop = nil
        removeGestureRecognizer(tap)
        commit = { _ in }
        tapAction = nil
        menu = { UIMenu(children: []) }
        preview = { AnyView(EmptyView()) }
        previewSize = { _ in .zero }
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
        if dropInteraction(interaction, canHandle: session) { backgroundColor = .tertiarySystemFill }
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) {
        backgroundColor = .clear
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) {
        backgroundColor = .clear
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        backgroundColor = .clear
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
            return self.libraryArtworkSource()
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
            let traits = self.traitCollection.modifyingTraits {
                $0.preferredContentSizeCategory = UIContentSizeCategory(self.environment.dynamicTypeSize)
            }
            let preview = UIHostingController(rootView: AnyView(content))
            preview.traitOverrides.preferredContentSizeCategory = traits.preferredContentSizeCategory
            preview.safeAreaRegions = []
            preview.preferredContentSize = self.previewSize(traits)
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
              hosted.window != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .systemBackground
        parameters.visiblePath = UIBezierPath(roundedRect: hosted.bounds, cornerRadius: 12)
        return UITargetedPreview(view: hosted, parameters: parameters)
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
