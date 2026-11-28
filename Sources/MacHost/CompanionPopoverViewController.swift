import AppKit
import UniformTypeIdentifiers

/// Popover anchored to the toolbar Companion button showing server status, 6-digit Pairing PIN,
/// connected iPhones, APNs push configuration, device revocation, and optional background menu bar mode.
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
    private let pushStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let pushDeliveryLabel = NSTextField(wrappingLabelWithString: "")
    private let configureAPNsButton = NSButton(title: "Configure APNs…", target: nil, action: nil)
    private let testPushButton = NSButton(title: "Send Test Push", target: nil, action: nil)
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

        // Direct Mac -> APNs Push Notifications
        let pushHeader = NSTextField(labelWithString: "IPHONE PUSH (APNS)")
        pushHeader.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        pushHeader.textColor = .secondaryLabelColor
        stack.addArrangedSubview(pushHeader)

        pushStatusLabel.font = NSFont.systemFont(ofSize: 11.5)
        pushStatusLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(pushStatusLabel)
        pushStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true

        pushDeliveryLabel.font = NSFont.systemFont(ofSize: 11)
        pushDeliveryLabel.textColor = .secondaryLabelColor
        pushDeliveryLabel.isHidden = true
        stack.addArrangedSubview(pushDeliveryLabel)
        pushDeliveryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true

        let pushButtonsRow = NSStackView()
        pushButtonsRow.orientation = .horizontal
        pushButtonsRow.alignment = .centerY
        pushButtonsRow.spacing = 8
        configureAPNsButton.bezelStyle = .rounded
        configureAPNsButton.controlSize = .small
        configureAPNsButton.target = self
        configureAPNsButton.action = #selector(configureAPNsClicked)
        testPushButton.bezelStyle = .rounded
        testPushButton.controlSize = .small
        testPushButton.target = self
        testPushButton.action = #selector(sendTestPushClicked)
        pushButtonsRow.addArrangedSubview(configureAPNsButton)
        pushButtonsRow.addArrangedSubview(testPushButton)
        pushButtonsRow.addArrangedSubview(NSView())
        stack.addArrangedSubview(pushButtonsRow)
        pushButtonsRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true

        stack.addArrangedSubview(makeSeparator())

        menuBarCheck.controlSize = .small
        menuBarCheck.font = NSFont.systemFont(ofSize: 11.5)
        menuBarCheck.bezelColor = ChromaTheme.vermilionNS
        menuBarCheck.target = self
        menuBarCheck.action = #selector(menuBarToggled)
        stack.addArrangedSubview(menuBarCheck)

        refreshUI()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        let wasConfigured = preferences.isAPNsConfigured
        preferences.refreshLocalAPNsConfig()
        if preferences.isAPNsConfigured != wasConfigured {
            server.notifyAPNsConfigurationChanged()
        }
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

        let pushReadyDevices = preferences.pushEligibleDevices
        let pushReadyCount = pushReadyDevices.count
        let mismatchedDevices = preferences.mismatchedTeamDeviceNames
        if let kcStatus = preferences.apnsKeychainUnavailableStatus {
            pushStatusLabel.stringValue = "Keychain APNs key inaccessible (status \(kcStatus)) — re-save your .p8 key or sign ChromaScan with Apple Development."
            pushStatusLabel.textColor = .systemOrange
            configureAPNsButton.title = "Edit APNs…"
        } else if let activeConfig = preferences.apnsConfiguration {
            let readyText = pushReadyCount == 1 ? "1 push-ready iPhone" : "\(pushReadyCount) push-ready iPhones"
            let sourceDir = preferences.discoveredLocalAPNsConfig?.sourceDirectoryDisplay ?? "~/.config/chromascan/apns"
            let sourceSuffix = preferences.isUsingLocalAPNsDirectoryKey ? " (\(sourceDir))" : ""
            if pushReadyCount > 0 {
                let targetBundle = pushReadyDevices.first?.apnsBundleID ?? activeConfig.bundleID
                let envSuffix = pushReadyDevices.first?.apnsEnvironment.map { " · \($0.rawValue)" } ?? ""
                if !mismatchedDevices.isEmpty {
                    let names = mismatchedDevices.joined(separator: ", ")
                    pushStatusLabel.stringValue = "Key \(activeConfig.keyID)\(sourceSuffix) · Team ID mismatch on \(names)\nTarget: \(targetBundle)\(envSuffix)"
                    pushStatusLabel.textColor = .systemOrange
                } else {
                    pushStatusLabel.stringValue = "Key \(activeConfig.keyID)\(sourceSuffix) · \(readyText)\nTarget: \(targetBundle)\(envSuffix)"
                    pushStatusLabel.textColor = .systemGreen
                }
            } else if let regErr = preferences.latestDevicePushRegistrationError {
                pushStatusLabel.stringValue = "Key \(activeConfig.keyID)\(sourceSuffix) · \(Self.friendlyRegistrationError(regErr))"
                pushStatusLabel.textColor = .systemOrange
            } else {
                pushStatusLabel.stringValue = "Key \(activeConfig.keyID)\(sourceSuffix) · \(readyText)"
                pushStatusLabel.textColor = .secondaryLabelColor
            }
            configureAPNsButton.title = "Edit APNs…"
        } else if let localError = preferences.discoveredLocalAPNsConfig?.configurationError {
            pushStatusLabel.stringValue = localError
            pushStatusLabel.textColor = .systemOrange
            configureAPNsButton.title = "Configure APNs…"
        } else if let local = preferences.discoveredLocalAPNsConfig, let keyFile = local.keyFilename {
            let dir = local.sourceDirectoryDisplay ?? "~/.config/chromascan/apns"
            pushStatusLabel.stringValue = "Found \(dir)/\(keyFile) — add your Apple Team ID (or pair a signed iPhone) to enable push."
            pushStatusLabel.textColor = .systemOrange
            configureAPNsButton.title = "Configure APNs…"
        } else if let regErr = preferences.latestDevicePushRegistrationError {
            pushStatusLabel.stringValue = Self.friendlyRegistrationError(regErr)
            pushStatusLabel.textColor = .secondaryLabelColor
            configureAPNsButton.title = "Configure APNs…"
        } else {
            pushStatusLabel.stringValue = "Not configured — add an Apple APNs .p8 key (or place it in ~/.config/chromascan/apns/) for lock-screen scan alerts."
            pushStatusLabel.textColor = .secondaryLabelColor
            configureAPNsButton.title = "Configure APNs…"
        }
        testPushButton.isEnabled = preferences.isAPNsConfigured && pushReadyCount > 0

        if let delivery = server.lastPushStatus, !delivery.isEmpty {
            pushDeliveryLabel.stringValue = delivery
            pushDeliveryLabel.textColor = (server.lastPushSucceeded == false) ? .systemRed : .secondaryLabelColor
            pushDeliveryLabel.isHidden = false
        } else {
            pushDeliveryLabel.isHidden = true
        }
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

    @objc private func sendTestPushClicked() {
        testPushButton.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            _ = await self.server.sendTestPush()
            self.refreshUI()
        }
    }

    @objc private func configureAPNsClicked() {
        preferences.refreshLocalAPNsConfig()
        let alert = NSAlert()
        alert.messageText = "Direct APNs Push Notifications"
        alert.informativeText = "Select an Apple Push Notifications (.p8) key from Apple Developer → Certificates, Identifiers & Profiles → Keys (or install one in ~/.config/chromascan/apns/ via ./scripts/setup-apns.sh)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if preferences.apnsPrivateKeyPEM != nil || !preferences.apnsKeyID.isEmpty || !preferences.apnsTeamID.isEmpty {
            alert.addButton(withTitle: "Remove Saved Key")
        }

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8
        container.frame = NSRect(x: 0, y: 0, width: 340, height: 158)

        let keyIDField = NSTextField(string: preferences.effectiveAPNsKeyID)
        keyIDField.placeholderString = "10-character Key ID (e.g. 9A8B7C6D5E)"
        let teamIDField = NSTextField(string: preferences.effectiveAPNsTeamID)
        teamIDField.placeholderString = "10-character Apple Team ID"
        let bundleIDField = NSTextField(string: preferences.apnsBundleID)
        bundleIDField.placeholderString = "iOS Bundle ID (auto-detected when paired)"

        let initialPEM = preferences.effectiveAPNsPrivateKeyPEM
        let initialStatusText: String
        if preferences.apnsPrivateKeyPEM != nil {
            initialStatusText = "Stored in Keychain (.p8 loaded)"
        } else if let local = preferences.discoveredLocalAPNsConfig, let file = local.keyFilename {
            let dir = local.sourceDirectoryDisplay ?? "~/.config/chromascan/apns"
            initialStatusText = "Auto-loaded \(dir)/\(file)"
        } else {
            initialStatusText = "No .p8 key file selected"
        }
        let keyStatusLabel = NSTextField(labelWithString: initialStatusText)
        keyStatusLabel.font = NSFont.systemFont(ofSize: 11)
        keyStatusLabel.textColor = initialPEM != nil ? .systemGreen : .secondaryLabelColor

        let pickerHandler = APNsKeyPickerHandler(
            initialPEM: initialPEM,
            keyIDField: keyIDField,
            statusLabel: keyStatusLabel
        )
        let chooseKeyButton = NSButton(title: "Choose .p8 Key File…", target: pickerHandler, action: #selector(APNsKeyPickerHandler.chooseKeyFile))
        chooseKeyButton.bezelStyle = .rounded
        chooseKeyButton.controlSize = .small

        func labeledRow(_ title: String, field: NSTextField) -> NSStackView {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            let lbl = NSTextField(labelWithString: title)
            lbl.font = NSFont.systemFont(ofSize: 12)
            lbl.alignment = .right
            lbl.widthAnchor.constraint(equalToConstant: 82).isActive = true
            field.widthAnchor.constraint(equalToConstant: 248).isActive = true
            row.addArrangedSubview(lbl)
            row.addArrangedSubview(field)
            return row
        }

        let keyRow = NSStackView()
        keyRow.orientation = .horizontal
        keyRow.alignment = .centerY
        keyRow.spacing = 8
        keyRow.addArrangedSubview(chooseKeyButton)
        keyRow.addArrangedSubview(keyStatusLabel)

        container.addArrangedSubview(keyRow)
        container.addArrangedSubview(labeledRow("Key ID:", field: keyIDField))
        container.addArrangedSubview(labeledRow("Team ID:", field: teamIDField))
        container.addArrangedSubview(labeledRow("Bundle ID:", field: bundleIDField))

        alert.accessoryView = container

        let response = alert.runModal()
        _ = pickerHandler // retain during modal run

        switch response {
        case .alertFirstButtonReturn:
            let keyID = keyIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let teamID = teamIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let bundleID = bundleIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pem = pickerHandler.selectedPEM, !pem.isEmpty else {
                presentValidationError("Select a valid Apple APNs .p8 private key file before saving.")
                return
            }
            guard !keyID.isEmpty, !teamID.isEmpty, !bundleID.isEmpty else {
                presentValidationError("Key ID, Team ID, and iOS Bundle ID are all required.")
                return
            }
            do {
                _ = try APNsConfiguration.validatePrivateKeyPEM(pem)
            } catch {
                presentValidationError("The selected .p8 file is not a valid P-256 private key: \(error.localizedDescription)")
                return
            }
            guard preferences.saveAPNsPrivateKeyPEM(pem) else {
                presentValidationError("Could not store the APNs .p8 key in the macOS Keychain. Sign ChromaScan with an Apple Development certificate in Config/Local.xcconfig, or place the .p8 file in ~/.config/chromascan/apns/ (chmod 600).")
                return
            }
            preferences.apnsKeyID = keyID
            preferences.apnsTeamID = teamID
            preferences.apnsBundleID = bundleID
            server.notifyAPNsConfigurationChanged()
            refreshUI()

        case .alertThirdButtonReturn:
            if !preferences.clearAPNsConfiguration() {
                presentValidationError("Could not remove the saved APNs key from the macOS Keychain.")
                return
            }
            preferences.refreshLocalAPNsConfig()
            server.notifyAPNsConfigurationChanged()
            refreshUI()

        default:
            break
        }
    }

    private static func friendlyRegistrationError(_ rawError: String) -> String {
        if rawError.localizedCaseInsensitiveContains("aps-environment") {
            return "iPhone app lacks Push entitlement (enable CHROMASCAN_IOS_ENTITLEMENTS with a paid Apple Developer account)."
        }
        return "iPhone push unavailable: \(rawError)"
    }

    private func presentValidationError(_ message: String) {
        let err = NSAlert()
        err.alertStyle = .warning
        err.messageText = "Invalid APNs Configuration"
        err.informativeText = message
        err.runModal()
    }
}

@MainActor
private final class APNsKeyPickerHandler: NSObject {
    var selectedPEM: String?
    private let keyIDField: NSTextField
    private let statusLabel: NSTextField

    init(initialPEM: String?, keyIDField: NSTextField, statusLabel: NSTextField) {
        self.selectedPEM = initialPEM
        self.keyIDField = keyIDField
        self.statusLabel = statusLabel
    }

    @objc func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.title = "Select Apple APNs Auth Key (.p8)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if let p8Type = UTType(filenameExtension: "p8") {
            panel.allowedContentTypes = [p8Type, .text, .data]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let pem = try String(contentsOf: url, encoding: .utf8)
            _ = try APNsConfiguration.validatePrivateKeyPEM(pem)
            selectedPEM = pem
            statusLabel.stringValue = "Loaded \(url.lastPathComponent)"
            statusLabel.textColor = .systemGreen
            if let extracted = APNsConfiguration.extractKeyID(fromFilename: url.lastPathComponent) {
                keyIDField.stringValue = extracted
            }
        } catch {
            statusLabel.stringValue = "Invalid .p8 key file"
            statusLabel.textColor = .systemRed
        }
    }
}
