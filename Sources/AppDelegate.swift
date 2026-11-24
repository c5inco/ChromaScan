import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appIcon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = appIcon
        }
        buildMainMenu()
        let controller = MainWindowController()
        self.mainWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
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

        // File / Scanner menu
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

        fileMenu.addItem(.separator())
        let revealItem = fileMenu.addItem(withTitle: "Reveal Last Scan in Finder", action: #selector(MainWindowController.revealLastSaved), keyEquivalent: "r")
        revealItem.keyEquivalentModifierMask = [.command, .shift]

        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu (for filename text field copy/paste/select-all)
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

        // View menu
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
        let resetCropItem = viewMenu.addItem(withTitle: "Reset Crop to Full Page", action: #selector(MainWindowController.resetCrop), keyEquivalent: "0")
        resetCropItem.keyEquivalentModifierMask = [.command, .option]
        let toggleInspItem = viewMenu.addItem(withTitle: "Toggle Inspector", action: #selector(MainWindowController.toggleInspector), keyEquivalent: "i")
        toggleInspItem.keyEquivalentModifierMask = [.command, .option]
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu
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
