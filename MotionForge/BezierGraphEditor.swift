// BezierGraphEditor.swift — MotionForge
// Interactive cubic-bezier easing editor. Drag the two handles; the curve, readout and
// preview ball update live. `CubicBezier` also exports a LUT for GPU/CPU interpolation.

import SwiftUI

// MARK: - Model

struct CubicBezier: Equatable, Hashable {
    var x1: Double, y1: Double, x2: Double, y2: Double

    static let linear    = CubicBezier(x1: 0,    y1: 0,    x2: 1,    y2: 1)
    static let easeIn    = CubicBezier(x1: 0.42, y1: 0,    x2: 1,    y2: 1)
    static let easeOut   = CubicBezier(x1: 0,    y1: 0,    x2: 0.58, y2: 1)
    static let easeInOut = CubicBezier(x1: 0.42, y1: 0,    x2: 0.58, y2: 1)
    static let backOut   = CubicBezier(x1: 0.34, y1: 1.35, x2: 0.64, y2: 1)
    static let backIn    = CubicBezier(x1: 0.36, y1: 0,    x2: 0.66, y2: -0.35)
    static let snap      = CubicBezier(x1: 0.85, y1: 0,    x2: 0.15, y2: 1)

    struct Preset { let name: String; let curve: CubicBezier }
    static let presets: [Preset] = [
        .init(name: "Linear", curve: .linear), .init(name: "Ease in", curve: .easeIn),
        .init(name: "Ease out", curve: .easeOut), .init(name: "Ease in-out", curve: .easeInOut),
        .init(name: "Overshoot", curve: .backOut), .init(name: "Anticipate", curve: .backIn),
        .init(name: "Snap", curve: .snap)
    ]

    private func sampleX(_ t: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t
    }
    private func sampleY(_ t: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t
    }
    private func slopeX(_ t: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * x1 + 6 * u * t * (x2 - x1) + 3 * t * t * (1 - x2)
    }

    /// Eased value for normalized time `x` in 0...1 (Newton–Raphson, bisection fallback).
    func value(at x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        var t = x
        for _ in 0..<8 {
            let err = sampleX(t) - x
            if abs(err) < 1e-7 { return sampleY(t) }
            let d = slopeX(t)
            if abs(d) < 1e-6 { break }
            t = min(max(t - err / d, 0), 1)
        }
        var lo = 0.0, hi = 1.0
        t = x
        for _ in 0..<40 {
            let err = sampleX(t) - x
            if abs(err) < 1e-7 { break }
            if err > 0 { hi = t } else { lo = t }
            t = (lo + hi) / 2
        }
        return sampleY(t)
    }

    /// Lookup table for upload to a Metal buffer (`constant float* easingLUT`).
    func lut(count: Int = 256) -> [Float] {
        (0..<count).map { Float(value(at: Double($0) / Double(count - 1))) }
    }
}

// MARK: - Editor

struct BezierGraphEditor: View {
    @Binding var curve: CubicBezier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragging: Int?

    private let yMin = -0.5, yMax = 1.5
    private let inset: CGFloat = 22

    private var activePreset: String? { CubicBezier.presets.first { $0.curve == curve }?.name }

    var body: some View {
        VStack(spacing: 14) {
            graph
            Text(String(format: "cubic-bezier(%.2f, %.2f, %.2f, %.2f)", curve.x1, curve.y1, curve.x2, curve.y2))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            presets
            previewTrack
        }
        .sensoryFeedback(.selection, trigger: activePreset)
    }

    // MARK: Graph

    private var graph: some View {
        GeometryReader { geo in
            let plot = CGRect(x: inset, y: inset,
                              width: geo.size.width - inset * 2, height: geo.size.height - inset * 2)
            let p0 = map(0, 0, plot), p3 = map(1, 1, plot)
            let p1 = map(curve.x1, curve.y1, plot), p2 = map(curve.x2, curve.y2, plot)

            ZStack {
                Canvas { ctx, _ in
                    let unit = Path(CGRect(x: p0.x, y: p3.y, width: p3.x - p0.x, height: p0.y - p3.y))
                    ctx.fill(unit, with: .color(.white.opacity(0.04)))
                    for i in 1..<4 {
                        let f = CGFloat(i) / 4
                        var grid = Path()
                        grid.move(to: CGPoint(x: p0.x + (p3.x - p0.x) * f, y: p0.y))
                        grid.addLine(to: CGPoint(x: p0.x + (p3.x - p0.x) * f, y: p3.y))
                        grid.move(to: CGPoint(x: p0.x, y: p0.y + (p3.y - p0.y) * f))
                        grid.addLine(to: CGPoint(x: p3.x, y: p0.y + (p3.y - p0.y) * f))
                        ctx.stroke(grid, with: .color(.white.opacity(0.07)), lineWidth: 1)
                    }
                    ctx.stroke(unit, with: .color(.white.opacity(0.22)), lineWidth: 1)

                    var arms = Path()
                    arms.move(to: p0); arms.addLine(to: p1)
                    arms.move(to: p3); arms.addLine(to: p2)
                    ctx.stroke(arms, with: .color(Theme.accent.opacity(0.7)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

                    var path = Path()
                    path.move(to: p0)
                    path.addCurve(to: p3, control1: p1, control2: p2)   // affine map keeps the curve exact
                    ctx.stroke(path, with: .color(Theme.key),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    for p in [p0, p3] {
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                                 with: .color(Theme.key))
                    }
                }
                handle(1, at: p1, plot: plot)
                handle(2, at: p2, plot: plot)
            }
            .coordinateSpace(name: "plot")
        }
        .aspectRatio(0.85, contentMode: .fit)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func handle(_ index: Int, at point: CGPoint, plot: CGRect) -> some View {
        Circle().fill(Theme.accent)
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .scaleEffect(dragging == index ? 1.3 : 1)
            .animation(.motionSnap, value: dragging)
            .frame(width: 44, height: 44)                       // 44 pt hit target
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("plot"))
                    .onChanged { v in
                        dragging = index
                        let n = unmap(v.location, plot)
                        let x = (min(max(n.x, 0), 1) * 100).rounded() / 100
                        let y = (min(max(n.y, yMin), yMax) * 100).rounded() / 100
                        if index == 1 { curve.x1 = x; curve.y1 = y } else { curve.x2 = x; curve.y2 = y }
                    }
                    .onEnded { _ in dragging = nil }
            )
            .position(point)
            .accessibilityLabel("Easing control point \(index)")
            .accessibilityValue(index == 1 ? "x \(curve.x1), y \(curve.y1)" : "x \(curve.x2), y \(curve.y2)")
            .accessibilityAdjustableAction { direction in
                let d = direction == .increment ? 0.05 : -0.05
                if index == 1 { curve.y1 = min(max(curve.y1 + d, yMin), yMax) }
                else { curve.y2 = min(max(curve.y2 + d, yMin), yMax) }
            }
    }

    // MARK: Presets + preview

    private var presets: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CubicBezier.presets, id: \.name) { preset in
                    let on = curve == preset.curve
                    Button { curve = preset.curve } label: {
                        Text(preset.name)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(on ? Theme.accent.opacity(0.25) : Theme.raised, in: Capsule())
                            .foregroundStyle(on ? Theme.accent : Theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var previewTrack: some View {
        TimelineView(.animation(paused: reduceMotion)) { tl in
            let cycle = 1.8
            let phase = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
            let u = reduceMotion ? 1 : min(phase / 0.7, 1)          // travel 70 %, hold 30 %
            let e = curve.value(at: u)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raised).frame(height: 6)
                    Circle().fill(Theme.key).frame(width: 18, height: 18)
                        .offset(x: (g.size.width - 18) * CGFloat(e))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 24)
        }
    }

    // MARK: Coordinate mapping (normalized value space <-> view space)

    private func map(_ nx: Double, _ ny: Double, _ r: CGRect) -> CGPoint {
        CGPoint(x: r.minX + CGFloat(nx) * r.width,
                y: r.maxY - CGFloat((ny - yMin) / (yMax - yMin)) * r.height)
    }
    private func unmap(_ p: CGPoint, _ r: CGRect) -> (x: Double, y: Double) {
        (Double((p.x - r.minX) / r.width),
         yMin + Double((r.maxY - p.y) / r.height) * (yMax - yMin))
    }
}

// MARK: - Small read-only thumbnail used by the property drawer

struct BezierThumbnail: View {
    let curve: CubicBezier
    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 10)
            func pt(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: r.minX + r.width * x, y: r.maxY - r.height * y)
            }
            var p = Path()
            p.move(to: pt(0, 0))
            p.addCurve(to: pt(1, 1), control1: pt(curve.x1, curve.y1), control2: pt(curve.x2, curve.y2))
            ctx.stroke(p, with: .color(Theme.key), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
        .frame(width: 64, height: 44)
        .accessibilityHidden(true)
    }
}
