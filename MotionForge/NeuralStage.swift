// NeuralStage.swift — zero-copy Core ML bridge (Apple Neural Engine). Compiled into the app but not wired
// into the render graph: no models ship with this build. See ARCHITECTURE.md section 7.

import Metal
import CoreML
import CoreVideo

// MARK: - Zero-copy neural stage (Core ML on the Apple Neural Engine)
//
//  GPU (Metal)                         ANE (Core ML)                       GPU (Metal)
//  linear fp16 --[encode kernel]-->  IOSurface BGRA8 --predict()-->  IOSurface BGRA8 --[decode kernel]--> linear fp16
//                 same physical pages, no memcpy        same physical pages
//
// Synchronisation: the ANE is not a Metal queue, so the hand-off uses an MTLSharedEvent that the CPU
// signals when `prediction` returns; the consumer command buffer waits on it on the GPU timeline.

final class NeuralStage {
    let inputTexture: MTLTexture          // GPU writes here (bgra8Unorm, IOSurface-backed)
    let outputTexture: MTLTexture         // GPU reads here
    let event: MTLSharedEvent
    private(set) var ticketCounter: UInt64 = 0

    private let model: MLModel
    private let inName: String
    private let outName: String
    private let inBuffer: CVPixelBuffer
    private let outBuffer: CVPixelBuffer
    private var keepAlive: [CVMetalTexture] = []

    init(modelURL: URL, inputName: String, outputName: String,
         inputSize: (w: Int, h: Int), outputSize: (w: Int, h: Int),
         device: MTLDevice) throws {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndNeuralEngine            // keep the GPU free for compositing
        model = try MLModel(contentsOf: modelURL, configuration: cfg)
        inName = inputName; outName = outputName

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw PipelineError.textureCache }

        let a = try Self.makeShared(cache, inputSize.w, inputSize.h)
        let b = try Self.makeShared(cache, outputSize.w, outputSize.h)
        inBuffer = a.buffer;  inputTexture = a.texture
        outBuffer = b.buffer; outputTexture = b.texture
        guard let ev = device.makeSharedEvent() else { throw PipelineError.textureCache }
        event = ev
        keepAlive = [a.cv, b.cv]
    }

    private static func makeShared(_ cache: CVMetalTextureCache, _ w: Int, _ h: Int) throws
        -> (buffer: CVPixelBuffer, texture: MTLTexture, cv: CVMetalTexture) {
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()      // forces IOSurface backing
        ]
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else {
            throw PipelineError.pixelBuffer
        }
        var cvTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm,
                                                        w, h, 0, &cvTex) == kCVReturnSuccess,
              let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { throw PipelineError.textureCache }
        return (pb, tex, cvTex)
    }

    /// Call right after encoding the GPU "encode for ML" pass into `producer`, before committing it.
    /// Returns the ticket the consumer command buffer must wait for.
    func schedule(after producer: MTLCommandBuffer) -> UInt64 {
        ticketCounter += 1
        let ticket = ticketCounter
        producer.addCompletedHandler { [self] _ in
            Task.detached(priority: .userInitiated) {
                do { try await self.predict() } catch { print("Neural stage failed:", error) }
                self.event.signaledValue = ticket          // always signal, or the GPU queue would stall
            }
        }
        return ticket
    }

    func encodeWait(on consumer: MTLCommandBuffer, ticket: UInt64) {
        consumer.encodeWaitForEvent(event, value: ticket)
    }

    private func predict() async throws {
        let input = try MLDictionaryFeatureProvider(dictionary: [inName: MLFeatureValue(pixelBuffer: inBuffer)])
        let options = MLPredictionOptions()
        options.outputBackings = [outName: outBuffer]      // model writes straight into our IOSurface
        _ = try await model.prediction(from: input, options: options)
    }
}
