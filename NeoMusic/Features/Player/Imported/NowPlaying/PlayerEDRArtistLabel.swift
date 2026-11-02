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

    func makeUIView(context: Context) -> PlayerEDRGlyphView { PlayerEDRGlyphView() }
    func updateUIView(_ view: PlayerEDRGlyphView, context: Context) {
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

@MainActor
private final class PlayerEDRMetalResources {
    private static var cached: PlayerEDRMetalResources?

    static func shared() -> PlayerEDRMetalResources? {
        if let cached { return cached }
        guard let resources = PlayerEDRMetalResources() else { return nil }
        cached = resources
        return resources
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let loader: MTKTextureLoader

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        loader = MTKTextureLoader(device: device)
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct Varying { float4 position [[position]]; float2 uv; };
        vertex Varying vertexMain(uint id [[vertex_id]]) {
            float2 p[] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
            float2 uv[] = { float2(0,1), float2(1,1), float2(0,0), float2(1,0) };
            return { float4(p[id], 0, 1), uv[id] };
        }
        fragment float4 fragmentMain(Varying in [[stage_in]], texture2d<float> mask [[texture(0)]], texture2d<float> backdrop [[texture(1)]], constant float4 &rect [[buffer(0)]], constant float2 &options [[buffer(1)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float a = mask.sample(s, in.uv).a;
            float3 background = backdrop.sample(s, rect.xy + in.uv * rect.zw).rgb;
            float3 color = options.y > 0.5 ? float3(1.0) : float3(1.0) + background * 0.65;
            return float4(color * (2.0 * options.x) * a, a);
        }
        """
        do {
            let lib = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = lib.makeFunction(name: "vertexMain")
            descriptor.fragmentFunction = lib.makeFunction(name: "fragmentMain")
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("Player EDR pipeline unavailable: \(error)")
            return nil
        }
    }
}

final class PlayerEDRGlyphView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let resources = PlayerEDRMetalResources.shared()
    private var text = ""
    private var fontSize: CGFloat = 20
    private var brightness: Float = 0.7
    private var isWhite = false
    private var fontWeight: UIFont.Weight = .regular
    private var shape: PlayerEDRMask?
    private var image: UIImage?
    private weak var anchor: NowPlayingBackdropAnchor?
    private var displayLink: CADisplayLink?
    private var lastRect = CGRect.null
    private var dirty = true

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
        if self.text != text || self.fontSize != fontSize || self.image !== image || self.anchor !== anchor || self.brightness != Float(brightness) || self.isWhite != isWhite || self.fontWeight != fontWeight { dirty = true }
        self.text = text; self.fontSize = fontSize; self.image = image; self.anchor = anchor; self.brightness = Float(brightness); self.isWhite = isWhite; self.fontWeight = fontWeight
        shape = nil
        setNeedsLayout()
    }
    func update(shape: PlayerEDRMask, image: UIImage?, anchor: NowPlayingBackdropAnchor?, brightness: Double) {
        if self.shape != shape || self.image !== image || self.anchor !== anchor || self.brightness != Float(brightness) { dirty = true }
        self.shape = shape; self.image = image; self.anchor = anchor; self.brightness = Float(brightness); self.isWhite = false
        setNeedsLayout()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        stop()
        if window != nil {
            let link = CADisplayLink(target: DisplayProxy(self), selector: #selector(DisplayProxy.tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
            dirty = true
        }
    }
    override func layoutSubviews() { super.layoutSubviews(); dirty = true; renderIfNeeded() }
    func stop() { displayLink?.invalidate(); displayLink = nil }

    private func renderIfNeeded() {
        guard let resources, let window,
              let source = anchor?.view, source.window === window,
              let image = image?.cgImage, bounds.width > 0, bounds.height > 0,
              source.bounds.width > 0, source.bounds.height > 0 else { return }
        let rect = source.convert(bounds, from: self)
        guard dirty || rect != lastRect else { return }
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
        var uv = SIMD4<Float>(Float(rect.minX / source.bounds.width), Float(rect.minY / source.bounds.height),
                              Float(rect.width / source.bounds.width), Float(rect.height / source.bounds.height))
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
