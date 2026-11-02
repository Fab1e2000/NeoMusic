import SwiftUI
import UIKit

/// An opaque base plus a single fading overlay. No layer fades out to the black underlay.
struct NowPlayingBackdropImage: UIViewRepresentable {
    let image: UIImage
    var animated = true

    func makeUIView(context: Context) -> CrossfadeView { CrossfadeView() }
    func updateUIView(_ view: CrossfadeView, context: Context) {
        view.setImage(image, animated: animated)
    }
    static func dismantleUIView(_ view: CrossfadeView, coordinator: ()) { view.stop() }

    final class CrossfadeView: UIView {
        private let base = UIImageView()
        private let overlay = UIImageView()
        private var target: UIImage?
        private var animator: UIViewPropertyAnimator?

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            clipsToBounds = true
            for imageView in [base, overlay] {
                imageView.contentMode = .scaleToFill
                imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                addSubview(imageView)
            }
            overlay.alpha = 0
        }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() {
            super.layoutSubviews()
            base.frame = bounds
            overlay.frame = bounds
        }

        func setImage(_ image: UIImage, animated: Bool) {
            if target === image {
                if !animated { settle(image) }
                return
            }
            // Fast successive skips start from the currently visible composite,
            // rather than jumping to either endpoint of the interrupted fade.
            let visible = currentComposite()
            stop()
            target = image
            guard animated, let visible else {
                settle(image)
                return
            }
            base.image = visible
            base.alpha = 1
            overlay.image = image
            overlay.alpha = 0
            let transition = UIViewPropertyAnimator(duration: 0.6, curve: .easeInOut) {
                self.overlay.alpha = 1
            }
            transition.addCompletion { [weak self] position in
                guard let self, position == .end, self.target === image else { return }
                self.settle(image)
            }
            animator = transition
            transition.startAnimation()
        }

        private func currentComposite() -> UIImage? {
            guard let bottom = base.image else { return nil }
            guard animator != nil, let top = overlay.image else { return bottom }
            let alpha = CGFloat(overlay.layer.presentation()?.opacity ?? Float(overlay.alpha))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            // Backdrops are tiny palette rasters, not screen-sized snapshots.
            return UIGraphicsImageRenderer(size: bottom.size, format: format).image { _ in
                let rect = CGRect(origin: .zero, size: bottom.size)
                bottom.draw(in: rect)
                top.draw(in: rect, blendMode: .normal, alpha: alpha)
            }
        }

        private func settle(_ image: UIImage) {
            stop()
            base.image = image
            base.alpha = 1
            overlay.image = nil
            overlay.alpha = 0
        }

        func stop() {
            animator?.stopAnimation(true)
            animator = nil
        }
    }
}
