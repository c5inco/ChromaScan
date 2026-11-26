import SwiftUI

struct RemoteControlsSheet: View {
    @Bindable var store: RemoteSessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var showManualScannerAlert = false
    @State private var manualScannerHost = ""
    @State private var manualScannerPort = "8080"
    @State private var manualScannerTLS = false

    var body: some View {
        NavigationStack {
            if let snap = store.snapshot {
                Form {
                    scannerSection(snap)
                    captureSection(snap)
                    if snap.capabilities?.brightnessRange != nil || snap.capabilities?.contrastRange != nil {
                        hardwareToneSection(snap)
                    }
                    colorAndOutputSection(snap)
                    softwareToneSection(snap)
                    companionActionsSection(snap)
                }
                .navigationTitle("Scan Controls")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .sheet(isPresented: $showManualScannerAlert) {
                    manualScannerSheet
                }
            } else {
                ContentUnavailableView("Not Connected", systemImage: "wifi.slash")
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func scannerSection(_ snap: SessionSnapshot) -> some View {
        Section("Scanner") {
            if snap.scanners.isEmpty {
                Text("No scanners found on Mac")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Scanner", selection: Binding(
                    get: { snap.selectedScannerID ?? "" },
                    set: { store.selectScanner(id: $0) }
                )) {
                    ForEach(snap.scanners) { scanner in
                        Label(
                            scanner.displayTitle,
                            systemImage: scanner.transport == .usb ? "cable.connector" : (scanner.transport == .manual ? "network" : "wifi")
                        )
                        .tag(scanner.id)
                    }
                }
                .disabled(snap.isBusy)
            }

            if let status = snap.scannerStatus {
                LabeledContent("Status", value: status.state)
            }

            HStack {
                Button {
                    store.refreshScanners()
                } label: {
                    Label("Refresh Scanners", systemImage: "arrow.clockwise")
                }
                .disabled(snap.isBusy)

                Spacer()

                Button {
                    showManualScannerAlert = true
                } label: {
                    Label("Add IP…", systemImage: "plus")
                }
                .disabled(snap.isBusy)
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func captureSection(_ snap: SessionSnapshot) -> some View {
        let caps = snap.capabilities
        let inputCaps = caps?.caps(for: snap.settings.inputSource) ?? caps?.platen
        let resolutions = inputCaps?.discreteResolutions ?? [75, 100, 200, 300, 600, 1200]
        let availableSources: [ScanInputSource] = {
            var arr: [ScanInputSource] = []
            if caps == nil || caps?.platen != nil { arr.append(.platen) }
            if caps?.adf != nil { arr.append(.feeder) }
            return arr.isEmpty ? [.platen] : arr
        }()
        let availableColorModes: [ScanColorMode] = {
            let modes = inputCaps?.colorModes ?? []
            let list = ScanColorMode.allCases.filter { modes.isEmpty || modes.contains($0.rawValue) }
            return list.isEmpty ? [.rgb24] : list
        }()
        let availableTransfers: [TransferFormat] = {
            var arr: [TransferFormat] = []
            if inputCaps?.supportsRawOctetStream ?? true { arr.append(.rawOctetStream) }
            if inputCaps?.supportsJPEG ?? true { arr.append(.jpeg) }
            return arr.isEmpty ? [.rawOctetStream] : arr
        }()

        Section("Capture") {
            Picker("Source", selection: Binding(
                get: { snap.settings.inputSource },
                set: { store.updateSettings(ScanSettingsPatch(inputSource: $0)) }
            )) {
                ForEach(availableSources, id: \.self) { src in
                    Text(src.displayName).tag(src)
                }
            }
            .disabled(snap.isBusy)

            Picker("Resolution", selection: Binding(
                get: { snap.settings.resolution },
                set: { store.updateSettings(ScanSettingsPatch(resolution: $0)) }
            )) {
                ForEach(resolutions, id: \.self) { dpi in
                    Text("\(dpi) DPI").tag(dpi)
                }
            }
            .disabled(snap.isBusy)

            Picker("Color Mode", selection: Binding(
                get: { snap.settings.colorMode },
                set: { store.updateSettings(ScanSettingsPatch(colorMode: $0)) }
            )) {
                ForEach(availableColorModes, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .disabled(snap.isBusy)

            Picker("Intent", selection: Binding(
                get: { snap.settings.intent },
                set: { store.updateSettings(ScanSettingsPatch(intent: $0)) }
            )) {
                ForEach(ScanIntent.allCases, id: \.self) { intent in
                    Text(intent.displayName).tag(intent)
                }
            }
            .disabled(snap.isBusy)

            Picker("Transfer", selection: Binding(
                get: { snap.settings.transferFormat },
                set: { store.updateSettings(ScanSettingsPatch(transferFormat: $0)) }
            )) {
                ForEach(availableTransfers, id: \.self) { tf in
                    Text(tf.displayName).tag(tf)
                }
            }
            .disabled(snap.isBusy)

            VStack(alignment: .leading, spacing: 6) {
                Text("Rotation")
                    .font(.subheadline)
                Picker("Rotation", selection: Binding(
                    get: { snap.settings.rotation },
                    set: { store.updateSettings(ScanSettingsPatch(rotation: $0)) }
                )) {
                    ForEach(ScanRotation.allCases, id: \.self) { rot in
                        Text(rot.displayName).tag(rot)
                    }
                }
                .pickerStyle(.segmented)
            }

            Toggle("Auto-trim empty space", isOn: Binding(
                get: { snap.settings.autoTrimEmptySpace },
                set: { store.updateSettings(ScanSettingsPatch(autoTrimEmptySpace: $0)) }
            ))
            .tint(ChromaTheme.vermilion)
            .disabled(snap.isBusy)
        }
    }

    @ViewBuilder
    private func hardwareToneSection(_ snap: SessionSnapshot) -> some View {
        Section {
            if let br = snap.capabilities?.brightnessRange {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Brightness")
                        Spacer()
                        Text("\(snap.settings.hardwareBrightness)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(snap.settings.hardwareBrightness) },
                            set: { store.updateSettings(ScanSettingsPatch(hardwareBrightness: Int($0.rounded()))) }
                        ),
                        in: Double(br.min)...Double(br.max)
                    )
                    .tint(ChromaTheme.vermilion)
                    .disabled(snap.isBusy)
                }
            }
            if let cr = snap.capabilities?.contrastRange {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Contrast")
                        Spacer()
                        Text("\(snap.settings.hardwareContrast)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(snap.settings.hardwareContrast) },
                            set: { store.updateSettings(ScanSettingsPatch(hardwareContrast: Int($0.rounded()))) }
                        ),
                        in: Double(cr.min)...Double(cr.max)
                    )
                    .tint(ChromaTheme.vermilion)
                    .disabled(snap.isBusy)
                }
            }
            Button("Reset Hardware Tone") {
                store.updateSettings(ScanSettingsPatch(resetHardwareTone: true))
            }
            .disabled(snap.isBusy)
        } header: {
            Text("Scanner Tone (Hardware)")
        }
    }

    @ViewBuilder
    private func colorAndOutputSection(_ snap: SessionSnapshot) -> some View {
        Section("Color & Output (Mac Archive)") {
            Picker("Color Profile", selection: Binding(
                get: { snap.settings.colorProfile },
                set: { store.updateSettings(ScanSettingsPatch(colorProfile: $0)) }
            )) {
                ForEach(ColorProfileMode.allCases, id: \.self) { profile in
                    Text(profile.shortName).tag(profile)
                }
            }
            .disabled(snap.settings.colorMode == .grayscale8)

            Picker("Format", selection: Binding(
                get: { snap.settings.outputFormat },
                set: { store.updateSettings(ScanSettingsPatch(outputFormat: $0)) }
            )) {
                ForEach(OutputFormat.allCases, id: \.self) { fmt in
                    Text(fmt.displayName).tag(fmt)
                }
            }

            if snap.settings.outputFormat.supportsQuality {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Quality")
                        Spacer()
                        Text("\(Int((snap.settings.quality * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { snap.settings.quality },
                            set: { store.updateSettings(ScanSettingsPatch(quality: $0)) }
                        ),
                        in: 0.5...1.0
                    )
                    .tint(ChromaTheme.vermilion)
                }

                Toggle("Preview compression live", isOn: Binding(
                    get: { snap.settings.previewCompressionEnabled },
                    set: { store.updateSettings(ScanSettingsPatch(previewCompressionEnabled: $0)) }
                ))
                .tint(ChromaTheme.vermilion)
            }

            LabeledContent("Mac Folder", value: snap.saveFolderDisplayName)

            HStack {
                Text("Filename")
                TextField("scan-001", text: Binding(
                    get: { snap.settings.baseFilename },
                    set: { store.updateSettings(ScanSettingsPatch(baseFilename: $0)) }
                ))
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(snap.isBusy)
            }

            Toggle("Auto-increment filename", isOn: Binding(
                get: { snap.settings.autoIncrement },
                set: { store.updateSettings(ScanSettingsPatch(autoIncrement: $0)) }
            ))
            .tint(ChromaTheme.vermilion)

            if !snap.outputPreviewSummary.isEmpty {
                Text(snap.outputPreviewSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func softwareToneSection(_ snap: SessionSnapshot) -> some View {
        Section("Tone Adjustments (Software)") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Black Point")
                    Spacer()
                    Text("\(Int((snap.settings.toneAdjustments.blackPoint * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { snap.settings.toneAdjustments.blackPoint },
                        set: {
                            var t = snap.settings.toneAdjustments
                            t.blackPoint = $0
                            store.updateSettings(ScanSettingsPatch(toneAdjustments: t))
                        }
                    ),
                    in: 0.0...0.25
                )
                .tint(ChromaTheme.vermilion)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("White Point")
                    Spacer()
                    Text("\(Int((snap.settings.toneAdjustments.whitePoint * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { snap.settings.toneAdjustments.whitePoint },
                        set: {
                            var t = snap.settings.toneAdjustments
                            t.whitePoint = $0
                            store.updateSettings(ScanSettingsPatch(toneAdjustments: t))
                        }
                    ),
                    in: 0.75...1.0
                )
                .tint(ChromaTheme.vermilion)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Gamma")
                    Spacer()
                    Text(String(format: "%.2f", snap.settings.toneAdjustments.gamma))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { snap.settings.toneAdjustments.gamma },
                        set: {
                            var t = snap.settings.toneAdjustments
                            t.gamma = $0
                            store.updateSettings(ScanSettingsPatch(toneAdjustments: t))
                        }
                    ),
                    in: 0.5...2.0
                )
                .tint(ChromaTheme.vermilion)
            }

            Button("Reset Tone Adjustments") {
                store.updateSettings(ScanSettingsPatch(resetSoftwareTone: true))
            }
            .disabled(snap.settings.toneAdjustments.isIdentity)
        }
    }

    @ViewBuilder
    private func companionActionsSection(_ snap: SessionSnapshot) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { store.notifyOnScanComplete },
                set: { store.setNotifyOnScanComplete($0) }
            )) {
                Label("Notify When Scan Completes", systemImage: "bell.badge")
            }
            .tint(ChromaTheme.vermilion)

            Toggle(isOn: Binding(
                get: { store.liveActivityEnabled },
                set: { store.setLiveActivityEnabled($0) }
            )) {
                Label("Live Activity & Dynamic Island", systemImage: "platter.filled.top.iphone")
            }
            .tint(ChromaTheme.vermilion)

            if store.liveActivityEnabled && !store.areLiveActivitiesAvailable {
                Text("Live Activities are turned off in iOS Settings for ChromaScan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.notifyOnScanComplete && store.notificationAuthorizationStatus == .denied {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notifications are turned off in iOS Settings for ChromaScan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.caption.weight(.medium))
                }
            }

            Button {
                store.saveCopyToPhotos()
            } label: {
                HStack {
                    Label("Save Copy to iPhone Photos", systemImage: "photo.badge.arrow.down")
                    if store.isSavingToPhotos {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!snap.hasScanImage || store.isSavingToPhotos)

            Button("Disconnect from Mac", role: .destructive) {
                dismiss()
                store.disconnect()
            }
        } header: {
            Text("iPhone Companion")
        } footer: {
            if store.notifyOnScanComplete {
                if let regError = store.apnsRegistrationError {
                    if regError.localizedCaseInsensitiveContains("aps-environment") {
                        Text("This build was signed without Push Notifications (free Apple ID or CHROMASCAN_IOS_ENTITLEMENTS disabled). Local alerts remain active.")
                    } else {
                        Text("Remote push unavailable (\(regError)). Local alerts remain active.")
                    }
                } else if store.isDirectAPNsActive {
                    Text("Direct push via Mac is active — alerts deliver even when your iPhone is locked.")
                } else if store.hostAPNsConfigured {
                    Text("Mac APNs is configured; waiting for an iPhone push token (physical iPhone required). Local alerts remain active.")
                } else {
                    Text("Local alerts active. Configure an Apple APNs .p8 key in ChromaScan on your Mac to receive alerts while your iPhone is locked.")
                }
            }
        }
        .onAppear {
            store.refreshNotificationAuthorizationStatus()
        }
    }

    private var manualScannerSheet: some View {
        NavigationStack {
            Form {
                Section("Add eSCL Scanner on Mac") {
                    TextField("Hostname or IP (e.g. 192.168.1.50)", text: $manualScannerHost)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $manualScannerPort)
                        .keyboardType(.numberPad)
                    Toggle("Use HTTPS (port 443)", isOn: $manualScannerTLS)
                        .tint(ChromaTheme.vermilion)
                }
            }
            .navigationTitle("Manual Scanner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showManualScannerAlert = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let port = Int(manualScannerPort) ?? (manualScannerTLS ? 443 : 8080)
                        store.addManualScanner(host: manualScannerHost, port: port, useTLS: manualScannerTLS)
                        showManualScannerAlert = false
                    }
                    .disabled(manualScannerHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
