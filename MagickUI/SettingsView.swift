import SwiftUI
import AppKit
import ServiceManagement

private let numberFormat = FloatingPointFormatStyle<Double>.number.grouping(.never)

struct SettingsView: View {
    var body: some View {
        TabView {
            WatchedFoldersTab()
                .tabItem { Label("Watched Folders", systemImage: "folder") }
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(minWidth: 600, minHeight: 420)
    }
}

// MARK: - Watched folders

private struct WatchedFoldersTab: View {
    @EnvironmentObject private var store: RuleStore
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 250)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            if store.rules.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text("No folders yet")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach($store.rules) { $rule in
                        FolderRow(rule: $rule)
                            .tag(rule.id)
                            .contextMenu {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([rule.folderURL])
                                }
                                Button("Remove", role: .destructive) { remove(rule.id) }
                            }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()

            // Two identical buttons, like a native source-list footer.
            HStack(spacing: 0) {
                SidebarButton(symbol: "plus", help: "Add a folder to watch") { addFolder() }
                SidebarButton(symbol: "minus", help: "Remove the selected folder") {
                    if let id = selection { remove(id) }
                }
                .disabled(selection == nil)
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(height: 32)
            .background(.bar)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let index = store.rules.firstIndex(where: { $0.id == selection }) {
            RuleDetail(rule: $store.rules[index])
        } else {
            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 44))
                    .foregroundStyle(.tertiary)
                Text(store.rules.isEmpty ? "Optimize images automatically" : "Select a folder")
                    .font(.title3.weight(.semibold))
                Text("New images that land in a watched folder are optimized in the background, with no window needed.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                Button {
                    addFolder()
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
            }
            .padding(32)
        }
    }

    // MARK: Actions

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Watch"
        panel.message = "Choose a folder to watch for new images"
        if panel.runModal() == .OK, let url = panel.url {
            selection = store.addFolder(url)
        }
    }

    private func remove(_ id: UUID) {
        store.rules.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }
}

private struct SidebarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.45))
        .help(help)
    }
}

private struct FolderRow: View {
    @Binding var rule: WatchRule

    private var subtitle: String {
        if rule.task == .optimize { return "Smart optimize · \(rule.optimize.level.rawValue)" }
        return rule.task.shortTitle
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(rule.enabled ? Color.accentColor : Color.gray.opacity(0.55),
                            in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.folderName)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: $rule.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - One folder's settings

private struct RuleDetail: View {
    @Binding var rule: WatchRule
    @EnvironmentObject private var watcher: WatchManager

    private let convertFormats = ["jpg", "png", "webp", "heic", "avif", "tiff"]

    private var shrinksFiles: Bool {
        rule.task == .optimize || rule.task == .compress || rule.task == .metadata
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section {
                    Picker("Action", selection: $rule.task) {
                        ForEach(WatchTask.allCases) { Text($0.title).tag($0) }
                    }
                    taskOptions
                } header: {
                    Text("When a new image appears")
                }

                Section {
                    Picker("Original file", selection: $rule.originalHandling) {
                        ForEach(OriginalHandling.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if rule.originalHandling == .overwrite {
                        Text("Overwriting can't be undone. If the format changes (for example HEIC to JPG), the original still goes to the Trash.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if shrinksFiles {
                        Toggle("Only replace the file if the result is smaller", isOn: $rule.onlyIfSmaller)
                    }
                } header: {
                    Text("Result")
                }

                Section {
                    Button("Process existing images now") { watcher.processExisting(in: rule) }
                } footer: {
                    Text("Images already in the folder are ignored unless you click this.")
                }
            }
            .formStyle(.grouped)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: rule.path))
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.folderName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(rule.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Toggle("Watching", isOn: $rule.enabled)
                .toggleStyle(.switch)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([rule.folderURL])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Show in Finder")
        }
        .padding(16)
    }

    // MARK: Options per action

    private var customStrength: Binding<Double> {
        Binding(get: { Double(rule.optimize.customFactor) },
                set: { rule.optimize.customFactor = Int($0) })
    }

    private var optimizeSummary: String {
        let factor = rule.optimize.factor
        return "JPEG quality is capped at \(OptimizeCurves.jpegMaxQuality(factor)) (files already below it are only optimized losslessly). "
            + "PNG colors are reduced with quality 0–\(OptimizeCurves.pngQualityMax(factor)). Dimensions never change."
    }

    @ViewBuilder
    private var taskOptions: some View {
        switch rule.task {
        case .optimize:
            Picker("Strength", selection: $rule.optimize.level) {
                ForEach(OptimizeLevel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if rule.optimize.level == .custom {
                LabeledContent("Custom strength") {
                    HStack(spacing: 8) {
                        Slider(value: customStrength, in: 5...100, step: 1)
                            .frame(width: 150)
                        Text("\(rule.optimize.factor)")
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                }
            }

            Text(optimizeSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Remove metadata (keeps the photo upright and its color profile)", isOn: $rule.optimize.stripMetadata)
            Toggle("Convert HEIC, TIFF and BMP to JPG", isOn: $rule.optimize.convertIncompatible)

            if ExternalTool.jpegoptim == nil || ExternalTool.pngquant == nil {
                Label("Install the optimizers once in Terminal:  brew install jpegoptim pngquant",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

        case .compress:
            LabeledContent("Make each image under") {
                HStack(spacing: 8) {
                    TextField("", value: $rule.compress.amount, format: numberFormat)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Picker("", selection: $rule.compress.unit) {
                        ForEach(SizeUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 90)
                }
            }
            Picker("Save as", selection: $rule.compress.format) {
                ForEach(CompressFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Remove metadata", isOn: $rule.compress.stripMetadata)
            Text("To hit an exact size this mode may reduce the dimensions. For gentle everyday shrinking, use Smart optimize.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .convert:
            Picker("Convert to", selection: $rule.convert.target) {
                ForEach(convertFormats, id: \.self) { Text($0.uppercased()).tag($0) }
            }
            if ImageFiles.lossyOutputs.contains(rule.convert.target) {
                LabeledContent("Quality") {
                    HStack(spacing: 8) {
                        Slider(value: $rule.convert.quality, in: 30...100, step: 1)
                            .frame(width: 150)
                        Text("\(Int(rule.convert.quality))")
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                }
            }

        case .resize:
            LabeledContent("Max width (px)") {
                TextField("", value: $rule.resize.width, format: numberFormat)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
            LabeledContent("Max height (px)") {
                TextField("", value: $rule.resize.height, format: numberFormat)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
            Text("Larger images are scaled down, keeping their proportions. Smaller images are left alone. Leave one side at 0 to limit only the other.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .metadata:
            Text("Strips EXIF, GPS and camera data. The photo is rotated upright first, and the color profile is removed too.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var watcher: WatchManager
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginMessage: String?

    private var dockCaption: String {
        switch settings.dockMode {
        case .whileOpen: return "MagickUI lives in the menu bar and shows a Dock icon only while one of its windows is open."
        case .always: return "The Dock icon is always visible."
        case .never: return "No Dock icon at all. Use the menu bar icon to open MagickUI. (If the menu bar icon is hidden too, the Dock icon appears while a window is open.)"
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Dock icon", selection: $settings.dockMode) {
                    ForEach(DockMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Show the icon in the menu bar", isOn: $showMenuBarIcon)
            } header: {
                Text("Dock & menu bar")
            } footer: {
                Text(dockCaption)
            }

            Section {
                Toggle("Launch MagickUI at login", isOn: loginBinding)
                if let loginMessage {
                    Text(loginMessage).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Open the main window when the app starts", isOn: $settings.showWindowAtLaunch)
            } header: {
                Text("Startup")
            } footer: {
                Text("Turning on “Launch at login” also turns off the main window at startup, so MagickUI starts quietly in the background.")
            }

            Section {
                Toggle("Show a floating preview while images are optimized", isOn: $settings.showFloatingPreview)
                Button("Try it") { FloatingPreview.shared.demo() }
            } header: {
                Text("Floating preview")
            } footer: {
                Text("A small card appears in the bottom-right corner of your screen. It says “Optimizing…” while a watched folder or a Finder quick action is working, then shows how much space was saved. Click it to reveal the file.")
            }

            Section {
                Picker("Strength", selection: $settings.quickLevel) {
                    Text("Balanced").tag(OptimizeLevel.balanced)
                    Text("Aggressive").tag(OptimizeLevel.aggressive)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Finder: Quick compress")
            } footer: {
                Text("Used by Services ▸ “Quick compress (MagickUI)” in Finder's right-click menu. It runs Smart optimize and saves the result next to the original.")
            }

            Section {
                toolRow("jpegoptim", found: ExternalTool.jpegoptim != nil)
                toolRow("pngquant", found: ExternalTool.pngquant != nil)
                toolRow("ffmpeg", found: ExternalTool.ffmpeg != nil)
                toolRow("ffprobe", found: ExternalTool.ffprobe != nil)
                LabeledContent("ImageMagick") {
                    Text(app.versionLine.isEmpty ? (app.problem ?? "Not found") : app.versionLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Button("Choose magick…") { app.chooseExecutable() }
            } header: {
                Text("Tools")
            } footer: {
                Text("Smart optimize for images uses jpegoptim and pngquant. Video tools use ffmpeg (which includes ffprobe). Install them with:  brew install jpegoptim pngquant ffmpeg")
            }

            Section {
                Text("Space saved by watched folders: \(formatBytes(watcher.totalSavedBytes))")
            } header: {
                Text("This session")
            }
        }
        .formStyle(.grouped)
    }

    private func toolRow(_ name: String, found: Bool) -> some View {
        Label(found ? "\(name) is installed" : "\(name) is missing",
              systemImage: found ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(found ? Color.green : Color.orange)
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                        settings.showWindowAtLaunch = false
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    loginMessage = nil
                } catch {
                    loginMessage = error.localizedDescription
                }
                let status = SMAppService.mainApp.status
                launchAtLogin = status == .enabled
                if status == .requiresApproval {
                    loginMessage = "Approve MagickUI in System Settings ▸ General ▸ Login Items."
                }
            })
    }
}
