import SwiftUI

struct PairingView: View {
    @Bindable var store: RemoteSessionStore

    @State private var manualHost: String = ""
    @State private var manualPort: String = ""
    @State private var pinInput: String = ""
    @State private var showManualSection: Bool = false
    @FocusState private var pinFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                if case .needsPIN(_, let hostName, let reason) = store.phase {
                    pinEntrySection(hostName: hostName, reason: reason)
                }

                if case .connecting(let hostName) = store.phase {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connecting to \(hostName)…")
                                    .font(.headline)
                                Text("Waiting for ChromaScan host handshake")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Cancel", role: .cancel) {
                                store.disconnect()
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    if store.browser.hosts.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Searching for Mac running ChromaScan…")
                                    .font(.subheadline.weight(.medium))
                                Text("Make sure ChromaScan is open on your Mac Studio on the same Wi-Fi/LAN.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    } else {
                        ForEach(store.browser.hosts) { host in
                            Button {
                                pinInput = ""
                                store.connect(to: host)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "macstudio")
                                        .font(.title2)
                                        .foregroundStyle(.tint)
                                        .frame(width: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(host.name)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        if let scanner = host.scannerName, !scanner.isEmpty {
                                            Text("Scanner: \(scanner)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text("ChromaScan Host · Ready to pair")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                } header: {
                    Text("Nearby Macs")
                } footer: {
                    if let err = store.browser.browseError {
                        Text("Bonjour notice: \(err)")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Discovers ChromaScan automatically via Bonjour (_chromascan._tcp).")
                    }
                }

                Section {
                    DisclosureGroup("Connect Manually (IP / Tailscale)", isExpanded: $showManualSection) {
                        TextField("Host or IP (e.g. mac-studio.local)", text: $manualHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        TextField("Port (from Mac Companion popover)", text: $manualPort)
                            .keyboardType(.numberPad)
                        let canConnectManual = !manualHost.trimmingCharacters(in: .whitespaces).isEmpty
                            && UInt16(manualPort.trimmingCharacters(in: .whitespaces)) != nil
                        Button {
                            guard let p = UInt16(manualPort.trimmingCharacters(in: .whitespaces)) else { return }
                            pinInput = ""
                            store.connectManual(host: manualHost, port: p)
                        } label: {
                            Label("Connect to Host", systemImage: "network")
                                .chromaAccentButtonForeground(isEnabled: canConnectManual)
                                .frame(maxWidth: .infinity)
                        }
                        .chromaAccentGlassButtonStyle(isEnabled: canConnectManual)
                        .disabled(!canConnectManual)
                    }
                }
            }
            .navigationTitle("ChromaScan")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.browser.start()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh Macs")
                }
            }
            .onAppear {
                if manualHost.isEmpty { manualHost = store.lastManualHost }
                if manualPort.isEmpty { manualPort = store.lastManualPort }
            }
        }
    }

    @ViewBuilder
    private func pinEntrySection(hostName: String, reason: String?) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "lock.shield")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pair with \(hostName)")
                            .font(.headline)
                        Text("Enter the 6-digit PIN from ChromaScan's Companion toolbar popover.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let reason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                }

                HStack(spacing: 10) {
                    TextField("6-digit PIN", text: $pinInput)
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($pinFocused)
                        .onChange(of: pinInput) { _, newValue in
                            let filtered = String(newValue.filter(\.isNumber).prefix(6))
                            if filtered != newValue {
                                pinInput = filtered
                            }
                            if filtered.count == 6 {
                                store.submitPIN(filtered)
                            }
                        }

                    let canSubmitPIN = pinInput.filter(\.isNumber).count == 6
                    Button {
                        store.submitPIN(pinInput)
                    } label: {
                        Text("Pair")
                            .fontWeight(.semibold)
                            .chromaAccentButtonForeground(isEnabled: canSubmitPIN)
                    }
                    .chromaAccentGlassButtonStyle(isEnabled: canSubmitPIN)
                    .disabled(!canSubmitPIN)
                }

                Button("Cancel Pairing", role: .cancel) {
                    pinInput = ""
                    store.disconnect()
                }
                .font(.caption)
            }
            .padding(.vertical, 6)
            .onAppear {
                pinFocused = true
            }
        } header: {
            Text("Pairing Required")
        }
    }
}
