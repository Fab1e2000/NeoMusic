// Source: NeoDizzy Features/Player/MiniPlayerTitlePager.swift; see Resources/PlayerSourceNotices.txt.
import SwiftUI
import UIKit

/// Native paging only owns the title slot. Artwork and transport controls stay put.
struct ReferenceMiniPlayerTitlePager<Content: View>: UIViewRepresentable {
    var height: CGFloat = 36
    let song: ReferenceTrack
    let currentIndex: Int
    let previous: ReferenceUpcomingTrack?
    let next: ReferenceUpcomingTrack?
    let select: (Int) -> Void
    @ViewBuilder let content: (ReferenceTrack, Bool) -> Content

    struct Page { let track: ReferenceTrack; let index: Int }
    var pages: [Page] {
        [previous.map { Page(track: $0.track, index: $0.index) },
         Page(track: song, index: currentIndex),
         next.map { Page(track: $0.track, index: $0.index) }].compactMap { $0 }
    }
    var center: Int { previous == nil ? 0 : 1 }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PagerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PagerView {
        let view = PagerView()
        view.delegate = context.coordinator
        context.coordinator.view = view
        view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.layout() }
        context.coordinator.update(self)
        return view
    }
    func updateUIView(_ view: PagerView, context: Context) { context.coordinator.update(self) }

    final class PagerView: UIScrollView {
        var onLayout: (() -> Void)?
        private let edgeMask = CAGradientLayer()
        init() {
            super.init(frame: .zero)
            isPagingEnabled = true
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false
            contentInsetAdjustmentBehavior = .never
            alwaysBounceVertical = false
            alwaysBounceHorizontal = true
            isDirectionalLockEnabled = true
            backgroundColor = .clear
            edgeMask.startPoint = CGPoint(x: 0, y: 0.5)
            edgeMask.endPoint = CGPoint(x: 1, y: 0.5)
            layer.mask = edgeMask
            panGestureRecognizer.name = "NeoDizzy.NowPlayingTrackSwipe"
        }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
            updateEdgeMask()
        }

        private func updateEdgeMask() {
            guard bounds.width > 0 else { return }
            // Fade only between pages. Resting text keeps its full leading glyph.
            // The mask follows the viewport bounds, not the scrolling page content.
            let width = bounds.width
            let distance = abs(contentOffset.x - (contentOffset.x / width).rounded() * width)
            let fadeWidth = min(CGFloat(10), width / 4)
            let strength = min(distance / fadeWidth, 1)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            edgeMask.frame = bounds
            edgeMask.locations = [0, NSNumber(value: Double(fadeWidth / width)),
                                  NSNumber(value: Double(1 - fadeWidth / width)), 1]
            edgeMask.colors = [UIColor.black.withAlphaComponent(1 - strength).cgColor,
                               UIColor.black.cgColor, UIColor.black.cgColor,
                               UIColor.black.withAlphaComponent(1 - strength).cgColor]
            CATransaction.commit()
        }
        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === panGestureRecognizer {
                let velocity = panGestureRecognizer.velocity(in: self)
                guard abs(velocity.x) > abs(velocity.y) * 1.25 else { return false }
            }
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var latest: ReferenceMiniPlayerTitlePager
        weak var view: PagerView?
        private var hosts: [UIHostingController<Content>] = []
        private var displayed: [Page] = []
        private var displayedIndex: Int?
        private var displayedID: ReferenceTrack.ID?
        private var center = 0
        private var moving = false
        var selectionFeedback: () -> Void = { ReferenceTrackSwipeFeedback.selection() }
        private var didGiveSelectionFeedback = false
        private var layingOut = false
        private var size: CGSize = .zero

        init(_ latest: ReferenceMiniPlayerTitlePager) { self.latest = latest }
        func update(_ value: ReferenceMiniPlayerTitlePager) {
            latest = value
            // Freeze neighbors during a gesture; external track changes cancel it.
            if moving, displayedIndex == value.currentIndex, displayedID == value.song.id { return }
            if moving {
                view?.setContentOffset(view?.contentOffset ?? .zero, animated: false)
                view?.panGestureRecognizer.isEnabled = false
                view?.panGestureRecognizer.isEnabled = true
                moving = false
            }
            displayed = value.pages
            displayedIndex = value.currentIndex
            displayedID = value.song.id
            center = value.center
            while hosts.count > displayed.count { hosts.removeLast().view.removeFromSuperview() }
            for (index, page) in displayed.enumerated() {
                let root = value.content(page.track, index == center)
                if index < hosts.count { hosts[index].rootView = root }
                else {
                    let host = UIHostingController(rootView: root)
                    host.safeAreaRegions = []
                    host.view.backgroundColor = .clear
                    hosts.append(host)
                    view?.addSubview(host.view)
                }
            }
            layout(recenter: true)
        }
        func layout(recenter: Bool = false) {
            guard let view, !layingOut, view.bounds.width > 0 else { return }
            layingOut = true
            defer { layingOut = false }
            let resized = size != view.bounds.size
            size = view.bounds.size
            // Page geometry is bookkeeping; only the scroll view animates a swipe.
            UIView.performWithoutAnimation {
                view.contentSize = CGSize(width: size.width * CGFloat(hosts.count), height: size.height)
                for (index, host) in hosts.enumerated() {
                    host.view.frame = CGRect(x: CGFloat(index) * size.width, y: 0, width: size.width, height: size.height)
                }
                if recenter || (resized && !moving) {
                    view.setContentOffset(CGPoint(x: CGFloat(center) * size.width, y: 0), animated: false)
                }
                for host in hosts { host.view.layoutIfNeeded() }
            }
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            moving = true
            didGiveSelectionFeedback = false
            for (index, host) in hosts.enumerated() { host.rootView = latest.content(displayed[index].track, false) }
        }
        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                       targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            guard moving, scrollView.bounds.width > 0 else { return }
            let page = Int((targetContentOffset.pointee.x / scrollView.bounds.width).rounded())
            // Match the fullscreen gesture: acknowledge the chosen page at release,
            // before the settling animation, instead of after deceleration finishes.
            if validTarget(at: page) != nil { giveSelectionFeedback() }
        }
        private func validTarget(at page: Int) -> Page? {
            guard displayed.indices.contains(page), page != center else { return nil }
            let target = displayed[page]
            guard target.index != latest.currentIndex,
                  latest.pages.contains(where: { $0.index == target.index && $0.track.id == target.track.id }) else { return nil }
            return target
        }
        private func giveSelectionFeedback() {
            guard !didGiveSelectionFeedback else { return }
            didGiveSelectionFeedback = true
            selectionFeedback()
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { settle() }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
        private func settle() {
            guard let view, moving, view.bounds.width > 0 else { return }
            let page = min(max(Int((view.contentOffset.x / view.bounds.width).rounded()), 0), displayed.count - 1)
            moving = false
            guard displayed.indices.contains(page), page != center else { update(latest); return }
            // The landed title is already visible. The next update rebuilds its
            // neighbors and recenters without animation, retaining that same title.
            guard let target = validTarget(at: page) else { update(latest); return }
            giveSelectionFeedback()
            latest.select(target.index)
        }
    }
}
