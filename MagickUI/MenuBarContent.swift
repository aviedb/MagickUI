import SwiftUI
import AppKit

/// What you see when you click the MagickUI icon in the menu bar.
struct MenuBarContent: View {
    @EnvironmentObject private var watcher: WatchManager
    @EnvironmentObject private var videoWatcher: VideoWatchManager

    private var statusText: String {
        if watcher.isPaused { return "Folder watching is paused" }
        let images = watcher.activeFolderCount
        let videos = videoWatcher.activeFolderCount
        if images == 0 && videos == 0 { return "No folders are being watched" }

        var parts: [String] = []
        if images > 0 { parts.append(images == 1 ? "1 image folder" : "\(images) image folders") }
        if videos > 0 { parts.append(videos == 1 ? "1 video folder" : "\(videos) video folders") }
        return "Watching " + parts.joined(separator: " · ")
    }

    /// The latest activity from image and video folders together, newest first.
    private var recent: [ActivityEntry] {
        let all = watcher.activity + videoWatcher.activity
        return Array(all.sorted { $0.date > $1.date }.prefix(5))
    }

    var body: some View {
        Text(statusText)

        Toggle("Pause folder watching", isOn: $watcher.isPaused)

        if videoWatcher.isProcessing {
            Button("Cancel the video being processed") { videoWatcher.cancelCurrent() }
        }

        Divider()

        if recent.isEmpty {
            Text("No recent activity")
        } else {
            ForEach(recent) { entry in
                Text("\(entry.success ? "✓" : "✗") \(entry.name): \(entry.message)")
            }
        }

        Divider()

        Button("Open MagickUI") { AppContext.shared.showMainWindow() }
        Button("Settings…") { AppContext.shared.showSettings() }
            .keyboardShortcut(",")

        Divider()

        Button("Quit MagickUI") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
