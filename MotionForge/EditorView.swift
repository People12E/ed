// EditorView.swift — the editor: top bar, Metal preview, property drawer, timeline.
// Requires iOS 17+ (Observation, MagnifyGesture, sensoryFeedback).

import SwiftUI
import MetalKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Video import

struct VideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            // The received file is deleted when this closure returns, so copy it.
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return VideoFile(url: copy)
        }
    }
}

/// Copies the picked video into the project's media folder and adds it as a layer.
@MainActor
func importVideoItem(_ item: PhotosPickerItem, into project: ProjectModel) async throws {
    guard let file = try await item.loadTransferable(type: VideoFile.self) else { throw VideoError.noVideoTrack }
    guard let device = MTLCreateSystemDefaultDevice() else { throw VideoError.noTextureCache }
    let destination = project.mediaDirectory.appendingPathComponent(file.url.lastPathComponent)
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: file.url, to: destination)
    let source = try await VideoSource.load(url: destination, device: device)
    let count = project.layers.filter { $0.kind == .video }.count + 1
    project.isPlaying = false
    project.addVideo(source: source, name: "Clip \(count)")
}

// MARK: - Editor

struct EditorView: View {
    let project: ProjectModel
    var onClose: () -> Void

    @State private var clock = PlaybackClock()
    @State private var drawerOpen = true
    @State private var showCompare = false
    @State private var showGraph = false
    @State private var showExport = false
    @State private var showLibrary = false
    @State private var detent: TimelineDetent = .mid
    @State private var pickerItem: PhotosPickerItem?
    @State private var importing = false
    @State private var importError: String?
    @State private var historyTask: Task<Void, Never>?
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar(project: project, pickerItem: $pickerItem, showCompare: $showCompare,
                       showGraph: $showGraph, showExport: $showExport, drawerOpen: $drawerOpen,
                       onClose: close)
                GeometryReader { geo in
                    if hSize == .regular && geo.size.width > 820 {
                        HStack(spacing: 0) {                               // iPad: inspector docks right
                            PreviewStage(project: project, pickerItem: $pickerItem, showCompare: showCompare)
                            if drawerOpen {
                                PropertyDrawer(project: project, showGraph: $showGraph, showLibrary: $showLibrary)
                                    .frame(width: 330)
                                    .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                    } else {
                        ZStack(alignment: .bottom) {                       // iPhone: inspector is a bottom sheet
                            PreviewStage(project: project, pickerItem: $pickerItem, showCompare: showCompare)
                            if drawerOpen {
                                PropertyDrawer(project: project, showGraph: $showGraph, showLibrary: $showLibrary)
                                    .frame(maxHeight: geo.size.height * 0.6)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                    }
                }
                .animation(.motionPanel, value: drawerOpen)
                TimelineDock(project: project, detent: $detent)
            }
            if let notice = project.notice {
                VStack {
                    Spacer()
                    Text(notice)
                        .font(.footnote.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal, 24).padding(.bottom, 96)
                        .onTapGesture { project.notice = nil }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if importing {
                ProgressView("Importing…")
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .sheet(isPresented: $showGraph) { EasingSheet(project: project) }
        .sheet(isPresented: $showExport) { ExportSheet(project: project) }
        .sheet(isPresented: $showLibrary) { EffectLibrarySheet(project: project) }
        .fileImporter(isPresented: Binding(get: { project.showModelImporter },
                                           set: { project.showModelImporter = $0 }),
                      allowedContentTypes: Self.modelTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await importModel(urls) } }
        }
        .animation(.motionPanel, value: project.notice)
        .onChange(of: project.notice) { _, text in
            guard let text else { return }
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if project.notice == text { project.notice = nil }
            }
        }
        .alert("Couldn't import that video", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importError ?? "") }
        .onAppear { clock.onTick = { [project] dt in project.advance(by: dt) } }
        .onChange(of: project.isPlaying) { _, playing in
            if playing { clock.start() } else { clock.stop() }
        }
        .onChange(of: project.layers) { _, _ in scheduleHistoryCommit() }
        .onChange(of: project.fx) { _, _ in scheduleHistoryCommit() }
        .onChange(of: project.duration) { _, _ in scheduleHistoryCommit() }
        .onChange(of: project.name) { _, _ in scheduleHistoryCommit() }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task { await runImport(item) }
        }
        .onDisappear { project.isPlaying = false; project.save() }
    }

    private func close() {
        project.isPlaying = false
        historyTask?.cancel()
        project.commitIfChanged()
        project.save()
        onClose()
    }

    /// Waits for edits (slider drags, typing) to settle, then records one undo step and saves.
    @MainActor
    private func scheduleHistoryCommit() {
        historyTask?.cancel()
        historyTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            if !Task.isCancelled {
                project.commitIfChanged()
                project.save()
            }
        }
    }

    static var modelTypes: [UTType] {
        var types: [UTType] = [.usdz, .threeDContent]
        for ext in ["usd", "usda", "usdc", "obj", "mtl", "stl", "ply", "png", "jpg", "jpeg"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }

    /// Copies the picked files (a model plus any materials and textures) into the project and loads the model.
    @MainActor
    private func importModel(_ urls: [URL]) async {
        importing = true
        defer { importing = false }
        do {
            let id = UUID().uuidString
            let folder = project.mediaDirectory.appendingPathComponent("model-\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var copied: [URL] = []
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let dest = folder.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: url, to: dest)
                copied.append(dest)
            }
            // Prefer self-contained formats, then OBJ and the rest.
            let order = ["usdz", "usd", "usdc", "usda", "obj", "ply", "stl"]
            var main: URL?
            for ext in order where main == nil {
                main = copied.first { $0.pathExtension.lowercased() == ext }
            }
            guard let file = main else { throw ModelError.unreadable }
            guard let device = MTLCreateSystemDefaultDevice() else { throw VideoError.noTextureCache }
            let asset = try ModelAsset.load(url: file, device: device)
            project.addModel(asset: asset, relativePath: "model-\(id)/\(file.lastPathComponent)",
                             name: file.deletingPathExtension().lastPathComponent)
            project.save()
        } catch {
            importError = error.localizedDescription
        }
    }

    @MainActor
    private func runImport(_ item: PhotosPickerItem) async {
        importing = true
        defer { importing = false }
        do {
            try await importVideoItem(item, into: project)
            project.save()
        } catch {
            importError = error.localizedDescription
        }
    }
}

// MARK: - Top bar

struct TopBar: View {
    @Bindable var project: ProjectModel
    @Binding var pickerItem: PhotosPickerItem?
    @Binding var showCompare: Bool
    @Binding var showGraph: Bool
    @Binding var showExport: Bool
    @Binding var drawerOpen: Bool
    var onClose: () -> Void
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "chevron.left", label: "Back to projects") { onClose() }
            TextField("Project name", text: $project.name)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .submitLabel(.done)
                .frame(maxWidth: 170)
            Spacer(minLength: 4)

            if hSize == .regular {
                IconButton(symbol: "arrow.uturn.backward", label: "Undo") { project.undo() }
                    .disabled(!project.canUndo).opacity(project.canUndo ? 1 : 0.35)
                IconButton(symbol: "arrow.uturn.forward", label: "Redo") { project.redo() }
                    .disabled(!project.canRedo).opacity(project.canRedo ? 1 : 0.35)
                IconButton(symbol: "rectangle.split.2x1", label: "Compare before and after effects",
                           isOn: showCompare) { withAnimation(.motionPanel) { showCompare.toggle() } }
                IconButton(symbol: "point.topleft.down.to.point.bottomright.curvepath",
                           label: "Easing curve editor") { showGraph = true }
            } else {
                Menu {
                    Button("Undo", systemImage: "arrow.uturn.backward") { project.undo() }
                        .disabled(!project.canUndo)
                    Button("Redo", systemImage: "arrow.uturn.forward") { project.redo() }
                        .disabled(!project.canRedo)
                    Button(showCompare ? "Hide compare" : "Compare effects", systemImage: "rectangle.split.2x1") {
                        withAnimation(.motionPanel) { showCompare.toggle() }
                    }
                    Button("Easing curve", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                        showGraph = true
                    }
                } label: {
                    IconFace(symbol: "ellipsis.circle", isOn: showCompare)
                }
                .accessibilityLabel("More")
            }

            PhotosPicker(selection: $pickerItem, matching: .videos) {
                IconFace(symbol: "video.badge.plus")
            }
            .accessibilityLabel("Import video")
            IconButton(symbol: "sidebar.right", label: "Properties", isOn: drawerOpen) {
                withAnimation(.motionPanel) { drawerOpen.toggle() }
            }
            Button { project.isPlaying = false; showExport = true } label: {
                Text("Export").font(.subheadline.weight(.bold))
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(Color.black.opacity(0.85))
            }
            .buttonStyle(PressableStyle())
            .disabled(project.layers.isEmpty)
            .opacity(project.layers.isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

// MARK: - Preview

struct PreviewStage: View {
    let project: ProjectModel
    @Binding var pickerItem: PhotosPickerItem?
    let showCompare: Bool
    @State private var split: CGFloat = 0.5

    var body: some View {
        let aspect = max(0.2, project.canvas.width / max(project.canvas.height, 1))
        MetalPreview(project: project, splitX: showCompare ? Float(split) : 0)
            .aspectRatio(aspect, contentMode: .fit)
            .overlay { if showCompare { CompareDivider(split: $split) } }
            .overlay { GuideOverlay(project: project) }
            .overlay { TrackerOverlay(project: project) }
            .overlay {
                if project.layers.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "film.stack").font(.system(size: 34))
                        Text("Import a video, or add text, shapes and content fill from the + menu.")
                            .font(.footnote).multilineTextAlignment(.center)
                        PhotosPicker(selection: $pickerItem, matching: .videos) {
                            Text("Import video").font(.subheadline.weight(.bold))
                                .padding(.horizontal, 16).frame(height: 36)
                                .background(Theme.accent, in: Capsule())
                                .foregroundStyle(Color.black.opacity(0.85))
                        }
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(24)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Crosshairs for null objects, shown in the editor only (never in the render).
struct GuideOverlay: View {
    @Bindable var project: ProjectModel

    var body: some View {
        GeometryReader { g in
            let scale = g.size.width / max(project.canvas.width, 1)
            ForEach(project.layers.filter { $0.kind == .null && $0.isActive(at: project.time) }) { l in
                let w = WorldTransform.compute(l, in: project.layers, at: project.time, engine: nil)
                Image(systemName: "plus.viewfinder")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(project.selectedID == l.id ? Theme.accent : Color.white.opacity(0.75))
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .onTapGesture { project.selectedID = l.id }
                    .position(x: w.x * scale, y: w.y * scale)
                    .accessibilityLabel("Null object \(l.name)")
            }
        }
    }
}

/// Draggable box used to choose what the point tracker follows.
struct TrackerOverlay: View {
    @Bindable var project: ProjectModel

    var body: some View {
        GeometryReader { g in
            if let p = project.trackerPoint {
                let scale = g.size.width / max(project.canvas.width, 1)
                let side = max(24, project.trackerSize * scale)
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.key, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    Image(systemName: "plus").foregroundStyle(Theme.key)
                }
                .frame(width: side, height: side)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("trackerSpace"))
                        .onChanged { v in
                            project.trackerPoint = CGPoint(
                                x: min(max(v.location.x / scale, 0), project.canvas.width),
                                y: min(max(v.location.y / scale, 0), project.canvas.height))
                        }
                )
                .position(x: p.x * scale, y: p.y * scale)
                .accessibilityLabel("Point tracker")
            }
        }
        .coordinateSpace(name: "trackerSpace")
    }
}

struct CompareDivider: View {
    @Binding var split: CGFloat
    var body: some View {
        GeometryReader { g in
            ZStack {
                Circle().fill(.ultraThinMaterial)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.caption.bold()))
                    .frame(width: 34, height: 34)
                    .position(x: g.size.width * split, y: g.size.height / 2)
                HStack {
                    Text("No effects"); Spacer(); Text("With effects")
                }
                .font(.caption2.weight(.semibold))
                .padding(8)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged {
                split = min(max($0.location.x / g.size.width, 0.02), 0.98)
            })
        }
    }
}

struct MetalPreview: UIViewRepresentable {
    let project: ProjectModel
    let splitX: Float

    func makeCoordinator() -> PreviewRenderer { PreviewRenderer(project: project) }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        context.coordinator.configure(v)
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {
        // Reading these registers an Observation dependency: SwiftUI calls us again when they change.
        _ = project.time; _ = project.layers; _ = project.fx; _ = project.canvas; _ = project.lighting
        context.coordinator.splitX = splitX
        v.isPaused = !project.isPlaying          // free-run only while playing
        v.setNeedsDisplay()                      // scrubbing and edits redraw on demand
    }
}

final class PreviewRenderer: NSObject, MTKViewDelegate {
    private let project: ProjectModel
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let compositor: LayerCompositor
    private var present: PresentPass?
    private let inflight = DispatchSemaphore(value: 3)
    var splitX: Float = 0

    init(project: ProjectModel) {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(),
              let c = LayerCompositor(device: d) else {
            fatalError("Metal is unavailable or the shader library is missing")
        }
        self.project = project
        device = d; queue = q; compositor = c
        super.init()
    }

    func configure(_ view: MTKView) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.delegate = self
        if let lib = device.makeDefaultLibrary() {
            present = PresentPass(device: device, library: lib, pixelFormat: view.colorPixelFormat)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let present,
              let cb = queue.makeCommandBuffer() else { return }
        inflight.wait()
        cb.addCompletedHandler { [inflight] _ in inflight.signal() }

        // Redraw when a background frame fetch finishes.
        for source in project.videos.values where source.onFrame == nil {
            source.onFrame = { [weak view] in view?.setNeedsDisplay() }
        }

        let snap = RenderSnapshot.make(layers: project.layers, videos: project.videos, models: project.models,
                                       time: project.time, canvas: project.canvas, fx: project.fx,
                                       lighting: project.lighting, engine: project.exprEngine)
        if let frame = compositor.render(snap, commandBuffer: cb) {
            present.encode(cb, pass: rpd, processed: frame.processed, original: frame.original,
                           splitX: splitX, viewportWidth: Float(view.drawableSize.width))
        }
        cb.present(drawable)
        cb.commit()
    }
}

// MARK: - Easing sheet

struct EasingSheet: View {
    @Bindable var project: ProjectModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Easing curve").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            BezierGraphEditor(curve: $project.easing)
            Text("New keyframes use this curve. Park the playhead on a keyframe and drag the handles to change that key's curve.")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
        }
        .padding(20)
        .onChange(of: project.easing) { _, _ in project.applyEasingToKeys() }
        .presentationDetents([.height(640), .large])
        .presentationBackground(.ultraThinMaterial)
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}
