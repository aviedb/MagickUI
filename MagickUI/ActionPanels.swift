import SwiftUI
import AppKit

// MARK: - Main panel: "what do you want to do?" then that action's options

struct MainPanel: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        if let action = workspace.action {
            VStack(spacing: 0) {
                ActionTabs(current: action)
                Divider()
                panel(for: action)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            ActionGrid()
        }
    }

    @ViewBuilder
    private func panel(for action: ImageAction) -> some View {
        switch action {
        case .compress: CompressPanel()
        case .convert: ConvertPanel()
        case .crop: CropPanel()
        case .resize: ResizePanel()
        case .rotate: RotatePanel()
        case .metadata: MetadataPanel()
        }
    }
}

/// Shown right after the drop.
private struct ActionGrid: View {
    @EnvironmentObject private var workspace: Workspace
    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("What do you want to do?")
                    .font(.title.weight(.semibold))
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(ImageAction.allCases) { action in
                        Button {
                            workspace.choose(action)
                        } label: {
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: action.symbol)
                                    .font(.title)
                                    .frame(width: 36)
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(action.title).font(.headline)
                                    Text(action.subtitle)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
                            .contentShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(28)
        }
    }
}

private struct ActionTabs: View {
    let current: ImageAction
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ImageAction.allCases) { action in
                    ChipButton(label: action.title, symbol: action.symbol, selected: action == current) {
                        workspace.choose(action)
                    }
                    .disabled(workspace.isRunning)
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Shared small views

struct ChipButton: View {
    let label: String
    var symbol: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        if selected {
            Button(action: action) { content }
                .buttonStyle(.borderedProminent)
        } else {
            Button(action: action) { content }
                .buttonStyle(.bordered)
        }
    }

    private var content: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol) }
            Text(label).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PanelContainer<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(subtitle).foregroundStyle(.secondary)
                }
                content
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private let integerFormat = FloatingPointFormatStyle<Double>.number.grouping(.never)

// MARK: - Compress to size

struct CompressPanel: View {
    @EnvironmentObject private var workspace: Workspace

    private let presets: [(String, Double, SizeUnit)] = [
        ("50 KB", 50, .kb), ("100 KB", 100, .kb), ("200 KB", 200, .kb),
        ("500 KB", 500, .kb), ("1 MB", 1, .mb), ("2 MB", 2, .mb)
    ]

    var body: some View {
        PanelContainer(title: "Compress to a target size",
                       subtitle: "Each image is re-encoded at the best quality that fits under the size you choose.") {
            HStack(spacing: 10) {
                Text("Make each image under")
                TextField("", value: $workspace.compress.amount, format: integerFormat)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $workspace.compress.unit) {
                    ForEach(SizeUnit.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
            }

            HStack(spacing: 8) {
                ForEach(presets, id: \.0) { preset in
                    Button(preset.0) {
                        workspace.compress.amount = preset.1
                        workspace.compress.unit = preset.2
                    }
                    .buttonStyle(.bordered)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Save as").font(.headline)
                Picker("", selection: $workspace.compress.format) {
                    ForEach(CompressFormat.allCases.filter { $0 != .webp || workspace.canWriteWebP }) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 380)
                Text("HEIC, TIFF and BMP files can't stay in their format here, so they're saved as JPG.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Remove metadata (saves a few KB)", isOn: $workspace.compress.stripMetadata)

            VStack(alignment: .leading, spacing: 4) {
                Text("How it works").font(.headline)
                Text("""
                It tries high quality first. If the file is still too big, it shrinks the dimensions only as much \
                as needed, then raises the quality back up. PNG is lossless, so it reduces colors, then dimensions. \
                Files already under the target are left alone. KB means 1,000 bytes, so the result also fits \
                sites that count 1,024.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Convert

struct ConvertPanel: View {
    @EnvironmentObject private var workspace: Workspace
    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 8)]

    private var lossy: Bool {
        ImageFiles.lossyOutputs.contains(workspace.convert.resolvedExtension)
    }

    var body: some View {
        PanelContainer(title: "Convert to another format",
                       subtitle: "Pick the format every image should be saved as.") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(workspace.convertChoices, id: \.self) { ext in
                    ChipButton(label: ext.uppercased(),
                               selected: !workspace.convert.useOther && workspace.convert.target == ext) {
                        workspace.convert.target = ext
                        workspace.convert.useOther = false
                    }
                }
                ChipButton(label: "Other…", selected: workspace.convert.useOther) {
                    workspace.convert.useOther = true
                }
            }

            if workspace.convert.useOther {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Extension, e.g. jp2", text: $workspace.convert.otherExtension)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Text("Any image format your ImageMagick can write. Documents (PDF, PS, HTML…) aren't allowed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if lossy {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Quality").font(.headline)
                        Spacer()
                        Text("\(Int(workspace.convert.quality))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $workspace.convert.quality, in: 30...100, step: 1)
                        .frame(maxWidth: 380)
                }
            }

            if ImageFiles.noAlphaOutputs.contains(workspace.convert.resolvedExtension) {
                Text("This format has no transparency, so transparent areas are filled with white.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Resize

struct ResizePanel: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        PanelContainer(title: "Resize",
                       subtitle: "Set exact pixels or scale by percent. HEIC files are saved as JPG.") {
            Picker("", selection: $workspace.resize.mode) {
                ForEach(ResizeMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)

            if workspace.resize.mode == .pixels {
                HStack(spacing: 12) {
                    labeledField("Width (px)", value: $workspace.resize.width)
                    labeledField("Height (px)", value: $workspace.resize.height)
                }
                Text("Leave one side at 0 to size by the other side.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Keep aspect ratio", isOn: $workspace.resize.keepAspect)
                if workspace.resize.keepAspect || workspace.resize.width == 0 || workspace.resize.height == 0 {
                    Toggle("Only shrink larger images (never enlarge)", isOn: $workspace.resize.shrinkOnly)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Scale").font(.headline)
                        Spacer()
                        Text("\(Int(workspace.resize.percent))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $workspace.resize.percent, in: 1...200, step: 1)
                        .frame(maxWidth: 380)
                }
            }
        }
    }

    private func labeledField(_ label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", value: value, format: integerFormat)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
        }
    }
}

// MARK: - Rotate & flip

struct RotatePanel: View {
    @EnvironmentObject private var workspace: Workspace
    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 8)]

    var body: some View {
        PanelContainer(title: "Rotate & flip",
                       subtitle: "Applies to every image in the list. HEIC files are saved as JPG.") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(RotateOperation.allCases) { operation in
                    ChipButton(label: operation.rawValue, symbol: operation.symbol,
                               selected: workspace.rotate == operation) {
                        workspace.rotate = operation
                    }
                }
            }
        }
    }
}

// MARK: - Remove metadata

struct MetadataPanel: View {
    var body: some View {
        PanelContainer(title: "Remove metadata",
                       subtitle: "Strips EXIF, GPS location, camera details and other embedded data.") {
            VStack(alignment: .leading, spacing: 10) {
                Label("The photo is rotated upright first, so it doesn't end up sideways.", systemImage: "checkmark.circle")
                Label("The embedded color profile is removed too, so colors on wide-gamut photos can shift slightly.",
                      systemImage: "exclamationmark.triangle")
                Label("JPEGs are re-encoded, which is a small quality loss. HEIC files are saved as JPG.",
                      systemImage: "exclamationmark.triangle")
            }
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Bottom bar: where to save + Run

struct RunBar: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var workspace: Workspace
    @State private var showCommand = false

    private var runLabel: String {
        guard let action = workspace.action else { return "Choose an action" }
        if workspace.isRunning { return "Working…" }
        let count = workspace.runCount
        return "\(action.verb) \(count) \(count == 1 ? "image" : "images")"
    }

    private var canRun: Bool {
        workspace.action != nil && workspace.runCount > 0 && !workspace.isRunning && app.runner != nil
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Save to").font(.caption).foregroundStyle(.secondary)
                Text(workspace.outputFolder?.path ?? "Next to the originals")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 260, alignment: .leading)

            Button("Choose…") { workspace.chooseOutputFolder() }
                .disabled(workspace.isRunning)
            if workspace.outputFolder != nil {
                Button("Reset") { workspace.outputFolder = nil }
                    .disabled(workspace.isRunning)
            }

            Spacer()

            if !workspace.commandPreview.isEmpty {
                Button("Show command") { showCommand.toggle() }
                    .popover(isPresented: $showCommand) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Command for the selected image").font(.caption).foregroundStyle(.secondary)
                            Text(workspace.commandPreview)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(14)
                        .frame(width: 460, alignment: .leading)
                    }
            }

            if workspace.hasResults {
                Button("Show results in Finder") { workspace.revealResults() }
            }

            Button {
                Task { await workspace.run() }
            } label: {
                Text(runLabel).frame(minWidth: 170)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canRun)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
