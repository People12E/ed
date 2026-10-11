// VideoSource.swift — random-access video frames as Metal textures.
//
// Preview: texture(at:) returns the latest decoded frame immediately and fetches the requested one in the
//          background (latest request wins), then calls onFrame so the preview redraws.
// Export:  frameSync(at:) decodes the exact frame on the calling thread.
//
// Decoding goes through AVAssetReaderVideoCompositionOutput so the track's preferredTransform
// (portrait phone video) is applied and `size` is the upright size.

import AVFoundation
import Metal
import CoreVideo

enum VideoError: LocalizedError {
    case noVideoTrack, noTextureCache
    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "That file doesn't contain a video track."
        case .noTextureCache: return "Couldn't create a Metal texture cache."
        }
    }
}

final class VideoSource: @unchecked Sendable {
    let duration: Double
    let size: CGSize
    let fps: Double
    let asset: AVURLAsset
    let audioTrack: AVAssetTrack?
    var onFrame: (() -> Void)?

    private let track: AVAssetTrack
    private let composition: AVVideoComposition
    private var cache: CVMetalTextureCache?
    private let queue = DispatchQueue(label: "motionforge.video.fetch", qos: .userInteractive)
    private let lock = NSLock()
    private var ring: [CVMetalTexture] = []        // keeps recent pixel buffers alive for in-flight GPU work
    private var latest: MTLTexture?
    private var requested = -1.0
    private var fetched = -1.0
    private var inFlight = false

    private init(asset: AVURLAsset, track: AVAssetTrack, audio: AVAssetTrack?, composition: AVVideoComposition,
                 duration: Double, fps: Double, device: MTLDevice) throws {
        self.asset = asset
        self.track = track
        self.audioTrack = audio
        self.composition = composition
        self.duration = duration
        self.fps = fps > 1 ? fps : 30
        let rs = composition.renderSize
        self.size = CGSize(width: max(2, rs.width), height: max(2, rs.height))
        var c: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &c) == kCVReturnSuccess else {
            throw VideoError.noTextureCache
        }
        cache = c
    }

    static func load(url: URL, device: MTLDevice) async throws -> VideoSource {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoError.noVideoTrack
        }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let durationTime = try await asset.load(.duration)
        let duration = durationTime.seconds
        let nominalRate = try await track.load(.nominalFrameRate)
        let fps = Double(nominalRate)
        let composition = AVMutableVideoComposition(propertiesOf: asset)   // applies preferredTransform
        return try VideoSource(asset: asset, track: track, audio: audio, composition: composition,
                               duration: duration.isFinite ? duration : 0, fps: fps, device: device)
    }

    // MARK: Preview path (asynchronous, coalescing)

    func texture(at time: Double) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        requested = time
        if !inFlight && abs(fetched - time) > 0.4 / fps { startFetch() }
        return latest
    }

    /// Caller must hold `lock`.
    private func startFetch() {
        inFlight = true
        let t = requested
        queue.async { [self] in
            let pixelBuffer = readFrame(at: t)
            let tex = pixelBuffer.flatMap { makeTexture($0) }
            lock.lock()
            if let tex { latest = tex }
            fetched = t
            inFlight = false
            if abs(requested - t) > 0.4 / fps { startFetch() }
            lock.unlock()
            DispatchQueue.main.async { self.onFrame?() }
        }
    }

    // MARK: Export path (synchronous, exact)

    func frameSync(at time: Double) -> MTLTexture? {
        guard let pb = readFrame(at: time) else { return nil }
        return makeTexture(pb)
    }

    // MARK: Decoding

    private func readFrame(at t: Double) -> CVPixelBuffer? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: settings)
        out.videoComposition = composition
        guard reader.canAdd(out) else { return nil }
        reader.add(out)

        // Start half a frame early so the frame displayed at `t` is the first sample returned.
        let clamped = min(max(t, 0), max(duration - 0.001, 0))
        let start = max(0, clamped - 0.5 / fps)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: 0.75, preferredTimescale: 600))
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        guard let sample = out.copyNextSampleBuffer() else { return nil }
        return CMSampleBufferGetImageBuffer(sample)
    }

    private func makeTexture(_ pb: CVPixelBuffer) -> MTLTexture? {
        guard let cache else { return nil }
        var cv: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        // sRGB view: sampling returns linear-light values for the linear compositing space.
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm_srgb, w, h, 0, &cv) == kCVReturnSuccess,
              let cv, let tex = CVMetalTextureGetTexture(cv) else { return nil }
        lock.lock()
        ring.append(cv)
        if ring.count > 8 { ring.removeFirst() }
        lock.unlock()
        return tex
    }
}
