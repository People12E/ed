// Compositor.swift — turns a RenderSnapshot into pixels.
//
//   layers --(transform quad, blend)--> comp target (rgba16Float, linear)
//          --(displace + chromatic aberration compute)--> fx target
//   present pass converts to display (or to an export buffer) and draws the compare split.

import Metal
import MetalKit
import simd

// MARK: - Snapshot (value types, safe to build and render on any thread)

struct LayerDraw {
    var layer: Layer
    var x: Double
    var y: Double
    var scale: Double          // percent
    var rotation: Double       // degrees
    var opacity: Double        // percent
}

struct RenderSnapshot {
    var time: Double
    var canvas: CGSize
    var fx: FXSettings
    var draws: [LayerDraw]
    var videos: [UUID: VideoSource]

    static func make(layers: [Layer], videos: [UUID: VideoSource], time: Double, canvas: CGSize,
                     fx: FXSettings, engine: ExpressionEngine?) -> RenderSnapshot {
        var draws: [LayerDraw] = []
        for (i, l) in layers.enumerated() where l.isActive(at: time) {
            draws.append(LayerDraw(
                layer: l,
                x: l.value(.x, at: time, engine: engine, index: i + 1),
                y: l.value(.y, at: time, engine: engine, index: i + 1),
                scale: l.value(.scale, at: time, engine: engine, index: i + 1),
                rotation: l.value(.rotation, at: time, engine: engine, index: i + 1),
                opacity: l.value(.opacity, at: time, engine: engine, index: i + 1)))
        }
        return RenderSnapshot(time: time, canvas: canvas, fx: fx, draws: draws, videos: videos)
    }
}

// MARK: - Present pass

final class PresentPass {
    private let pso: MTLRenderPipelineState
    private struct Uniforms { var splitX: Float; var viewportWidth: Float }

    init?(device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat) {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "present_vertex")
        d.fragmentFunction = library.makeFunction(name: "present_fragment")
        d.colorAttachments[0].pixelFormat = pixelFormat
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        pso = p
    }

    func encode(_ cb: MTLCommandBuffer, pass: MTLRenderPassDescriptor,
                processed: MTLTexture, original: MTLTexture, splitX: Float, viewportWidth: Float) {
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "Present"
        var u = Uniforms(splitX: splitX, viewportWidth: viewportWidth)
        enc.setRenderPipelineState(pso)
        enc.setFragmentTexture(processed, index: 0)
        enc.setFragmentTexture(original, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}

// MARK: - Compositor

final class LayerCompositor {
    /// true = decode the exact frame on this thread (export). false = latest available frame (preview).
    var syncVideo = false

    private struct LayerUniforms {
        var center: SIMD2<Float>
        var halfSize: SIMD2<Float>
        var compSize: SIMD2<Float>
        var rotation: Float
        var opacity: Float
    }

    private let device: MTLDevice
    private let displace: DisplaceChromaticPass
    private let layerPSO: [BlendKind: MTLRenderPipelineState]
    private let sampler: MTLSamplerState
    private let store: LayerTextureStore
    private let rippleMap: MTLTexture?
    private var compTargets: [MTLTexture] = []
    private var fxTargets: [MTLTexture] = []
    private var index = 0

    init?(device: MTLDevice) {
        guard let lib = device.makeDefaultLibrary(),
              let pass = try? DisplaceChromaticPass(device: device, library: lib) else { return nil }

        var psos: [BlendKind: MTLRenderPipelineState] = [:]
        for kind in BlendKind.allCases {
            guard let pso = Self.makePSO(device: device, library: lib, blend: kind) else { return nil }
            psos[kind] = pso
        }

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let smp = device.makeSamplerState(descriptor: sd) else { return nil }

        self.device = device
        self.displace = pass
        self.layerPSO = psos
        self.sampler = smp
        self.store = LayerTextureStore(device: device)
        self.rippleMap = Self.makeRippleMap(device: device)
    }

    private static func makePSO(device: MTLDevice, library: MTLLibrary, blend: BlendKind) -> MTLRenderPipelineState? {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "layer_vertex")
        d.fragmentFunction = library.makeFunction(name: "layer_fragment")
        let c = d.colorAttachments[0]!
        c.pixelFormat = .rgba16Float
        c.isBlendingEnabled = true

        // Output is premultiplied, so the "over" source factor is .one.
        let factors: (MTLBlendFactor, MTLBlendFactor)
        switch blend {
        case .normal:   factors = (.one, .oneMinusSourceAlpha)
        case .add:      factors = (.one, .one)
        case .screen:   factors = (.one, .oneMinusSourceColor)
        case .multiply: factors = (.destinationColor, .oneMinusSourceAlpha)
        }
        c.sourceRGBBlendFactor = factors.0
        c.sourceAlphaBlendFactor = factors.0
        c.destinationRGBBlendFactor = factors.1
        c.destinationAlphaBlendFactor = factors.1
        return try? device.makeRenderPipelineState(descriptor: d)
    }

    // MARK: Render

    func render(_ snap: RenderSnapshot, commandBuffer cb: MTLCommandBuffer)
        -> (processed: MTLTexture, original: MTLTexture)? {
        let w = Int(snap.canvas.width), h = Int(snap.canvas.height)
        guard w > 0, h > 0 else { return nil }
        ensureTargets(width: w, height: h)
        index = (index + 1) % 3
        let comp = compTargets[index], out = fxTargets[index]

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = comp
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.label = "Composite layers"
            enc.setFragmentSamplerState(sampler, index: 0)
            for d in snap.draws {
                guard let tex = texture(for: d.layer, snap), let pso = layerPSO[d.layer.blend] else { continue }
                let s = Float(max(d.scale, 0) / 100)
                var u = LayerUniforms(
                    center: SIMD2<Float>(Float(d.x), Float(d.y)),
                    halfSize: SIMD2<Float>(Float(tex.width) * s / 2, Float(tex.height) * s / 2),
                    compSize: SIMD2<Float>(Float(w), Float(h)),
                    rotation: Float(d.rotation * .pi / 180),
                    opacity: Float(min(max(d.opacity / 100, 0), 1)))
                enc.setRenderPipelineState(pso)
                enc.setVertexBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
                enc.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
                enc.setFragmentTexture(tex, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            enc.endEncoding()
        }

        var params = snap.fx.shaderParams(time: snap.time)
        var map: MTLTexture? = snap.fx.displaceEnabled ? rippleMap : nil
        if !snap.fx.enabled {
            params = DisplaceChromaticParams()
            params.caAmount = 0
            map = nil
        }
        displace.encode(cb, source: comp, map: map, output: out, params: params)
        return (out, comp)
    }

    private func texture(for layer: Layer, _ snap: RenderSnapshot) -> MTLTexture? {
        switch layer.kind {
        case .video:
            guard let source = snap.videos[layer.id] else { return nil }
            let t = snap.time - layer.start
            return syncVideo ? source.frameSync(at: t) : source.texture(at: t)
        case .text, .shape:
            return store.texture(for: layer)
        }
    }

    private func ensureTargets(width: Int, height: Int) {
        if compTargets.first?.width == width && compTargets.first?.height == height { return }
        let compDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                width: width, height: height, mipmapped: false)
        compDesc.usage = [.renderTarget, .shaderRead]
        compDesc.storageMode = .private
        let fxDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                              width: width, height: height, mipmapped: false)
        fxDesc.usage = [.shaderRead, .shaderWrite]
        fxDesc.storageMode = .private
        compTargets = (0..<3).compactMap { device.makeTexture(descriptor: compDesc) }
        fxTargets = (0..<3).compactMap { device.makeTexture(descriptor: fxDesc) }
    }

    /// Procedural displacement map (R/G carry the x/y offset, 0.5 = no movement).
    private static func makeRippleMap(device: MTLDevice, width: Int = 512, height: Int = 512) -> MTLTexture? {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let r = 0.5 + 0.5 * sin(Float(x) * 0.05 + Float(y) * 0.02)
                let g = 0.5 + 0.5 * cos(Float(y) * 0.06)
                let i = (y * width + x) * 4
                px[i] = UInt8(r * 255)
                px[i + 1] = UInt8(g * 255)
                px[i + 2] = 128
            }
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,   // data, not color
                                                         width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                  withBytes: px, bytesPerRow: width * 4)
        return t
    }
}
