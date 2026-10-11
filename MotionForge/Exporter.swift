// Exporter.swift — offline render to H.264 MP4.
// Runs its own compositor (separate textures, own expression engine) on a background queue,
// decodes exact video frames (syncVideo) and passes the first video layer's audio through untouched.

import AVFoundation
import Metal
import CoreVideo

struct ExportJob {
    var layers: [Layer]
    var videos: [UUID: VideoSource]
    var canvas: CGSize
    var duration: Double
    var fps: Double
    var fx: FXSettings
}

enum ExportError: LocalizedError {
    case setup(String), failed(String), cancelled
    var errorDescription: String? {
        switch self {
        case .setup(let s): return s
        case .failed(let s): return s
        case .cancelled: return "Export cancelled."
        }
    }
}

final class Exporter {
    private let flagLock = NSLock()
    private var cancelledFlag = false

    var isCancelled: Bool {
        flagLock.lock(); defer { flagLock.unlock() }
        return cancelledFlag
    }
    func cancel() {
        flagLock.lock(); cancelledFlag = true; flagLock.unlock()
    }

    func run(job: ExportJob, progress: @escaping (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try self.runSync(job, progress)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func runSync(_ job: ExportJob, _ progress: @escaping (Double) -> Void) throws -> URL {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let compositor = LayerCompositor(device: device),
              let present = PresentPass(device: device, library: library, pixelFormat: .bgra8Unorm) else {
            throw ExportError.setup("Metal isn't available on this device.")
        }
        compositor.syncVideo = true
        let engine = ExpressionEngine()

        let w = max(2, Int(job.canvas.width) & ~1)
        let h = max(2, Int(job.canvas.height) & ~1)
        let fpsInt = max(1, Int(job.fps.rounded()))
        let total = max(1, Int((job.duration * Double(fpsInt)).rounded()))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MotionForge-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(8_000_000, w * h * 4),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ])
        guard writer.canAdd(videoInput) else { throw ExportError.setup("Couldn't configure the video track.") }
        writer.add(videoInput)

        // Audio: pass the first visible video layer's audio through when the clip starts at 0.
        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let layer = job.layers.first(where: { $0.kind == .video && $0.visible }),
           layer.start < 0.001,
           let source = job.videos[layer.id],
           let audioTrack = source.audioTrack,
           let reader = try? AVAssetReader(asset: source.asset) {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            let hint = audioTrack.formatDescriptions.first.map { $0 as! CMFormatDescription }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: job.duration, preferredTimescale: 600))
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                audioReader = reader
                audioOutput = output
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            throw ExportError.failed(writer.error?.localizedDescription ?? "Couldn't start writing the file.")
        }
        writer.startSession(atSourceTime: .zero)
        _ = audioReader?.startReading()

        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)

        // Renders one frame into a pooled BGRA pixel buffer and waits for the GPU.
        func renderFrame(_ i: Int, pool: CVPixelBufferPool) -> CVPixelBuffer? {
            var pbOut: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess,
                  let pb = pbOut, let cache = textureCache else { return nil }
            var cvTex: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex) == kCVReturnSuccess,
                  let cvTex, let target = CVMetalTextureGetTexture(cvTex),
                  let cb = queue.makeCommandBuffer() else { return nil }

            let t = Double(i) / Double(fpsInt)
            let snap = RenderSnapshot.make(layers: job.layers, videos: job.videos, time: t,
                                           canvas: CGSize(width: w, height: h), fx: job.fx, engine: engine)
            guard let frame = compositor.render(snap, commandBuffer: cb) else { return nil }

            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            present.encode(cb, pass: rpd, processed: frame.processed, original: frame.original,
                           splitX: 0, viewportWidth: Float(w))
            cb.commit()
            cb.waitUntilCompleted()
            withExtendedLifetime(cvTex) {}
            return pb
        }

        let group = DispatchGroup()
        var failure: Error?
        var frameIndex = 0

        group.enter()
        videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "motionforge.export.video")) {
            while videoInput.isReadyForMoreMediaData {
                if self.isCancelled || frameIndex >= total || failure != nil {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                guard let pool = adaptor.pixelBufferPool, let pb = renderFrame(frameIndex, pool: pool) else {
                    failure = ExportError.failed("A frame couldn't be rendered.")
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fpsInt))
                if !adaptor.append(pb, withPresentationTime: pts) {
                    failure = ExportError.failed(writer.error?.localizedDescription ?? "Couldn't write a frame.")
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                frameIndex += 1
                if frameIndex % 3 == 0 { progress(Double(frameIndex) / Double(total)) }
            }
        }

        if let audioInput, let audioOutput {
            group.enter()
            audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "motionforge.export.audio")) {
                while audioInput.isReadyForMoreMediaData {
                    if self.isCancelled { audioInput.markAsFinished(); group.leave(); return }
                    if let sample = audioOutput.copyNextSampleBuffer() {
                        if !audioInput.append(sample) { audioInput.markAsFinished(); group.leave(); return }
                    } else {
                        audioInput.markAsFinished(); group.leave(); return
                    }
                }
            }
        }

        group.wait()

        if isCancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw ExportError.cancelled
        }
        if let failure {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw failure
        }

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw ExportError.failed(writer.error?.localizedDescription ?? "The file couldn't be finished.")
        }
        progress(1)
        return url
    }
}
