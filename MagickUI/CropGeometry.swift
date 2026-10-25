import CoreGraphics

/// Pure math for the crop box. Everything is in IMAGE PIXELS (origin top-left),
/// so the same numbers are what we pass to `magick -crop`.
nonisolated enum CropGeometry {
    static let minSide: CGFloat = 20

    enum Handle {
        case move
        case topLeft, top, topRight
        case right
        case bottomRight, bottom, bottomLeft
        case left
    }

    // MARK: Ratio fit

    /// Largest rect with `ratio` (width/height) that fits inside `rect`, centered on it.
    static func fit(ratio: CGFloat, in rect: CGRect, bounds: CGRect) -> CGRect {
        guard ratio > 0, rect.width > 0, rect.height > 0 else { return rect }
        var w = rect.width
        var h = rect.height
        if w / h > ratio { w = h * ratio } else { h = w / ratio }
        let out = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        return clampOrigin(out, in: bounds)
    }

    static func clampOrigin(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        var r = rect
        r.origin.x = min(max(r.origin.x, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.origin.y, bounds.minY), bounds.maxY - r.height)
        return r
    }

    // MARK: Move

    static func move(start: CGRect, delta: CGSize, bounds: CGRect) -> CGRect {
        clampOrigin(start.offsetBy(dx: delta.width, dy: delta.height), in: bounds)
    }

    // MARK: Resize by a handle

    static func resize(start: CGRect, handle: Handle, delta: CGSize, ratio: CGFloat?, bounds: CGRect) -> CGRect {
        guard let r = ratio, r > 0 else {
            return resizeFree(start: start, handle: handle, delta: delta, bounds: bounds)
        }

        switch handle {
        case .move:
            return start

        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let anchor: CGPoint
            let moving: CGPoint
            let sx: CGFloat
            let sy: CGFloat
            switch handle {
            case .topLeft:
                anchor = CGPoint(x: start.maxX, y: start.maxY)
                moving = CGPoint(x: start.minX, y: start.minY)
                sx = -1; sy = -1
            case .topRight:
                anchor = CGPoint(x: start.minX, y: start.maxY)
                moving = CGPoint(x: start.maxX, y: start.minY)
                sx = 1; sy = -1
            case .bottomLeft:
                anchor = CGPoint(x: start.maxX, y: start.minY)
                moving = CGPoint(x: start.minX, y: start.maxY)
                sx = -1; sy = 1
            default: // bottomRight
                anchor = CGPoint(x: start.minX, y: start.minY)
                moving = CGPoint(x: start.maxX, y: start.maxY)
                sx = 1; sy = 1
            }
            let pointer = CGPoint(x: moving.x + delta.width, y: moving.y + delta.height)
            return rectFrom(anchor: anchor, sx: sx, sy: sy, pointer: pointer, ratio: r, bounds: bounds)

        case .right:
            let fixedX = start.minX
            let cy = start.midY
            var w = max(start.width + delta.width, minSide)
            let maxW = min(bounds.maxX - fixedX, 2 * min(cy - bounds.minY, bounds.maxY - cy) * r)
            w = max(1, min(w, maxW))
            let h = w / r
            return CGRect(x: fixedX, y: cy - h / 2, width: w, height: h)

        case .left:
            let fixedX = start.maxX
            let cy = start.midY
            var w = max(start.width - delta.width, minSide)
            let maxW = min(fixedX - bounds.minX, 2 * min(cy - bounds.minY, bounds.maxY - cy) * r)
            w = max(1, min(w, maxW))
            let h = w / r
            return CGRect(x: fixedX - w, y: cy - h / 2, width: w, height: h)

        case .bottom:
            let fixedY = start.minY
            let cx = start.midX
            var h = max(start.height + delta.height, minSide)
            let maxH = min(bounds.maxY - fixedY, 2 * min(cx - bounds.minX, bounds.maxX - cx) / r)
            h = max(1, min(h, maxH))
            let w = h * r
            return CGRect(x: cx - w / 2, y: fixedY, width: w, height: h)

        case .top:
            let fixedY = start.maxY
            let cx = start.midX
            var h = max(start.height - delta.height, minSide)
            let maxH = min(fixedY - bounds.minY, 2 * min(cx - bounds.minX, bounds.maxX - cx) / r)
            h = max(1, min(h, maxH))
            let w = h * r
            return CGRect(x: cx - w / 2, y: fixedY - h, width: w, height: h)
        }
    }

    private static func resizeFree(start: CGRect, handle: Handle, delta: CGSize, bounds: CGRect) -> CGRect {
        var minX = start.minX, maxX = start.maxX
        var minY = start.minY, maxY = start.maxY

        switch handle {
        case .left, .topLeft, .bottomLeft: minX += delta.width
        case .right, .topRight, .bottomRight: maxX += delta.width
        default: break
        }
        switch handle {
        case .top, .topLeft, .topRight: minY += delta.height
        case .bottom, .bottomLeft, .bottomRight: maxY += delta.height
        default: break
        }

        // Only one edge per axis moves, so clamp the moved edge against the fixed one.
        maxX = min(max(maxX, minX + minSide), bounds.maxX)
        minX = max(min(minX, maxX - minSide), bounds.minX)
        maxY = min(max(maxY, minY + minSide), bounds.maxY)
        minY = max(min(minY, maxY - minSide), bounds.minY)

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Draw a new rect by dragging

    static func draw(from start: CGPoint, to end: CGPoint, ratio: CGFloat?, bounds: CGRect) -> CGRect {
        var sx: CGFloat = end.x >= start.x ? 1 : -1
        var sy: CGFloat = end.y >= start.y ? 1 : -1
        // If there's no room in the drag direction (anchor on the edge), grow the other way.
        if sx > 0, bounds.maxX - start.x < minSide { sx = -1 }
        if sx < 0, start.x - bounds.minX < minSide { sx = 1 }
        if sy > 0, bounds.maxY - start.y < minSide { sy = -1 }
        if sy < 0, start.y - bounds.minY < minSide { sy = 1 }
        return rectFrom(anchor: start, sx: sx, sy: sy, pointer: end, ratio: ratio, bounds: bounds)
    }

    // MARK: Shared: rect from a fixed anchor corner and a pointer

    /// `sx`/`sy` say which side of the anchor the rect extends to (+1 right/down, -1 left/up).
    private static func rectFrom(anchor: CGPoint, sx: CGFloat, sy: CGFloat,
                                 pointer: CGPoint, ratio: CGFloat?, bounds: CGRect) -> CGRect {
        let availW = sx > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
        let availH = sy > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY

        var w = max((pointer.x - anchor.x) * sx, minSide)
        var h = max((pointer.y - anchor.y) * sy, minSide)
        w = min(w, availW)
        h = min(h, availH)

        if let r = ratio, r > 0 {
            var width = max(w, h * r)
            width = min(width, availW, availH * r)
            w = width
            h = width / r
        }

        w = max(w, 1)
        h = max(h, 1)
        let x = sx > 0 ? anchor.x : anchor.x - w
        let y = sy > 0 ? anchor.y : anchor.y - h
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
