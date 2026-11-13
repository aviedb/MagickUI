import SwiftUI
import AppKit

// MARK: - Rotate & flip

/// Laid out like Crop: a preview of the selected image, and the controls next to it (or below it, in a narrow
/// window). The buttons change the preview straight away. Nothing is written until the Apply button at the
/// bottom of the window is pressed. Then the same changes are made to every image in the list, and the results
/// wait there to be copied or saved, like every other action.
struct RotatePanel: View {
    @EnvironmentObject private var workspace: Workspace

    /// The finished picture of the selected image, while its result waits to be copied or saved.
    private var resultURL: URL? {
        guard let item = workspace.selectedItem, item.kind == .image,
              workspace.isStaged(item.id),
              case .done(let output, _, _, _) = item.status else { return nil }
        return output
    }

    var body: some View {
        if let item = workspace.selectedItem, item.kind == .image {
            GeometryReader { geometry in
                if geometry.size.width >= 740 {
                    // Wide: preview on the left, controls on the right.
                    HStack(spacing: 0) {
                        editor(for: item)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        ScrollView {
                            controls(for: item)
                        }
                        .frame(width: 270)
                    }
                } else {
                    // Narrow: preview on top, controls below, and the whole thing scrolls.
                    ScrollView {
                        VStack(spacing: 0) {
                            editor(for: item)
                                .frame(height: max(240, min(geometry.size.height * 0.7, 480)))
                            Divider()
                            controls(for: item)
                        }
                    }
                }
            }
        } else {
            Text("Select an image in the list to rotate or flip it.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Preview

    private func editor(for item: ImageItem) -> some View {
        let result = resultURL
        // A finished result is shown as it is. Its changes are already in the file, so none are added on top.
        return RotatePreview(url: result ?? item.url,
                             settings: result == nil ? workspace.rotate : RotateSettings())
            .id("\(result == nil ? "original" : "result")-\(item.id.uuidString)")
    }

    // MARK: Controls

    private func controls(for item: ImageItem) -> some View {
        let locked = workspace.isRunning || workspace.hasPendingResults

        return VStack(alignment: .leading, spacing: 16) {
            Text(item.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            VStack(alignment: .leading, spacing: 8) {
                Text("Rotate").font(.subheadline.weight(.semibold))
                operationButton(.rotateLeft)
                operationButton(.rotateRight)
            }
            .disabled(locked)

            VStack(alignment: .leading, spacing: 8) {
                Text("Flip").font(.subheadline.weight(.semibold))
                operationButton(.flipHorizontal)
                operationButton(.flipVertical)
            }
            .disabled(locked)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Result").font(.subheadline.weight(.semibold))
                if resultURL != nil {
                    Label("Applied. Copy or save the result below, or Discard it to start over.",
                          systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                } else {
                    Text(workspace.rotate.summary)
                        .font(.callout)
                        .foregroundStyle(workspace.rotate.isUnchanged ? .secondary : .primary)
                }
            }

            Button("Reset") { change { $0.reset() } }
                .disabled(locked || workspace.rotate.isUnchanged)

            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private func operationButton(_ operation: RotateOperation) -> some View {
        ChipButton(label: operation.rawValue, symbol: operation.symbol, selected: false) {
            change { $0.apply(operation) }
        }
    }

    private var note: String {
        if workspace.imageCount > 1 {
            return "Apply changes all \(workspace.imageCount) images the same way. The preview shows the selected one. HEIC files are saved as JPG."
        }
        return "Nothing changes until you press Apply. HEIC files are saved as JPG."
    }

    private func change(_ edit: (inout RotateSettings) -> Void) {
        withAnimation(.smooth(duration: 0.3)) {
            edit(&workspace.rotate)
        }
    }
}

// MARK: - The preview picture

/// The picture on a checkerboard (so see-through parts show) with a border, turned and mirrored by `settings`.
private struct RotatePreview: View {
    let url: URL
    let settings: RotateSettings

    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    picture(image, in: geometry.size)
                } else if failed {
                    Text("A preview isn't available for this file, but Apply will still work.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    ProgressView()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .padding(16)
        // Reloads when the file moves (for example after Save). The old picture stays until the new one is ready.
        .task(id: url) {
            let box = await Task.detached(priority: .userInitiated) {
                SendableBox(value: ImagePreview.cgImage(url: url, maxPixel: 1600))
            }.value
            if let loaded = box.value {
                image = loaded
                failed = false
            } else if image == nil {
                failed = true
            }
        }
    }

    private func picture(_ image: CGImage, in size: CGSize) -> some View {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        // A quarter turn swaps the picture's width and height on screen.
        let sideways = abs(settings.angle / 90) % 2 == 1
        let boxWidth = sideways ? height : width
        let boxHeight = sideways ? width : height

        // Small pictures are not enlarged.
        let scale = min(max(size.width, 1) / boxWidth, max(size.height, 1) / boxHeight, 1)

        return ZStack {
            TransparencyGrid()
                .frame(width: boxWidth * scale, height: boxHeight * scale)
                .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1))

            // Turned first, then mirrored left to right, which is the order the final result is made in.
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: width * scale, height: height * scale)
                .rotationEffect(.degrees(Double(settings.angle)))
                .scaleEffect(x: settings.mirrored ? -1 : 1, y: 1)
        }
    }
}
