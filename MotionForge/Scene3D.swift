// Scene3D.swift — camera and light state, matrices, GPU structs and 3D model loading.
//
// World space is composition space: x right and y down in pixels, z pointing into the screen.
// A layer at z = 0 seen by the default camera appears at exactly its 2D size and position.

import Metal
import MetalKit
import ModelIO
import simd

// MARK: - Matrices

enum M4 {
    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0),
                                SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(t.x, t.y, t.z, 1)))
    }

    static func scale(_ s: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4<Float>(s.x, 0, 0, 0), SIMD4<Float>(0, s.y, 0, 0),
                                SIMD4<Float>(0, 0, s.z, 0), SIMD4<Float>(0, 0, 0, 1)))
    }

    static func rotX(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, c, s, 0),
                                       SIMD4<Float>(0, -s, c, 0), SIMD4<Float>(0, 0, 0, 1)))
    }

    static func rotY(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (SIMD4<Float>(c, 0, -s, 0), SIMD4<Float>(0, 1, 0, 0),
                                       SIMD4<Float>(s, 0, c, 0), SIMD4<Float>(0, 0, 0, 1)))
    }

    static func rotZ(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (SIMD4<Float>(c, s, 0, 0), SIMD4<Float>(-s, c, 0, 0),
                                       SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(0, 0, 0, 1)))
    }

    /// Yaw (Y), then pitch (X), then roll (Z). Angles in radians.
    static func rotation(rx: Float, ry: Float, rz: Float) -> simd_float4x4 {
        rotY(ry) * rotX(rx) * rotZ(rz)
    }

    /// Perspective for a camera looking down +z, y down on screen. `width`/`height` only matter as a ratio.
    static func projection(width: Float, height: Float, fovY: Float, near: Float, far: Float) -> simd_float4x4 {
        let f = (height / 2) / tan(fovY / 2)
        let a = far / (far - near)
        let b = -far * near / (far - near)
        return simd_float4x4(columns: (SIMD4<Float>(2 * f / width, 0, 0, 0), SIMD4<Float>(0, -2 * f / height, 0, 0),
                                       SIMD4<Float>(0, 0, a, 1), SIMD4<Float>(0, 0, b, 0)))
    }

    static func ortho(extent: Float, near: Float, far: Float) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4<Float>(1 / extent, 0, 0, 0), SIMD4<Float>(0, -1 / extent, 0, 0),
                                SIMD4<Float>(0, 0, 1 / (far - near), 0), SIMD4<Float>(0, 0, -near / (far - near), 1)))
    }

    /// World matrix of something at `eye` looking along `forward` (used for light cameras).
    static func lookWorld(eye: SIMD3<Float>, forward: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(forward)
        var up = SIMD3<Float>(0, -1, 0)
        if abs(simd_dot(f, up)) > 0.99 { up = SIMD3<Float>(1, 0, 0) }
        let x = simd_normalize(simd_cross(up, f))
        let y = simd_cross(f, x)
        return simd_float4x4(columns: (SIMD4<Float>(x.x, x.y, x.z, 0), SIMD4<Float>(y.x, y.y, y.z, 0),
                                       SIMD4<Float>(f.x, f.y, f.z, 0), SIMD4<Float>(eye.x, eye.y, eye.z, 1)))
    }
}

// MARK: - Camera and lights

struct CameraState {
    var position: SIMD3<Float>
    var rotX: Float            // radians
    var rotY: Float
    var roll: Float
    var fovY: Float

    var viewMatrix: simd_float4x4 {
        simd_inverse(M4.translation(position) * M4.rotation(rx: rotX, ry: rotY, rz: roll))
    }

    /// The camera used when the project has no camera layer: looks straight at the composition.
    static func standard(canvas: CGSize, fovDegrees: Float = 40) -> CameraState {
        let fov = fovDegrees * Float.pi / 180
        let f = Float(canvas.height) / 2 / tan(fov / 2)
        return CameraState(position: SIMD3<Float>(Float(canvas.width) / 2, Float(canvas.height) / 2, -f),
                           rotX: 0, rotY: 0, roll: 0, fovY: fov)
    }
}

struct LightState {
    var type: LightType
    var position: SIMD3<Float>
    var direction: SIMD3<Float>      // the way the light travels
    var color: SIMD3<Float>
    var intensity: Float             // 1 = 100 %
    var coneRadians: Float
    var castsShadow: Bool
}

// MARK: - GPU structs (mirror of the MSL structs in Shaders.metal)

struct LightGPU {                         // stride 64
    var positionType = SIMD4<Float>(0, 0, 0, 0)    // xyz position, w type (0 ambient, 1 parallel, 2 point, 3 spot)
    var direction = SIMD4<Float>(0, 0, 1, 0)       // xyz direction, w cos(outer cone)
    var color = SIMD4<Float>(1, 1, 1, 1)           // rgb radiance, w cos(inner cone)
    var extra = SIMD4<Float>(0, 0, 0, 0)           // x: uses the shadow map
}

struct SceneGPU {                         // stride 176
    var viewProj = matrix_identity_float4x4
    var lightViewProj = matrix_identity_float4x4
    var camPos = SIMD4<Float>(0, 0, 0, 1)          // xyz camera position, w exposure
    var params = SIMD4<Float>(0.7, 0.0006, 1.5, 0) // x environment, y shadow bias, z shadow softness, w light count
    var flags: UInt32 = 0                          // bit 0 realistic, bit 1 shadows
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0
}

struct ModelGPU {                         // stride 112
    var model = matrix_identity_float4x4
    var baseColor = SIMD4<Float>(1, 1, 1, 1)
    var material = SIMD4<Float>(0, 0.5, 0, 1)      // metallic, roughness, has texture, lit
    var extra = SIMD4<Float>(1, 0, 0, 0)           // x opacity
}

// MARK: - Model asset

enum ModelError: LocalizedError {
    case empty, unreadable
    var errorDescription: String? {
        switch self {
        case .empty: return "That file doesn't contain any 3D geometry."
        case .unreadable: return "That 3D file couldn't be read. USDZ, USD, OBJ, PLY and STL are supported."
        }
    }
}

/// A loaded 3D model: GPU meshes plus per-part material information.
final class ModelAsset {
    struct Part {
        let meshIndex: Int
        let submeshIndex: Int
        let baseColor: SIMD3<Float>      // linear
        let texture: MTLTexture?
        let roughness: Float
        let metallic: Float
    }

    let meshes: [MTKMesh]
    let parts: [Part]
    let center: SIMD3<Float>
    /// Scale that makes the model's longest side 500 px at 100 % layer scale.
    let scaleToFit: Float

    private init(meshes: [MTKMesh], parts: [Part], center: SIMD3<Float>, scaleToFit: Float) {
        self.meshes = meshes
        self.parts = parts
        self.center = center
        self.scaleToFit = scaleToFit
    }

    static func load(url: URL, device: MTLDevice) throws -> ModelAsset {
        let vd = MDLVertexDescriptor()
        vd.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        vd.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
        vd.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 24, bufferIndex: 0)
        vd.layouts[0] = MDLVertexBufferLayout(stride: 32)

        let allocator = MTKMeshBufferAllocator(device: device)
        let asset = MDLAsset(url: url, vertexDescriptor: vd, bufferAllocator: allocator)
        asset.loadTextures()

        let ext = url.pathExtension.lowercased()
        let hasNormals = ["usd", "usda", "usdc", "usdz"].contains(ext)
        if !hasNormals, let meshes = asset.childObjects(of: MDLMesh.self) as? [MDLMesh] {
            for m in meshes { m.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5) }
        }

        let result: (modelIOMeshes: [MDLMesh], metalKitMeshes: [MTKMesh])
        do { result = try MTKMesh.newMeshes(asset: asset, device: device) } catch { throw ModelError.unreadable }
        guard !result.metalKitMeshes.isEmpty else { throw ModelError.empty }

        let loader = MTKTextureLoader(device: device)
        var parts: [Part] = []
        for (mi, mdl) in result.modelIOMeshes.enumerated() where mi < result.metalKitMeshes.count {
            let mtk = result.metalKitMeshes[mi]
            let subs = (mdl.submeshes as? [MDLSubmesh]) ?? []
            for (si, sub) in subs.enumerated() where si < mtk.submeshes.count {
                var color = SIMD3<Float>(0.8, 0.8, 0.8)
                var texture: MTLTexture?
                var roughness: Float = 0.5
                var metallic: Float = 0
                if let material = sub.material {
                    if let p = material.property(with: .baseColor) {
                        switch p.type {
                        case .float3:
                            let v = p.float3Value
                            color = SIMD3<Float>(pow(v.x, 2.2), pow(v.y, 2.2), pow(v.z, 2.2))
                        case .float4:
                            let v = p.float4Value
                            color = SIMD3<Float>(pow(v.x, 2.2), pow(v.y, 2.2), pow(v.z, 2.2))
                        case .color:
                            if let cg = p.color, let comps = cg.components, comps.count >= 3 {
                                color = SIMD3<Float>(pow(Float(comps[0]), 2.2), pow(Float(comps[1]), 2.2), pow(Float(comps[2]), 2.2))
                            }
                        case .texture:
                            if let t = p.textureSamplerValue?.texture {
                                texture = try? loader.newTexture(texture: t, options: [.SRGB: true])
                                color = SIMD3<Float>(1, 1, 1)
                            }
                        default:
                            break
                        }
                    }
                    if let r = material.property(with: .roughness), r.type == .float { roughness = r.floatValue }
                    if let m = material.property(with: .metallic), m.type == .float { metallic = m.floatValue }
                }
                parts.append(Part(meshIndex: mi, submeshIndex: si, baseColor: color, texture: texture,
                                  roughness: roughness, metallic: metallic))
            }
        }
        guard !parts.isEmpty else { throw ModelError.empty }

        let box = asset.boundingBox
        let center = (box.minBounds + box.maxBounds) * 0.5
        let extent = box.maxBounds - box.minBounds
        let longest = max(extent.x, max(extent.y, extent.z))
        let fit: Float = longest > 1e-6 ? 500 / longest : 1
        return ModelAsset(meshes: result.metalKitMeshes, parts: parts, center: center, scaleToFit: fit)
    }
}
