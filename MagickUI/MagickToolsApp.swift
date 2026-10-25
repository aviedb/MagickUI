import SwiftUI
import AppKit
import Combine

@main
struct MagickToolsApp: App {
    @StateObject private var appState: AppState
    @StateObject private var workspace: Workspace

    init() {
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        _workspace = StateObject(wrappedValue: Workspace(app: state))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(workspace)
        }
    }
}

/// Holds the located `magick` executable for the whole app.
@MainActor
final class AppState: ObservableObject {
    @Published var runner: MagickRunner?
    @Published var versionLine = ""
    @Published var problem: String?

    init() {
        Task { await refresh() }
    }

    func refresh() async {
        guard let url = MagickLocator.locate() else {
            runner = nil
            versionLine = ""
            problem = "ImageMagick (magick) wasn't found."
            return
        }
        let candidate = MagickRunner(executable: url)
        do {
            let output = try await candidate.run(["-version"])
            versionLine = output.components(separatedBy: "\n").first ?? ""
            runner = candidate
            problem = nil
        } catch {
            runner = nil
            versionLine = ""
            problem = "Found magick at \(url.path), but it didn't run: \(error.localizedDescription)"
        }
    }

    func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.message = "Select the magick executable (usually /opt/homebrew/bin/magick)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            MagickLocator.remember(url)
            Task { await refresh() }
        }
    }
}
