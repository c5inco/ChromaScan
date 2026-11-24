import AppKit

/// Popover anchored to the toolbar Companion button showing server status, 6-digit Pairing PIN,
/// connected iPhones, device revocation, and optional background menu bar mode.
@MainActor
final class CompanionPopoverViewController: NSViewController {
    private let server: CompanionServer
    private let preferences: AppPreferences
    var onMenuBarModeChanged: ((Bool) -> Void)?

    private let enableSwitch = NSSwitch()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let pinValueLabel = NSTextField(labelWithString: "000 000")
    private let newPINButton = NSButton(title: "New PIN", target: nil, action: nil)
    private let connectedStack = NSStackView()
    private let pairedCountLabel = NSTextField(labelWithString: "")
    private let revokeButton = NSButton(title: "Revoke All", target: nil, action: nil)
    private let menuBarCheck = NSButton(checkboxWithTitle: "Keep running in menu bar when window closes", target: nil, action: nil)

    init(server: CompanionServer, preferences: AppPreferences) {
        self.server = server
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 270))
        self.view = root

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 320)
        ])

        // Header + Enable switch
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        let titleLabel = NSTextField(labelWithString: "iPhone Companion")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        enableSwitch.controlSize = .small
        enableSwitch.target = self
        enableSwitch.action = #selector(enableToggled)
        headerRow.addArrangedSubview(titleLabel)
        headerRow.addArrangedSubview(NSView())
        headerRow.addArrangedSubview(enableSwitch)
        stack.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true

        statusLabel.font = NSFont.systemFont(ofSize: 11.5)
        statusLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true

        stack.addArrangedSubview(makeSeparator())

        // Pairing PIN
        let pinHeader = NSTextField(labelWithString: "PAIRING PIN")
        pinHeader.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        pinHeader.textColor = .secondaryLabelColor
        stack.addArrangedSubview(pinHeader)

        let pinRow = NSStackView()
        pinRow.orientation = .horizontal
        pinRow.alignment = .centerY
        pinValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        pinValueLabel.isSelectable = true
        newPINButton.bezelStyle = .rounded
        newPINButton.controlSize = .small
        newPINButton.target = self
        newPINButton.action = #selector(regeneratePIN)
        pinRow.addArrangedSubview(pinValueLabel)
        pinRow.addArrangedSubview(NSView())
        pinRow.addArrangedSubview(newPINButton)
        stack.addArrangedSubview(pinRow)
        pinRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true

        stack.addArrangedSubview(makeSeparator())

        // Connected devices
        let connHeader = NSTextField(labelWithString: "CONNECTED DEVICES")
        connHeader.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        connHeader.textColor = .secondaryLabelColor
        stack.addArrangedSubview(connHeader)

        connectedStack.orientation = .vertical
        connectedStack.alignment = .leading
        connectedStack.spacing = 4
        stack.addArrangedSubview(connectedStack)
        connectedStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true

        let pairedRow = NSStackView()
        pairedRow.orientation = .horizontal
        pairedRow.alignment = .centerY
        pairedCountLabel.font = NSFont.systemFont(ofSize: 11.5)
        pairedCountLabel.textColor = .secondaryLabelColor
        revokeButton.bezelStyle = .rounded
        revokeButton.controlSize = .small
        revokeButton.target = self
        revokeButton.action = #selector(revokeAllClicked)
        pairedRow.addArrangedSubview(pairedCountLabel)
        pairedRow.addArrangedSubview(NSView())
        pairedRow.addArrangedSubview(revokeButton)
        stack.addArrangedSubview(pairedRow)
        pairedRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true

        stack.addArrangedSubview(makeSeparator())

        menuBarCheck.controlSize = .small
        menuBarCheck.font = NSFont.systemFont(ofSize: 11.5)
        menuBarCheck.target = self
        menuBarCheck.action = #selector(menuBarToggled)
        stack.addArrangedSubview(menuBarCheck)

        refreshUI()
    }

    func refreshUI() {
        guard isViewLoaded else { return }
        enableSwitch.state = preferences.companionServerEnabled ? .on : .off
        menuBarCheck.state = preferences.keepRunningInMenuBar ? .on : .off

        if server.isRunning, let port = server.port {
            statusLabel.stringValue = "Active on \(server.hostDisplayName) (port \(port)) · Bonjour \(CompanionConstants.bonjourServiceType)"
            statusLabel.textColor = .secondaryLabelColor
        } else if let err = server.lastError {
            statusLabel.stringValue = "Error: \(err)"
            statusLabel.textColor = .systemRed
        } else {
            statusLabel.stringValue = "Companion server is paused."
            statusLabel.textColor = .secondaryLabelColor
        }

        let pin = preferences.pairingPIN
        if pin.count == 6 {
            let mid = pin.index(pin.startIndex, offsetBy: 3)
            pinValueLabel.stringValue = "\(pin[..<mid]) \(pin[mid...])"
        } else {
            pinValueLabel.stringValue = pin
        }

        for v in connectedStack.arrangedSubviews {
            connectedStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        let clients = server.connectedClients
        if clients.isEmpty {
            let none = NSTextField(labelWithString: "No iPhone currently connected")
            none.font = NSFont.systemFont(ofSize: 12)
            none.textColor = .tertiaryLabelColor
            connectedStack.addArrangedSubview(none)
        } else {
            for client in clients {
                let row = NSStackView()
                row.orientation = .horizontal
                row.spacing = 6
                row.alignment = .centerY
                let dot = NSImageView()
                if let img = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Connected") {
                    dot.image = img
                    dot.contentTintColor = .systemGreen
                    dot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
                }
                let lbl = NSTextField(labelWithString: client.name)
                lbl.font = NSFont.systemFont(ofSize: 12, weight: .medium)
                row.addArrangedSubview(dot)
                row.addArrangedSubview(lbl)
                connectedStack.addArrangedSubview(row)
            }
        }

        let pairedCount = preferences.pairedDevices.count
        pairedCountLabel.stringValue = pairedCount == 1 ? "1 paired device" : "\(pairedCount) paired devices"
        revokeButton.isEnabled = pairedCount > 0
    }

    private func makeSeparator() -> NSBox {
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        return sep
    }

    @objc private func enableToggled() {
        let on = (enableSwitch.state == .on)
        preferences.companionServerEnabled = on
        if on {
            server.start()
        } else {
            server.stop()
        }
        refreshUI()
    }

    @objc private func regeneratePIN() {
        preferences.regeneratePairingPIN()
        refreshUI()
    }

    @objc private func revokeAllClicked() {
        server.revokeAllPairedDevices()
        refreshUI()
    }

    @objc private func menuBarToggled() {
        let on = (menuBarCheck.state == .on)
        preferences.keepRunningInMenuBar = on
        onMenuBarModeChanged?(on)
    }
}
