import SwiftUI
import UIKit
import MetalKit

enum PlayerEDRRole { case artist, subtitle, queueArtist, controls, buttons }
struct PlayerEDRLevels: Equatable {
    var artist = 0.35
    var subtitle = 0.35
    var queueArtist = 0.35
    var controls = 0.25
    var buttons = 0.25
    func value(for role: PlayerEDRRole) -> Double {
        switch role {
        case .artist: artist
        case .subtitle: subtitle
        case .queueArtist: queueArtist
        case .controls: controls
        case .buttons: buttons
        }
    }
}

extension EnvironmentValues {
    @Entry var playerArtistEDREnabled = true
    @Entry var playerEDRLevels = PlayerEDRLevels()
}

/// Experimental EDR variant: samples the same generated background image used by
/// the player at the glyph's position. It does not capture the screen.
struct PlayerEDRArtistLabel: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let image: UIImage?
    let anchor: NowPlayingBackdropAnchor?
    let brightness: Double
    var isWhite = false
    var fontWeight: UIFont.Weight = .regular
    @Environment(\.playerVisualsActive) private var visualsActive

    func makeUIView(context: Context) -> PlayerEDRGlyphView { PlayerEDRGlyphView() }
    func updateUIView(_ view: PlayerEDRGlyphView, context: Context) {
        view.setRenderingActive(visualsActive)
        view.update(text: text, fontSize: fontSize, image: image, anchor: anchor, brightness: brightness, isWhite: isWhite, fontWeight: fontWeight)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PlayerEDRGlyphView, context: Context) -> CGSize? {
        let font = UIFont.systemFont(ofSize: fontSize)
        return CGSize(width: proposal.width ?? (text as NSString).size(withAttributes: [.font: font]).width,
                      height: font.lineHeight)
    }
    static func dismantleUIView(_ view: PlayerEDRGlyphView, coordinator: ()) { view.stop() }
}

enum PlayerEDRMask: Equatable {
    case symbol(String, CGFloat, CGFloat)
    case circle(CGFloat)
    case time(String, Bool)
}

/// Metal objects are immutable after preparation and Metal supports their use across threads.
final class PlayerEDRMetalResources: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let loader: MTKTextureLoader

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        self.device = device
        self.queue = queue
        loader = MTKTextureLoader(device: device)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "playerEDRVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "playerEDRFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.pipeline = pipeline
    }
}

@MainActor @Observable
final class PlayerEDRResources {
    static let shared = PlayerEDRResources()
    private(set) var resources: PlayerEDRMetalResources?
    @ObservationIgnored private var preparation: Task<PlayerEDRMetalResources?, Never>?
    var isReady: Bool { resources != nil }

    func prepare() async {
        guard resources == nil else { return }
        let task: Task<PlayerEDRMetalResources?, Never>
        if let preparation { task = preparation }
        else {
            task = Task.detached(priority: .userInitiated) { PlayerEDRMetalResources() }
            preparation = task
        }
        resources = await task.value
    }
}

final class PlayerEDRGlyphView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let resources = PlayerEDRResources.shared.resources
    private var text = ""
    private var fontSize: CGFloat = 20
    private var brightness: Float = 0.7
    private var isWhite = false
    private var fontWeight: UIFont.Weight = .regular
    private var shape: PlayerEDRMask?
    private var image: UIImage?
    private weak var anchor: NowPlayingBackdropAnchor?
    private var displayLink: CADisplayLink?
    private(set) var isRenderingActive = false
    var hasActiveDisplayLink: Bool { displayLink?.isPaused == false }
    private var lastRect = CGRect.null
    private var dirty = true
    private var lastLayout: LayoutInput?

    private struct LayoutInput: Equatable {
        let bounds: CGRect
        let scale: CGFloat
        let traits: UITraitCollection
    }

    private struct MaskInput: Equatable {
        let text: String
        let fontSize: CGFloat
        let fontWeight: UIFont.Weight
        let isWhite: Bool
        let shape: PlayerEDRMask?
        let bounds: CGRect
        let scale: CGFloat
        let traits: UITraitCollection
        let currentTraits: UITraitCollection
    }

    private var cachedMask: (input: MaskInput, texture: MTLTexture)?
    private var cachedBackdrop: (image: CGImage, texture: MTLTexture)?

    @MainActor private final class DisplayProxy: NSObject {
        weak var view: PlayerEDRGlyphView?
        init(_ view: PlayerEDRGlyphView) { self.view = view }
        @objc func tick() { view?.renderIfNeeded() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        guard let resources else { return }
        metalLayer.device = resources.device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.isOpaque = false
    }
    required init?(coder: NSCoder) { nil }

    func update(text: String, fontSize: CGFloat, image: UIImage?, anchor: NowPlayingBackdropAnchor?, brightness: Double, isWhite: Bool, fontWeight: UIFont.Weight) {
        guard self.text != text || self.fontSize != fontSize || self.image !== image || self.anchor !== anchor
                || self.brightness != Float(brightness) || self.isWhite != isWhite || self.fontWeight != fontWeight
                || shape != nil else { return }
        let wasWhite = self.isWhite
        dirty = true
        self.text = text; self.fontSize = fontSize; self.image = image; self.anchor = anchor; self.brightness = Float(brightness); self.isWhite = isWhite; self.fontWeight = fontWeight
        shape = nil
        if wasWhite != isWhite { updateDisplayLink() }
        setNeedsLayout()
    }
    func update(shape: PlayerEDRMask, image: UIImage?, anchor: NowPlayingBackdropAnchor?, brightness: Double) {
        guard self.shape != shape || self.image !== image || self.anchor !== anchor
                || self.brightness != Float(brightness) else { return }
        let wasWhite = isWhite
        dirty = true
        self.shape = shape; self.image = image; self.anchor = anchor; self.brightness = Float(brightness); self.isWhite = false
        if wasWhite { updateDisplayLink() }
        setNeedsLayout()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        stop()
        dirty = true
        updateDisplayLink()
        setNeedsLayout()
    }
    func setRenderingActive(_ active: Bool) {
        guard isRenderingActive != active else { return }
        isRenderingActive = active
        updateDisplayLink()
        if active { dirty = true; renderIfNeeded() }
    }
    private func updateDisplayLink() {
        // White EDR glyphs have position-independent pixels. Core Animation moves
        // their existing layer; text, layout and visibility updates redraw it.
        guard !isWhite else { stop(); return }
        guard window != nil, resources != nil else { return }
        if displayLink == nil, isRenderingActive {
            let link = CADisplayLink(target: DisplayProxy(self), selector: #selector(DisplayProxy.tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = !isRenderingActive
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let layout = LayoutInput(bounds: bounds, scale: window?.screen.scale ?? traitCollection.displayScale,
                                 traits: traitCollection)
        if lastLayout != layout {
            lastLayout = layout
            dirty = true
        }
        renderIfNeeded()
    }
    func stop() { displayLink?.invalidate(); displayLink = nil }

    private func renderIfNeeded() {
        guard isRenderingActive, let resources, let window,
              let image = image?.cgImage, bounds.width > 0, bounds.height > 0 else { return }
        let rect: CGRect
        var uv: SIMD4<Float>
        if isWhite {
            // White glyphs do not sample the backdrop's position and can render
            // before the backdrop anchor finishes its first layout.
            rect = .zero
            uv = .zero
        } else {
            guard let source = anchor?.view, source.window === window,
                  source.bounds.width > 0, source.bounds.height > 0 else { return }
            rect = source.convert(bounds, from: self)
            uv = SIMD4<Float>(Float(rect.minX / source.bounds.width), Float(rect.minY / source.bounds.height),
                              Float(rect.width / source.bounds.width), Float(rect.height / source.bounds.height))
        }
        guard dirty || (!isWhite && rect != lastRect) else { return }
        dirty = false
        lastRect = rect
        let scale = window.screen.scale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard let textures = preparedTextures(backdrop: image, scale: scale),
              let drawable = metalLayer.nextDrawable(), let command = resources.queue.makeCommandBuffer() else { dirty = true; return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { dirty = true; return }
        encoder.setRenderPipelineState(resources.pipeline)
        encoder.setFragmentTexture(textures.mask, index: 0)
        encoder.setFragmentTexture(textures.backdrop, index: 1)
        encoder.setFragmentBytes(&uv, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        var options = SIMD2<Float>(brightness, isWhite ? 1 : 0)
        encoder.setFragmentBytes(&options, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding(); command.present(drawable); command.commit()
    }

    /// Keep the current view's pixels while position and brightness continue to update every draw.
    func preparedTextures(backdrop: CGImage, scale: CGFloat) -> (mask: MTLTexture, backdrop: MTLTexture)? {
        guard let resources, bounds.width > 0, bounds.height > 0 else { return nil }
        let input = MaskInput(text: text, fontSize: fontSize, fontWeight: fontWeight, isWhite: isWhite,
                              shape: shape, bounds: bounds, scale: scale, traits: traitCollection,
                              currentTraits: UITraitCollection.current)
        let maskTexture: MTLTexture
        if let cachedMask, cachedMask.input == input {
            maskTexture = cachedMask.texture
        } else {
            guard let cgMask = makeMask(scale: scale).cgImage,
                  let texture = try? resources.loader.newTexture(cgImage: cgMask, options: [.SRGB: false]) else { return nil }
            cachedMask = (input, texture)
            maskTexture = texture
        }
        let backdropTexture: MTLTexture
        if let cachedBackdrop, cachedBackdrop.image === backdrop {
            backdropTexture = cachedBackdrop.texture
        } else {
            guard let texture = try? resources.loader.newTexture(cgImage: backdrop, options: [.SRGB: true]) else { return nil }
            cachedBackdrop = (backdrop, texture)
            backdropTexture = texture
        }
        return (maskTexture, backdropTexture)
    }

    private func makeMask(scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale; format.opaque = false; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { _ in
            if let shape {
                switch shape {
                case let .symbol(name, size, alpha):
                    let config = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
                    if let symbol = UIImage(systemName: name, withConfiguration: config)?.withTintColor(.white.withAlphaComponent(alpha), renderingMode: .alwaysOriginal) {
                        let rect = CGRect(x: (bounds.width - symbol.size.width) / 2, y: (bounds.height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height)
                        symbol.draw(in: rect)
                    }
                case let .circle(diameter):
                    UIColor.white.withAlphaComponent(0.68).setFill()
                    UIBezierPath(ovalIn: CGRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)).fill()
                case let .time(value, rightAligned):
                    let label = UILabel(frame: bounds)
                    label.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
                    label.text = value
                    label.textAlignment = rightAligned ? .right : .left
                    label.textColor = .white.withAlphaComponent(0.5)
                    label.drawText(in: bounds)
                }
            } else {
                let label = UILabel(frame: bounds)
                label.text = text
                let base = UIFont.systemFont(ofSize: fontSize, weight: fontWeight)
                label.font = fontSize == 20 ? base : UIFontMetrics(forTextStyle: isWhite ? .headline : (fontSize == 13 ? .footnote : .subheadline)).scaledFont(for: base, compatibleWith: traitCollection)
                label.textColor = .white
                label.numberOfLines = 1
                label.lineBreakMode = .byTruncatingTail
                label.drawText(in: bounds)
            }
        }
    }
}
