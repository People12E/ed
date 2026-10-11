// Effects.swift — shader parameter block and the displace + chromatic aberration compute pass.

import Metal
import simd

enum PipelineError: Error { case missingFunction(String), pixelBuffer, textureCache }

// MARK: - Shader parameter block (mirror of `DCParams` in Shaders.metal)

struct DisplaceChromaticParams {
    var displaceScale   = SIMD2<Float>(24, 24)
    var mapOffset       = SIMD2<Float>(0, 0)
    var mapTile         = SIMD2<Float>(1, 1)
    var caCenter        = SIMD2<Float>(0.5, 0.5)
    var turbOffset      = SIMD2<Float>(0, 0)
    var caAmount: Float = 6
    var caFalloff: Float = 1.6
    var turbAmount: Float = 0
    var turbSize: Float = 120
    var turbEvolution: Float = 0
    var mapChannelX: UInt32 = 0          // R
    var mapChannelY: UInt32 = 1          // G
    var edgeMode: UInt32 = 0             // clamp
    var spectralSamples: UInt32 = 9
    var flags: UInt32 = 0

    static let useMap:  UInt32 = 1 << 0
    static let useTurb: UInt32 = 1 << 1
}

extension FXSettings {
    func shaderParams(time: Double) -> DisplaceChromaticParams {
        var p = DisplaceChromaticParams()
        p.displaceScale   = SIMD2<Float>(Float(displaceScale), Float(displaceScale))
        p.caAmount        = Float(caAmount)
        p.caFalloff       = Float(caFalloff)
        p.turbAmount      = Float(turbulence)
        p.turbEvolution   = Float(time * 0.35)
        p.spectralSamples = caAmount > 12 ? 15 : 9
        if turbulence > 0 { p.flags |= DisplaceChromaticParams.useTurb }
        return p
    }
}

// MARK: - Compute pass

final class DisplaceChromaticPass {
    private let pso: MTLComputePipelineState

    init(device: MTLDevice, library: MTLLibrary) throws {
        precondition(MemoryLayout<DisplaceChromaticParams>.stride == 80,
                     "Swift/MSL parameter layout drifted")
        guard let fn = library.makeFunction(name: "displaceChromaticKernel") else {
            throw PipelineError.missingFunction("displaceChromaticKernel")
        }
        pso = try device.makeComputePipelineState(function: fn)
    }

    func encode(_ cb: MTLCommandBuffer, source: MTLTexture, map: MTLTexture?,
                output: MTLTexture, params: DisplaceChromaticParams) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.label = "Displace + Chromatic Aberration"
        var p = params
        if map != nil { p.flags |= DisplaceChromaticParams.useMap }
        enc.setComputePipelineState(pso)
        enc.setTexture(source, index: 0)
        enc.setTexture(map ?? source, index: 1)           // always bind something valid
        enc.setTexture(output, index: 2)
        enc.setBytes(&p, length: MemoryLayout<DisplaceChromaticParams>.stride, index: 0)
        let w = pso.threadExecutionWidth
        let h = max(1, pso.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(MTLSize(width: output.width, height: output.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc.endEncoding()
    }
}
