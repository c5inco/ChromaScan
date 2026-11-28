import AppKit

/// Pure AppKit right-hand inspector sidebar with native macOS controls for Capture, Hardware Tone,
/// Color/Output, and Software Adjustments. Bidirectionally bound to `ScanSessionEngine`.
@MainActor
final class InspectorViewController: NSViewController, NSTextFieldDelegate {

    private let engine: ScanSessionEngine
    private var capabilities: ScannerCapabilities?
    private var isApplyingSnapshot = false

    // Capture controls
    private let sourcePopup = NSPopUpButton()
    private let resolutionPopup = NSPopUpButton()
    private let colorModePopup = NSPopUpButton()
    private let intentPopup = NSPopUpButton()
    private let transferPopup = NSPopUpButton()
    private let rotateSegment = NSSegmentedControl()
    private let autoTrimCheck = NSButton(checkboxWithTitle: "Auto-trim empty space on scan", target: nil, action: nil)

    // Hardware tone controls
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

    init(engine: ScanSessionEngine) {
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

        applySnapshot(engine.makeSnapshot())
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

        autoTrimCheck.controlSize = .small
        autoTrimCheck.font = NSFont.systemFont(ofSize: 11.5)
        autoTrimCheck.bezelColor = ChromaTheme.vermilionNS
        autoTrimCheck.toolTip = "Automatically detect and crop blank flatbed margins when scanning"
        autoTrimCheck.target = self
        autoTrimCheck.action = #selector(autoTrimChanged)
        stack.addArrangedSubview(autoTrimCheck)
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

        configureSlider(qualitySlider, min: 0.5, max: 1.0, value: engine.settings.quality, action: #selector(qualityChanged))
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
        previewCompressionCheck.bezelColor = ChromaTheme.vermilionNS
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
        autoIncrementCheck.bezelColor = ChromaTheme.vermilionNS
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

    // MARK: - Snapshot Sync

    func applySnapshot(_ snapshot: SessionSnapshot) {
        isApplyingSnapshot = true
        defer { isApplyingSnapshot = false }

        let caps = snapshot.capabilities
        let settings = snapshot.settings
        self.capabilities = caps

        populateSourcePopup(caps: caps, selected: settings.inputSource)
        let inputCaps = caps?.caps(for: settings.inputSource) ?? caps?.platen
        populateResolutionPopup(resolutions: inputCaps?.discreteResolutions ?? [75, 100, 200, 300, 600, 1200], selected: settings.resolution)
        populateColorModePopup(modes: inputCaps?.colorModes ?? ["RGB24", "Grayscale8"], selected: settings.colorMode)
        populateIntentPopup(selected: settings.intent)
        populateTransferPopup(
            supportsRaw: inputCaps?.supportsRawOctetStream ?? true,
            supportsJPEG: inputCaps?.supportsJPEG ?? true,
            selected: settings.transferFormat
        )

        if let rotIdx = ScanRotation.allCases.firstIndex(of: settings.rotation) {
            rotateSegment.selectedSegment = rotIdx
        }
        autoTrimCheck.state = settings.autoTrimEmptySpace ? .on : .off

        if let br = caps?.brightnessRange {
            brightnessSlider.minValue = Double(br.min)
            brightnessSlider.maxValue = Double(br.max)
            brightnessSlider.integerValue = settings.hardwareBrightness
            brightnessValueLabel.stringValue = "\(settings.hardwareBrightness)"
        }
        if let cr = caps?.contrastRange {
            contrastSlider.minValue = Double(cr.min)
            contrastSlider.maxValue = Double(cr.max)
            contrastSlider.integerValue = settings.hardwareContrast
            contrastValueLabel.stringValue = "\(settings.hardwareContrast)"
        }

        selectPopup(profilePopup, rawValue: settings.colorProfile.rawValue)
        profilePopup.isEnabled = (settings.colorMode == .rgb24)
        selectPopup(formatPopup, rawValue: settings.outputFormat.rawValue)

        qualitySlider.doubleValue = settings.quality
        let lossy = settings.outputFormat.supportsQuality
        qualityRow.isHidden = !lossy
        previewCompressionCheck.isHidden = !lossy
        previewCompressionCheck.state = settings.previewCompressionEnabled ? .on : .off
        qualityValueLabel.stringValue = "\(Int((settings.quality * 100).rounded()))%"

        setOutputPreviewSummary(snapshot.outputPreviewSummary)

        folderButton.title = engine.saveFolderURL.lastPathComponent
        folderButton.toolTip = engine.saveFolderURL.path

        if filenameField.stringValue != settings.baseFilename {
            filenameField.stringValue = settings.baseFilename
        }
        autoIncrementCheck.state = settings.autoIncrement ? .on : .off

        blackPointSlider.doubleValue = settings.toneAdjustments.blackPoint
        whitePointSlider.doubleValue = settings.toneAdjustments.whitePoint
        gammaSlider.doubleValue = settings.toneAdjustments.gamma
        blackPointLabel.stringValue = "\(Int((settings.toneAdjustments.blackPoint * 100).rounded()))%"
        whitePointLabel.stringValue = "\(Int((settings.toneAdjustments.whitePoint * 100).rounded()))%"
        gammaLabel.stringValue = String(format: "%.2f", settings.toneAdjustments.gamma)

        let enabled = !snapshot.isBusy
        sourcePopup.isEnabled = enabled
        resolutionPopup.isEnabled = enabled
        colorModePopup.isEnabled = enabled
        intentPopup.isEnabled = enabled
        transferPopup.isEnabled = enabled
        autoTrimCheck.isEnabled = enabled
        brightnessSlider.isEnabled = enabled && caps?.brightnessRange != nil
        contrastSlider.isEnabled = enabled && caps?.contrastRange != nil
        hardwareResetButton.isEnabled = enabled && (caps?.brightnessRange != nil || caps?.contrastRange != nil)
        folderButton.isEnabled = enabled
        filenameField.isEnabled = enabled
    }

    func setOutputPreviewSummary(_ text: String) {
        outputPreviewSummaryLabel.stringValue = text
        outputPreviewSummaryLabel.isHidden = text.isEmpty
    }

    // MARK: - Popup Population

    private func populateSourcePopup(caps: ScannerCapabilities?, selected: ScanInputSource) {
        sourcePopup.removeAllItems()
        var available: [ScanInputSource] = []
        if caps == nil || caps?.platen != nil { available.append(.platen) }
        if caps?.adf != nil { available.append(.feeder) }
        if available.isEmpty { available = [.platen] }

        for src in available {
            sourcePopup.addItem(withTitle: src.displayName)
            sourcePopup.lastItem?.representedObject = src.rawValue
        }
        selectPopup(sourcePopup, rawValue: available.contains(selected) ? selected.rawValue : available[0].rawValue)
    }

    private func populateResolutionPopup(resolutions: [Int], selected: Int) {
        resolutionPopup.removeAllItems()
        for r in resolutions {
            resolutionPopup.addItem(withTitle: "\(r) DPI")
            resolutionPopup.lastItem?.representedObject = r
        }
        if let idx = resolutions.firstIndex(of: selected) {
            resolutionPopup.selectItem(at: idx)
        } else if !resolutions.isEmpty {
            resolutionPopup.selectItem(at: resolutions.count - 1)
        }
    }

    private func populateColorModePopup(modes: [String], selected: ScanColorMode) {
        colorModePopup.removeAllItems()
        let supported = ScanColorMode.allCases.filter { modes.isEmpty || modes.contains($0.rawValue) }
        let list = supported.isEmpty ? [ScanColorMode.rgb24] : supported
        for m in list {
            colorModePopup.addItem(withTitle: m.displayName)
            colorModePopup.lastItem?.representedObject = m.rawValue
        }
        selectPopup(colorModePopup, rawValue: list.contains(selected) ? selected.rawValue : list[0].rawValue)
    }

    private func populateIntentPopup(selected: ScanIntent) {
        intentPopup.removeAllItems()
        for intent in ScanIntent.allCases {
            intentPopup.addItem(withTitle: intent.displayName)
            intentPopup.lastItem?.representedObject = intent.rawValue
        }
        selectPopup(intentPopup, rawValue: selected.rawValue)
    }

    private func populateTransferPopup(supportsRaw: Bool, supportsJPEG: Bool, selected: TransferFormat) {
        transferPopup.removeAllItems()
        var formats: [TransferFormat] = []
        if supportsRaw { formats.append(.rawOctetStream) }
        if supportsJPEG { formats.append(.jpeg) }
        if formats.isEmpty { formats = [.rawOctetStream] }

        for f in formats {
            transferPopup.addItem(withTitle: f.displayName)
            transferPopup.lastItem?.representedObject = f.rawValue
        }
        selectPopup(transferPopup, rawValue: formats.contains(selected) ? selected.rawValue : formats[0].rawValue)
    }

    // MARK: - Actions

    @objc private func sourceChanged() {
        guard !isApplyingSnapshot,
              let raw = sourcePopup.selectedItem?.representedObject as? String,
              let src = ScanInputSource(rawValue: raw) else { return }
        engine.updateSettings(ScanSettingsPatch(inputSource: src))
    }

    @objc private func resolutionChanged() {
        guard !isApplyingSnapshot,
              let r = resolutionPopup.selectedItem?.representedObject as? Int else { return }
        engine.updateSettings(ScanSettingsPatch(resolution: r))
    }

    @objc private func colorModeChanged() {
        guard !isApplyingSnapshot,
              let raw = colorModePopup.selectedItem?.representedObject as? String,
              let mode = ScanColorMode(rawValue: raw) else { return }
        engine.updateSettings(ScanSettingsPatch(colorMode: mode))
    }

    @objc private func intentChanged() {
        guard !isApplyingSnapshot,
              let raw = intentPopup.selectedItem?.representedObject as? String,
              let intent = ScanIntent(rawValue: raw) else { return }
        engine.updateSettings(ScanSettingsPatch(intent: intent))
    }

    @objc private func transferChanged() {
        guard !isApplyingSnapshot,
              let raw = transferPopup.selectedItem?.representedObject as? String,
              let tf = TransferFormat(rawValue: raw) else { return }
        engine.updateSettings(ScanSettingsPatch(transferFormat: tf))
    }

    @objc private func rotationChanged() {
        guard !isApplyingSnapshot else { return }
        let idx = rotateSegment.selectedSegment
        guard idx >= 0 && idx < ScanRotation.allCases.count else { return }
        engine.updateSettings(ScanSettingsPatch(rotation: ScanRotation.allCases[idx]))
    }

    @objc private func autoTrimChanged() {
        guard !isApplyingSnapshot else { return }
        engine.updateSettings(ScanSettingsPatch(autoTrimEmptySpace: autoTrimCheck.state == .on))
    }

    @objc private func hardwareToneChanged() {
        guard !isApplyingSnapshot else { return }
        engine.updateSettings(ScanSettingsPatch(
            hardwareBrightness: brightnessSlider.integerValue,
            hardwareContrast: contrastSlider.integerValue
        ))
    }

    @objc private func resetHardwareTone() {
        guard !isApplyingSnapshot else { return }
        engine.updateSettings(ScanSettingsPatch(resetHardwareTone: true))
    }

    @objc private func profileChanged() {
        guard !isApplyingSnapshot,
              let raw = profilePopup.selectedItem?.representedObject as? String,
              let mode = ColorProfileMode(rawValue: raw) else { return }
        engine.updateSettings(ScanSettingsPatch(colorProfile: mode))
    }

    @objc private func formatChanged() {
        guard !isApplyingSnapshot,
              let raw = formatPopup.selectedItem?.representedObject as? String,
              let fmt = OutputFormat(rawValue: raw) else { return }
        engine.updateSettings(ScanSettingsPatch(outputFormat: fmt))
    }

    @objc private func qualityChanged() {
        guard !isApplyingSnapshot else { return }
        engine.updateSettings(ScanSettingsPatch(quality: qualitySlider.doubleValue))
    }

    @objc private func previewCompressionChanged() {
        guard !isApplyingSnapshot else { return }
        engine.updateSettings(ScanSettingsPatch(previewCompressionEnabled: previewCompressionCheck.state == .on))
    }

    @objc private func chooseFolderClicked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = engine.saveFolderURL
        panel.prompt = "Choose"
        if let window = view.window {
            panel.beginSheetModal(for: window) { [weak self] resp in
                guard resp == .OK, let url = panel.url, let self else { return }
                self.engine.setSaveFolderURL(url)
            }
        }
    }

    @objc private func autoIncrementChanged() {
        guard !isApplyingSnapshot else { return }
        engine.updateSettings(ScanSettingsPatch(autoIncrement: autoIncrementCheck.state == .on))
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !isApplyingSnapshot else { return }
        engine.updateSettings(ScanSettingsPatch(baseFilename: filenameField.stringValue))
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
        guard !isApplyingSnapshot else { return }
        let tone = ToneAdjustments(
            blackPoint: blackPointSlider.doubleValue,
            whitePoint: whitePointSlider.doubleValue,
            gamma: gammaSlider.doubleValue
        )
        engine.updateSettings(ScanSettingsPatch(toneAdjustments: tone))
    }

    @objc private func resetSoftwareTone() {
        guard !isApplyingSnapshot else { return }
        engine.updateSettings(ScanSettingsPatch(resetSoftwareTone: true))
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
        slider.trackFillColor = ChromaTheme.vermilionNS
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
