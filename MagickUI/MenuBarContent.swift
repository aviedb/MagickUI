import SwiftUI
import AppKit

/// What you see when you click the MagickUI icon in the menu bar.
struct MenuBarContent: View {
    @EnvironmentObject private var watcher: WatchManager

    private var statusText: String {
        if watcher.isPaused { return "Folder watching is paused" }
        let count = watcher.activeFolderCount
        if count == 0 { return "No folders are being watched" }
        return count == 1 ? "Watching 1 folder" : "Watching \(count) folders"
    }

    var body: some View {
        Text(statusText)

        Toggle("Pause folder watching", isOn: $watcher.isPaused)

        Divider()

        if watcher.activity.isEmpty {
            Text("No recent activity")
        } else {
            ForEach(watcher.activity.prefix(5)) { entry in
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
