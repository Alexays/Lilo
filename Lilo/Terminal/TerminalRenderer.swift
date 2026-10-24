import Metal

/// Matches `Uniforms` in TerminalShaders.metal: keep both in sync.
struct TerminalUniforms {
    var viewport: SIMD2<Float> = .zero
    var cellSize: SIMD2<Float> = .zero
    var padding: SIMD2<Float> = .zero
    var grid: SIMD2<UInt32> = .zero
    var background: SIMD4<Float> = .zero
    var cursorColor: SIMD4<Float> = .zero
    var cursorTextColor: SIMD4<Float> = .zero
    var cursorRect: SIMD4<Float> = .zero
    var cursorAlpha: Float = 0
    var cursorStyle: UInt32 = 0
    /// Pixels the grid is pushed down while scrolling by less than a row.
    var scrollOffset: Float = 0
}

/// GPU side of a terminal view: two pipelines and triple-buffered per-frame data. Encodes one frame
/// from a `TerminalFrameBuilder` into any texture (a drawable, or an offscreen target).
final class TerminalRenderer {
    static let pixelFormat = MTLPixelFormat.bgra8Unorm
    private static let framesInFlight = 3
    /// Every terminal draws with the same device and pipelines: compiled once, on first use.
    private static let shared: (device: MTLDevice, background: MTLRenderPipelineState, text: MTLRenderPipelineState)? = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeDefaultLibrary(bundle: .main) else { return nil }
        let background = MTLRenderPipelineDescriptor()
        background.vertexFunction = library.makeFunction(name: "backgroundVertex")
        background.fragmentFunction = library.makeFunction(name: "backgroundFragment")
        background.colorAttachments[0].pixelFormat = TerminalRenderer.pixelFormat
        let text = MTLRenderPipelineDescriptor()
        text.vertexFunction = library.makeFunction(name: "textVertex")
        text.fragmentFunction = library.makeFunction(name: "textFragment")
        let attachment = text.colorAttachments[0]!
        attachment.pixelFormat = TerminalRenderer.pixelFormat
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let backgroundPipeline = try? device.makeRenderPipelineState(descriptor: background),
              let textPipeline = try? device.makeRenderPipelineState(descriptor: text) else { return nil }
        return (device, backgroundPipeline, textPipeline)
    }()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let backgroundPipeline: MTLRenderPipelineState
    private let textPipeline: MTLRenderPipelineState
    private var backgroundBuffers: [MTLBuffer?]
    private var instanceBuffers: [MTLBuffer?]
    private var instanceCounts = Array(repeating: 0, count: TerminalRenderer.framesInFlight)
    /// One bit per buffer slot: set while that slot holds the frame builder's latest content.
    private var currentSlots = 0
    private var frameIndex = 0
    private let inFlight = DispatchSemaphore(value: TerminalRenderer.framesInFlight)

    init?() {
        guard let shared = Self.shared, let queue = shared.device.makeCommandQueue() else { return nil }
        device = shared.device
        self.queue = queue
        backgroundPipeline = shared.background
        textPipeline = shared.text
        backgroundBuffers = Array(repeating: nil, count: Self.framesInFlight)
        instanceBuffers = Array(repeating: nil, count: Self.framesInFlight)
    }

    /// Returns once no frame is left on the GPU, so shared textures can be rewritten safely.
    func waitUntilIdle() {
        for _ in 0..<Self.framesInFlight { inFlight.wait() }
        for _ in 0..<Self.framesInFlight { inFlight.signal() }
    }

    /// Blocks while three frames are already on the GPU, then encodes and commits this one.
    /// `contentChanged` false reuses what the slot already holds when it is the latest content.
    func render(
        _ frame: TerminalFrameBuilder, uniforms: TerminalUniforms, into texture: MTLTexture, present: MTLDrawable? = nil,
        contentChanged: Bool = true
    ) {
        inFlight.wait()
        frameIndex = (frameIndex + 1) % Self.framesInFlight
        if contentChanged { currentSlots = 0 }
        let cellCount = max(1, frame.cols * (frame.rows + 2))
        let backgrounds = buffer(&backgroundBuffers, bytes: cellCount * MemoryLayout<UInt32>.stride)
        let capacity = max(64, frame.instanceCount)
        let instances = buffer(&instanceBuffers, bytes: capacity * MemoryLayout<GlyphInstance>.stride)
        if currentSlots & (1 << frameIndex) == 0 {
            frame.backgrounds.withUnsafeBytes { source in
                backgrounds.contents().copyMemory(from: source.baseAddress!, byteCount: min(source.count, backgrounds.length))
            }
            instanceCounts[frameIndex] = frame.copyInstances(
                to: instances.contents().bindMemory(to: GlyphInstance.self, capacity: capacity), capacity: capacity
            )
            currentSlots |= 1 << frameIndex
        }
        let instanceCount = instanceCounts[frameIndex]

        guard let commands = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        var uniforms = uniforms
        if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(backgroundPipeline)
            encoder.setFragmentBuffer(backgrounds, offset: 0, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TerminalUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            if instanceCount > 0 {
                // Rows only: the left padding keeps the command marks, the top and bottom never
                // show the overscan rows built for smooth scrolling.
                let top = min(max(Int(uniforms.padding.y), 0), texture.height)
                let height = min(Int(uniforms.cellSize.y * Float(uniforms.grid.y)), texture.height - top)
                encoder.setScissorRect(MTLScissorRect(x: 0, y: top, width: texture.width, height: max(height, 0)))
                encoder.setRenderPipelineState(textPipeline)
                encoder.setVertexBuffer(instances, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<TerminalUniforms>.stride, index: 1)
                encoder.setFragmentTexture(frame.atlas.grayTexture, index: 0)
                encoder.setFragmentTexture(frame.atlas.colorTexture, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instanceCount)
            }
            encoder.endEncoding()
        }
        if let present { commands.present(present) }
        let inFlight = inFlight
        commands.addCompletedHandler { _ in inFlight.signal() }
        commands.commit()
    }

    /// The current frame's buffer, regrown (to the next power of two) only when the frame outgrows it.
    private func buffer(_ buffers: inout [MTLBuffer?], bytes: Int) -> MTLBuffer {
        if let existing = buffers[frameIndex], existing.length >= bytes { return existing }
        let grown = device.makeBuffer(length: max(4096, 1 << (Int.bitWidth - (bytes - 1).leadingZeroBitCount)), options: [.storageModeShared, .cpuCacheModeWriteCombined])!
        buffers[frameIndex] = grown
        return grown
    }
}
