import AppKit
import SwiftUI
import SpectreCore

/// Borderless full-screen window at desktop level: below the desktop icons and
/// every other window, click-through, present on all Spaces.
final class WallpaperController {
    weak var model: AppModel?
    private(set) var window: NSWindow?
    private(set) var view: SpectrumMetalView?
    private var overlay: NSHostingView<WallpaperOverlay>?
    private var screenID = ""
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.reposition()
            }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.view?.refreshVisibility()
            }
    }

    static func screens() -> [(id: String, name: String)] {
        NSScreen.screens.map { (id: id(of: $0), name: $0.localizedName) }
    }

    static func id(of screen: NSScreen) -> String {
        if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber { return n.stringValue }
        return screen.localizedName
    }

    private func targetScreen() -> NSScreen? {
        if !screenID.isEmpty, let s = NSScreen.screens.first(where: { Self.id(of: $0) == screenID }) { return s }
        return NSScreen.main ?? NSScreen.screens.first
    }

    func apply(settings s: AppSettings, level: QualityLevel) {
        guard s.wallpaperEnabled, let model, let ctx = model.ctx else { teardown(); return }
        screenID = s.wallpaperScreen
        if window == nil { build(model: model, ctx: ctx) }
        guard let v = view else { return }
        var st = v.renderer.style
        st.mode = s.wallpaperMode
        st.theme = s.wallpaperTheme
        st.fluidity = Float(max(s.fluidity, 0.45))
        st.opacity = Float(s.wallpaperOpacity)
        st.showHold = false
        st.scale = s.scale
        st.quality = RenderQuality.profile(level, wallpaper: true)
        st.heightScale = 0.55
        v.renderer.style = st
        v.targetFPS = AppModel.fps(level, wallpaper: true)
        v.updateDrawableSize()
        let showText = s.wallpaperShowFrequency || s.wallpaperShowNote || s.wallpaperShowTitle
        overlay?.isHidden = !showText
        reposition()
    }

    private func build(model: AppModel, ctx: RenderContext) {
        guard let screen = targetScreen() else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        w.ignoresMouseEvents = true
        w.isOpaque = true
        w.hasShadow = false
        w.backgroundColor = NSColor(red: 0.03, green: 0.035, blue: 0.045, alpha: 1)
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.title = "Spectre – fond d'écran"

        let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        container.autoresizingMask = [.width, .height]
        let v = SpectrumMetalView(role: .wallpaper, ctx: ctx, snapshot: model.engine.snapshot)
        v.frame = container.bounds
        v.autoresizingMask = [.width, .height]
        container.addSubview(v)
        let o = NSHostingView(rootView: WallpaperOverlay(model: model, settings: model.settings))
        o.frame = container.bounds
        o.autoresizingMask = [.width, .height]
        container.addSubview(o)
        w.contentView = container
        window = w
        view = v
        overlay = o
        w.setFrame(screen.frame, display: false)
        w.orderFrontRegardless()
        model.scheduler.add(v)
    }

    private func reposition() {
        guard let w = window, let screen = targetScreen() else { return }
        if w.frame != screen.frame { w.setFrame(screen.frame, display: false) }
        view?.refreshVisibility()
    }

    func teardown() {
        guard let w = window else { return }
        if let v = view { model?.scheduler.remove(v) }
        w.orderOut(nil)
        w.contentView = nil
        window = nil
        view = nil
        overlay = nil
    }
}

struct WallpaperOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        let r = model.readout
        let p = r.peaks.first
        VStack(alignment: .leading, spacing: 4) {
            if settings.wallpaperShowTitle, let np = model.nowPlaying {
                Text(np).font(.system(size: 13, weight: .light)).lineLimit(1)
            }
            if settings.wallpaperShowFrequency, let p {
                Text(Fmt.hz(p.frequency)).font(.system(size: 30, weight: .ultraLight)).monospacedDigit()
            }
            if settings.wallpaperShowNote, let p {
                Text(Fmt.note(p.frequency)).font(.system(size: 13, weight: .light)).monospacedDigit()
            }
        }
        .foregroundColor(MainLayout.ink)
        .opacity(r.hasSignal ? 0.5 : 0)
        .animation(.easeInOut(duration: 0.9), value: r.hasSignal)
        .padding(.leading, 72)
        .padding(.top, 96)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
