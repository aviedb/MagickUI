# MagickUI

**A drop-first, offline image app for macOS, powered by ImageMagick.**

Drop your images or videos into the window, then choose what to do: optimize them, compress to a target size, convert formats, crop or trim, resize, rotate, extract frames, or strip metadata. MagickUI can also live in your menu bar and optimize new images automatically as they land in folders you choose. Everything runs locally on your Mac and works in batch.

<p align="center">
  <img src="docs/main-screen.png" alt="Main screen" width="49%">
  <img src="docs/action-screen.png" alt="Action screen" width="49%">
</p>

<!-- Tip: add screenshots of the Settings window and the floating preview in docs/ and link them here. -->

## Why

There are plenty of online image tools (shout-out to my fav [ihateimg.cv](https://ihateimg.cv)), but I wanted one that works offline and in batch. Mac App alternatives exist, but many of them are a \~$20 license which is a little bit too steep. [ImageMagick](https://imagemagick.org) is free and open source, but it is mainly a command-line tool, so I built a GUI on top of it.

## Features

| Action | What it does |
|---|---|
| **Smart optimize** | Makes files smaller **without ever resizing them**, using `jpegoptim` for JPEG and `pngquant` for PNG. Balanced or Aggressive, or a custom strength |
| **Compress to size** | Gets each image under a size you choose (e.g. 200 KB or 1 MB) at the best quality that fits |
| **Convert format** | Saves images as JPG, PNG, WebP, HEIC, AVIF, TIFF, GIF, BMP, ICO, JP2, JXL, or another image format your ImageMagick can write |
| **Crop** | Drag a crop box on a preview, with aspect-ratio presets, a landscape/portrait swap, and a live preview of the result |
| **Resize** | Set exact pixels or scale by percent |
| **Rotate & flip** | Rotate 90° or 180°, or mirror horizontally or vertically |
| **Remove metadata** | Strips EXIF, GPS, and camera data before you share a photo |

Beyond the main window:

| Feature | What it does |
|---|---|
| **Watched folders** | Optimizes new images automatically in folders you choose, such as Downloads or your screenshots folder |
| **Menu bar app** | Runs in the background with no Dock icon, and you can pause watching or open Settings from the menu bar |
| **Floating preview** | A small card in the bottom-right corner shows **Optimizing…** and then the result, with no notification |
| **Finder integration** | Right-click ▸ **Open With ▸ MagickUI**, drop files on the Dock icon, or use the **Services** actions, including one-click quick compress |
| **Resizable window** | The main window shrinks to a small size, so it fits any corner of the screen when tiled with a window manager |

Video tools (they appear when you drop a video):

| Action | What it does |
|---|---|
| **Smart optimize** | Re-encodes with H.264 or HEVC so the video is much smaller while looking about the same. The resolution never changes |
| **Compress to size** | Gets each video under a size you choose (such as 25 MB), using two-pass encoding |
| **Downscale** | Reduces the resolution (4K down to 1080p, 720p…) and/or caps the frame rate |
| **Convert format** | MP4 (H.264 or HEVC), MOV, MKV, WebM, AVI, GIF, animated WebP, or just the audio as MP3, M4A, WAV, FLAC or Opus |
| **Trim** | Cuts the start and end with a two-handle slider and a frame preview, with a precise or a lossless fast mode |
| **Export frame** | Saves any moment (or several evenly spaced frames) as an image, in any of the image formats |

PDF is intentionally not supported.

## Requirements

- A Mac running macOS 13 or later
- [Homebrew](https://brew.sh)
- ImageMagick 7 (the `magick` command)
- `jpegoptim` and `pngquant`, for Smart optimize on images
- `ffmpeg` (which includes `ffprobe`), for the video tools
- Xcode, to build the app from source

## Install

There is no prebuilt release yet, so you build the app yourself.

**1. Install the command-line tools**

```bash
brew install imagemagick jpegoptim pngquant ffmpeg
```

**2. Get the code and open it in Xcode**

```bash
git clone https://github.com/aviedb/MagickUI.git
cd MagickUI
open MagickUI.xcodeproj
```

**3. Check the project settings**

- Under **Signing & Capabilities**, choose **Sign to Run Locally**, or select your own team.
- Keep **App Sandbox** turned off. A sandboxed app cannot run Homebrew's tools.
- Set the destination to **My Mac**.
- Under **Build Settings**, check that **Info.plist File** is set to `MagickUI-Info.plist` and **Generate Info.plist File** is **Yes**. This small plist (in the repo root, next to the `.xcodeproj`) starts the app as a background app and adds the Open With, Dock drop and Services entries. Do not add it to the target's files.

**4. Run or install**

- To try it, press **⌘R**.
- To install it, choose **Product → Archive**. In the Organizer, right-click the archive and choose **Show in Finder**. Then right-click the `.xcarchive` file, choose **Show Package Contents**, open `Products/Applications`, and drag the app into your **Applications** folder.

When you change the code later, repeat the archive step and replace the app. Run the app from the **Applications** folder at least once so macOS registers the Finder Services.

## How to use

1. **Drop images or videos** (or a whole folder) onto the window, or click **Choose files…**. If you drop both kinds, a switch at the top lets you choose which the actions apply to.
2. **Pick an action.** You can switch actions at any time from the tabs at the top.
3. **Adjust the options** (see below).
4. Optionally choose where to save with **Save to → Choose…**. By default, files go next to the originals.
5. Click the **Run** button. Each image shows its result, with a **Reveal in Finder** link.

Use **Show command** to see the exact `magick` command that will run, which is handy for learning ImageMagick.

On a wide window the image list is a sidebar. On a narrow window it becomes a thumbnail strip along the top, and the bottom bar wraps onto two rows.

### Smart optimize

Shrinks images **without changing their dimensions**.

| | Balanced (default) | Aggressive |
|---|---|---|
| JPEG | quality capped at 85 | quality capped at 58 |
| PNG | `pngquant` quality 0–100 | quality 0–64 |
| Dimensions | never changed | never changed |

- A JPEG that is **already at or below the cap** is only optimized losslessly, so it is never degraded further.
- A result that isn't smaller is never kept.
- **Remove metadata** is on by default for JPEGs. It keeps the photo upright and keeps the color profile.
- **HEIC, TIFF and BMP** are converted to JPG (you can turn this off). **WebP** is left alone because it is already efficient.
- The **Custom** strength runs from 5 (best quality) to 100 (smallest files).

Savings depend on the file. A phone or camera JPEG saved at very high quality often shrinks a lot. A JPEG that was already exported at quality 85 or lower barely changes, which is exactly what you want.

### Compress to size

Enter a target and a unit, or tap a preset. The app tries high quality first, and if the file is still too big, it shrinks the dimensions only as much as needed and then raises the quality again. PNG is lossless, so it reduces colors first and then dimensions. Images already under the target are left alone. KB means 1,000 bytes, so results also fit sites that count 1,024.

> Use **Smart optimize** for everyday "make it smaller without hurting it". Use **Compress to size** when a site demands a specific limit, and accept that it may shrink the dimensions to get there.

### Convert format

Pick a format chip, or choose **Other…** and type an extension (for example `jp2`). Only formats your ImageMagick can write are offered. Formats without transparency (JPG, BMP) fill transparent areas with white.

### Crop

Select an image, then drag on the preview to draw a crop box. Drag the corners or edges to resize it, and drag inside to move it. Pick an aspect ratio (Free, Original, 1:1, 4:3, 3:2, 16:9, 4:5, or Custom) and use **Swap landscape / portrait** if needed. Each image keeps its own crop. **Apply to all images** copies the crop proportionally to every image, and images without a crop are skipped.

### Resize, Rotate & flip, Remove metadata

Resize accepts pixels or a percentage, and can keep the aspect ratio and avoid enlarging. Rotate & flip applies one operation to every image. Remove metadata strips all embedded data.

## Video tools

Drop a video and the screen shows the video actions. Videos are processed by `ffmpeg`, and each one shows a live progress bar. **Cancel** stops the video that is encoding and the rest of the batch.

### Smart optimize (video)

Pick **H.264** (plays everywhere) or **HEVC** (usually smaller, but not every device plays it), a quality (High, Balanced or Smaller file) and an encoding speed. The resolution is never changed. AAC audio is copied untouched, the result is an MP4, and a video that wouldn't get smaller is left alone. 10-bit HEVC sources stay 10-bit, so HDR phone videos don't turn flat. Converting an HDR video to H.264 makes it SDR, and the result tells you so.

### Compress to size (video)

Enter a target such as 25 MB. MagickUI works out the bitrate from the video's length and encodes in two passes, so the result lands very close to the target and a little under. If the size is too small for the current resolution, it can lower the resolution for you (you can turn this off). Videos already under the target are left alone.

### Downscale

Choose a resolution (4K, 1440p, 1080p, 720p, 540p, 480p, 360p, 240p, or a custom height) and optionally a frame rate limit (60, 30, 24 or 15 fps). A video that is already smaller or slower is left as it is, unless you turn off **Only shrink**.

### Convert format (video)

Video: **MP4 (H.264)**, **MP4 (HEVC)**, **MOV**, **MKV**, **WebM**, **AVI**. Animated image: **GIF** and **animated WebP**, with a frame rate and maximum width. Audio only: **MP3**, **M4A**, **WAV**, **FLAC**, **Opus**. Only formats your ffmpeg can write are shown. MP4, MOV and MKV can also be **copied without re-encoding**, which is instant and lossless when the codecs fit the new container.

### Trim

Select a video, drag the start and end handles (or type exact seconds), and watch the preview. The preview shows the frame at the handle you moved, and it works for any format. **Precise** re-encodes at high quality and cuts exactly where you chose. **Fast** copies the streams, which is instant and lossless, but can only cut on keyframes, so the start may be a moment earlier. **Apply to all videos** copies the range to every video, and videos without a trim range are skipped.

### Export frame

Select a video, move the slider (or step by a frame or a second), and pick any image format: PNG, JPG, WebP, HEIC, AVIF, TIFF and any other format your ImageMagick can write. Or export several frames spaced evenly through the video. Frames are saved next to the video.

## Watched folders

MagickUI can optimize new images as they land in folders you choose, with no window needed.

1. Open **Settings** (menu bar icon ▸ **Settings…**, or ⌘,) and go to **Watched Folders**.
2. Click **+** and choose a folder, such as Downloads or your screenshots folder.
3. Pick what happens to each new image. **Smart optimize** is the default. You can also compress to an exact size, convert, shrink to a maximum size, or remove metadata.
4. Choose what happens to the original: **move it to the Trash** (default) or **overwrite it**.

Details:

- Only images that arrive **after** you add the folder are processed. Click **Process existing images now** to include the ones already there.
- Only the top level of the folder is watched, not its subfolders.
- A new file is processed only after it has finished being written, so downloads and screenshots in progress are left alone.
- With Smart optimize, compress and remove-metadata, the file is replaced only if the result is smaller (you can turn this off). Converting to another format is always kept.
- Files MagickUI has written are marked with a hidden attribute, so they are never processed twice.
- Closing the window does not quit the app, so watching continues. Use the menu bar icon to pause watching or quit.

### Floating preview

When a watched folder (or a Finder quick action) optimizes an image, a small card appears in the bottom-right corner of your screen. It shows a thumbnail and says **Optimizing…**, then turns into the result, for example **Saved 1.4 MB (−68%)** with the before and after sizes. No notification is sent.

- Cards never take focus, so they don't interrupt what you're typing.
- Several images stack up. Cards fade away on their own after a few seconds.
- Click a card to reveal the file in Finder. Hover to get a dismiss button.
- Turn it off, or try a demo card, in **Settings ▸ General ▸ Floating preview**.

## Runs in the background

MagickUI is built to live in the menu bar. It starts without a Dock icon, and folder watching keeps running when you close every window.

Open **Settings ▸ General ▸ Dock & menu bar** to choose when the Dock icon appears:

- **Only while a window is open** (default): the icon shows while you use a window and disappears when you close it.
- **Always**: a normal app with a permanent Dock icon.
- **Never (menu bar only)**: no Dock icon at all. Use the menu bar icon to open the app.

Turn on **Launch MagickUI at login** in **Settings ▸ General** to start watching automatically. This also turns off the main window at startup, so the app starts quietly.

## Finder integration

- **Open With:** right-click an image ▸ **Open With ▸ MagickUI**. You can also drop images or folders on the Dock icon while it is showing.
- **Services:** right-click an image ▸ **Services** (at the bottom of the menu). The actions are:
  - **Open in MagickUI**
  - **Compress / Convert / Crop / Resize with MagickUI…** opens the window with that action selected
  - **Quick compress (MagickUI)** runs Smart optimize right away (strength set in Settings ▸ General), shows the floating preview, and saves next to the original
  - **Remove metadata (MagickUI)** strips metadata right away and saves next to the original

## Where files are saved

- From the main window, output goes next to each original, or in the folder you choose. Originals are never overwritten.
- Name clashes get a number: `photo 2.jpg`, `photo 3.jpg`.
- Files get a suffix by action: `_optimized`, `_compressed`, `_cropped`, `_resized`, `_rotated`, `_clean`. Convert keeps the original name with a new extension (or `_converted` if the format stays the same).
- Videos get `_optimized`, `_compressed`, `_720p` (or `_30fps`), `_trimmed`, and `_frame_12-50s` (the time of the frame). Convert gives the video a new extension.
- **Watched folders** replace the original by default, and move it to the Trash (or overwrite it, if you choose that).

## Supported input formats

**Images:** JPG, PNG, HEIC/HEIF, WebP, TIFF, and BMP.

**Videos:** MP4, M4V, MOV, MKV, WebM, AVI, MPG/MPEG, WMV, FLV, MTS/M2TS, 3GP and OGV (anything ffmpeg can read).

You can also drop a folder.

## Good to know

- Crop coordinates are applied after the photo is rotated upright (`-auto-orient`), so the crop matches what you see.
- HEIC input is saved as JPG by every action except Convert, because HEIC encoding depends on your ImageMagick build. Compress also saves TIFF and BMP as JPG.
- Remove metadata also removes the embedded color profile, so colors on wide-gamut photos can shift slightly. (Smart optimize keeps the color profile.)
- JPEG edits re-encode the file, which causes a small quality loss.
- Only the first frame of an animated or multi-page file is used. GIF input is not accepted yet.
- Images are processed one at a time.
- Watched folders work on images only for now. Video is coming.
- Video: fast trim copies the streams, so it can only cut on keyframes. Use Precise for an exact cut.
- Video: GIFs and animated WebP are large for long clips, and have no sound.
- Dropping files on the Dock icon only works while the icon is showing, which in the default mode means while a window is open.

## Troubleshooting

- **"ImageMagick (magick) wasn't found."** Run `brew install imagemagick`. If it is installed somewhere unusual, click **Choose magick…** and select the executable (usually `/opt/homebrew/bin/magick` on Apple Silicon or `/usr/local/bin/magick` on Intel).
- **"jpegoptim isn't installed" or "pngquant isn't installed".** Run `brew install jpegoptim pngquant`. **Settings ▸ General ▸ Tools** shows which one is missing.
- **"ffmpeg isn't installed" or a video shows no preview.** Run `brew install ffmpeg`, then click **Check again** on the video screen. **Settings ▸ General ▸ Tools** shows whether `ffmpeg` and `ffprobe` are found.
- **A video format is missing from Convert.** The app only shows formats your ffmpeg can write. If one is missing, try `brew reinstall ffmpeg`.
- **A format is missing from Convert.** The app only shows formats your ImageMagick build can write. Run `magick -list format` in Terminal to see them.
- **The Services entries don't appear in Finder.** Run the app once from the **Applications** folder. Then open **System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Services** and make sure the MagickUI items are ticked. As a last resort, log out and back in.
- **There's no Dock icon.** That is the default. Use the menu bar icon, or change **Settings ▸ General ▸ Dock icon**.
- **No floating preview appears.** Check that it is turned on in **Settings ▸ General ▸ Floating preview**, and use **Try it** to see a demo card.
- **macOS asks for access to Pictures, Desktop, or Downloads.** Click **Allow**, so the app can read your images and write the results.
- **Build errors.** Make sure App Sandbox is off, the destination is My Mac, and **Info.plist File** is set to `MagickUI-Info.plist`. If you still have a problem, open an issue with the full error text.

## Roadmap

**Video:**

- [x] Smart optimize with H.264 or HEVC
- [x] Compress to a target size
- [x] Downscale and cap the frame rate
- [x] Convert between many formats, including GIF, animated WebP and audio-only
- [x] Trim with a frame preview
- [x] Export any frame as an image
- [ ] Watched folders and the floating preview for video, with a progress bar
- [ ] An optional hardware-encoder mode (VideoToolbox) for much faster encoding
- [ ] Tone mapping, so HDR videos can become SDR without looking flat
- [ ] Remove or replace the audio track
- [ ] Join several clips into one

**Everything else:**

- [ ] GIF support for images (including animated GIFs)
- [ ] Switching format when it saves a lot, such as a flat JPEG to PNG
- [ ] A Finder extension for a top-level right-click menu
- [ ] A prebuilt, downloadable release

## Credits

Built on [ImageMagick](https://imagemagick.org), which is a separate project with its own license and is not bundled with this app. Smart optimize for images uses [jpegoptim](https://github.com/tjko/jpegoptim) and [pngquant](https://pngquant.org), and the video tools use [ffmpeg](https://ffmpeg.org). They are separate open-source projects that are not bundled. Inspired by [ihateimg.cv](https://ihateimg.cv).

## License

MagickUI is released under the [MIT License](LICENSE).

ImageMagick, jpegoptim, pngquant, and ffmpeg are separate projects under their own licenses and are not bundled with this app.
