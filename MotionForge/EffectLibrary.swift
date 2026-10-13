// EffectLibrary.swift — browse the full effect list, apply the implemented ones, and edit a layer's effect stack.

import SwiftUI

/// Why a whole category can't be offered yet.
private let categoryNotes: [String: String] = [
    "Audio": "Needs an audio effects engine, which this build doesn't have.",
    "Boris FX Mocha": "Third-party plug-in.",
    "CINEMA 4D": "Needs Maxon's Cineware, a third-party plug-in.",
    "Expression Controls": "Needs controls that other properties can link to.",
    "Obsolete": "Legacy effects that were replaced by newer ones.",
    "Immersive Video": "Needs 360° sphere projection.",
    "Time": "Needs frame history, which the renderer doesn't keep yet.",
    "Simulation": "Needs a particle and physics system.",
    "3D Channel": "Needs depth and ID passes from 3D renders."
]

struct EffectLibrarySheet: View {
    @Bindable var project: ProjectModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var readyOnly = false
    @State private var message: String?

    private var targetLayer: Layer? {
        if let l = project.selected, l.kind.hasImage { return l }
        return nil
    }

    private func visible(_ category: String) -> [CatalogEntry] {
        EffectCatalog.entries(in: category).filter { e in
            (query.isEmpty || e.name.localizedCaseInsensitiveContains(query) || category.localizedCaseInsensitiveContains(query))
                && (!readyOnly || EffectRegistry.isImplemented(e.name))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(EffectRegistry.implementedCount) of \(EffectCatalog.all.count) effects work in this build")
                            .font(.subheadline.weight(.semibold))
                        if let l = targetLayer {
                            Text("Applying to “\(l.name)”").font(.footnote).foregroundStyle(Theme.accent)
                        } else {
                            Text("Select a video, text or shape layer to apply effects.")
                                .font(.footnote).foregroundStyle(Theme.key)
                        }
                        Toggle("Show only working effects", isOn: $readyOnly).tint(Theme.accent).font(.footnote)
                        if let message {
                            Text(message).font(.footnote).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .listRowBackground(Theme.panel)
                }

                ForEach(EffectCatalog.categories, id: \.self) { category in
                    let entries = visible(category)
                    if !entries.isEmpty {
                        let ready = entries.filter { EffectRegistry.isImplemented($0.name) }.count
                        Section {
                            ForEach(entries) { entry in
                                row(entry)
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(category)  ·  \(ready)/\(EffectCatalog.entries(in: category).count) working")
                                if ready == 0, let note = categoryNotes[category] {
                                    Text(note).font(.caption2).textCase(nil)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
            .searchable(text: $query, prompt: "Search effects")
            .navigationTitle("Effect library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private func row(_ entry: CatalogEntry) -> some View {
        let ready = EffectRegistry.isImplemented(entry.name)
        return Button {
            if !ready {
                message = "“\(entry.name)” isn't implemented yet."
            } else if targetLayer == nil {
                message = "Select a video, text or shape layer first."
            } else {
                project.addEffect(entry.name)
                message = "Added “\(entry.name)”. Edit it in the Effects section of the layer."
            }
        } label: {
            HStack {
                Text(entry.name).foregroundStyle(ready ? Theme.textPrimary : Theme.textSecondary)
                Spacer()
                Text(ready ? "Ready" : "Planned")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(ready ? Theme.accent.opacity(0.2) : Color.white.opacity(0.06), in: Capsule())
                    .foregroundStyle(ready ? Theme.accent : Theme.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.panel)
        .accessibilityLabel("\(entry.name), \(ready ? "ready" : "planned")")
    }
}

/// One effect on the selected layer, with its parameters.
struct EffectRow: View {
    @Bindable var project: ProjectModel
    let effect: EffectInstance
    @State private var open = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { project.toggleEffect(effect.id) } label: {
                    Image(systemName: effect.enabled ? "eye" : "eye.slash")
                        .frame(width: 28, height: 28)
                        .foregroundStyle(effect.enabled ? Theme.accent : Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(effect.enabled ? "Disable \(effect.effect)" : "Enable \(effect.effect)")

                Text(effect.effect).font(.footnote.weight(.semibold)).lineLimit(1)
                Spacer()
                Button { withAnimation(.motionPanel) { open.toggle() } } label: {
                    Image(systemName: "chevron.right").font(.caption.weight(.bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? "Hide settings" : "Show settings")
                Button { project.removeEffect(effect.id) } label: {
                    Image(systemName: "trash").frame(width: 28, height: 28).foregroundStyle(Theme.danger)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(effect.effect)")
            }

            if open, let def = EffectRegistry.def(named: effect.effect) {
                ForEach(def.sliders, id: \.key) { s in
                    PropertyRow(
                        title: s.title,
                        value: Binding(get: { project.effectParam(effect.id, s.key, default: s.def) },
                                       set: { project.setEffectParam(effect.id, s.key, $0) }),
                        range: s.min...s.max, decimals: s.decimals)
                }
                ForEach(def.colors, id: \.key) { c in
                    ColorPicker(c.title, selection: colorBinding(c)).font(.footnote)
                }
            }
        }
        .padding(10)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func colorBinding(_ c: EffectColor) -> Binding<Color> {
        Binding(
            get: {
                Color(.sRGB,
                      red: project.effectParam(effect.id, c.key + ".r", default: c.def[0]),
                      green: project.effectParam(effect.id, c.key + ".g", default: c.def[1]),
                      blue: project.effectParam(effect.id, c.key + ".b", default: c.def[2]),
                      opacity: 1)
            },
            set: { color in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
                project.setEffectParam(effect.id, c.key + ".r", Double(r))
                project.setEffectParam(effect.id, c.key + ".g", Double(g))
                project.setEffectParam(effect.id, c.key + ".b", Double(b))
            })
    }
}
