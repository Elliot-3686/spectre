import Metal
import QuartzCore
import SpectreCore

/// Device, queue, pipelines and palettes shared by every view.
final class RenderContext {
    static let shared: RenderContext? = try? RenderContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let colorFormat: MTLPixelFormat = .bgra8Unorm_srgb
    let trailFormat: MTLPixelFormat = .rgba16Float

    let liquidPipeline: MTLRenderPipelineState
    let barsPipeline: MTLRenderPipelineState
    let spectroPipeline: MTLRenderPipelineState
    let trailPipeline: MTLRenderPipelineState
    let grainPipeline: MTLRenderPipelineState
    let liquidStep: MTLComputePipelineState
    let sandStep: MTLComputePipelineState
    let duneUpdate: MTLComputePipelineState
    let spectroWrite: MTLComputePipelineState
    let linearClamp: MTLSamplerState
    let spectroSampler: MTLSamplerState
    let dummyTexture: MTLTexture

    private var luts: [ThemeKind: MTLBuffer] = [:]

    enum SetupError: Error { case noDevice, noLibrary, noFunction(String) }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw SetupError.noDevice }
        self.device = device
        guard let q = device.makeCommandQueue() else { throw SetupError.noDevice }
        queue = q
        guard let lib = device.makeDefaultLibrary() else { throw SetupError.noLibrary }

        func fn(_ name: String) throws -> MTLFunction {
            guard let f = lib.makeFunction(name: name) else { throw SetupError.noFunction(name) }
            return f
        }
        func render(_ vertex: String, _ fragment: String, format: MTLPixelFormat, blend: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = try fn(vertex)
            d.fragmentFunction = try fn(fragment)
            d.colorAttachments[0].pixelFormat = format
            if blend {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.rgbBlendOperation = .add
                a.alphaBlendOperation = .add
                a.sourceRGBBlendFactor = .sourceAlpha
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.sourceAlphaBlendFactor = .one
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        liquidPipeline = try render("fullscreenVertex", "fragLiquid", format: colorFormat)
        barsPipeline = try render("fullscreenVertex", "fragBars", format: colorFormat)
        spectroPipeline = try render("fullscreenVertex", "fragSpectro", format: colorFormat)
        trailPipeline = try render("fullscreenVertex", "fragTrail", format: trailFormat)
        grainPipeline = try render("grainVertex", "grainFragment", format: colorFormat, blend: true)
        liquidStep = try device.makeComputePipelineState(function: try fn("liquidStep"))
        sandStep = try device.makeComputePipelineState(function: try fn("sandStep"))
        duneUpdate = try device.makeComputePipelineState(function: try fn("duneUpdate"))
        spectroWrite = try device.makeComputePipelineState(function: try fn("spectroWrite"))

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        linearClamp = device.makeSamplerState(descriptor: sd)!
        let sp = MTLSamplerDescriptor()
        sp.minFilter = .linear; sp.magFilter = .linear
        sp.sAddressMode = .repeat; sp.tAddressMode = .clampToEdge
        spectroSampler = device.makeSamplerState(descriptor: sp)!

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        td.usage = [.shaderRead]
        td.storageMode = .private
        dummyTexture = device.makeTexture(descriptor: td)!
    }

    /// Max simulation columns (one threadgroup).
    var maxColumns: Int { min(512, liquidStep.maxTotalThreadsPerThreadgroup) }

    func lut(for theme: ThemeKind) -> MTLBuffer {
        if let b = luts[theme] { return b }
        let data = Palette.lut(theme)
        let b = device.makeBuffer(bytes: data, length: MemoryLayout<SIMD4<Float>>.stride * data.count, options: .storageModeShared)!
        luts[theme] = b
        return b
    }
}
