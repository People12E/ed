// Scene3DRenderer.swift — draws every 3D item (models and 3D layers) as one group on top of the picture built so far.
//
//   1. Shadow pass: models are drawn depth-only from the first shadow-casting spot or parallel light.
//   2. Colour pass with a depth buffer: opaque models first, then 3D layers back to front.
//
// Lighting is physically based (GGX specular, Fresnel, procedural sky and ground light, filmic tone mapping)
// when `LightingSettings.realistic` is on, and plain diffuse otherwise.

import Metal
import MetalKit
import simd

final class Scene3DRenderer {
    private struct Item {
        let draw: LayerDraw
        let asset: ModelAsset?
        let texture: MTLTexture?
        let matrix: simd_float4x4
        let viewDepth: Float
    }

    private let device: MTLDevice
    private let modelPSO: MTLRenderPipelineState
    private let planePSO: MTLRenderPipelineState
    private let shadowPSO: MTLRenderPipelineState
    private let depthWrite: MTLDepthStencilState
    private let depthTest: MTLDepthStencilState
    private let quadVB: MTLBuffer
    private let quadIB: MTLBuffer
    private let whiteTexture: MTLTexture
    private let shadowMap: MTLTexture
    private var depthTargets: [MTLTexture] = []

    init?(device: MTLDevice, library: MTLLibrary) {
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3
        vd.attributes[1].offset = 12
        vd.attributes[1].bufferIndex = 0
        vd.attributes[2].format = .float2
        vd.attributes[2].offset = 24
        vd.attributes[2].bufferIndex = 0
        vd.layouts[0].stride = 32

        func colorPSO(_ fragment: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "mesh_vertex")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.vertexDescriptor = vd
            let c = d.colorAttachments[0]!
            c.pixelFormat = .rgba16Float
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            d.depthAttachmentPixelFormat = .depth32Float
            return try? device.makeRenderPipelineState(descriptor: d)
        }

        let sd = MTLRenderPipelineDescriptor()
        sd.vertexFunction = library.makeFunction(name: "shadow_vertex")
        sd.vertexDescriptor = vd
        sd.depthAttachmentPixelFormat = .depth32Float

        func depthState(write: Bool) -> MTLDepthStencilState? {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = .lessEqual
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)
        }

        let verts: [Float] = [
            -0.5, -0.5, 0, 0, 0, -1, 0, 0,
             0.5, -0.5, 0, 0, 0, -1, 1, 0,
             0.5,  0.5, 0, 0, 0, -1, 1, 1,
            -0.5,  0.5, 0, 0, 0, -1, 0, 1
        ]
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]

        let wd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        wd.usage = .shaderRead
        let sdesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 2048, height: 2048, mipmapped: false)
        sdesc.usage = [.renderTarget, .shaderRead]
        sdesc.storageMode = .private

        guard let m = colorPSO("mesh_fragment"), let p = colorPSO("plane_fragment"),
              let s = try? device.makeRenderPipelineState(descriptor: sd),
              let dw = depthState(write: true), let dt = depthState(write: false),
              let vb = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<Float>.stride, options: []),
              let ib = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt16>.stride, options: []),
              let white = device.makeTexture(descriptor: wd),
              let shadow = device.makeTexture(descriptor: sdesc) else { return nil }

        var one: [UInt8] = [255, 255, 255, 255]
        white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &one, bytesPerRow: 4)

        self.device = device
        modelPSO = m
        planePSO = p
        shadowPSO = s
        depthWrite = dw
        depthTest = dt
        quadVB = vb
        quadIB = ib
        whiteTexture = white
        shadowMap = shadow
    }

    private func ensureDepth(width: Int, height: Int) {
        if depthTargets.first?.width == width && depthTargets.first?.height == height { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        d.usage = .renderTarget
        d.storageMode = .private
        depthTargets = (0..<3).compactMap { _ in device.makeTexture(descriptor: d) }
    }

    // MARK: Render

    func render(snapshot snap: RenderSnapshot, items draws: [LayerDraw], planeTextures: [UUID: MTLTexture],
                comp: MTLTexture, ringIndex: Int, commandBuffer cb: MTLCommandBuffer) {
        ensureDepth(width: comp.width, height: comp.height)
        guard ringIndex < depthTargets.count else { return }
        let width = Float(comp.width), height = Float(comp.height)
        let cam = snap.camera
        let view = cam.viewMatrix
        let proj = M4.projection(width: width, height: height, fovY: cam.fovY, near: 1, far: 100000)
        let deg = Float.pi / 180

        var models: [Item] = []
        var planes: [Item] = []
        for d in draws {
            let pos = SIMD3<Float>(Float(d.x), Float(d.y), Float(d.z))
            let rot = M4.rotation(rx: Float(d.rotX) * deg, ry: Float(d.rotY) * deg, rz: Float(d.rotation) * deg)
            let depth = (view * SIMD4<Float>(pos.x, pos.y, pos.z, 1)).z
            if d.layer.kind == .model {
                guard let asset = snap.models[d.layer.id] else { continue }
                let s = Float(max(d.scale, 0) / 100) * asset.scaleToFit
                // model space is y-up, z-toward-viewer; composition space is y-down, z-away: flip y and z
                let m = M4.translation(pos) * rot * M4.scale(SIMD3<Float>(s, s, s))
                    * M4.scale(SIMD3<Float>(1, -1, -1)) * M4.translation(-asset.center)
                models.append(Item(draw: d, asset: asset, texture: nil, matrix: m, viewDepth: depth))
            } else if let tex = planeTextures[d.layer.id] {
                let sc = Float(max(d.scale, 0) / 100)
                let m = M4.translation(pos) * rot * M4.scale(SIMD3<Float>(Float(tex.width) * sc, Float(tex.height) * sc, 1))
                planes.append(Item(draw: d, asset: nil, texture: tex, matrix: m, viewDepth: depth))
            }
        }
        planes.sort { $0.viewDepth > $1.viewDepth }
        if models.isEmpty && planes.isEmpty { return }

        // Lights. With none in the project, models get a soft default key light.
        var lights = snap.lights
        if lights.isEmpty && !models.isEmpty {
            lights = [LightState(type: .parallel, position: .zero,
                                 direction: simd_normalize(SIMD3<Float>(0.3, 0.55, 0.8)),
                                 color: SIMD3<Float>(1, 1, 1), intensity: 1, coneRadians: 0, castsShadow: true)]
        }
        lights = Array(lights.prefix(8))
        let realistic = snap.lighting.realistic
        var casterIndex: Int?
        if snap.lighting.shadows {
            casterIndex = lights.firstIndex(where: { $0.castsShadow && ($0.type == .spot || $0.type == .parallel) })
        }

        var lightGPU: [LightGPU] = []
        for (i, l) in lights.enumerated() {
            var g = LightGPU()
            let type: Float = l.type == .ambient ? 0 : l.type == .parallel ? 1 : l.type == .point ? 2 : 3
            g.positionType = SIMD4<Float>(l.position.x, l.position.y, l.position.z, type)
            let dir = simd_normalize(l.direction)
            g.direction = SIMD4<Float>(dir.x, dir.y, dir.z, cos(l.coneRadians))
            let gain: Float = l.type == .ambient ? 0.5 : 3.0
            let rgb = l.color * l.intensity * gain
            g.color = SIMD4<Float>(rgb.x, rgb.y, rgb.z, cos(l.coneRadians * 0.75))
            g.extra = SIMD4<Float>(i == casterIndex ? 1 : 0, 0, 0, 0)
            lightGPU.append(g)
        }

        var scene = SceneGPU()
        scene.viewProj = proj * view
        scene.camPos = SIMD4<Float>(cam.position.x, cam.position.y, cam.position.z, Float(snap.lighting.exposure))
        scene.params = SIMD4<Float>(Float(snap.lighting.environment), 0.0008,
                                    Float(snap.lighting.softness), Float(lightGPU.count))
        scene.flags = realistic ? 1 : 0

        // 1. shadow pass
        if let ci = casterIndex, !models.isEmpty {
            var center = SIMD3<Float>(0, 0, 0)
            for m in models { center += SIMD3<Float>(Float(m.draw.x), Float(m.draw.y), Float(m.draw.z)) }
            center /= Float(models.count)
            if let lvp = shadowMatrix(for: lights[ci], center: center) {
                scene.lightViewProj = lvp
                scene.flags |= 2
                let sp = MTLRenderPassDescriptor()
                sp.depthAttachment.texture = shadowMap
                sp.depthAttachment.loadAction = .clear
                sp.depthAttachment.clearDepth = 1.0
                sp.depthAttachment.storeAction = .store
                if let enc = cb.makeRenderCommandEncoder(descriptor: sp) {
                    enc.label = "Shadow map"
                    enc.setRenderPipelineState(shadowPSO)
                    enc.setDepthStencilState(depthWrite)
                    var matrix = lvp
                    enc.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                    for item in models { drawModel(enc, item, planeLit: true, shadowOnly: true) }
                    enc.endEncoding()
                }
            }
        }

        // 2. colour pass
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = comp
        rp.colorAttachments[0].loadAction = .load
        rp.colorAttachments[0].storeAction = .store
        rp.depthAttachment.texture = depthTargets[ringIndex]
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.clearDepth = 1.0
        rp.depthAttachment.storeAction = .dontCare
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.label = "3D layers and models"

        enc.setVertexBytes(&scene, length: MemoryLayout<SceneGPU>.stride, index: 1)
        enc.setFragmentBytes(&scene, length: MemoryLayout<SceneGPU>.stride, index: 1)
        if lightGPU.isEmpty { lightGPU = [LightGPU()] }
        lightGPU.withUnsafeBytes { raw in
            if let base = raw.baseAddress { enc.setFragmentBytes(base, length: raw.count, index: 3) }
        }
        enc.setFragmentTexture(shadowMap, index: 1)

        enc.setRenderPipelineState(modelPSO)
        enc.setDepthStencilState(depthWrite)
        let anyLight = !snap.lights.isEmpty || realistic
        for item in models { drawModel(enc, item, planeLit: anyLight, shadowOnly: false) }

        enc.setRenderPipelineState(planePSO)
        enc.setDepthStencilState(depthTest)
        for item in planes {
            guard let tex = item.texture else { continue }
            var u = ModelGPU()
            u.model = item.matrix
            let lit = item.draw.layer.acceptsLights && anyLight
            u.material = SIMD4<Float>(0, 0.8, 0, lit ? 1 : 0)
            u.extra = SIMD4<Float>(Float(min(max(item.draw.opacity / 100, 0), 1)), 0, 0, 0)
            enc.setVertexBuffer(quadVB, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<ModelGPU>.stride, index: 2)
            enc.setFragmentBytes(&u, length: MemoryLayout<ModelGPU>.stride, index: 2)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint16,
                                      indexBuffer: quadIB, indexBufferOffset: 0)
        }
        enc.endEncoding()
    }

    private func drawModel(_ enc: MTLRenderCommandEncoder, _ item: Item, planeLit: Bool, shadowOnly: Bool) {
        guard let asset = item.asset else { return }
        let layer = item.draw.layer
        let c = layer.rgba
        let tint = SIMD3<Float>(pow(Float(c[0]), 2.2), pow(Float(c[1]), 2.2), pow(Float(c[2]), 2.2))
        let useLayerMaterial = layer.metallic != 0 || layer.roughness != 0.5
        for part in asset.parts {
            let mesh = asset.meshes[part.meshIndex]
            guard let vb = mesh.vertexBuffers.first else { continue }
            let sub = mesh.submeshes[part.submeshIndex]
            var u = ModelGPU()
            u.model = item.matrix
            let base = part.baseColor * tint
            u.baseColor = SIMD4<Float>(base.x, base.y, base.z, 1)
            let metallic = useLayerMaterial ? Float(layer.metallic) : part.metallic
            let roughness = useLayerMaterial ? Float(layer.roughness) : part.roughness
            u.material = SIMD4<Float>(metallic, roughness, part.texture != nil ? 1 : 0, 1)
            u.extra = SIMD4<Float>(Float(min(max(item.draw.opacity / 100, 0), 1)), 0, 0, 0)
            enc.setVertexBuffer(vb.buffer, offset: vb.offset, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<ModelGPU>.stride, index: 2)
            if !shadowOnly {
                enc.setFragmentBytes(&u, length: MemoryLayout<ModelGPU>.stride, index: 2)
                enc.setFragmentTexture(part.texture ?? whiteTexture, index: 0)
            }
            enc.drawIndexedPrimitives(type: sub.primitiveType, indexCount: sub.indexCount, indexType: sub.indexType,
                                      indexBuffer: sub.indexBuffer.buffer, indexBufferOffset: sub.indexBuffer.offset)
        }
    }

    private func shadowMatrix(for light: LightState, center: SIMD3<Float>) -> simd_float4x4? {
        switch light.type {
        case .parallel:
            let dir = simd_normalize(light.direction)
            let world = M4.lookWorld(eye: center - dir * 3000, forward: dir)
            return M4.ortho(extent: 1400, near: 100, far: 6000) * simd_inverse(world)
        case .spot:
            let world = M4.lookWorld(eye: light.position, forward: light.direction)
            let fov = min(light.coneRadians * 2 + 0.2, 2.6)
            return M4.projection(width: 1, height: 1, fovY: fov, near: 20, far: 8000) * simd_inverse(world)
        case .point, .ambient:
            return nil
        }
    }
}
