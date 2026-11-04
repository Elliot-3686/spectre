import AppKit
import MetalKit
import SpectreCore

/// MTKView driven on demand: never runs its own display timer.
/// Frames are requested by the FrameScheduler only when new audio data
/// arrives or while the simulation is still settling.
final class SpectrumMetalView: MTKView, MTKViewDelegate {
    enum Role { case window, wallpaper }

    let role: Role
    let renderer: SpectrumRenderer
    weak var scheduler: FrameScheduler?
    private let snapshot: SpectrumSnapshot

    var targetFPS: Double = 60
    private(set) var lastFrameTime: CFTimeInterval = 0
    private var occlusionObserver: NSObjectProtocol?
    /// Visible on screen (window not occluded / minimised).
    private(set) var isOnScreen = false {
        didSet { if isOnScreen != oldValue { scheduler?.visibilityChanged() } }
    }

    init(role: Role, ctx: RenderContext, snapshot: SpectrumSnapshot) {
        self.role = role
        self.snapshot = snapshot
        renderer = SpectrumRenderer(ctx: ctx)
        super.init(frame: .zero, device: ctx.device)
        colorPixelFormat = ctx.colorFormat
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = false
        autoResizeDrawable = false
        preferredFramesPerSecond = 60
        clearColor = MTLClearColor(red: 0.03, green: 0.035, blue: 0.045, alpha: 1)
        delegate = self
        layer?.isOpaque = true
        if let ml = layer as? CAMetalLayer {
            ml.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            ml.maximumDrawableCount = 3
            ml.displaySyncEnabled = true
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    deinit {
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: Size

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    var pixelsPerPoint: CGFloat {
        (window?.backingScaleFactor ?? 2) * renderer.style.quality.renderScale
    }

    /// Margins (points) kept free for axes and read-outs.
    var plotInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) {
        didSet { updatePlot() }
    }

    private func updatePlot() {
        let w = bounds.width, h = bounds.height
        guard w > 1, h > 1 else { return }
        var st = renderer.style
        st.plotL = Float(plotInsets.left / w)
        st.plotR = Float(1 - plotInsets.right / w)
        st.plotB = Float(plotInsets.bottom / h)
        st.plotT = Float(1 - plotInsets.top / h)
        renderer.style = st
    }

    func updateDrawableSize() {
        updatePlot()
        let s = pixelsPerPoint
        let size = CGSize(width: max(bounds.width * s, 16).rounded(), height: max(bounds.height * s, 16).rounded())
        if drawableSize != size {
            drawableSize = size
            renderer.markActive()
            scheduler?.requestFrame()
        }
    }

    // MARK: Visibility

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o); occlusionObserver = nil }
        guard let w = window else { isOnScreen = false; return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
                self?.refreshVisibility()
            }
        updateDrawableSize()
        refreshVisibility()
    }

    func refreshVisibility() {
        guard let w = window else { isOnScreen = false; return }
        isOnScreen = w.isVisible && w.occlusionState.contains(.visible) && !w.isMiniaturized
    }

    // MARK: Frames

    /// Should this view draw now? (fps cap + rest)
    func wantsFrame(at now: CFTimeInterval, newData: Bool) -> Bool {
        guard isOnScreen, targetFPS > 0 else { return false }
        if now - lastFrameTime < 0.92 / targetFPS { return false }
        if renderer.isAtRest && !newData { return false }
        if renderer.isAtRest && snapshot.isAtRestUnlocked { return false }
        return true
    }

    private(set) var framesDrawn: UInt64 = 0
    private(set) var drawSeconds: Double = 0

    func renderFrame(now: CFTimeInterval) {
        lastFrameTime = now
        let t0 = CACurrentMediaTime()
        draw()
        drawSeconds += CACurrentMediaTime() - t0
        framesDrawn &+= 1
    }

    func draw(in view: MTKView) {
        guard let rpd = currentRenderPassDescriptor, let drawable = currentDrawable else { return }
        renderer.draw(snapshot: snapshot, passDescriptor: rpd, drawable: drawable,
                      size: drawableSize, pixelScale: Float(pixelsPerPoint), now: CACurrentMediaTime())
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { role == .wallpaper ? nil : super.hitTest(point) }
}

extension SpectrumSnapshot {
    /// Unsynchronised read of a Bool flag (benign; only used as a hint).
    var isAtRestUnlocked: Bool { isAtRest }
}
