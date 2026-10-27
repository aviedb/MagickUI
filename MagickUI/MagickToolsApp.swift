import SwiftUI

/// The windows (main + Settings) are created by `AppContext`, so Open With, Dock drops,
/// Finder Services and the menu bar can all reuse the same window.
/// The only SwiftUI scene is the menu bar item.
@main
struct MagickToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra("MagickUI", systemImage: "photo.on.rectangle.angled", isInserted: $showMenuBarIcon) {
            MenuBarContent()
                .environmentObject(AppContext.shared.watcher)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { AppContext.shared.showSettings() }
                    .keyboardShortcut(",")
            }
        }
    }
}
