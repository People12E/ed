// Persistence.swift — projects live in Documents/Projects/<id>/
//   project.json   layers, keyframes, effects, settings
//   media/         imported video files
//   thumb.jpg      first frame, shown on the home screen

import SwiftUI
import Observation
import AVFoundation
import UIKit
import Metal

struct ProjectFile: Codable {
    var version: Int
    var id: UUID
    var name: String
    var modified: Date
    var canvasWidth: Double
    var canvasHeight: Double
    var duration: Double
    var fps: Double
    var fx: FXSettings
    var easing: CubicBezier
    var layers: [Layer]
    var media: [String: String]          // layer id -> file name inside media/
    var lighting: LightingSettings?      // absent in projects saved by older versions
}

struct ProjectSummary: Identifiable, Equatable {
    var id: UUID
    var name: String
    var modified: Date
    var duration: Double
    var layerCount: Int
    var directory: URL
    var thumbnail: URL?
}

@Observable
final class ProjectStore {
    var items: [ProjectSummary] = []

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: ProjectModel.rootURL, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var found: [ProjectSummary] = []
        for dir in dirs {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("project.json")),
                  let file = try? decoder.decode(ProjectFile.self, from: data) else { continue }
            let thumb = dir.appendingPathComponent("thumb.jpg")
            found.append(ProjectSummary(id: file.id, name: file.name, modified: file.modified,
                                        duration: file.duration, layerCount: file.layers.count,
                                        directory: dir,
                                        thumbnail: fm.fileExists(atPath: thumb.path) ? thumb : nil))
        }
        items = found.sorted { $0.modified > $1.modified }
    }

    func delete(_ item: ProjectSummary) {
        try? FileManager.default.removeItem(at: item.directory)
        reload()
    }
}

extension ProjectModel {
    static var rootURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var directory: URL { Self.rootURL.appendingPathComponent(projectID.uuidString, isDirectory: true) }

    var mediaDirectory: URL {
        let url = directory.appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var thumbnailURL: URL { directory.appendingPathComponent("thumb.jpg") }

    /// Writes project.json. Imported videos already live in media/, so only the JSON is written.
    func save() {
        var media: [String: String] = [:]
        for (layerID, source) in videos where layers.contains(where: { $0.id == layerID }) {
            media[layerID.uuidString] = source.asset.url.lastPathComponent
        }
        let file = ProjectFile(version: 1, id: projectID, name: name, modified: Date(),
                               canvasWidth: Double(canvas.width), canvasHeight: Double(canvas.height),
                               duration: duration, fps: fps, fx: fx, easing: easing,
                               layers: layers, media: media, lighting: lighting)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(file)
            try data.write(to: directory.appendingPathComponent("project.json"), options: .atomic)
        } catch {
            print("Saving the project failed:", error)
        }
        saveThumbnailIfNeeded()
    }

    func saveThumbnailIfNeeded() {
        let url = thumbnailURL
        guard !FileManager.default.fileExists(atPath: url.path),
              let layer = layers.first(where: { $0.kind == .video }),
              let source = videos[layer.id] else { return }
        let asset = source.asset
        Task.detached(priority: .utility) {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 720, height: 720)
            guard let result = try? await generator.image(at: .zero),
                  let data = UIImage(cgImage: result.image).jpegData(compressionQuality: 0.8) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    @MainActor
    static func load(directory: URL) async throws -> ProjectModel {
        let data = try Data(contentsOf: directory.appendingPathComponent("project.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(ProjectFile.self, from: data)

        let model = ProjectModel()
        model.projectID = file.id
        model.name = file.name
        model.canvas = CGSize(width: file.canvasWidth, height: file.canvasHeight)
        model.duration = file.duration
        model.fps = file.fps
        model.fx = file.fx
        model.easing = file.easing
        model.layers = file.layers
        model.lighting = file.lighting ?? LightingSettings()

        guard let device = MTLCreateSystemDefaultDevice() else { throw VideoError.noTextureCache }
        var loaded: [String: VideoSource] = [:]
        for (layerID, fileName) in file.media {
            guard let uuid = UUID(uuidString: layerID) else { continue }
            if let existing = loaded[fileName] { model.videos[uuid] = existing; continue }
            let url = directory.appendingPathComponent("media").appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let source = try await VideoSource.load(url: url, device: device)
            loaded[fileName] = source
            model.videos[uuid] = source
        }
        for layer in model.layers where layer.kind == .model {
            guard let relative = layer.modelFile else { continue }
            let url = directory.appendingPathComponent("media").appendingPathComponent(relative)
            if let asset = try? ModelAsset.load(url: url, device: device) { model.models[layer.id] = asset }
        }
        model.selectedID = model.layers.last?.id
        model.resetHistory()
        return model
    }
}
