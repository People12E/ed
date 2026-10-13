// Fill.swift — content fill for a rectangular / elliptical region.
//
// Method: push-pull (pyramid) diffusion inpainting.
//   1. Pixels inside the region are marked unknown, the rest keep their colour and a weight of 1.
//   2. The image is averaged down a pyramid, weighting by how much of each texel is known.
//   3. Going back up, unknown texels take their colour from the coarser level.
//   4. The filled result is blended in with a soft edge and a little grain.
// It produces a smooth fill from the surroundings, good for removing small objects, logos and text on
// even backgrounds. It does not synthesise texture the way patch-based fill does.

import Metal
import simd

struct FillParams {                      // mirror of `FillParams` in Shaders.metal (stride 40)
    var center = SIMD2<Float>(0, 0)
    var halfSize = SIMD2<Float>(100, 100)
    var rotation: Float = 0
    var feather: Float = 24
    var grain: Float = 0
    var shape: UInt32 = 0                // 0 rectangle, 1 rounded, 2 ellipse
    var seed: Float = 0
    var pad: Float = 0
}

final class ContentFillPass {
    private let device: MTLDevice
    private let preparePSO: MTLComputePipelineState
    private let downPSO: MTLComputePipelineState
    private let upPSO: MTLComputePipelineState
    private let compositePSO: MTLComputePipelineState

    private var down: [MTLTexture] = []
    private var up: [MTLTexture] = []
    private var scratch: MTLTexture?
    private var width = 0
    private var height = 0

    init?(device: MTLDevice, library: MTLLibrary) {
        func makePSO(_ name: String) -> MTLComputePipelineState? {
            guard let f = library.makeFunction(name: name) else { return nil }
            return try? device.makeComputePipelineState(function: f)
        }
        guard let a = makePSO("fill_prepare"), let b = makePSO("fill_down"),
              let c = makePSO("fill_up"), let d = makePSO("fill_composite") else { return nil }
        self.device = device
        preparePSO = a
        downPSO = b
        upPSO = c
        compositePSO = d
    }

    private func makeTexture(_ w: Int, _ h: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    private func ensureTextures(_ w: Int, _ h: Int) {
        if width == w && height == h && scratch != nil { return }
        width = w
        height = h
        down = []
        up = []
        var lw = w, lh = h
        while true {
            if let t = makeTexture(lw, lh) { down.append(t) }
            if let t = makeTexture(lw, lh) { up.append(t) }
            if lw <= 1 && lh <= 1 { break }
            lw = max(1, (lw + 1) / 2)
            lh = max(1, (lh + 1) / 2)
        }
        scratch = makeTexture(w, h)
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState, _ target: MTLTexture) {
        let w = pso.threadExecutionWidth
        let h = max(1, pso.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    /// Fills the region in `comp` (in place: result goes through a scratch texture and is blitted back).
    func encode(_ cb: MTLCommandBuffer, comp: MTLTexture, params: FillParams) {
        ensureTextures(comp.width, comp.height)
        guard let scratch, down.count >= 2, down.count == up.count,
              let enc = cb.makeComputeCommandEncoder() else { return }
        enc.label = "Content fill"
        var p = params

        // 1. unknown region -> weights
        enc.setComputePipelineState(preparePSO)
        enc.setTexture(comp, index: 0)
        enc.setTexture(down[0], index: 1)
        enc.setBytes(&p, length: MemoryLayout<FillParams>.stride, index: 0)
        dispatch(enc, preparePSO, down[0])

        // 2. pyramid down
        enc.setComputePipelineState(downPSO)
        for l in 0..<(down.count - 1) {
            enc.setTexture(down[l], index: 0)
            enc.setTexture(down[l + 1], index: 1)
            dispatch(enc, downPSO, down[l + 1])
        }

        // 3. pyramid up, filling unknown texels from the coarser level
        enc.setComputePipelineState(upPSO)
        var coarse = down[down.count - 1]
        for l in stride(from: down.count - 2, through: 0, by: -1) {
            enc.setTexture(down[l], index: 0)
            enc.setTexture(coarse, index: 1)
            enc.setTexture(up[l], index: 2)
            dispatch(enc, upPSO, up[l])
            coarse = up[l]
        }

        // 4. blend into the picture
        enc.setComputePipelineState(compositePSO)
        enc.setTexture(comp, index: 0)
        enc.setTexture(up[0], index: 1)
        enc.setTexture(scratch, index: 2)
        enc.setBytes(&p, length: MemoryLayout<FillParams>.stride, index: 0)
        dispatch(enc, compositePSO, scratch)
        enc.endEncoding()

        // 5. copy back
        if let blit = cb.makeBlitCommandEncoder() {
            blit.label = "Content fill copy-back"
            blit.copy(from: scratch, to: comp)
            blit.endEncoding()
        }
    }
}
