// Model.swift — layers, keyframes, evaluation and the observable project.
// Plain value types (Layer, Keyframe) so a snapshot can be rendered on any thread.

import SwiftUI
import Observation
import QuartzCore

// MARK: - Properties

enum TransformProp: String, CaseIterable, Identifiable, Hashable {
    case x, y, scale, rotation, opacity
    var id: String { rawValue }

    var title: String {
        switch self {
        case .x: return "X"
        case .y: return "Y"
        case .scale: return "Scale"
        case .rotation: return "Rotation"
        case .opacity: return "Opacity"
        }
    }
    var unit: String {
        switch self {
        case .x, .y: return "px"
        case .scale, .opacity: return "%"
        case .rotation: return "°"
        }
    }
    func range(canvas: CGSize) -> ClosedRange<Double> {
        switch self {
        case .x: return Double(-canvas.width)...Double(canvas.width * 2)
        case .y: return Double(-canvas.height)...Double(canvas.height * 2)
        case .scale: return 0...400
        case .rotation: return -360...360
        case .opacity: return 0...100
        }
    }
}

struct Keyframe: Identifiable, Equatable {
    var id = UUID()
    var time: Double
    var value: Double
    var easing: CubicBezier          // easing from this key to the next
}

enum LayerKind: String, CaseIterable, Identifiable {
    case video, text, shape
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .video: return "film"
        case .text: return "textformat"
        case .shape: return "square.on.circle"
        }
    }
    var tint: Color {
        switch self {
        case .video: return .indigo
        case .text: return .purple
        case .shape: return .pink
        }
    }
}

enum ShapeKind: String, CaseIterable, Identifiable {
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

enum BlendKind: String, CaseIterable, Identifiable {
    case normal, add, screen, multiply
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

// MARK: - Layer

struct Layer: Identifiable, Equatable {
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
    var color: Color = .white
    var sourceSize = CGSize(width: 1920, height: 1080)    // video pixels

    static func defaultBase(canvas: CGSize) -> [TransformProp: Double] {
        [.x: Double(canvas.width) / 2, .y: Double(canvas.height) / 2,
         .scale: 100, .rotation: 0, .opacity: 100]
    }

    func isActive(at t: Double) -> Bool { visible && t >= start - 1e-6 && t <= end + 1e-6 }

    /// Key/value interpolation only (no expressions). Used by the UI and as the expression's `value`.
    func rawValue(_ p: TransformProp, at t: Double) -> Double {
        guard let keys = tracks[p], !keys.isEmpty else { return base[p] ?? 0 }
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
        switch kind {
        case .video: return "video:\(id)"
        case .text: return "text|\(text)|\(Int(fontSize))|\(colorKey)"
        case .shape: return "shape|\(shape.rawValue)|\(Int(shapeWidth))x\(Int(shapeHeight))|\(colorKey)"
        }
    }

    private var colorKey: String {
        let comps = UIColor(color).cgColor.components ?? []
        return comps.map { String(format: "%.3f", Double($0)) }.joined(separator: ",")
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

// MARK: - Effects

struct FXSettings: Equatable {
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
    var layers: [Layer] = []
    var selectedID: UUID?
    var time = 0.0
    var duration = 10.0
    var fps = 30.0
    var canvas = CGSize(width: 1920, height: 1080)
    var isPlaying = false
    var easing = CubicBezier.easeInOut
    var fx = FXSettings()
    var expressionError: String?

    @ObservationIgnored var videos: [UUID: VideoSource] = [:]
    let exprEngine = ExpressionEngine()

    // MARK: History (snapshot based; the view layer calls commitIfChanged() after edits settle)
    struct Snapshot: Equatable {
        var layers: [Layer]
        var fx: FXSettings
        var duration: Double
        var selectedID: UUID?
    }
    var canUndo = false
    var canRedo = false
    @ObservationIgnored private var undoStack: [Snapshot] = []
    @ObservationIgnored private var redoStack: [Snapshot] = []
    @ObservationIgnored private var committed: Snapshot?

    private var currentSnapshot: Snapshot {
        Snapshot(layers: layers, fx: fx, duration: duration, selectedID: selectedID)
    }

    init() { committed = currentSnapshot }

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
    func applyEasingToKeys(atPlayhead: Bool = true) {
        guard let i = selectedIndex else { return }
        let t = snapped(time)
        for p in layers[i].tracks.keys {
            guard var keys = layers[i].tracks[p] else { continue }
            for k in keys.indices where abs(keys[k].time - t) < 0.5 / fps { keys[k].easing = easing }
            layers[i].tracks[p] = keys
        }
    }

    // MARK: Layers
    func addLayer(kind: LayerKind) {
        var l = Layer(name: "\(kind.title) \(layers.count + 1)", kind: kind,
                      start: time, end: min(time + 4, max(duration, time + 1)))
        l.base = Layer.defaultBase(canvas: canvas)
        if kind == .shape { l.color = Color(red: 0.30, green: 0.79, blue: 1.0) }
        if kind == .text { l.name = "Title" }
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

    func deleteSelected() {
        guard let i = selectedIndex else { return }
        layers.remove(at: i)                       // the VideoSource stays in `videos` so undo can restore it
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
        selectedID = c.id
    }

    func moveSelected(by delta: Int) {
        guard let i = selectedIndex else { return }
        let j = i + delta
        guard layers.indices.contains(j) else { return }
        layers.swapAt(i, j)
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
