// Model.swift — layers, keyframes, evaluation and the observable project.
// Plain value types (Layer, Keyframe) so a snapshot can be rendered on any thread, and so a project can be saved.

import SwiftUI
import Observation
import QuartzCore

// MARK: - Properties

enum TransformProp: String, CaseIterable, Identifiable, Hashable, Codable {
    case x, y, z, scale, rotX, rotY, rotation, opacity, fov, intensity, cone
    var id: String { rawValue }

    var title: String {
        switch self {
        case .x: return "X"
        case .y: return "Y"
        case .z: return "Z"
        case .scale: return "Scale"
        case .rotX: return "Rotate X"
        case .rotY: return "Rotate Y"
        case .rotation: return "Rotation"
        case .opacity: return "Opacity"
        case .fov: return "Field of view"
        case .intensity: return "Intensity"
        case .cone: return "Cone angle"
        }
    }
    var unit: String {
        switch self {
        case .x, .y, .z: return "px"
        case .scale, .opacity, .intensity: return "%"
        case .rotX, .rotY, .rotation, .fov, .cone: return "°"
        }
    }
    func range(canvas: CGSize) -> ClosedRange<Double> {
        switch self {
        case .x: return Double(-canvas.width)...Double(canvas.width * 2)
        case .y: return Double(-canvas.height)...Double(canvas.height * 2)
        case .z: return -3000...3000
        case .scale: return 0...400
        case .rotX, .rotY, .rotation: return -360...360
        case .opacity: return 0...100
        case .fov: return 10...120
        case .intensity: return 0...500
        case .cone: return 5...120
        }
    }

    /// The properties that make sense for a layer, in display order.
    static func relevant(for layer: Layer) -> [TransformProp] {
        switch layer.kind {
        case .null: return [.x, .y, .scale, .rotation]
        case .camera: return [.x, .y, .z, .rotX, .rotY, .rotation, .fov]
        case .light:
            switch layer.lightType {
            case .spot: return [.x, .y, .z, .rotX, .rotY, .intensity, .cone]
            case .ambient: return [.intensity]
            case .parallel: return [.rotX, .rotY, .intensity]
            case .point: return [.x, .y, .z, .intensity]
            }
        case .model: return [.x, .y, .z, .scale, .rotX, .rotY, .rotation, .opacity]
        case .fill: return [.x, .y, .scale, .rotation, .opacity]
        case .video, .text, .shape:
            return layer.is3D ? [.x, .y, .z, .scale, .rotX, .rotY, .rotation, .opacity]
                              : [.x, .y, .scale, .rotation, .opacity]
        }
    }
}

struct Keyframe: Identifiable, Equatable, Codable {
    var id = UUID()
    var time: Double
    var value: Double
    var easing: CubicBezier          // easing from this key to the next
}

enum LayerKind: String, CaseIterable, Identifiable, Codable {
    case video, text, shape, fill, null, camera, light, model
    var id: String { rawValue }
    var title: String {
        switch self {
        case .video: return "Video"
        case .text: return "Text"
        case .shape: return "Shape"
        case .fill: return "Content fill"
        case .null: return "Null"
        case .camera: return "Camera"
        case .light: return "Light"
        case .model: return "3D model"
        }
    }
    var symbol: String {
        switch self {
        case .video: return "film"
        case .text: return "textformat"
        case .shape: return "square.on.circle"
        case .fill: return "eraser"
        case .null: return "plus.viewfinder"
        case .camera: return "camera"
        case .light: return "lightbulb"
        case .model: return "cube"
        }
    }
    var tint: Color {
        switch self {
        case .video: return .indigo
        case .text: return .purple
        case .shape: return .pink
        case .fill: return .mint
        case .null: return .gray
        case .camera: return .orange
        case .light: return .yellow
        case .model: return .teal
        }
    }
    /// Layers that produce pixels in the 2D stack (so effects can apply).
    var hasImage: Bool { self == .video || self == .text || self == .shape }
}

enum ShapeKind: String, CaseIterable, Identifiable, Codable {
    case rectangle, roundedRectangle, ellipse
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .roundedRectangle: return "Rounded"
        case .ellipse: return "Ellipse"
        }
    }
}

enum BlendKind: String, CaseIterable, Identifiable, Codable {
    case normal, add, screen, multiply
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum LightType: String, CaseIterable, Identifiable, Codable {
    case ambient, parallel, point, spot
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Scene-wide lighting options for 3D layers and models.
struct LightingSettings: Equatable, Codable {
    var realistic = true          // physically based shading + environment light + tone mapping
    var environment = 0.7         // sky / ground light strength
    var exposure = 1.0
    var shadows = true
    var softness = 1.5            // shadow edge softness in shadow-map texels
}

/// One effect on a layer's effect stack.
struct EffectInstance: Identifiable, Equatable, Codable {
    var id = UUID()
    var effect: String            // catalog name, e.g. "Gaussian Blur"
    var enabled = true
    var params: [String: Double] = [:]
}

// MARK: - Layer

struct Layer: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String
    var kind: LayerKind
    var start: Double = 0
    var end: Double = 4
    var visible = true
    var blend: BlendKind = .normal

    var base: [TransformProp: Double] = [:]
    var tracks: [TransformProp: [Keyframe]] = [:]
    var expressions: [TransformProp: String] = [:]

    // Content
    var text = "Your title"
    var fontSize = 140.0
    var shape: ShapeKind = .roundedRectangle
    var shapeWidth = 480.0
    var shapeHeight = 300.0
    var feather = 24.0               // content fill: soft edge in pixels
    var grain = 0.2                  // content fill: noise added to the filled area, 0...1
    var rgba: [Double] = [1, 1, 1, 1]
    var sourceSize = CGSize(width: 1920, height: 1080)    // video pixels

    // 3D, parenting, effects, lights, models
    var is3D = false
    var acceptsLights = true
    var parentID: UUID?
    var parentRest: [Double] = [0, 0, 100, 0]   // parent's x, y, scale, rotation when the link was made
    var effects: [EffectInstance] = []
    var lightType: LightType = .spot
    var castsShadow = true
    var modelFile: String?                       // path inside the project's media folder
    var metallic = 0.0
    var roughness = 0.5

    /// SwiftUI colour view of `rgba` (the stored form, so the layer can be saved).
    var color: Color {
        get { Color(.sRGB, red: rgba[0], green: rgba[1], blue: rgba[2], opacity: rgba[3]) }
        set {
            var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
            UIColor(newValue).getRed(&r, green: &g, blue: &b, alpha: &a)
            rgba = [Double(r), Double(g), Double(b), Double(a)]
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, start, end, visible, blend, base, tracks, expressions
        case text, fontSize, shape, shapeWidth, shapeHeight, feather, grain, rgba, sourceSize
        case is3D, acceptsLights, parentID, parentRest, effects, lightType, castsShadow
        case modelFile, metallic, roughness
    }

    static func defaultBase(canvas: CGSize) -> [TransformProp: Double] {
        [.x: Double(canvas.width) / 2, .y: Double(canvas.height) / 2, .z: 0,
         .scale: 100, .rotX: 0, .rotY: 0, .rotation: 0, .opacity: 100,
         .fov: 40, .intensity: 100, .cone: 45]
    }

    func isActive(at t: Double) -> Bool { visible && t >= start - 1e-6 && t <= end + 1e-6 }

    /// Key/value interpolation only (no expressions). Used by the UI and as the expression's `value`.
    func rawValue(_ p: TransformProp, at t: Double) -> Double {
        guard let keys = tracks[p], !keys.isEmpty else {
            return base[p] ?? Layer.defaultBase(canvas: CGSize(width: 1920, height: 1080))[p] ?? 0
        }
        if t <= keys[0].time { return keys[0].value }
        let last = keys[keys.count - 1]
        if t >= last.time { return last.value }
        var i = 0
        while keys[i + 1].time < t { i += 1 }
        let a = keys[i], b = keys[i + 1]
        let u = (t - a.time) / (b.time - a.time)
        return a.value + (b.value - a.value) * a.easing.value(at: u)
    }

    /// Final value: interpolation, then the property's expression (if any).
    func value(_ p: TransformProp, at t: Double, engine: ExpressionEngine?, index: Int) -> Double {
        let v = rawValue(p, at: t)
        guard let engine, let src = expressions[p], !src.isEmpty else { return v }
        let u = id.uuid
        let seed = Int(u.0) * 31 + Int(u.1) * 7 + p.rawValue.count
        return engine.evaluate(src, time: t, index: index, value: v, seed: seed) ?? v
    }

    var contentKey: String {
        let c = rgba.map { String(format: "%.3f", $0) }.joined(separator: ",")
        switch kind {
        case .video: return "video:\(id)"
        case .fill, .null, .camera, .light, .model: return "none:\(id)"
        case .text: return "text|\(text)|\(Int(fontSize))|\(c)"
        case .shape: return "shape|\(shape.rawValue)|\(Int(shapeWidth))x\(Int(shapeHeight))|\(c)"
        }
    }

    // MARK: Keyframe editing

    func keyIndex(_ p: TransformProp, at time: Double, fps: Double) -> Int? {
        tracks[p]?.firstIndex { abs($0.time - time) < 0.5 / fps }
    }

    mutating func upsertKey(_ p: TransformProp, time: Double, value: Double, easing: CubicBezier, fps: Double) {
        var keys = tracks[p] ?? []
        if let i = keys.firstIndex(where: { abs($0.time - time) < 0.5 / fps }) {
            keys[i].value = value
        } else {
            keys.append(Keyframe(time: time, value: value, easing: easing))
            keys.sort { $0.time < $1.time }
        }
        tracks[p] = keys
    }

    mutating func removeKey(_ p: TransformProp, at time: Double, fps: Double) {
        guard var keys = tracks[p], let i = keys.firstIndex(where: { abs($0.time - time) < 0.5 / fps }) else { return }
        let v = keys[i].value
        keys.remove(at: i)
        if keys.isEmpty { tracks[p] = nil; base[p] = v } else { tracks[p] = keys }
    }

    var allKeyTimes: [Double] {
        var s = Set<Double>()
        for keys in tracks.values { for k in keys { s.insert((k.time * 1000).rounded() / 1000) } }
        return s.sorted()
    }
}

/// Projects saved by earlier versions lack the newer fields, so every optional field falls back to a default.
extension Layer {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Layer"
        kind = try c.decode(LayerKind.self, forKey: .kind)
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? 4
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        blend = try c.decodeIfPresent(BlendKind.self, forKey: .blend) ?? .normal
        base = try c.decodeIfPresent([TransformProp: Double].self, forKey: .base) ?? [:]
        tracks = try c.decodeIfPresent([TransformProp: [Keyframe]].self, forKey: .tracks) ?? [:]
        expressions = try c.decodeIfPresent([TransformProp: String].self, forKey: .expressions) ?? [:]
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? "Your title"
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 140
        shape = try c.decodeIfPresent(ShapeKind.self, forKey: .shape) ?? .roundedRectangle
        shapeWidth = try c.decodeIfPresent(Double.self, forKey: .shapeWidth) ?? 480
        shapeHeight = try c.decodeIfPresent(Double.self, forKey: .shapeHeight) ?? 300
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 24
        grain = try c.decodeIfPresent(Double.self, forKey: .grain) ?? 0.2
        rgba = try c.decodeIfPresent([Double].self, forKey: .rgba) ?? [1, 1, 1, 1]
        if rgba.count < 4 { rgba = [1, 1, 1, 1] }
        sourceSize = try c.decodeIfPresent(CGSize.self, forKey: .sourceSize) ?? CGSize(width: 1920, height: 1080)
        is3D = try c.decodeIfPresent(Bool.self, forKey: .is3D) ?? false
        acceptsLights = try c.decodeIfPresent(Bool.self, forKey: .acceptsLights) ?? true
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        parentRest = try c.decodeIfPresent([Double].self, forKey: .parentRest) ?? [0, 0, 100, 0]
        if parentRest.count < 4 { parentRest = [0, 0, 100, 0] }
        effects = try c.decodeIfPresent([EffectInstance].self, forKey: .effects) ?? []
        lightType = try c.decodeIfPresent(LightType.self, forKey: .lightType) ?? .spot
        castsShadow = try c.decodeIfPresent(Bool.self, forKey: .castsShadow) ?? true
        modelFile = try c.decodeIfPresent(String.self, forKey: .modelFile)
        metallic = try c.decodeIfPresent(Double.self, forKey: .metallic) ?? 0
        roughness = try c.decodeIfPresent(Double.self, forKey: .roughness) ?? 0.5
    }
}

// MARK: - World transform (parenting)

struct WorldTransform {
    var x: Double, y: Double, scale: Double, rotation: Double

    /// Position, scale and rotation of `layer` at `t` after following its chain of parents.
    /// A child keeps its own animated values; its parent's *change since the link was made* is applied on top,
    /// rotating and scaling about the parent.
    static func compute(_ layer: Layer, in layers: [Layer], at t: Double,
                        engine: ExpressionEngine?, depth: Int = 0) -> WorldTransform {
        let idx = (layers.firstIndex(where: { $0.id == layer.id }) ?? 0) + 1
        let own = WorldTransform(
            x: layer.value(.x, at: t, engine: engine, index: idx),
            y: layer.value(.y, at: t, engine: engine, index: idx),
            scale: layer.value(.scale, at: t, engine: engine, index: idx),
            rotation: layer.value(.rotation, at: t, engine: engine, index: idx))
        guard depth < 8, let pid = layer.parentID,
              let parent = layers.first(where: { $0.id == pid }), parent.id != layer.id else { return own }
        let p = compute(parent, in: layers, at: t, engine: engine, depth: depth + 1)
        let rest = layer.parentRest
        let k = rest[2] != 0 ? p.scale / rest[2] : 1
        let dr = (p.rotation - rest[3]) * Double.pi / 180
        let dx = own.x - rest[0], dy = own.y - rest[1]
        let rx = dx * cos(dr) - dy * sin(dr)
        let ry = dx * sin(dr) + dy * cos(dr)
        return WorldTransform(x: p.x + k * rx, y: p.y + k * ry,
                              scale: own.scale * k, rotation: own.rotation + (p.rotation - rest[3]))
    }
}

// MARK: - Effects

struct FXSettings: Equatable, Codable {
    var enabled = true
    var displaceEnabled = true
    var displaceScale = 24.0
    var turbulence = 0.0
    var caAmount = 6.0
    var caFalloff = 1.6
}

enum KeyState { case off, animated, onKey }

// MARK: - Project

@Observable
final class ProjectModel {
    var projectID = UUID()
    var name = "Untitled"
    var layers: [Layer] = []
    var selectedID: UUID?
    var time = 0.0
    var duration = 10.0
    var fps = 30.0
    var canvas = CGSize(width: 1920, height: 1080)
    var isPlaying = false
    var easing = CubicBezier.easeInOut
    var fx = FXSettings()
    var lighting = LightingSettings()
    var expressionError: String?

    // Tracking UI state
    var trackStatus: String?
    var trackProgress: Double?
    var trackerPoint: CGPoint?          // comp pixels; nil = marker hidden
    var trackerSize = 120.0

    var notice: String?                 // short message shown by the editor (imports, effects)
    var showModelImporter = false       // asks the editor to open the 3D model file picker

    @ObservationIgnored var videos: [UUID: VideoSource] = [:]
    @ObservationIgnored var models: [UUID: ModelAsset] = [:]
    let exprEngine = ExpressionEngine()

    // MARK: History (snapshot based; the view layer calls commitIfChanged() after edits settle)
    struct Snapshot: Equatable {
        var layers: [Layer]
        var fx: FXSettings
        var lighting: LightingSettings
        var duration: Double
        var selectedID: UUID?
    }
    var canUndo = false
    var canRedo = false
    @ObservationIgnored var undoStack: [Snapshot] = []
    @ObservationIgnored var redoStack: [Snapshot] = []
    @ObservationIgnored var committed: Snapshot?

    var currentSnapshot: Snapshot {
        Snapshot(layers: layers, fx: fx, lighting: lighting, duration: duration, selectedID: selectedID)
    }

    init() { committed = currentSnapshot }

    func resetHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        committed = currentSnapshot
        canUndo = false
        canRedo = false
    }

    func commitIfChanged() {
        let now = currentSnapshot
        guard let last = committed, now != last else { return }
        undoStack.append(last)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        committed = now
        canUndo = true
        canRedo = false
    }

    func undo() {
        commitIfChanged()
        guard let previous = undoStack.popLast(), let current = committed else { return }
        redoStack.append(current)
        restore(previous)
    }

    func redo() {
        commitIfChanged()
        guard let next = redoStack.popLast(), let current = committed else { return }
        undoStack.append(current)
        restore(next)
    }

    private func restore(_ s: Snapshot) {
        layers = s.layers
        fx = s.fx
        lighting = s.lighting
        duration = s.duration
        selectedID = s.layers.contains(where: { $0.id == s.selectedID }) ? s.selectedID : s.layers.last?.id
        time = min(time, duration)
        committed = s
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: Selection helpers
    var selectedIndex: Int? { layers.firstIndex { $0.id == selectedID } }
    var selected: Layer? { selectedIndex.map { layers[$0] } }

    // MARK: Time
    func snapped(_ t: Double) -> Double { min(max((t * fps).rounded() / fps, 0), duration) }
    func advance(by dt: Double) { time += dt; if time >= duration { time = 0 } }
    func step(frames: Int) { time = snapped(time + Double(frames) / fps) }

    var timecode: String {
        let rate = max(1, Int(fps))
        let f = Int((time * fps).rounded())
        let s = f / rate
        return String(format: "%02d:%02d:%02d", s / 60, s % 60, f % rate)
    }

    // MARK: Property access for the drawer
    func value(_ p: TransformProp) -> Double { selected?.rawValue(p, at: time) ?? 0 }

    func setValue(_ p: TransformProp, _ v: Double) {
        guard let i = selectedIndex else { return }
        if layers[i].tracks[p]?.isEmpty == false {
            layers[i].upsertKey(p, time: snapped(time), value: v, easing: easing, fps: fps)
        } else {
            layers[i].base[p] = v
        }
    }

    func keyState(_ p: TransformProp) -> KeyState {
        guard let l = selected, let keys = l.tracks[p], !keys.isEmpty else { return .off }
        return l.keyIndex(p, at: snapped(time), fps: fps) != nil ? .onKey : .animated
    }

    func toggleKey(_ p: TransformProp) {
        guard let i = selectedIndex else { return }
        let t = snapped(time)
        if layers[i].keyIndex(p, at: t, fps: fps) != nil {
            layers[i].removeKey(p, at: t, fps: fps)
        } else {
            layers[i].upsertKey(p, time: t, value: layers[i].rawValue(p, at: t), easing: easing, fps: fps)
        }
    }

    /// Applies the current easing to every key of the selected layer that sits at the playhead.
    func applyEasingToKeys() {
        guard let i = selectedIndex else { return }
        let t = snapped(time)
        for p in layers[i].tracks.keys {
            guard var keys = layers[i].tracks[p] else { continue }
            for k in keys.indices where abs(keys[k].time - t) < 0.5 / fps { keys[k].easing = easing }
            layers[i].tracks[p] = keys
        }
    }

    // MARK: Layers
    func addLayer(kind: LayerKind, lightType: LightType = .spot) {
        var l = Layer(name: kind.title, kind: kind,
                      start: 0, end: duration)
        l.base = Layer.defaultBase(canvas: canvas)
        switch kind {
        case .shape:
            l.color = Color(red: 0.30, green: 0.79, blue: 1.0)
            l.start = time; l.end = min(time + 4, max(duration, time + 1))
        case .text:
            l.start = time; l.end = min(time + 4, max(duration, time + 1))
        case .fill:
            l.start = time; l.end = min(time + 4, max(duration, time + 1))
            l.shape = .roundedRectangle
            l.shapeWidth = 360
            l.shapeHeight = 240
        case .null:
            l.name = "Null \(layers.filter { $0.kind == .null }.count + 1)"
        case .camera:
            l.name = "Camera \(layers.filter { $0.kind == .camera }.count + 1)"
            let f = Double(canvas.height) / 2 / tan(20 * Double.pi / 180)
            l.base[.z] = -f
        case .light:
            l.lightType = lightType
            l.name = "\(lightType.title) light"
            l.base[.x] = Double(canvas.width) * 0.3
            l.base[.y] = Double(canvas.height) * 0.15
            l.base[.z] = -900
            l.base[.rotX] = 25
            l.base[.rotY] = 20
            l.base[.intensity] = lightType == .ambient ? 30 : 100
        case .video, .model:
            break
        }
        layers.append(l)
        selectedID = l.id
        if l.end > duration { duration = l.end }
    }

    func addVideo(source: VideoSource, name: String) {
        if !layers.contains(where: { $0.kind == .video }) {
            // The first clip defines the composition: long edge capped at 1920, even dimensions.
            let long = max(source.size.width, source.size.height)
            let f = min(1, 1920 / long)
            canvas = CGSize(width: max(2, (source.size.width * f / 2).rounded() * 2),
                            height: max(2, (source.size.height * f / 2).rounded() * 2))
            duration = max(source.duration, 1)
        }
        var l = Layer(name: name, kind: .video, start: 0, end: min(source.duration, duration))
        l.sourceSize = source.size
        l.base = Layer.defaultBase(canvas: canvas)
        l.base[.scale] = 100 * Double(min(canvas.width / source.size.width, canvas.height / source.size.height))
        layers.append(l)
        videos[l.id] = source
        selectedID = l.id
        time = 0
    }

    func addModel(asset: ModelAsset, relativePath: String, name: String) {
        var l = Layer(name: name, kind: .model, start: 0, end: duration)
        l.base = Layer.defaultBase(canvas: canvas)
        l.modelFile = relativePath
        l.is3D = true
        layers.append(l)
        models[l.id] = asset
        selectedID = l.id
        if !layers.contains(where: { $0.kind == .light }) {
            notice = "Model added. With no lights in the scene it uses a soft default light. Add a light from the + menu for shadows."
        }
    }

    func deleteSelected() {
        guard let i = selectedIndex else { return }
        layers.remove(at: i)                       // decoded media stays in memory so undo can restore the layer
        selectedID = layers.last?.id
    }

    func duplicateSelected() {
        guard let i = selectedIndex else { return }
        var c = layers[i]
        c.id = UUID()
        c.name += " copy"
        c.base[.x] = (c.base[.x] ?? 0) + 40
        c.base[.y] = (c.base[.y] ?? 0) + 40
        layers.insert(c, at: i + 1)
        if let v = videos[layers[i].id] { videos[c.id] = v }
        if let m = models[layers[i].id] { models[c.id] = m }
        selectedID = c.id
    }

    func moveSelected(by delta: Int) {
        guard let i = selectedIndex else { return }
        let j = i + delta
        guard layers.indices.contains(j) else { return }
        layers.swapAt(i, j)
    }

    // MARK: Parenting
    /// Links the selected layer to `parentID` (nil unlinks). The layer stays where it is.
    func setParent(_ parentID: UUID?) {
        guard let i = selectedIndex else { return }
        guard let pid = parentID else { layers[i].parentID = nil; return }
        // refuse cycles
        var cursor: UUID? = pid
        var guardCount = 0
        while let c = cursor, guardCount < 16 {
            if c == layers[i].id { notice = "A layer can't be its own parent."; return }
            cursor = layers.first(where: { $0.id == c })?.parentID
            guardCount += 1
        }
        guard let parent = layers.first(where: { $0.id == pid }) else { return }
        let w = WorldTransform.compute(parent, in: layers, at: snapped(time), engine: nil)
        layers[i].parentID = pid
        layers[i].parentRest = [w.x, w.y, w.scale, w.rotation]
    }

    // MARK: Effects
    func addEffect(_ name: String) {
        guard let i = selectedIndex, let def = EffectRegistry.def(named: name) else { return }
        guard layers[i].kind.hasImage else {
            notice = "Effects apply to video, text and shape layers. Select one of those first."
            return
        }
        layers[i].effects.append(EffectInstance(effect: name, params: def.defaultParams))
        notice = "Added \(name) to \(layers[i].name)."
    }

    func removeEffect(_ id: UUID) {
        guard let i = selectedIndex else { return }
        layers[i].effects.removeAll { $0.id == id }
    }

    func setEffectParam(_ id: UUID, _ key: String, _ value: Double) {
        guard let i = selectedIndex, let e = layers[i].effects.firstIndex(where: { $0.id == id }) else { return }
        layers[i].effects[e].params[key] = value
    }

    func effectParam(_ id: UUID, _ key: String, default d: Double) -> Double {
        guard let l = selected, let e = l.effects.first(where: { $0.id == id }) else { return d }
        return e.params[key] ?? d
    }

    func toggleEffect(_ id: UUID) {
        guard let i = selectedIndex, let e = layers[i].effects.firstIndex(where: { $0.id == id }) else { return }
        layers[i].effects[e].enabled.toggle()
    }
}

// MARK: - Playback clock

/// Display-link clock. Playback is driven here, never by SwiftUI animation.
final class PlaybackClock: NSObject {
    var onTick: ((Double) -> Void)?
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0

    func start() {
        stop()
        last = CACurrentMediaTime()
        let l = CADisplayLink(target: self, selector: #selector(step(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() { link?.invalidate(); link = nil }

    @objc private func step(_ l: CADisplayLink) {
        let now = l.timestamp
        onTick?(now - last)
        last = now
    }
}
