import IOSurface
import Metal
import QuartzCore

/// Draws the display's current IOSurface into a CAMetalLayer, letterboxed
/// while a live resize is in progress. Frames are never encoded or copied on
/// the CPU (spec: "frame tidak perlu di-encode menjadi video").
final class MetalRenderer: @unchecked Sendable {
    let layer = CAMetalLayer()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let renderQueue = DispatchQueue(label: "dev.avo.render", qos: .userInteractive)
    private let lock = NSLock()
    private var textures: [MTLTexture] = []
    private var current: Int?
    private(set) var lastSequence: UInt64 = 0
    /// Called once on the main queue after the next frame is shown.
    private var onFirstFrame: (@MainActor () -> Void)?

    func whenNextFrameShown(_ callback: @escaping @MainActor () -> Void) {
        lock.withLock { onFirstFrame = callback }
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.displaySyncEnabled = true
        layer.maximumDrawableCount = 3

        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct Out { float4 position [[position]]; float2 uv; };
        vertex Out avo_vertex(uint id [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
            float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
            float2 c = corners[id];
            Out out;
            out.position = float4(rect.x + c.x * rect.z, rect.y - c.y * rect.w, 0, 1);
            out.uv = c;
            return out;
        }
        fragment float4 avo_fragment(Out in [[stage_in]], texture2d<float> frame [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            return frame.sample(s, in.uv);
        }
        """
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "avo_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "avo_fragment")
            descriptor.colorAttachments[0].pixelFormat = layer.pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }
    }

    /// Wraps the engine's swapchain (IOSurfaces shared through the daemon).
    func setSurfaces(_ surfaces: [IOSurface]) {
        let wrapped: [MTLTexture] = surfaces.compactMap { surface in
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: surface.width,
                                                                      height: surface.height, mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            return device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
        }
        lock.withLock {
            textures = wrapped
            current = nil
        }
    }

    func present(index: Int, sequence: UInt64) {
        renderQueue.async { [self] in
            let texture: MTLTexture? = lock.withLock {
                guard textures.indices.contains(index), sequence > lastSequence else { return nil }
                current = index
                lastSequence = sequence
                return textures[index]
            }
            guard let texture else { return }
            draw(texture)
            let callback: (@MainActor () -> Void)? = lock.withLock {
                defer { onFirstFrame = nil }
                return onFirstFrame
            }
            if let callback { DispatchQueue.main.async { MainActor.assumeIsolated { callback() } } }
        }
    }

    /// Redraws the last frame (after a resize, before the guest catches up).
    func redraw() {
        renderQueue.async { [self] in
            let texture: MTLTexture? = lock.withLock { current.flatMap { textures.indices.contains($0) ? textures[$0] : nil } }
            if let texture { draw(texture) }
        }
    }

    private func draw(_ texture: MTLTexture) {
        guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        // Aspect-fit the frame in the drawable, in normalized device coordinates.
        var rect = Self.fitRect(frame: CGSize(width: texture.width, height: texture.height),
                                in: CGSize(width: drawable.texture.width, height: drawable.texture.height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// (left, top, width, height) in NDC for an aspect-fit frame.
    static func fitRect(frame: CGSize, in target: CGSize) -> SIMD4<Float> {
        guard frame.width > 0, frame.height > 0, target.width > 0, target.height > 0 else { return SIMD4(-1, 1, 2, 2) }
        let scale = min(target.width / frame.width, target.height / frame.height)
        let width = Float(frame.width * scale / target.width * 2)
        let height = Float(frame.height * scale / target.height * 2)
        return SIMD4(-width / 2, height / 2, width, height)
    }
}
