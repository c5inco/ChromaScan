import AppKit
import QuartzCore

/// Native bottom status bar displaying crop/zoom controls, dimensions, live progress, and cancel/reveal actions.
@MainActor
final class StatusFooterView: NSView {
    var onTrimEmptySpace: (() -> Void)?
    var onResetCrop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRevealLastSaved: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomFit: (() -> Void)?
    var onZoomActualSize: (() -> Void)?

    private let trimEmptySpaceButton = NSButton(title: "Trim Space", target: nil, action: nil)
    private let fullPageButton = NSButton(title: "Full Page", target: nil, action: nil)
    private let dimensionsLabel = NSTextField(labelWithString: "")

    // Zoom controls
    private let zoomOutButton = NSButton()
    private let zoomFitButton = NSButton(title: "Fit", target: nil, action: nil)
    private let zoomInButton = NSButton()
    private let zoomActualButton = NSButton(title: "100%", target: nil, action: nil)
    private let zoomDivider = NSBox()

    // Status / progress
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let revealButton = NSButton(title: "Reveal", target: nil, action: nil)
    private let progressBar = PigmentProgressBarView()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }

    private func setupUI() {
        wantsLayer = true
        clipsToBounds = true

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        trimEmptySpaceButton.bezelStyle = .rounded
        trimEmptySpaceButton.controlSize = .small
        trimEmptySpaceButton.image = NSImage(systemSymbolName: "crop", accessibilityDescription: "Trim Empty Space")
        trimEmptySpaceButton.imagePosition = .imageLeading
        trimEmptySpaceButton.toolTip = "Auto-detect and trim empty space (⇧⌘T)"
        trimEmptySpaceButton.target = self
        trimEmptySpaceButton.action = #selector(trimEmptySpaceClicked)
        trimEmptySpaceButton.isHidden = true

        fullPageButton.bezelStyle = .rounded
        fullPageButton.controlSize = .small
        fullPageButton.target = self
        fullPageButton.action = #selector(resetCropClicked)

        // Zoom controls
        zoomOutButton.bezelStyle = .rounded
        zoomOutButton.controlSize = .small
        zoomOutButton.image = NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "Zoom Out")
        zoomOutButton.toolTip = "Zoom Out (⌘-)"
        zoomOutButton.target = self
        zoomOutButton.action = #selector(zoomOutClicked)

        zoomFitButton.bezelStyle = .rounded
        zoomFitButton.controlSize = .small
        zoomFitButton.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomFitButton.toolTip = "Zoom to Fit (⌘0)"
        zoomFitButton.target = self
        zoomFitButton.action = #selector(zoomFitClicked)

        zoomInButton.bezelStyle = .rounded
        zoomInButton.controlSize = .small
        zoomInButton.image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Zoom In")
        zoomInButton.toolTip = "Zoom In (⌘+)"
        zoomInButton.target = self
        zoomInButton.action = #selector(zoomInClicked)

        zoomActualButton.bezelStyle = .rounded
        zoomActualButton.controlSize = .small
        zoomActualButton.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomActualButton.toolTip = "Actual Size 100% (⌘1)"
        zoomActualButton.target = self
        zoomActualButton.action = #selector(zoomActualClicked)

        zoomDivider.boxType = .separator
        zoomDivider.translatesAutoresizingMaskIntoConstraints = false
        zoomDivider.heightAnchor.constraint(equalToConstant: 16).isActive = true

        dimensionsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        dimensionsLabel.textColor = .secondaryLabelColor
        dimensionsLabel.lineBreakMode = .byTruncatingTail
        dimensionsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        statusLabel.textColor = .labelColor
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        revealButton.bezelStyle = .rounded
        revealButton.controlSize = .small
        revealButton.target = self
        revealButton.action = #selector(revealClicked)
        revealButton.isHidden = true

        progressBar.isHidden = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.isHidden = true

        let zoomStack = NSStackView(views: [zoomOutButton, zoomFitButton, zoomInButton, zoomActualButton])
        zoomStack.orientation = .horizontal
        zoomStack.spacing = 4
        zoomStack.alignment = .centerY

        let leftStack = NSStackView(views: [zoomStack, zoomDivider, trimEmptySpaceButton, fullPageButton, dimensionsLabel])
        leftStack.orientation = .horizontal
        leftStack.spacing = 8
        leftStack.alignment = .centerY
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let rightStack = NSStackView(views: [statusLabel, revealButton, progressBar, cancelButton])
        rightStack.orientation = .horizontal
        rightStack.spacing = 8
        rightStack.alignment = .centerY
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(leftStack)
        addSubview(rightStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),

            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            leftStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            leftStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            rightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            rightStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightStack.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 12),

            progressBar.widthAnchor.constraint(equalToConstant: 116),
            progressBar.heightAnchor.constraint(equalToConstant: 6)
        ])

        setZoomEnabled(false)
    }

    func setZoomEnabled(_ enabled: Bool) {
        zoomOutButton.isEnabled = enabled
        zoomFitButton.isEnabled = enabled
        zoomInButton.isEnabled = enabled
        zoomActualButton.isEnabled = enabled
    }

    func updateZoom(effectiveScale: CGFloat, isFit: Bool) {
        let pct = max(1, Int((effectiveScale * 100.0).rounded()))
        zoomFitButton.title = isFit ? "Fit (\(pct)%)" : "\(pct)%"
    }

    func updateTrimControls(
        showingScan: Bool,
        hasImage: Bool,
        isCropFull: Bool,
        isScanTrimmed: Bool,
        isTrimHiddenAfterTrim: Bool = false,
        isBusy: Bool
    ) {
        if showingScan || isBusy {
            trimEmptySpaceButton.isHidden = true
            fullPageButton.isHidden = true
        } else {
            trimEmptySpaceButton.isHidden = !hasImage || isTrimHiddenAfterTrim
            trimEmptySpaceButton.isEnabled = hasImage
            fullPageButton.isHidden = !hasImage || isCropFull
            fullPageButton.isEnabled = !isCropFull
        }
    }

    func updateDimensions(
        widthInches: Double,
        heightInches: Double,
        pixelWidth: Int,
        pixelHeight: Int,
        estimatedRawBytes: Int64,
        isFullPage: Bool
    ) {
        let mb = Double(estimatedRawBytes) / (1024.0 * 1024.0)
        let sizeStr = mb >= 10.0 ? String(format: "%.0f MB", mb) : String(format: "%.1f MB", mb)
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        let pw = nf.string(from: NSNumber(value: pixelWidth)) ?? "\(pixelWidth)"
        let ph = nf.string(from: NSNumber(value: pixelHeight)) ?? "\(pixelHeight)"
        dimensionsLabel.stringValue = String(format: "%.2f\"×%.2f\" · %@×%@ (%@)", widthInches, heightInches, pw, ph, sizeStr)
    }

    func updateScanDimensions(pixelWidth: Int, pixelHeight: Int, dpi: Int, profileName: String, isTrimmed: Bool = false) {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        let pw = nf.string(from: NSNumber(value: pixelWidth)) ?? "\(pixelWidth)"
        let ph = nf.string(from: NSNumber(value: pixelHeight)) ?? "\(pixelHeight)"
        let trimSuffix = isTrimmed ? " · Trimmed" : ""
        dimensionsLabel.stringValue = "\(pw)×\(ph) px · \(dpi) DPI · \(profileName)\(trimSuffix)"
    }

    func setIdle(status: String, showReveal: Bool) {
        statusLabel.stringValue = status
        statusLabel.textColor = .secondaryLabelColor
        progressBar.stop()
        progressBar.isHidden = true
        cancelButton.isHidden = true
        revealButton.isHidden = !showReveal
    }

    func setError(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
        progressBar.stop()
        progressBar.isHidden = true
        cancelButton.isHidden = true
        revealButton.isHidden = true
    }

    func setProgress(status: String, fraction: Double?) {
        statusLabel.stringValue = status
        statusLabel.textColor = .labelColor
        revealButton.isHidden = true
        cancelButton.isHidden = false
        progressBar.isHidden = false
        progressBar.setFraction(fraction)
    }

    @objc private func trimEmptySpaceClicked() { onTrimEmptySpace?() }
    @objc private func resetCropClicked() { onResetCrop?() }
    @objc private func cancelClicked() { onCancel?() }
    @objc private func revealClicked() { onRevealLastSaved?() }
    @objc private func zoomOutClicked() { onZoomOut?() }
    @objc private func zoomInClicked() { onZoomIn?() }
    @objc private func zoomFitClicked() { onZoomFit?() }
    @objc private func zoomActualClicked() { onZoomActualSize?() }
}

// MARK: - Vermilion-to-Cyan Capsule Progress Bar (Matches iOS & Live Activity)

@MainActor
private final class PigmentProgressBarView: NSView {
    private let trackLayer = CALayer()
    private let fillLayer = CAGradientLayer()

    private var currentFraction: Double?
    private var isAnimatingIndeterminate = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.masksToBounds = false

        trackLayer.masksToBounds = true
        layer?.addSublayer(trackLayer)

        fillLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
        fillLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        trackLayer.addSublayer(fillLayer)

        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Operation progress")
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds
        trackLayer.cornerRadius = bounds.height / 2.0
        fillLayer.cornerRadius = bounds.height / 2.0
        CATransaction.commit()
        applyFillLayout(animated: false)
    }

    func setFraction(_ fraction: Double?) {
        currentFraction = fraction.map { max(0.0, min(1.0, $0)) }
        if let f = currentFraction {
            setAccessibilityValue(Int((f * 100.0).rounded()))
        } else {
            setAccessibilityValue(nil)
        }
        applyFillLayout(animated: true)
    }

    func stop() {
        currentFraction = nil
        isAnimatingIndeterminate = false
        fillLayer.removeAnimation(forKey: "indeterminateSweep")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = CGRect(x: 0, y: 0, width: 0, height: bounds.height)
        CATransaction.commit()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            trackLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
            let vermilion = ChromaTheme.vermilionNS.cgColor
            let cyan = NSColor.systemCyan.cgColor
            fillLayer.colors = [vermilion, cyan]
        }
    }

    private func applyFillLayout(animated: Bool) {
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return }

        if let fraction = currentFraction {
            if isAnimatingIndeterminate {
                isAnimatingIndeterminate = false
                fillLayer.removeAnimation(forKey: "indeterminateSweep")
            }
            let targetWidth = fraction > 0 ? max(height, width * CGFloat(fraction)) : 0
            CATransaction.begin()
            CATransaction.setDisableActions(!animated)
            CATransaction.setAnimationDuration(0.18)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            fillLayer.opacity = 1.0
            fillLayer.frame = CGRect(x: 0, y: 0, width: targetWidth, height: height)
            CATransaction.commit()
        } else if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            isAnimatingIndeterminate = false
            fillLayer.removeAnimation(forKey: "indeterminateSweep")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fillLayer.opacity = 0.72
            fillLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
            CATransaction.commit()
        } else {
            let segWidth = max(32, width * 0.34)
            let travel = max(0, width - segWidth)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fillLayer.opacity = 1.0
            fillLayer.frame = CGRect(x: 0, y: 0, width: segWidth, height: height)
            CATransaction.commit()

            if !isAnimatingIndeterminate || fillLayer.animation(forKey: "indeterminateSweep") == nil {
                isAnimatingIndeterminate = true
                let anim = CABasicAnimation(keyPath: "position.x")
                anim.fromValue = segWidth / 2.0
                anim.toValue = travel + segWidth / 2.0
                anim.duration = 1.1
                anim.autoreverses = true
                anim.repeatCount = .infinity
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                fillLayer.add(anim, forKey: "indeterminateSweep")
            }
        }
    }
}
