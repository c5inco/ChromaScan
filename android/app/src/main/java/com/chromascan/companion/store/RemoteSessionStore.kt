package com.chromascan.companion.store

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import com.chromascan.companion.model.CanvasViewMode
import com.chromascan.companion.model.ClientMessage
import com.chromascan.companion.model.CompanionBinaryFrame
import com.chromascan.companion.model.CompanionFrameKind
import com.chromascan.companion.model.CompanionImageKind
import com.chromascan.companion.model.CompanionImageReadyInfo
import com.chromascan.companion.model.CompanionOperation
import com.chromascan.companion.model.HostMessage
import com.chromascan.companion.model.NormalizedCropRect
import com.chromascan.companion.model.OutputFormat
import com.chromascan.companion.model.ScanColorMode
import com.chromascan.companion.model.ScanInputSource
import com.chromascan.companion.model.ScanRotation
import com.chromascan.companion.model.ScanSettingsPatch
import com.chromascan.companion.model.SessionSnapshot
import com.chromascan.companion.model.ToneAdjustments
import com.chromascan.companion.network.CompanionClient
import com.chromascan.companion.network.CompanionTarget
import com.chromascan.companion.network.ConnectionStatus
import com.chromascan.companion.network.DiscoveredHost
import com.chromascan.companion.network.HostBrowser
import com.chromascan.companion.network.TokenStore
import com.chromascan.companion.service.ScanMonitorService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

sealed class AuthPhase {
    data object Browsing : AuthPhase()
    data class Connecting(val hostName: String) : AuthPhase()
    data class NeedsPin(val hostID: String, val hostName: String, val reason: String?) : AuthPhase()
    data class Connected(val hostID: String, val hostName: String) : AuthPhase()
}

data class RemoteProgressState(
    val operation: CompanionOperation,
    val bytesReceived: Long,
    val expectedBytes: Long,
    val elapsedSeconds: Double,
    val statusText: String,
    val estimatedRemainingSeconds: Double? = null
) {
    val fraction: Double?
        get() = if (expectedBytes > 0) min(1.0, bytesReceived.toDouble() / expectedBytes.toDouble()) else null
}

data class RemoteOperationDisplayInfo(
    val title: String,
    val statusDetail: String,
    val trailingBadge: String?,
    val progressFraction: Double?,
    val metadataSummary: String
)

data class RemoteErrorAlert(
    val title: String,
    val message: String
)

data class RemoteUiState(
    val phase: AuthPhase = AuthPhase.Browsing,
    val connectionStatus: ConnectionStatus = ConnectionStatus.Disconnected,
    val snapshot: SessionSnapshot? = null,
    val progress: RemoteProgressState? = null,
    val proxyBitmap: Bitmap? = null,
    val proxyInfo: CompanionImageReadyInfo? = null,
    val proxyRotation: ScanRotation = ScanRotation.DEG_0,
    val isAwaitingRotatedProxy: Boolean = false,
    val tileBitmap: Bitmap? = null,
    val tileNormalizedRect: NormalizedCropRect? = null,
    val isLoadingTile: Boolean = false,
    val toastMessage: String? = null,
    val errorAlert: RemoteErrorAlert? = null,
    val isSavingToPhotos: Boolean = false,
    val notifyOnScanComplete: Boolean = true,
    val isTrimChipHidden: Boolean = false
) {
    val isConnected: Boolean
        get() = connectionStatus is ConnectionStatus.Connected

    val showsTrimChip: Boolean
        get() {
            val snap = snapshot ?: return false
            return !snap.isBusy &&
                snap.viewMode == CanvasViewMode.PREVIEW &&
                snap.hasPreviewImage &&
                proxyBitmap != null &&
                !isTrimChipHidden
        }

    val showsFullPageChip: Boolean
        get() {
            val snap = snapshot ?: return false
            return !snap.isBusy &&
                snap.viewMode == CanvasViewMode.PREVIEW &&
                snap.hasPreviewImage &&
                proxyBitmap != null &&
                !snap.cropRect.isFull
        }

    val effectiveOutputFilename: String
        get() {
            val snap = snapshot ?: return ""
            val stem = snap.settings.baseFilename.trim().ifEmpty { "scan" }
            return "$stem.${snap.settings.outputFormat.fileExtension}"
        }

    val topStatusPrimaryLine: String
        get() = snapshot?.let { RemoteSessionStore.computeTopStatusPrimaryLine(it) } ?: ""

    val topStatusSecondaryLine: String
        get() = snapshot?.let { RemoteSessionStore.computeTopStatusSecondaryLine(it) } ?: ""

    val isScanActive: Boolean
        get() {
            val snap = snapshot ?: return false
            if (!snap.isBusy) return false
            return (progress?.operation ?: snap.activeOperation) == CompanionOperation.SCAN
        }

    val plannedCaptureReadout: String
        get() = snapshot?.let { RemoteSessionStore.computePlannedCaptureReadout(it) } ?: ""

    val dimensionsReadout: String
        get() = snapshot?.let { RemoteSessionStore.computeDimensionsReadout(it) } ?: ""

    val activeOperationInfo: RemoteOperationDisplayInfo
        get() = RemoteSessionStore.computeActiveOperationInfo(snapshot, progress)
}

/**
 * Central application-scoped session store mirroring iOS `RemoteSessionStore`.
 */
class RemoteSessionStore private constructor(context: Context) {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    val tokenStore = TokenStore(appContext)
    val browser = HostBrowser(appContext)
    val client = CompanionClient(
        clientName = buildDeviceDisplayName(),
        tokenStore = tokenStore,
        scope = scope
    )

    private val _uiState = MutableStateFlow(
        RemoteUiState(notifyOnScanComplete = tokenStore.notifyOnScanComplete)
    )
    val uiState: StateFlow<RemoteUiState> = _uiState.asStateFlow()

    private data class FrameKey(
        val kind: CompanionFrameKind,
        val generation: Long,
        val requestID: Long
    )

    private val pendingImageInfoByKey = LinkedHashMap<FrameKey, CompanionImageReadyInfo>()
    private var latestProxyGeneration: Long = 0L
    private var nextRequestID: Long = 1L
    private var activeTileRequestID: Long = 0L
    private var activePhotosRequestID: Long = 0L

    private var cropThrottleJob: Job? = null
    private var pendingCropToSend: NormalizedCropRect? = null
    private var toastClearJob: Job? = null
    private var proxyDecodeJob: Job? = null
    private var tileDecodeJob: Job? = null
    private var tileTimeoutJob: Job? = null
    private var photosTimeoutJob: Job? = null
    private var isAppInBackground: Boolean = false
    private var lastServiceUpdateMs: Long = 0L

    init {
        ScanMonitorService.ensureChannels(appContext)
        wireClientCallbacks()
        observeBonjourForReconnect()
        browser.start()
    }

    private fun observeBonjourForReconnect() {
        scope.launch {
            browser.hosts.collect { hosts ->
                val target = client.activeTarget as? CompanionTarget.Bonjour ?: return@collect
                if (_uiState.value.connectionStatus !is ConnectionStatus.Reconnecting) return@collect
                val match = hosts.firstOrNull { h ->
                    (target.hostID != null && h.hostID == target.hostID) ||
                        h.name.equals(target.name, ignoreCase = true)
                } ?: return@collect
                client.updateBonjourEndpoint(match.hostAddress, match.port)
            }
        }
    }

    private fun wireClientCallbacks() {
        client.onStatusChanged = { status ->
            if (status is ConnectionStatus.Reconnecting) {
                clearPendingTransientRequests()
                if (client.activeTarget is CompanionTarget.Bonjour && !browser.isSearching.value) {
                    browser.start(clearExisting = false)
                }
            } else if (status is ConnectionStatus.Disconnected) {
                clearPendingTransientRequests()
            }
            _uiState.update { cur ->
                val newPhase = if (status is ConnectionStatus.Disconnected && cur.phase is AuthPhase.Connected) {
                    AuthPhase.Browsing
                } else {
                    cur.phase
                }
                cur.copy(connectionStatus = status, phase = newPhase)
            }
        }
        client.onHostMessage = { message -> handleHostMessage(message) }
        client.onBinaryFrame = { frame -> handleBinaryFrame(frame) }
        client.onInvalidTarget = { errMsg ->
            _uiState.update {
                it.copy(
                    phase = AuthPhase.Browsing,
                    errorAlert = RemoteErrorAlert("Invalid Host", errMsg)
                )
            }
        }
    }

    // MARK: - Connection & Pairing

    fun connect(host: DiscoveredHost) {
        resetSessionImages()
        clearPendingTransientRequests()
        _uiState.update { it.copy(phase = AuthPhase.Connecting(host.name)) }
        client.connect(
            CompanionTarget.Bonjour(
                name = host.name,
                hostAddress = host.hostAddress,
                port = host.port,
                hostID = host.hostID
            )
        )
    }

    fun connectManual(host: String, port: Int, pin: String? = null) {
        val clean = host.trim()
        if (clean.isEmpty() || port !in 1..65535) return
        if (CompanionTarget.buildWsUrl(clean, port) == null) {
            _uiState.update {
                it.copy(
                    errorAlert = RemoteErrorAlert(
                        title = "Invalid Host",
                        message = "Enter a valid hostname or IP address and port (1–65535)."
                    )
                )
            }
            return
        }
        tokenStore.lastManualHost = clean
        tokenStore.lastManualPort = port.toString()
        resetSessionImages()
        clearPendingTransientRequests()
        _uiState.update { it.copy(phase = AuthPhase.Connecting("$clean:$port")) }
        client.connect(CompanionTarget.Manual(clean, port), pin = pin)
    }

    fun submitPIN(pin: String) {
        val digits = pin.filter { it.isDigit() }
        if (digits.length != 6) return
        client.submitPIN(digits)
    }

    fun disconnect() {
        ScanMonitorService.stop(appContext)
        client.disconnect(clearTarget = true)
        resetSessionImages()
        clearPendingTransientRequests()
        _uiState.update {
            it.copy(
                phase = AuthPhase.Browsing,
                snapshot = null,
                progress = null,
                isTrimChipHidden = false
            )
        }
        browser.start(clearExisting = true)
    }

    fun onAppForegrounded() {
        isAppInBackground = false
        if (_uiState.value.phase is AuthPhase.Browsing) {
            browser.start(clearExisting = false)
        } else {
            client.reconnectIfNeeded()
        }
    }

    fun onAppBackgrounded() {
        isAppInBackground = true
        if (_uiState.value.phase is AuthPhase.Browsing) {
            browser.stop(clearHosts = false)
        }
        updateForegroundMonitorIfNeeded(force = true)
    }

    fun setNotifyOnScanComplete(enabled: Boolean) {
        tokenStore.notifyOnScanComplete = enabled
        _uiState.update { it.copy(notifyOnScanComplete = enabled) }
        if (!enabled) {
            ScanMonitorService.stop(appContext)
        } else {
            updateForegroundMonitorIfNeeded(force = true)
        }
    }

    fun dismissErrorAlert() {
        _uiState.update { it.copy(errorAlert = null) }
    }

    // MARK: - Remote Actions

    fun selectScanner(scannerID: String) {
        client.send(ClientMessage.SelectScanner(scannerID))
    }

    fun refreshScanners() {
        client.send(ClientMessage.RefreshScanners)
    }

    fun addManualScanner(host: String, port: Int, useTLS: Boolean) {
        val clean = host.trim()
        if (clean.isEmpty() || port !in 1..65535) return
        client.send(ClientMessage.AddManualScanner(host = clean, port = port, useTLS = useTLS))
    }

    fun updateSettings(patch: ScanSettingsPatch) {
        val rotationChanged = patch.rotation != null && patch.rotation != _uiState.value.snapshot?.settings?.rotation
        _uiState.update { cur ->
            val snap = cur.snapshot ?: return@update cur
            var s = snap.settings
            patch.inputSource?.let { s = s.copy(inputSource = it) }
            patch.resolution?.let { s = s.copy(resolution = it) }
            patch.colorMode?.let { s = s.copy(colorMode = it) }
            patch.intent?.let { s = s.copy(intent = it) }
            patch.transferFormat?.let { s = s.copy(transferFormat = it) }
            patch.rotation?.let { s = s.copy(rotation = it) }
            patch.autoTrimEmptySpace?.let { s = s.copy(autoTrimEmptySpace = it) }
            patch.hardwareBrightness?.let { s = s.copy(hardwareBrightness = it) }
            patch.hardwareContrast?.let { s = s.copy(hardwareContrast = it) }
            patch.colorProfile?.let { s = s.copy(colorProfile = it) }
            patch.outputFormat?.let { s = s.copy(outputFormat = it) }
            patch.quality?.let { s = s.copy(quality = it) }
            patch.previewCompressionEnabled?.let { s = s.copy(previewCompressionEnabled = it) }
            patch.toneAdjustments?.let { s = s.copy(toneAdjustments = it) }
            if (patch.resetSoftwareTone == true) {
                s = s.copy(toneAdjustments = ToneAdjustments())
            }
            patch.baseFilename?.let { s = s.copy(baseFilename = it) }
            patch.autoIncrement?.let { s = s.copy(autoIncrement = it) }
            cur.copy(
                snapshot = snap.copy(settings = s),
                isAwaitingRotatedProxy = if (rotationChanged && cur.proxyBitmap != null) true else cur.isAwaitingRotatedProxy
            )
        }
        client.send(ClientMessage.UpdateSettings(patch))
    }

    fun setCropRect(rect: NormalizedCropRect, immediate: Boolean = false) {
        val clamped = rect.clamped()
        _uiState.update { cur ->
            val snap = cur.snapshot ?: return@update cur
            val changed = clamped != snap.cropRect
            cur.copy(
                snapshot = snap.copy(cropRect = clamped),
                isTrimChipHidden = if (changed) false else cur.isTrimChipHidden
            )
        }

        if (immediate) {
            cropThrottleJob?.cancel()
            cropThrottleJob = null
            pendingCropToSend = null
            client.send(ClientMessage.SetCropRect(clamped))
            return
        }

        pendingCropToSend = clamped
        if (cropThrottleJob == null) {
            cropThrottleJob = scope.launch {
                delay(45)
                cropThrottleJob = null
                val pending = pendingCropToSend
                pendingCropToSend = null
                if (pending != null) {
                    client.send(ClientMessage.SetCropRect(pending))
                }
            }
        }
    }

    fun resetCrop() {
        _uiState.update { it.copy(isTrimChipHidden = false) }
        setCropRect(NormalizedCropRect.FULL, immediate = true)
    }

    fun trimEmptySpace() {
        val viewMode = _uiState.value.snapshot?.viewMode
        if (viewMode == CanvasViewMode.PREVIEW) {
            _uiState.update { it.copy(isTrimChipHidden = true) }
        } else if (viewMode == CanvasViewMode.SCAN) {
            clearHighResTile()
        }
        client.send(ClientMessage.TrimEmptySpace)
    }

    fun setViewMode(mode: CanvasViewMode) {
        clearHighResTile()
        client.send(ClientMessage.SetViewMode(mode))
    }

    fun triggerPreview() {
        _uiState.update { it.copy(isTrimChipHidden = false) }
        client.send(ClientMessage.TriggerPreview)
    }

    fun triggerScan() {
        val sent = client.send(ClientMessage.TriggerScan)
        if (sent && _uiState.value.notifyOnScanComplete && !isAppInBackground) {
            // Start foreground service immediately from the user's foreground tap so Android 12+
            // background-start restrictions never block monitoring if the user locks the phone right away.
            val dpi = _uiState.value.snapshot?.settings?.resolution ?: 1200
            ScanMonitorService.updateProgress(
                context = appContext,
                title = "Scanning · $dpi DPI",
                detail = "Starting scanner…",
                fraction = null,
                allowStartService = true
            )
        }
    }

    fun triggerExport() {
        client.send(ClientMessage.TriggerExport)
    }

    fun cancelActiveOperation() {
        client.send(ClientMessage.Cancel)
    }

    fun requestHighResTile(normalizedRect: NormalizedCropRect, maxPixelWidth: Int) {
        val state = _uiState.value
        val snap = state.snapshot ?: return
        if (!state.isConnected || snap.viewMode != CanvasViewMode.SCAN || !snap.hasScanImage) return
        val reqID = allocateRequestID()
        activeTileRequestID = reqID
        _uiState.update { it.copy(isLoadingTile = true) }
        val sent = client.send(
            ClientMessage.RequestTile(
                requestID = reqID,
                normalizedRect = normalizedRect,
                maxPixelWidth = maxPixelWidth.coerceIn(256, 3200)
            )
        )
        if (!sent) {
            activeTileRequestID = 0L
            _uiState.update { it.copy(isLoadingTile = false) }
            return
        }
        tileTimeoutJob?.cancel()
        tileTimeoutJob = scope.launch {
            delay(10_000)
            if (activeTileRequestID == reqID) {
                activeTileRequestID = 0L
                _uiState.update { it.copy(isLoadingTile = false) }
            }
        }
    }

    fun clearHighResTile() {
        activeTileRequestID = 0L
        tileTimeoutJob?.cancel()
        tileTimeoutJob = null
        tileDecodeJob?.cancel()
        tileDecodeJob = null
        _uiState.update {
            it.copy(
                tileBitmap = null,
                tileNormalizedRect = null,
                isLoadingTile = false
            )
        }
    }

    fun saveCopyToPhotos() {
        val state = _uiState.value
        val snap = state.snapshot ?: return
        if (!state.isConnected || !snap.hasScanImage || state.isSavingToPhotos) return
        val reqID = allocateRequestID()
        activePhotosRequestID = reqID
        _uiState.update { it.copy(isSavingToPhotos = true) }
        val format = if (snap.settings.outputFormat == OutputFormat.JPEG) {
            OutputFormat.JPEG
        } else {
            OutputFormat.HEIC
        }
        val sent = client.send(
            ClientMessage.RequestPhotosCopy(
                requestID = reqID,
                format = format,
                quality = snap.settings.quality
            )
        )
        if (!sent) {
            activePhotosRequestID = 0L
            _uiState.update {
                it.copy(
                    isSavingToPhotos = false,
                    errorAlert = RemoteErrorAlert("Not Connected", "Unable to request copy while disconnected from Mac.")
                )
            }
            return
        }
        photosTimeoutJob?.cancel()
        photosTimeoutJob = scope.launch {
            delay(15_000)
            if (activePhotosRequestID == reqID) {
                activePhotosRequestID = 0L
                _uiState.update {
                    it.copy(
                        isSavingToPhotos = false,
                        errorAlert = RemoteErrorAlert("Save Timed Out", "The Mac host did not return a gallery copy in time.")
                    )
                }
            }
        }
    }

    // MARK: - Incoming Messages & Binary Frames

    private fun handleHostMessage(message: HostMessage) {
        when (message) {
            is HostMessage.Welcome -> {
                client.markAuthenticated()
                client.saveAuthToken(message.authToken, message.hostID)
                browser.stop(clearHosts = false)
                // Reset per-connection image generation & transient request state so a Mac restart
                // with activeImageGeneration starting at 0 is never blocked by a stale generation counter.
                resetConnectionImageCounters()
                clearPendingTransientRequests()
                _uiState.update {
                    it.copy(
                        phase = AuthPhase.Connected(message.hostID, message.hostName),
                        proxyRotation = message.snapshot.settings.rotation,
                        isAwaitingRotatedProxy = false,
                        isTrimChipHidden = false
                    )
                }
                applyIncomingSnapshot(message.snapshot)
            }

            is HostMessage.AuthRequired -> {
                client.clearPendingPin()
                val reason = message.reason
                val isPinFailure = reason?.contains("PIN", ignoreCase = true) == true
                if (!reason.isNullOrEmpty() && !isPinFailure) {
                    client.clearSavedToken(message.hostID)
                }
                _uiState.update {
                    it.copy(phase = AuthPhase.NeedsPin(message.hostID, message.hostName, reason))
                }
            }

            is HostMessage.Snapshot -> {
                applyIncomingSnapshot(message.snapshot)
            }

            is HostMessage.Progress -> {
                val p = RemoteProgressState(
                    operation = message.operation,
                    bytesReceived = message.bytesReceived,
                    expectedBytes = message.expectedBytes,
                    elapsedSeconds = message.elapsedSeconds,
                    statusText = message.statusText,
                    estimatedRemainingSeconds = message.estimatedRemainingSeconds
                )
                _uiState.update { it.copy(progress = p) }
                updateForegroundMonitorIfNeeded(force = false)
            }

            is HostMessage.ImageReady -> {
                val info = message.toInfo()
                val key = FrameKey(info.kind.frameKind, info.generation, info.requestID)
                if (pendingImageInfoByKey.size >= 32) {
                    val oldest = pendingImageInfoByKey.keys.firstOrNull()
                    if (oldest != null) pendingImageInfoByKey.remove(oldest)
                }
                pendingImageInfoByKey[key] = info
                if (info.kind == CompanionImageKind.PREVIEW_PROXY || info.kind == CompanionImageKind.SCAN_PROXY) {
                    if (info.generation >= latestProxyGeneration) {
                        latestProxyGeneration = info.generation
                    }
                }
            }

            is HostMessage.ScanCompleted -> {
                ScanMonitorService.stop(appContext)
                _uiState.update { it.copy(progress = null) }
                val mb = message.fileSizeBytes.toDouble() / (1024.0 * 1024.0)
                showToast(
                    String.format(
                        Locale.US,
                        "Saved %s (%d×%d · %.1f MB)",
                        message.filename,
                        message.pixelWidth,
                        message.pixelHeight,
                        mb
                    )
                )
                if (_uiState.value.notifyOnScanComplete) {
                    ScanMonitorService.postScanCompleted(
                        context = appContext,
                        filename = message.filename,
                        pixelWidth = message.pixelWidth,
                        pixelHeight = message.pixelHeight,
                        fileSizeBytes = message.fileSizeBytes,
                        elapsedSeconds = message.elapsedSeconds
                    )
                }
            }

            is HostMessage.ExportCompleted -> {
                _uiState.update { it.copy(progress = null) }
                val mb = message.fileSizeBytes.toDouble() / (1024.0 * 1024.0)
                showToast(String.format(Locale.US, "Exported %s (%.1f MB)", message.filename, mb))
            }

            is HostMessage.PushStatus -> Unit

            is HostMessage.Error -> {
                photosTimeoutJob?.cancel()
                photosTimeoutJob = null
                activePhotosRequestID = 0L
                // Only stop scan monitoring if a scan is no longer active; unrelated errors
                // (e.g. Photos copy failure) must not kill an in-progress scan monitor.
                if (!_uiState.value.isScanActive) {
                    ScanMonitorService.stop(appContext)
                }
                _uiState.update {
                    it.copy(
                        isSavingToPhotos = false,
                        errorAlert = RemoteErrorAlert(message.title, message.message)
                    )
                }
            }

            is HostMessage.Pong -> Unit
        }
    }

    private fun applyIncomingSnapshot(snap: SessionSnapshot) {
        val prev = _uiState.value.snapshot
        val modeChanged = prev?.viewMode != snap.viewMode
        val genChanged = prev?.activeImageGeneration != snap.activeImageGeneration
        val rotationChanged = prev != null && prev.settings.rotation != snap.settings.rotation
        val hasActiveImage = if (snap.viewMode == CanvasViewMode.SCAN) snap.hasScanImage else snap.hasPreviewImage

        if (snap.activeImageGeneration < latestProxyGeneration) {
            latestProxyGeneration = snap.activeImageGeneration
        }

        if (modeChanged || genChanged) {
            activeTileRequestID = 0L
            tileTimeoutJob?.cancel()
            tileTimeoutJob = null
            tileDecodeJob?.cancel()
            tileDecodeJob = null
        }

        val shouldResetTrimHidden = snap.viewMode == CanvasViewMode.PREVIEW && (
            (prev != null && !prev.cropRect.isFull && snap.cropRect.isFull) ||
                (prev?.hasPreviewImage == false && snap.hasPreviewImage) ||
                (prev?.activeOperation == CompanionOperation.PREVIEW && !snap.isBusy && snap.hasPreviewImage)
            )

        _uiState.update { cur ->
            cur.copy(
                snapshot = snap,
                progress = if (!snap.isBusy) null else cur.progress,
                isTrimChipHidden = if (shouldResetTrimHidden) false else cur.isTrimChipHidden,
                proxyBitmap = if (!hasActiveImage) null else cur.proxyBitmap,
                proxyInfo = if (!hasActiveImage) null else cur.proxyInfo,
                proxyRotation = if (!hasActiveImage) snap.settings.rotation else cur.proxyRotation,
                isAwaitingRotatedProxy = when {
                    !hasActiveImage -> false
                    rotationChanged -> true
                    else -> cur.isAwaitingRotatedProxy
                },
                tileBitmap = if (modeChanged || genChanged || !hasActiveImage) null else cur.tileBitmap,
                tileNormalizedRect = if (modeChanged || genChanged || !hasActiveImage) null else cur.tileNormalizedRect,
                isLoadingTile = if (modeChanged || genChanged || !hasActiveImage) false else cur.isLoadingTile
            )
        }
        updateForegroundMonitorIfNeeded(force = true)
    }

    private fun handleBinaryFrame(frame: CompanionBinaryFrame) {
        val key = FrameKey(frame.kind, frame.generation, frame.requestID)
        val info = pendingImageInfoByKey.remove(key)

        when (frame.kind) {
            CompanionFrameKind.PREVIEW_PROXY, CompanionFrameKind.SCAN_PROXY -> {
                if (frame.generation < latestProxyGeneration) return
                latestProxyGeneration = frame.generation
                val gen = frame.generation
                val payload = frame.payload
                proxyDecodeJob?.cancel()
                proxyDecodeJob = scope.launch {
                    val bitmap = withContext(Dispatchers.Default) {
                        ImageDecoding.decodeWideGamutBitmap(payload)
                    } ?: return@launch
                    if (gen < latestProxyGeneration) return@launch
                    activeTileRequestID = 0L
                    tileTimeoutJob?.cancel()
                    tileTimeoutJob = null
                    _uiState.update { cur ->
                        cur.copy(
                            proxyBitmap = bitmap,
                            proxyInfo = info ?: cur.proxyInfo,
                            proxyRotation = cur.snapshot?.settings?.rotation ?: cur.proxyRotation,
                            isAwaitingRotatedProxy = false,
                            tileBitmap = null,
                            tileNormalizedRect = null,
                            isLoadingTile = false
                        )
                    }
                }
            }

            CompanionFrameKind.HIGH_RES_TILE -> {
                if (frame.requestID != activeTileRequestID) return
                tileTimeoutJob?.cancel()
                tileTimeoutJob = null
                val reqID = frame.requestID
                val payload = frame.payload
                tileDecodeJob?.cancel()
                tileDecodeJob = scope.launch {
                    val bitmap = withContext(Dispatchers.Default) {
                        ImageDecoding.decodeWideGamutBitmap(payload)
                    }
                    if (reqID != activeTileRequestID) return@launch
                    _uiState.update { cur ->
                        cur.copy(
                            tileBitmap = bitmap,
                            tileNormalizedRect = info?.normalizedRect,
                            isLoadingTile = false
                        )
                    }
                }
            }

            CompanionFrameKind.PHOTOS_COPY -> {
                if (frame.requestID != activePhotosRequestID) return
                photosTimeoutJob?.cancel()
                photosTimeoutJob = null
                activePhotosRequestID = 0L
                persistImageToGallery(frame.payload)
            }
        }
    }

    private fun persistImageToGallery(bytes: ByteArray) {
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                val resolver = appContext.contentResolver
                var insertedUri: Uri? = null
                runCatching {
                    val isHeic = ImageDecoding.isLikelyHeic(bytes)
                    val mime = if (isHeic) "image/heic" else "image/jpeg"
                    val ext = if (isHeic) "heic" else "jpg"
                    val base = _uiState.value.snapshot?.settings?.baseFilename?.ifBlank { "chromascan" } ?: "chromascan"
                    val displayName = "${base}_${System.currentTimeMillis()}.$ext"
                    val values = ContentValues().apply {
                        put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
                        put(MediaStore.Images.Media.MIME_TYPE, mime)
                        put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/ChromaScan")
                        put(MediaStore.Images.Media.IS_PENDING, 1)
                    }
                    val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                        ?: error("Could not create MediaStore entry")
                    insertedUri = uri
                    resolver.openOutputStream(uri)?.use { out ->
                        out.write(bytes)
                    } ?: error("Could not open MediaStore output stream")
                    values.clear()
                    values.put(MediaStore.Images.Media.IS_PENDING, 0)
                    val updated = resolver.update(uri, values, null, null)
                    if (updated <= 0) {
                        error("Failed to publish saved image in MediaStore")
                    }
                }.onFailure {
                    insertedUri?.let { uri ->
                        runCatching { resolver.delete(uri, null, null) }
                    }
                }
            }
            _uiState.update { it.copy(isSavingToPhotos = false) }
            result.onSuccess {
                showToast("Saved Display P3 copy to Gallery")
            }.onFailure { err ->
                _uiState.update {
                    it.copy(
                        errorAlert = RemoteErrorAlert(
                            title = "Save to Gallery Failed",
                            message = err.localizedMessage ?: "Unknown error"
                        )
                    )
                }
            }
        }
    }

    private fun updateForegroundMonitorIfNeeded(force: Boolean) {
        val state = _uiState.value
        if (!state.notifyOnScanComplete || !state.isScanActive) {
            ScanMonitorService.stop(appContext)
            return
        }
        val now = System.currentTimeMillis()
        if (!force && now - lastServiceUpdateMs < 900L) return
        lastServiceUpdateMs = now
        val info = state.activeOperationInfo
        ScanMonitorService.updateProgress(
            context = appContext,
            title = info.title,
            detail = info.statusDetail,
            fraction = info.progressFraction,
            allowStartService = !isAppInBackground
        )
    }

    private fun allocateRequestID(): Long {
        nextRequestID = (nextRequestID + 1L) and 0xFFFF_FFFFL
        if (nextRequestID == 0L) nextRequestID = 1L
        return nextRequestID
    }

    private fun resetConnectionImageCounters() {
        proxyDecodeJob?.cancel()
        proxyDecodeJob = null
        tileDecodeJob?.cancel()
        tileDecodeJob = null
        latestProxyGeneration = 0L
        activeTileRequestID = 0L
        pendingImageInfoByKey.clear()
    }

    private fun clearPendingTransientRequests() {
        tileTimeoutJob?.cancel()
        tileTimeoutJob = null
        photosTimeoutJob?.cancel()
        photosTimeoutJob = null
        activeTileRequestID = 0L
        activePhotosRequestID = 0L
        _uiState.update {
            it.copy(
                isLoadingTile = false,
                isSavingToPhotos = false
            )
        }
    }

    private fun resetSessionImages() {
        resetConnectionImageCounters()
        _uiState.update {
            it.copy(
                proxyBitmap = null,
                proxyInfo = null,
                isAwaitingRotatedProxy = false,
                tileBitmap = null,
                tileNormalizedRect = null,
                isLoadingTile = false
            )
        }
    }

    private fun showToast(text: String) {
        _uiState.update { it.copy(toastMessage = text) }
        toastClearJob?.cancel()
        toastClearJob = scope.launch {
            delay(3500)
            _uiState.update { cur ->
                if (cur.toastMessage == text) cur.copy(toastMessage = null) else cur
            }
        }
    }

    companion object {
        @Volatile
        private var instance: RemoteSessionStore? = null

        fun getInstance(context: Context): RemoteSessionStore =
            instance ?: synchronized(this) {
                instance ?: RemoteSessionStore(context).also { instance = it }
            }

        fun peekInstance(): RemoteSessionStore? = instance

        private fun buildDeviceDisplayName(): String {
            val model = Build.MODEL?.trim().orEmpty()
            val manufacturer = Build.MANUFACTURER?.trim().orEmpty()
            return when {
                model.isEmpty() -> "Android Companion"
                manufacturer.isNotEmpty() && !model.startsWith(manufacturer, ignoreCase = true) ->
                    "${manufacturer.replaceFirstChar { it.uppercase() }} $model"
                else -> model
            }
        }

        fun formatMegabytes(bytes: Long): String {
            val mb = max(0L, bytes).toDouble() / (1024.0 * 1024.0)
            return String.format(Locale.US, "%.1f MB", mb)
        }

        fun formatElapsedSeconds(seconds: Double): String {
            val total = max(0, seconds.roundToInt())
            return if (total >= 60) {
                "${total / 60}m ${total % 60}s"
            } else {
                "${total}s"
            }
        }

        fun formatRemainingSeconds(seconds: Double): String {
            val total = max(1, seconds.roundToInt())
            return when {
                total >= 3600 -> {
                    val hours = total / 3600
                    val mins = (total % 3600) / 60
                    if (mins > 0) "~${hours}h ${mins}m left" else "~${hours}h left"
                }
                total >= 60 -> {
                    val mins = total / 60
                    val secs = total % 60
                    if (secs > 0) "~${mins}m ${secs}s left" else "~${mins}m left"
                }
                else -> "~${total}s left"
            }
        }

        fun sanitizedBaseFilename(raw: String, format: OutputFormat): String {
            var clean = raw.trim()
            val dotExt = ".${format.fileExtension}"
            if (clean.length > dotExt.length && clean.endsWith(dotExt, ignoreCase = true)) {
                clean = clean.dropLast(dotExt.length).trim()
            }
            return clean
        }

        fun computeTopStatusPrimaryLine(snap: SessionSnapshot): String {
            if (snap.viewMode == CanvasViewMode.SCAN &&
                snap.scanPixelWidth != null &&
                snap.scanPixelHeight != null &&
                snap.scanDPI != null
            ) {
                val nf = NumberFormat.getIntegerInstance(Locale.US)
                val pw = nf.format(snap.scanPixelWidth)
                val ph = nf.format(snap.scanPixelHeight)
                val trimSuffix = if (snap.isScanTrimmed) " · Trimmed" else ""
                return "${pw}×${ph} px · ${snap.scanDPI} DPI$trimSuffix"
            }
            return computePlannedCaptureReadout(snap)
        }

        fun computeTopStatusSecondaryLine(snap: SessionSnapshot): String {
            val profile = if (snap.settings.colorMode == ScanColorMode.GRAYSCALE8) {
                "Grayscale"
            } else {
                snap.settings.colorProfile.shortName
            }
            val fmt = snap.settings.outputFormat
            val dpiPrefix = if (snap.viewMode == CanvasViewMode.SCAN && snap.scanDPI != null) {
                ""
            } else {
                "${snap.settings.resolution} DPI · "
            }
            if (fmt.supportsQuality) {
                val qPct = (snap.settings.quality * 100.0).roundToInt()
                val est = if (snap.settings.previewCompressionEnabled) {
                    extractEstimatedLossySize(snap.outputPreviewSummary)
                } else {
                    null
                }
                return if (est != null) {
                    "$dpiPrefix$profile · ${fmt.displayName} $qPct% · $est"
                } else {
                    "$dpiPrefix$profile · ${fmt.displayName} $qPct%"
                }
            }
            return "$dpiPrefix$profile · ${fmt.displayName}"
        }

        fun extractEstimatedLossySize(summary: String): String? {
            val open = summary.lastIndexOf('(')
            val close = summary.lastIndexOf(')')
            if (open < 0 || close <= open) return null
            val inside = summary.substring(open + 1, close).trim()
            return if (inside.endsWith("est.")) inside else null
        }

        fun computeDimensionsReadout(snap: SessionSnapshot): String {
            val nf = NumberFormat.getIntegerInstance(Locale.US)
            if (snap.viewMode == CanvasViewMode.SCAN &&
                snap.scanPixelWidth != null &&
                snap.scanPixelHeight != null &&
                snap.scanDPI != null
            ) {
                val pw = nf.format(snap.scanPixelWidth)
                val ph = nf.format(snap.scanPixelHeight)
                val profile = if (snap.settings.colorMode == ScanColorMode.GRAYSCALE8) {
                    "Grayscale"
                } else {
                    snap.settings.colorProfile.shortName
                }
                val trimSuffix = if (snap.isScanTrimmed) " · Trimmed" else ""
                return "${pw}×${ph} px · ${snap.scanDPI} DPI · $profile$trimSuffix"
            }
            return computePlannedCaptureReadout(snap)
        }

        fun computePlannedCaptureReadout(snap: SessionSnapshot): String {
            val source = snap.settings.inputSource
            val inputCaps = snap.capabilities?.caps(source) ?: snap.capabilities?.platen
            val maxW = inputCaps?.maxWidth ?: 2550
            val maxH = inputCaps?.maxHeight ?: 3508
            val crop = if (source == ScanInputSource.FEEDER) NormalizedCropRect.FULL else snap.cropRect
            val region = crop.toESCLRegion(maxW, maxH)
            val dpi = snap.settings.resolution
            val bpp = snap.settings.colorMode.bytesPerPixel

            var wIn = region.width.toDouble() / 300.0
            var hIn = region.height.toDouble() / 300.0
            var pxW = (wIn * dpi.toDouble()).roundToInt()
            var pxH = (hIn * dpi.toDouble()).roundToInt()
            if (snap.settings.rotation == ScanRotation.DEG_90 || snap.settings.rotation == ScanRotation.DEG_270) {
                val tmpIn = wIn; wIn = hIn; hIn = tmpIn
                val tmpPx = pxW; pxW = pxH; pxH = tmpPx
            }
            val rawMB = (pxW.toLong() * pxH.toLong() * bpp.toLong()).toDouble() / (1024.0 * 1024.0)
            val sizeStr = if (rawMB >= 10.0) {
                String.format(Locale.US, "%.0f MB", rawMB)
            } else {
                String.format(Locale.US, "%.1f MB", rawMB)
            }
            val nf = NumberFormat.getIntegerInstance(Locale.US)
            return String.format(
                Locale.US,
                "%.2f\"×%.2f\" · %s×%s (%s)",
                wIn,
                hIn,
                nf.format(pxW),
                nf.format(pxH),
                sizeStr
            )
        }

        fun computeActiveOperationInfo(
            snap: SessionSnapshot?,
            progress: RemoteProgressState?
        ): RemoteOperationDisplayInfo {
            if (snap == null) {
                return RemoteOperationDisplayInfo(
                    title = "Working…",
                    statusDetail = "",
                    trailingBadge = null,
                    progressFraction = null,
                    metadataSummary = ""
                )
            }

            val op = progress?.operation ?: snap.activeOperation
            val rawStatus = (progress?.statusText ?: snap.statusText).trim()
            val isProcessingPhase = rawStatus.startsWith("Processing") || rawStatus.startsWith("Rendering")

            val title = when (op) {
                CompanionOperation.PREVIEW ->
                    if (rawStatus.startsWith("Rendering")) "Rendering Preview" else "Previewing Flatbed"
                CompanionOperation.SCAN ->
                    if (rawStatus.startsWith("Processing")) "Processing & Saving" else "Scanning · ${snap.settings.resolution} DPI"
                CompanionOperation.EXPORT -> "Exporting Scan"
                null -> "Working…"
            }

            val fraction = if (progress != null &&
                op != CompanionOperation.EXPORT &&
                !isProcessingPhase &&
                progress.expectedBytes > 0 &&
                progress.bytesReceived > 0
            ) {
                progress.fraction
            } else {
                null
            }

            val statusDetail: String
            val trailingBadge: String?
            if (progress != null) {
                when {
                    isProcessingPhase || op == CompanionOperation.EXPORT -> {
                        statusDetail = rawStatus.ifEmpty { title }
                        trailingBadge = if (progress.elapsedSeconds >= 1.0) {
                            formatElapsedSeconds(progress.elapsedSeconds)
                        } else {
                            null
                        }
                    }

                    progress.bytesReceived > 0 && progress.expectedBytes > 0 -> {
                        val remaining = progress.estimatedRemainingSeconds
                        val timeSuffix = if (remaining != null && remaining.isFinite() && remaining > 0.0) {
                            formatRemainingSeconds(remaining)
                        } else {
                            formatElapsedSeconds(progress.elapsedSeconds)
                        }
                        statusDetail = "${formatMegabytes(progress.bytesReceived)} / ${formatMegabytes(progress.expectedBytes)} · $timeSuffix"
                        val pct = ((fraction ?: 0.0) * 100.0).roundToInt()
                        trailingBadge = "$pct%"
                    }

                    progress.bytesReceived > 0 -> {
                        statusDetail = "${formatMegabytes(progress.bytesReceived)} received · ${formatElapsedSeconds(progress.elapsedSeconds)}"
                        trailingBadge = null
                    }

                    progress.expectedBytes > 0 -> {
                        statusDetail = "Starting scanner… · ${formatMegabytes(progress.expectedBytes)} expected"
                        trailingBadge = null
                    }

                    else -> {
                        statusDetail = rawStatus.ifEmpty { "Starting…" }
                        trailingBadge = null
                    }
                }
            } else {
                statusDetail = rawStatus.ifEmpty { "Starting…" }
                trailingBadge = null
            }

            val metadataSummary = when (op) {
                CompanionOperation.SCAN -> {
                    val profile = if (snap.settings.colorMode == ScanColorMode.GRAYSCALE8) {
                        "Grayscale"
                    } else {
                        snap.settings.colorProfile.shortName
                    }
                    listOf(computePlannedCaptureReadout(snap), profile, snap.settings.outputFormat.displayName)
                        .filter { it.isNotEmpty() }
                        .joinToString(" · ")
                }

                CompanionOperation.PREVIEW -> {
                    val scanner = snap.selectedScanner?.displayTitle ?: "Flatbed"
                    "$scanner · Full Page · ${snap.settings.colorMode.displayName}"
                }

                CompanionOperation.EXPORT -> {
                    val base = computeDimensionsReadout(snap)
                    val fmt = snap.settings.outputFormat.displayName
                    if (base.isEmpty()) fmt else "$base · $fmt"
                }

                null -> computeDimensionsReadout(snap)
            }

            return RemoteOperationDisplayInfo(
                title = title,
                statusDetail = statusDetail,
                trailingBadge = trailingBadge,
                progressFraction = fraction,
                metadataSummary = metadataSummary
            )
        }
    }
}
