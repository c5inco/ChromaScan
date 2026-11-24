import AppKit

/// Native bottom status bar displaying crop/zoom controls, dimensions, live progress, and cancel/reveal actions.
@MainActor
final class StatusFooterView: NSView {
    var onResetCrop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRevealLastSaved: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomFit: (() -> Void)?
    var onZoomActualSize: (() -> Void)?

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
    private let progressIndicator = NSProgressIndicator()
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

        progressIndicator.style = .bar
        progressIndicator.controlSize = .small
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.isHidden = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.isHidden = true

        let zoomStack = NSStackView(views: [zoomOutButton, zoomFitButton, zoomInButton, zoomActualButton])
        zoomStack.orientation = .horizontal
        zoomStack.spacing = 4
        zoomStack.alignment = .centerY

        let leftStack = NSStackView(views: [zoomStack, zoomDivider, fullPageButton, dimensionsLabel])
        leftStack.orientation = .horizontal
        leftStack.spacing = 8
        leftStack.alignment = .centerY
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let rightStack = NSStackView(views: [statusLabel, revealButton, progressIndicator, cancelButton])
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

            progressIndicator.widthAnchor.constraint(equalToConstant: 110)
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

    func setCropResetVisible(_ visible: Bool) {
        fullPageButton.isHidden = !visible
    }

    func updateDimensions(
        widthInches: Double,
        heightInches: Double,
        pixelWidth: Int,
        pixelHeight: Int,
        estimatedRawBytes: Int64,
        isFullPage: Bool
    ) {
        fullPageButton.isEnabled = !isFullPage
        let mb = Double(estimatedRawBytes) / (1024.0 * 1024.0)
        let sizeStr = mb >= 10.0 ? String(format: "%.0f MB", mb) : String(format: "%.1f MB", mb)
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        let pw = nf.string(from: NSNumber(value: pixelWidth)) ?? "\(pixelWidth)"
        let ph = nf.string(from: NSNumber(value: pixelHeight)) ?? "\(pixelHeight)"
        dimensionsLabel.stringValue = String(format: "%.2f\"×%.2f\" · %@×%@ (%@ raw)", widthInches, heightInches, pw, ph, sizeStr)
    }

    func updateScanDimensions(pixelWidth: Int, pixelHeight: Int, dpi: Int, profileName: String) {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        let pw = nf.string(from: NSNumber(value: pixelWidth)) ?? "\(pixelWidth)"
        let ph = nf.string(from: NSNumber(value: pixelHeight)) ?? "\(pixelHeight)"
        dimensionsLabel.stringValue = "\(pw)×\(ph) px · \(dpi) DPI · \(profileName)"
    }

    func setIdle(status: String, showReveal: Bool) {
        statusLabel.stringValue = status
        statusLabel.textColor = .secondaryLabelColor
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        cancelButton.isHidden = true
        revealButton.isHidden = !showReveal
    }

    func setError(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        cancelButton.isHidden = true
        revealButton.isHidden = true
    }

    func setProgress(status: String, fraction: Double?) {
        statusLabel.stringValue = status
        statusLabel.textColor = .labelColor
        revealButton.isHidden = true
        cancelButton.isHidden = false
        progressIndicator.isHidden = false
        if let fraction {
            progressIndicator.isIndeterminate = false
            progressIndicator.doubleValue = max(0, min(1, fraction))
        } else {
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
        }
    }

    @objc private func resetCropClicked() { onResetCrop?() }
    @objc private func cancelClicked() { onCancel?() }
    @objc private func revealClicked() { onRevealLastSaved?() }
    @objc private func zoomOutClicked() { onZoomOut?() }
    @objc private func zoomInClicked() { onZoomIn?() }
    @objc private func zoomFitClicked() { onZoomFit?() }
    @objc private func zoomActualClicked() { onZoomActualSize?() }
}
