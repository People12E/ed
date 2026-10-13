// HomeView.swift — app entry and the startup screen: new project, import, recent projects.

import SwiftUI
import PhotosUI

@main
struct MotionForgeApp: App {
    var body: some Scene {
        WindowGroup { AppRoot() }
    }
}

struct AppRoot: View {
    @State private var store = ProjectStore()
    @State private var active: ProjectModel?

    var body: some View {
        ZStack {
            HomeView(store: store) { project in
                withAnimation(.motionPanel) { active = project }
            }
            if let project = active {
                EditorView(project: project) {
                    store.reload()
                    withAnimation(.motionPanel) { active = nil }
                }
                .transition(.move(edge: .trailing))
                .zIndex(1)
            }
        }
        .preferredColorScheme(.dark)
        .task { store.reload() }
    }
}

// MARK: - Home

private struct Reveal: ViewModifier {
    let index: Int
    let shown: Bool
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 18)
            .animation(.motionPanel.delay(0.06 * Double(index)), value: shown)
    }
}

struct HomeView: View {
    let store: ProjectStore
    var open: (ProjectModel) -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var busy = false
    @State private var errorText: String?
    @State private var shown = false
    @State private var pendingDelete: ProjectSummary?

    private struct Preset: Identifiable {
        let name: String
        let ratio: String
        let size: CGSize
        var id: String { name }
    }

    private struct Feature: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    private let presets: [Preset] = [
        Preset(name: "Landscape", ratio: "16:9", size: CGSize(width: 1920, height: 1080)),
        Preset(name: "Vertical", ratio: "9:16", size: CGSize(width: 1080, height: 1920)),
        Preset(name: "Square", ratio: "1:1", size: CGSize(width: 1080, height: 1080)),
        Preset(name: "Portrait", ratio: "4:5", size: CGSize(width: 1080, height: 1350))
    ]

    private let features: [Feature] = [
        Feature(symbol: "viewfinder", title: "Face tracking", detail: "Pin text or shapes to a face."),
        Feature(symbol: "scope", title: "Point tracking", detail: "Follow any detail through the clip."),
        Feature(symbol: "eraser", title: "Content fill", detail: "Remove objects, logos and text."),
        Feature(symbol: "function", title: "Expressions", detail: "wiggle(), time and more."),
        Feature(symbol: "scribble.variable", title: "Easing curves", detail: "Draw your own Bézier motion."),
        Feature(symbol: "sparkles", title: "Effect library", detail: "290 effects listed, 51 working today."),
        Feature(symbol: "cube", title: "3D and lighting", detail: "Camera, lights, models, shadows.")
    ]

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            RadialGradient(colors: [Theme.accent.opacity(0.20), Color.clear],
                           center: .topLeading, startRadius: 0, endRadius: 560)
                .ignoresSafeArea()
            RadialGradient(colors: [Theme.key.opacity(0.10), Color.clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 480)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header.modifier(Reveal(index: 0, shown: shown))
                    startRow.modifier(Reveal(index: 1, shown: shown))
                    recents.modifier(Reveal(index: 2, shown: shown))
                    featureRow.modifier(Reveal(index: 3, shown: shown))
                }
                .padding(20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)

            if busy {
                ProgressView("Opening…")
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .onAppear { shown = true }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task { await createFromVideo(item) }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .confirmationDialog("Delete this project?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { item in
            Button("Delete “\(item.name)”", role: .destructive) { store.delete(item) }
        } message: { _ in
            Text("The project and its imported video are removed from this device.")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.panel)
                BezierThumbnail(curve: .easeInOut)
            }
            .frame(width: 64, height: 64)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
            VStack(alignment: .leading, spacing: 2) {
                Text("MotionForge")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Motion graphics, tracking and effects")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.top, 8)
    }

    private var startRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start").font(.headline).foregroundStyle(Theme.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    PhotosPicker(selection: $pickerItem, matching: .videos) {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: "video.badge.plus").font(.system(size: 26, weight: .semibold))
                            Spacer(minLength: 0)
                            Text("Import video").font(.subheadline.weight(.bold))
                            Text("Start from a clip").font(.caption)
                        }
                        .padding(14)
                        .frame(width: 160, height: 132, alignment: .leading)
                        .foregroundStyle(Color.black.opacity(0.85))
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Import video to start a project")

                    ForEach(presets) { preset in
                        Button { create(size: preset.size, name: "Untitled \(preset.ratio)") } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .strokeBorder(Theme.accent, lineWidth: 2)
                                        .aspectRatio(preset.size.width / preset.size.height, contentMode: .fit)
                                        .frame(height: 46)
                                }
                                .frame(height: 56)
                                Spacer(minLength: 0)
                                Text(preset.name).font(.subheadline.weight(.semibold))
                                Text(preset.ratio).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            .padding(14)
                            .frame(width: 140, height: 132, alignment: .leading)
                            .foregroundStyle(Theme.textPrimary)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel("New \(preset.name) project, \(preset.ratio)")
                    }
                }
            }
        }
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent projects").font(.headline).foregroundStyle(Theme.textPrimary)
            if store.items.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "tray").font(.title3)
                    Text("Your projects appear here. They're saved automatically as you work.")
                        .font(.footnote)
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 18) {
                    ForEach(store.items) { item in
                        Button { Task { await openExisting(item) } } label: {
                            ProjectCard(item: item)
                        }
                        .buttonStyle(PressableStyle())
                        .contextMenu {
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = item }
                        }
                    }
                }
            }
        }
    }

    private var featureRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What you can do").font(.headline).foregroundStyle(Theme.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(features) { f in
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: f.symbol)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                            Text(f.title).font(.subheadline.weight(.semibold))
                            Text(f.detail).font(.caption).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(width: 170, height: 118, alignment: .topLeading)
                        .background(Theme.panel.opacity(0.8), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func create(size: CGSize, name: String) {
        let project = ProjectModel()
        project.canvas = size
        project.name = name
        project.save()
        open(project)
    }

    @MainActor
    private func createFromVideo(_ item: PhotosPickerItem) async {
        busy = true
        defer { busy = false }
        do {
            let project = ProjectModel()
            project.name = "Untitled"
            try await importVideoItem(item, into: project)
            project.resetHistory()
            project.save()
            open(project)
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func openExisting(_ item: ProjectSummary) async {
        busy = true
        defer { busy = false }
        do {
            let project = try await ProjectModel.load(directory: item.directory)
            open(project)
        } catch {
            errorText = "That project couldn't be opened: \(error.localizedDescription)"
        }
    }
}

// MARK: - Project card

struct ProjectCard: View {
    let item: ProjectSummary
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                LinearGradient(colors: [Theme.raised, Theme.panel], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "film.stack").font(.title).foregroundStyle(Theme.textSecondary)
                }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))

            Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                .foregroundStyle(Theme.textPrimary)
            Text("\(item.modified.formatted(.relative(presentation: .named))) · \(Int(item.duration.rounded())) s · \(item.layerCount) layers")
                .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .task(id: item.thumbnail) {
            if let url = item.thumbnail { image = UIImage(contentsOfFile: url.path) }
        }
        .accessibilityElement(children: .combine)
    }
}
