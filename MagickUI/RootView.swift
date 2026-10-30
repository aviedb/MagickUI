import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var workspace: Workspace
    @State private var isTargeted = false
    @State private var showImporter = false

    /// Images, videos and folders. Some video containers (MKV, WebM…) have no system type, so they're added by extension.
    private var importerTypes: [UTType] {
        let extras = ["mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "mts", "m2ts", "ogv", "3gp"]
            .compactMap { UTType(filenameExtension: $0) }
        return [.image, .movie, .audiovisualContent, .folder] + extras
    }

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
        .overlay {
            if isTargeted && !workspace.items.isEmpty {
                ZStack {
                    Color.accentColor.opacity(0.12)
                    Label("Drop to add more files", systemImage: "plus.circle.fill")
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
                      allowedContentTypes: importerTypes,
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
            Text("Drop images or videos here")
                .font(.largeTitle.weight(.semibold))
            Text("Images: JPG, PNG, HEIC, WebP, TIFF, BMP. Videos: MP4, MOV, MKV, WebM, AVI and more. You can also drop a folder.")
                .foregroundStyle(.secondary)
            Button("Choose files…", action: choose)
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

/// Wide windows get the image list as a sidebar. Narrow windows (for example a window tiled into a
/// quarter of the screen) get a compact thumbnail strip on top instead, so nothing is cut off.
private struct WorkspaceView: View {
    let addMore: () -> Void
    private let sidebarThreshold: CGFloat = 860

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= sidebarThreshold {
                HStack(spacing: 0) {
                    SidebarView(addMore: addMore)
                        .frame(width: 300)
                    Divider()
                    mainColumn
                }
            } else {
                VStack(spacing: 0) {
                    CompactImageStrip(addMore: addMore)
                    Divider()
                    mainColumn
                }
            }
        }
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            MainPanel()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            RunBar()
        }
    }
}

private struct SidebarView: View {
    let addMore: () -> Void
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(workspace.countText)
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
        if let info = item.video { parts.append(formatDuration(info.duration)) }
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
        .opacity(item.kind == workspace.activeKind ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture { workspace.select(item.id) }
    }

    private var thumbnail: some View {
        ZStack {
            if let image = item.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Color.secondary.opacity(0.2))
                if item.kind == .video {
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottomTrailing) {
            if item.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .padding(2)
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch item.status {
        case .idle:
            EmptyView()
        case .running(let message):
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if item.progress == nil { ProgressView().controlSize(.small) }
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if let progress = item.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
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

// MARK: - Compact image strip (narrow windows)

private struct CompactImageStrip: View {
    let addMore: () -> Void
    @EnvironmentObject private var workspace: Workspace

    private var countText: String { workspace.countText }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(countText).font(.subheadline.weight(.semibold))
                if let notice = workspace.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button("Add…", action: addMore)
                    .controlSize(.small)
                    .disabled(workspace.isRunning)
                Button("Clear") { workspace.clearAll() }
                    .controlSize(.small)
                    .disabled(workspace.isRunning)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(workspace.items) { item in
                        CompactThumb(item: item,
                                     selected: item.id == workspace.selectedID,
                                     locked: workspace.isRunning)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 60)

            if let item = workspace.selectedItem {
                Text(summary(for: item))
                    .font(.caption)
                    .foregroundStyle(color(for: item))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func summary(for item: ImageItem) -> String {
        var parts = [item.name]
        if let size = item.pixelSize { parts.append("\(Int(size.width))×\(Int(size.height))") }
        if let info = item.video { parts.append(formatDuration(info.duration)) }
        parts.append(formatBytes(item.byteSize))
        switch item.status {
        case .idle: break
        case .running(let message): parts.append(message)
        case .done(_, let inBytes, let outBytes, let note):
            parts.append("✓ \(formatBytes(inBytes)) → \(formatBytes(outBytes))" + (note.isEmpty ? "" : " · \(note)"))
        case .skipped(let message): parts.append(message)
        case .failed(let message): parts.append(message)
        }
        return parts.joined(separator: " · ")
    }

    private func color(for item: ImageItem) -> Color {
        switch item.status {
        case .done: return .green
        case .skipped: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }
}

private struct CompactThumb: View {
    let item: ImageItem
    let selected: Bool
    let locked: Bool
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            thumbnail
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12),
                                      lineWidth: selected ? 2.5 : 1)
                )
            badge
        }
        .overlay(alignment: .topLeading) {
            if item.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .padding(3)
            }
        }
        .opacity(item.kind == workspace.activeKind ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture { workspace.select(item.id) }
        .contextMenu {
            Button("Remove") { workspace.remove(item.id) }
                .disabled(locked)
        }
        .help(item.name)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = item.thumbnail {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle().fill(Color.secondary.opacity(0.2))
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch item.status {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green)
        case .skipped:
            Image(systemName: "minus.circle.fill").foregroundStyle(.white, .orange)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .red)
        case .running:
            ProgressView().controlSize(.mini)
        case .idle:
            EmptyView()
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
