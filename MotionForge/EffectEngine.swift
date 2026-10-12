// EffectEngine.swift — applies a layer's effect stack on the GPU.
// Each effect is one or more passes of the `effect_apply` kernel, ping-ponging through pooled textures.

import Metal
import simd

struct EffectGPUParams {                      // mirror of `EffectParams` in Shaders.metal (stride 160)
    var p0 = SIMD4<Float>(0, 0, 0, 0)
    var p1 = SIMD4<Float>(0, 0, 0, 0)
    var p2 = SIMD4<Float>(0, 0, 0, 0)
    var p3 = SIMD4<Float>(0, 0, 0, 0)
    var c0 = SIMD4<Float>(0, 0, 0, 1)
    var c1 = SIMD4<Float>(0, 0, 0, 1)
    var c2 = SIMD4<Float>(0, 0, 0, 1)
    var c3 = SIMD4<Float>(0, 0, 0, 1)
    var size = SIMD2<Float>(0, 0)
    var time: Float = 0
    var kernelID: UInt32 = 0
    var pass = SIMD4<Float>(0, 0, 0, 0)
}

/// Textures for effect passes. Three sets are rotated per frame so frames in flight never share a texture.
final class EffectTexturePool {
    private let device: MTLDevice
    private var sets: [[String: [MTLTexture]]] = [[:], [:], [:]]
    private var cursor: [String: Int] = [:]
    private var frame = 0

    init(device: MTLDevice) { self.device = device }

    func beginFrame() {
        frame = (frame + 1) % 3
        cursor = [:]
    }

    func acquire(width: Int, height: Int) -> MTLTexture? {
        let key = "\(width)x\(height)"
        let i = cursor[key, default: 0]
        cursor[key] = i + 1
        if let existing = sets[frame][key], i < existing.count { return existing[i] }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        sets[frame][key, default: []].append(t)
        return t
    }
}

final class EffectEngine {
    private let pso: MTLComputePipelineState
    private let pool: EffectTexturePool

    init?(device: MTLDevice, library: MTLLibrary) {
        guard let fn = library.makeFunction(name: "effect_apply"),
              let state = try? device.makeComputePipelineState(function: fn) else { return nil }
        pso = state
        pool = EffectTexturePool(device: device)
    }

    func beginFrame() { pool.beginFrame() }

    /// Runs every enabled effect in order and returns the texture holding the result
    /// (the input itself when nothing needed to run).
    func apply(_ effects: [EffectInstance], to input: MTLTexture, time: Double,
               commandBuffer cb: MTLCommandBuffer) -> MTLTexture {
        let active = effects.filter { $0.enabled && EffectRegistry.def(named: $0.effect) != nil }
        guard !active.isEmpty, let enc = cb.makeComputeCommandEncoder() else { return input }
        enc.label = "Layer effects"
        enc.setComputePipelineState(pso)

        var current = input
        for instance in active {
            guard let def = EffectRegistry.def(named: instance.effect) else { continue }
            let original = current                      // what glow and drop shadow combine with
            var params = Self.pack(def: def, instance: instance,
                                   size: SIMD2<Float>(Float(input.width), Float(input.height)), time: Float(time))
            for (n, pass) in def.passes.enumerated() {
                guard let out = pool.acquire(width: input.width, height: input.height) else { continue }
                params.kernelID = pass.kernel
                params.pass = SIMD4<Float>(pass.dirX, pass.dirY, Float(n), pass.radiusSlot)
                enc.setTexture(current, index: 0)
                enc.setTexture(out, index: 1)
                enc.setTexture(original, index: 2)
                enc.setBytes(&params, length: MemoryLayout<EffectGPUParams>.stride, index: 0)
                let w = pso.threadExecutionWidth
                let h = max(1, pso.maxTotalThreadsPerThreadgroup / w)
                enc.dispatchThreads(MTLSize(width: out.width, height: out.height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
                current = out
            }
        }
        enc.endEncoding()
        return current
    }

    static func pack(def: EffectDef, instance: EffectInstance, size: SIMD2<Float>, time: Float) -> EffectGPUParams {
        var f = [Float](repeating: 0, count: 16)
        for (i, s) in def.sliders.enumerated() where i < 16 {
            f[i] = Float(instance.params[s.key] ?? s.def)
        }
        var cols = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 1), count: 4)
        for (i, c) in def.colors.enumerated() where i < 4 {
            cols[i] = SIMD4<Float>(Float(instance.params[c.key + ".r"] ?? c.def[0]),
                                   Float(instance.params[c.key + ".g"] ?? c.def[1]),
                                   Float(instance.params[c.key + ".b"] ?? c.def[2]), 1)
        }
        var p = EffectGPUParams()
        p.p0 = SIMD4<Float>(f[0], f[1], f[2], f[3])
        p.p1 = SIMD4<Float>(f[4], f[5], f[6], f[7])
        p.p2 = SIMD4<Float>(f[8], f[9], f[10], f[11])
        p.p3 = SIMD4<Float>(f[12], f[13], f[14], f[15])
        p.c0 = cols[0]; p.c1 = cols[1]; p.c2 = cols[2]; p.c3 = cols[3]
        p.size = size
        p.time = time
        return p
    }
}
