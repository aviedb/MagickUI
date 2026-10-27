import SwiftUI
import AppKit
import Combine

// MARK: - magick location

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

// MARK: - Shared objects and windows

/// One place that owns everything the main window, the menu bar, the folder watcher and the
/// Finder services share.
@MainActor
final class AppContext {
    static let shared = AppContext()

    let appState = AppState()
    let settings = AppSettings()
    let ruleStore = RuleStore()
    lazy var workspace = Workspace(app: appState)
    lazy var watcher = WatchManager(app: appState, store: ruleStore, settings: settings)

    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Re-evaluate the Dock icon whenever the setting changes, or the menu bar icon is toggled
        // (that toggle lives in UserDefaults too).
        settings.$dockMode
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateActivationPolicy() }
            }
            .store(in: &cancellables)

        settings.$showFloatingPreview
            .sink { enabled in
                Task { @MainActor in FloatingPreview.shared.isEnabled = enabled }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateActivationPolicy() }
            }
            .store(in: &cancellables)
    }

    // MARK: Dock icon

    /// The app starts as a background app (LSUIElement). Depending on the Dock setting it becomes a normal
    /// app, with a Dock icon and menus, only while a window is open, always, or never.
    func updateActivationPolicy() {
        let menuBarIconShown = UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
        var mode = settings.dockMode
        // Never leave the app with no way to reach it.
        if mode == .never && !menuBarIconShown { mode = .whileOpen }

        let windows = [mainWindow, settingsWindow]
        let windowOpen = windows.contains { ($0?.isVisible ?? false) || ($0?.isMiniaturized ?? false) } || NSApp.isHidden

        let desired: NSApplication.ActivationPolicy
        switch mode {
        case .always: desired = .regular
        case .never: desired = .accessory
        case .whileOpen: desired = windowOpen ? .regular : .accessory
        }
        if NSApp.activationPolicy() != desired {
            NSApp.setActivationPolicy(desired)
        }
    }

    private func bringToFront() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: Windows

    /// Windows are free-form: no size is imposed by the SwiftUI content (`sizingOptions = []`),
    /// only a small minimum, so they can be tiled into any corner by a window manager.
    private func makeWindow<Content: View>(title: String,
                                           size: NSSize,
                                           minSize: NSSize,
                                           autosaveName: String,
                                           content: Content) -> NSWindow {
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.contentMinSize = minSize
        window.setContentSize(size)
        if !window.setFrameUsingName(autosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(autosaveName)

        // When the last window closes, the Dock icon goes away again (in "only while open" mode).
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window,
                                               queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                Task { @MainActor in self?.updateActivationPolicy() }
            }
        }
        return window
    }

    private func present(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        updateActivationPolicy()
        Task { @MainActor in
            self.bringToFront()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func showMainWindow() {
        if mainWindow == nil {
            let root = RootView()
                .environmentObject(appState)
                .environmentObject(workspace)
            mainWindow = makeWindow(title: "MagickUI",
                                    size: NSSize(width: 1100, height: 720),
                                    minSize: NSSize(width: 440, height: 360),
                                    autosaveName: "MagickUIMainWindow",
                                    content: root)
        }
        if let window = mainWindow { present(window) }
    }

    func showSettings() {
        if settingsWindow == nil {
            let root = SettingsView()
                .environmentObject(appState)
                .environmentObject(settings)
                .environmentObject(ruleStore)
                .environmentObject(watcher)
            settingsWindow = makeWindow(title: "MagickUI Settings",
                                        size: NSSize(width: 780, height: 540),
                                        minSize: NSSize(width: 620, height: 440),
                                        autosaveName: "MagickUISettingsWindow",
                                        content: root)
        }
        if let window = settingsWindow { present(window) }
    }

    /// Silent Finder actions: process right away with no window and save next to the originals.
    /// A floating card shows the progress and the result.
    func runQuick(_ urls: [URL], action: ImageAction) {
        let files = ImageFiles.collect(from: urls).files
        guard let first = files.first else { return }

        let label = files.count == 1 ? first.lastPathComponent : "\(files.count) images"
        let card = FloatingPreview.shared.begin(url: first, name: label)

        guard let runner = appState.runner else {
            FloatingPreview.shared.finish(card, .failed("ImageMagick wasn't found."))
            return
        }

        var processorSettings = ProcessorSettings()
        processorSettings.optimize = settings.quickOptimize
        let processor = ImageProcessor(runner: runner)

        Task {
            var reserved = Set<String>()
            var done = 0
            var skipped = 0
            var failed = 0
            var totalIn: Int64 = 0
            var totalOut: Int64 = 0
            var lastOutput: URL?
            var lastNote = ""
            var lastProblem = ""

            for url in files {
                do {
                    let status = try await processor.process(
                        job: ImageJob(url: url, byteSize: fileSize(url)),
                        action: action,
                        settings: processorSettings,
                        outputDirectory: nil,
                        reserved: &reserved)
                    if case .done(let output, let inBytes, let outBytes, let note) = status {
                        done += 1
                        totalIn += inBytes
                        totalOut += outBytes
                        lastOutput = output
                        lastNote = note
                    }
                } catch is ItemSkip {
                    skipped += 1
                } catch {
                    failed += 1
                    lastProblem = error.localizedDescription
                }
            }

            if done > 0 {
                var detail = files.count > 1 ? "\(done) done" : lastNote
                if skipped > 0 { detail += ", \(skipped) skipped" }
                if failed > 0 { detail += ", \(failed) failed" }
                FloatingPreview.shared.finish(card, .saved(inBytes: totalIn, outBytes: totalOut,
                                                           detail: detail, reveal: lastOutput))
            } else if failed > 0 {
                FloatingPreview.shared.finish(card, .failed(lastProblem))
            } else {
                FloatingPreview.shared.finish(card, .unchanged("Nothing to do"))
            }
        }
    }
}

// MARK: - App delegate: launch, Dock icon, Open With

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let context = AppContext.shared
        NSApp.servicesProvider = ServicesProvider.shared
        NSUpdateDynamicServices()
        context.updateActivationPolicy()
        _ = context.watcher                    // creating it starts the folder watchers
        if context.settings.showWindowAtLaunch {
            context.showMainWindow()
        }
    }

    /// Finder: right-click ▸ Open With ▸ MagickUI, or dropping files on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        let context = AppContext.shared
        context.workspace.add(urls)
        context.showMainWindow()
    }

    /// Clicking the Dock icon when no window is open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppContext.shared.showMainWindow() }
        return false
    }

    /// Closing the window must not quit the app: folder watching keeps running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - Finder right-click: Services

/// Receives the entries declared under NSServices in MagickUI-Info.plist.
/// Each method name here matches an NSMessage value there.
@MainActor
final class ServicesProvider: NSObject {
    static let shared = ServicesProvider()

    private func urls(from pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    private func openInWindow(_ pasteboard: NSPasteboard, action: ImageAction?) {
        let files = urls(from: pasteboard)
        guard !files.isEmpty else { return }
        let context = AppContext.shared
        context.workspace.add(files)
        if let action { context.workspace.choose(action) }
        context.showMainWindow()
    }

    @objc func openService(_ pasteboard: NSPasteboard, userData: String,
                           error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        openInWindow(pasteboard, action: nil)
    }

    @objc func compressService(_ pasteboard: NSPasteboard, userData: String,
                               error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        openInWindow(pasteboard, action: .compress)
    }

    @objc func convertService(_ pasteboard: NSPasteboard, userData: String,
                              error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        openInWindow(pasteboard, action: .convert)
    }

    @objc func cropService(_ pasteboard: NSPasteboard, userData: String,
                           error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        openInWindow(pasteboard, action: .crop)
    }

    @objc func resizeService(_ pasteboard: NSPasteboard, userData: String,
                             error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        openInWindow(pasteboard, action: .resize)
    }

    @objc func quickCompressService(_ pasteboard: NSPasteboard, userData: String,
                                    error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        AppContext.shared.runQuick(urls(from: pasteboard), action: .optimize)
    }

    @objc func quickCleanService(_ pasteboard: NSPasteboard, userData: String,
                                 error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        AppContext.shared.runQuick(urls(from: pasteboard), action: .metadata)
    }
}
