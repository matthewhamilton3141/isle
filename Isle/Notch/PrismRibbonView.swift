//
//  PrismRibbonView.swift
//
//  Prism's ribbon (see IslandPrism.swift): a streak of light along the
//  lens's lip, split into a spectrum whose fan at each point across the
//  panel is the music's level in one band.
//
//  Drawn by a small Metal shader into a layer of its own, outside the view
//  graph, for the same reason the bars are Core Animation
//  (EqualizerLayer.swift): levels arrive thirty times a second, and nothing
//  about them should pass through SwiftUI. The view subscribes to the
//  capture itself. Unlike the bars, the ribbon isn't a handful of
//  rectangles — every pixel of it is a sum over the spectrum — so it is a
//  shader rather than layers, and it draws a frame only while a band is
//  still moving: silent or paused it settles in a few frames and then costs
//  nothing until the next level arrives. While the island is closed, black
//  in every mode, it is told so and rests the same way.
//
//  The light mostly covers what's under it rather than adding to it
//  (`IslandPrism.ribbonCover`), and lies on a soft bed of shade
//  (`ribbonBed`): light added to a white window would be nothing, and the
//  lip is all but bare glass.
//

import AppKit
import Combine
import Metal
import QuartzCore
import SwiftUI

// MARK: - The shader

/// The pipeline, built once and shared by every ribbon: one full-strip
/// triangle and the fragment function below.
final class PrismRibbonRenderer {
    /// Nil where there's no Metal device, or the shader didn't build; the
    /// ribbon is then simply not drawn.
    static let shared = PrismRibbonRenderer()

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    /// What the shader is told about one frame.
    struct Frame {
        /// The strip's size in points.
        var size: CGSize
        /// The ribbon's centre line, in points above the strip's bottom.
        var centre: CGFloat
        /// The fan's half-height and the brightness across the ribbon,
        /// `IslandPrism.ribbonColumns` of each.
        var spread: [Float]
        var glow: [Float]
    }

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.source, options: nil)
        } catch {
            NSLog("Isle: Prism's ribbon shader didn't build: \(error)")
            return nil
        }
        guard let vertex = library.makeFunction(name: "prismVertex"),
              let fragment = library.makeFunction(name: "prismFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    /// Draws `frame` into `texture`, then presents `drawable` if there is
    /// one. `wait` blocks until the GPU is done, for a caller that reads
    /// the texture back.
    func draw(_ frame: Frame, into texture: MTLTexture, presenting drawable: MTLDrawable? = nil, wait: Bool = false) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = Self.uniforms(frame)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: uniforms.count * MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        if let drawable { buffer.present(drawable) }
        buffer.commit()
        if wait { buffer.waitUntilCompleted() }
    }

    /// The frame laid out as the shader's `Uniforms`: eight floats of
    /// header, then the two profiles.
    private static func uniforms(_ frame: Frame) -> [Float] {
        let n = IslandPrism.ribbonColumns
        var u = [Float](repeating: 0, count: 8 + 2 * n)
        u[0] = Float(frame.size.width)
        u[1] = Float(frame.size.height)
        u[2] = Float(frame.centre)
        u[3] = Float(IslandPrism.restSigma)
        u[4] = Float(IslandPrism.sigmaPerSpread)
        u[5] = Float(IslandPrism.ribbonCover)
        u[6] = Float(IslandPrism.ribbonBed)
        for k in 0..<n {
            u[8 + k] = k < frame.spread.count ? frame.spread[k] : 0
            u[8 + n + k] = k < frame.glow.count ? frame.glow[k] : 0
        }
        return u
    }

    /// Built at first use rather than shipped as a .metallib, so the render
    /// harnesses, which compile the sources with swiftc alone, draw the
    /// same ribbon the app does.
    ///
    /// For each pixel: where it is across the ribbon gives the fan's
    /// half-height `s` and the brightness `g` (interpolated from the
    /// profile); how far it is above the centre line gives, for each of
    /// sixteen colours across the spectrum, how much of that colour's
    /// Gaussian reaches it — red centred `s` above the line, violet `s`
    /// below. The sum is divided by the spectrum's own sum, so with no fan
    /// the colours coincide as white. Over that, a narrow white core on the
    /// line itself, and a wide faint halo in the local colour.
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 size;
        float centre;
        float sigma;
        float sigmaPerSpread;
        float cover;
        float bed;
        float pad;
        float spread[\(IslandPrism.ribbonColumns)];
        float glow[\(IslandPrism.ribbonColumns)];
    };

    struct Varyings {
        float4 position [[position]];
        float2 uv;
    };

    vertex Varyings prismVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        Varyings out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(p.x, 1.0 - p.y);
        return out;
    }

    // The spectrum, 0 red (drawn uppermost) to 1 violet: piecewise linear
    // through eight colours, lighter and less green than a true rainbow.
    static float3 spectrum(float t) {
        const float3 c[8] = {
            float3(1.00, 0.16, 0.20),
            float3(1.00, 0.45, 0.10),
            float3(1.00, 0.80, 0.22),
            float3(0.62, 1.00, 0.55),
            float3(0.18, 0.90, 1.00),
            float3(0.20, 0.48, 1.00),
            float3(0.50, 0.28, 1.00),
            float3(0.95, 0.30, 0.90)
        };
        float x = clamp(t, 0.0, 1.0) * 7.0;
        int i = min(int(x), 6);
        return mix(c[i], c[i + 1], x - float(i));
    }

    static float column(constant float *a, float u) {
        float x = clamp(u, 0.0, 1.0) * float(\(IslandPrism.ribbonColumns - 1));
        int i = min(int(x), \(IslandPrism.ribbonColumns - 2));
        return mix(a[i], a[i + 1], x - float(i));
    }

    static float hash(float2 p) {
        return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
    }

    fragment float4 prismFragment(Varyings in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        float y = (1.0 - in.uv.y) * u.size.y - u.centre;
        float s = column(u.spread, in.uv.x);
        float g = column(u.glow, in.uv.x);
        float sigma = u.sigma + u.sigmaPerSpread * s;

        const int N = 16;
        float3 lit = float3(0.0);
        float3 whole = float3(0.0);
        for (int i = 0; i < N; i++) {
            float l = (float(i) + 0.5) / float(N);
            float3 c = spectrum(l);
            float d = (y - (1.0 - 2.0 * l) * s) / sigma;
            lit += c * exp(-d * d);
            whole += c;
        }
        // Fanned out, each colour's light is spread thinner; give most of
        // that back so a loud band is vivid rather than washed out.
        float fan = 1.0 + 1.1 * s / (sigma * 4.0);
        float3 color = lit / whole * fan * 1.3;

        // The local colour, for the halo: where this pixel sits in the fan.
        float3 local = spectrum(clamp(0.5 - y / (2.0 * max(s, 0.75)), 0.0, 1.0));
        float hd = y / (sigma * 2.6 + s * 0.9 + 2.0);
        color += mix(float3(1.0), local, 0.75) * 0.20 * exp(-hd * hd);

        // The core: white, on the line, narrower than any colour.
        float cd = y / (u.sigma * 0.62);
        color += float3(1.0) * 0.55 * exp(-cd * cd) / (1.0 + 0.12 * s);

        color *= g;
        // Roll off rather than clip where the core and the colours stack:
        // by the brightest channel, so a colour dims without paling.
        float peak = max(color.r, max(color.g, color.b));
        color *= (1.0 - exp(-peak * 1.5)) / max(peak, 1e-4);

        // Light that covers most of what it lights, so a colour is still
        // that colour over a white window, and round it a soft bed of
        // shade, the dark a caustic leaves beside its bright line.
        float cover = clamp(max(color.r, max(color.g, color.b)) * u.cover, 0.0, 1.0);
        float bd = y / (sigma * 3.0 + s + 5.0);
        cover = max(cover, u.bed * g * exp(-bd * bd));
        // A half-step of noise, so the halo's long falloff doesn't band.
        float n = (hash(in.position.xy) - 0.5) / 255.0;
        return float4(max(color + n, 0.0), cover);
    }
    """
}

// MARK: - The view

/// The ribbon's layer and what moves it. Like `EqualizerLayerView`, it
/// takes the levels straight from the capture; SwiftUI only tells it
/// whether to listen and whether anything is playing.
final class PrismRibbonView: NSView {
    private let metalLayer = CAMetalLayer()
    private let renderer = PrismRibbonRenderer.shared

    private static let bandCount = 6

    /// Where the bands are, and where they're headed.
    private var bands = [Double](repeating: 0, count: PrismRibbonView.bandCount)
    private var levels: [Double] = []

    private var isPlaying = false
    private var shows = true

    private var source: SystemAudioLevels?
    private var subscription: AnyCancellable?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var drawnSize: CGSize = .zero

    private enum Mode { case live, procedural, resting }

    private var mode: Mode {
        guard shows else { return .resting }
        if levels.count >= Self.bandCount { return .live }
        return isPlaying ? .procedural : .resting
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        metalLayer.device = renderer?.device
        metalLayer.pixelFormat = PrismRibbonRenderer.pixelFormat
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func makeBackingLayer() -> CALayer { metalLayer }

    /// Light on glass, never a target: see `PassThroughVisualEffectView`.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit { link?.invalidate() }

    // MARK: Input

    func attach(to source: SystemAudioLevels) {
        guard self.source !== source else { return }
        self.source = source
        subscription = source.$levels.sink { [weak self] levels in
            MainActor.assumeIsolated { self?.setLevels(levels) }
        }
    }

    func detach() {
        guard source != nil else { return }
        subscription = nil
        source = nil
        setLevels([])
    }

    /// `shows` is whether a waveform is wanted at all (the waveform setting
    /// isn't Off) and there's music for it to be of.
    func configure(isPlaying: Bool, shows: Bool) {
        guard isPlaying != self.isPlaying || shows != self.shows else { return }
        self.isPlaying = isPlaying
        self.shows = shows
        wake()
    }

    /// Fixed levels, drawn at once: for the gallery and the renders.
    func setStaticLevels(_ levels: [Double]) {
        self.levels = levels
        shows = true
        bands = Self.padded(levels)
        draw()
    }

    private func setLevels(_ next: [Double]) {
        levels = next
        wake()
    }

    private static func padded(_ levels: [Double]) -> [Double] {
        (0..<bandCount).map { $0 < levels.count ? levels[$0] : 0 }
    }

    // MARK: Motion

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTick = 0
        resize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resize()
    }

    override func layout() {
        super.layout()
        resize()
    }

    private func resize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width >= 1, size.height >= 1 else { return }
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        if bounds.size != drawnSize { draw() }
    }

    /// Something changed: run the link until the bands have settled again.
    private func wake() {
        guard let link, link.isPaused else { return }
        lastTick = 0
        link.isPaused = false
    }

    private func targets(at time: CFTimeInterval) -> [Double] {
        switch mode {
        case .live: return Self.padded(levels)
        case .procedural: return (0..<Self.bandCount).map { IslandPrism.procedural(band: $0, at: time) }
        case .resting: return [Double](repeating: 0, count: Self.bandCount)
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTick > 0 ? min(now - lastTick, 0.1) : 1.0 / 60
        lastTick = now
        let goal = targets(at: now)
        var moving = mode == .procedural
        for i in 0..<Self.bandCount {
            bands[i] = IslandPrism.follow(bands[i], toward: goal[i], dt: dt)
            if abs(bands[i] - goal[i]) > IslandPrism.settled { moving = true } else { bands[i] = goal[i] }
        }
        draw()
        // Settled: nothing more to draw until a level or a setting changes.
        if !moving { link.isPaused = true }
    }

    private func draw() {
        guard let renderer, bounds.width > 0, bounds.height > 0,
              metalLayer.drawableSize.width >= 1, metalLayer.drawableSize.height >= 1,
              let drawable = metalLayer.nextDrawable() else { return }
        drawnSize = bounds.size
        let profile = IslandPrism.profile(bands: bands)
        renderer.draw(
            .init(size: bounds.size, centre: IslandPrism.ribbonCentre, spread: profile.spread, glow: profile.glow),
            into: drawable.texture,
            presenting: drawable
        )
    }
}

// MARK: - SwiftUI

/// What the ribbon follows: the capture, whether to listen to it, and
/// whether there's anything playing for it to show.
struct PrismRibbonInput {
    var source: SystemAudioLevels
    /// Follow the capture (the waveform setting is Live).
    var listens: Bool
    var isPlaying: Bool
    /// A waveform is wanted and there's music up: off, the ribbon rests.
    var shows: Bool
    /// The panel is open. Closed, the ribbon is still in the glass
    /// window's tree, unseen: it lets go of the capture and rests, so
    /// nothing is drawn for an island that's shut, and each open starts
    /// from the resting streak and rises into the music.
    var open: Bool
}

/// The ribbon wired to the live capture, for the open panel.
struct PrismRibbon: NSViewRepresentable {
    var input: PrismRibbonInput

    func makeNSView(context: Context) -> PrismRibbonView {
        let view = PrismRibbonView()
        wire(view)
        return view
    }

    func updateNSView(_ view: PrismRibbonView, context: Context) { wire(view) }

    private func wire(_ view: PrismRibbonView) {
        let shows = input.shows && input.open
        input.listens && shows ? view.attach(to: input.source) : view.detach()
        view.configure(isPlaying: input.isPlaying, shows: shows)
    }
}

/// The ribbon at fixed levels, for the gallery and the renders. Empty
/// levels are the resting streak.
struct StaticPrismRibbon: NSViewRepresentable {
    var levels: [Double] = []

    func makeNSView(context: Context) -> PrismRibbonView {
        let view = PrismRibbonView()
        view.setStaticLevels(levels)
        return view
    }

    func updateNSView(_ view: PrismRibbonView, context: Context) { view.setStaticLevels(levels) }
}
