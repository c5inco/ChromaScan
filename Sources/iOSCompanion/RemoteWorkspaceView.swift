import SwiftUI

struct RemoteWorkspaceView: View {
    @Bindable var store: RemoteSessionStore
    let hostName: String

    @State private var showControlsSheet = false
    @State private var showDisconnectConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            canvasStage
            bottomDock
        }
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $showControlsSheet) {
            RemoteControlsSheet(store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Mac Host: \(hostName)", isPresented: $showDisconnectConfirm, titleVisibility: .visible) {
            Button("Refresh Scanners") { store.refreshScanners() }
            Button("Disconnect", role: .destructive) { store.disconnect() }
            Button("Cancel", role: .cancel) {}
        }
        .alert(item: $store.errorAlert) { err in
            Alert(
                title: Text(err.title),
                message: Text(err.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    showDisconnectConfirm = true
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(connectionDotColor)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hostName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(scannerSubtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                if let snap = store.snapshot {
                    Picker("Mode", selection: Binding(
                        get: { snap.viewMode },
                        set: { store.setViewMode($0) }
                    )) {
                        Text("Preview").tag(CanvasViewMode.preview)
                        Text("Last Scan").tag(CanvasViewMode.scan)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)
                    .disabled(!snap.hasScanImage && snap.viewMode == .preview)
                }

                Button {
                    showControlsSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.body.weight(.medium))
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Scan Controls")
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    // MARK: - Center Canvas

    private var canvasStage: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
                .ignoresSafeArea(edges: [])

            if let snap = store.snapshot {
                let showingScan = (snap.viewMode == .scan && snap.hasScanImage)
                let trueSize: CGSize = {
                    if let info = store.proxyInfo {
                        return CGSize(width: info.trueWidth, height: info.trueHeight)
                    }
                    if let img = store.proxyImage {
                        return img.size
                    }
                    return .zero
                }()

                if let img = store.proxyImage {
                    RemoteCanvasView(
                        image: img,
                        truePixelSize: trueSize,
                        tileImage: store.tileImage,
                        tileNormalizedRect: store.tileNormalizedRect,
                        isLoadingTile: store.isLoadingTile,
                        showCropOverlay: !showingScan,
                        cropRect: snap.cropRect,
                        rotation: snap.settings.rotation,
                        onCropChanged: { rect, isFinal in
                            store.setCropRect(rect, immediate: isFinal)
                        },
                        onRequestTile: { normRect, maxPxW in
                            store.requestHighResTile(normalizedRect: normRect, maxPixelWidth: maxPxW)
                        },
                        onClearTile: {
                            store.clearHighResTile()
                        }
                    )
                } else {
                    emptyCanvasView(showingScan: showingScan, snap: snap)
                }

                // Floating centered top summary pill, Trim / Full Page actions & bottom toast
                VStack(spacing: 6) {
                    if !snap.outputPreviewSummary.isEmpty, store.proxyImage != nil {
                        Text(snap.outputPreviewSummary)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.62), in: Capsule())
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .allowsHitTesting(false)
                    }

                    if store.proxyImage != nil {
                        HStack(spacing: 8) {
                            Button {
                                store.trimEmptySpace()
                            } label: {
                                Label("Trim", systemImage: "crop")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .background(.ultraThinMaterial, in: Capsule())
                            .disabled(snap.isBusy || (showingScan && snap.isScanTrimmed))

                            if !showingScan && !snap.cropRect.isFull {
                                Button {
                                    store.resetCrop()
                                } label: {
                                    Label("Full Page", systemImage: "arrow.uturn.backward")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .background(.ultraThinMaterial, in: Capsule())
                                .disabled(snap.isBusy)
                                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                            }
                        }
                    }

                    Spacer()

                    if let toast = store.toastMessage {
                        Label(toast, systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.green.opacity(0.88), in: Capsule())
                            .padding(.bottom, 12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .animation(.easeInOut(duration: 0.2), value: store.toastMessage)
                .animation(.easeInOut(duration: 0.2), value: snap.cropRect.isFull)
            } else {
                ProgressView("Syncing session…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyCanvasView(showingScan: Bool, snap: SessionSnapshot) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "scanner")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tertiary)
            Text(showingScan ? "No Scan Yet" : "No Preview Loaded")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(showingScan
                 ? "Tap Scan to capture a full-resolution Display P3 image on your Mac Studio."
                 : "Tap Preview to frame artwork on the flatbed, or Scan directly for a full page.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: - Bottom Action Dock

    private var bottomDock: some View {
        VStack(spacing: 0) {
            if let snap = store.snapshot {
                if snap.isBusy {
                    activeOperationDock(snap: snap)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity
                        ))
                } else {
                    idleActionDock(snap: snap)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .clipped()
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.88), value: store.snapshot?.isBusy ?? false)
    }

    private func idleActionDock(snap: SessionSnapshot) -> some View {
        let ready = snap.selectedScannerID != nil && snap.capabilities != nil

        return VStack(spacing: 10) {
            // Status & dimensions strip
            HStack(spacing: 8) {
                Text(store.dimensionsReadout)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(snap.statusText)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(snap.isErrorStatus ? .red : .secondary)
                    .lineLimit(1)
            }

            // Main action row
            HStack(spacing: 8) {
                Button {
                    store.triggerPreview()
                } label: {
                    Label("Preview", systemImage: "eye")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(!ready || snap.capabilities?.platen == nil)

                Button {
                    store.triggerScan()
                } label: {
                    Label("Scan", systemImage: "scanner")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!ready)

                Button {
                    store.triggerExport()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(!snap.hasScanImage)
            }
        }
    }

    private func activeOperationDock(snap: SessionSnapshot) -> some View {
        let info = store.activeOperationInfo

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.accentColor)

                Text(info.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button("Cancel", role: .destructive) {
                    store.cancelActiveOperation()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }

            ScanningProgressBar(fraction: info.progressFraction)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(info.statusDetail)
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Spacer(minLength: 8)

                    if let badge = info.trailingBadge {
                        Text(badge)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(info.progressFraction != nil ? Color.accentColor : .secondary)
                            .lineLimit(1)
                    }
                }

                if !info.metadataSummary.isEmpty {
                    Text(info.metadataSummary)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
    }

    private var connectionDotColor: Color {
        switch store.connectionStatus {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected: return .red
        }
    }

    private var scannerSubtitle: String {
        switch store.connectionStatus {
        case .reconnecting(let attempt):
            return "Reconnecting (\(attempt))…"
        case .connecting:
            return "Connecting…"
        case .disconnected:
            return "Disconnected"
        case .connected:
            if let scanner = store.snapshot?.selectedScanner {
                return "\(scanner.displayTitle) · \(store.snapshot?.settings.resolution ?? 1200) DPI"
            }
            return "No Scanner Selected"
        }
    }
}

private struct ScanningProgressBar: View {
    let fraction: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSweeping = false

    var body: some View {
        GeometryReader { geo in
            let width = max(0, geo.size.width)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))

                if let fraction {
                    let clamped = max(0, min(1, fraction))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: clamped > 0 ? max(6, width * clamped) : 0)
                        .animation(.easeOut(duration: 0.2), value: clamped)
                } else if reduceMotion {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.65))
                        .frame(width: width)
                } else {
                    let segmentWidth = max(48, width * 0.32)
                    let travel = max(0, width - segmentWidth)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: segmentWidth)
                        .offset(x: isSweeping ? travel : 0)
                        .task {
                            isSweeping = false
                            await Task.yield()
                            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                                isSweeping = true
                            }
                        }
                        .onDisappear {
                            isSweeping = false
                        }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Operation progress")
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
    }
}
