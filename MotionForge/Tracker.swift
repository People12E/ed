// Tracker.swift — face tracking and point tracking (Vision), turned into keyframes on a target layer.
//
// Both trackers decode the clip once, front to back, at about 15 samples per second and return positions in
// normalised video coordinates (0...1, origin top-left). Keyframes are linear and can be edited afterwards.
//
// This is 2D tracking. A 3D camera solve (recovering camera motion and depth) is not part of this build.

import Vision
import AVFoundation
import SwiftUI

enum TrackMode { case face, point }

struct TrackSample {
    var time: Double          // clip-local seconds
    var center: CGPoint       // 0...1, origin top-left
    var size: CGSize          // 0...1 of the frame
}

struct TrackOutcome {
    var samples: [TrackSample]
    var lostAt: Double?       // clip-local time where a point track lost its target
}

enum Tracker {
    static let sampleStep = 1.0 / 15.0

    /// Follows the largest face at the start, then the face closest to the previous position.
    static func trackFaces(source: VideoSource, progress: @escaping (Double) -> Void) -> TrackOutcome {
        var samples: [TrackSample] = []
        var last: CGPoint?
        let duration = max(source.duration, 0.01)

        source.scan(step: sampleStep) { time, pixelBuffer in
            progress(min(time / duration, 1))
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let faces = request.results, !faces.isEmpty else { return true }

            func area(_ f: VNFaceObservation) -> CGFloat { f.boundingBox.width * f.boundingBox.height }
            func distance(_ f: VNFaceObservation, _ p: CGPoint) -> CGFloat {
                hypot(f.boundingBox.midX - p.x, (1 - f.boundingBox.midY) - p.y)
            }

            var chosen = faces[0]
            if let previous = last {
                for f in faces where distance(f, previous) < distance(chosen, previous) { chosen = f }
            } else {
                for f in faces where area(f) > area(chosen) { chosen = f }
            }
            let box = chosen.boundingBox
            let center = CGPoint(x: box.midX, y: 1 - box.midY)         // Vision's origin is bottom-left
            last = center
            samples.append(TrackSample(time: time, center: center, size: box.size))
            return true
        }
        return TrackOutcome(samples: smooth(samples), lostAt: nil)
    }

    /// Follows the region `seed` (normalised, top-left origin) starting at clip-local time `start`.
    static func trackPoint(source: VideoSource, seed: CGRect, from start: Double,
                           progress: @escaping (Double) -> Void) -> TrackOutcome {
        var current = VNDetectedObjectObservation(
            boundingBox: CGRect(x: seed.minX, y: 1 - seed.maxY, width: seed.width, height: seed.height))
        let sequence = VNSequenceRequestHandler()
        var samples: [TrackSample] = []
        var lostAt: Double?
        let span = max(source.duration - start, 0.01)

        source.scan(step: sampleStep) { time, pixelBuffer in
            if time < start - 0.001 { return true }
            progress(min((time - start) / span, 1))
            let request = VNTrackObjectRequest(detectedObjectObservation: current)
            request.trackingLevel = .accurate
            guard (try? sequence.perform([request], on: pixelBuffer)) != nil,
                  let result = request.results?.first as? VNDetectedObjectObservation,
                  result.confidence > 0.2 else {
                lostAt = time
                return false
            }
            current = result
            let box = result.boundingBox
            samples.append(TrackSample(time: time, center: CGPoint(x: box.midX, y: 1 - box.midY), size: box.size))
            return true
        }
        return TrackOutcome(samples: smooth(samples), lostAt: lostAt)
    }

    /// 1-2-1 smoothing of positions and sizes to take the jitter out.
    static func smooth(_ s: [TrackSample]) -> [TrackSample] {
        guard s.count > 2 else { return s }
        var out = s
        for i in 1..<(s.count - 1) {
            let a = s[i - 1], b = s[i], c = s[i + 1]
            out[i].center = CGPoint(x: (a.center.x + b.center.x * 2 + c.center.x) / 4,
                                    y: (a.center.y + b.center.y * 2 + c.center.y) / 4)
            out[i].size = CGSize(width: (a.size.width + b.size.width * 2 + c.size.width) / 4,
                                 height: (a.size.height + b.size.height * 2 + c.size.height) / 4)
        }
        return out
    }
}

// MARK: - Applying a track to the project

extension ProjectModel {
    /// Tracks the first video clip and writes keyframes onto the selected (non-video) layer.
    @MainActor
    func runTrack(_ mode: TrackMode) async {
        guard let targetIndex = selectedIndex, layers[targetIndex].kind != .video,
              let videoIndex = layers.firstIndex(where: { $0.kind == .video }),
              let source = videos[layers[videoIndex].id] else {
            trackStatus = "Select a text, shape or content fill layer first, and make sure the project has a video clip."
            return
        }
        let targetID = layers[targetIndex].id
        let video = layers[videoIndex]
        let now = snapped(time)
        let localStart = max(0, now - video.start)

        var seed = CGRect.zero
        if mode == .point {
            guard let marker = trackerPoint else {
                trackStatus = "Turn on the point tracker and place it over what you want to follow."
                return
            }
            seed = seedRect(marker: marker, size: trackerSize, video: video, at: now)
        }
        let seedCopy = seed

        isPlaying = false
        trackProgress = 0
        trackStatus = nil

        let outcome: TrackOutcome = await Task.detached(priority: .userInitiated) { [weak self] () -> TrackOutcome in
            let report: (Double) -> Void = { p in
                Task { @MainActor in self?.trackProgress = p }
            }
            switch mode {
            case .face:
                return Tracker.trackFaces(source: source, progress: report)
            case .point:
                return Tracker.trackPoint(source: source, seed: seedCopy, from: localStart, progress: report)
            }
        }.value

        trackProgress = nil
        guard !outcome.samples.isEmpty else {
            trackStatus = mode == .face
                ? "No face was found in the clip."
                : "Couldn't lock onto that spot. Try an area with more contrast and place the marker on it."
            return
        }
        applyTrack(outcome.samples, to: targetID, video: video, followScale: mode == .face)

        let seconds = String(format: "%.1f", outcome.samples.last?.time ?? 0)
        if let lost = outcome.lostAt {
            trackStatus = "Lost the target at \(String(format: "%.1f", lost)) s. Kept the part before that (\(outcome.samples.count) points)."
        } else {
            trackStatus = "Tracked \(outcome.samples.count) points over \(seconds) s. X and Y keyframes were added."
        }
    }

    func applyTrack(_ samples: [TrackSample], to targetID: UUID, video: Layer, followScale: Bool) {
        guard let ti = layers.firstIndex(where: { $0.id == targetID }) else { return }
        let target = layers[ti]
        var xs: [Keyframe] = [], ys: [Keyframe] = [], ss: [Keyframe] = []
        for s in samples {
            let t = video.start + s.time
            let m = compPosition(s, video: video, at: t)
            xs.append(Keyframe(time: t, value: Double(m.point.x), easing: .linear))
            ys.append(Keyframe(time: t, value: Double(m.point.y), easing: .linear))
            if followScale && (target.kind == .shape || target.kind == .fill) {
                let percent = m.width * 1.4 / max(target.shapeWidth, 1) * 100
                ss.append(Keyframe(time: t, value: min(max(percent, 5), 400), easing: .linear))
            }
        }
        layers[ti].tracks[.x] = xs
        layers[ti].tracks[.y] = ys
        if !ss.isEmpty { layers[ti].tracks[.scale] = ss }
    }

    /// Video-frame position (0...1) to composition pixels, using the video layer's transform at time `t`.
    func compPosition(_ s: TrackSample, video: Layer, at t: Double) -> (point: CGPoint, width: Double) {
        let src = video.sourceSize
        let k = video.rawValue(.scale, at: t) / 100
        let rot = video.rawValue(.rotation, at: t) * Double.pi / 180
        let dx = (Double(s.center.x) - 0.5) * Double(src.width) * k
        let dy = (Double(s.center.y) - 0.5) * Double(src.height) * k
        let x = video.rawValue(.x, at: t) + dx * cos(rot) - dy * sin(rot)
        let y = video.rawValue(.y, at: t) + dx * sin(rot) + dy * cos(rot)
        return (CGPoint(x: x, y: y), Double(s.size.width) * Double(src.width) * k)
    }

    /// Composition pixels (the marker on the preview) to a normalised region of the video frame.
    func seedRect(marker: CGPoint, size: Double, video: Layer, at t: Double) -> CGRect {
        let src = video.sourceSize
        let k = max(video.rawValue(.scale, at: t) / 100, 0.001)
        let rot = video.rawValue(.rotation, at: t) * Double.pi / 180
        let dx = Double(marker.x) - video.rawValue(.x, at: t)
        let dy = Double(marker.y) - video.rawValue(.y, at: t)
        let ux = dx * cos(-rot) - dy * sin(-rot)
        let uy = dx * sin(-rot) + dy * cos(-rot)
        let cx = 0.5 + ux / (Double(src.width) * k)
        let cy = 0.5 + uy / (Double(src.height) * k)
        let hw = size / (Double(src.width) * k) / 2
        let hh = size / (Double(src.height) * k) / 2
        let x0 = min(max(cx - hw, 0), 0.97)
        let y0 = min(max(cy - hh, 0), 0.97)
        let x1 = min(max(cx + hw, x0 + 0.03), 1)
        let y1 = min(max(cy + hh, y0 + 0.03), 1)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
