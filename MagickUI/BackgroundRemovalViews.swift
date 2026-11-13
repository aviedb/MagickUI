import SwiftUI
import AppKit

// MARK: - Remove background: options panel

/// Shown when "Remove background" is chosen. The model is an optional download, so this is where
/// it is offered, installed and (once ready) confirmed.
struct RemoveBackgroundPanel: View {
    @EnvironmentObject private var model: BackgroundModelStore
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        PanelContainer(title: "Remove background",
                       subtitle: "Cuts out the subject and keeps the background transparent. It runs on your Mac, so your images are never uploaded.") {
            BackgroundModelCard()

            // The finished cutout of the image selected in the list (once there is one).
            if let item = workspace.selectedItem, item.kind == .image,
               case .done(let output, _, _, _) = item.status {
                CutoutPreview(url: output)
                    .id(item.id)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Results are saved as PNG, because PNG keeps the transparent areas.",
                      systemImage: "photo")
                Label("Pasting a result into another app keeps the transparency.",
                      systemImage: "doc.on.clipboard")
                Label("Images are processed one at a time.",
                      systemImage: "list.number")
            }
            .foregroundStyle(.secondary)

            Text("Built with DINOv3. Uses the withoutBG Open Weights model.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            model.refresh()
            if model.isInstalled { BackgroundRemovalEngine.shared.preload() }
        }
    }
}

// MARK: - Preview of the result

/// Shows a finished cutout on a checkerboard, so the transparent areas are easy to see.
/// It follows the image that is selected in the list.
private struct CutoutPreview: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview").font(.headline)
            ZStack {
                TransparencyGrid()
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))

            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        // Reloads when the file moves (for example after Save). The old picture stays until the new one is ready.
        .task(id: url) {
            let box = await Task.detached(priority: .userInitiated) {
                SendableBox(value: ImagePreview.cgImage(url: url, maxPixel: 1600))
            }.value
            if let loaded = box.value { image = loaded }
        }
    }
}

// MARK: - The download card

/// Offers the model download, shows its progress, and confirms when it is ready.
struct BackgroundModelCard: View {
    @EnvironmentObject private var model: BackgroundModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let step = model.step {
                installing(step)
            } else if model.isInstalled {
                ready
            } else {
                needsDownload
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var needsDownload: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("One-time download needed", systemImage: "arrow.down.circle")
                .font(.headline)
            Text("MagickUI stays small and fast until you need this tool. Download the model once (\(formatBytes(ModelManifest.builtIn.sizeBytes))) and it installs itself. After that, Remove background works offline.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = model.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Button {
                model.install()
            } label: {
                Label(model.errorMessage == nil ? "Download model" : "Try again",
                      systemImage: "arrow.down.to.line")
                    .frame(minWidth: 160)
            }
            .buttonStyle(AppButtonStyle(.prominent))
            .controlSize(.large)
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model ready").font(.headline)
                    Text(readySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let message = model.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private var readySubtitle: String {
        if let record = model.record, record.diskBytes > 0 {
            return "Installed on this Mac · \(formatBytes(record.diskBytes))"
        }
        return "Installed on this Mac"
    }

    private func installing(_ step: InstallStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(step.phase.title).font(.headline)
            if let fraction = step.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            if step.phase == .checking || step.phase == .downloading {
                Button("Cancel") { model.cancelInstall() }
            }
            Text("Keep MagickUI open until this finishes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Settings ▸ Models

struct BackgroundModelSettingsTab: View {
    @EnvironmentObject private var model: BackgroundModelStore
    @State private var confirmRemove = false

    private var statusText: String {
        if let step = model.step { return step.phase.title }
        return model.isInstalled ? "Installed" : "Not installed"
    }

    private var statusColor: Color {
        if model.step != nil { return .secondary }
        return model.isInstalled ? .green : .secondary
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Model") {
                    Text("withoutBG Open Weights")
                }
                LabeledContent("Status") {
                    Text(statusText).foregroundStyle(statusColor)
                }
                if model.isInstalled, let record = model.record {
                    LabeledContent("Version") { Text(record.version) }
                    if record.diskBytes > 0 {
                        LabeledContent("Disk space") { Text(formatBytes(record.diskBytes)) }
                    }
                }
                if model.isInstalled || model.cacheBytes > 0 {
                    LabeledContent("Cache") {
                        HStack(spacing: 10) {
                            Text(model.cacheBytes > 0 ? formatBytes(model.cacheBytes) : "Empty")
                                .foregroundStyle(.secondary)
                            Button("Clear cache") { model.clearCache() }
                                .disabled(model.cacheBytes == 0 || model.isBusy)
                        }
                    }
                }

                if let step = model.step {
                    if let fraction = step.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    if step.phase == .checking || step.phase == .downloading {
                        Button("Cancel") { model.cancelInstall() }
                    }
                } else {
                    actions
                }

                if let message = model.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Remove background")
            } footer: {
                Text("This tool is an optional download (\(formatBytes(ModelManifest.builtIn.sizeBytes))), so MagickUI stays small until you need it. It is the only thing MagickUI ever downloads. After that, background removal works offline. It is stored in ~/Library/Application Support/MagickUI/Models. Using it also builds up a cache, because macOS keeps prepared copies of the model. Clearing the cache is safe: the model stays installed, and the next background removal is just slower while your Mac prepares the model again.")
            }

            Section {
                HStack(spacing: 14) {
                    Link("withoutBG Open Weights license",
                         destination: URL(string: "https://withoutbg.com/open-weights-model/license")!)
                    Link("DINOv3 license",
                         destination: URL(string: "https://ai.meta.com/resources/models-and-libraries/dinov3-license/")!)
                }
                if model.isInstalled {
                    Button("Open the license notices that came with the model") { model.openLicenses() }
                }
            } header: {
                Text("About the model")
            } footer: {
                Text("Built with DINOv3. The model was developed by withoutBG using components from Meta DINOv3, Depth Anything V2 and IS-Net. The full notices are included in the download.")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
        .confirmationDialog("Remove the Remove background model?",
                            isPresented: $confirmRemove,
                            titleVisibility: .visible) {
            Button("Remove model", role: .destructive) { model.remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This frees its disk space. You can download it again whenever you need it.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        if model.isInstalled {
            HStack(spacing: 10) {
                Button("Show in Finder") { model.revealInFinder() }
                Button("Download again") { model.install() }
                Button("Remove…", role: .destructive) { confirmRemove = true }
            }
        } else {
            Button {
                model.install()
            } label: {
                Label("Download model", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(AppButtonStyle(.prominent))
        }
    }
}
