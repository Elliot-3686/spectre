import Metal
import QuartzCore
import SpectreCore

/// Per-view GPU state: simulation buffers, particles, trails, spectrogram.
/// All per-frame graphics work happens on the GPU; the CPU only uploads the
/// normalised spectrum (≤ 512 floats) and encodes a handful of commands.
final class SpectrumRenderer {
    let ctx: RenderContext
    var style = VisualStyle() {
        didSet { if style != oldValue { styleChanged(from: oldValue) } }
    }

    private let inflight = DispatchSemaphore(value: 3)
    private var slot = 0
    private(set) var columns = 0

    private var targetBufs: [MTLBuffer] = []
    private var holdBufs: [MTLBuffer] = []
    private var bandBufs: [MTLBuffer] = []
    private var bandHoldBufs: [MTLBuffer] = []
    private var energyBufs: [MTLBuffer] = []
    private var movingBufs: [MTLBuffer] = []
    private var hBuf: MTLBuffer?
    private var vBuf: MTLBuffer?
    private var layersBuf: MTLBuffer?
    private var surfVelBuf: MTLBuffer?
    private var paramsBuf: MTLBuffer?
    private var paramsFluidity: Float = -1

    private var grainBuf: MTLBuffer?
    private var grainCount = 0
    private let duneColumns = 192
    private var duneBuf: MTLBuffer?
    private var countsBuf: MTLBuffer?

    private var spectroTex: MTLTexture?
    private var spectroHead = 0
    private let spectroRows = 256

    private var trailTex: [MTLTexture] = []
    private var trailIndex = 0
    private var trailSize = (0, 0)

    private var bandTilts: [Float] = []
    private var lastSequence: UInt64 = .max
    private var lastTime: CFTimeInterval = 0
    private let startTime = CACurrentMediaTime()

    // Rest detection (read back from the previous completed frame).
    private let restLock = NSLock()
    private var gpuEnergy: Float = 1
    private var gpuMoving: Int = .max
    private var quietSince: CFTimeInterval?
    private(set) var isAtRest = false

    /// GPU time of the last frame, in ms (benchmark).
    private(set) var lastGPUTimeMS: Double = 0

    init(ctx: RenderContext) {
        self.ctx = ctx
        let dev = ctx.device
        for _ in 0..<3 {
            bandBufs.append(dev.makeBuffer(length: 4 * ISOBands.count, options: .storageModeShared)!)
            bandHoldBufs.append(dev.makeBuffer(length: 4 * ISOBands.count, options: .storageModeShared)!)
            energyBufs.append(dev.makeBuffer(length: 4, options: .storageModeShared)!)
            movingBufs.append(dev.makeBuffer(length: 4, options: .storageModeShared)!)
        }
        duneBuf = dev.makeBuffer(length: 4 * duneColumns, options: .storageModeShared)
        countsBuf = dev.makeBuffer(length: 4 * duneColumns, options: .storageModeShared)
        memset(duneBuf!.contents(), 0, 4 * duneColumns)
        updateBandTilts()
    }

    // MARK: - Allocation

    private func ensureColumns(_ k: Int) {
        let k = min(k, ctx.maxColumns)
        guard k != columns else { return }
        columns = k
        let dev = ctx.device
        let len = 4 * k
        targetBufs = (0..<3).map { _ in dev.makeBuffer(length: len, options: .storageModeShared)! }
        holdBufs = (0..<3).map { _ in dev.makeBuffer(length: len, options: .storageModeShared)! }
        hBuf = dev.makeBuffer(length: len, options: .storageModeShared)
        vBuf = dev.makeBuffer(length: len, options: .storageModeShared)
        surfVelBuf = dev.makeBuffer(length: len, options: .storageModeShared)
        layersBuf = dev.makeBuffer(length: 16 * k, options: .storageModeShared)
        paramsBuf = dev.makeBuffer(length: 16 * k, options: .storageModeShared)
        for b in [hBuf, vBuf, surfVelBuf, layersBuf] { memset(b!.contents(), 0, b!.length) }
        for b in targetBufs + holdBufs { memset(b.contents(), 0, b.length) }
        paramsFluidity = -1
    }

    /// Physical properties per column: bass heavy and slow, treble light and lively.
    private func updateParams() {
        let f = style.fluidity
        guard let p = paramsBuf, abs(f - paramsFluidity) > 1e-4 else { return }
        paramsFluidity = f
        let ptr = p.contents().bindMemory(to: SIMD4<Float>.self, capacity: columns)
        for j in 0..<columns {
            let u = Float(j) / Float(max(columns - 1, 1))
            let hz = (1.4 + (7.0 - 1.4) * pow(u, 0.9)) * (1.35 - 0.85 * f)
            let w0 = 2 * Float.pi * hz
            let zeta = 0.9 + (0.42 - 0.9) * u + 0.12 * f
            let couple = w0 * (1.2 + (0.7 - 1.2) * u)
            let kappa = couple * couple * (0.35 + 0.9 * f)
            ptr[j] = SIMD4(w0, zeta, kappa, 0)
        }
    }

    private func ensureGrains() {
        let n = style.quality.particles
        guard n != grainCount || grainBuf == nil else { return }
        grainCount = n
        let b = ctx.device.makeBuffer(length: 16 * max(n, 1), options: .storageModeShared)!
        let ptr = b.contents().bindMemory(to: SIMD4<Float>.self, capacity: max(n, 1))
        var rng = SplitMix64(seed: 0xC0FFEE)
        for i in 0..<n { ptr[i] = SIMD4(Float(rng.nextUniform()), Float(rng.nextUniform()) * 0.3, 0, 0) }
        grainBuf = b
        memset(duneBuf!.contents(), 0, 4 * duneColumns)
    }

    private func ensureSpectro() {
        let w = style.quality.spectroWidth
        if let t = spectroTex, t.width == w { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: w, height: spectroRows, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .managed
        let t = ctx.device.makeTexture(descriptor: d)!
        let zeros = [UInt16](repeating: 0, count: w * spectroRows)
        zeros.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, spectroRows), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 2 * w) }
        spectroTex = t
        spectroHead = 0
    }

    private func ensureTrails(width: Int, height: Int, commandBuffer: MTLCommandBuffer) {
        let div = max(style.quality.trailDivisor, 1)
        let w = max(width / div, 8), h = max(height / div, 8)
        if trailTex.count == 2 && trailSize == (w, h) { return }
        trailSize = (w, h)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ctx.trailFormat, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        trailTex = (0..<2).map { _ in ctx.device.makeTexture(descriptor: d)! }
        for t in trailTex {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = t
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rp.colorAttachments[0].storeAction = .store
            commandBuffer.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
        }
    }

    private func styleChanged(from old: VisualStyle) {
        if old.scale != style.scale { updateBandTilts() }
        if old.mode != style.mode || old.fluidity != style.fluidity { markActive() }
        if old.quality.trails != style.quality.trails || old.quality.trailDivisor != style.quality.trailDivisor { trailTex = [] }
    }

    private func updateBandTilts() {
        bandTilts = style.scale.tilts(for: ISOBands.exactCenters)
    }

    func markActive() {
        restLock.lock()
        isAtRest = false
        quietSince = nil
        gpuEnergy = 1
        restLock.unlock()
    }

    // MARK: - Frame

    /// Encodes and commits one frame. `drawable` nil = offscreen.
    func draw(snapshot s: SpectrumSnapshot, passDescriptor rpd: MTLRenderPassDescriptor,
              drawable: MTLDrawable?, size: CGSize, pixelScale: Float, now: CFTimeInterval,
              waitUntilCompleted: Bool = false) {
        inflight.wait()
        slot = (slot + 1) % 3
        let mode = style.mode

        // 1. Upload the normalised spectrum (CPU: ≤ 512 + 62 floats).
        s.lock.lock()
        ensureColumns(s.binCount)
        let k = columns
        let useRaw = style.fluidity < 0.02 && mode != .curve
        let src = useRaw ? s.raw.pointer : s.smoothed.pointer
        let tgt = targetBufs[slot].contents().bindMemory(to: Float.self, capacity: k)
        let hold = holdBufs[slot].contents().bindMemory(to: Float.self, capacity: k)
        let scale = style.scale
        let tilts = s.tilts
        for j in 0..<k {
            let tilt = j < tilts.count ? tilts[j] : 0
            tgt[j] = scale.normalized(src[j], tilt: tilt)
            hold[j] = scale.normalized(s.hold[j], tilt: tilt)
        }
        let bands = bandBufs[slot].contents().bindMemory(to: Float.self, capacity: ISOBands.count)
        let bandHold = bandHoldBufs[slot].contents().bindMemory(to: Float.self, capacity: ISOBands.count)
        for b in 0..<ISOBands.count {
            bands[b] = scale.normalized(s.bandsSmoothed[b], tilt: bandTilts[b])
            bandHold[b] = scale.normalized(s.bandsHold[b], tilt: bandTilts[b])
        }
        let sequence = s.sequence
        let snapshotRest = s.isAtRest
        s.lock.unlock()

        let newData = sequence != lastSequence
        lastSequence = sequence
        let dt = Float(min(max(lastTime == 0 ? 1.0 / 60 : now - lastTime, 1.0 / 240), 0.1))
        lastTime = now
        let time = Float(now - startTime)

        updateParams()
        if mode == .sand { ensureGrains() }
        if mode == .spectrogram { ensureSpectro() }

        guard let cb = ctx.queue.makeCommandBuffer() else { inflight.signal(); return }
        cb.label = "Spectre frame"

        energyBufs[slot].contents().storeBytes(of: UInt32(0), as: UInt32.self)
        movingBufs[slot].contents().storeBytes(of: UInt32(0), as: UInt32.self)

        var sim = SimUniforms()
        sim.dt = dt
        sim.columns = Float(k)
        sim.fluidity = mode == .curve ? 0 : style.fluidity
        sim.substeps = Float(min(max(Int((dt / 0.004).rounded(.up)), 1), 16))
        sim.bypass = (mode == .curve || style.fluidity < 0.02) ? 1 : 0
        sim.blur = Float(k) / 512
        sim.sandCount = Float(grainCount)
        sim.duneColumns = Float(duneColumns)
        sim.gravity = 1.9
        sim.time = time
        sim.kick = 0.5
        sim.grainHeight = 0.07 / max(Float(grainCount) / Float(duneColumns), 1)

        if mode == .sand, let counts = countsBuf, let blit = cb.makeBlitCommandEncoder() {
            blit.fill(buffer: counts, range: 0..<counts.length, value: 0)
            blit.endEncoding()
        }

        // 2. Simulation (compute).
        if let enc = cb.makeComputeCommandEncoder() {
            if mode != .bars && mode != .spectrogram {
                enc.setComputePipelineState(ctx.liquidStep)
                enc.setBuffer(hBuf, offset: 0, index: 0)
                enc.setBuffer(vBuf, offset: 0, index: 1)
                enc.setBuffer(targetBufs[slot], offset: 0, index: 2)
                enc.setBuffer(paramsBuf, offset: 0, index: 3)
                enc.setBuffer(layersBuf, offset: 0, index: 4)
                enc.setBuffer(surfVelBuf, offset: 0, index: 5)
                enc.setBuffer(energyBufs[slot], offset: 0, index: 6)
                enc.setBytes(&sim, length: MemoryLayout<SimUniforms>.stride, index: 7)
                enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: k, height: 1, depth: 1))
            }
            if mode == .sand, grainCount > 0 {
                enc.setComputePipelineState(ctx.sandStep)
                enc.setBuffer(grainBuf, offset: 0, index: 0)
                enc.setBuffer(layersBuf, offset: 0, index: 1)
                enc.setBuffer(surfVelBuf, offset: 0, index: 2)
                enc.setBuffer(duneBuf, offset: 0, index: 3)
                enc.setBuffer(countsBuf, offset: 0, index: 4)
                enc.setBuffer(movingBufs[slot], offset: 0, index: 5)
                enc.setBytes(&sim, length: MemoryLayout<SimUniforms>.stride, index: 6)
                let w = ctx.sandStep.threadExecutionWidth
                enc.dispatchThreadgroups(MTLSize(width: (grainCount + w * 4 - 1) / (w * 4), height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: w * 4, height: 1, depth: 1))
                enc.setComputePipelineState(ctx.duneUpdate)
                enc.setBuffer(countsBuf, offset: 0, index: 0)
                enc.setBuffer(duneBuf, offset: 0, index: 1)
                enc.setBytes(&sim, length: MemoryLayout<SimUniforms>.stride, index: 2)
                enc.dispatchThreadgroups(MTLSize(width: (duneColumns + 63) / 64, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            }
            if mode == .spectrogram, newData, let tex = spectroTex {
                spectroHead = (spectroHead + 1) % tex.width
                sim.head = Float(spectroHead)
                enc.setComputePipelineState(ctx.spectroWrite)
                enc.setTexture(tex, index: 0)
                enc.setBuffer(targetBufs[slot], offset: 0, index: 0)
                enc.setBytes(&sim, length: MemoryLayout<SimUniforms>.stride, index: 1)
                enc.dispatchThreadgroups(MTLSize(width: spectroRows / 64, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            }
            enc.endEncoding()
        }

        // 3. Uniforms.
        var u = FrameUniforms()
        u.viewW = Float(size.width); u.viewH = Float(size.height)
        u.time = time; u.dt = dt
        u.columns = Float(k)
        u.mode = mode.shaderMode
        u.opacity = style.opacity
        u.layerCount = mode == .curve ? 1 : Float(style.quality.layers)
        u.glow = mode == .curve ? 0.35 * style.quality.glow : style.quality.glow
        let trails = mode == .liquid && style.quality.trails
        u.trailStrength = trails ? 0.55 : 0
        u.fluidity = style.fluidity
        u.dither = 1
        u.plotL = style.plotL; u.plotB = style.plotB; u.plotR = style.plotR; u.plotT = style.plotT
        u.vignette = 0.22
        u.crest = 1
        u.spectroHead = Float(spectroHead)
        u.spectroWidth = Float(spectroTex?.width ?? 1)
        u.bandCount = Float(ISOBands.count)
        u.showHold = style.showHold && (mode == .curve || mode == .bars) ? 1 : 0
        u.pointSize = max(1.5 * pixelScale, 1.2)
        u.particleCount = Float(grainCount)
        u.pixelScale = pixelScale
        u.heightScale = style.heightScale
        u.trailDecay = Float(pow(0.5, Double(dt) / 0.45))
        u.surfaceAlpha = mode == .sand ? 0.22 : 1

        // 4. Trails (reduced resolution ping-pong).
        let lut = ctx.lut(for: style.theme)
        if trails {
            ensureTrails(width: Int(size.width), height: Int(size.height), commandBuffer: cb)
            let src = trailTex[trailIndex], dst = trailTex[1 - trailIndex]
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = dst
            rp.colorAttachments[0].loadAction = .dontCare
            rp.colorAttachments[0].storeAction = .store
            if let enc = cb.makeRenderCommandEncoder(descriptor: rp) {
                enc.setRenderPipelineState(ctx.trailPipeline)
                enc.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 0)
                enc.setFragmentBuffer(layersBuf, offset: 0, index: 1)
                enc.setFragmentBuffer(lut, offset: 0, index: 2)
                enc.setFragmentTexture(src, index: 0)
                enc.setFragmentSamplerState(ctx.linearClamp, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
            trailIndex = 1 - trailIndex
        }

        // 5. Main pass.
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            switch mode {
            case .liquid, .curve, .sand:
                enc.setRenderPipelineState(ctx.liquidPipeline)
                enc.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 0)
                enc.setFragmentBuffer(layersBuf, offset: 0, index: 1)
                enc.setFragmentBuffer(lut, offset: 0, index: 2)
                enc.setFragmentBuffer(holdBufs[slot], offset: 0, index: 3)
                enc.setFragmentTexture(trails ? trailTex[trailIndex] : ctx.dummyTexture, index: 0)
                enc.setFragmentSamplerState(ctx.linearClamp, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                if mode == .sand, grainCount > 0 {
                    enc.setRenderPipelineState(ctx.grainPipeline)
                    enc.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 0)
                    enc.setVertexBuffer(grainBuf, offset: 0, index: 1)
                    enc.setVertexBuffer(lut, offset: 0, index: 2)
                    enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: grainCount)
                }
            case .bars:
                enc.setRenderPipelineState(ctx.barsPipeline)
                enc.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 0)
                enc.setFragmentBuffer(bandBufs[slot], offset: 0, index: 1)
                enc.setFragmentBuffer(lut, offset: 0, index: 2)
                enc.setFragmentBuffer(bandHoldBufs[slot], offset: 0, index: 3)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            case .spectrogram:
                enc.setRenderPipelineState(ctx.spectroPipeline)
                enc.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 0)
                enc.setFragmentBuffer(lut, offset: 0, index: 2)
                enc.setFragmentTexture(spectroTex ?? ctx.dummyTexture, index: 0)
                enc.setFragmentSamplerState(ctx.spectroSampler, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            enc.endEncoding()
        }
        if let d = drawable { cb.present(d) }

        // 6. Rest detection from GPU feedback (no stall: read in the completion handler).
        let energyBuf = energyBufs[slot], movingBuf = movingBufs[slot]
        let usesSim = mode != .bars && mode != .spectrogram
        let isSand = mode == .sand
        let grains = grainCount
        cb.addCompletedHandler { [weak self] buffer in
            guard let self else { return }
            let e = Float(energyBuf.contents().load(as: UInt32.self)) / 1e6
            let m = Int(movingBuf.contents().load(as: UInt32.self))
            self.restLock.lock()
            self.gpuEnergy = usesSim ? e : 0
            self.gpuMoving = isSand ? m : 0
            if grains == 0 { self.gpuMoving = 0 }
            self.restLock.unlock()
            if buffer.gpuEndTime > buffer.gpuStartTime {
                self.lastGPUTimeMS = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            }
            self.inflight.signal()
        }
        cb.commit()
        if waitUntilCompleted { cb.waitUntilCompleted() }

        // Rest = no signal, curves decayed, simulation settled, grains still, trails faded.
        restLock.lock()
        let settled = snapshotRest && gpuEnergy < 0.002 && gpuMoving <= max(grains / 100, 0)
        if settled {
            if quietSince == nil { quietSince = now }
            isAtRest = now - (quietSince ?? now) > (trails ? 1.6 : 0.3)
        } else {
            quietSince = nil
            isAtRest = false
        }
        restLock.unlock()
    }
}
