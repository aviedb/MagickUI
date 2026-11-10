import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Errors

nonisolated enum BackgroundRemovalError: LocalizedError {
    case modelNotInstalled
    case unreadableImage
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled:
            return "The Remove background model isn't installed yet. Download it first."
        case .unreadableImage:
            return "The image could not be read."
        case .failed(let message):
            return message
        }
    }
}

// MARK: - The engine

/// On-device background removal with the withoutBG Open Weights Core ML model (`wbgnet_oss`, fp32).
///
/// This is a port of `CoreMLProcessor` from withoutbg-mac v1.0, and it must give the same results:
/// letterbox to 1024×1024 (top-left, black padding) → NCHW float32 tensor in [0, 1] → model →
/// alpha (1×1×1024×1024) → crop the valid region → resize to the source size → use as the alpha channel.
/// Do not change the constants or the steps below, or the results will no longer match withoutbg-mac.
///
/// The model is not part of the app. It is downloaded once (see `BackgroundModelStore`) and loaded from
/// Application Support when first needed, then released again after a few idle minutes.
final class BackgroundRemovalEngine: @unchecked Sendable {
    static let shared = BackgroundRemovalEngine()

    // Same values as withoutbg-mac v1.0.
    static let inputName = "rgb"
    static let outputName = "alpha"
    private static let canvas = 1024

    /// How long the loaded model stays in memory after its last use.
    private static let idleSeconds: TimeInterval = 300

    private let lock = NSLock()           // guards `cachedModel` and `idleItem`
    private let inferenceLock = NSLock()  // one prediction at a time
    private var cachedModel: MLModel?
    private var idleItem: DispatchWorkItem?

    // Counts the images being processed right now. It has its own lock, so asking never waits for a model load.
    private let runLock = NSLock()
    private var activeRuns = 0

    private init() {}

    /// True while an image is going through the model.
    var isProcessing: Bool {
        runLock.lock()
        defer { runLock.unlock() }
        return activeRuns > 0
    }

    private func beginRun() {
        runLock.lock()
        activeRuns += 1
        runLock.unlock()
    }

    private func endRun() {
        runLock.lock()
        activeRuns -= 1
        runLock.unlock()
    }

    // MARK: Public

    /// Cuts out the subject and returns a PNG with a transparent background.
    /// Runs off the main thread.
    func cutoutPNG(from url: URL) async throws -> Data {
        beginRun()
        defer { endRun() }
        return try await Task.detached(priority: .userInitiated) { [self] in
            try renderCutoutPNG(from: url)
        }.value
    }

    /// Loads the model in the background, so the first image doesn't wait for it.
    func preload() {
        guard FileManager.default.fileExists(atPath: BackgroundModelFiles.compiledModelURL.path) else { return }
        Task.detached(priority: .utility) { [self] in
            if (try? loadModel()) != nil { scheduleUnload() }
        }
    }

    /// Releases the model from memory (also needed before the files are replaced or deleted).
    func unload() {
        lock.lock()
        defer { lock.unlock() }
        idleItem?.cancel()
        idleItem = nil
        cachedModel = nil
    }

    // MARK: Model loading

    private func loadModel() throws -> MLModel {
        lock.lock()
        defer { lock.unlock() }
        if let cachedModel { return cachedModel }

        let url = BackgroundModelFiles.compiledModelURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BackgroundRemovalError.modelNotInstalled
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: url, configuration: configuration)
        cachedModel = model
        return model
    }

    private func scheduleUnload() {
        lock.lock()
        defer { lock.unlock() }
        idleItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.cachedModel = nil
            self.idleItem = nil
            self.lock.unlock()
        }
        idleItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.idleSeconds, execute: item)
    }

    // MARK: Inference

    private func renderCutoutPNG(from url: URL) throws -> Data {
        guard let image = WBGImage.cgImage(from: url) else {
            throw BackgroundRemovalError.unreadableImage
        }
        let cutout = try runInference(on: image)
        guard let png = WBGImage.pngData(from: cutout) else {
            throw BackgroundRemovalError.failed("Could not create the PNG file.")
        }
        return png
    }

    private func runInference(on image: CGImage) throws -> CGImage {
        let model = try loadModel()

        guard let (tensor, newW, newH) = WBGImage.letterboxTensor(image, canvas: Self.canvas) else {
            throw BackgroundRemovalError.unreadableImage
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            Self.inputName: MLFeatureValue(multiArray: tensor)
        ])

        inferenceLock.lock()
        let output: any MLFeatureProvider
        do {
            output = try model.prediction(from: provider)
        } catch {
            inferenceLock.unlock()
            throw error
        }
        inferenceLock.unlock()

        guard let alpha = output.featureValue(for: Self.outputName)?.multiArrayValue else {
            throw BackgroundRemovalError.failed("The model returned no \"\(Self.outputName)\" output.")
        }

        guard let matte = Self.makeMatte(from: alpha,
                                         canvas: Self.canvas,
                                         validW: newW,
                                         validH: newH,
                                         targetW: image.width,
                                         targetH: image.height) else {
            throw BackgroundRemovalError.failed("Could not build the alpha matte.")
        }

        guard let cutout = WBGImage.cutout(from: image, matte: matte) else {
            throw BackgroundRemovalError.failed("Could not composite the cutout.")
        }

        scheduleUnload()
        return cutout
    }

    /// Crops the model's `(1, 1, canvas, canvas)` alpha output to the valid letterboxed region,
    /// then resizes it to the source dimensions.
    private static func makeMatte(from alpha: MLMultiArray,
                                  canvas: Int,
                                  validW: Int,
                                  validH: Int,
                                  targetW: Int,
                                  targetH: Int) -> CGImage? {
        guard validW > 0, validH > 0 else { return nil }
        var gray = [UInt8](repeating: 0, count: validW * validH)

        func fill(_ read: (Int) -> Float) {
            for y in 0..<validH {
                let srcRow = y * canvas
                let dstRow = y * validW
                for x in 0..<validW {
                    let v = max(0, min(1, read(srcRow + x)))
                    gray[dstRow + x] = UInt8(v * 255 + 0.5)
                }
            }
        }

        switch alpha.dataType {
        case .float32:
            let p = alpha.dataPointer.bindMemory(to: Float32.self, capacity: alpha.count)
            fill { Float(p[$0]) }
        case .float16:
            #if arch(arm64)
            let p = alpha.dataPointer.bindMemory(to: Float16.self, capacity: alpha.count)
            fill { Float(p[$0]) }
            #else
            return nil
            #endif
        case .double:
            let p = alpha.dataPointer.bindMemory(to: Double.self, capacity: alpha.count)
            fill { Float(p[$0]) }
        @unknown default:
            return nil
        }

        guard let cropped = WBGImage.grayImage(gray, width: validW, height: validH) else { return nil }
        return WBGImage.resizedMatte(cropped, toWidth: targetW, height: targetH)
    }
}

// MARK: - Image helpers (ported unchanged from withoutbg-mac v1.0 `ImageUtilities`)

nonisolated enum WBGImage {
    // MARK: Decode

    /// Decodes JPEG/PNG/WebP/HEIC/TIFF/BMP data to a CGImage. The EXIF orientation is NOT applied,
    /// exactly like withoutbg-mac.
    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageSourceShouldCache: true]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    static func cgImage(from url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return cgImage(from: data)
    }

    // MARK: Letterbox (model input)

    /// Letterboxes `image` onto a `canvas`×`canvas` black square as a 32BGRA `CVPixelBuffer`,
    /// anchored top-left, preserving the aspect ratio (longest side → `canvas`).
    static func letterboxPixelBuffer(
        _ image: CGImage,
        canvas: Int
    ) -> (pixelBuffer: CVPixelBuffer, newW: Int, newH: Int)? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0, canvas > 0 else { return nil }

        let newW: Int
        let newH: Int
        if h >= w {
            newH = canvas
            newW = max(1, Int((Double(w) * Double(canvas) / Double(h)).rounded()))
        } else {
            newW = canvas
            newH = max(1, Int((Double(h) * Double(canvas) / Double(w)).rounded()))
        }

        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            canvas,
            canvas,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let pixelBuffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // 32BGRA = premultipliedFirst + little-endian byte order.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: base,
            width: canvas,
            height: canvas,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        // Fresh CVPixelBuffer memory is not guaranteed zeroed; paint the black padding explicitly.
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
        ctx.interpolationQuality = .high
        // CGContext origin is bottom-left; draw at the top so the content lands in the first rows.
        ctx.draw(image, in: CGRect(x: 0, y: canvas - newH, width: newW, height: newH))
        return (pixelBuffer, newW, newH)
    }

    /// Letterboxes `image` as an NCHW float32 `MLMultiArray` in [0, 1] (shape `[1, 3, canvas, canvas]`).
    static func letterboxTensor(
        _ image: CGImage,
        canvas: Int
    ) -> (tensor: MLMultiArray, newW: Int, newH: Int)? {
        guard let (pixelBuffer, newW, newH) = letterboxPixelBuffer(image, canvas: canvas) else {
            return nil
        }
        guard let array = try? MLMultiArray(
            shape: [1, 3, canvas as NSNumber, canvas as NSNumber],
            dataType: .float32
        ) else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let src = base.assumingMemoryBound(to: UInt8.self)
        let out = array.dataPointer.bindMemory(to: Float32.self, capacity: 3 * canvas * canvas)
        let planeSize = canvas * canvas

        for y in 0..<canvas {
            let row = src.advanced(by: y * bytesPerRow)
            for x in 0..<canvas {
                let px = x * 4
                let idx = y * canvas + x
                out[idx] = Float(row[px + 2]) / 255
                out[planeSize + idx] = Float(row[px + 1]) / 255
                out[2 * planeSize + idx] = Float(row[px]) / 255
            }
        }
        return (array, newW, newH)
    }

    // MARK: Matte

    /// Builds a grayscale CGImage from a row-major 8-bit buffer.
    static func grayImage(_ pixels: [UInt8], width w: Int, height h: Int) -> CGImage? {
        guard w > 0, h > 0, pixels.count >= w * h else { return nil }
        var data = pixels
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &data,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        return ctx.makeImage()
    }

    /// High-quality resize of a (grayscale) matte to an exact pixel size.
    static func resizedMatte(_ image: CGImage, toWidth w: Int, height h: Int) -> CGImage? {
        guard w > 0, h > 0 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: Cutout

    /// Applies the grayscale matte's luminance as the alpha channel of `image`, producing a transparent cutout.
    static func cutout(from image: CGImage, matte: CGImage) -> CGImage? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }

        // 1. Rasterize the source into a known RGBA layout.
        guard let rgba = rgbaBuffer(from: image, width: w, height: h) else { return nil }

        // 2. Rasterize the matte (scaled to match) into a grayscale buffer.
        guard let matteBuffer = grayBuffer(from: matte, width: w, height: h) else { return nil }

        // 3. Replace alpha with the matte luminance.
        var out = rgba
        for i in 0..<(w * h) {
            out[i * 4 + 3] = matteBuffer[i]
        }

        // 4. Emit a non-premultiplied RGBA CGImage so PNG export keeps colors.
        return makeRGBAImage(out, width: w, height: h, premultiplied: false)
    }

    // MARK: PNG

    static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: Buffer helpers

    private static func rgbaBuffer(from image: CGImage, width w: Int, height h: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &buffer,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buffer
    }

    private static func grayBuffer(from image: CGImage, width w: Int, height h: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: w * h)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &buffer,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buffer
    }

    private static func makeRGBAImage(
        _ buffer: [UInt8],
        width w: Int,
        height h: Int,
        premultiplied: Bool
    ) -> CGImage? {
        var data = buffer
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let alphaInfo: CGImageAlphaInfo = premultiplied ? .premultipliedLast : .last
        let bitmapInfo = CGBitmapInfo(rawValue: alphaInfo.rawValue)
        guard let provider = CGDataProvider(
            data: Data(bytes: &data, count: data.count) as CFData
        ) else {
            return nil
        }
        return CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
