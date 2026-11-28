import AppKit
import UniformTypeIdentifiers

@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSMenuItemValidation, NSWindowDelegate {

    private let engine: ScanSessionEngine
    private let companionServer: CompanionServer
    private var engineObserverID: UUID?

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
    private var scanToolbarItem: NSToolbarItem?
    private let exportButton = NSButton()
    private let companionButton = NSButton()
    private let inspectorToggleButton = NSButton()

    private let companionPopover = NSPopover()
    private let companionPopoverVC: CompanionPopoverViewController

    private var tileRenderTask: Task<Void, Never>?
    private var lastViewMode: CanvasViewMode = .preview
    private var isTrimHiddenAfterTrim: Bool = false
    private var lastCropWasFull: Bool = true
    private var lastWasPreviewBusy: Bool = false

    var onMenuBarModeChanged: ((Bool) -> Void)? {
        didSet { companionPopoverVC.onMenuBarModeChanged = onMenuBarModeChanged }
    }

    private enum ToolbarID {
        static let scannerPicker = NSToolbarItem.Identifier("scannerPicker")
        static let refresh = NSToolbarItem.Identifier("refresh")
        static let viewMode = NSToolbarItem.Identifier("viewMode")
        static let preview = NSToolbarItem.Identifier("preview")
        static let scan = NSToolbarItem.Identifier("scan")
        static let export = NSToolbarItem.Identifier("export")
        static let companion = NSToolbarItem.Identifier("companion")
        static let inspector = NSToolbarItem.Identifier("inspector")
    }

    init(engine: ScanSessionEngine, companionServer: CompanionServer) {
        self.engine = engine
        self.companionServer = companionServer
        self.inspectorVC = InspectorViewController(engine: engine)
        self.companionPopoverVC = CompanionPopoverViewController(
            server: companionServer,
            preferences: engine.preferences
        )

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
        window.delegate = self

        companionPopover.contentViewController = companionPopoverVC
        companionPopover.behavior = .transient

        setupSplitView()
        setupToolbar()
        wireCallbacks()
        applySnapshot(engine.makeSnapshot())
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
        engineObserverID = engine.addObserver { [weak self] event in
            self?.handleEngineEvent(event)
        }

        companionServer.onStateChanged = { [weak self] in
            self?.updateCompanionButtonAppearance()
            self?.companionPopoverVC.refreshUI()
        }

        canvasVC.canvasView.onCropChanged = { [weak self] rect in
            guard let self else { return }
            if rect.clamped() != self.engine.cropRect {
                self.isTrimHiddenAfterTrim = false
            }
            self.engine.setCropRect(rect)
        }

        canvasVC.canvasView.onZoomChanged = { [weak self] scale, isFit in
            self?.canvasVC.footerView.updateZoom(effectiveScale: scale, isFit: isFit)
        }

        canvasVC.canvasView.onViewportSettled = { [weak self] in
            self?.refreshHighResOverlayTile()
        }

        canvasVC.footerView.onTrimEmptySpace = { [weak self] in
            self?.trimEmptySpaceClicked()
        }

        canvasVC.footerView.onResetCrop = { [weak self] in
            self?.resetCrop()
        }

        canvasVC.footerView.onCancel = { [weak self] in
            self?.engine.cancelActiveOperation()
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
            ToolbarID.companion,
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
            rebuildScannerMenu(snapshot: engine.makeSnapshot())
            item.view = scannerPopup
            return item

        case ToolbarID.refresh:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Refresh"
            item.toolTip = "Refresh USB and Wi-Fi scanners and status"
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
            viewModeSegment.selectedSegment = engine.viewMode.segmentIndex
            viewModeSegment.setEnabled(engine.rawScanBuffer != nil, forSegment: 1)
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
            scanButton.imagePosition = .imageLeading
            scanButton.target = self
            scanButton.action = #selector(scanClicked)
            item.view = scanButton
            scanToolbarItem = item
            updateScanButtonAppearance()
            return item

        case ToolbarID.export:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Export"
            item.toolTip = "Re-export the current scan with updated color profile, format, or tone settings (⌘S)"
            exportButton.bezelStyle = .texturedRounded
            exportButton.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Export")
            exportButton.imagePosition = .imageOnly
            exportButton.isEnabled = false
            exportButton.target = self
            exportButton.action = #selector(exportScanClicked)
            item.view = exportButton
            return item

        case ToolbarID.companion:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "iPhone Companion"
            item.toolTip = "iPhone Companion pairing PIN and status"
            companionButton.bezelStyle = .texturedRounded
            companionButton.image = NSImage(systemSymbolName: "iphone.radiowaves.left.and.right", accessibilityDescription: "iPhone Companion")
            companionButton.target = self
            companionButton.action = #selector(toggleCompanionPopover)
            updateCompanionButtonAppearance()
            item.view = companionButton
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

    // MARK: - Engine Event Handling

    private func handleEngineEvent(_ event: SessionEngineEvent) {
        switch event {
        case .snapshotChanged(let snapshot):
            applySnapshot(snapshot)

        case .displayImageUpdated(let image, let truePixelSize, let summary, _, _, _):
            canvasVC.canvasView.truePixelSize = truePixelSize
            canvasVC.canvasView.previewImage = image
            canvasVC.footerView.setZoomEnabled(true)
            inspectorVC.setOutputPreviewSummary(summary)
            refreshHighResOverlayTile()

        case .fullScanImageReady:
            refreshHighResOverlayTile()

        case .progress(_, let bytesReceived, let expectedBytes, _, let statusText, _):
            let frac: Double? = expectedBytes > 0 ? min(1.0, Double(bytesReceived) / Double(expectedBytes)) : nil
            canvasVC.footerView.setProgress(status: statusText, fraction: frac)

        case .scanCompleted, .exportCompleted:
            break

        case .error(let title, let message):
            presentErrorAlert(title: title, message: message)
        }
    }

    private func applySnapshot(_ snapshot: SessionSnapshot) {
        inspectorVC.applySnapshot(snapshot)
        rebuildScannerMenu(snapshot: snapshot)

        let modeChanged = (snapshot.viewMode != lastViewMode)
        lastViewMode = snapshot.viewMode

        canvasVC.canvasView.platenAspectRatio = CGFloat(snapshot.platenAspectRatio)
        canvasVC.canvasView.rotation = snapshot.settings.rotation
        if canvasVC.canvasView.cropRect != snapshot.cropRect {
            canvasVC.canvasView.cropRect = snapshot.cropRect
        }

        viewModeSegment.selectedSegment = snapshot.viewMode.segmentIndex
        viewModeSegment.setEnabled(snapshot.hasScanImage, forSegment: 1)

        let showingScan = (snapshot.viewMode == .scan && snapshot.hasScanImage)
        canvasVC.canvasView.showCropOverlay = !showingScan

        if showingScan {
            canvasVC.canvasView.emptyStateTitle = "No Scan Yet"
            canvasVC.canvasView.emptyStateSubtitle = "Click Scan to capture a full-resolution image."
        } else {
            canvasVC.canvasView.emptyStateTitle = "No Preview Loaded"
            canvasVC.canvasView.emptyStateSubtitle = "Click Preview to inspect the flatbed, or Scan directly for a full page."
        }

        let hasImageForMode = showingScan ? snapshot.hasScanImage : snapshot.hasPreviewImage
        if !showingScan {
            let returnedToFullPage = !lastCropWasFull && snapshot.cropRect.isFull
            let freshPreviewCompleted = lastWasPreviewBusy && !snapshot.isBusy && snapshot.hasPreviewImage
            if returnedToFullPage || freshPreviewCompleted {
                isTrimHiddenAfterTrim = false
            }
        }
        lastCropWasFull = snapshot.cropRect.isFull
        lastWasPreviewBusy = snapshot.isBusy && snapshot.activeOperation == .preview

        canvasVC.footerView.updateTrimControls(
            showingScan: showingScan,
            hasImage: hasImageForMode,
            isCropFull: snapshot.cropRect.isFull,
            isScanTrimmed: snapshot.isScanTrimmed,
            isTrimHiddenAfterTrim: isTrimHiddenAfterTrim,
            isBusy: snapshot.isBusy
        )
        if !hasImageForMode {
            canvasVC.canvasView.previewImage = nil
            canvasVC.canvasView.truePixelSize = .zero
            canvasVC.footerView.setZoomEnabled(false)
        } else if modeChanged {
            canvasVC.canvasView.zoomToFit()
        }

        // Toolbar enablement
        let ready = !snapshot.isBusy && snapshot.selectedScannerID != nil && snapshot.capabilities != nil
        scannerPopup.isEnabled = !snapshot.isBusy
        refreshButton.isEnabled = !snapshot.isBusy
        previewButton.isEnabled = ready && (snapshot.capabilities?.platen != nil)
        scanButton.isEnabled = ready
        updateScanButtonAppearance()
        exportButton.isEnabled = !snapshot.isBusy && snapshot.hasScanImage

        // Footer status
        if !snapshot.isBusy {
            if snapshot.isErrorStatus {
                canvasVC.footerView.setError(snapshot.statusText)
            } else {
                canvasVC.footerView.setIdle(
                    status: snapshot.statusText,
                    showReveal: engine.lastSavedURL != nil
                )
            }
        }

        updateDimensionsReadout(snapshot: snapshot)
        updateCompanionButtonAppearance()
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        updateScanButtonAppearance()
    }

    func windowDidResignKey(_ notification: Notification) {
        updateScanButtonAppearance()
    }

    private func updateScanButtonAppearance() {
        let isProminent = scanButton.isEnabled && (window?.isKeyWindow ?? false)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let baseSymbol = NSImage(systemSymbolName: "scanner", accessibilityDescription: "Scan")

        if isProminent {
            let foreground: NSColor
            if #available(macOS 26.0, *) {
                scanToolbarItem?.style = .prominent
                scanToolbarItem?.backgroundTintColor = ChromaTheme.creamNS.withAlphaComponent(0.32)
                scanButton.bezelColor = nil
                foreground = ChromaTheme.creamNS
            } else {
                scanButton.bezelColor = ChromaTheme.creamNS
                foreground = ChromaTheme.inkNS
            }
            scanButton.contentTintColor = foreground
            scanButton.image = baseSymbol?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [foreground])
            ) ?? baseSymbol
            scanButton.attributedTitle = NSAttributedString(
                string: "Scan",
                attributes: [
                    .foregroundColor: foreground,
                    .font: font
                ]
            )
        } else {
            if #available(macOS 26.0, *) {
                scanToolbarItem?.style = .plain
                scanToolbarItem?.backgroundTintColor = nil
            }
            scanButton.bezelColor = nil
            scanButton.contentTintColor = nil
            scanButton.image = baseSymbol
            scanButton.font = font
            scanButton.title = "Scan"
        }
    }

    private func updateCompanionButtonAppearance() {
        let count = companionServer.connectedClients.count
        if count > 0 {
            companionButton.contentTintColor = .systemGreen
            companionButton.toolTip = "iPhone Companion (\(count) connected)"
        } else if companionServer.isRunning {
            companionButton.contentTintColor = nil
            companionButton.toolTip = "iPhone Companion ready (PIN: \(engine.preferences.pairingPIN))"
        } else {
            companionButton.contentTintColor = .tertiaryLabelColor
            companionButton.toolTip = "iPhone Companion paused"
        }
    }

    private func rebuildScannerMenu(snapshot: SessionSnapshot) {
        scannerPopup.removeAllItems()
        if snapshot.scanners.isEmpty {
            scannerPopup.addItem(withTitle: "No Scanners Found")
            scannerPopup.lastItem?.isEnabled = false
        } else {
            for s in snapshot.scanners {
                let suffix: String
                if s.id == snapshot.selectedScannerID, let status = snapshot.scannerStatus {
                    suffix = " (\(status.state))"
                } else {
                    suffix = ""
                }
                scannerPopup.addItem(withTitle: s.displayTitle + suffix)
                scannerPopup.lastItem?.representedObject = s.id
                let symbolName: String
                switch s.transport {
                case .usb: symbolName = "cable.connector"
                case .wifi: symbolName = "wifi"
                case .manual: symbolName = "network"
                }
                scannerPopup.lastItem?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: s.transport.rawValue.uppercased())
            }
            if let selID = snapshot.selectedScannerID,
               let idx = snapshot.scanners.firstIndex(where: { $0.id == selID }) {
                scannerPopup.selectItem(at: idx)
            }
        }

        scannerPopup.menu?.addItem(.separator())
        let manualItem = NSMenuItem(title: "Add Scanner by Host / IP…", action: #selector(showAddManualScannerSheet), keyEquivalent: "")
        manualItem.target = self
        scannerPopup.menu?.addItem(manualItem)
    }

    // MARK: - Actions (Toolbar, Footer & Menu)

    @objc private func scannerPopupChanged() {
        guard let id = scannerPopup.selectedItem?.representedObject as? String else { return }
        engine.selectScanner(id: id)
    }

    @objc private func viewModeSegmentChanged() {
        let chosen = CanvasViewMode(segmentIndex: viewModeSegment.selectedSegment)
        engine.setViewMode(chosen)
    }

    @objc func refreshScannersClicked() {
        engine.refreshScanners()
    }

    @objc func toggleInspector() {
        inspectorSplitItem.animator().isCollapsed.toggle()
    }

    @objc func toggleCompanionPopover() {
        if companionPopover.isShown {
            companionPopover.performClose(nil)
        } else {
            companionPopoverVC.refreshUI()
            companionPopover.show(relativeTo: companionButton.bounds, of: companionButton, preferredEdge: .minY)
        }
    }

    @objc func resetCrop() {
        isTrimHiddenAfterTrim = false
        engine.resetCrop()
    }

    @objc func trimEmptySpaceClicked() {
        if window?.firstResponder is NSTextView {
            window?.makeFirstResponder(canvasVC.canvasView)
        }
        if engine.viewMode == .preview {
            isTrimHiddenAfterTrim = true
            let snap = engine.makeSnapshot()
            canvasVC.footerView.updateTrimControls(
                showingScan: false,
                hasImage: snap.hasPreviewImage,
                isCropFull: snap.cropRect.isFull,
                isScanTrimmed: snap.isScanTrimmed,
                isTrimHiddenAfterTrim: true,
                isBusy: snap.isBusy
            )
        }
        engine.trimEmptySpace()
    }

    @objc func undo(_ sender: Any?) {
        engine.undo()
    }

    @objc func redo(_ sender: Any?) {
        engine.redo()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            menuItem.title = engine.undoManager.undoMenuItemTitle
            return engine.undoManager.canUndo && !engine.isBusy
        case #selector(redo(_:)):
            menuItem.title = engine.undoManager.redoMenuItemTitle
            return engine.undoManager.canRedo && !engine.isBusy
        case #selector(trimEmptySpaceClicked):
            guard !engine.isBusy else { return false }
            return engine.viewMode == .scan
                ? (engine.rawScanBuffer != nil && !engine.isScanTrimmed)
                : (engine.rawPreviewBuffer != nil)
        case #selector(resetCrop):
            return !engine.isBusy && engine.viewMode == .preview && !engine.cropRect.isFull
        case #selector(refreshScannersClicked):
            return !engine.isBusy
        default:
            return true
        }
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
        guard let url = engine.lastSavedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func previewClicked() {
        engine.startPreview()
    }

    @objc func scanClicked() {
        engine.startScan()
    }

    @objc func exportScanClicked() {
        engine.exportCurrentScan()
    }

    @objc func exportScanAsClicked() {
        guard !engine.isBusy, engine.rawScanBuffer != nil, let window else { return }
        let fmt = engine.settings.outputFormat
        let panel = NSSavePanel()
        panel.directoryURL = engine.saveFolderURL
        panel.nameFieldStringValue = "\(engine.settings.baseFilename).\(fmt.fileExtension)"
        if let utType = UTType(fmt.uti) {
            panel.allowedContentTypes = [utType]
        }
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.engine.exportCurrentScan(to: url)
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
            self.engine.addManualScanner(host: host, port: port, useTLS: useTLS)
        }
    }

    // MARK: - Local Mac 1:1 High-Res Overlay Tile

    private func refreshHighResOverlayTile() {
        tileRenderTask?.cancel()

        guard engine.viewMode == .scan,
              let fullCG = engine.renderedFullScanImage,
              let proxyImg = canvasVC.canvasView.previewImage,
              fullCG.width > proxyImg.width,
              let visibleNorm = canvasVC.canvasView.visibleNormalizedRect() else {
            canvasVC.canvasView.highResOverlayTile = nil
            return
        }

        let proxyToFullRatio = CGFloat(proxyImg.width) / CGFloat(max(1, fullCG.width))
        guard canvasVC.canvasView.effectiveZoomScale > proxyToFullRatio * 1.05 else {
            canvasVC.canvasView.highResOverlayTile = nil
            return
        }

        let format = engine.settings.outputFormat
        let quality = engine.settings.quality
        let simulateCompression = engine.settings.previewCompressionEnabled && format.supportsQuality

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
        guard pxW > 4, pxH > 4, pxW * pxH <= 18_000_000 else { return }

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
                guard let self, self.engine.viewMode == .scan else { return }
                self.canvasVC.canvasView.highResOverlayTile = PreviewCanvasView.OverlayTile(
                    image: finalTile,
                    normalizedRect: exactNorm
                )
            }
        }
    }

    // MARK: - Helpers

    private func updateDimensionsReadout(snapshot: SessionSnapshot) {
        if snapshot.viewMode == .scan,
           let w = snapshot.scanPixelWidth,
           let h = snapshot.scanPixelHeight,
           let dpi = snapshot.scanDPI {
            let isGray = engine.rawScanBuffer?.colorMode == .grayscale8
            let profile = isGray ? "Grayscale" : snapshot.settings.colorProfile.shortName
            canvasVC.footerView.updateScanDimensions(
                pixelWidth: w,
                pixelHeight: h,
                dpi: dpi,
                profileName: profile,
                isTrimmed: snapshot.isScanTrimmed
            )
            return
        }

        let source = snapshot.settings.inputSource
        let inputCaps = snapshot.capabilities?.caps(for: source) ?? snapshot.capabilities?.platen
        let maxW = inputCaps?.maxWidth ?? 2550
        let maxH = inputCaps?.maxHeight ?? 3508

        let crop = (source == .feeder) ? .full : snapshot.cropRect
        let region = crop.toESCLRegion(maxWidth: maxW, maxHeight: maxH)
        let dpi = snapshot.settings.resolution
        let bpp = snapshot.settings.colorMode.bytesPerPixel

        var wIn = Double(region.width) / 300.0
        var hIn = Double(region.height) / 300.0
        var pxW = Int((wIn * Double(dpi)).rounded())
        var pxH = Int((hIn * Double(dpi)).rounded())

        if snapshot.settings.rotation == .deg90 || snapshot.settings.rotation == .deg270 {
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

    private func presentErrorAlert(title: String, message: String) {
        guard let window, window.isVisible else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
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
