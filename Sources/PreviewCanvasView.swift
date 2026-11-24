import AppKit
import CoreGraphics

/// Pure AppKit canvas displaying either the flatbed preview (with rotation-aware crop handles)
/// or the completed full-resolution scan, with smooth native zoom & pan controls.
@MainActor
final class PreviewCanvasView: NSView {
    var onCropChanged: ((NormalizedCropRect) -> Void)?
    var onZoomChanged: ((_ effectiveScale: CGFloat, _ isFit: Bool) -> Void)?
    var onViewportSettled: (() -> Void)?

    /// Physical flatbed crop rect (normalized 0...1, unrotated platen coordinates).
    var cropRect: NormalizedCropRect = .full {
        didSet {
            if cropRect != oldValue {
                needsDisplay = true
            }
        }
    }

    /// Shows drag-to-crop overlay in Preview mode; hides it in Scan inspection mode so dragging pans cleanly.
    var showCropOverlay: Bool = true {
        didSet {
            if showCropOverlay != oldValue {
                dragMode = .none
                needsDisplay = true
                refreshCursorIfPointerInside()
            }
        }
    }

    var rotation: ScanRotation = .deg0 {
        didSet {
            if rotation != oldValue {
                needsDisplay = true
            }
        }
    }

    /// Primary image drawn across the full page rect.
    var previewImage: CGImage? {
        didSet {
            highResOverlayTile = nil
            clampPanOffset()
            needsDisplay = true
            notifyZoomChanged()
            refreshCursorIfPointerInside()
        }
    }

    /// Optional crisp 1:1 pixel overlay tile (normalized 0...1 rect in displayed image coordinates)
    /// used when zoomed in on large 1200 DPI scans or inspecting lossy JPEG/HEIC compression at 1:1.
    struct OverlayTile {
        let image: CGImage
        let normalizedRect: CGRect // in displayed image coords (origin top-left, 0...1)
    }
    var highResOverlayTile: OverlayTile? {
        didSet { needsDisplay = true }
    }

    /// True full-resolution pixel size of the underlying image (used so "100%" reflects real scan pixels even when displaying a proxy).
    var truePixelSize: CGSize = .zero {
        didSet {
            clampPanOffset()
            notifyZoomChanged()
        }
    }

    var emptyStateTitle: String = "No Preview Loaded" {
        didSet { needsDisplay = true }
    }

    var emptyStateSubtitle: String = "Click Preview to inspect the flatbed, or Scan directly for a full page." {
        didSet { needsDisplay = true }
    }

    /// Physical flatbed aspect ratio (width / height) used when drawing placeholder or mapping crop.
    var platenAspectRatio: CGFloat = 2550.0 / 3508.0 {
        didSet { needsDisplay = true }
    }

    // MARK: - Zoom & Pan State

    private(set) var isFitToWindow: Bool = true
    private(set) var zoomScale: CGFloat = 1.0 // points per true image pixel (1.0 == 100%)
    private var panOffset: CGPoint = .zero    // translation in view points from viewport center

    private let minZoom: CGFloat = 0.04
    private let maxZoom: CGFloat = 8.0
    private let canvasPadding: CGFloat = 28
    private let handleRadius: CGFloat = 5.5
    private let hitTolerance: CGFloat = 11.0

    private enum DragMode {
        case none
        case pan(startViewPoint: CGPoint, initialPanOffset: CGPoint)
        case move(startDisplayPoint: CGPoint, initialDisplayRect: CGRect)
        case resize(handle: Handle, startDisplayPoint: CGPoint, initialDisplayRect: CGRect)
        case create(anchorNorm: CGPoint)
    }

    private enum Handle: CaseIterable {
        case topLeft, top, topRight
        case left, right
        case bottomLeft, bottom, bottomRight
    }

    private var dragMode: DragMode = .none
    private var trackingArea: NSTrackingArea?
    private var settleWorkItem: DispatchWorkItem?
    private var hasCanvasCursor: Bool = false

    private var isDragging: Bool {
        if case .none = dragMode { return false }
        return true
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        clampPanOffset()
        notifyZoomChanged()
        scheduleViewportSettled()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Public Zoom API

    var effectiveZoomScale: CGFloat {
        isFitToWindow ? computeFitScale() : zoomScale
    }

    /// Returns the currently visible portion of the displayed image in normalized [0, 1] top-left coordinates.
    func visibleNormalizedRect() -> CGRect? {
        guard previewImage != nil else { return nil }
        let pageRect = currentPageRect()
        guard pageRect.width > 1, pageRect.height > 1 else { return nil }
        let inter = pageRect.intersection(bounds)
        if inter.isNull || inter.isEmpty { return nil }
        return CGRect(
            x: max(0, (inter.minX - pageRect.minX) / pageRect.width),
            y: max(0, (inter.minY - pageRect.minY) / pageRect.height),
            width: min(1, inter.width / pageRect.width),
            height: min(1, inter.height / pageRect.height)
        )
    }

    func zoomToFit() {
        isFitToWindow = true
        panOffset = .zero
        highResOverlayTile = nil
        needsDisplay = true
        notifyZoomChanged()
        scheduleViewportSettled()
        refreshCursorIfPointerInside()
    }

    func zoomToActualSize() {
        setZoom(1.0, anchorInView: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    func zoomIn() {
        let current = effectiveZoomScale
        let steps: [CGFloat] = [0.1, 0.15, 0.25, 0.33, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0, 8.0]
        let next = steps.first(where: { $0 > current * 1.05 }) ?? min(maxZoom, current * 1.35)
        setZoom(next, anchorInView: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    func zoomOut() {
        let current = effectiveZoomScale
        let fit = computeFitScale()
        let steps: [CGFloat] = [0.1, 0.15, 0.25, 0.33, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0, 8.0]
        if let prev = steps.last(where: { $0 < current * 0.95 }) {
            if prev <= fit * 1.02 {
                zoomToFit()
            } else {
                setZoom(prev, anchorInView: CGPoint(x: bounds.midX, y: bounds.midY))
            }
        } else {
            zoomToFit()
        }
    }

    private func setZoom(_ newScale: CGFloat, anchorInView anchor: CGPoint) {
        guard previewImage != nil else { return }
        let oldScale = effectiveZoomScale
        let clamped = max(minZoom, min(maxZoom, newScale))
        guard oldScale > 0 else { return }

        // Preserve image point under anchor
        let oldPage = currentPageRect()
        let relX = (anchor.x - oldPage.midX)
        let relY = (anchor.y - oldPage.midY)
        let ratio = clamped / oldScale

        isFitToWindow = false
        zoomScale = clamped
        panOffset = CGPoint(
            x: panOffset.x - relX * (ratio - 1.0),
            y: panOffset.y - relY * (ratio - 1.0)
        )
        clampPanOffset()
        highResOverlayTile = nil
        needsDisplay = true
        notifyZoomChanged()
        scheduleViewportSettled()
        refreshCursorIfPointerInside()
    }

    private func effectiveImagePixelSize() -> CGSize {
        if truePixelSize.width > 0 && truePixelSize.height > 0 {
            return truePixelSize
        }
        if let img = previewImage {
            return CGSize(width: img.width, height: img.height)
        }
        let rotated = (rotation == .deg90 || rotation == .deg270)
        let aspect = rotated ? (1.0 / max(0.1, platenAspectRatio)) : platenAspectRatio
        return CGSize(width: 1000 * aspect, height: 1000)
    }

    private func computeFitScale() -> CGFloat {
        let availW = max(1, bounds.width - canvasPadding * 2)
        let availH = max(1, bounds.height - canvasPadding * 2)
        let px = effectiveImagePixelSize()
        guard px.width > 0, px.height > 0 else { return 1.0 }
        return min(availW / px.width, availH / px.height)
    }

    private func currentPageRect() -> CGRect {
        let px = effectiveImagePixelSize()
        let scale = effectiveZoomScale
        let w = px.width * scale
        let h = px.height * scale
        let cx = bounds.midX + (isFitToWindow ? 0 : panOffset.x)
        let cy = bounds.midY + (isFitToWindow ? 0 : panOffset.y)
        return CGRect(
            x: (cx - w / 2.0).rounded(),
            y: (cy - h / 2.0).rounded(),
            width: max(1, w.rounded()),
            height: max(1, h.rounded())
        )
    }

    private func clampPanOffset() {
        if isFitToWindow {
            panOffset = .zero
            return
        }
        let px = effectiveImagePixelSize()
        let w = px.width * zoomScale
        let h = px.height * zoomScale
        let maxPanX = max(0, (w - (bounds.width - canvasPadding * 2)) / 2.0)
        let maxPanY = max(0, (h - (bounds.height - canvasPadding * 2)) / 2.0)
        panOffset.x = max(-maxPanX, min(maxPanX, panOffset.x))
        panOffset.y = max(-maxPanY, min(maxPanY, panOffset.y))
    }

    private func canPan() -> Bool {
        guard !isFitToWindow else { return false }
        let px = effectiveImagePixelSize()
        let w = px.width * zoomScale
        let h = px.height * zoomScale
        return w > bounds.width - canvasPadding * 2 || h > bounds.height - canvasPadding * 2
    }

    private func notifyZoomChanged() {
        onZoomChanged?(effectiveZoomScale, isFitToWindow)
    }

    private func scheduleViewportSettled() {
        settleWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.onViewportSettled?()
        }
        settleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: item)
    }

    // MARK: - Coordinate Mapping (Physical Platen <-> Displayed Rotated Space)

    private func physicalToDisplay(_ r: NormalizedCropRect) -> CGRect {
        let p1 = mapPointToDisplay(CGPoint(x: r.x, y: r.y))
        let p2 = mapPointToDisplay(CGPoint(x: r.x + r.width, y: r.y + r.height))
        let minX = min(p1.x, p2.x)
        let minY = min(p1.y, p2.y)
        return CGRect(x: minX, y: minY, width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
    }

    private func displayToPhysical(_ r: CGRect) -> NormalizedCropRect {
        let p1 = mapPointToPhysical(CGPoint(x: r.minX, y: r.minY))
        let p2 = mapPointToPhysical(CGPoint(x: r.maxX, y: r.maxY))
        let minX = min(p1.x, p2.x)
        let minY = min(p1.y, p2.y)
        return NormalizedCropRect(
            x: Double(minX),
            y: Double(minY),
            width: Double(abs(p2.x - p1.x)),
            height: Double(abs(p2.y - p1.y))
        ).clamped()
    }

    private func mapPointToDisplay(_ p: CGPoint) -> CGPoint {
        switch rotation {
        case .deg0: return p
        case .deg90: return CGPoint(x: 1.0 - p.y, y: p.x)
        case .deg180: return CGPoint(x: 1.0 - p.x, y: 1.0 - p.y)
        case .deg270: return CGPoint(x: p.y, y: 1.0 - p.x)
        }
    }

    private func mapPointToPhysical(_ p: CGPoint) -> CGPoint {
        switch rotation {
        case .deg0: return p
        case .deg90: return CGPoint(x: p.y, y: 1.0 - p.x)
        case .deg180: return CGPoint(x: 1.0 - p.x, y: 1.0 - p.y)
        case .deg270: return CGPoint(x: 1.0 - p.y, y: p.x)
        }
    }

    private func cropViewRect(in pageRect: CGRect) -> CGRect {
        let d = physicalToDisplay(cropRect)
        return CGRect(
            x: pageRect.minX + d.minX * pageRect.width,
            y: pageRect.minY + d.minY * pageRect.height,
            width: d.width * pageRect.width,
            height: d.height * pageRect.height
        )
    }

    private func handleCenter(_ handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    private func hitTestHandle(at point: CGPoint, cropViewRect: CGRect) -> Handle? {
        for handle in Handle.allCases {
            let c = handleCenter(handle, in: cropViewRect)
            if hypot(point.x - c.x, point.y - c.y) <= hitTolerance {
                return handle
            }
        }
        return nil
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: bounds)

        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()

        guard let img = previewImage else {
            drawEmptyState()
            return
        }

        let pageRect = currentPageRect()

        // Page shadow + crisp image render
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 14, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        NSColor.white.setFill()
        ctx.fill(pageRect)
        ctx.restoreGState()

        let interp: CGInterpolationQuality = effectiveZoomScale >= 2.0 ? .none : .high
        drawUpright(img, in: pageRect, context: ctx, interpolation: interp)

        // Optional crisp 1:1 high-res tile overlay when zoomed in
        if let tile = highResOverlayTile {
            let tileRect = CGRect(
                x: pageRect.minX + tile.normalizedRect.minX * pageRect.width,
                y: pageRect.minY + tile.normalizedRect.minY * pageRect.height,
                width: tile.normalizedRect.width * pageRect.width,
                height: tile.normalizedRect.height * pageRect.height
            )
            drawUpright(tile.image, in: tileRect, context: ctx, interpolation: interp)
        }

        guard showCropOverlay else { return }

        // Crop overlay
        let selRect = cropViewRect(in: pageRect)

        if !cropRect.isFull {
            ctx.saveGState()
            let maskPath = CGMutablePath()
            maskPath.addRect(pageRect)
            maskPath.addRect(selRect)
            ctx.addPath(maskPath)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }

        if case .move = dragMode { drawThirdsGrid(in: selRect, context: ctx) }
        if case .resize = dragMode { drawThirdsGrid(in: selRect, context: ctx) }
        if case .create = dragMode { drawThirdsGrid(in: selRect, context: ctx) }

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(selRect.insetBy(dx: 0.75, dy: 0.75))

        for handle in Handle.allCases {
            let c = handleCenter(handle, in: selRect)
            let dotRect = CGRect(
                x: c.x - handleRadius,
                y: c.y - handleRadius,
                width: handleRadius * 2,
                height: handleRadius * 2
            )
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: dotRect)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.75)
            ctx.strokeEllipse(in: dotRect)
        }
        ctx.restoreGState()
    }

    private func drawUpright(_ image: CGImage, in rect: CGRect, context ctx: CGContext, interpolation: CGInterpolationQuality) {
        ctx.saveGState()
        ctx.interpolationQuality = interpolation
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }

    private func drawThirdsGrid(in selRect: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(0.75)
        for frac in [CGFloat(1.0 / 3.0), CGFloat(2.0 / 3.0)] {
            let vx = selRect.minX + selRect.width * frac
            ctx.move(to: CGPoint(x: vx, y: selRect.minY))
            ctx.addLine(to: CGPoint(x: vx, y: selRect.maxY))
            let hy = selRect.minY + selRect.height * frac
            ctx.move(to: CGPoint(x: selRect.minX, y: hy))
            ctx.addLine(to: CGPoint(x: selRect.maxX, y: hy))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawEmptyState() {
        let iconSize: CGFloat = 46
        let centerX = bounds.midX
        let centerY = bounds.midY - 12

        if let sym = NSImage(systemSymbolName: "scanner", accessibilityDescription: "Scanner") {
            let cfg = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .light)
            let configured = sym.withSymbolConfiguration(cfg) ?? sym
            let tinted = configured.copy() as! NSImage
            tinted.isTemplate = true
            let drawRect = CGRect(x: centerX - 28, y: centerY - 56, width: 56, height: 56)
            NSColor.tertiaryLabelColor.set()
            tinted.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 0.55)
        }

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let title = NSAttributedString(string: emptyStateTitle, attributes: titleAttrs)
        let titleSize = title.size()
        title.draw(at: CGPoint(x: centerX - titleSize.width / 2, y: centerY + 8))

        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let sub = NSAttributedString(string: emptyStateSubtitle, attributes: subAttrs)
        let subSize = sub.size()
        sub.draw(at: CGPoint(x: centerX - subSize.width / 2, y: centerY + 32))
    }

    // MARK: - Gestures (Pinch to Zoom & Trackpad Pan / Cmd+Scroll Zoom)

    override func magnify(with event: NSEvent) {
        guard previewImage != nil else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let factor = max(0.5, min(2.0, 1.0 + event.magnification))
        let next = effectiveZoomScale * factor
        let fit = computeFitScale()
        if next <= fit * 1.01 && event.magnification < 0 {
            zoomToFit()
        } else {
            setZoom(next, anchorInView: pt)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard previewImage != nil else { return }
        if event.modifierFlags.contains(.command) {
            let pt = convert(event.locationInWindow, from: nil)
            let delta = event.scrollingDeltaY
            let factor = exp(delta * (event.hasPreciseScrollingDeltas ? 0.008 : 0.08))
            setZoom(effectiveZoomScale * factor, anchorInView: pt)
            return
        }
        guard canPan() else { return }
        let mult: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
        panOffset.x += event.scrollingDeltaX * mult
        panOffset.y += event.scrollingDeltaY * mult
        clampPanOffset()
        highResOverlayTile = nil
        needsDisplay = true
        scheduleViewportSettled()
        refreshCursorIfPointerInside()
    }

    // MARK: - Mouse Interaction

    func desiredCursor(at point: CGPoint) -> NSCursor {
        guard previewImage != nil, bounds.contains(point) else {
            return .arrow
        }
        if !showCropOverlay {
            return canPan() ? .openHand : .arrow
        }

        let pageRect = currentPageRect()
        let selRect = cropViewRect(in: pageRect)

        if let handle = hitTestHandle(at: point, cropViewRect: selRect) {
            return cursor(for: handle)
        } else if selRect.contains(point) && !cropRect.isFull {
            return .openHand
        } else if pageRect.contains(point) {
            return .crosshair
        } else {
            return .arrow
        }
    }

    private func isPointerOverCanvas(windowPoint: CGPoint, viewPoint: CGPoint) -> Bool {
        guard bounds.contains(viewPoint), visibleRect.contains(viewPoint) else { return false }
        guard let window, let rootView = window.contentView?.superview ?? window.contentView else {
            return true
        }
        let ptInRoot = rootView.superview?.convert(windowPoint, from: nil) ?? windowPoint
        guard let hit = rootView.hitTest(ptInRoot) else { return false }
        return hit === self || hit.isDescendant(of: self)
    }

    private func updateCursor(for event: NSEvent) {
        if isDragging { return }
        let windowPt = event.locationInWindow
        let pt = convert(windowPt, from: nil)
        guard isPointerOverCanvas(windowPoint: windowPt, viewPoint: pt) else {
            if hasCanvasCursor {
                NSCursor.arrow.set()
                hasCanvasCursor = false
            }
            return
        }
        let target = desiredCursor(at: pt)
        target.set()
        hasCanvasCursor = (target != .arrow)
    }

    private func refreshCursorIfPointerInside() {
        guard !isDragging, let window, window.isKeyWindow else { return }
        let windowPt = window.mouseLocationOutsideOfEventStream
        let pt = convert(windowPt, from: nil)
        guard isPointerOverCanvas(windowPoint: windowPt, viewPoint: pt) else { return }
        let target = desiredCursor(at: pt)
        target.set()
        hasCanvasCursor = (target != .arrow)
    }

    override func mouseEntered(with event: NSEvent) {
        updateCursor(for: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        if !isDragging {
            if hasCanvasCursor || NSCursor.current == .crosshair || NSCursor.current == .openHand || NSCursor.current == .closedHand {
                NSCursor.arrow.set()
            }
            hasCanvasCursor = false
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard previewImage != nil else { return }
        let pt = convert(event.locationInWindow, from: nil)

        // Double-click toggles Fit <-> 100% in Scan inspection mode
        if !showCropOverlay && event.clickCount == 2 {
            if isFitToWindow {
                setZoom(1.0, anchorInView: pt)
            } else {
                zoomToFit()
            }
            return
        }

        // Pan in Scan mode, or when Option-dragging in Preview mode while zoomed in
        if (!showCropOverlay || event.modifierFlags.contains(.option)) && canPan() {
            dragMode = .pan(startViewPoint: pt, initialPanOffset: panOffset)
            NSCursor.closedHand.set()
            hasCanvasCursor = true
            return
        }

        guard showCropOverlay else {
            dragMode = .none
            return
        }

        let pageRect = currentPageRect()
        let selRect = cropViewRect(in: pageRect)
        let displayNorm = physicalToDisplay(cropRect)

        if let handle = hitTestHandle(at: pt, cropViewRect: selRect) {
            dragMode = .resize(handle: handle, startDisplayPoint: pt, initialDisplayRect: displayNorm)
            cursor(for: handle).set()
            hasCanvasCursor = true
        } else if selRect.contains(pt) && !cropRect.isFull {
            dragMode = .move(startDisplayPoint: pt, initialDisplayRect: displayNorm)
            NSCursor.closedHand.set()
            hasCanvasCursor = true
        } else if pageRect.contains(pt) {
            let nx = max(0, min(1, (pt.x - pageRect.minX) / pageRect.width))
            let ny = max(0, min(1, (pt.y - pageRect.minY) / pageRect.height))
            dragMode = .create(anchorNorm: CGPoint(x: nx, y: ny))
            NSCursor.crosshair.set()
            hasCanvasCursor = true
        } else {
            dragMode = .none
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard previewImage != nil else { return }
        let pt = convert(event.locationInWindow, from: nil)

        if case let .pan(startPt, initPan) = dragMode {
            panOffset = CGPoint(
                x: initPan.x + (pt.x - startPt.x),
                y: initPan.y + (pt.y - startPt.y)
            )
            clampPanOffset()
            highResOverlayTile = nil
            needsDisplay = true
            return
        }

        let pageRect = currentPageRect()
        guard pageRect.width > 1, pageRect.height > 1 else { return }

        let minFrac: CGFloat = 0.03
        var newDisplayRect: CGRect?

        switch dragMode {
        case .none, .pan:
            break

        case .move(let startPt, let initRect):
            let dx = (pt.x - startPt.x) / pageRect.width
            let dy = (pt.y - startPt.y) / pageRect.height
            let nx = max(0, min(1 - initRect.width, initRect.minX + dx))
            let ny = max(0, min(1 - initRect.height, initRect.minY + dy))
            newDisplayRect = CGRect(x: nx, y: ny, width: initRect.width, height: initRect.height)

        case .resize(let handle, let startPt, let initRect):
            let dx = (pt.x - startPt.x) / pageRect.width
            let dy = (pt.y - startPt.y) / pageRect.height
            var minX = initRect.minX
            var minY = initRect.minY
            var maxX = initRect.maxX
            var maxY = initRect.maxY

            switch handle {
            case .topLeft:
                minX = max(0, min(maxX - minFrac, minX + dx))
                minY = max(0, min(maxY - minFrac, minY + dy))
            case .top:
                minY = max(0, min(maxY - minFrac, minY + dy))
            case .topRight:
                maxX = min(1, max(minX + minFrac, maxX + dx))
                minY = max(0, min(maxY - minFrac, minY + dy))
            case .left:
                minX = max(0, min(maxX - minFrac, minX + dx))
            case .right:
                maxX = min(1, max(minX + minFrac, maxX + dx))
            case .bottomLeft:
                minX = max(0, min(maxX - minFrac, minX + dx))
                maxY = min(1, max(minY + minFrac, maxY + dy))
            case .bottom:
                maxY = min(1, max(minY + minFrac, maxY + dy))
            case .bottomRight:
                maxX = min(1, max(minX + minFrac, maxX + dx))
                maxY = min(1, max(minY + minFrac, maxY + dy))
            }
            newDisplayRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        case .create(let anchor):
            let nx = max(0, min(1, (pt.x - pageRect.minX) / pageRect.width))
            let ny = max(0, min(1, (pt.y - pageRect.minY) / pageRect.height))
            let minX = min(anchor.x, nx)
            let minY = min(anchor.y, ny)
            let w = max(minFrac, abs(nx - anchor.x))
            let h = max(minFrac, abs(ny - anchor.y))
            newDisplayRect = CGRect(x: minX, y: minY, width: min(1 - minX, w), height: min(1 - minY, h))
        }

        if let r = newDisplayRect {
            cropRect = displayToPhysical(r)
            onCropChanged?(cropRect)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let wasPan = {
            if case .pan = dragMode { return true }
            return false
        }()
        dragMode = .none
        needsDisplay = true
        if wasPan {
            scheduleViewportSettled()
        }
        updateCursor(for: event)
    }

    private func cursor(for handle: Handle) -> NSCursor {
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return .crosshair
        }
    }
}
