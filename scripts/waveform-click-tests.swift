//
//  waveform-click-tests.swift
//
//  A click on the Music face's waveform starts the level meter over
//  (`NotchViewModel.restartWaveform`), and the bars ping. What's tested is
//  that the click lands there and nowhere else: through the shipping
//  NotchRootView in the real NotchWindow and NotchHostingView, with the
//  press interceptor (`IslandCarry`) wired as NotchWindowController wires
//  it, offscreen and invisible, clicked by synthetic mouse-down/up NSEvents
//  through NSWindow.sendEvent. The waveform is found as the view that draws
//  it, so the click goes where the bars really are.
//
//  No capture runs: the view model is never started, so the restart has no
//  tap to rebuild and only the ping (`SystemAudioLevels.pings`) is counted.
//  Nothing here clicks the transport keys; no player is sent anything.
//
//  Run with scripts/test-waveform-click.sh.
//
import SwiftUI
import AppKit
import Combine

@MainActor
final class ClickIsland {
    let vm: NotchViewModel
    let settings: AppSettings
    let island: IslandPresentation
    let window: NotchWindow
    let hosting: NotchHostingView<NotchRootView>
    let carry: IslandCarry
    var pings = 0
    var bag: Set<AnyCancellable> = []

    init(mode: IsleMode, source: WaveformSource, floating: Bool = false) {
        let defaults = UserDefaults(suiteName: "isle.waveclick.\(UUID().uuidString)")!
        defaults.set("black", forKey: "isle.panelBackground")
        settings = AppSettings(defaults: defaults)
        let fixture = ClaudePanelFixture.all.first { $0.name == "sl_entry_busy" }!
        fixture.configure(settings)
        settings.mode = mode
        settings.waveformSource = source
        vm = NotchViewModel(settings: settings)
        vm.applyPreviewFixture(fixture)
        var track = MediaPlaybackModel()
        track.title = "Song"
        track.artist = "Artist"
        track.duration = 200
        track.isPlaying = true
        track.playbackRate = 1
        track.timestamp = Date()
        track.bundleIdentifier = "com.spotify.client"
        vm.applyPreviewMedia(track)
        vm.selectTab(.music)
        island = IslandPresentation(content: vm)
        let metrics = NotchMetrics(screen: NotchMetrics.preferredScreen()!)
        island.metrics = metrics
        if floating { island.placement = .floating(anchor: CGPoint(x: 600, y: 500)) }
        let frame = metrics.maximumFrame
        window = NotchWindow(contentRect: frame)
        var hostingRef: NotchHostingView<NotchRootView>?
        hosting = NotchHostingView(rootView: NotchRootView(viewModel: vm, island: island) { rect in
            hostingRef?.activeRect = rect
        })
        hostingRef = hosting
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setFrame(NSRect(x: -20000, y: -20000, width: frame.width, height: frame.height), display: false)
        window.alphaValue = 0
        carry = IslandCarry(presentation: island, window: window)
        let window = self.window
        window.pressInterceptor = { [weak carry] event in carry?.handle(event) ?? .pass }
        carry.drawnRect = { window.frame }
        carry.canArm = { true }
        window.orderFrontRegardless()
        vm.audioLevelSource.pings.sink { [weak self] in self?.pings += 1 }.store(in: &bag)
        island.setHovering(true)
        settle(1.0)
    }

    func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The waveforms on screen, in hosting-view coordinates (top-left).
    func waveforms() -> [CGRect] {
        var found: [CGRect] = []
        func walk(_ view: NSView) {
            if view is EqualizerLayerView, !view.isHiddenOrHasHiddenAncestor {
                let r = view.convert(view.bounds, to: hosting)
                found.append(hosting.isFlipped ? r : CGRect(x: r.minX, y: hosting.bounds.height - r.maxY, width: r.width, height: r.height))
            }
            view.subviews.forEach(walk)
        }
        walk(hosting)
        return found
    }

    /// A click at `p`, top-left points in the hosting view.
    func click(at p: CGPoint) {
        let inWindow = NSPoint(x: p.x, y: hosting.bounds.height - p.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            window.sendEvent(e)
            settle(0.05)
        }
        settle()
    }

    func close() { window.orderOut(nil) }
}

var failures = 0
var passes = 0
func report(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok { passes += 1 } else { failures += 1 }
    print("  \(ok ? "ok  " : "FAIL")  \(name)\(ok ? "" : " " + detail())")
}

@main
enum WaveformClickProbe {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)

        for (mode, label, floating) in [(IsleMode.both, "both modes", false), (.music, "music only", false),
                                        (.both, "both modes, off the notch", true)] {
            print(label)
            let t = ClickIsland(mode: mode, source: .live, floating: floating)
            report(t.vm.expandedPlace == .face(.music) && t.island.state.isExpanded, "open on the Music face")
            let corner = t.waveforms().filter { $0.width == 30 }
            report(corner.count == 1, "the corner waveform is on screen", "\(t.waveforms())")
            guard let bars = corner.first else { t.close(); continue }
            let wasPlaying = t.vm.media.isPlaying

            t.click(at: CGPoint(x: bars.midX, y: bars.midY))
            report(t.pings == 1, "a click on the bars restarts the meter", "pings \(t.pings)")
            report(t.vm.expandedPlace == .face(.music) && t.island.state.isExpanded, "and the panel stays on the Music face")
            report(t.vm.media.isPlaying == wasPlaying, "and playback is untouched")

            t.click(at: CGPoint(x: bars.minX - 2, y: bars.maxY + 2))
            report(t.pings == 2, "a click just outside the bars, inside the slack, counts", "pings \(t.pings)")

            t.click(at: CGPoint(x: bars.minX - 9, y: bars.midY))
            report(t.pings == 2, "a click well left of them doesn't", "pings \(t.pings)")
            t.click(at: CGPoint(x: bars.midX, y: bars.maxY + 10))
            report(t.pings == 2, "nor one well below them", "pings \(t.pings)")

            if mode == .both, !floating {
                // Control: the crumb in the band above still goes home.
                let metrics = NotchMetrics(screen: NotchMetrics.preferredScreen()!)
                let W = metrics.maximumFrame.width
                let panelX = (W - NotchMetrics.expandedSize.width) / 2
                let faceRight = panelX + (NotchMetrics.expandedSize.width + ClaudePanelLayout.faceWidth) / 2
                t.click(at: CGPoint(x: faceRight - ClaudePanelLayout.crumbWidth(showsHome: true) + 10,
                                    y: metrics.notchSize.height / 2))
                report(t.vm.expandedPlace == .home, "a click on the crumb still goes home (control)")
                report(t.pings == 2, "and is no click on the waveform", "pings \(t.pings)")
                t.vm.selectTab(.music)
                t.settle()
            }

            // Animated: no meter behind the bars, so the corner takes no click.
            t.settings.waveformSource = .animated
            t.settle()
            if let animated = t.waveforms().first(where: { $0.width == 30 }) {
                t.click(at: CGPoint(x: animated.midX, y: animated.midY))
                report(t.pings == 2, "with the Animated waveform, a click there does nothing", "pings \(t.pings)")
            } else {
                report(false, "the animated corner waveform is on screen")
            }
            t.settings.waveformSource = .live
            t.settle()

            // Closed: the pill's waveform takes no click. On the notch the
            // island opens on hover before a click could land; off it, a
            // click on the capsule opens it.
            t.island.setHovering(false)
            t.settle(1.0)
            let pill = t.waveforms().filter { $0.width != 30 }
            if !floating {
                report(!t.island.state.isExpanded && !pill.isEmpty, "closed, the pill shows its waveform", "\(t.waveforms())")
                if let wave = pill.first {
                    t.click(at: CGPoint(x: wave.midX, y: wave.midY))
                    report(t.pings == 2, "a click on the pill's waveform restarts nothing", "pings \(t.pings)")
                }
            }
            t.close()
        }

        print("\n\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
