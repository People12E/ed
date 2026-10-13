// ExportSheet.swift — export settings summary, progress, cancel, share.

import SwiftUI

struct ExportSheet: View {
    let project: ProjectModel
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case idle
        case running(Double)
        case done(URL)
        case failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var exporter: Exporter?

    private var size: CGSize {
        CGSize(width: Double(Int(project.canvas.width) & ~1), height: Double(Int(project.canvas.height) & ~1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Export video").font(.headline)
                Spacer()
                Button("Close") { cancelIfRunning(); dismiss() }
            }

            VStack(alignment: .leading, spacing: 6) {
                row("Format", "MP4 (H.264)")
                row("Size", "\(Int(size.width)) × \(Int(size.height))")
                row("Frame rate", "\(Int(project.fps)) fps")
                row("Length", String(format: "%.1f s", project.duration))
                row("Audio", hasAudio ? "First clip's audio" : "None")
            }
            .font(.subheadline)

            switch phase {
            case .idle:
                Button(action: start) {
                    Text("Start export").font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(Theme.accent, in: Capsule())
                        .foregroundStyle(Color.black.opacity(0.85))
                }
                .buttonStyle(PressableStyle())
                Text("Keep the app open until the export finishes.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)

            case .running(let p):
                ProgressView(value: p).tint(Theme.accent)
                Text("Rendering \(Int(p * 100))%").font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                Button("Cancel", role: .destructive) { cancelIfRunning() }

            case .done(let url):
                Label("Export finished", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                ShareLink(item: url) {
                    Label("Share or save", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(Theme.accent, in: Capsule())
                        .foregroundStyle(Color.black.opacity(0.85))
                }

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                Button("Try again") { phase = .idle }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .presentationDetents([.height(420)])
        .presentationBackground(.ultraThinMaterial)
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isRunning)
    }

    private var isRunning: Bool { if case .running = phase { return true } else { return false } }

    private var hasAudio: Bool {
        guard let layer = project.layers.first(where: { $0.kind == .video && $0.visible }),
              layer.start < 0.001, let source = project.videos[layer.id] else { return false }
        return source.audioTrack != nil
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    private func cancelIfRunning() { exporter?.cancel() }

    @MainActor
    private func start() {
        let job = ExportJob(layers: project.layers, videos: project.videos, models: project.models,
                            lighting: project.lighting, canvas: project.canvas,
                            duration: project.duration, fps: project.fps, fx: project.fx)
        let e = Exporter()
        exporter = e
        phase = .running(0)
        Task {
            do {
                let url = try await e.run(job: job) { p in
                    Task { @MainActor in
                        if case .running = phase { phase = .running(p) }
                    }
                }
                phase = .done(url)
            } catch ExportError.cancelled {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
