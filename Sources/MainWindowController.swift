import AppKit
import UniformTypeIdentifiers

@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate {

    private enum CanvasViewMode: Int {
        case preview = 0
        case scan = 1
    }

    private let prefs = AppPreferences()
    private let browser = BonjourScannerBrowser()
    private let client = ESCLClient()

    private let splitVC = NSSplitViewController()
    private let canvasVC = CanvasContainerViewController()
    private let inspectorVC: InspectorViewController
    private var inspectorSplitItem: NSSplitViewItem!

    // Toolbar controls
    private let scannerPopup = NSPopUpButton()
    private let refreshButton = NSButton()
    private let viewModeSegment = NSSegmentedControl()
    private let previewButton = NSButton()
    private let scanButton = NSButton()
    private let exportButton = NSButton()
    private let inspectorToggleButton = NSButton()

    // Scanner state
    private var scanners: [DiscoveredScanner] = []
    private var selectedScanner: DiscoveredScanner?
    private var capabilities: ScannerCapabilities?
    private var scannerStatus: ScannerStatus?

    // Image buffers & cached renders
    private var viewMode: CanvasViewMode = .preview
    private var rawPreviewBuffer: RawImageBuffer?
    private var rawScanBuffer: RawImageBuffer?
    private var rawScanProxyBuffer: RawImageBuffer?
    private var renderedFullScanImage: CGImage?
    private var fullScanRenderSignature: RenderSignature?

    private var lastSavedURL: URL?
    private var activeTask: Task<Void, Never>?
    private var previewRenderTask: Task<Void, Never>?
    private var fullScanRenderTask: Task<Void, Never>?
    private var tileRenderTask: Task<Void, Never>?
    private var isBusy = false

    private struct RenderSignature: Equatable {
        let rotation: ScanRotation
        let colorProfile: ColorProfileMode
        let toneAdjustments: ToneAdjustments
    }

    private enum ToolbarID {
        static let scannerPicker = NSToolbarItem.Identifier("scannerPicker")
        static let refresh = NSToolbarItem.Identifier("refresh")
        static let viewMode = NSToolbarItem.Identifier("viewMode")
        static let preview = NSToolbarItem.Identifier("preview")
        static let scan = NSToolbarItem.Identifier("scan")
        static let export = NSToolbarItem.Identifier("export")
        static let inspector = NSToolbarItem.Identifier("inspector")
    }

    init() {
        self.inspectorVC = InspectorViewController(preferences: prefs)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "ChromaScan"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 880, height: 560)
        window.colorSpace = .displayP3
        window.setFrameAutosaveName("ChromaScanMainWindow")
        window.center()

        super.init(window: window)

        setupSplitView()
        setupToolbar()
        wireCallbacks()
        updateViewModeUI()
        updateDimensionsReadout()

        browser.start()
        canvasVC.footerView.setIdle(status: "Searching for Wi-Fi scanners…", showReveal: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupSplitView() {
        let canvasItem = NSSplitViewItem(viewController: canvasVC)
        canvasItem.minimumThickness = 500
        canvasItem.holdingPriority = .defaultLow

        let inspItem = NSSplitViewItem(inspectorWithViewController: inspectorVC)
        inspItem.minimumThickness = 295
        inspItem.maximumThickness = 350
        inspItem.canCollapse = true
        self.inspectorSplitItem = inspItem

        splitVC.addSplitViewItem(canvasItem)
        splitVC.addSplitViewItem(inspItem)
        window?.contentViewController = splitVC
    }

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "ChromaScanMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    private func wireCallbacks() {
        browser.onScannersChanged = { [weak self] found in
            self?.handleDiscoveredScanners(found)
        }

        canvasVC.canvasView.onCropChanged = { [weak self] _ in
            self?.updateDimensionsReadout()
        }

        canvasVC.canvasView.onZoomChanged = { [weak self] scale, isFit in
            self?.canvasVC.footerView.updateZoom(effectiveScale: scale, isFit: isFit)
        }

        canvasVC.canvasView.onViewportSettled = { [weak self] in
            self?.refreshHighResOverlayTile()
        }

        canvasVC.footerView.onResetCrop = { [weak self] in
            self?.resetCrop()
        }

        canvasVC.footerView.onCancel = { [weak self] in
            self?.cancelActiveOperation()
        }

        canvasVC.footerView.onRevealLastSaved = { [weak self] in
            self?.revealLastSaved()
        }

        canvasVC.footerView.onZoomOut = { [weak self] in
            self?.zoomOutClicked()
        }

        canvasVC.footerView.onZoomIn = { [weak self] in
            self?.zoomInClicked()
        }

        canvasVC.footerView.onZoomFit = { [weak self] in
            self?.zoomToFitClicked()
        }

        canvasVC.footerView.onZoomActualSize = { [weak self] in
            self?.zoomActualSizeClicked()
        }

        inspectorVC.onScanSettingsChanged = { [weak self] in
            self?.updateDimensionsReadout()
        }

        inspectorVC.onPreviewDisplayChanged = { [weak self] in
            guard let self else { return }
            self.canvasVC.canvasView.rotation = self.inspectorVC.selectedRotation
            self.reRenderActiveView()
            self.updateDimensionsReadout()
        }

        canvasVC.canvasView.rotation = inspectorVC.selectedRotation
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarID.scannerPicker,
            ToolbarID.refresh,
            .flexibleSpace,
            ToolbarID.viewMode,
            .flexibleSpace,
            ToolbarID.preview,
            ToolbarID.scan,
            ToolbarID.export,
            .inspectorTrackingSeparator,
            ToolbarID.inspector
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarID.scannerPicker:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Scanner"
            scannerPopup.controlSize = .regular
            scannerPopup.target = self
            scannerPopup.action = #selector(scannerPopupChanged)
            scannerPopup.translatesAutoresizingMaskIntoConstraints = false
            scannerPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
            scannerPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 290).isActive = true
            rebuildScannerMenu()
            item.view = scannerPopup
            return item

        case ToolbarID.refresh:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Refresh"
            item.toolTip = "Refresh Wi-Fi scanners and status"
            refreshButton.bezelStyle = .texturedRounded
            refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
            refreshButton.target = self
            refreshButton.action = #selector(refreshScannersClicked)
            item.view = refreshButton
            return item

        case ToolbarID.viewMode:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "View"
            viewModeSegment.segmentCount = 2
            viewModeSegment.trackingMode = .selectOne
            viewModeSegment.segmentStyle = .texturedRounded
            viewModeSegment.setLabel("Preview", forSegment: 0)
            viewModeSegment.setLabel("Last Scan", forSegment: 1)
            viewModeSegment.selectedSegment = viewMode.rawValue
            viewModeSegment.setEnabled(false, forSegment: 1)
            viewModeSegment.target = self
            viewModeSegment.action = #selector(viewModeSegmentChanged)
            item.view = viewModeSegment
            return item

        case ToolbarID.preview:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Preview"
            item.toolTip = "Fast low-DPI flatbed preview (⌘P)"
            previewButton.bezelStyle = .texturedRounded
            previewButton.title = "Preview"
            previewButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Preview")
            previewButton.imagePosition = .imageLeading
            previewButton.target = self
            previewButton.action = #selector(previewClicked)
            item.view = previewButton
            return item

        case ToolbarID.scan:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Scan"
            item.toolTip = "Scan and save at full resolution (⌘⏎)"
            scanButton.bezelStyle = .rounded
            scanButton.bezelColor = .controlAccentColor
            scanButton.contentTintColor = .white
            scanButton.title = "Scan"
            scanButton.image = NSImage(systemSymbolName: "scanner", accessibilityDescription: "Scan")
            scanButton.imagePosition = .imageLeading
            scanButton.target = self
            scanButton.action = #selector(scanClicked)
            item.view = scanButton
            return item

        case ToolbarID.export:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Export"
            item.toolTip = "Re-export the current scan with updated color profile, format, or tone settings (⌘S)"
            exportButton.bezelStyle = .texturedRounded
            exportButton.title = "Export"
            exportButton.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Export")
            exportButton.imagePosition = .imageLeading
            exportButton.isEnabled = false
            exportButton.target = self
            exportButton.action = #selector(exportScanClicked)
            item.view = exportButton
            return item

        case ToolbarID.inspector:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Inspector"
            item.toolTip = "Show or hide inspector (⌥⌘I)"
            inspectorToggleButton.bezelStyle = .texturedRounded
            inspectorToggleButton.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Inspector")
            inspectorToggleButton.target = self
            inspectorToggleButton.action = #selector(toggleInspector)
            item.view = inspectorToggleButton
            return item

        default:
            return nil
        }
    }

    // MARK: - Scanner Discovery & Selection

    private func handleDiscoveredScanners(_ found: [DiscoveredScanner]) {
        let prevID = selectedScanner?.id
        self.scanners = found

        if let prevID, let stillPresent = found.first(where: { $0.id == prevID }) {
            selectedScanner = stillPresent
        } else if selectedScanner == nil, let first = found.first {
            selectedScanner = first
            loadCapabilities(for: first)
        } else if found.isEmpty {
            selectedScanner = nil
            capabilities = nil
            scannerStatus = nil
            inspectorVC.applyCapabilities(nil)
            if !isBusy {
                canvasVC.footerView.setIdle(status: "No Wi-Fi scanners found", showReveal: lastSavedURL != nil)
            }
        }

        rebuildScannerMenu()
        updateActionButtons()
    }

    private func rebuildScannerMenu() {
        scannerPopup.removeAllItems()
        if scanners.isEmpty {
            scannerPopup.addItem(withTitle: "No Scanners Found")
            scannerPopup.lastItem?.isEnabled = false
        } else {
            for s in scanners {
                let suffix: String
                if s.id == selectedScanner?.id, let status = scannerStatus {
                    suffix = " (\(status.state))"
                } else {
                    suffix = ""
                }
                scannerPopup.addItem(withTitle: s.displayTitle + suffix)
                scannerPopup.lastItem?.representedObject = s.id
            }
            if let selID = selectedScanner?.id,
               let idx = scanners.firstIndex(where: { $0.id == selID }) {
                scannerPopup.selectItem(at: idx)
            }
        }

        scannerPopup.menu?.addItem(.separator())
        let manualItem = NSMenuItem(title: "Add Scanner by Host / IP…", action: #selector(showAddManualScannerSheet), keyEquivalent: "")
        manualItem.target = self
        scannerPopup.menu?.addItem(manualItem)
    }

    private func loadCapabilities(for scanner: DiscoveredScanner) {
        if !isBusy {
            canvasVC.footerView.setIdle(status: "Connecting to \(scanner.displayTitle)…", showReveal: false)
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                async let capsTask = client.fetchCapabilities(from: scanner)
                async let statusTask = client.fetchStatus(from: scanner)
                let (caps, status) = try await (capsTask, statusTask)
                guard self.selectedScanner?.id == scanner.id else { return }
                self.capabilities = caps
                self.scannerStatus = status
                self.inspectorVC.applyCapabilities(caps)
                if let platen = caps.platen, platen.maxHeight > 0 {
                    self.canvasVC.canvasView.platenAspectRatio = CGFloat(platen.maxWidth) / CGFloat(platen.maxHeight)
                }
                self.rebuildScannerMenu()
                self.updateDimensionsReadout()
                self.updateActionButtons()
                if !self.isBusy {
                    self.canvasVC.footerView.setIdle(
                        status: "Ready · \(caps.makeAndModel) (\(status.state))",
                        showReveal: self.lastSavedURL != nil
                    )
                }
            } catch {
                guard self.selectedScanner?.id == scanner.id else { return }
                self.capabilities = nil
                self.scannerStatus = nil
                self.rebuildScannerMenu()
                self.updateActionButtons()
                if !self.isBusy {
                    self.canvasVC.footerView.setError("Could not reach scanner: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Actions (Toolbar, Footer & Menu)

    @objc private func scannerPopupChanged() {
        guard let id = scannerPopup.selectedItem?.representedObject as? String,
              let chosen = scanners.first(where: { $0.id == id }) else { return }
        if chosen.id != selectedScanner?.id {
            selectedScanner = chosen
            capabilities = nil
            scannerStatus = nil
            loadCapabilities(for: chosen)
        }
    }

    @objc private func viewModeSegmentChanged() {
        let chosen = CanvasViewMode(rawValue: viewModeSegment.selectedSegment) ?? .preview
        switchViewMode(to: chosen, resetZoom: true)
    }

    private func switchViewMode(to mode: CanvasViewMode, resetZoom: Bool) {
        if mode == .scan && rawScanBuffer == nil { return }
        viewMode = mode
        updateViewModeUI()
        if resetZoom {
            canvasVC.canvasView.zoomToFit()
        }
        reRenderActiveView()
        updateDimensionsReadout()
    }

    private func updateViewModeUI() {
        viewModeSegment.selectedSegment = viewMode.rawValue
        viewModeSegment.setEnabled(rawScanBuffer != nil, forSegment: 1)

        let showingScan = (viewMode == .scan && rawScanBuffer != nil)
        canvasVC.canvasView.showCropOverlay = !showingScan
        canvasVC.footerView.setCropResetVisible(!showingScan)

        if showingScan {
            canvasVC.canvasView.emptyStateTitle = "No Scan Yet"
            canvasVC.canvasView.emptyStateSubtitle = "Click Scan to capture a full-resolution image."
        } else {
            canvasVC.canvasView.emptyStateTitle = "No Preview Loaded"
            canvasVC.canvasView.emptyStateSubtitle = "Click Preview to inspect the flatbed, or Scan directly for a full page."
        }
    }

    @objc func refreshScannersClicked() {
        if let scanner = selectedScanner {
            loadCapabilities(for: scanner)
        }
        browser.start()
    }

    @objc func toggleInspector() {
        inspectorSplitItem.animator().isCollapsed.toggle()
    }

    @objc func resetCrop() {
        canvasVC.canvasView.cropRect = .full
        updateDimensionsReadout()
    }

    @objc func zoomInClicked() {
        canvasVC.canvasView.zoomIn()
    }

    @objc func zoomOutClicked() {
        canvasVC.canvasView.zoomOut()
    }

    @objc func zoomToFitClicked() {
        canvasVC.canvasView.zoomToFit()
    }

    @objc func zoomActualSizeClicked() {
        canvasVC.canvasView.zoomToActualSize()
    }

    @objc func revealLastSaved() {
        guard let url = lastSavedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func previewClicked() {
        startScan(isPreview: true)
    }

    @objc func scanClicked() {
        startScan(isPreview: false)
    }

    @objc func exportScanClicked() {
        exportHeldScan(destinationURL: nil)
    }

    @objc func exportScanAsClicked() {
        guard !isBusy, rawScanBuffer != nil, let window else { return }
        let fmt = inspectorVC.selectedOutputFormat
        let panel = NSSavePanel()
        panel.directoryURL = inspectorVC.saveFolderURL
        panel.nameFieldStringValue = "\(inspectorVC.baseFilename).\(fmt.fileExtension)"
        if let utType = UTType(fmt.uti) {
            panel.allowedContentTypes = [utType]
        }
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.exportHeldScan(destinationURL: url)
        }
    }

    @objc func showAddManualScannerSheet() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Add eSCL Scanner Manually"
        alert.informativeText = "Enter the printer's Bonjour hostname or local IP address (e.g. HPE8D8D11CE486.local or 192.168.1.50)."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let hostField = NSTextField(frame: NSRect(x: 0, y: 32, width: 280, height: 22))
        hostField.placeholderString = "HPE8D8D11CE486.local"
        let portField = NSTextField(frame: NSRect(x: 0, y: 0, width: 90, height: 22))
        portField.stringValue = "8080"
        let tlsCheck = NSButton(checkboxWithTitle: "Use HTTPS (port 443)", target: nil, action: nil)
        tlsCheck.frame = NSRect(x: 102, y: 2, width: 178, height: 18)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 60))
        accessory.addSubview(hostField)
        accessory.addSubview(portField)
        accessory.addSubview(tlsCheck)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = hostField

        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let self else { return }
            let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { return }
            let useTLS = (tlsCheck.state == .on)
            let port = Int(portField.stringValue) ?? (useTLS ? 443 : 8080)
            self.browser.addManualScanner(host: host, port: port, useTLS: useTLS)
            if let added = self.scanners.last {
                self.selectedScanner = added
                self.rebuildScannerMenu()
                self.loadCapabilities(for: added)
            }
        }
    }

    // MARK: - Scan Execution

    private func startScan(isPreview: Bool) {
        guard !isBusy, let scanner = selectedScanner else { return }

        let source = isPreview ? .platen : inspectorVC.selectedSource
        let inputCaps = capabilities?.caps(for: source) ?? capabilities?.platen
        let maxW = inputCaps?.maxWidth ?? 2550
        let maxH = inputCaps?.maxHeight ?? 3300

        let resolution: Int
        if isPreview {
            let available = inputCaps?.discreteResolutions ?? [75, 100, 200, 300]
            resolution = available.contains(100) ? 100 : (available.first ?? 75)
        } else {
            resolution = inspectorVC.selectedResolution
        }

        let crop: NormalizedCropRect = (isPreview || source == .feeder) ? .full : canvasVC.canvasView.cropRect
        let region = crop.toESCLRegion(maxWidth: maxW, maxHeight: maxH)

        let transfer: TransferFormat
        if isPreview {
            transfer = (inputCaps?.supportsRawOctetStream ?? true) ? .rawOctetStream : .jpeg
        } else {
            transfer = inspectorVC.selectedTransferFormat
        }

        let request = ScanJobRequest(
            version: capabilities?.version ?? "2.5",
            inputSource: source,
            resolution: resolution,
            colorMode: inspectorVC.selectedColorMode,
            intent: inspectorVC.selectedIntent,
            isPreview: false,
            transferFormat: transfer,
            region: region,
            brightness: inspectorVC.effectiveHardwareBrightness,
            contrast: inspectorVC.effectiveHardwareContrast
        )

        let rotation = inspectorVC.selectedRotation
        let colorProfile = inspectorVC.selectedColorProfile
        let toneAdjustments = inspectorVC.toneAdjustments
        let outputFormat = inspectorVC.selectedOutputFormat
        let quality = inspectorVC.selectedQuality
        let folderURL = inspectorVC.saveFolderURL
        let baseName = inspectorVC.baseFilename
        let autoInc = inspectorVC.autoIncrement
        let makeAndModel = capabilities?.makeAndModel ?? scanner.displayTitle

        setBusy(true)
        let startTime = CFAbsoluteTimeGetCurrent()
        let labelPrefix = isPreview ? "Previewing" : "Scanning \(resolution) DPI"
        canvasVC.footerView.setProgress(status: "\(labelPrefix)…", fraction: nil)

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let download = try await self.client.performScan(scanner: scanner, request: request) { [weak self] recv, expected in
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    Task { @MainActor [weak self] in
                        guard let self, self.isBusy else { return }
                        let recvMB = Double(recv) / (1024.0 * 1024.0)
                        if expected > 0 {
                            let frac = min(1.0, Double(recv) / Double(expected))
                            let expMB = Double(expected) / (1024.0 * 1024.0)
                            let status = String(format: "%@ · %.1f / %.1f MB (%.0fs)", labelPrefix, recvMB, expMB, elapsed)
                            self.canvasVC.footerView.setProgress(status: status, fraction: frac)
                        } else {
                            let status = String(format: "%@ · %.1f MB (%.0fs)", labelPrefix, recvMB, elapsed)
                            self.canvasVC.footerView.setProgress(status: status, fraction: nil)
                        }
                    }
                }

                try Task.checkCancellation()

                if isPreview {
                    self.canvasVC.footerView.setProgress(status: "Rendering preview…", fraction: nil)
                    let rawBuf = try await Task.detached(priority: .userInitiated) {
                        try ImagePipeline.decodeToRawBuffer(download: download, request: request)
                    }.value

                    self.rawPreviewBuffer = rawBuf
                    self.canvasVC.canvasView.platenAspectRatio = CGFloat(rawBuf.width) / CGFloat(max(1, rawBuf.height))
                    self.switchViewMode(to: .preview, resetZoom: true)
                    self.setBusy(false)
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    self.canvasVC.footerView.setIdle(
                        status: String(format: "Preview ready (%dx%d · %.1fs)", rawBuf.width, rawBuf.height, elapsed),
                        showReveal: self.lastSavedURL != nil
                    )
                } else {
                    self.canvasVC.footerView.setProgress(status: "Processing & saving (\(colorProfile.shortName))…", fraction: nil)
                    let exportSettings = ExportSettings(
                        rotation: rotation,
                        colorProfile: colorProfile,
                        toneAdjustments: toneAdjustments,
                        format: outputFormat,
                        quality: quality,
                        scannerMakeAndModel: makeAndModel
                    )
                    let destURL = FilenameHelper.uniqueDestinationURL(
                        in: folderURL,
                        baseName: baseName,
                        ext: outputFormat.fileExtension
                    )

                    let sig = RenderSignature(rotation: rotation, colorProfile: colorProfile, toneAdjustments: toneAdjustments)

                    let (rawBuf, proxyBuf, fullCG, fileSize) = try await Task.detached(priority: .userInitiated) {
                        let rawBuf = try ImagePipeline.decodeToRawBuffer(download: download, request: request)
                        let cgImg = try ImagePipeline.renderCGImage(
                            from: rawBuf,
                            rotation: exportSettings.rotation,
                            colorProfile: exportSettings.colorProfile,
                            toneAdjustments: exportSettings.toneAdjustments
                        )
                        try ImagePipeline.export(cgImage: cgImg, dpi: rawBuf.dpi, settings: exportSettings, to: destURL)
                        let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path)
                        let bytes = (attrs?[.size] as? Int64) ?? 0
                        let proxy = ImagePipeline.makeProxyBuffer(from: rawBuf, maxDimension: 2200)
                        return (rawBuf, proxy, cgImg, bytes)
                    }.value

                    // Retain full-res scan in memory so Color Profile, Format, Quality & Tone can be inspected live & re-exported!
                    self.rawScanBuffer = rawBuf
                    self.rawScanProxyBuffer = proxyBuf
                    self.renderedFullScanImage = fullCG
                    self.fullScanRenderSignature = sig
                    self.lastSavedURL = destURL

                    if autoInc {
                        self.inspectorVC.setFilename(FilenameHelper.incrementedFilename(baseName))
                    }
                    self.setBusy(false)
                    self.switchViewMode(to: .scan, resetZoom: true)

                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    let mb = Double(fileSize) / (1024.0 * 1024.0)
                    self.canvasVC.footerView.setIdle(
                        status: String(format: "Saved %@ (%dx%d · %.1f MB · %.1fs)", destURL.lastPathComponent, fullCG.width, fullCG.height, mb, elapsed),
                        showReveal: true
                    )
                }
            } catch ESCLClientError.cancelled {
                self.setBusy(false)
                self.canvasVC.footerView.setIdle(status: "Scan cancelled", showReveal: self.lastSavedURL != nil)
            } catch is CancellationError {
                self.setBusy(false)
                self.canvasVC.footerView.setIdle(status: "Scan cancelled", showReveal: self.lastSavedURL != nil)
            } catch {
                self.setBusy(false)
                self.canvasVC.footerView.setError(error.localizedDescription)
                self.presentErrorAlert(title: "Scan Failed", error: error)
            }
        }
    }

    // MARK: - Re-Export Held Full-Res Scan

    private func exportHeldScan(destinationURL customURL: URL?) {
        guard !isBusy, let rawBuf = rawScanBuffer else { return }

        let rotation = inspectorVC.selectedRotation
        let colorProfile = inspectorVC.selectedColorProfile
        let toneAdjustments = inspectorVC.toneAdjustments
        let outputFormat = inspectorVC.selectedOutputFormat
        let quality = inspectorVC.selectedQuality
        let folderURL = inspectorVC.saveFolderURL
        let baseName = inspectorVC.baseFilename
        let autoInc = inspectorVC.autoIncrement && customURL == nil
        let makeAndModel = capabilities?.makeAndModel ?? selectedScanner?.displayTitle

        let destURL = customURL ?? FilenameHelper.uniqueDestinationURL(
            in: folderURL,
            baseName: baseName,
            ext: outputFormat.fileExtension
        )

        let sig = RenderSignature(rotation: rotation, colorProfile: colorProfile, toneAdjustments: toneAdjustments)
        let cachedCG = (fullScanRenderSignature == sig) ? renderedFullScanImage : nil

        let settings = ExportSettings(
            rotation: rotation,
            colorProfile: colorProfile,
            toneAdjustments: toneAdjustments,
            format: outputFormat,
            quality: quality,
            scannerMakeAndModel: makeAndModel
        )

        setBusy(true)
        let startTime = CFAbsoluteTimeGetCurrent()
        canvasVC.footerView.setProgress(status: "Exporting \(destURL.lastPathComponent)…", fraction: nil)

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (fullCG, fileSize) = try await Task.detached(priority: .userInitiated) {
                    let cgImg: CGImage
                    if let cachedCG {
                        cgImg = cachedCG
                    } else {
                        cgImg = try ImagePipeline.renderCGImage(
                            from: rawBuf,
                            rotation: settings.rotation,
                            colorProfile: settings.colorProfile,
                            toneAdjustments: settings.toneAdjustments
                        )
                    }
                    try ImagePipeline.export(cgImage: cgImg, dpi: rawBuf.dpi, settings: settings, to: destURL)
                    let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path)
                    let bytes = (attrs?[.size] as? Int64) ?? 0
                    return (cgImg, bytes)
                }.value

                self.renderedFullScanImage = fullCG
                self.fullScanRenderSignature = sig
                self.lastSavedURL = destURL
                if autoInc {
                    self.inspectorVC.setFilename(FilenameHelper.incrementedFilename(baseName))
                }
                self.setBusy(false)
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                let mb = Double(fileSize) / (1024.0 * 1024.0)
                self.canvasVC.footerView.setIdle(
                    status: String(format: "Exported %@ (%.1f MB · %.2fs)", destURL.lastPathComponent, mb, elapsed),
                    showReveal: true
                )
            } catch {
                self.setBusy(false)
                self.canvasVC.footerView.setError(error.localizedDescription)
                self.presentErrorAlert(title: "Export Failed", error: error)
            }
        }
    }

    private func cancelActiveOperation() {
        activeTask?.cancel()
        activeTask = nil
    }

    // MARK: - Live Color Profile, Format, Quality & Tone Rendering

    private func reRenderActiveView() {
        let activeSource: RawImageBuffer?
        let trueBuf: RawImageBuffer?
        switch viewMode {
        case .preview:
            activeSource = rawPreviewBuffer
            trueBuf = rawPreviewBuffer
        case .scan:
            activeSource = rawScanProxyBuffer ?? rawScanBuffer
            trueBuf = rawScanBuffer
        }

        guard let sourceBuf = activeSource, let fullBuf = trueBuf else {
            canvasVC.canvasView.previewImage = nil
            canvasVC.canvasView.truePixelSize = .zero
            canvasVC.footerView.setZoomEnabled(false)
            inspectorVC.setOutputPreviewSummary("")
            return
        }

        let rotation = inspectorVC.selectedRotation
        let profile = inspectorVC.selectedColorProfile
        let tone = inspectorVC.toneAdjustments
        let format = inspectorVC.selectedOutputFormat
        let quality = inspectorVC.selectedQuality
        let simulateCompression = inspectorVC.previewCompressionEnabled && format.supportsQuality
        let sig = RenderSignature(rotation: rotation, colorProfile: profile, toneAdjustments: tone)

        let trueRotatedSize: CGSize = (rotation == .deg90 || rotation == .deg270)
            ? CGSize(width: fullBuf.height, height: fullBuf.width)
            : CGSize(width: fullBuf.width, height: fullBuf.height)

        canvasVC.canvasView.truePixelSize = trueRotatedSize
        canvasVC.footerView.setZoomEnabled(true)

        // 1. Fast proxy / preview render (updates in <15ms for live sliders!)
        previewRenderTask?.cancel()
        previewRenderTask = Task.detached(priority: .userInitiated) { [weak self] in
            if Task.isCancelled { return }
            guard let baseImg = try? ImagePipeline.renderCGImage(
                from: sourceBuf,
                rotation: rotation,
                colorProfile: profile,
                toneAdjustments: tone
            ) else { return }
            if Task.isCancelled { return }

            var displayImg = baseImg
            var summary: String
            let profileLabel = (sourceBuf.colorMode == .grayscale8) ? "Grayscale" : profile.shortName

            if simulateCompression,
               let sim = ImagePipeline.simulateLossyFormat(cgImage: baseImg, format: format, quality: quality) {
                displayImg = sim.image
                // Estimate full-resolution compressed size by scaling proxy bytes by pixel ratio
                let proxyPixels = Double(max(1, baseImg.width * baseImg.height))
                let fullPixels = Double(max(1, Int(trueRotatedSize.width * trueRotatedSize.height)))
                let estBytes = Double(sim.encodedBytes) * (fullPixels / proxyPixels)
                let estMB = estBytes / (1024.0 * 1024.0)
                let sizeText = estMB >= 1.0 ? String(format: "~%.1f MB", estMB) : String(format: "~%.0f KB", estBytes / 1024.0)
                let qPct = Int((quality * 100).rounded())
                summary = "Live: \(profileLabel) · \(format.displayName) \(qPct)% (\(sizeText) est.)"
            } else {
                let rawMB = Double(fullBuf.width * fullBuf.height * fullBuf.colorMode.bytesPerPixel) / (1024.0 * 1024.0)
                let fmtSuffix = format.supportsQuality ? "\(format.displayName) (compression preview off)" : "\(format.displayName) · ~\(Int(rawMB.rounded())) MB raw"
                summary = "Live: \(profileLabel) · \(fmtSuffix)"
            }

            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.canvasVC.canvasView.previewImage = displayImg
                self.inspectorVC.setOutputPreviewSummary(summary)
                self.refreshHighResOverlayTile()
            }
        }

        // 2. When in Scan mode, also keep full-res rendered CGImage fresh in the background (~34ms in vImage!)
        if viewMode == .scan, let rawScan = rawScanBuffer, fullScanRenderSignature != sig {
            fullScanRenderTask?.cancel()
            fullScanRenderTask = Task.detached(priority: .utility) { [weak self] in
                if Task.isCancelled { return }
                guard let fullCG = try? ImagePipeline.renderCGImage(
                    from: rawScan,
                    rotation: rotation,
                    colorProfile: profile,
                    toneAdjustments: tone
                ) else { return }
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.renderedFullScanImage = fullCG
                    self.fullScanRenderSignature = sig
                    self.refreshHighResOverlayTile()
                }
            }
        }
    }

    /// When zoomed into a full-res Scan, crops ONLY the visible 1:1 pixel region from `renderedFullScanImage`
    /// and optionally runs real JPEG/HEIC compression on that 1:1 tile so pixel-peeping is razor sharp & instant.
    private func refreshHighResOverlayTile() {
        tileRenderTask?.cancel()

        guard viewMode == .scan,
              let fullCG = renderedFullScanImage,
              let proxyImg = canvasVC.canvasView.previewImage,
              fullCG.width > proxyImg.width,
              let visibleNorm = canvasVC.canvasView.visibleNormalizedRect() else {
            canvasVC.canvasView.highResOverlayTile = nil
            return
        }

        // Only bother rendering a 1:1 tile when zoomed past the proxy's native resolution
        let proxyToFullRatio = CGFloat(proxyImg.width) / CGFloat(max(1, fullCG.width))
        guard canvasVC.canvasView.effectiveZoomScale > proxyToFullRatio * 1.05 else {
            canvasVC.canvasView.highResOverlayTile = nil
            return
        }

        let format = inspectorVC.selectedOutputFormat
        let quality = inspectorVC.selectedQuality
        let simulateCompression = inspectorVC.previewCompressionEnabled && format.supportsQuality

        // Pad slightly to avoid edge seams while keeping pixel coordinates aligned
        let pad: CGFloat = 0.01
        let nx = max(0, visibleNorm.minX - pad)
        let ny = max(0, visibleNorm.minY - pad)
        let maxX = min(1, visibleNorm.maxX + pad)
        let maxY = min(1, visibleNorm.maxY + pad)

        let fw = CGFloat(fullCG.width)
        let fh = CGFloat(fullCG.height)
        let pxX = max(0, Int((nx * fw).rounded(.down)))
        let pxY = max(0, Int((ny * fh).rounded(.down)))
        let pxMaxX = min(fullCG.width, Int((maxX * fw).rounded(.up)))
        let pxMaxY = min(fullCG.height, Int((maxY * fh).rounded(.up)))
        let pxW = pxMaxX - pxX
        let pxH = pxMaxY - pxY
        guard pxW > 4, pxH > 4 else { return }

        // Avoid huge tiles if user is barely zoomed in
        guard pxW * pxH <= 18_000_000 else { return }

        let cropRectPx = CGRect(x: pxX, y: pxY, width: pxW, height: pxH)
        let exactNorm = CGRect(
            x: CGFloat(pxX) / fw,
            y: CGFloat(pxY) / fh,
            width: CGFloat(pxW) / fw,
            height: CGFloat(pxH) / fh
        )

        tileRenderTask = Task.detached(priority: .userInitiated) { [weak self] in
            if Task.isCancelled { return }
            guard let cropped = fullCG.cropping(to: cropRectPx) else { return }
            if Task.isCancelled { return }

            let finalTile: CGImage
            if simulateCompression,
               let sim = ImagePipeline.simulateLossyFormat(cgImage: cropped, format: format, quality: quality) {
                finalTile = sim.image
            } else {
                finalTile = cropped
            }

            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self, self.viewMode == .scan else { return }
                self.canvasVC.canvasView.highResOverlayTile = PreviewCanvasView.OverlayTile(
                    image: finalTile,
                    normalizedRect: exactNorm
                )
            }
        }
    }

    // MARK: - Helpers

    private func setBusy(_ busy: Bool) {
        self.isBusy = busy
        inspectorVC.setBusy(busy)
        scannerPopup.isEnabled = !busy
        refreshButton.isEnabled = !busy
        updateActionButtons()
    }

    private func updateActionButtons() {
        let ready = !isBusy && selectedScanner != nil && capabilities != nil
        previewButton.isEnabled = ready && (capabilities?.platen != nil)
        scanButton.isEnabled = ready
        exportButton.isEnabled = !isBusy && rawScanBuffer != nil
        viewModeSegment.setEnabled(rawScanBuffer != nil, forSegment: 1)
    }

    private func updateDimensionsReadout() {
        if viewMode == .scan, let rawScan = rawScanBuffer {
            let rotated = (inspectorVC.selectedRotation == .deg90 || inspectorVC.selectedRotation == .deg270)
            let w = rotated ? rawScan.height : rawScan.width
            let h = rotated ? rawScan.width : rawScan.height
            let profile = (rawScan.colorMode == .grayscale8) ? "Grayscale" : inspectorVC.selectedColorProfile.shortName
            canvasVC.footerView.updateScanDimensions(pixelWidth: w, pixelHeight: h, dpi: rawScan.dpi, profileName: profile)
            return
        }

        let source = inspectorVC.selectedSource
        let inputCaps = capabilities?.caps(for: source) ?? capabilities?.platen
        let maxW = inputCaps?.maxWidth ?? 2550
        let maxH = inputCaps?.maxHeight ?? 3508

        let crop = (source == .feeder) ? .full : canvasVC.canvasView.cropRect
        let region = crop.toESCLRegion(maxWidth: maxW, maxHeight: maxH)
        let dpi = inspectorVC.selectedResolution
        let bpp = inspectorVC.selectedColorMode.bytesPerPixel

        var wIn = Double(region.width) / 300.0
        var hIn = Double(region.height) / 300.0
        var pxW = Int((wIn * Double(dpi)).rounded())
        var pxH = Int((hIn * Double(dpi)).rounded())

        if inspectorVC.selectedRotation == .deg90 || inspectorVC.selectedRotation == .deg270 {
            swap(&wIn, &hIn)
            swap(&pxW, &pxH)
        }

        let rawBytes = Int64(pxW) * Int64(pxH) * Int64(bpp)
        canvasVC.footerView.updateDimensions(
            widthInches: wIn,
            heightInches: hIn,
            pixelWidth: pxW,
            pixelHeight: pxH,
            estimatedRawBytes: rawBytes,
            isFullPage: crop.isFull
        )
    }

    private func presentErrorAlert(title: String, error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}

// MARK: - Canvas + Footer Container VC

@MainActor
private final class CanvasContainerViewController: NSViewController {
    let canvasView = PreviewCanvasView()
    let footerView = StatusFooterView()

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        self.view = container

        canvasView.translatesAutoresizingMaskIntoConstraints = false
        footerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(canvasView)
        container.addSubview(footerView)

        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            canvasView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvasView.bottomAnchor.constraint(equalTo: footerView.topAnchor),

            footerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}
