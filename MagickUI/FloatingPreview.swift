import SwiftUI
import AppKit
import Combine

// MARK: - What a card can say

nonisolated enum PreviewOutcome {
    /// The file was written. `detail` is a short note such as "JPEG quality capped at 85".
    case saved(inBytes: Int64, outBytes: Int64, detail: String, reveal: URL?)
    /// Nothing was changed (already optimal, nothing to do).
    case unchanged(String)
    case failed(String)
}

struct PreviewItem: Identifiable {
    enum State {
        case working
        case saved(title: String, detail: String?)
        case neutral(String)
        case failed(String)
    }

    let id: UUID
    var name: String
    var thumbnail: NSImage?
    var state: State
    var reveal: URL?
}

// MARK: - The floating preview

/// A small stack of cards in the bottom-right corner of the screen. A card appears with
/// "Optimizing…" the moment a file starts, then turns into the result and fades away.
/// The panel never takes focus, so it doesn't interrupt what you're doing.
@MainActor
final class FloatingPreview: ObservableObject {
    static let shared = FloatingPreview()

    enum Metrics {
        static let cardWidth: CGFloat = 340
        static let cardHeight: CGFloat = 76
        static let spacing: CGFloat = 8
        static let margin: CGFloat = 14      // room around the cards for their shadow
        static let maxVisible = 4
    }

    @Published private(set) var items: [PreviewItem] = []
    /// Turned off in Settings.
    var isEnabled = true

    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var dismissTokens: [UUID: Int] = [:]

    private init() {
        $items
            .sink { [weak self] _ in
                Task { @MainActor in self?.layoutPanel() }
            }
            .store(in: &cancellables)
    }

    // MARK: Showing and updating cards

    /// Shows an "Optimizing…" card. Returns an id to finish it with.
    @discardableResult
    func begin(url: URL?, name: String, force: Bool = false) -> UUID {
        let id = UUID()
        guard isEnabled || force else { return id }

        items.append(PreviewItem(id: id, name: name, thumbnail: nil, state: .working, reveal: nil))
        if items.count > Metrics.maxVisible {
            items.removeFirst(items.count - Metrics.maxVisible)
        }
        if let url { loadThumbnail(for: id, url: url) }
        return id
    }

    func finish(_ id: UUID, _ outcome: PreviewOutcome) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let seconds: TimeInterval

        switch outcome {
        case .saved(let inBytes, let outBytes, let detail, let reveal):
            let saved = inBytes - outBytes
            let title: String
            if saved > 0 {
                let percent = inBytes > 0 ? Int((Double(saved) / Double(inBytes) * 100).rounded()) : 0
                title = "Saved \(formatBytes(saved)) (−\(percent)%)"
            } else {
                title = "Done"
            }
            let sizes = "\(formatBytes(inBytes)) → \(formatBytes(outBytes))"
            items[index].state = .saved(title: title, detail: detail.isEmpty ? sizes : "\(sizes) · \(detail)")
            items[index].reveal = reveal
            seconds = 6

        case .unchanged(let message):
            items[index].state = .neutral(message)
            seconds = 4

        case .failed(let message):
            items[index].state = .failed(message)
            seconds = 8
        }
        scheduleDismiss(id, after: seconds)
    }

    func dismiss(_ id: UUID) {
        dismissTokens[id] = nil
        items.removeAll { $0.id == id }
    }

    func reveal(_ item: PreviewItem) {
        if let url = item.reveal {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        dismiss(item.id)
    }

    /// "Try it" button in Settings.
    func demo() {
        let id = begin(url: nil, name: "Example photo.jpg", force: true)
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            finish(id, .saved(inBytes: 2_400_000, outBytes: 780_000, detail: "JPEG quality capped at 85", reveal: nil))
        }
    }

    // MARK: Helpers

    private func scheduleDismiss(_ id: UUID, after seconds: TimeInterval) {
        let token = (dismissTokens[id] ?? 0) + 1
        dismissTokens[id] = token
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard dismissTokens[id] == token else { return }
            dismiss(id)
        }
    }

    private func loadThumbnail(for id: UUID, url: URL) {
        Task {
            let box = await Task.detached(priority: .utility) {
                SendableBox(value: ImagePreview.cgImage(url: url, maxPixel: 160))
            }.value
            guard let image = box.value, let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }

    // MARK: The panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false                 // the cards draw their own shadow
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: FloatingPreviewView(center: self))
        return panel
    }

    /// Sizes the panel to exactly fit the cards and pins it to the bottom-right of the screen the
    /// mouse is on, above the Dock. Because it fits the cards, it never blocks clicks elsewhere.
    private func layoutPanel() {
        guard !items.isEmpty else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let count = CGFloat(items.count)
        let width = Metrics.cardWidth + Metrics.margin * 2
        let height = count * Metrics.cardHeight + (count - 1) * Metrics.spacing + Metrics.margin * 2

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }

        let frame = NSRect(x: visible.maxX - width, y: visible.minY, width: width, height: height)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }
}

// MARK: - Views

struct FloatingPreviewView: View {
    @ObservedObject var center: FloatingPreview

    var body: some View {
        VStack(spacing: FloatingPreview.Metrics.spacing) {
            ForEach(center.items) { item in
                PreviewCard(item: item,
                            onClose: { center.dismiss(item.id) },
                            onOpen: { center.reveal(item) })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(FloatingPreview.Metrics.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: center.items.map { $0.id })
    }
}

private struct PreviewCard: View {
    let item: PreviewItem
    let onClose: () -> Void
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    statusIcon
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                }
                Text(item.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: FloatingPreview.Metrics.cardWidth,
               height: FloatingPreview.Metrics.cardHeight,
               alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.10)))
        .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .background(Circle().fill(.regularMaterial))
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Dismiss")
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
    }

    // MARK: Pieces

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let image = item.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(Color.secondary.opacity(0.18))
                    Image(systemName: "photo")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.state {
        case .working:
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
        case .saved:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 13))
        case .neutral:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary).font(.system(size: 13))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 13))
        }
    }

    private var title: String {
        switch item.state {
        case .working: return "Optimizing…"
        case .saved(let title, _): return title
        case .neutral(let message): return message
        case .failed: return "Couldn't process this image"
        }
    }

    private var titleColor: Color {
        switch item.state {
        case .failed: return .orange
        default: return .primary
        }
    }

    private var detail: String? {
        switch item.state {
        case .saved(_, let detail): return detail
        case .failed(let message): return message
        default: return nil
        }
    }
}
