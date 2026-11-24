import AppKit

/// Pure AppKit right-hand inspector sidebar with native macOS controls for Capture, Hardware Tone, Color/Output, and Software Adjustments.
@MainActor
final class InspectorViewController: NSViewController, NSTextFieldDelegate {

    var onScanSettingsChanged: (() -> Void)?
    var onPreviewDisplayChanged: (() -> Void)?
    var onPreferencesChanged: (() -> Void)?

    private let prefs: AppPreferences
    private var capabilities: ScannerCapabilities?

    // Capture controls
    private let sourcePopup = NSPopUpButton()
    private let resolutionPopup = NSPopUpButton()
    private let colorModePopup = NSPopUpButton()
    private let intentPopup = NSPopUpButton()
    private let transferPopup = NSPopUpButton()
    private let rotateSegment = NSSegmentedControl()

    // Hardware tone controls
    private let hardwareToneBox = NSView()
    private let brightnessSlider = NSSlider()
    private let brightnessValueLabel = NSTextField(labelWithString: "1000")
    private let contrastSlider = NSSlider()
    private let contrastValueLabel = NSTextField(labelWithString: "1000")
    private let hardwareResetButton = NSButton(title: "Reset", target: nil, action: nil)

    // Color & Output controls
    private let profilePopup = NSPopUpButton()
    private let formatPopup = NSPopUpButton()
    private let qualityRow = NSView()
    private let qualitySlider = NSSlider()
    private let qualityValueLabel = NSTextField(labelWithString: "92%")
    private let previewCompressionCheck = NSButton(checkboxWithTitle: "Preview compression live", target: nil, action: nil)
    private let outputPreviewSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let folderButton = NSButton(title: "Pictures", target: nil, action: nil)
    private let filenameField = NSTextField()
    private let autoIncrementCheck = NSButton(checkboxWithTitle: "Auto-increment filename", target: nil, action: nil)

    private(set) var previewCompressionEnabled: Bool = true

    // Software tone controls (collapsible)
    private let toneDisclosureButton = NSButton(title: "Tone Adjustments (Software)", target: nil, action: nil)
    private let toneContentStack = NSStackView()
    private let blackPointSlider = NSSlider()
    private let blackPointLabel = NSTextField(labelWithString: "0%")
    private let whitePointSlider = NSSlider()
    private let whitePointLabel = NSTextField(labelWithString: "100%")
    private let gammaSlider = NSSlider()
    private let gammaLabel = NSTextField(labelWithString: "1.00")
    private let toneResetButton = NSButton(title: "Reset", target: nil, action: nil)

    // State accessors
    private(set) var selectedSource: ScanInputSource = .platen
    private(set) var selectedResolution: Int
    private(set) var selectedColorMode: ScanColorMode
    private(set) var selectedIntent: ScanIntent
    private(set) var selectedTransferFormat: TransferFormat
    private(set) var selectedRotation: ScanRotation
    private(set) var selectedColorProfile: ColorProfileMode
    private(set) var selectedOutputFormat: OutputFormat
    private(set) var selectedQuality: Double
    private(set) var saveFolderURL: URL
    private(set) var baseFilename: String
    private(set) var autoIncrement: Bool

    private var hardwareBrightness: Int = 1000
    private var hardwareContrast: Int = 1000
    private var defaultBrightness: Int = 1000
    private var defaultContrast: Int = 1000
    private(set) var toneAdjustments = ToneAdjustments()

    init(preferences: AppPreferences) {
        self.prefs = preferences
        self.selectedResolution = preferences.resolution
        self.selectedColorMode = preferences.colorMode
        self.selectedIntent = preferences.intent
        self.selectedTransferFormat = preferences.transferFormat
        self.selectedRotation = preferences.rotation
        self.selectedColorProfile = preferences.colorProfile
        self.selectedOutputFormat = preferences.outputFormat
        self.selectedQuality = preferences.quality
        self.saveFolderURL = preferences.saveFolderURL
        self.baseFilename = preferences.baseFilename
        self.autoIncrement = preferences.autoIncrement
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var effectiveHardwareBrightness: Int? {
        guard capabilities?.brightnessRange != nil else { return nil }
        return hardwareBrightness == defaultBrightness ? nil : hardwareBrightness
    }

    var effectiveHardwareContrast: Int? {
        guard capabilities?.contrastRange != nil else { return nil }
        return hardwareContrast == defaultContrast ? nil : hardwareContrast
    }

    override func loadView() {
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .sidebar
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .followsWindowActiveState
        self.view = visualEffect

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let docView = FlippedClipContentView()
        docView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = docView

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 14
        rootStack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 18, right: 14)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            docView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            docView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            docView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            docView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            rootStack.topAnchor.constraint(equalTo: docView.topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: docView.bottomAnchor)
        ])

        buildCaptureSection(into: rootStack)
        rootStack.addArrangedSubview(makeSeparator())
        buildHardwareToneSection(into: rootStack)
        rootStack.addArrangedSubview(makeSeparator())
        buildColorAndOutputSection(into: rootStack)
        rootStack.addArrangedSubview(makeSeparator())
        buildSoftwareToneSection(into: rootStack)

        applyInitialValues()
    }

    // MARK: - Section Builders

    private func buildCaptureSection(into stack: NSStackView) {
        stack.addArrangedSubview(makeSectionHeader("CAPTURE"))

        configurePopup(sourcePopup, action: #selector(sourceChanged))
        configurePopup(resolutionPopup, action: #selector(resolutionChanged))
        configurePopup(colorModePopup, action: #selector(colorModeChanged))
        configurePopup(intentPopup, action: #selector(intentChanged))
        configurePopup(transferPopup, action: #selector(transferChanged))

        rotateSegment.segmentCount = ScanRotation.allCases.count
        rotateSegment.trackingMode = .selectOne
        rotateSegment.segmentStyle = .rounded
        rotateSegment.controlSize = .small
        for (i, rot) in ScanRotation.allCases.enumerated() {
            rotateSegment.setLabel(rot.displayName, forSegment: i)
        }
        rotateSegment.target = self
        rotateSegment.action = #selector(rotationChanged)

        let grid = makeFormGrid([
            ("Source", sourcePopup),
            ("Resolution", resolutionPopup),
            ("Color", colorModePopup),
            ("Intent", intentPopup),
            ("Transfer", transferPopup),
            ("Rotate", rotateSegment)
        ])
        stack.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
    }

    private func buildHardwareToneSection(into stack: NSStackView) {
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.distribution = .fill
        let title = makeSectionHeader("SCANNER TONE (HARDWARE)")
        hardwareResetButton.bezelStyle = .inline
        hardwareResetButton.controlSize = .mini
        hardwareResetButton.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        hardwareResetButton.target = self
        hardwareResetButton.action = #selector(resetHardwareTone)
        headerRow.addArrangedSubview(title)
        headerRow.addArrangedSubview(NSView())
        headerRow.addArrangedSubview(hardwareResetButton)
        stack.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        configureSlider(brightnessSlider, min: 0, max: 2000, value: 1000, action: #selector(hardwareToneChanged))
        configureSlider(contrastSlider, min: 0, max: 2000, value: 1000, action: #selector(hardwareToneChanged))
        configureValueLabel(brightnessValueLabel)
        configureValueLabel(contrastValueLabel)

        let bRow = makeSliderRow(label: "Brightness", slider: brightnessSlider, valueLabel: brightnessValueLabel)
        let cRow = makeSliderRow(label: "Contrast", slider: contrastSlider, valueLabel: contrastValueLabel)
        stack.addArrangedSubview(bRow)
        stack.addArrangedSubview(cRow)
        bRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        cRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
    }

    private func buildColorAndOutputSection(into stack: NSStackView) {
        stack.addArrangedSubview(makeSectionHeader("COLOR & OUTPUT"))

        configurePopup(profilePopup, action: #selector(profileChanged))
        for mode in ColorProfileMode.allCases {
            profilePopup.addItem(withTitle: mode.shortName)
            profilePopup.lastItem?.representedObject = mode.rawValue
        }

        configurePopup(formatPopup, action: #selector(formatChanged))
        for fmt in OutputFormat.allCases {
            formatPopup.addItem(withTitle: fmt.displayName)
            formatPopup.lastItem?.representedObject = fmt.rawValue
        }

        configureSlider(qualitySlider, min: 0.5, max: 1.0, value: selectedQuality, action: #selector(qualityChanged))
        configureValueLabel(qualityValueLabel)

        folderButton.bezelStyle = .rounded
        folderButton.controlSize = .small
        folderButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
        folderButton.imagePosition = .imageLeading
        folderButton.alignment = .left
        folderButton.lineBreakMode = .byTruncatingMiddle
        folderButton.target = self
        folderButton.action = #selector(chooseFolderClicked)

        filenameField.controlSize = .small
        filenameField.font = NSFont.systemFont(ofSize: 12)
        filenameField.placeholderString = "scan-001"
        filenameField.delegate = self

        let grid = makeFormGrid([
            ("Profile", profilePopup),
            ("Format", formatPopup),
            ("Folder", folderButton),
            ("Filename", filenameField)
        ])
        stack.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        let qStack = makeSliderRow(label: "Quality", slider: qualitySlider, valueLabel: qualityValueLabel)
        qStack.translatesAutoresizingMaskIntoConstraints = false
        qualityRow.translatesAutoresizingMaskIntoConstraints = false
        qualityRow.addSubview(qStack)
        NSLayoutConstraint.activate([
            qStack.topAnchor.constraint(equalTo: qualityRow.topAnchor),
            qStack.leadingAnchor.constraint(equalTo: qualityRow.leadingAnchor),
            qStack.trailingAnchor.constraint(equalTo: qualityRow.trailingAnchor),
            qStack.bottomAnchor.constraint(equalTo: qualityRow.bottomAnchor)
        ])
        stack.addArrangedSubview(qualityRow)
        qualityRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        previewCompressionCheck.controlSize = .small
        previewCompressionCheck.font = NSFont.systemFont(ofSize: 11.5)
        previewCompressionCheck.state = .on
        previewCompressionCheck.target = self
        previewCompressionCheck.action = #selector(previewCompressionChanged)
        stack.addArrangedSubview(previewCompressionCheck)

        outputPreviewSummaryLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        outputPreviewSummaryLabel.textColor = .secondaryLabelColor
        outputPreviewSummaryLabel.maximumNumberOfLines = 2
        stack.addArrangedSubview(outputPreviewSummaryLabel)
        outputPreviewSummaryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        autoIncrementCheck.controlSize = .small
        autoIncrementCheck.font = NSFont.systemFont(ofSize: 11.5)
        autoIncrementCheck.target = self
        autoIncrementCheck.action = #selector(autoIncrementChanged)
        stack.addArrangedSubview(autoIncrementCheck)
    }

    private func buildSoftwareToneSection(into stack: NSStackView) {
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY

        toneDisclosureButton.isBordered = false
        toneDisclosureButton.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        toneDisclosureButton.contentTintColor = .secondaryLabelColor
        toneDisclosureButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Expand")
        toneDisclosureButton.imagePosition = .imageLeading
        toneDisclosureButton.target = self
        toneDisclosureButton.action = #selector(toggleSoftwareTone)

        toneResetButton.bezelStyle = .inline
        toneResetButton.controlSize = .mini
        toneResetButton.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        toneResetButton.target = self
        toneResetButton.action = #selector(resetSoftwareTone)
        toneResetButton.isHidden = true

        headerRow.addArrangedSubview(toneDisclosureButton)
        headerRow.addArrangedSubview(NSView())
        headerRow.addArrangedSubview(toneResetButton)
        stack.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        configureSlider(blackPointSlider, min: 0.0, max: 0.25, value: 0.0, action: #selector(softwareToneChanged))
        configureSlider(whitePointSlider, min: 0.75, max: 1.0, value: 1.0, action: #selector(softwareToneChanged))
        configureSlider(gammaSlider, min: 0.5, max: 2.0, value: 1.0, action: #selector(softwareToneChanged))
        configureValueLabel(blackPointLabel)
        configureValueLabel(whitePointLabel)
        configureValueLabel(gammaLabel)

        toneContentStack.orientation = .vertical
        toneContentStack.spacing = 8
        toneContentStack.alignment = .leading
        toneContentStack.isHidden = true

        for row in [
            makeSliderRow(label: "Black Pt", slider: blackPointSlider, valueLabel: blackPointLabel),
            makeSliderRow(label: "White Pt", slider: whitePointSlider, valueLabel: whitePointLabel),
            makeSliderRow(label: "Gamma", slider: gammaSlider, valueLabel: gammaLabel)
        ] {
            toneContentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: toneContentStack.widthAnchor).isActive = true
        }

        stack.addArrangedSubview(toneContentStack)
        toneContentStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
    }

    // MARK: - Populate / Update Controls

    private func applyInitialValues() {
        populateSourcePopup(caps: nil)
        populateResolutionPopup(resolutions: [75, 100, 200, 300, 600, 1200])
        populateColorModePopup(modes: ["RGB24", "Grayscale8"])
        populateIntentPopup()
        populateTransferPopup(supportsRaw: true, supportsJPEG: true)

        if let rotIdx = ScanRotation.allCases.firstIndex(of: selectedRotation) {
            rotateSegment.selectedSegment = rotIdx
        }
        selectPopup(profilePopup, rawValue: selectedColorProfile.rawValue)
        selectPopup(formatPopup, rawValue: selectedOutputFormat.rawValue)
        updateQualityVisibility()
        updateFolderButtonTitle()
        filenameField.stringValue = baseFilename
        autoIncrementCheck.state = autoIncrement ? .on : .off
        updateToneLabels()
    }

    func applyCapabilities(_ caps: ScannerCapabilities?) {
        self.capabilities = caps
        populateSourcePopup(caps: caps)

        let inputCaps = caps?.caps(for: selectedSource) ?? caps?.platen
        populateResolutionPopup(resolutions: inputCaps?.discreteResolutions ?? [75, 100, 200, 300, 600, 1200])
        populateColorModePopup(modes: inputCaps?.colorModes ?? ["RGB24", "Grayscale8"])
        populateTransferPopup(
            supportsRaw: inputCaps?.supportsRawOctetStream ?? true,
            supportsJPEG: inputCaps?.supportsJPEG ?? true
        )

        if let br = caps?.brightnessRange {
            brightnessSlider.isEnabled = true
            brightnessSlider.minValue = Double(br.min)
            brightnessSlider.maxValue = Double(br.max)
            defaultBrightness = br.normal
            hardwareBrightness = br.normal
            brightnessSlider.integerValue = br.normal
            brightnessValueLabel.stringValue = "\(br.normal)"
        } else {
            brightnessSlider.isEnabled = false
        }

        if let cr = caps?.contrastRange {
            contrastSlider.isEnabled = true
            contrastSlider.minValue = Double(cr.min)
            contrastSlider.maxValue = Double(cr.max)
            defaultContrast = cr.normal
            hardwareContrast = cr.normal
            contrastSlider.integerValue = cr.normal
            contrastValueLabel.stringValue = "\(cr.normal)"
        } else {
            contrastSlider.isEnabled = false
        }
        hardwareResetButton.isEnabled = (caps?.brightnessRange != nil || caps?.contrastRange != nil)
    }

    func setFilename(_ name: String) {
        baseFilename = name
        filenameField.stringValue = name
        prefs.baseFilename = name
    }

    func setBusy(_ busy: Bool) {
        let enabled = !busy
        sourcePopup.isEnabled = enabled
        resolutionPopup.isEnabled = enabled
        colorModePopup.isEnabled = enabled
        intentPopup.isEnabled = enabled
        transferPopup.isEnabled = enabled
        brightnessSlider.isEnabled = enabled && capabilities?.brightnessRange != nil
        contrastSlider.isEnabled = enabled && capabilities?.contrastRange != nil
        hardwareResetButton.isEnabled = enabled && (capabilities?.brightnessRange != nil || capabilities?.contrastRange != nil)
        folderButton.isEnabled = enabled
        filenameField.isEnabled = enabled
    }

    private func populateSourcePopup(caps: ScannerCapabilities?) {
        sourcePopup.removeAllItems()
        var available: [ScanInputSource] = []
        if caps == nil || caps?.platen != nil { available.append(.platen) }
        if caps?.adf != nil { available.append(.feeder) }
        if available.isEmpty { available = [.platen] }

        for src in available {
            sourcePopup.addItem(withTitle: src.displayName)
            sourcePopup.lastItem?.representedObject = src.rawValue
        }
        if !available.contains(selectedSource) {
            selectedSource = available[0]
        }
        selectPopup(sourcePopup, rawValue: selectedSource.rawValue)
    }

    private func populateResolutionPopup(resolutions: [Int]) {
        resolutionPopup.removeAllItems()
        for r in resolutions {
            resolutionPopup.addItem(withTitle: "\(r) DPI")
            resolutionPopup.lastItem?.representedObject = r
        }
        if !resolutions.contains(selectedResolution) {
            selectedResolution = resolutions.last ?? 300
        }
        if let idx = resolutions.firstIndex(of: selectedResolution) {
            resolutionPopup.selectItem(at: idx)
        }
    }

    private func populateColorModePopup(modes: [String]) {
        colorModePopup.removeAllItems()
        let supported = ScanColorMode.allCases.filter { modes.isEmpty || modes.contains($0.rawValue) }
        let list = supported.isEmpty ? [ScanColorMode.rgb24] : supported
        for m in list {
            colorModePopup.addItem(withTitle: m.displayName)
            colorModePopup.lastItem?.representedObject = m.rawValue
        }
        if !list.contains(selectedColorMode) {
            selectedColorMode = list[0]
        }
        selectPopup(colorModePopup, rawValue: selectedColorMode.rawValue)
    }

    private func populateIntentPopup() {
        intentPopup.removeAllItems()
        for intent in ScanIntent.allCases {
            intentPopup.addItem(withTitle: intent.displayName)
            intentPopup.lastItem?.representedObject = intent.rawValue
        }
        selectPopup(intentPopup, rawValue: selectedIntent.rawValue)
    }

    private func populateTransferPopup(supportsRaw: Bool, supportsJPEG: Bool) {
        transferPopup.removeAllItems()
        var formats: [TransferFormat] = []
        if supportsRaw { formats.append(.rawOctetStream) }
        if supportsJPEG { formats.append(.jpeg) }
        if formats.isEmpty { formats = [.rawOctetStream] }

        for f in formats {
            transferPopup.addItem(withTitle: f.displayName)
            transferPopup.lastItem?.representedObject = f.rawValue
        }
        if !formats.contains(selectedTransferFormat) {
            selectedTransferFormat = formats[0]
        }
        selectPopup(transferPopup, rawValue: selectedTransferFormat.rawValue)
    }

    private func updateQualityVisibility() {
        let lossy = selectedOutputFormat.supportsQuality
        qualityRow.isHidden = !lossy
        previewCompressionCheck.isHidden = !lossy
        qualityValueLabel.stringValue = "\(Int((selectedQuality * 100).rounded()))%"
    }

    func setOutputPreviewSummary(_ text: String) {
        outputPreviewSummaryLabel.stringValue = text
        outputPreviewSummaryLabel.isHidden = text.isEmpty
    }

    private func updateFolderButtonTitle() {
        folderButton.title = saveFolderURL.lastPathComponent
        folderButton.toolTip = saveFolderURL.path
    }

    private func updateToneLabels() {
        blackPointLabel.stringValue = "\(Int((toneAdjustments.blackPoint * 100).rounded()))%"
        whitePointLabel.stringValue = "\(Int((toneAdjustments.whitePoint * 100).rounded()))%"
        gammaLabel.stringValue = String(format: "%.2f", toneAdjustments.gamma)
    }

    // MARK: - Actions

    @objc private func sourceChanged() {
        guard let raw = sourcePopup.selectedItem?.representedObject as? String,
              let src = ScanInputSource(rawValue: raw) else { return }
        selectedSource = src
        if let caps = capabilities {
            let inputCaps = caps.caps(for: src) ?? caps.platen
            populateResolutionPopup(resolutions: inputCaps?.discreteResolutions ?? [75, 100, 200, 300, 600])
        }
        onScanSettingsChanged?()
    }

    @objc private func resolutionChanged() {
        guard let r = resolutionPopup.selectedItem?.representedObject as? Int else { return }
        selectedResolution = r
        prefs.resolution = r
        onScanSettingsChanged?()
    }

    @objc private func colorModeChanged() {
        guard let raw = colorModePopup.selectedItem?.representedObject as? String,
              let mode = ScanColorMode(rawValue: raw) else { return }
        selectedColorMode = mode
        prefs.colorMode = mode
        profilePopup.isEnabled = (mode == .rgb24)
        onScanSettingsChanged?()
    }

    @objc private func intentChanged() {
        guard let raw = intentPopup.selectedItem?.representedObject as? String,
              let intent = ScanIntent(rawValue: raw) else { return }
        selectedIntent = intent
        prefs.intent = intent
        onScanSettingsChanged?()
    }

    @objc private func transferChanged() {
        guard let raw = transferPopup.selectedItem?.representedObject as? String,
              let tf = TransferFormat(rawValue: raw) else { return }
        selectedTransferFormat = tf
        prefs.transferFormat = tf
        onScanSettingsChanged?()
    }

    @objc private func rotationChanged() {
        let idx = rotateSegment.selectedSegment
        guard idx >= 0 && idx < ScanRotation.allCases.count else { return }
        selectedRotation = ScanRotation.allCases[idx]
        prefs.rotation = selectedRotation
        onPreviewDisplayChanged?()
        onScanSettingsChanged?()
    }

    @objc private func hardwareToneChanged() {
        hardwareBrightness = brightnessSlider.integerValue
        hardwareContrast = contrastSlider.integerValue
        brightnessValueLabel.stringValue = "\(hardwareBrightness)"
        contrastValueLabel.stringValue = "\(hardwareContrast)"
    }

    @objc private func resetHardwareTone() {
        hardwareBrightness = defaultBrightness
        hardwareContrast = defaultContrast
        brightnessSlider.integerValue = defaultBrightness
        contrastSlider.integerValue = defaultContrast
        brightnessValueLabel.stringValue = "\(defaultBrightness)"
        contrastValueLabel.stringValue = "\(defaultContrast)"
    }

    @objc private func profileChanged() {
        guard let raw = profilePopup.selectedItem?.representedObject as? String,
              let mode = ColorProfileMode(rawValue: raw) else { return }
        selectedColorProfile = mode
        prefs.colorProfile = mode
        onPreviewDisplayChanged?()
    }

    @objc private func formatChanged() {
        guard let raw = formatPopup.selectedItem?.representedObject as? String,
              let fmt = OutputFormat(rawValue: raw) else { return }
        selectedOutputFormat = fmt
        prefs.outputFormat = fmt
        updateQualityVisibility()
        onPreferencesChanged?()
        onPreviewDisplayChanged?()
    }

    @objc private func qualityChanged() {
        selectedQuality = qualitySlider.doubleValue
        prefs.quality = selectedQuality
        qualityValueLabel.stringValue = "\(Int((selectedQuality * 100).rounded()))%"
        onPreviewDisplayChanged?()
    }

    @objc private func previewCompressionChanged() {
        previewCompressionEnabled = (previewCompressionCheck.state == .on)
        onPreviewDisplayChanged?()
    }

    @objc private func chooseFolderClicked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = saveFolderURL
        panel.prompt = "Choose"
        if let window = view.window {
            panel.beginSheetModal(for: window) { [weak self] resp in
                guard resp == .OK, let url = panel.url, let self else { return }
                self.saveFolderURL = url
                self.prefs.saveFolderURL = url
                self.updateFolderButtonTitle()
            }
        }
    }

    @objc private func autoIncrementChanged() {
        autoIncrement = (autoIncrementCheck.state == .on)
        prefs.autoIncrement = autoIncrement
    }

    func controlTextDidChange(_ obj: Notification) {
        baseFilename = filenameField.stringValue
        prefs.baseFilename = baseFilename
    }

    @objc private func toggleSoftwareTone() {
        let expanding = toneContentStack.isHidden
        toneContentStack.isHidden = !expanding
        toneResetButton.isHidden = !expanding
        toneDisclosureButton.image = NSImage(
            systemSymbolName: expanding ? "chevron.down" : "chevron.right",
            accessibilityDescription: expanding ? "Collapse" : "Expand"
        )
    }

    @objc private func softwareToneChanged() {
        toneAdjustments.blackPoint = blackPointSlider.doubleValue
        toneAdjustments.whitePoint = whitePointSlider.doubleValue
        toneAdjustments.gamma = gammaSlider.doubleValue
        updateToneLabels()
        onPreviewDisplayChanged?()
    }

    @objc private func resetSoftwareTone() {
        toneAdjustments = ToneAdjustments()
        blackPointSlider.doubleValue = 0.0
        whitePointSlider.doubleValue = 1.0
        gammaSlider.doubleValue = 1.0
        updateToneLabels()
        onPreviewDisplayChanged?()
    }

    // MARK: - UI Factory Helpers

    private func makeSectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeSeparator() -> NSBox {
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return sep
    }

    private func configurePopup(_ popup: NSPopUpButton, action: Selector) {
        popup.controlSize = .small
        popup.font = NSFont.systemFont(ofSize: 12)
        popup.target = self
        popup.action = action
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func selectPopup(_ popup: NSPopUpButton, rawValue: String) {
        for (i, item) in popup.itemArray.enumerated() {
            if let v = item.representedObject as? String, v == rawValue {
                popup.selectItem(at: i)
                return
            }
        }
    }

    private func configureSlider(_ slider: NSSlider, min: Double, max: Double, value: Double, action: Selector) {
        slider.minValue = min
        slider.maxValue = max
        slider.doubleValue = value
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = action
    }

    private func configureValueLabel(_ label: NSTextField) {
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 38).isActive = true
    }

    private func makeFormGrid(_ rows: [(String, NSView)]) -> NSGridView {
        var gridRows: [[NSView]] = []
        for (title, control) in rows {
            let lbl = NSTextField(labelWithString: title)
            lbl.font = NSFont.systemFont(ofSize: 12)
            lbl.textColor = .labelColor
            lbl.alignment = .right
            lbl.setContentHuggingPriority(.required, for: .horizontal)
            gridRows.append([lbl, control])
        }
        let grid = NSGridView(views: gridRows)
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.yPlacement = .center
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 68
        grid.column(at: 1).xPlacement = .fill
        return grid
    }

    private func makeSliderRow(label: String, slider: NSSlider, valueLabel: NSTextField) -> NSStackView {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = NSFont.systemFont(ofSize: 12)
        lbl.textColor = .labelColor
        lbl.alignment = .right
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.widthAnchor.constraint(equalToConstant: 68).isActive = true

        let row = NSStackView(views: [lbl, slider, valueLabel])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }
}

private final class FlippedClipContentView: NSView {
    override var isFlipped: Bool { true }
}
