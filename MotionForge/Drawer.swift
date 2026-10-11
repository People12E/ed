// Drawer.swift — collapsible property drawer with spring-animated sections.

import SwiftUI

struct DrawerSection<Content: View>: View {
    let title: String
    let symbol: String
    @Binding var isOpen: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.motionPanel) { isOpen.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: symbol).frame(width: 22).foregroundStyle(Theme.accent)
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.bold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Collapse section" : "Expand section")

            if isOpen {
                VStack(spacing: 12) { content() }
                    .padding(.horizontal, 14).padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Theme.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipped()
    }
}

/// A labelled slider with an optional keyframe diamond.
struct PropertyRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit = ""
    var keyState: KeyState? = nil
    var onToggleKey: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let keyState, let onToggleKey {
                Button { withAnimation(.motionSnap) { onToggleKey() } } label: {
                    Image(systemName: keyState == .onKey ? "diamond.fill" : "diamond")
                        .foregroundStyle(keyState == .off ? Theme.textSecondary : Theme.key)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title) keyframe")
                .accessibilityValue(keyState == .onKey ? "On at playhead"
                                    : keyState == .animated ? "Animated" : "Off")
            }
            Text(title).font(.footnote).foregroundStyle(Theme.textSecondary)
                .frame(width: 64, alignment: .leading)
            Slider(value: $value, in: range).tint(Theme.accent)
            Text("\(value, specifier: "%.0f")\(unit)")
                .font(.footnote.monospacedDigit())
                .frame(width: 58, alignment: .trailing)
        }
    }
}

struct PropertyDrawer: View {
    @Bindable var project: ProjectModel
    @Binding var showGraph: Bool
    @State private var open: Set<String> = ["Layer", "Transform", "Effects"]
    @State private var exprProp: TransformProp = .rotation

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { open.contains(key) },
                set: { if $0 { open.insert(key) } else { open.remove(key) } })
    }

    /// Two-way binding into the selected layer.
    private func layerBinding<T>(_ keyPath: WritableKeyPath<Layer, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { project.selected?[keyPath: keyPath] ?? fallback },
            set: { newValue in
                if let i = project.selectedIndex { project.layers[i][keyPath: keyPath] = newValue }
            })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let layer = project.selected {
                    layerSection(layer)
                    transformSection
                    expressionSection
                } else {
                    Text("Select a layer in the timeline or on the canvas to edit it.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        .background(Theme.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                effectsSection
                easingSection
                neuralSection
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.hairline))
        .padding(8)
    }

    // MARK: Layer

    @ViewBuilder
    private func layerSection(_ layer: Layer) -> some View {
        DrawerSection(title: "Layer", symbol: "square.stack.3d.up", isOpen: binding("Layer")) {
            TextField("Name", text: layerBinding(\.name, fallback: ""))
                .textFieldStyle(.roundedBorder)

            switch layer.kind {
            case .text:
                TextField("Text", text: layerBinding(\.text, fallback: ""), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                PropertyRow(title: "Size", value: layerBinding(\.fontSize, fallback: 140), range: 20...400, unit: "pt")
                ColorPicker("Color", selection: layerBinding(\.color, fallback: .white))
                    .font(.footnote)
            case .shape:
                Picker("Shape", selection: layerBinding(\.shape, fallback: .roundedRectangle)) {
                    ForEach(ShapeKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                PropertyRow(title: "Width", value: layerBinding(\.shapeWidth, fallback: 480), range: 20...2000, unit: "px")
                PropertyRow(title: "Height", value: layerBinding(\.shapeHeight, fallback: 300), range: 20...2000, unit: "px")
                ColorPicker("Color", selection: layerBinding(\.color, fallback: .white))
                    .font(.footnote)
            case .video:
                Text("Source \(Int(layer.sourceSize.width)) × \(Int(layer.sourceSize.height))")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Picker("Blend", selection: layerBinding(\.blend, fallback: .normal)) {
                ForEach(BlendKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Toggle("Visible", isOn: layerBinding(\.visible, fallback: true)).tint(Theme.accent)

            PropertyRow(title: "Start", value: startBinding, range: 0...max(project.duration, 1), unit: "s")
            PropertyRow(title: "End", value: endBinding, range: 0...max(project.duration, 1), unit: "s")

            HStack(spacing: 8) {
                actionButton("doc.on.doc", "Duplicate layer") { project.duplicateSelected() }
                actionButton("arrow.up", "Bring forward") { project.moveSelected(by: 1) }
                actionButton("arrow.down", "Send backward") { project.moveSelected(by: -1) }
                Spacer()
                actionButton("trash", "Delete layer", tint: Theme.danger) { project.deleteSelected() }
            }
        }
    }

    private var startBinding: Binding<Double> {
        Binding(get: { project.selected?.start ?? 0 },
                set: { v in
                    if let i = project.selectedIndex {
                        project.layers[i].start = min(v, project.layers[i].end - 1 / project.fps)
                    }
                })
    }

    private var endBinding: Binding<Double> {
        Binding(get: { project.selected?.end ?? 0 },
                set: { v in
                    if let i = project.selectedIndex {
                        project.layers[i].end = max(v, project.layers[i].start + 1 / project.fps)
                    }
                })
    }

    private func actionButton(_ symbol: String, _ label: String, tint: Color = Theme.textPrimary,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 40)
                .foregroundStyle(tint)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }

    // MARK: Transform

    private var transformSection: some View {
        DrawerSection(title: "Transform", symbol: "move.3d", isOpen: binding("Transform")) {
            ForEach(TransformProp.allCases) { p in
                PropertyRow(
                    title: p.title,
                    value: Binding(get: { project.value(p) }, set: { project.setValue(p, $0) }),
                    range: p.range(canvas: project.canvas),
                    unit: p.unit,
                    keyState: project.keyState(p),
                    onToggleKey: { project.toggleKey(p) })
            }
            Text("Tap a diamond to set a keyframe at the playhead. Once a property has keyframes, editing it keys automatically.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Expressions

    private var expressionSection: some View {
        DrawerSection(title: "Expression", symbol: "function", isOpen: binding("Expression")) {
            Picker("Property", selection: $exprProp) {
                ForEach(TransformProp.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            TextField("e.g. wiggle(2, 30)", text: expressionBinding, axis: .vertical)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(10)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let error = project.expressionError {
                Text(error).font(.caption).foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Available: time, index, value, wiggle(freq, amp), linear(t, a, b, c, d), ease(t, a, b, c, d)")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var expressionBinding: Binding<String> {
        Binding(
            get: { project.selected?.expressions[exprProp] ?? "" },
            set: { text in
                guard let i = project.selectedIndex else { return }
                project.layers[i].expressions[exprProp] = text.isEmpty ? nil : text
                project.expressionError = project.exprEngine.validate(text)
            })
    }

    // MARK: Effects

    private var effectsSection: some View {
        DrawerSection(title: "Composition effects", symbol: "wand.and.stars", isOpen: binding("Effects")) {
            Toggle("Enable effects", isOn: $project.fx.enabled).tint(Theme.accent)
            Toggle("Displacement map", isOn: $project.fx.displaceEnabled).tint(Theme.accent)
            PropertyRow(title: "Amount", value: $project.fx.displaceScale, range: 0...120, unit: "px")
            PropertyRow(title: "Turbulence", value: $project.fx.turbulence, range: 0...80, unit: "px")
            PropertyRow(title: "Aberration", value: $project.fx.caAmount, range: 0...40, unit: "px")
            PropertyRow(title: "Falloff", value: $project.fx.caFalloff, range: 0.5...4)
            PropertyRow(title: "Length", value: $project.duration, range: 1...300, unit: "s")
        }
    }

    // MARK: Easing

    private var easingSection: some View {
        DrawerSection(title: "Easing", symbol: "scribble.variable", isOpen: binding("Easing")) {
            Button { showGraph = true } label: {
                HStack {
                    BezierThumbnail(curve: project.easing)
                    Spacer()
                    Text("Edit curve").font(.footnote.weight(.semibold))
                    Image(systemName: "chevron.right").font(.caption)
                }
                .foregroundStyle(Theme.textPrimary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Neural (not included in this build)

    private var neuralSection: some View {
        DrawerSection(title: "Neural restoration", symbol: "brain", isOpen: binding("Neural")) {
            Text("Face restore, frame interpolation and detail upscale need Core ML models, and none are bundled with this build. The Neural Engine bridge is in NeuralStage.swift; see ARCHITECTURE.md for how to add models.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
