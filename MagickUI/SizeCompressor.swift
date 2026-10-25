import Foundation

nonisolated struct SizeCompressResult {
    /// Temp file holding the best result. The caller moves it to its final place.
    let file: URL
    let bytes: Int64
    let note: String
}

/// Finds the best-looking encode that fits under a byte budget.
///
/// JPG / WebP: try high quality first; if too big, find the smallest size reduction that works at
/// quality 40, then binary-search the quality back up at that size.
/// PNG (lossless): try max compression, then 256 colors, then reduce dimensions.
nonisolated struct SizeCompressor {
    let runner: MagickRunner

    /// Percent of original dimensions, largest first.
    static let scales = [100, 90, 80, 70, 60, 50, 40, 30, 25, 20, 15, 10, 5]

    private struct Attempt {
        let scaleIndex: Int
        let level: Int      // JPG/WebP: quality. PNG: color count (0 = lossless)
        let url: URL
        let bytes: Int64
    }

    /// `ext` must be "jpg", "webp" or "png".
    func compress(inputPath: String,
                  ext: String,
                  targetBytes: Int64,
                  strip: Bool,
                  workDir: URL) async throws -> SizeCompressResult {
        let isPNG = ext == "png"
        let highLevel = isPNG ? 0 : 95
        let lowLevel = isPNG ? 256 : 40
        var counter = 0

        func attempt(_ scaleIndex: Int, _ level: Int) async throws -> Attempt {
            counter += 1
            let out = workDir.appendingPathComponent("attempt-\(counter).\(ext)")
            var args = [firstFrame(inputPath), "-auto-orient"]
            if strip { args.append("-strip") }
            let scale = SizeCompressor.scales[scaleIndex]
            if scale < 100 { args += ["-resize", "\(scale)%"] }
            switch ext {
            case "png":
                args += ["-define", "png:compression-level=9"]
                if level > 0 { args += ["-colors", String(level)] }
            case "jpg":
                args += ["-background", "white", "-alpha", "remove", "-alpha", "off",
                         "-sampling-factor", "4:2:0", "-interlace", "Plane",
                         "-quality", String(level)]
            default:
                args += ["-quality", String(level)]
            }
            args.append(out.path)
            try await runner.run(args)
            guard FileManager.default.fileExists(atPath: out.path) else {
                throw MagickError(message: "magick finished but no output file was created.")
            }
            return Attempt(scaleIndex: scaleIndex, level: level, url: out, bytes: fileSize(out))
        }

        func describe(_ a: Attempt) -> String {
            var parts: [String] = []
            if isPNG {
                parts.append(a.level > 0 ? "\(a.level) colors" : "lossless")
            } else {
                parts.append("quality \(a.level)")
            }
            let scale = SizeCompressor.scales[a.scaleIndex]
            if scale < 100 { parts.append("scaled to \(scale)%") }
            return parts.joined(separator: ", ")
        }

        func result(_ a: Attempt) -> SizeCompressResult {
            SizeCompressResult(file: a.url, bytes: a.bytes, note: describe(a))
        }

        // 1. Full size at the best level.
        let first = try await attempt(0, highLevel)
        if first.bytes <= targetBytes { return result(first) }

        // 2. Smallest reduction that fits at the lowest acceptable level.
        let passing: Attempt
        let lowAtFull = try await attempt(0, lowLevel)
        if lowAtFull.bytes <= targetBytes {
            if isPNG { return result(lowAtFull) }
            passing = lowAtFull
        } else {
            var lo = 1
            var hi = SizeCompressor.scales.count - 1
            var found: Attempt?
            while lo <= hi {
                let mid = (lo + hi) / 2
                let a = try await attempt(mid, lowLevel)
                if a.bytes <= targetBytes {
                    found = a
                    hi = mid - 1      // fits: try a larger image
                } else {
                    lo = mid + 1      // too big: go smaller
                }
            }
            guard let f = found else {
                let smallest = SizeCompressor.scales.last ?? 5
                throw MagickError(message: "Couldn't get under the target, even at \(smallest)% size. Try a larger target.")
            }
            if isPNG { return result(f) }
            passing = f
        }

        // 3. (JPG / WebP) Raise the quality again at that size.
        if passing.scaleIndex > 0 {
            let top = try await attempt(passing.scaleIndex, highLevel)
            if top.bytes <= targetBytes { return result(top) }
        }
        var loQ = lowLevel
        var hiQ = highLevel
        var best = passing
        while hiQ - loQ > 1 {
            let mid = (loQ + hiQ) / 2
            let a = try await attempt(passing.scaleIndex, mid)
            if a.bytes <= targetBytes {
                best = a
                loQ = mid
            } else {
                hiQ = mid
            }
        }
        return result(best)
    }
}
