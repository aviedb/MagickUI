import SwiftUI
import AppKit

private let numberFormat = FloatingPointFormatStyle<Double>.number.grouping(.never)

// MARK: - Video folders tab

struct VideoFoldersTab: View {
    @EnvironmentObject private var store: VideoRuleStore
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
                    Image(systemName: "film.stack")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text("No video folders yet")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach($store.rules) { $rule in
                        VideoFolderRow(rule: $rule)
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

            HStack(spacing: 0) {
                SidebarButton(symbol: "plus", help: "Add a folder to watch for videos") { addFolder() }
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
            VideoRuleDetail(rule: $store.rules[index])
        } else {
            VStack(spacing: 12) {
                Image(systemName: "film")
                    .font(.system(size: 44))
                    .foregroundStyle(.tertiary)
                Text(store.rules.isEmpty ? "Optimize videos automatically" : "Select a folder")
                    .font(.title3.weight(.semibold))
                Text("New videos that land in a watched folder are processed in the background, one at a time, with a progress card in the corner of your screen. Video folders are separate from image folders.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Button {
                    addFolder()
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                .buttonStyle(AppButtonStyle(.prominent))
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
        panel.message = "Choose a folder to watch for new videos"
        if panel.runModal() == .OK, let url = panel.url {
            selection = store.addFolder(url)
        }
    }

    private func remove(_ id: UUID) {
        store.rules.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }
}

private struct VideoFolderRow: View {
    @Binding var rule: VideoWatchRule

    private var subtitle: String {
        if rule.task == .optimize { return "Smart optimize · \(rule.optimize.codec.rawValue)" }
        return rule.task.shortTitle
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "film.fill")
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

// MARK: - One video folder's settings

private struct VideoRuleDetail: View {
    @Binding var rule: VideoWatchRule
    @EnvironmentObject private var watcher: VideoWatchManager

    private let heights: [(Int, String)] = [
        (2160, "4K (2160p)"), (1440, "1440p"), (1080, "1080p"), (720, "720p"),
        (540, "540p"), (480, "480p"), (360, "360p"), (240, "240p")
    ]
    private let frameRates: [(Int, String)] = [(0, "Original"), (60, "60 fps"), (30, "30 fps"), (24, "24 fps"), (15, "15 fps")]

    private var shrinksFiles: Bool {
        rule.task == .optimize || rule.task == .compress
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                if ExternalTool.ffmpeg == nil {
                    Section {
                        Label("Install ffmpeg once in Terminal:  brew install ffmpeg",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }

                Section {
                    Picker("Action", selection: $rule.task) {
                        ForEach(VideoWatchTask.allCases) { Text($0.title).tag($0) }
                    }
                    taskOptions
                } header: {
                    Text("When a new video appears")
                }

                Section {
                    Picker("Original file", selection: $rule.originalHandling) {
                        ForEach(OriginalHandling.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if rule.originalHandling == .overwrite {
                        Text("Overwriting can't be undone. If the format changes (for example MOV to MP4), the original still goes to the Trash.")
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
                    Button("Process existing videos now") { watcher.processExisting(in: rule) }
                } footer: {
                    Text("Videos already in the folder are ignored unless you click this. Videos are processed one at a time and can take a while. A card in the corner of your screen shows the progress, and the menu bar icon can cancel the current one.")
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

    @ViewBuilder
    private var taskOptions: some View {
        switch rule.task {
        case .optimize:
            Picker("Format", selection: $rule.optimize.codec) {
                ForEach(VideoCodec.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Quality", selection: $rule.optimize.quality) {
                ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Encoding speed", selection: $rule.optimize.speed) {
                ForEach(EncodeSpeed.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Remove metadata (location, device and chapters)", isOn: $rule.optimize.stripMetadata)
            Text("The resolution never changes and the result is an MP4. AAC audio is copied untouched.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .compress:
            LabeledContent("Make each video under") {
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
            Picker("Format", selection: $rule.compress.codec) {
                ForEach(VideoCodec.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Encoding speed", selection: $rule.compress.speed) {
                ForEach(EncodeSpeed.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Lower the resolution if the size is too small for it", isOn: $rule.compress.allowDownscale)
            Toggle("Remove metadata", isOn: $rule.compress.stripMetadata)
            Text("Encodes in two passes to land just under the size. Videos already under it are left alone.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .downscale:
            Picker("Resolution", selection: $rule.downscale.height) {
                ForEach(heights, id: \.0) { Text($0.1).tag($0.0) }
            }
            Picker("Frame rate limit", selection: $rule.downscale.fpsCap) {
                ForEach(frameRates, id: \.0) { Text($0.1).tag($0.0) }
            }
            Picker("Format", selection: $rule.downscale.codec) {
                ForEach(VideoCodec.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Quality", selection: $rule.downscale.quality) {
                ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Remove metadata", isOn: $rule.downscale.stripMetadata)
            Text("Videos already at or below this resolution (and frame rate) are left alone.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .convert:
            Picker("Convert to", selection: $rule.convert.format) {
                ForEach(VideoFormat.allCases.filter { $0.group == .video }) { Text($0.title).tag($0) }
            }
            if rule.convert.format.supportsRemux {
                Toggle("Copy without re-encoding (instant, no quality loss)", isOn: $rule.convert.remux)
            }
            if !(rule.convert.format.supportsRemux && rule.convert.remux) {
                Picker("Quality", selection: $rule.convert.quality) {
                    ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Encoding speed", selection: $rule.convert.speed) {
                    ForEach(EncodeSpeed.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            Text("Copying only changes the container, and can fail if the codecs don't fit the new format.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
