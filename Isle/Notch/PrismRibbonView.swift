//
//  PrismRibbonView.swift
//
//  Prism's ribbon (see IslandPrism.swift): a streak of light along the
//  lens's lip, split into a fan of colours, lifted and spread at each
//  point across the panel by the music's level in one band — or, when the
//  island is showing Claude, moved by Claude's status.
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
        /// The ribbon's line at rest, in points above the strip's bottom.
        var centre: CGFloat
        /// The line's lift, the fan's half-height and the brightness
        /// across the ribbon, `IslandPrism.ribbonColumns` of each.
        var lift: [Float]
        var spread: [Float]
        var glow: [Float]
        /// The fan's colours, top to bottom, `IslandPrism.stopCount` of them.
        var stops: [SIMD3<Float>]
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

    /// The frame laid out as the shader's `Uniforms`: the colours (four
    /// floats each), eight floats of header, then the three profiles.
    private static func uniforms(_ frame: Frame) -> [Float] {
        let n = IslandPrism.ribbonColumns, c = IslandPrism.stopCount
        var u = [Float](repeating: 0, count: 4 * c + 8 + 3 * n)
        for k in 0..<c where k < frame.stops.count {
            u[4 * k] = frame.stops[k].x
            u[4 * k + 1] = frame.stops[k].y
            u[4 * k + 2] = frame.stops[k].z
        }
        let h = 4 * c
        u[h] = Float(frame.size.width)
        u[h + 1] = Float(frame.size.height)
        u[h + 2] = Float(frame.centre)
        u[h + 3] = Float(IslandPrism.restSigma)
        u[h + 4] = Float(IslandPrism.sigmaPerSpread)
        u[h + 5] = Float(IslandPrism.ribbonCover)
        u[h + 6] = Float(IslandPrism.ribbonBed)
        u[h + 7] = IslandPrism.ribbonStyle == .crystal ? 1 : 0
        for k in 0..<n {
            u[h + 8 + k] = k < frame.lift.count ? frame.lift[k] : 0
            u[h + 8 + n + k] = k < frame.spread.count ? frame.spread[k] : 0
            u[h + 8 + 2 * n + k] = k < frame.glow.count ? frame.glow[k] : 0
        }
        return u
    }

    /// Built at first use rather than shipped as a .metallib, so the render
    /// harnesses, which compile the sources with swiftc alone, draw the
    /// same ribbon the app does.
    ///
    /// For each pixel: where it is across the ribbon gives the line's lift,
    /// the fan's half-height `s` and the brightness `g` (interpolated from
    /// the profile); how far it is above the lifted line gives, for each of
    /// sixteen colours down the fan, how much of that colour's Gaussian
    /// reaches it — the first centred `s` above the line, the last `s`
    /// below. With no spread the colours coincide as their own mix (near
    /// white for the spectrum, the cover's blend for a cover). Over that, a
    /// narrow white core on the line itself, so the resting streak is
    /// white whatever the colours, and a wide faint halo in the local colour. Distances
    /// are measured straight up, so on a crest's steep sides the widths are
    /// stretched by the slope to keep the line as thick as it is on the flat.
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 stops[\(IslandPrism.stopCount)];
        float2 size;
        float centre;
        float sigma;
        float sigmaPerSpread;
        float cover;
        float bed;
        float style;
        float lift[\(IslandPrism.ribbonColumns)];
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

    // The fan's colour at t, 0 its top to 1 its bottom.
    static float3 fan(constant Uniforms &u, float t) {
        float x = clamp(t, 0.0, 1.0) * float(\(IslandPrism.stopCount - 1));
        int i = min(int(x), \(IslandPrism.stopCount - 2));
        return mix(u.stops[i].rgb, u.stops[i + 1].rgb, x - float(i));
    }

    static float column(constant float *a, float u) {
        float x = clamp(u, 0.0, 1.0) * float(\(IslandPrism.ribbonColumns - 1));
        int i = min(int(x), \(IslandPrism.ribbonColumns - 2));
        return mix(a[i], a[i + 1], x - float(i));
    }

    static float hash(float2 p) {
        return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
    }

    // The ribbon as a body of glass. `y` is the height above the body's
    // middle, `t` its half-thickness there, `rise` how steeply its upper
    // surface climbs to the right; all in points.
    //
    // Across its thickness the body is shaded as a rounded bar lit from
    // above and a little to the left: `h` runs -1 at its lower edge to 1
    // at its upper, and the surface faces the viewer squarely at 0 and
    // turns away toward either edge. Glass is clearest where it faces
    // you and densest, and brightest, where it turns away, so the colour
    // gathers at the edges and the middle lets the panel show through. A
    // bright line lies where the surface faces the light, sliding toward
    // the crest's lit side as the surface tilts; a softer one near the
    // lower edge is the light coming back up through it. Each colour
    // channel is cut at a slightly different thickness, which leaves a
    // fringe of colour along the silhouette, as a cut edge does. Under
    // the body, the light it lets through pools as a soft glow.
    static float4 crystal(constant Uniforms &u, float y, float t, float rise, float g, float2 pixel) {
        float h = y / t;
        float aa = 0.7 / t;
        // The silhouette, once per channel: red cut a little wider than
        // green, blue a little narrower.
        float3 edge = float3(1.03, 1.0, 0.97);
        float3 inside = 1.0 - smoothstep(edge - aa, edge + aa, float3(abs(h)));
        float within = clamp(abs(h), 0.0, 1.0);
        float facing = sqrt(1.0 - within * within);
        float away = 1.0 - facing;
        // How much body there is here: a thread at rest, full on a crest.
        float full = smoothstep(2.3, 7.0, t);

        // The fan's colours through the body, first at the top.
        float3 tint = fan(u, (1.0 - clamp(h, -1.0, 1.0)) * 0.5);
        // Dense at the edges, thin through the middle.
        float density = mix(0.1, 0.85, pow(away, 2.2));
        float3 color = tint * density;
        // Where the light gathers inside, below the middle: glass is
        // brightest on the side away from the light.
        float pool = (h + 0.34) / 0.34;
        color += tint * (0.3 + 0.35 * full) * exp(-pool * pool);

        // Where the surface faces the light: a soft sheen across the upper
        // half, and in it a glint, both moved by the tilt. The glint is a
        // crest's: it thins away where the body does.
        float lit = 0.46 - 0.3 * clamp(rise, -1.0, 1.0);
        float sheen = (h - lit) / 0.3;
        float glint = (h - lit - 0.08) / 0.085;
        float facingLight = 1.0 + 0.6 * clamp(-rise * 1.5, -0.7, 1.0);
        float shine = (0.2 * exp(-sheen * sheen) + 0.9 * exp(-glint * glint) * mix(0.25, 1.0, full)) * facingLight;
        // The light coming back up along the lower edge, in the body's colour.
        float back = (h + 0.76) / 0.13;
        float3 bounce = mix(float3(1.0), tint, 0.7) * 0.34 * exp(-back * back);

        color = (color + bounce) * inside + float3(shine) * inside.g;
        // How much the body hides what's under it: little through the
        // middle, most at the edges and under the shine.
        float body = clamp(mix(0.14, 0.8, pow(away, 1.6)) + shine * 0.85, 0.0, 1.0) * inside.g;

        // Under the body: the light it lets through, and its shade.
        float below = max(-y - t, 0.0);
        float above = max(y - t, 0.0);
        float out = below + above * 2.5;
        float3 glow = fan(u, 0.8) * (0.16 + 0.22 * full) * exp(-out / (2.2 + 0.35 * t)) * (1.0 - inside.g);
        color += glow;
        float shade = u.bed * 0.55 * exp(-out / (4.0 + 0.5 * t)) * (1.0 - inside.g);

        // A thread at rest is brighter than its share of the glow: it is
        // all edge.
        float lift = mix(1.35, 1.0, full);
        color *= g * lift;
        float cover = clamp(max(body * g, max(shade * g, max(color.r, max(color.g, color.b)) * 0.7)), 0.0, 1.0);
        float n = (hash(pixel) - 0.5) / 255.0;
        return float4(max(color + n, 0.0), cover);
    }

    fragment float4 prismFragment(Varyings in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        float x = in.uv.x;
        float y = (1.0 - in.uv.y) * u.size.y - u.centre - column(u.lift, x);
        float s = column(u.spread, x);
        float g = column(u.glow, x);
        // The line's slope here, in points up per point across.
        float dx = 1.5 / u.size.x;
        float slope = (column(u.lift, x + dx) - column(u.lift, x - dx)) / 3.0;
        float steep = sqrt(1.0 + slope * slope);
        if (u.style > 0.5) {
            // The upper surface's slope: the line's, and the thickness's.
            float grow = (column(u.spread, x + dx) - column(u.spread, x - dx)) / 3.0;
            return crystal(u, y, max(s, 0.85) * steep, slope + grow, g, in.position.xy);
        }
        float sigma = (u.sigma + u.sigmaPerSpread * s) * steep;

        const int N = 16;
        float3 lit = float3(0.0);
        for (int i = 0; i < N; i++) {
            float l = (float(i) + 0.5) / float(N);
            float d = (y - (1.0 - 2.0 * l) * s) / sigma;
            lit += fan(u, l) * exp(-d * d);
        }
        // Spread out, each colour's light is thinner; give most of that
        // back so a loud band is vivid rather than washed out.
        float gain = 1.0 + 1.1 * s / (sigma * 4.0);
        float3 color = lit / float(N) * gain * 2.1;

        // The local colour, for the halo: where this pixel sits in the fan.
        float3 local = fan(u, clamp(0.5 - y / (2.0 * max(s, 0.75)), 0.0, 1.0));
        float hd = y / (sigma * 2.6 + s * 0.9 + 2.0);
        color += mix(float3(1.0), local, 0.75) * 0.20 * exp(-hd * hd);

        // The core: white, on the line, narrower than any colour.
        float cd = y / (u.sigma * 0.62 * steep);
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
/// takes the levels straight from the capture; SwiftUI only tells it what
/// to follow and in which colours.
final class PrismRibbonView: NSView {
    private let metalLayer = CAMetalLayer()
    private let renderer = PrismRibbonRenderer.shared

    private static let bandCount = 6

    /// Where the bands are; the capture's levels, when it's listened to.
    private var bands = [Double](repeating: 0, count: PrismRibbonView.bandCount)
    private var levels: [Double] = []

    private var motion: IslandPrism.Motion = .rest
    private var isPlaying = false
    private var reduceMotion = false
    /// When the motion began, on the display link's clock: nil until the
    /// first tick after it changed.
    private var motionStart: CFTimeInterval?

    /// The fan's colours as drawn, and where they're turning to.
    private var stops = PrismRibbonView.vectors(IslandPrism.spectrum)
    private var stopGoal = PrismRibbonView.vectors(IslandPrism.spectrum)
    private var hasColors = false

    private var source: SystemAudioLevels?
    private var subscription: AnyCancellable?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var drawnSize: CGSize = .zero

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

    /// What moves the ribbon, and in which colours. A new motion starts
    /// from its beginning; new colours are turned to, not cut to — except
    /// the first, which there is nothing to turn from.
    func configure(motion: IslandPrism.Motion, isPlaying: Bool, stops: [IslandPrism.RGB], reduceMotion: Bool) {
        let goal = Self.vectors(stops)
        let changed = motion != self.motion || isPlaying != self.isPlaying
            || reduceMotion != self.reduceMotion || goal != stopGoal
        if motion != self.motion { motionStart = nil }
        self.motion = motion
        self.isPlaying = isPlaying
        self.reduceMotion = reduceMotion
        stopGoal = goal
        if !hasColors {
            self.stops = goal
            hasColors = true
        }
        if changed { wake() }
    }

    /// Fixed levels and colours, drawn at once: for the gallery and the
    /// renders.
    func setStatic(levels: [Double], stops: [IslandPrism.RGB] = IslandPrism.spectrum) {
        motion = .rest
        bands = Self.padded(levels)
        self.stops = Self.vectors(stops)
        stopGoal = self.stops
        hasColors = true
        draw()
    }

    private func setLevels(_ next: [Double]) {
        levels = next
        wake()
    }

    private static func padded(_ levels: [Double]) -> [Double] {
        (0..<bandCount).map { $0 < levels.count ? levels[$0] : 0 }
    }

    private static func vectors(_ stops: [IslandPrism.RGB]) -> [SIMD3<Float>] {
        (0..<IslandPrism.stopCount).map {
            let c = stops.isEmpty ? IslandPrism.spectrum[$0] : stops[min($0, stops.count - 1)]
            return SIMD3(Float(c.r), Float(c.g), Float(c.b))
        }
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

    /// Something changed: run the link until everything has settled again.
    private func wake() {
        guard let link, link.isPaused else { return }
        lastTick = 0
        link.isPaused = false
    }

    /// Where the bands are headed at `time`, and whether what's moving
    /// them will still be moving after it.
    private func targets(at time: CFTimeInterval) -> (bands: [Double], moving: Bool) {
        if motion == .music {
            // The capture's levels, or the bars' own pattern while
            // something plays and there are none.
            if levels.count >= Self.bandCount { return (Self.padded(levels), false) }
            guard isPlaying else { return ([Double](repeating: 0, count: Self.bandCount), false) }
            return ((0..<Self.bandCount).map { IslandPrism.procedural(band: $0, at: time) }, true)
        }
        let start = motionStart ?? time
        motionStart = start
        let t = time - start
        return (
            (0..<Self.bandCount).map { IslandPrism.pattern(motion, band: $0, at: t, reduceMotion: reduceMotion) },
            IslandPrism.isMoving(motion, at: t, reduceMotion: reduceMotion)
        )
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTick > 0 ? min(now - lastTick, 0.1) : 1.0 / 60
        lastTick = now
        let goal = targets(at: now)
        var moving = goal.moving
        for i in 0..<Self.bandCount {
            bands[i] = IslandPrism.follow(bands[i], toward: goal.bands[i], dt: dt)
            if abs(bands[i] - goal.bands[i]) > IslandPrism.settled { moving = true } else { bands[i] = goal.bands[i] }
        }
        // The colours turn toward their goal on the same clock.
        let turn = Float(1 - exp(-dt / IslandPrism.colorTurn))
        for i in 0..<stops.count {
            let d = stopGoal[i] - stops[i]
            if max(abs(d.x), abs(d.y), abs(d.z)) > 0.004 {
                stops[i] += d * turn
                moving = true
            } else {
                stops[i] = stopGoal[i]
            }
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
            .init(size: bounds.size, centre: IslandPrism.ribbonCentre,
                  lift: profile.lift, spread: profile.spread, glow: profile.glow, stops: stops),
            into: drawable.texture,
            presenting: drawable
        )
    }
}

// MARK: - SwiftUI

/// What the ribbon follows.
struct PrismRibbonInput {
    var source: SystemAudioLevels
    /// Follow the capture (the waveform setting is Live).
    var listens: Bool
    var isPlaying: Bool
    /// What moves it: the music, or one of Claude's statuses.
    var motion: IslandPrism.Motion
    /// The fan's colours, top to bottom.
    var stops: [IslandPrism.RGB]
    /// The panel is open. Closed, the ribbon is still in the glass
    /// window's tree, unseen: it lets go of the capture and rests, so
    /// nothing is drawn for an island that's shut, and each open starts
    /// from the resting streak and rises into whatever it's following.
    var open: Bool
    var reduceMotion: Bool
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
        let motion = input.open ? input.motion : .rest
        input.listens && motion == .music ? view.attach(to: input.source) : view.detach()
        view.configure(motion: motion, isPlaying: input.isPlaying, stops: input.stops, reduceMotion: input.reduceMotion)
    }
}

/// The ribbon at fixed levels and colours, for the gallery and the
/// renders. Empty levels are the resting streak.
struct StaticPrismRibbon: NSViewRepresentable {
    var levels: [Double] = []
    var stops: [IslandPrism.RGB] = IslandPrism.spectrum

    func makeNSView(context: Context) -> PrismRibbonView {
        let view = PrismRibbonView()
        view.setStatic(levels: levels, stops: stops)
        return view
    }

    func updateNSView(_ view: PrismRibbonView, context: Context) { view.setStatic(levels: levels, stops: stops) }
}
