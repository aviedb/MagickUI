import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Clipboard

/// Puts finished results on the clipboard.
enum ResultClipboard {
    /// Copies the files. A single image is also put on as picture data, so it pastes straight into chats,
    /// documents and design tools, and as a file when pasted into Finder. Anything else (several files,
    /// videos) is copied as files.
    @MainActor
    @discardableResult
    static func copy(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if urls.count == 1, let url = urls.first, let item = imageItem(for: url) {
            return pasteboard.writeObjects([item])
        }
        return pasteboard.writeObjects(urls as [NSURL])
    }

    /// One pasteboard item that carries both the file and the picture, so an app can take whichever it prefers.
    private static func imageItem(for url: URL) -> NSPasteboardItem? {
        guard let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image),
              let data = try? Data(contentsOf: url) else { return nil }

        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        // Many apps only read PNG or TIFF, so formats like JPG, WebP and HEIC get a TIFF copy as well.
        // LZW keeps it much smaller than a raw TIFF, because the clipboard holds this until it is replaced.
        if type != .png && type != .tiff,
           let tiff = NSImage(data: data)?.tiffRepresentation(using: .lzw, factor: 1) {
            item.setData(tiff, forType: .tiff)
        }
        return item
    }
}

// MARK: - Snackbar

/// A short message such as "Copied to clipboard" or "Saved to Downloads".
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var symbol = "checkmark.circle.fill"
}

struct ToastView: View {
    let toast: Toast

    private var iconColor: Color {
        toast.symbol.contains("exclamationmark") ? .orange : .green
    }

    var body: some View {
        Label {
            Text(toast.message)
        } icon: {
            Image(systemName: toast.symbol).foregroundStyle(iconColor)
        }
        .font(.system(size: 13, weight: .medium))
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10)))
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
        .padding(.horizontal, 20)
    }
}
