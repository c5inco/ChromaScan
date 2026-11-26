import SwiftUI
import UIKit

/// High-frame-rate (120 Hz ProMotion) Display P3 canvas backed by `UIScrollView` + `UIImageView`,
/// supporting rotation-aware touch crop handles in Preview mode and on-demand 1:1 tiles in Scan mode.
struct RemoteCanvasView: UIViewRepresentable {
    let image: UIImage?
    let truePixelSize: CGSize
    let tileImage: UIImage?
    let tileNormalizedRect: NormalizedCropRect?
    let isLoadingTile: Bool
    let showCropOverlay: Bool
    let cropRect: NormalizedCropRect
    let rotation: ScanRotation
    let topContentPadding: CGFloat
    let onCropChanged: (_ rect: NormalizedCropRect, _ isFinal: Bool) -> Void
    let onRequestTile: (_ normalizedRect: NormalizedCropRect, _ maxPixelWidth: Int) -> Void
    let onClearTile: () -> Void

    func makeUIView(context: Context) -> RemoteCanvasUIView {
        let view = RemoteCanvasUIView()
        view.onCropChanged = onCropChanged
        view.onRequestTile = onRequestTile
        view.onClearTile = onClearTile
        return view
    }

    func updateUIView(_ uiView: RemoteCanvasUIView, context: Context) {
        uiView.onCropChanged = onCropChanged
        uiView.onRequestTile = onRequestTile
        uiView.onClearTile = onClearTile
        uiView.update(
            image: image,
            truePixelSize: truePixelSize,
            tileImage: tileImage,
            tileNormalizedRect: tileNormalizedRect,
            isLoadingTile: isLoadingTile,
            showCropOverlay: showCropOverlay,
            cropRect: cropRect,
            rotation: rotation,
            topContentPadding: topContentPadding
        )
    }
}

// MARK: - UIKit Scroll + Tile + Touch Crop Container

@MainActor
final class RemoteCanvasUIView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var onCropChanged: ((_ rect: NormalizedCropRect, _ isFinal: Bool) -> Void)?
    var onRequestTile: ((_ normalizedRect: NormalizedCropRect, _ maxPixelWidth: Int) -> Void)?
    var onClearTile: (() -> Void)?

    private let scrollView = UIScrollView()
    private let pageContainer = UIView()
    private let proxyImageView = UIImageView()
    private let tileImageView = UIImageView()
    private let cropOverlay = TouchCropOverlayView()
    private let zoomBadge = UILabel()
    private lazy var cropPanGesture: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleCropPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        return pan
    }()

    private var currentImage: UIImage?
    private var truePixelSize: CGSize = .zero
    private var showCropOverlay: Bool = true
    private var topContentPadding: CGFloat = 68
    private var lastBaseImageSize: CGSize = .zero
    private var lastLayoutBounds: CGSize = .zero
    private var settleWorkItem: DispatchWorkItem?
    private var badgeHideWorkItem: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        backgroundColor = .clear
        clipsToBounds = true

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 12.0
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .normal
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)

        pageContainer.backgroundColor = .white
        pageContainer.layer.shadowColor = UIColor.black.cgColor
        pageContainer.layer.shadowOpacity = 0.35
        pageContainer.layer.shadowRadius = 14
        pageContainer.layer.shadowOffset = CGSize(width: 0, height: 4)
        scrollView.addSubview(pageContainer)

        proxyImageView.contentMode = .scaleToFill
        proxyImageView.clipsToBounds = true
        pageContainer.addSubview(proxyImageView)

        tileImageView.contentMode = .scaleToFill
        tileImageView.clipsToBounds = true
        tileImageView.isHidden = true
        pageContainer.addSubview(tileImageView)

        cropOverlay.isUserInteractionEnabled = false
        cropOverlay.onCropChanged = { [weak self] rect, isFinal in
            self?.onCropChanged?(rect, isFinal)
        }
        addSubview(cropOverlay)

        // Attach single-finger crop pan directly to scrollView so 2-finger pinch-to-zoom
        // and double-tap zoom always reach scrollView even inside a trimmed marquee.
        scrollView.addGestureRecognizer(cropPanGesture)
        scrollView.panGestureRecognizer.require(toFail: cropPanGesture)

        zoomBadge.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        zoomBadge.textColor = .white
        zoomBadge.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        zoomBadge.textAlignment = .center
        zoomBadge.layer.cornerRadius = 11
        zoomBadge.clipsToBounds = true
        zoomBadge.alpha = 0
        addSubview(zoomBadge)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        cropOverlay.frame = bounds

        if bounds.size != lastLayoutBounds {
            lastLayoutBounds = bounds.size
            relayoutPage(resetZoom: true)
        } else {
            centerContent()
            syncCropOverlayPageFrame()
        }

        zoomBadge.sizeToFit()
        let bw = max(56, zoomBadge.bounds.width + 18)
        let bh: CGFloat = 22
        zoomBadge.frame = CGRect(x: bounds.width - bw - 14, y: bounds.height - bh - 12, width: bw, height: bh)
    }

    func update(
        image: UIImage?,
        truePixelSize: CGSize,
        tileImage: UIImage?,
        tileNormalizedRect: NormalizedCropRect?,
        isLoadingTile: Bool,
        showCropOverlay: Bool,
        cropRect: NormalizedCropRect,
        rotation: ScanRotation,
        topContentPadding: CGFloat
    ) {
        let imageChanged = (image !== currentImage)
        let imageAspectChanged = image?.size != lastBaseImageSize
        let modeChanged = (showCropOverlay != self.showCropOverlay)
        let paddingChanged = abs(topContentPadding - self.topContentPadding) > 0.5

        self.currentImage = image
        self.truePixelSize = truePixelSize
        self.showCropOverlay = showCropOverlay
        self.topContentPadding = topContentPadding

        proxyImageView.image = image
        pageContainer.isHidden = (image == nil)
        cropOverlay.isHidden = !showCropOverlay || image == nil
        cropOverlay.rotation = rotation
        if !cropOverlay.isDragging {
            cropOverlay.cropRect = cropRect
        }

        if imageChanged || imageAspectChanged || modeChanged || paddingChanged {
            lastBaseImageSize = image?.size ?? .zero
            relayoutPage(resetZoom: imageAspectChanged || modeChanged)
        } else {
            updateMaxZoomScale()
            syncCropOverlayPageFrame()
        }

        // Update 1:1 tile overlay
        if let tileImage, let norm = tileNormalizedRect, !showCropOverlay {
            tileImageView.image = tileImage
            let b = pageContainer.bounds
            tileImageView.frame = CGRect(
                x: CGFloat(norm.x) * b.width,
                y: CGFloat(norm.y) * b.height,
                width: CGFloat(norm.width) * b.width,
                height: CGFloat(norm.height) * b.height
            )
            tileImageView.isHidden = false
            updateZoomBadge(hasTile: true, loading: false)
        } else {
            tileImageView.image = nil
            tileImageView.isHidden = true
            if isLoadingTile {
                updateZoomBadge(hasTile: false, loading: true)
            }
        }
    }

    private func relayoutPage(resetZoom: Bool) {
        guard let image = currentImage,
              image.size.width > 0,
              image.size.height > 0,
              bounds.width > 20,
              bounds.height > 20 else {
            syncCropOverlayPageFrame()
            return
        }

        let topPadding = topContentPadding
        let sidePadding: CGFloat = 18
        let bottomPadding: CGFloat = 18
        let availW = max(1, bounds.width - sidePadding * 2)
        let availH = max(1, bounds.height - topPadding - bottomPadding)
        let scale = min(availW / image.size.width, availH / image.size.height)
        let pageW = (image.size.width * scale).rounded()
        let pageH = (image.size.height * scale).rounded()

        let previousZoom = scrollView.zoomScale
        scrollView.zoomScale = 1.0
        pageContainer.frame = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        proxyImageView.frame = pageContainer.bounds
        scrollView.contentSize = pageContainer.bounds.size

        updateMaxZoomScale()
        if !resetZoom {
            scrollView.zoomScale = min(scrollView.maximumZoomScale, max(1.0, previousZoom))
        }
        centerContent(resetOffsetIfUnzoomed: resetZoom || scrollView.zoomScale <= 1.02)
        syncCropOverlayPageFrame()
    }

    private func updateMaxZoomScale() {
        let baseW = max(1, pageContainer.bounds.width)
        let screenScale = window?.screen.scale ?? 3.0
        let trueW = truePixelSize.width > 0 ? truePixelSize.width : (currentImage?.size.width ?? baseW)
        let oneToOneScale = trueW / (baseW * screenScale)
        scrollView.maximumZoomScale = max(4.0, min(28.0, oneToOneScale * 3.0))
    }

    private func centerContent(resetOffsetIfUnzoomed: Bool = false) {
        let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) * 0.5, 0)
        if scrollView.zoomScale <= 1.02 {
            let topPad = topContentPadding
            let bottomPad: CGFloat = 18
            let availH = max(0, scrollView.bounds.height - topPad - bottomPad)
            let extra = max(0, (availH - scrollView.contentSize.height) * 0.5)
            scrollView.contentInset = UIEdgeInsets(top: topPad + extra, left: offsetX, bottom: bottomPad + extra, right: offsetX)
            if resetOffsetIfUnzoomed {
                scrollView.contentOffset = CGPoint(x: -scrollView.contentInset.left, y: -scrollView.contentInset.top)
            }
        } else {
            let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) * 0.5, 0)
            scrollView.contentInset = UIEdgeInsets(top: offsetY, left: offsetX, bottom: offsetY, right: offsetX)
        }
    }

    private func syncCropOverlayPageFrame() {
        guard !pageContainer.isHidden else {
            cropOverlay.pageFrame = .zero
            return
        }
        cropOverlay.pageFrame = pageContainer.convert(pageContainer.bounds, to: cropOverlay)
    }

    // MARK: - Gestures & UIScrollViewDelegate

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, pan === cropPanGesture else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        guard !cropOverlay.isHidden,
              cropOverlay.pageFrame.width > 10,
              cropOverlay.pageFrame.height > 10,
              pan.numberOfTouches == 1 else {
            return false
        }
        let loc = pan.location(in: cropOverlay)
        let trans = pan.translation(in: cropOverlay)
        let startPt = CGPoint(x: loc.x - trans.x, y: loc.y - trans.y)
        // Always allow dragging any of the 8 crop handles (even while zoomed in).
        // Only allow moving the trimmed marquee with 1 finger when unzoomed, so zoomed
        // 1-finger panning and 2-finger pinch-to-zoom work freely inside the trimmed box.
        return cropOverlay.canBeginDrag(at: startPt, allowMove: scrollView.zoomScale <= 1.02)
    }

    @objc private func handleCropPan(_ gesture: UIPanGestureRecognizer) {
        cropOverlay.handleExternalPan(gesture, allowMove: scrollView.zoomScale <= 1.02)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard currentImage != nil else { return }
        if scrollView.zoomScale > 1.05 {
            scrollView.setZoomScale(1.0, animated: true)
            onClearTile?()
        } else {
            let pt = gesture.location(in: pageContainer)
            let screenScale = window?.screen.scale ?? 3.0
            let baseW = max(1, pageContainer.bounds.width)
            let trueW = truePixelSize.width > 0 ? truePixelSize.width : (currentImage?.size.width ?? baseW)
            let targetScale = min(scrollView.maximumZoomScale, max(2.5, trueW / (baseW * screenScale)))
            let w = scrollView.bounds.width / targetScale
            let h = scrollView.bounds.height / targetScale
            let zoomRect = CGRect(x: pt.x - w / 2, y: pt.y - h / 2, width: w, height: h)
            scrollView.zoom(to: zoomRect, animated: true)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        pageContainer
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        syncCropOverlayPageFrame()
        if !tileImageView.isHidden {
            tileImageView.isHidden = true
        }
        updateZoomBadge(hasTile: false, loading: false)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        syncCropOverlayPageFrame()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        scheduleViewportSettled()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scheduleViewportSettled()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scheduleViewportSettled()
    }

    private func scheduleViewportSettled() {
        settleWorkItem?.cancel()
        guard !showCropOverlay, let proxy = currentImage, truePixelSize.width > proxy.size.width else {
            return
        }

        let item = DispatchWorkItem { [weak self] in
            self?.requestTileIfNeeded()
        }
        settleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: item)
    }

    private func requestTileIfNeeded() {
        guard !showCropOverlay,
              let proxy = currentImage,
              truePixelSize.width > proxy.size.width else {
            onClearTile?()
            return
        }

        let pageFrameInSelf = pageContainer.convert(pageContainer.bounds, to: self)
        let visible = pageFrameInSelf.intersection(bounds)
        guard !visible.isNull, visible.width > 4, visible.height > 4, pageFrameInSelf.width > 1, pageFrameInSelf.height > 1 else {
            return
        }

        let screenScale = window?.screen.scale ?? 3.0
        let displayedFullWidthPx = pageFrameInSelf.width * screenScale
        guard displayedFullWidthPx > proxy.size.width * 1.05 else {
            onClearTile?()
            return
        }

        let pad: CGFloat = 0.015
        let nx = max(0, (visible.minX - pageFrameInSelf.minX) / pageFrameInSelf.width - pad)
        let ny = max(0, (visible.minY - pageFrameInSelf.minY) / pageFrameInSelf.height - pad)
        let maxX = min(1, (visible.maxX - pageFrameInSelf.minX) / pageFrameInSelf.width + pad)
        let maxY = min(1, (visible.maxY - pageFrameInSelf.minY) / pageFrameInSelf.height + pad)

        let normRect = NormalizedCropRect(
            x: Double(nx),
            y: Double(ny),
            width: Double(max(0.01, maxX - nx)),
            height: Double(max(0.01, maxY - ny))
        )
        let maxPixelWidth = Int((bounds.width * screenScale * 1.15).rounded())
        onRequestTile?(normRect, maxPixelWidth)
    }

    private func updateZoomBadge(hasTile: Bool, loading: Bool) {
        let baseW = max(1, pageContainer.bounds.width)
        let screenScale = window?.screen.scale ?? 3.0
        let trueW = truePixelSize.width > 0 ? truePixelSize.width : (currentImage?.size.width ?? baseW)
        let effectivePct = max(1, Int(((baseW * scrollView.zoomScale * screenScale) / max(1, trueW) * 100.0).rounded()))

        if scrollView.zoomScale <= 1.02 {
            zoomBadge.alpha = 0
            return
        }

        if hasTile {
            zoomBadge.text = "\(effectivePct)% · 1:1"
        } else if loading {
            zoomBadge.text = "\(effectivePct)% · HD…"
        } else {
            zoomBadge.text = "\(effectivePct)%"
        }
        setNeedsLayout()

        UIView.animate(withDuration: 0.15) {
            self.zoomBadge.alpha = 1
        }
        badgeHideWorkItem?.cancel()
        if !loading {
            let hide = DispatchWorkItem { [weak self] in
                UIView.animate(withDuration: 0.25) {
                    self?.zoomBadge.alpha = 0
                }
            }
            badgeHideWorkItem = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: hide)
        }
    }
}

// MARK: - Touch-Friendly Rotation-Aware Crop Overlay

@MainActor
private final class TouchCropOverlayView: UIView {
    var onCropChanged: ((_ rect: NormalizedCropRect, _ isFinal: Bool) -> Void)?

    var pageFrame: CGRect = .zero {
        didSet {
            if pageFrame != oldValue { setNeedsDisplay() }
        }
    }

    var cropRect: NormalizedCropRect = .full {
        didSet {
            if cropRect != oldValue { setNeedsDisplay() }
        }
    }

    var rotation: ScanRotation = .deg0 {
        didSet {
            if rotation != oldValue { setNeedsDisplay() }
        }
    }

    private enum Handle: CaseIterable {
        case topLeft, top, topRight
        case left, right
        case bottomLeft, bottom, bottomRight
    }

    private enum DragMode {
        case none
        case move(startPoint: CGPoint, initialDisplayRect: CGRect)
        case resize(handle: Handle, startPoint: CGPoint, initialDisplayRect: CGRect)
    }

    private var dragMode: DragMode = .none
    private let hitRadius: CGFloat = 24.0 // 48pt touch target diameter

    var isDragging: Bool {
        if case .none = dragMode { return false }
        return true
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func canBeginDrag(at point: CGPoint, allowMove: Bool) -> Bool {
        guard !isHidden, pageFrame.width > 10, pageFrame.height > 10 else { return false }
        let selRect = currentSelectionRect()
        if hitTestHandle(at: point, selRect: selRect) != nil {
            return true
        }
        if allowMove && !cropRect.isFull && selRect.contains(point) {
            return true
        }
        return false
    }

    func handleExternalPan(_ gesture: UIPanGestureRecognizer, allowMove: Bool) {
        guard pageFrame.width > 10, pageFrame.height > 10 else { return }
        let pt = gesture.location(in: self)

        switch gesture.state {
        case .began:
            let trans = gesture.translation(in: self)
            let startPt = CGPoint(x: pt.x - trans.x, y: pt.y - trans.y)
            let selRect = currentSelectionRect()
            let displayNorm = cropRect.physicalToDisplay(rotation: rotation)
            if let handle = hitTestHandle(at: startPt, selRect: selRect) {
                dragMode = .resize(handle: handle, startPoint: startPt, initialDisplayRect: displayNorm)
            } else if allowMove && !cropRect.isFull && selRect.contains(startPt) {
                dragMode = .move(startPoint: startPt, initialDisplayRect: displayNorm)
            } else {
                dragMode = .none
            }
            applyDrag(to: pt, isFinal: false)
            setNeedsDisplay()

        case .changed:
            applyDrag(to: pt, isFinal: false)

        case .ended:
            applyDrag(to: pt, isFinal: true)
            dragMode = .none
            setNeedsDisplay()

        case .cancelled, .failed:
            dragMode = .none
            setNeedsDisplay()

        default:
            break
        }
    }

    private func currentSelectionRect() -> CGRect {
        let d = cropRect.physicalToDisplay(rotation: rotation)
        return CGRect(
            x: pageFrame.minX + d.minX * pageFrame.width,
            y: pageFrame.minY + d.minY * pageFrame.height,
            width: d.width * pageFrame.width,
            height: d.height * pageFrame.height
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

    private func hitTestHandle(at pt: CGPoint, selRect: CGRect) -> Handle? {
        var best: (Handle, CGFloat)?
        for h in Handle.allCases {
            let c = handleCenter(h, in: selRect)
            let d = hypot(pt.x - c.x, pt.y - c.y)
            if d <= hitRadius {
                if best == nil || d < best!.1 {
                    best = (h, d)
                }
            }
        }
        return best?.0
    }

    private func applyDrag(to pt: CGPoint, isFinal: Bool) {
        let minFrac: CGFloat = 0.04
        var newDisplayRect: CGRect?

        switch dragMode {
        case .none:
            return

        case .move(let startPt, let initRect):
            let dx = (pt.x - startPt.x) / pageFrame.width
            let dy = (pt.y - startPt.y) / pageFrame.height
            let nx = max(0, min(1 - initRect.width, initRect.minX + dx))
            let ny = max(0, min(1 - initRect.height, initRect.minY + dy))
            newDisplayRect = CGRect(x: nx, y: ny, width: initRect.width, height: initRect.height)

        case .resize(let handle, let startPt, let initRect):
            let dx = (pt.x - startPt.x) / pageFrame.width
            let dy = (pt.y - startPt.y) / pageFrame.height
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
        }

        if let r = newDisplayRect {
            let physical = NormalizedCropRect.fromDisplayRect(r, rotation: rotation)
            cropRect = physical
            onCropChanged?(physical, isFinal)
        }
    }

    override func draw(_ rect: CGRect) {
        guard pageFrame.width > 10, pageFrame.height > 10,
              let ctx = UIGraphicsGetCurrentContext() else { return }

        let selRect = currentSelectionRect()

        // Dim exterior when cropped
        if !cropRect.isFull {
            ctx.saveGState()
            let maskPath = CGMutablePath()
            maskPath.addRect(pageFrame)
            maskPath.addRect(selRect)
            ctx.addPath(maskPath)
            ctx.setFillColor(UIColor.black.withAlphaComponent(0.48).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }

        // Rule of thirds while dragging
        if isDragging {
            ctx.saveGState()
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.5).cgColor)
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

        // Border
        ctx.saveGState()
        ctx.setStrokeColor(ChromaTheme.creamUI.cgColor)
        ctx.setLineWidth(2.0)
        ctx.stroke(selRect)

        // Crisp circular touch handles with white fill + vermilion ring (matching Android)
        let radius: CGFloat = 7.5
        for handle in Handle.allCases {
            let c = handleCenter(handle, in: selRect)
            let dot = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillEllipse(in: dot)
            ctx.setStrokeColor(ChromaTheme.vermilionUI.cgColor)
            ctx.setLineWidth(2.25)
            ctx.strokeEllipse(in: dot)
        }
        ctx.restoreGState()
    }
}
