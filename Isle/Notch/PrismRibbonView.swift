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
        /// The twist's own half-width across the ribbon, in points. For the
        /// twist, `lift`, `spread` and `glow` carry how far its bass, mids
        /// and treble layers are turned instead.
        var width: [Float] = []
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
    /// floats each), twelve floats of header, then the four profiles.
    private static func uniforms(_ frame: Frame) -> [Float] {
        let n = IslandPrism.ribbonColumns, c = IslandPrism.stopCount
        var u = [Float](repeating: 0, count: 4 * c + 12 + 4 * n)
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
        switch IslandPrism.ribbonStyle {
        case .light: u[h + 7] = 0
        case .crystal: u[h + 7] = 1
        case .twist: u[h + 7] = 2
        }
        for k in 0..<n {
            u[h + 12 + k] = k < frame.lift.count ? frame.lift[k] : 0
            u[h + 12 + n + k] = k < frame.spread.count ? frame.spread[k] : 0
            u[h + 12 + 2 * n + k] = k < frame.glow.count ? frame.glow[k] : 0
            u[h + 12 + 3 * n + k] = k < frame.width.count ? frame.width[k] : 0
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
        float pad0;
        float pad1;
        float pad2;
        float pad3;
        float lift[\(IslandPrism.ribbonColumns)];
        float spread[\(IslandPrism.ribbonColumns)];
        float glow[\(IslandPrism.ribbonColumns)];
        float width[\(IslandPrism.ribbonColumns)];
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

    // One sheet of glass, seen nearly edge on: `y` is the height above
    // its middle, `wide` its half-width there (points), `shift` where in
    // the fan its colours start, `tilt` how steeply it climbs.
    //
    // A thin sheet is clear and dark through its middle and carries its
    // colour along its edges, the way a film of oil does: the fan's first
    // colours toward its upper edge, its last toward its lower, moved a
    // little by the tilt so the colours slide as the sheet bends. Each
    // edge has a hairline of light on it. Returns premultiplied colour
    // and how much of what's under it the sheet hides.
    static float4 sheet(constant Uniforms &u, float y, float wide, float shift, float tilt) {
        float h = y / wide;
        float aa = 0.6 / wide;
        float inside = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, abs(h));
        float e = clamp(abs(h), 0.0, 1.0);
        // Colour gathers toward the edges; the middle keeps a trace.
        float gather = 0.07 + 0.93 * pow(e, 2.4);
        float3 tint = fan(u, fract(0.5 - 0.42 * h + shift + 0.18 * tilt));
        // The hairline: wide a point wide, just inside each edge.
        float d = (1.0 - e) * wide;
        float line = exp(-d * d / 0.4);
        float3 color = tint * gather * 1.25 + mix(tint, float3(1.0), 0.75) * line * 0.7;
        float cover = 0.06 + 0.7 * pow(e, 2.0) + 0.6 * line;
        return float4(color, clamp(cover, 0.0, 1.0)) * inside;
    }

    // The ribbon as glass: three sheets about the resting line. Two take
    // the outline between them, one reaching to its upper edge and one to
    // its lower, and sway apart and back as the bands rise and fall (one
    // up, one down, by turns), so their edges cross. The third lies
    // through the middle and follows the outline a little further along
    // the ribbon, so its crests fall between the others'. Where sheets
    // overlap their colours add, as light through two panes does. Under
    // them, the light they let through pools as a glow, and they shade
    // the glass a little.
    static float4 crystal(constant Uniforms &u, float x, float y, float s, float sway, float tilt, float g, float2 pixel) {
        float ahead = 9.0 / u.size.x;
        float s2 = max(column(u.spread, x + ahead), 0.85);
        float sway2 = column(u.lift, x - ahead);

        float4 a = sheet(u, y - (0.32 * s + sway), 0.68 * s, 0.0, tilt);
        float4 b = sheet(u, y - (-0.32 * s - sway), 0.68 * s, 0.37, -tilt);
        float4 c = sheet(u, y - 0.6 * sway2, 0.5 * s2, 0.71, tilt * 0.5);

        float3 color = a.rgb + b.rgb + c.rgb;
        float body = 1.0 - (1.0 - a.a) * (1.0 - b.a) * (1.0 - c.a);

        // Outside the outline: the glow, mostly below, and the shade.
        float reach = s + abs(sway);
        float below = max(-y - reach, 0.0);
        float above = max(y - reach, 0.0);
        float out = below + above * 2.5;
        float outside = step(reach, abs(y));
        color += fan(u, 0.8) * 0.26 * exp(-out / (2.4 + 0.3 * s)) * outside;
        float shade = u.bed * 0.5 * exp(-out / (4.0 + 0.5 * s)) * outside;

        color *= g;
        float peak = max(color.r, max(color.g, color.b));
        color *= (1.0 - exp(-peak * 1.6)) / max(peak, 1e-4);
        float cover = clamp(max(body * g, max(shade * g, max(color.r, max(color.g, color.b)) * 0.8)), 0.0, 1.0);
        float n = (hash(pixel) - 0.5) / 255.0;
        return float4(max(color + n, 0.0), cover);
    }

    // One twisted strip of light, seen from the side. `y` is the height
    // above its axis, `w` its half-width here (points), `c` how far it is
    // turned to face you here (1 its near face full on, 0 edge-on, -1 its
    // far face), `split` how far apart the colours are drawn.
    //
    // Turned so, a strip w wide shows w·|c| of itself: a wide lobe face-on,
    // a point edge-on, and past edge-on its other side. A lobe on the near
    // face rides a little above the axis and one on the far face a little
    // below, which is what makes the ribbon cross itself between them.
    // Across the lobe the light is strongest toward one edge, which is
    // crisp, and falls away to nothing toward the other; which edge is
    // which swaps with the side showing. The far side is dimmer. Red and
    // blue are drawn a fraction of a point above and below green, so the
    // crisp edge carries a thin fringe of colour.
    static float4 strip(float y, float w, float c, float split) {
        float side = c >= 0.0 ? 1.0 : -1.0;
        // Edge-on it still shows a sliver: the line a silent ribbon is.
        float lobe = max(w * abs(c), 0.1 * w + 0.2);
        float axis = y - 0.2 * w * c;
        float3 v = float3(axis - split, axis, axis + split) / lobe * side;
        float aa = 0.95 / lobe;
        float3 inside = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, abs(v));
        // Face-on is bright, edge-on half as bright; the far side of the
        // strip is dimmer the more of it shows, so nothing jumps as it
        // turns through edge-on.
        float far = side > 0.0 ? 1.0 : mix(1.0, 0.55, smoothstep(0.0, 0.3, abs(c)));
        float lit = (0.5 + 0.5 * pow(abs(c), 0.75)) * far;
        // Strongest toward the crisp edge, melting away toward the other.
        float3 across = smoothstep(-1.08, 0.3, v) * (0.5 + 0.5 * v);
        // And hottest a little inside the crisp edge.
        float3 hot = exp(-((v - 0.5) / 0.42) * ((v - 0.5) / 0.42));
        float3 color = inside * lit * (across * 0.85 + hot * 0.55);
        float cover = inside.g * clamp(lit * (0.15 + 0.85 * across.g + 0.4 * hot.g), 0.0, 1.0);
        return float4(color, cover);
    }

    // The ribbon as twisted light, in three layers on one axis: the bass,
    // the mids and the treble, each a strip of its own turned as its part
    // of the music has it (`lift`, `spread` and `glow` carry how far each
    // is turned, signed by the face showing; `width` the ribbon's own
    // half-width). Each is in its own part of the fan's colours — the bass
    // its first, the mids its middle, the treble its last — and narrower
    // than the one before, so the treble rides inside the mids and the
    // mids inside the bass. Their light adds: where they lie over one
    // another it runs toward white, and where one stands alone it is that
    // layer's colour. A soft bloom in those colours lies round it.
    static float4 twist(constant Uniforms &u, float x, float y, float2 pixel) {
        float w = column(u.width, x);
        float fa = column(u.lift, x), fb = column(u.spread, x), fc = column(u.glow, x);
        float3 ca = fan(u, 0.16), cb = fan(u, 0.5), cc = fan(u, 0.84);
        float wa = max(w, 0.6), wb = max(w * 0.82, 0.6), wc = max(w * 0.64, 0.6);
        float tall = max(abs(fa) * wa, max(abs(fb) * wb, abs(fc) * wc));
        float split = 0.2 + 0.022 * tall;
        float4 a = strip(y, wa, clamp(fa, -1.0, 1.0), split);
        float4 b = strip(y, wb, clamp(fb, -1.0, 1.0), -split);
        float4 c = strip(y, wc, clamp(fc, -1.0, 1.0), split);

        float3 color = a.rgb * mix(float3(1.0), ca, 0.72)
            + b.rgb * mix(float3(1.0), cb, 0.72) * 0.9
            + c.rgb * mix(float3(1.0), cc, 0.72) * 0.85;
        float body = 1.0 - (1.0 - a.a) * (1.0 - b.a * 0.9) * (1.0 - c.a * 0.85);
        // Three slivers lie on one another where nothing is turned: as
        // bright together as one ribbon edge-on, not three.
        float turned = smoothstep(0.0, 0.25, max(abs(fa), max(abs(fb), abs(fc))));
        color *= mix(0.42, 1.0, turned);
        // The ribbon thins to nothing where its width does.
        float there = smoothstep(0.0, 1.6, w);

        // The bloom: wide and soft, taller than the ribbon, in the colour
        // nearest this height.
        float3 tint = fan(u, clamp(0.5 - y / (2.0 * tall + 2.0), 0.0, 1.0));
        float bd = y / (3.5 + 1.7 * tall);
        float bloom = exp(-bd * bd);
        color += mix(float3(1.0), tint, 0.6) * 0.17 * bloom * (0.4 + 0.6 * smoothstep(1.0, 9.0, tall));

        color *= there * 1.25;
        float peak = max(color.r, max(color.g, color.b));
        color *= (1.0 - exp(-peak * 1.7)) / max(peak, 1e-4);
        // Light needs something to be seen against: over a bright window
        // the bloom's footprint is shaded, more the taller it is.
        float shade = u.bed * (0.55 + 0.4 * smoothstep(1.0, 9.0, tall)) * bloom * there;
        float cover = clamp(max(body * there, max(shade, max(color.r, max(color.g, color.b)) * 0.85)), 0.0, 1.0);
        float n = (hash(pixel) - 0.5) / 255.0;
        return float4(max(color + n, 0.0), cover);
    }

    fragment float4 prismFragment(Varyings in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        float x = in.uv.x;
        float s = column(u.spread, x);
        float g = column(u.glow, x);
        float dx = 1.5 / u.size.x;
        if (u.style > 1.5) {
            float rest = (1.0 - in.uv.y) * u.size.y - u.centre;
            return twist(u, x, rest, in.position.xy);
        }
        if (u.style > 0.5) {
            // The crystal stays on the resting line; `lift` is its sway.
            // Its tilt is how fast the outline is opening here.
            float grow = (column(u.spread, x + dx) - column(u.spread, x - dx)) / 3.0;
            float rest = (1.0 - in.uv.y) * u.size.y - u.centre;
            return crystal(u, x, rest, max(s, 0.85), column(u.lift, x), grow, g, in.position.xy);
        }
        float y = (1.0 - in.uv.y) * u.size.y - u.centre - column(u.lift, x);
        // The line's slope here, in points up per point across.
        float slope = (column(u.lift, x + dx) - column(u.lift, x - dx)) / 3.0;
        float steep = sqrt(1.0 + slope * slope);
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

    /// The travelling twist's three layers (bass, mids, treble): for each,
    /// what writes it, what it has written (how far its ribbon is turned
    /// at each step back in time, the newest first), and how far into its
    /// next step the clock has run.
    private struct Layer {
        var trace = IslandPrism.TwistTrace()
        var history = [Double](repeating: 0, count: IslandPrism.ribbonColumns + 2)
        var sinceStep: Double = 0
    }
    private var layers = [Layer](repeating: Layer(), count: 3)
    /// Levels were fixed by `setStatic`: draw them as they stand.
    private var isStatic = false

    /// Whether the ribbon is the travelling one.
    private var travels: Bool { IslandPrism.ribbonStyle == .twist && !reduceMotion && !isStatic }

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
        isStatic = true
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
        if travels {
            // Write the ribbon on, a step at a time, and keep drawing while
            // anything written is still on its way across.
            let energy = IslandPrism.twistLayerEnergy(bands)
            for g in layers.indices {
                let step = IslandPrism.twistWindows[g] / Double(IslandPrism.ribbonColumns - 1)
                layers[g].sinceStep += dt
                while layers[g].sinceStep >= step {
                    layers[g].history.insert(layers[g].trace.step(energy[g], dt: step), at: 0)
                    layers[g].history.removeLast()
                    layers[g].sinceStep -= step
                }
                if layers[g].history.contains(where: { abs($0) > 0.002 }) { moving = true }
            }
        }
        draw()
        // Settled: nothing more to draw until a level or a setting changes.
        if !moving { link.isPaused = true }
    }

    /// How far one layer of the travelling ribbon is turned at each
    /// column, left to right: the newest of what's been written at the
    /// right end, each column further left that much older, read between
    /// the written steps so it moves smoothly rather than a column at a
    /// time.
    private func travelling(_ g: Int) -> [Double] {
        let n = IslandPrism.ribbonColumns
        let step = IslandPrism.twistWindows[g] / Double(n - 1)
        let layer = layers[g]
        let into = min(max(layer.sinceStep / step, 0), 1)
        return (0..<n).map { k in
            let age = Double(n - 1 - k) + into
            let i = min(Int(age), layer.history.count - 2)
            let f = age - Double(i)
            return layer.history[i] * (1 - f) + layer.history[i + 1] * f
        }
    }

    /// The three layers standing still, for Reduce Motion and fixed levels.
    private func standing() -> [[Double]] {
        let n = IslandPrism.ribbonColumns
        let columns = (0..<n).map { IslandPrism.twistLayers(at: Double($0) / Double(n - 1), bands: bands) }
        return (0..<3).map { g in columns.map { $0[g] } }
    }

    private func draw() {
        guard let renderer, bounds.width > 0, bounds.height > 0,
              metalLayer.drawableSize.width >= 1, metalLayer.drawableSize.height >= 1,
              let drawable = metalLayer.nextDrawable() else { return }
        drawnSize = bounds.size
        let frame: PrismRibbonRenderer.Frame
        if IslandPrism.ribbonStyle == .twist {
            let twist = IslandPrism.profile(layers: travels ? (0..<3).map(travelling) : standing(), travelling: travels)
            frame = .init(size: bounds.size, centre: IslandPrism.ribbonCentre,
                          lift: twist.layers[0], spread: twist.layers[1], glow: twist.layers[2],
                          stops: stops, width: twist.width)
        } else {
            let profile = IslandPrism.profile(bands: bands)
            frame = .init(size: bounds.size, centre: IslandPrism.ribbonCentre,
                          lift: profile.lift, spread: profile.spread, glow: profile.glow, stops: stops)
        }
        renderer.draw(frame, into: drawable.texture, presenting: drawable)
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
