import SwiftUI
import UIKit

/// UIKit conversion crosses UIHostingConfiguration roots without publishing window
/// movement into SwiftUI. Both ends move together during popup dismissal.
@MainActor
final class NowPlayingBackdropAnchor {
    weak var view: UIView?
    private let readers = NSHashTable<NowPlayingAlignedBackdrop.AlignedView>.weakObjects()

    func register(_ reader: NowPlayingAlignedBackdrop.AlignedView) { readers.add(reader) }
    func refresh() { for reader in readers.allObjects { reader.align() } }
}

struct NowPlayingBackdropAnchorView: UIViewRepresentable {
    let anchor: NowPlayingBackdropAnchor
    func makeUIView(context: Context) -> AnchorView { AnchorView(anchor: anchor) }
    func updateUIView(_ view: AnchorView, context: Context) {}

    final class AnchorView: UIView {
        let anchor: NowPlayingBackdropAnchor
        init(anchor: NowPlayingBackdropAnchor) {
            self.anchor = anchor
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            anchor.view = self
        }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() { super.layoutSubviews(); anchor.refresh() }
        override func didMoveToWindow() { super.didMoveToWindow(); anchor.refresh() }
    }
}

struct NowPlayingAlignedBackdrop: UIViewRepresentable {
    let image: UIImage
    let anchor: NowPlayingBackdropAnchor
    let animated: Bool

    func makeUIView(context: Context) -> AlignedView { AlignedView(anchor: anchor) }
    func updateUIView(_ view: AlignedView, context: Context) {
        view.imageView.setImage(image, animated: animated)
        view.align()
    }
    static func dismantleUIView(_ view: AlignedView, coordinator: ()) { view.imageView.stop() }

    final class AlignedView: UIView {
        let imageView = NowPlayingBackdropImage.CrossfadeView()
        let anchor: NowPlayingBackdropAnchor
        init(anchor: NowPlayingBackdropAnchor) {
            self.anchor = anchor
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            clipsToBounds = true
            addSubview(imageView)
            anchor.register(self)
        }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() { super.layoutSubviews(); align() }
        override func didMoveToWindow() { super.didMoveToWindow(); align() }
        func align() {
            guard let source = anchor.view, let window, source.window === window else { return }
            let frame = source.convert(source.bounds, to: self)
            if imageView.frame != frame { imageView.frame = frame }
        }
    }
}
