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
    var rotation: Double       // degrees (roll for 3D)
    var opacity: Double        // percent
    var z: Double = 0
    var rotX: Double = 0
    var rotY: Double = 0
}

struct RenderSnapshot {
    var time: Double
    var canvas: CGSize
    var fx: FXSettings
    var draws: [LayerDraw]
    var videos: [UUID: VideoSource]
    var models: [UUID: ModelAsset]
    var camera: CameraState
    var lights: [LightState]
    var lighting: LightingSettings

    static func make(layers: [Layer], videos: [UUID: VideoSource], models: [UUID: ModelAsset],
                     time: Double, canvas: CGSize, fx: FXSettings, lighting: LightingSettings,
                     engine: ExpressionEngine?) -> RenderSnapshot {
        var draws: [LayerDraw] = []
        var camera: CameraState?
        var lights: [LightState] = []
        let deg = Float.pi / 180

        for (i, l) in layers.enumerated() where l.isActive(at: time) {
            let idx = i + 1
            let world = WorldTransform.compute(l, in: layers, at: time, engine: engine)
            let z = l.value(.z, at: time, engine: engine, index: idx)
            let rotX = l.value(.rotX, at: time, engine: engine, index: idx)
            let rotY = l.value(.rotY, at: time, engine: engine, index: idx)
            let opacity = l.value(.opacity, at: time, engine: engine, index: idx)

            switch l.kind {
            case .null:
                break                                         // only used as a parent
            case .camera:
                let fov = l.value(.fov, at: time, engine: engine, index: idx)
                camera = CameraState(
                    position: SIMD3<Float>(Float(world.x), Float(world.y), Float(z)),
                    rotX: Float(rotX) * deg, rotY: Float(rotY) * deg, roll: Float(world.rotation) * deg,
                    fovY: Float(min(max(fov, 5), 150)) * deg)
            case .light:
                let intensity = Float(l.value(.intensity, at: time, engine: engine, index: idx)) / 100
                let cone = Float(l.value(.cone, at: time, engine: engine, index: idx))
                let rot = M4.rotation(rx: Float(rotX) * deg, ry: Float(rotY) * deg, rz: 0)
                let dir4 = rot * SIMD4<Float>(0, 0, 1, 0)
                let rgb = SIMD3<Float>(pow(Float(l.rgba[0]), 2.2), pow(Float(l.rgba[1]), 2.2), pow(Float(l.rgba[2]), 2.2))
                lights.append(LightState(type: l.lightType,
                                         position: SIMD3<Float>(Float(world.x), Float(world.y), Float(z)),
                                         direction: SIMD3<Float>(dir4.x, dir4.y, dir4.z),
                                         color: rgb, intensity: intensity,
                                         coneRadians: cone * 0.5 * deg, castsShadow: l.castsShadow))
            case .video, .text, .shape, .fill, .model:
                draws.append(LayerDraw(layer: l, x: world.x, y: world.y, scale: world.scale,
                                       rotation: world.rotation, opacity: opacity,
                                       z: z, rotX: rotX, rotY: rotY))
            }
        }
        return RenderSnapshot(time: time, canvas: canvas, fx: fx, draws: draws, videos: videos, models: models,
                              camera: camera ?? CameraState.standard(canvas: canvas),
                              lights: lights, lighting: lighting)
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
    private let fillPass: ContentFillPass?
    private let effects: EffectEngine?
    private let scene3D: Scene3DRenderer?
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
        self.fillPass = ContentFillPass(device: device, library: lib)
        self.effects = EffectEngine(device: device, library: lib)
        self.scene3D = Scene3DRenderer(device: device, library: lib)
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

        // Layers are drawn in one render pass; a content fill layer ends the pass, fills the picture
        // built so far with compute passes, then a new pass continues on top of the result.
        func beginPass(clear: Bool) -> MTLRenderCommandEncoder? {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = comp
            rpd.colorAttachments[0].loadAction = clear ? .clear : .load
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            let e = cb.makeRenderCommandEncoder(descriptor: rpd)
            e?.label = "Composite layers"
            e?.setFragmentSamplerState(sampler, index: 0)
            return e
        }

        // Effects run first, as compute passes on each layer's own texture.
        effects?.beginFrame()
        var layerTextures: [UUID: MTLTexture] = [:]
        for d in snap.draws where d.layer.kind.hasImage {
            guard var tex = texture(for: d.layer, snap) else { continue }
            if !d.layer.effects.isEmpty, let engine = effects {
                tex = engine.apply(d.layer.effects, to: tex, time: snap.time, commandBuffer: cb)
            }
            layerTextures[d.layer.id] = tex
        }

        func isThreeD(_ layer: Layer) -> Bool { layer.kind == .model || (layer.is3D && layer.kind.hasImage) }
        let threeDItems = snap.draws.filter { isThreeD($0.layer) }
        var drewThreeD = false

        var encoder = beginPass(clear: true)
        for d in snap.draws {
            if d.layer.kind == .fill {
                encoder?.endEncoding()
                encoder = nil
                fillPass?.encode(cb, comp: comp, params: fillParams(d, time: snap.time))
                encoder = beginPass(clear: false)
                continue
            }
            if isThreeD(d.layer) {
                // All 3D items render together, at the position of the lowest one in the stack.
                if !drewThreeD {
                    drewThreeD = true
                    encoder?.endEncoding()
                    encoder = nil
                    scene3D?.render(snapshot: snap, items: threeDItems, planeTextures: layerTextures,
                                    comp: comp, ringIndex: index, commandBuffer: cb)
                    encoder = beginPass(clear: false)
                }
                continue
            }
            guard let enc = encoder, d.layer.kind.hasImage, let tex = layerTextures[d.layer.id],
                  let pso = layerPSO[d.layer.blend] else { continue }
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
        encoder?.endEncoding()
                encoder = nil
                fillPass?.encode(cb, comp: comp, params: fillParams(d, time: snap.time))
                encoder = beginPass(clear: false)
                continue
            }
            guard let enc = encoder, let tex = texture(for: d.layer, snap),
                  let pso = layerPSO[d.layer.blend] else { continue }
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
        encoder?.endEncoding()

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
        case .fill, .null, .camera, .light, .model:
            return nil
        }
    }

    private func fillParams(_ d: LayerDraw, time: Double) -> FillParams {
        var p = FillParams()
        let s = Float(max(d.scale, 0) / 100)
        p.center = SIMD2<Float>(Float(d.x), Float(d.y))
        p.halfSize = SIMD2<Float>(Float(d.layer.shapeWidth) * s / 2, Float(d.layer.shapeHeight) * s / 2)
        p.rotation = Float(d.rotation * .pi / 180)
        p.feather = Float(max(d.layer.feather, 1))
        p.grain = Float(min(max(d.layer.grain, 0), 1))
        switch d.layer.shape {
        case .rectangle: p.shape = 0
        case .roundedRectangle: p.shape = 1
        case .ellipse: p.shape = 2
        }
        p.seed = Float((time * 30).rounded())
        return p
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
        compTargets = (0..<3).compactMap { _ in device.makeTexture(descriptor: compDesc) }
        fxTargets = (0..<3).compactMap { _ in device.makeTexture(descriptor: fxDesc) }
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
