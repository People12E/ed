// Timeline.swift — spring-snapped dock, transport, pinch-zoom multi-track timeline.

import SwiftUI

enum TimelineDetent: CGFloat, CaseIterable {
    case collapsed = 68, mid = 290, full = 470
}

struct TimelineDock: View {
    @Bindable var project: ProjectModel
    @Binding var detent: TimelineDetent
    @GestureState private var dragY: CGFloat = 0

    var body: some View {
        let h = min(max(detent.rawValue - dragY, 68), 470)
        VStack(spacing: 0) {
            Capsule().fill(Color.white.opacity(0.25)).frame(width: 40, height: 5)
                .frame(maxWidth: .infinity, minHeight: 22)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .updating($dragY) { value, state, _ in state = value.translation.height }
                        .onEnded { value in
                            let target = detent.rawValue - value.predictedEndTranslation.height
                            detent = TimelineDetent.allCases
                                .min { abs($0.rawValue - target) < abs($1.rawValue - target) } ?? detent
                        }
                )
                .accessibilityLabel("Resize timeline")
                .accessibilityAdjustableAction { direction in
                    let all = TimelineDetent.allCases
                    if let i = all.firstIndex(of: detent) {
                        detent = all[min(max(i + (direction == .increment ? 1 : -1), 0), all.count - 1)]
                    }
                }
            TransportBar(project: project)
            if h > 140 { TrackArea(project: project).transition(.opacity) }
        }
        .frame(height: h, alignment: .top)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .animation(.motionPanel, value: detent)
    }
}

struct TransportBar: View {
    @Bindable var project: ProjectModel

    var body: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "backward.end.fill", label: "Go to start") { project.time = 0 }
            IconButton(symbol: "chevron.left", label: "Previous frame") { project.step(frames: -1) }
            Button { withAnimation(.motionSnap) { project.isPlaying.toggle() } } label: {
                Image(systemName: project.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 48, height: 40)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(Color.black.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(project.isPlaying ? "Pause" : "Play")
            IconButton(symbol: "chevron.right", label: "Next frame") { project.step(frames: 1) }
            Text(project.timecode)
                .font(.system(.subheadline, design: .rounded, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 12).frame(height: 32)
                .background(Theme.canvas, in: Capsule())
                .padding(.leading, 6)
            Spacer()
            Menu {
                Button { project.addLayer(kind: .text) } label: { Label("Text", systemImage: LayerKind.text.symbol) }
                Button { project.addLayer(kind: .shape) } label: { Label("Shape", systemImage: LayerKind.shape.symbol) }
                Button { project.addLayer(kind: .fill) } label: { Label("Content fill", systemImage: LayerKind.fill.symbol) }
                Divider()
                Button { project.addLayer(kind: .null) } label: { Label("Null object", systemImage: LayerKind.null.symbol) }
                Button { project.addLayer(kind: .camera) } label: { Label("3D camera", systemImage: LayerKind.camera.symbol) }
                Menu {
                    ForEach(LightType.allCases) { t in
                        Button(t.title) { project.addLayer(kind: .light, lightType: t) }
                    }
                } label: { Label("Light", systemImage: LayerKind.light.symbol) }
                Button { project.showModelImporter = true } label: { Label("3D model…", systemImage: LayerKind.model.symbol) }
            } label: {
                Image(systemName: "plus").font(.system(size: 16, weight: .bold))
                    .frame(width: 40, height: 40)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(Theme.textPrimary)
            }
            .accessibilityLabel("Add layer")
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
    }
}

struct TrackArea: View {
    @Bindable var project: ProjectModel
    @State private var pxPerSec: CGFloat = 110
    @State private var zoomBase: CGFloat = 110

    private let labelW: CGFloat = 116
    private let rowH: CGFloat = 40
    private let rulerH: CGFloat = 28

    private var contentW: CGFloat { CGFloat(project.duration) * pxPerSec + 80 }
    private var rows: [Layer] { Array(project.layers.reversed()) }      // top layer first, like AE

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                // Pinned label column (does not scroll horizontally)
                VStack(spacing: 0) {
                    Color.clear.frame(height: rulerH)
                    ForEach(rows) { layer in
                        HStack(spacing: 6) {
                            Image(systemName: layer.kind.symbol).font(.caption)
                                .foregroundStyle(layer.kind.tint).frame(width: 18)
                            Text(layer.name).font(.footnote.weight(.medium)).lineLimit(1)
                                .opacity(layer.visible ? 1 : 0.4)
                        }
                        .padding(.horizontal, 10)
                        .frame(width: labelW, height: rowH, alignment: .leading)
                        .background(project.selectedID == layer.id ? Theme.accent.opacity(0.12) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { project.selectedID = layer.id }
                    }
                }
                .frame(width: labelW)
                .background(Theme.panel.opacity(0.6))

                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            ruler
                            ForEach(rows) { layer in
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(project.selectedID == layer.id
                                                     ? Theme.accent.opacity(0.06) : Color.clear)
                                    ClipView(layer: layer, pxPerSec: pxPerSec, rowH: rowH,
                                             selected: project.selectedID == layer.id) { time in
                                        project.selectedID = layer.id
                                        project.time = project.snapped(time)
                                    }
                                }
                                .frame(width: contentW, height: rowH)
                                .contentShape(Rectangle())
                                .onTapGesture { project.selectedID = layer.id }
                                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                            }
                        }
                        playhead
                    }
                    .frame(width: contentW, alignment: .topLeading)
                }
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { pxPerSec = min(max(zoomBase * $0.magnification, 24), 900) }
                        .onEnded { _ in zoomBase = pxPerSec }
                )
            }
        }
    }

    private var ruler: some View {
        Canvas { ctx, size in
            let step: Double = pxPerSec > 220 ? 0.5 : pxPerSec > 90 ? 1 : pxPerSec > 45 ? 2 : 5
            var t = 0.0
            while t <= project.duration + 0.0001 {
                let x = CGFloat(t) * pxPerSec
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height - 9))
                tick.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(tick, with: .color(.white.opacity(0.35)), lineWidth: 1)
                let label = t.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(t))s" : String(format: "%.1fs", t)
                ctx.draw(Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.55)),
                         at: CGPoint(x: x + 4, y: 9), anchor: .leading)
                t += step
            }
        }
        .frame(width: contentW, height: rulerH)
        .background(Theme.panel.opacity(0.6))
        .contentShape(Rectangle())
        .highPriorityGesture(                                         // scrub; beats the scroll view's pan
            DragGesture(minimumDistance: 0).onChanged {
                project.time = project.snapped(Double($0.location.x / pxPerSec))
            }
        )
        .accessibilityLabel("Timeline ruler")
        .accessibilityAdjustableAction { direction in project.step(frames: direction == .increment ? 1 : -1) }
    }

    private var playhead: some View {
        Rectangle().fill(Theme.key).frame(width: 2)
            .overlay(alignment: .top) { Capsule().fill(Theme.key).frame(width: 14, height: 16) }
            .offset(x: CGFloat(project.time) * pxPerSec - 1)
            .allowsHitTesting(false)
    }
}

struct ClipView: View {
    let layer: Layer
    let pxPerSec: CGFloat
    let rowH: CGFloat
    let selected: Bool
    var onKeyTap: (Double) -> Void

    var body: some View {
        let w = max(8, CGFloat(layer.end - layer.start) * pxPerSec)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(layer.kind.tint.opacity(layer.visible ? 0.55 : 0.2))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Color.white.opacity(0.12),
                                  lineWidth: selected ? 1.5 : 1))
            ForEach(layer.allKeyTimes, id: \.self) { t in
                Rectangle().fill(Theme.key)
                    .frame(width: 9, height: 9).rotationEffect(.degrees(45))
                    .frame(width: 24, height: 24).contentShape(Rectangle())     // 24 pt touch target
                    .offset(x: CGFloat(t - layer.start) * pxPerSec - 12)
                    .onTapGesture { onKeyTap(t) }
                    .accessibilityLabel("Keyframe at \(String(format: "%.2f", t)) seconds")
            }
        }
        .frame(width: w, height: rowH - 10)
        .offset(x: CGFloat(layer.start) * pxPerSec)
    }
}
