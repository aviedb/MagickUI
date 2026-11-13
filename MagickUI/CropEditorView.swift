import SwiftUI
import AppKit

// MARK: - Crop panel (editor + controls)

struct CropPanel: View {
    @EnvironmentObject private var workspace: Workspace
    private let ratioColumns = [GridItem(.adaptive(minimum: 70), spacing: 6)]

    var body: some View {
        if let item = workspace.selectedItem {
            if let size = item.pixelSize {
                GeometryReader { geometry in
                    if geometry.size.width >= 740 {
                        // Wide: editor on the left, controls on the right.
                        HStack(spacing: 0) {
                            editor(item: item, size: size)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            Divider()
                            ScrollView {
                                controls(item: item, size: size)
                            }
                            .frame(width: 270)
                        }
                    } else {
                        // Narrow: editor on top, controls below, and the whole thing scrolls.
                        ScrollView {
                            VStack(spacing: 0) {
                                editor(item: item, size: size)
                                    .frame(height: max(240, min(geometry.size.height * 0.7, 480)))
                                Divider()
                                controls(item: item, size: size)
                            }
                        }
                    }
                }
            } else {
                loading("Reading image size…")
            }
        } else {
            loading("Select an image in the list to crop it.", spinner: false)
        }
    }

    private func loading(_ text: String, spinner: Bool = true) -> some View {
        VStack(spacing: 10) {
            if spinner { ProgressView() }
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Editor

    @ViewBuilder
    private func editor(item: ImageItem, size: CGSize) -> some View {
        if let image = workspace.cropPreview {
            CropEditorView(
                image: image,
                pixelSize: size,
                rect: Binding(
                    get: { workspace.cropRects[item.id] },
                    set: { workspace.cropRects[item.id] = $0 }),
                ratio: workspace.cropSettings.ratio(imageSize: size))
            .id(item.id)
            .disabled(workspace.isRunning)
        } else {
            loading("Loading preview…")
        }
    }

    // MARK: Controls

    private func controls(item: ImageItem, size: CGSize) -> some View {
        let rect = workspace.cropRects[item.id]
        let kindBinding = Binding<CropRatioKind>(
            get: { workspace.cropSettings.kind },
            set: { newValue in
                workspace.cropSettings.kind = newValue
                workspace.applyRatioChange()
            })

        return VStack(alignment: .leading, spacing: 16) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Aspect ratio").font(.subheadline.weight(.semibold))
                    LazyVGrid(columns: ratioColumns, spacing: 6) {
                        ForEach(CropRatioKind.allCases) { kind in
                            ChipButton(label: kind.rawValue, selected: kindBinding.wrappedValue == kind) {
                                kindBinding.wrappedValue = kind
                            }
                        }
                    }

                    if workspace.cropSettings.kind == .custom {
                        HStack(spacing: 6) {
                            TextField("W", value: customBinding(\.customWidth), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            Text(":")
                            TextField("H", value: customBinding(\.customHeight), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                        }
                    }

                    if workspace.cropSettings.kind != .free {
                        Button {
                            workspace.swapCropOrientation()
                        } label: {
                            Label("Swap landscape / portrait", systemImage: "arrow.left.arrow.right")
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Selection").font(.subheadline.weight(.semibold))
                    if let rect {
                        Text("\(Int(rect.width.rounded())) × \(Int(rect.height.rounded())) px")
                            .font(.title3.monospacedDigit())
                        Text("from (\(Int(rect.minX.rounded())), \(Int(rect.minY.rounded()))) of \(Int(size.width)) × \(Int(size.height))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if let image = workspace.cropPreview {
                            CropResultPreview(image: image, pixelSize: size, rect: rect)
                        }
                    } else {
                        Text("No crop yet. Drag on the image to draw one, or pick a ratio.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("Reset") { workspace.resetCrop() }
                        .disabled(rect == nil)
                    if workspace.items.count > 1 {
                        Button("Apply to all images") { workspace.applyCropToAll() }
                            .disabled(rect == nil)
                    }
                }
                if workspace.items.count > 1 {
                    Text("Images without a crop are skipped. “Apply to all” uses the same proportions on every image.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
    }

    private func customBinding(_ keyPath: WritableKeyPath<CropSettings, Double>) -> Binding<Double> {
        Binding(
            get: { workspace.cropSettings[keyPath: keyPath] },
            set: { newValue in
                workspace.cropSettings[keyPath: keyPath] = newValue
                workspace.applyRatioChange()
            })
    }
}

// MARK: - Live preview of the cropped result

private struct CropResultPreview: View {
    let image: CGImage
    let pixelSize: CGSize
    let rect: CGRect

    var body: some View {
        if let cropped = croppedImage() {
            Image(nsImage: NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height)))
                .resizable()
                .scaledToFit()
                .background(TransparencyGrid(cell: 8))
                .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1))
                .frame(maxWidth: .infinity, maxHeight: 150)
        }
    }

    private func croppedImage() -> CGImage? {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let sx = CGFloat(image.width) / pixelSize.width
        let sy = CGFloat(image.height) / pixelSize.height
        let scaled = CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard scaled.width >= 1, scaled.height >= 1 else { return nil }
        return image.cropping(to: scaled)
    }
}

// MARK: - The draggable crop box

struct CropEditorView: View {
    let image: CGImage
    /// Size in pixels AFTER auto-orient. The crop rect is in these units.
    let pixelSize: CGSize
    /// nil = no crop set yet (the whole image is shown undimmed).
    @Binding var rect: CGRect?
    /// width / height to lock to, or nil for a free crop.
    let ratio: CGFloat?

    private enum DragKind {
        case handle(CropGeometry.Handle)
        case draw
    }

    @State private var dragKind: DragKind?
    @State private var startRect = CGRect.zero
    @State private var drawAnchor = CGPoint.zero
    /// The part of the box under the mouse (nil: outside it). Used for the cursor and the highlight.
    @State private var hoverHandle: CropGeometry.Handle?
    @State private var isHovering = false

    /// While dragging, keep showing the part being dragged. Otherwise show what's under the mouse.
    private var activeHandle: CropGeometry.Handle? {
        if let kind = dragKind {
            if case .handle(let handle) = kind { return handle }
            return nil
        }
        return hoverHandle
    }

    private var bounds: CGRect { CGRect(origin: .zero, size: pixelSize) }

    var body: some View {
        GeometryReader { geo in
            let fit = fittedRect(in: geo.size)
            let scale = pixelSize.width > 0 ? fit.width / pixelSize.width : 1

            ZStack(alignment: .topLeading) {
                // The checkerboard shows through any see-through parts of the picture.
                TransparencyGrid()
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.midX, y: fit.midY)

                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.midX, y: fit.midY)

                // A thin border around the picture.
                Rectangle()
                    .strokeBorder(Color.primary.opacity(0.3), lineWidth: 1)
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.midX, y: fit.midY)
                    .allowsHitTesting(false)

                cropOverlay(fit: fit, scale: scale, highlight: activeHandle)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(dragGesture(fit: fit, scale: scale))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    isHovering = true
                    let base = rect ?? bounds
                    let whole = base.width >= pixelSize.width * 0.99 && base.height >= pixelSize.height * 0.99
                    let box = viewRect(for: base, fit: fit, scale: scale)
                    hoverHandle = hitTest(location, in: box, wholeImage: whole)
                    if #unavailable(macOS 15.0) {
                        cursor(for: activeHandle).set()
                    }
                case .ended:
                    isHovering = false
                    hoverHandle = nil
                    if #unavailable(macOS 15.0) {
                        NSCursor.arrow.set()
                    }
                }
            }
            .modifier(CropPointerModifier(hovering: isHovering || dragKind != nil,
                                          handle: activeHandle,
                                          dragging: dragKind != nil))
        }
        .padding(16)
    }

    // MARK: Layout

    /// Where the picture is drawn inside the editor.
    ///
    /// The picture is kept `margin` points away from every side of the editor. The crop handles sit ON the
    /// picture's edge, and a mouse press only counts inside the editor's own bounds, so without this margin
    /// the outer half of every grab zone (the half beyond the picture's edge) would be cut off and dead.
    private func fittedRect(in size: CGSize) -> CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0, size.width > 0, size.height > 0 else { return .zero }
        let margin: CGFloat = 30
        let available = CGSize(width: max(size.width - margin * 2, 1), height: max(size.height - margin * 2, 1))
        let s = min(available.width / pixelSize.width, available.height / pixelSize.height)
        let w = pixelSize.width * s
        let h = pixelSize.height * s
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func viewRect(for imageRect: CGRect, fit: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: fit.minX + imageRect.minX * scale,
               y: fit.minY + imageRect.minY * scale,
               width: imageRect.width * scale,
               height: imageRect.height * scale)
    }

    private func handleList(_ v: CGRect) -> [(handle: CropGeometry.Handle, point: CGPoint)] {
        [(.topLeft, CGPoint(x: v.minX, y: v.minY)),
         (.top, CGPoint(x: v.midX, y: v.minY)),
         (.topRight, CGPoint(x: v.maxX, y: v.minY)),
         (.right, CGPoint(x: v.maxX, y: v.midY)),
         (.bottomRight, CGPoint(x: v.maxX, y: v.maxY)),
         (.bottom, CGPoint(x: v.midX, y: v.maxY)),
         (.bottomLeft, CGPoint(x: v.minX, y: v.maxY)),
         (.left, CGPoint(x: v.minX, y: v.midY))]
    }

    /// Corners are squares. Edge handles are short bars along the edge they move.
    private func handleSize(for handle: CropGeometry.Handle) -> CGSize {
        switch handle {
        case .top, .bottom: return CGSize(width: 22, height: 8)
        case .left, .right: return CGSize(width: 8, height: 22)
        default: return CGSize(width: 13, height: 13)
        }
    }

    // MARK: Overlay

    @ViewBuilder
    private func cropOverlay(fit: CGRect, scale: CGFloat, highlight: CropGeometry.Handle?) -> some View {
        let current = rect ?? bounds
        let v = viewRect(for: current, fit: fit, scale: scale)

        ZStack {
            // Darken everything outside the crop box.
            Path { path in
                path.addRect(fit)
                path.addRect(v)
            }
            .fill(Color.black.opacity(rect == nil ? 0 : 0.55), style: FillStyle(eoFill: true))

            // Rule-of-thirds grid.
            Path { path in
                for i in 1...2 {
                    let fraction = CGFloat(i) / 3
                    path.move(to: CGPoint(x: v.minX + v.width * fraction, y: v.minY))
                    path.addLine(to: CGPoint(x: v.minX + v.width * fraction, y: v.maxY))
                    path.move(to: CGPoint(x: v.minX, y: v.minY + v.height * fraction))
                    path.addLine(to: CGPoint(x: v.maxX, y: v.minY + v.height * fraction))
                }
            }
            .stroke(Color.white.opacity(0.45), lineWidth: 0.5)

            Rectangle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: v.width, height: v.height)
                .position(x: v.midX, y: v.midY)

            ForEach(handleList(v), id: \.handle) { entry in
                let lit = entry.handle == highlight
                let size = handleSize(for: entry.handle)
                RoundedRectangle(cornerRadius: 2)
                    .fill(lit ? Color.accentColor : Color.white)
                    .frame(width: size.width, height: size.height)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.55), lineWidth: 0.75))
                    .scaleEffect(lit ? 1.3 : 1)
                    .shadow(color: .black.opacity(0.3), radius: 1.5)
                    .position(entry.point)
                    .animation(.easeOut(duration: 0.1), value: lit)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Gesture

    private func dragGesture(fit: CGRect, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard scale > 0, fit.width > 0 else { return }

                func toImage(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: min(max((p.x - fit.minX) / scale, 0), pixelSize.width),
                            y: min(max((p.y - fit.minY) / scale, 0), pixelSize.height))
                }

                if dragKind == nil {
                    let base = rect ?? bounds
                    startRect = base
                    drawAnchor = toImage(value.startLocation)
                    let whole = base.width >= pixelSize.width * 0.99 && base.height >= pixelSize.height * 0.99
                    let start = viewRect(for: base, fit: fit, scale: scale)
                    if let handle = hitTest(value.startLocation, in: start, wholeImage: whole) {
                        dragKind = .handle(handle)
                    } else {
                        dragKind = .draw
                    }
                }
                guard let kind = dragKind else { return }

                let dx = value.translation.width / scale
                let dy = value.translation.height / scale

                switch kind {
                case .handle(let handle):
                    if handle == .move {
                        rect = CropGeometry.move(start: startRect,
                                                 delta: CGSize(width: dx, height: dy),
                                                 bounds: bounds)
                    } else {
                        rect = CropGeometry.resize(start: startRect, handle: handle,
                                                   delta: CGSize(width: dx, height: dy),
                                                   ratio: ratio, bounds: bounds)
                    }
                case .draw:
                    // Ignore tiny movements so a plain click doesn't create a crop.
                    if hypot(value.translation.width, value.translation.height) < 3 { return }
                    rect = CropGeometry.draw(from: drawAnchor,
                                             to: toImage(value.location),
                                             ratio: ratio, bounds: bounds)
                }
            }
            .onEnded { _ in
                dragKind = nil
            }
    }

    /// Which part of the box is under the pointer (in view coordinates), if any.
    ///
    /// The grab zones are much bigger than the little handles you see: a corner reacts within about 28 points,
    /// and an edge reacts anywhere along its whole length within about 14 points on either side. On a small
    /// box the zones shrink so there's still some middle left for moving it.
    private func hitTest(_ p: CGPoint, in v: CGRect, wholeImage: Bool) -> CropGeometry.Handle? {
        let smallest = min(v.width, v.height)
        let cornerGrab = min(28, max(12, smallest * 0.35))
        let edgeGrab = min(14, max(8, smallest * 0.22))

        // Corners first, so a corner is easy to grab even where two edge zones overlap.
        let corners: [(CropGeometry.Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: v.minX, y: v.minY)),
            (.topRight, CGPoint(x: v.maxX, y: v.minY)),
            (.bottomLeft, CGPoint(x: v.minX, y: v.maxY)),
            (.bottomRight, CGPoint(x: v.maxX, y: v.maxY))
        ]
        var nearestCorner: (handle: CropGeometry.Handle, distance: CGFloat)?
        for (handle, point) in corners {
            let distance = hypot(p.x - point.x, p.y - point.y)
            if distance <= cornerGrab, distance < (nearestCorner?.distance ?? .infinity) {
                nearestCorner = (handle, distance)
            }
        }
        if let nearestCorner { return nearestCorner.handle }

        // Edges: the distance to the edge as a whole (not just its middle point).
        func distanceToHorizontal(y: CGFloat) -> CGFloat {
            hypot(max(v.minX - p.x, 0, p.x - v.maxX), p.y - y)
        }
        func distanceToVertical(x: CGFloat) -> CGFloat {
            hypot(p.x - x, max(v.minY - p.y, 0, p.y - v.maxY))
        }
        let edges: [(CropGeometry.Handle, CGFloat)] = [
            (.top, distanceToHorizontal(y: v.minY)),
            (.bottom, distanceToHorizontal(y: v.maxY)),
            (.left, distanceToVertical(x: v.minX)),
            (.right, distanceToVertical(x: v.maxX))
        ]
        if let nearest = edges.min(by: { $0.1 < $1.1 }), nearest.1 <= edgeGrab {
            return nearest.0
        }

        if v.contains(p) {
            // Inside an untouched full-image box, a drag should draw a new crop rather than move nothing.
            return wholeImage ? nil : .move
        }
        return nil
    }

    /// Cursor for versions of macOS before 15 (15 and later use the system resize pointers).
    private func cursor(for handle: CropGeometry.Handle?) -> NSCursor {
        switch handle {
        case .move?: return .openHand
        case .left?, .right?: return .resizeLeftRight
        case .top?, .bottom?: return .resizeUpDown
        default: return .crosshair
        }
    }
}

// MARK: - Cursor feedback (macOS 15 and later)

/// Shows resize arrows over the edges and corners, a hand over the box, so it's clear what can be dragged.
private struct CropPointerModifier: ViewModifier {
    let hovering: Bool
    let handle: CropGeometry.Handle?
    let dragging: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            let style: PointerStyle? = hovering ? pointerStyle() : nil
            content.pointerStyle(style)
        } else {
            content
        }
    }

    @available(macOS 15.0, *)
    private func pointerStyle() -> PointerStyle {
        switch handle {
        case .move?: return dragging ? .grabActive : .grabIdle
        case .top?: return .frameResize(position: .top)
        case .bottom?: return .frameResize(position: .bottom)
        case .left?: return .frameResize(position: .leading)
        case .right?: return .frameResize(position: .trailing)
        case .topLeft?: return .frameResize(position: .topLeading)
        case .topRight?: return .frameResize(position: .topTrailing)
        case .bottomLeft?: return .frameResize(position: .bottomLeading)
        case .bottomRight?: return .frameResize(position: .bottomTrailing)
        case nil: return .default
        }
    }
}
