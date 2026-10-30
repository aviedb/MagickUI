import SwiftUI
import AppKit

private let secondsFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2)).grouping(.never)
private let wholeFormat = FloatingPointFormatStyle<Double>.number.grouping(.never)

// MARK: - Main video panel

struct VideoMainPanel: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.ffmpegAvailable {
                FFmpegMissingBanner()
                    .padding(12)
            }
            if let action = workspace.videoAction {
                VStack(spacing: 0) {
                    VideoActionTabs(current: action)
                    Divider()
                    panel(for: action)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                VideoActionGrid()
            }
        }
    }

    @ViewBuilder
    private func panel(for action: VideoAction) -> some View {
        switch action {
        case .optimize: VideoOptimizePanel()
        case .compress: VideoCompressPanel()
        case .downscale: VideoDownscalePanel()
        case .convert: VideoConvertPanel()
        case .trim: VideoTrimPanel()
        case .frame: VideoFramePanel()
        }
    }
}

private struct FFmpegMissingBanner: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("ffmpeg isn't installed", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            Text("Video tools use ffmpeg. Install it once in Terminal:")
                .foregroundStyle(.secondary)
            Text("brew install ffmpeg")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Button("Check again") { workspace.refreshVideoTools() }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct VideoActionGrid: View {
    @EnvironmentObject private var workspace: Workspace
    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("What do you want to do with the video?")
                    .font(.title.weight(.semibold))
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(VideoAction.allCases) { action in
                        Button {
                            workspace.chooseVideo(action)
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

private struct VideoActionTabs: View {
    let current: VideoAction
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(VideoAction.allCases) { action in
                    ChipButton(label: action.title, symbol: action.symbol, selected: action == current) {
                        workspace.chooseVideo(action)
                    }
                    .disabled(workspace.isRunning)
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Shared option pickers

private struct VideoCodecPicker: View {
    @Binding var codec: VideoCodec

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Format").font(.headline)
            Picker("", selection: $codec) {
                ForEach(VideoCodec.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)
            Text(codec == .h264
                 ? "H.264 plays on practically every device and website."
                 : "HEVC is usually smaller at the same quality, but older devices and some websites can't play it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct VideoQualityPicker: View {
    @Binding var quality: VideoQuality
    let codec: VideoCodec

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quality").font(.headline)
            Picker("", selection: $quality) {
                ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 400)
            Text("\(codec.rawValue) CRF \(quality.crf(for: codec)). A lower number keeps more detail and makes a bigger file.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct VideoSpeedPicker: View {
    @Binding var speed: EncodeSpeed

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Encoding speed").font(.headline)
            Picker("", selection: $speed) {
                ForEach(EncodeSpeed.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 400)
            Text("Slower encoding squeezes out a smaller file at the same quality.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Smart optimize

struct VideoOptimizePanel: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        PanelContainer(title: "Smart optimize",
                       subtitle: "Re-encodes each video so it's much smaller while looking about the same. The resolution never changes.") {
            VideoCodecPicker(codec: $workspace.videoOptimize.codec)
            VideoQualityPicker(quality: $workspace.videoOptimize.quality, codec: workspace.videoOptimize.codec)
            VideoSpeedPicker(speed: $workspace.videoOptimize.speed)
            Toggle("Remove metadata (location, device and chapters)", isOn: $workspace.videoOptimize.stripMetadata)
            Text("AAC audio is copied untouched. The result is an MP4. If re-encoding wouldn't make a video smaller, it's left alone.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Compress to size

struct VideoCompressPanel: View {
    @EnvironmentObject private var workspace: Workspace

    private let presets: [(String, Double)] = [("8 MB", 8), ("10 MB", 10), ("16 MB", 16), ("25 MB", 25), ("50 MB", 50), ("100 MB", 100)]

    var body: some View {
        PanelContainer(title: "Compress to a target size",
                       subtitle: "Each video is encoded to land just under the size you choose.") {
            HStack(spacing: 10) {
                Text("Make each video under")
                TextField("", value: $workspace.videoCompress.amount, format: wholeFormat)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $workspace.videoCompress.unit) {
                    ForEach(SizeUnit.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(presets, id: \.0) { preset in
                    Button {
                        workspace.videoCompress.amount = preset.1
                        workspace.videoCompress.unit = .mb
                    } label: {
                        Text(preset.0).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: 420)

            VideoCodecPicker(codec: $workspace.videoCompress.codec)
            VideoSpeedPicker(speed: $workspace.videoCompress.speed)
            Toggle("Lower the resolution if the size is too small for it", isOn: $workspace.videoCompress.allowDownscale)
            Toggle("Remove metadata", isOn: $workspace.videoCompress.stripMetadata)

            Text("It works out the bitrate from the video's length and encodes in two passes, so the result is very close to the target, and a little under. Videos already under the target are left alone. MB means 1,000,000 bytes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Downscale

struct VideoDownscalePanel: View {
    @EnvironmentObject private var workspace: Workspace

    private let heights: [(Int, String)] = [
        (2160, "4K · 2160p"), (1440, "1440p"), (1080, "1080p"), (720, "720p"),
        (540, "540p"), (480, "480p"), (360, "360p"), (240, "240p")
    ]
    private let frameRates: [(Int, String)] = [(0, "Original"), (60, "60 fps"), (30, "30 fps"), (24, "24 fps"), (15, "15 fps")]

    var body: some View {
        PanelContainer(title: "Downscale",
                       subtitle: "Reduce the resolution, the frame rate, or both. The shape of the picture is kept.") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Resolution").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(heights, id: \.0) { entry in
                        ChipButton(label: entry.1,
                                   selected: !workspace.videoDownscale.useCustom && workspace.videoDownscale.height == entry.0) {
                            workspace.videoDownscale.height = entry.0
                            workspace.videoDownscale.useCustom = false
                        }
                    }
                    ChipButton(label: "Custom…", selected: workspace.videoDownscale.useCustom) {
                        workspace.videoDownscale.useCustom = true
                    }
                }
                if workspace.videoDownscale.useCustom {
                    HStack(spacing: 8) {
                        Text("Height")
                        TextField("", value: $workspace.videoDownscale.customHeight, format: wholeFormat)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                        Text("px")
                    }
                }
                Toggle("Only shrink (never enlarge a smaller video)", isOn: $workspace.videoDownscale.shrinkOnly)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Frame rate limit").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(frameRates, id: \.0) { entry in
                        ChipButton(label: entry.1, selected: workspace.videoDownscale.fpsCap == entry.0) {
                            workspace.videoDownscale.fpsCap = entry.0
                        }
                    }
                }
                Text("A video that's already at or below the limit keeps its frame rate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VideoCodecPicker(codec: $workspace.videoDownscale.codec)
            VideoQualityPicker(quality: $workspace.videoDownscale.quality, codec: workspace.videoDownscale.codec)
            Toggle("Remove metadata", isOn: $workspace.videoDownscale.stripMetadata)
        }
    }
}

// MARK: - Convert

struct VideoConvertPanel: View {
    @EnvironmentObject private var workspace: Workspace

    private let frameRates = [8, 10, 12, 15, 20, 24]
    private let widths: [(Int, String)] = [(0, "Original"), (320, "320 px"), (480, "480 px"), (640, "640 px"), (800, "800 px")]

    private var format: VideoFormat { workspace.videoConvert.format }
    private var isCopying: Bool { format.supportsRemux && workspace.videoConvert.remux }

    private var formatNote: String {
        switch format {
        case .mp4H264: return "Plays everywhere."
        case .mp4HEVC: return "Smaller, but not every device plays HEVC."
        case .mov: return "QuickTime container with H.264."
        case .mkv: return "Holds almost anything."
        case .webm: return "VP9 video with Opus audio. Good for the web, but slow to encode."
        case .avi: return "Old-style AVI with MPEG-4 video."
        case .gif: return "No sound. GIFs get large quickly, so keep them short."
        case .webp: return "Animated WebP is much smaller than GIF."
        case .mp3, .m4a, .wav, .flac, .opus: return "Extracts the audio track."
        }
    }

    var body: some View {
        PanelContainer(title: "Convert format",
                       subtitle: "Pick the format every video should become. Only formats your ffmpeg can write are shown.") {
            ForEach([VideoFormat.Group.video, .animated, .audio], id: \.rawValue) { group in
                let formats = workspace.availableVideoFormats.filter { $0.group == group }
                if !formats.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.rawValue).font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(formats) { candidate in
                                ChipButton(label: candidate.title, selected: candidate == format) {
                                    workspace.videoConvert.format = candidate
                                }
                            }
                        }
                    }
                }
            }

            Text(formatNote)
                .font(.callout)
                .foregroundStyle(.secondary)

            if format.supportsRemux {
                Toggle("Copy without re-encoding (instant, no quality loss)", isOn: $workspace.videoConvert.remux)
                if isCopying {
                    Text("Only changes the container. It can fail if the video or audio codec doesn't fit the new format. Turn this off to re-encode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if format.usesQuality && !isCopying && format != .webp && format.group != .animated {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Quality").font(.headline)
                    Picker("", selection: $workspace.videoConvert.quality) {
                        ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 400)
                }
            }

            if [VideoFormat.mp4H264, .mp4HEVC, .mov, .mkv, .webm].contains(format) && !isCopying {
                VideoSpeedPicker(speed: $workspace.videoConvert.speed)
            }

            if format == .gif || format == .webp {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Frames per second").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(frameRates, id: \.self) { rate in
                            ChipButton(label: "\(rate)", selected: workspace.videoConvert.gifFPS == rate) {
                                workspace.videoConvert.gifFPS = rate
                            }
                        }
                    }
                    Text("Maximum width").font(.headline).padding(.top, 4)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(widths, id: \.0) { entry in
                            ChipButton(label: entry.1, selected: workspace.videoConvert.gifWidth == entry.0) {
                                workspace.videoConvert.gifWidth = entry.0
                            }
                        }
                    }
                    if format == .webp {
                        Text("Quality").font(.headline).padding(.top, 4)
                        Picker("", selection: $workspace.videoConvert.quality) {
                            ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 400)
                    }
                }
            }
        }
    }
}

// MARK: - Trim

struct VideoTrimPanel: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        PanelContainer(title: "Trim",
                       subtitle: "Drag the handles to choose the part to keep. The preview shows the frame at the handle you moved.") {
            if let item = workspace.selectedItem, item.kind == .video, let info = item.video, info.duration > 0 {
                TrimEditor(item: item, info: info)
                    .id(item.id)
            } else {
                SelectVideoHint()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Method").font(.headline)
                Picker("", selection: $workspace.videoTrim.mode) {
                    ForEach(TrimMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                Text(workspace.videoTrim.mode == .precise
                     ? "Cuts exactly where you chose. The video is re-encoded at high quality, so it takes a little longer."
                     : "Instant and lossless, but it can only cut at keyframes, so the start may be a moment earlier than you chose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Videos without a trim range are skipped.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SelectVideoHint: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        let selected = workspace.selectedItem
        VStack(spacing: 8) {
            if let selected, selected.kind == .video, selected.video == nil {
                ProgressView()
                Text(workspace.ffmpegAvailable ? "Reading this video…" : "Install ffmpeg to read this video.")
            } else {
                Text("Select a video in the list.")
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

private struct TrimEditor: View {
    let item: ImageItem
    let info: VideoInfo
    @EnvironmentObject private var workspace: Workspace
    @State private var scrub: Double = 0

    private var range: TimeRange { workspace.trimRange(for: item) }

    private var startBinding: Binding<Double> {
        Binding(get: { range.start },
                set: { value in
                    var updated = range
                    updated.start = min(max(0, value), updated.end - 0.1)
                    workspace.setTrim(updated, for: item.id)
                    scrub = updated.start
                })
    }

    private var endBinding: Binding<Double> {
        Binding(get: { range.end },
                set: { value in
                    var updated = range
                    updated.end = max(min(info.duration, value), updated.start + 0.1)
                    workspace.setTrim(updated, for: item.id)
                    scrub = updated.end
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FramePreview(url: item.url, time: scrub)

            RangeSlider(start: startBinding, end: endBinding, bounds: 0...info.duration) { moved in
                scrub = moved
            }

            HStack(alignment: .top, spacing: 18) {
                timeField("Start", binding: startBinding)
                timeField("End", binding: endBinding)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Keeping").font(.caption).foregroundStyle(.secondary)
                    Text(formatTime(range.end - range.start)).font(.title3.monospacedDigit())
                    Text("of \(formatTime(info.duration))").font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Reset") {
                    workspace.resetTrim(for: item.id)
                    scrub = 0
                }
                .disabled(!workspace.isTrimModified(item))
                if workspace.videoCount > 1 {
                    Button("Apply to all videos") { workspace.applyTrimToAll() }
                        .disabled(!workspace.isTrimModified(item))
                }
            }
        }
        .onAppear { scrub = range.start }
    }

    private func timeField(_ label: String, binding: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField("", value: binding, format: secondsFormat)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text("s").foregroundStyle(.secondary)
            }
            Text(formatTime(binding.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Export frame

struct VideoFramePanel: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        PanelContainer(title: "Export frame",
                       subtitle: "Save any moment of the video as an image, in any of the image formats.") {
            Toggle("Export several frames, spaced evenly through the video", isOn: $workspace.frameSettings.evenly)

            if workspace.frameSettings.evenly {
                Stepper("Number of frames: \(workspace.frameSettings.count)",
                        value: $workspace.frameSettings.count, in: 2...50)
                    .frame(maxWidth: 260, alignment: .leading)
            } else if let item = workspace.selectedItem, item.kind == .video, let info = item.video, info.duration > 0 {
                FrameEditor(item: item, info: info)
                    .id(item.id)
            } else {
                SelectVideoHint()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Image format").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(workspace.convertChoices, id: \.self) { ext in
                        ChipButton(label: ext.uppercased(),
                                   selected: !workspace.frameFormat.useOther && workspace.frameFormat.target == ext) {
                            workspace.frameFormat.target = ext
                            workspace.frameFormat.useOther = false
                        }
                    }
                    ChipButton(label: "Other…", selected: workspace.frameFormat.useOther) {
                        workspace.frameFormat.useOther = true
                    }
                }
                if workspace.frameFormat.useOther {
                    TextField("Extension, e.g. jp2", text: $workspace.frameFormat.otherExtension)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                if ImageFiles.lossyOutputs.contains(workspace.frameFormat.resolvedExtension) {
                    HStack {
                        Text("Quality")
                        Slider(value: $workspace.frameFormat.quality, in: 30...100, step: 1)
                            .frame(width: 220)
                        Text("\(Int(workspace.frameFormat.quality))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Frames are saved next to the video. PNG is lossless. Other formats are made with ImageMagick, so every format from the image tools works.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct FrameEditor: View {
    let item: ImageItem
    let info: VideoInfo
    @EnvironmentObject private var workspace: Workspace

    private var time: Double { workspace.frameTime(for: item) }
    private var frameLength: Double { 1 / max(info.fps, 1) }

    private var timeBinding: Binding<Double> {
        Binding(get: { time }, set: { workspace.setFrameTime($0, for: item) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FramePreview(url: item.url, time: time)

            Slider(value: timeBinding, in: 0...max(info.duration - 0.05, 0.1))

            HStack(spacing: 8) {
                Button("−1 s") { step(-1) }
                Button("−1 frame") { step(-frameLength) }
                Button("+1 frame") { step(frameLength) }
                Button("+1 s") { step(1) }
                Spacer(minLength: 8)
                TextField("", value: timeBinding, format: secondsFormat)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text("s of \(formatTime(info.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
    }

    private func step(_ delta: Double) {
        workspace.setFrameTime(time + delta, for: item)
    }
}

// MARK: - Frame preview (works for any format ffmpeg can read)

private struct FramePreview: View {
    let url: URL
    let time: Double
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.85))
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                Text("No frame here").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // The task restarts when the time changes, and the short sleep waits for the slider to settle.
        .task(id: Int((time * 10).rounded())) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            guard let ffmpeg = ExternalTool.ffmpeg else {
                failed = true
                return
            }
            let result = await FrameGrabber.frame(url: url, at: time, maxWidth: 960, ffmpeg: ffmpeg)
            if Task.isCancelled { return }
            if let result {
                image = result
                failed = false
            } else {
                failed = true
            }
        }
    }
}

// MARK: - A slider with two handles

private struct RangeSlider: View {
    @Binding var start: Double
    @Binding var end: Double
    let bounds: ClosedRange<Double>
    var minGap: Double = 0.1
    var onMoved: (Double) -> Void = { _ in }

    private let handleSize: CGFloat = 22

    private var span: Double { max(bounds.upperBound - bounds.lowerBound, 0.0001) }

    private func position(of value: Double, width: CGFloat) -> CGFloat {
        handleSize / 2 + CGFloat((value - bounds.lowerBound) / span) * width
    }

    private func value(at x: CGFloat, width: CGFloat) -> Double {
        bounds.lowerBound + Double((x - handleSize / 2) / width) * span
    }

    private var handle: some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
            .frame(width: handleSize, height: handleSize)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - handleSize, 1)
            let startX = position(of: start, width: width)
            let endX = position(of: end, width: width)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 6)
                    .padding(.horizontal, handleSize / 2)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, endX - startX), height: 6)
                    .offset(x: startX)

                handle
                    .position(x: startX, y: geometry.size.height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("range"))
                            .onChanged { drag in
                                let raw = value(at: drag.location.x, width: width)
                                let clamped = min(max(raw, bounds.lowerBound), end - minGap)
                                start = clamped
                                onMoved(clamped)
                            })

                handle
                    .position(x: endX, y: geometry.size.height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("range"))
                            .onChanged { drag in
                                let raw = value(at: drag.location.x, width: width)
                                let clamped = max(min(raw, bounds.upperBound), start + minGap)
                                end = clamped
                                onMoved(clamped)
                            })
            }
            .coordinateSpace(name: "range")
        }
        .frame(height: 28)
    }
}
