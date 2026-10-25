# MagickTools: drop-first image app

Drop images into the window, then choose what to do: **Compress to size**, **Convert format**, **Crop**, **Resize**, **Rotate & flip**, **Remove metadata**. Images only (no PDF).

## Replace the old files in Xcode

1. In the project navigator, **delete every old `.swift` file** (Move to Trash): `HomeView`, `ToolView`, `ToolViewModel`, `ToolModel`, `ToolRegistry`, `JobPlanner`, `MagickRunner`, `MagickLocator`, `MagickToolsApp`.
2. Drag in **all 11 files** from this folder (tick "Copy items if needed" and your app target):
   `MagickToolsApp, MagickLocator, MagickRunner, Helpers, Models, CropGeometry, SizeCompressor, Workspace, RootView, ActionPanels, CropEditorView`.
3. Keep your existing settings: **App Sandbox removed**, destination **Mac only**, Swift Language Version 5, Default Actor Isolation **nonisolated** (if shown).
4. ⌘B, then ⌘R.

## Things to test first

- Drop a few photos (including a HEIC). The sidebar should show thumbnails and pixel sizes.
- **Compress to size:** try 200 KB on a big JPG. The result row shows the before → after size and what was used (quality / scale).
- **Convert:** HEIC → JPG, PNG → WebP, JPG → PNG. Try "Other…" with `jp2`.
- **Crop:** drag on the image to draw a box, drag corners and edges, drag inside to move. Pick 16:9, then Swap. Check the cropped preview, run it, and compare the output with the preview.
- Drop several images, crop one, press "Apply to all images".
- A filename with spaces or `[brackets]`.

## Notes

- Output goes next to each original (or the folder you choose), never overwriting. Name clashes get " 2", " 3".
- Crop coordinates are applied after the photo is rotated upright (`-auto-orient`), so the crop matches what you see.
- HEIC input is saved as JPG by every action except Convert.
- Only the first frame of an animated or multi-page file is used (GIF isn't accepted yet).
- Not compiled by the author. Send me any build error you get.
