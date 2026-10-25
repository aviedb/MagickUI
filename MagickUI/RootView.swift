import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var workspace: Workspace
    @State private var isTargeted = false
    @State private var showImporter = false

    var body: some View {
        ZStack(alignment: .top) {
            if workspace.items.isEmpty {
                DropZoneView(isTargeted: isTargeted) { showImporter = true }
            } else {
                WorkspaceView { showImporter = true }
            }

            if app.runner == nil {
                MagickMissingBanner()
                    .padding(16)
            }
        }
        .frame(minWidth: 1000, minHeight: 660)
        .overlay {
            if isTargeted && !workspace.items.isEmpty {
                ZStack {
                    Color.accentColor.opacity(0.12)
                    Label("Drop to add more images", systemImage: "plus.circle.fill")
                        .font(.title2)
                        .padding(20)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            workspace.add(urls)
            return !urls.isEmpty
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.image, .folder],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { workspace.add(urls) }
        }
    }
}

// MARK: - Empty state: the big drop zone

private struct DropZoneView: View {
    let isTargeted: Bool
    let choose: () -> Void
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            Text("Drop images here")
                .font(.largeTitle.weight(.semibold))
            Text("JPG, PNG, HEIC, WebP, TIFF and BMP. You can also drop a folder.")
                .foregroundStyle(.secondary)
            Button("Choose images…", action: choose)
                .controlSize(.large)
                .padding(.top, 6)
            if let notice = workspace.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.45),
                              style: StrokeStyle(lineWidth: 3, dash: [12, 8]))
                .padding(28)
        )
    }
}

// MARK: - Workspace: sidebar + main panel + run bar

private struct WorkspaceView: View {
    let addMore: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(addMore: addMore)
                .frame(width: 300)
            Divider()
            VStack(spacing: 0) {
                MainPanel()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                RunBar()
            }
        }
    }
}

private struct SidebarView: View {
    let addMore: () -> Void
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(workspace.items.count == 1 ? "1 image" : "\(workspace.items.count) images")
                    .font(.headline)
                Spacer()
                Button("Add…", action: addMore)
                    .disabled(workspace.isRunning)
                Button("Clear") { workspace.clearAll() }
                    .disabled(workspace.isRunning)
            }
            .padding(12)

            if let notice = workspace.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(workspace.items) { item in
                        ImageRow(item: item,
                                 selected: item.id == workspace.selectedID,
                                 locked: workspace.isRunning)
                    }
                }
                .padding(8)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ImageRow: View {
    let item: ImageItem
    let selected: Bool
    let locked: Bool
    @EnvironmentObject private var workspace: Workspace

    private var subtitle: String {
        var parts: [String] = []
        if let size = item.pixelSize {
            parts.append("\(Int(size.width))×\(Int(size.height))")
        }
        parts.append(formatBytes(item.byteSize))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                statusView
            }
            Spacer(minLength: 0)
            Button {
                workspace.remove(item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .disabled(locked)
            .help("Remove from the list")
        }
        .padding(8)
        .background(selected ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { workspace.select(item.id) }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = item.thumbnail {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 48, height: 48)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch item.status {
        case .idle:
            EmptyView()
        case .running(let message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        case .done(let output, let inBytes, let outBytes, let note):
            VStack(alignment: .leading, spacing: 2) {
                let detail = note.isEmpty ? "" : " · \(note)"
                Text("✓ \(formatBytes(inBytes)) → \(formatBytes(outBytes))\(detail)")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(2)
                Button("Reveal in Finder") { workspace.reveal(output) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        case .skipped(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(3)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(4)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Banner when magick can't be found

private struct MagickMissingBanner: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(app.problem ?? "Looking for ImageMagick…", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            Text("Install it with Homebrew, or point the app at your copy:")
                .foregroundStyle(.secondary)
            Text("brew install imagemagick")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            HStack {
                Button("Choose magick…") { app.chooseExecutable() }
                Button("Check again") { Task { await app.refresh() } }
            }
        }
        .padding(16)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.regularMaterial)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.6)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
