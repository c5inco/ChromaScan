import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = AppPreferences()
    private var engine: ScanSessionEngine?
    private var companionServer: CompanionServer?
    private var mainWindowController: MainWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        if let appIcon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = appIcon
        }
        buildMainMenu()

        let engine = ScanSessionEngine(preferences: preferences)
        self.engine = engine

        // Optional fixed port via launch arg `--companion-port <port>` for automated testing
        let args = ProcessInfo.processInfo.arguments
        var fixedPort: UInt16 = 0
        if let idx = args.firstIndex(of: "--companion-port"), idx + 1 < args.count,
           let parsed = UInt16(args[idx + 1]) {
            fixedPort = parsed
        }
        if let idx = args.firstIndex(of: "--companion-pin"), idx + 1 < args.count {
            let pin = args[idx + 1]
            if pin.count == 6 && pin.allSatisfy(\.isNumber) {
                preferences.pairingPIN = pin
            }
        }

        let server = CompanionServer(
            engine: engine,
            preferences: preferences,
            advertiseBonjour: true,
            port: fixedPort
        )
        self.companionServer = server

        let controller = MainWindowController(engine: engine, companionServer: server)
        controller.onMenuBarModeChanged = { [weak self] enabled in
            self?.updateStatusItem(enabled: enabled)
        }
        self.mainWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        updateStatusItem(enabled: preferences.keepRunningInMenuBar)

        engine.startDiscovery()
        if preferences.companionServerEnabled {
            server.start()
        }

        if args.contains("--seed-demo-buffers") {
            seedDemoArtwork(into: engine)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !preferences.keepRunningInMenuBar
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindowController?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionServer?.stop()
        engine?.stopDiscovery()
    }

    // MARK: - Optional Menu Bar Mode

    private func updateStatusItem(enabled: Bool) {
        if enabled {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.image = NSImage(systemSymbolName: "scanner", accessibilityDescription: "ChromaScan")
                item.menu = buildStatusMenu()
                statusItem = item
            } else {
                statusItem?.menu = buildStatusMenu()
            }
        } else if let existing = statusItem {
            NSStatusBar.system.removeStatusItem(existing)
            statusItem = nil
        }
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open ChromaScan", action: #selector(openMainWindow), keyEquivalent: "")
        menu.addItem(.separator())

        let statusText: String
        if let server = companionServer, server.isRunning {
            let c = server.connectedClients.count
            statusText = c > 0 ? "iPhone Companion: \(c) Connected" : "iPhone Companion: Ready (PIN \(preferences.pairingPIN))"
        } else {
            statusText = "iPhone Companion: Off"
        }
        let infoItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        infoItem.isEnabled = false
        menu.addItem(infoItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ChromaScan", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action == #selector(openMainWindow) {
            item.target = self
        }
        return menu
    }

    @objc private func openMainWindow() {
        mainWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Demo Artwork Seeder (for Simulator / Visual Verification)

    private func seedDemoArtwork(into engine: ScanSessionEngine) {
        let pw = 850, ph = 1170
        let previewData = makeArtworkRGB24(width: pw, height: ph)
        let preview = RawImageBuffer(data: previewData, width: pw, height: ph, bytesPerRow: pw * 3, colorMode: .rgb24, dpi: 100)

        let sw = 2400, sh = 3200
        let scanData = makeArtworkRGB24(width: sw, height: sh)
        let scan = RawImageBuffer(data: scanData, width: sw, height: sh, bytesPerRow: sw * 3, colorMode: .rgb24, dpi: 600)

        engine.loadSyntheticBuffersForTesting(preview: preview, scan: scan)
    }

    private func makeArtworkRGB24(width: Int, height: Int) -> Data {
        var data = Data(count: width * height * 3)
        data.withUnsafeMutableBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            for y in 0..<height {
                let ny = Double(y) / Double(max(1, height - 1))
                for x in 0..<width {
                    let nx = Double(x) / Double(max(1, width - 1))
                    let off = (y * width + x) * 3
                    // Warm cream paper border + rich watercolor botanical gradient + crisp registration grid
                    let inArt = nx > 0.08 && nx < 0.92 && ny > 0.07 && ny < 0.93
                    if !inArt {
                        ptr[off] = 246
                        ptr[off + 1] = 242
                        ptr[off + 2] = 234
                    } else {
                        let cx = nx - 0.5
                        let cy = ny - 0.48
                        let dist = sqrt(cx * cx + cy * cy)
                        let fineLine = (x % 40 == 0 || y % 40 == 0)
                        if dist < 0.24 {
                            // Vivid vermilion / coral sun circle (great Display P3 saturation test)
                            ptr[off] = fineLine ? 255 : 235
                            ptr[off + 1] = UInt8(max(0, min(255, Int(72 + ny * 90))))
                            ptr[off + 2] = UInt8(max(0, min(255, Int(58 + nx * 60))))
                        } else {
                            // Deep cerulean to emerald watercolor wash
                            let r = Int(32 + nx * 70 + (fineLine ? 18 : 0))
                            let g = Int(96 + ny * 115 + (fineLine ? 18 : 0))
                            let b = Int(168 + (1.0 - nx) * 75)
                            ptr[off] = UInt8(max(0, min(255, r)))
                            ptr[off + 1] = UInt8(max(0, min(255, g)))
                            ptr[off + 2] = UInt8(max(0, min(255, b)))
                        }
                    }
                }
            }
        }
        return data
    }

    // MARK: - Main Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About ChromaScan", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ChromaScan", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ChromaScan", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "Scanner")
        let previewItem = fileMenu.addItem(withTitle: "Preview Flatbed", action: #selector(MainWindowController.previewClicked), keyEquivalent: "p")
        previewItem.keyEquivalentModifierMask = [.command]

        let scanItem = fileMenu.addItem(withTitle: "Scan & Save", action: #selector(MainWindowController.scanClicked), keyEquivalent: "\r")
        scanItem.keyEquivalentModifierMask = [.command]

        fileMenu.addItem(.separator())
        let exportItem = fileMenu.addItem(withTitle: "Export Current Scan", action: #selector(MainWindowController.exportScanClicked), keyEquivalent: "s")
        exportItem.keyEquivalentModifierMask = [.command]

        let exportAsItem = fileMenu.addItem(withTitle: "Export Current Scan As…", action: #selector(MainWindowController.exportScanAsClicked), keyEquivalent: "s")
        exportAsItem.keyEquivalentModifierMask = [.command, .shift]

        fileMenu.addItem(.separator())
        let refreshItem = fileMenu.addItem(withTitle: "Refresh Scanners", action: #selector(MainWindowController.refreshScannersClicked), keyEquivalent: "r")
        refreshItem.keyEquivalentModifierMask = [.command]

        fileMenu.addItem(withTitle: "Add Scanner by Host / IP…", action: #selector(MainWindowController.showAddManualScannerSheet), keyEquivalent: "")
        fileMenu.addItem(withTitle: "iPhone Companion…", action: #selector(MainWindowController.toggleCompanionPopover), keyEquivalent: "")

        fileMenu.addItem(.separator())
        let revealItem = fileMenu.addItem(withTitle: "Reveal Last Scan in Finder", action: #selector(MainWindowController.revealLastSaved), keyEquivalent: "r")
        revealItem.keyEquivalentModifierMask = [.command, .shift]

        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let zoomInItem = viewMenu.addItem(withTitle: "Zoom In", action: #selector(MainWindowController.zoomInClicked), keyEquivalent: "+")
        zoomInItem.keyEquivalentModifierMask = [.command]
        let zoomOutItem = viewMenu.addItem(withTitle: "Zoom Out", action: #selector(MainWindowController.zoomOutClicked), keyEquivalent: "-")
        zoomOutItem.keyEquivalentModifierMask = [.command]
        let zoomFitItem = viewMenu.addItem(withTitle: "Zoom to Fit", action: #selector(MainWindowController.zoomToFitClicked), keyEquivalent: "0")
        zoomFitItem.keyEquivalentModifierMask = [.command]
        let zoomActualItem = viewMenu.addItem(withTitle: "Actual Size (100%)", action: #selector(MainWindowController.zoomActualSizeClicked), keyEquivalent: "1")
        zoomActualItem.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(.separator())
        let trimEmptySpaceItem = viewMenu.addItem(withTitle: "Trim Empty Space", action: #selector(MainWindowController.trimEmptySpaceClicked), keyEquivalent: "t")
        trimEmptySpaceItem.keyEquivalentModifierMask = [.command, .shift]
        let resetCropItem = viewMenu.addItem(withTitle: "Reset Crop to Full Page", action: #selector(MainWindowController.resetCrop), keyEquivalent: "0")
        resetCropItem.keyEquivalentModifierMask = [.command, .option]
        let toggleInspItem = viewMenu.addItem(withTitle: "Toggle Inspector", action: #selector(MainWindowController.toggleInspector), keyEquivalent: "i")
        toggleInspItem.keyEquivalentModifierMask = [.command, .option]
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
