package com.chromascan.companion.store

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
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
    val statusText: String
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
    val tileBitmap: Bitmap? = null,
    val tileNormalizedRect: NormalizedCropRect? = null,
    val isLoadingTile: Boolean = false,
    val toastMessage: String? = null,
    val errorAlert: RemoteErrorAlert? = null,
    val isSavingToPhotos: Boolean = false,
    val notifyOnScanComplete: Boolean = true
) {
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

    private val pendingImageInfoByKey = HashMap<FrameKey, CompanionImageReadyInfo>()
    private var latestProxyGeneration: Long = 0L
    private var nextRequestID: Long = 1L
    private var activeTileRequestID: Long = 0L
    private var activePhotosRequestID: Long = 0L

    private var cropThrottleJob: Job? = null
    private var pendingCropToSend: NormalizedCropRect? = null
    private var toastClearJob: Job? = null
    private var proxyDecodeJob: Job? = null
    private var tileDecodeJob: Job? = null
    private var isAppInBackground: Boolean = false
    private var lastServiceUpdateMs: Long = 0L

    init {
        ScanMonitorService.ensureChannels(appContext)
        wireClientCallbacks()
        browser.start()
    }

    private fun wireClientCallbacks() {
        client.onStatusChanged = { status ->
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
    }

    // MARK: - Connection & Pairing

    fun connect(host: DiscoveredHost) {
        resetSessionImages()
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
        tokenStore.lastManualHost = clean
        tokenStore.lastManualPort = port.toString()
        resetSessionImages()
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
        _uiState.update {
            it.copy(
                phase = AuthPhase.Browsing,
                snapshot = null,
                progress = null
            )
        }
        browser.start()
    }

    fun onAppForegrounded() {
        isAppInBackground = false
        if (_uiState.value.phase is AuthPhase.Browsing) {
            browser.start()
        } else {
            client.reconnectIfNeeded()
        }
    }

    fun onAppBackgrounded() {
        isAppInBackground = true
        if (_uiState.value.phase is AuthPhase.Browsing) {
            browser.stop()
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
        if (clean.isEmpty()) return
        client.send(ClientMessage.AddManualScanner(host = clean, port = port, useTLS = useTLS))
    }

    fun updateSettings(patch: ScanSettingsPatch) {
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
            cur.copy(snapshot = snap.copy(settings = s))
        }
        client.send(ClientMessage.UpdateSettings(patch))
    }

    fun setCropRect(rect: NormalizedCropRect, immediate: Boolean = false) {
        val clamped = rect.clamped()
        _uiState.update { cur ->
            val snap = cur.snapshot ?: return@update cur
            cur.copy(snapshot = snap.copy(cropRect = clamped))
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
        setCropRect(NormalizedCropRect.FULL, immediate = true)
    }

    fun trimEmptySpace() {
        if (_uiState.value.snapshot?.viewMode == CanvasViewMode.SCAN) {
            clearHighResTile()
        }
        client.send(ClientMessage.TrimEmptySpace)
    }

    fun setViewMode(mode: CanvasViewMode) {
        clearHighResTile()
        client.send(ClientMessage.SetViewMode(mode))
    }

    fun triggerPreview() {
        client.send(ClientMessage.TriggerPreview)
    }

    fun triggerScan() {
        client.send(ClientMessage.TriggerScan)
    }

    fun triggerExport() {
        client.send(ClientMessage.TriggerExport)
    }

    fun cancelActiveOperation() {
        client.send(ClientMessage.Cancel)
    }

    fun requestHighResTile(normalizedRect: NormalizedCropRect, maxPixelWidth: Int) {
        val snap = _uiState.value.snapshot ?: return
        if (snap.viewMode != CanvasViewMode.SCAN || !snap.hasScanImage) return
        val reqID = allocateRequestID()
        activeTileRequestID = reqID
        _uiState.update { it.copy(isLoadingTile = true) }
        client.send(
            ClientMessage.RequestTile(
                requestID = reqID,
                normalizedRect = normalizedRect,
                maxPixelWidth = maxPixelWidth.coerceIn(256, 3200)
            )
        )
    }

    fun clearHighResTile() {
        activeTileRequestID = 0L
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
        if (!snap.hasScanImage || state.isSavingToPhotos) return
        val reqID = allocateRequestID()
        activePhotosRequestID = reqID
        _uiState.update { it.copy(isSavingToPhotos = true) }
        val format = if (snap.settings.outputFormat == OutputFormat.JPEG) {
            OutputFormat.JPEG
        } else {
            OutputFormat.HEIC
        }
        client.send(
            ClientMessage.RequestPhotosCopy(
                requestID = reqID,
                format = format,
                quality = snap.settings.quality
            )
        )
    }

    // MARK: - Incoming Messages & Binary Frames

    private fun handleHostMessage(message: HostMessage) {
        when (message) {
            is HostMessage.Welcome -> {
                client.saveAuthToken(message.authToken, message.hostID)
                browser.stop()
                _uiState.update {
                    it.copy(phase = AuthPhase.Connected(message.hostID, message.hostName))
                }
                applyIncomingSnapshot(message.snapshot)
            }

            is HostMessage.AuthRequired -> {
                if (!message.reason.isNullOrEmpty()) {
                    client.clearSavedToken(message.hostID)
                }
                _uiState.update {
                    it.copy(phase = AuthPhase.NeedsPin(message.hostID, message.hostName, message.reason))
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
                    statusText = message.statusText
                )
                _uiState.update { it.copy(progress = p) }
                updateForegroundMonitorIfNeeded(force = false)
            }

            is HostMessage.ImageReady -> {
                val info = message.toInfo()
                val key = FrameKey(info.kind.frameKind, info.generation, info.requestID)
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
                ScanMonitorService.stop(appContext)
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
        val hasActiveImage = if (snap.viewMode == CanvasViewMode.SCAN) snap.hasScanImage else snap.hasPreviewImage

        if (modeChanged || genChanged) {
            activeTileRequestID = 0L
            tileDecodeJob?.cancel()
            tileDecodeJob = null
        }

        _uiState.update { cur ->
            cur.copy(
                snapshot = snap,
                progress = if (!snap.isBusy) null else cur.progress,
                proxyBitmap = if (!hasActiveImage) null else cur.proxyBitmap,
                proxyInfo = if (!hasActiveImage) null else cur.proxyInfo,
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
                    _uiState.update { cur ->
                        cur.copy(
                            proxyBitmap = bitmap,
                            proxyInfo = info ?: cur.proxyInfo,
                            tileBitmap = null,
                            tileNormalizedRect = null,
                            isLoadingTile = false
                        )
                    }
                }
            }

            CompanionFrameKind.HIGH_RES_TILE -> {
                if (frame.requestID != activeTileRequestID) return
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
                persistImageToGallery(frame.payload)
            }
        }
    }

    private fun persistImageToGallery(bytes: ByteArray) {
        scope.launch {
            val result = withContext(Dispatchers.IO) {
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
                    val resolver = appContext.contentResolver
                    val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                        ?: error("Could not create MediaStore entry")
                    resolver.openOutputStream(uri)?.use { out ->
                        out.write(bytes)
                    } ?: error("Could not open MediaStore output stream")
                    values.clear()
                    values.put(MediaStore.Images.Media.IS_PENDING, 0)
                    resolver.update(uri, values, null, null)
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
            fraction = info.progressFraction
        )
    }

    private fun allocateRequestID(): Long {
        nextRequestID = (nextRequestID + 1L) and 0xFFFF_FFFFL
        if (nextRequestID == 0L) nextRequestID = 1L
        return nextRequestID
    }

    private fun resetSessionImages() {
        proxyDecodeJob?.cancel()
        tileDecodeJob?.cancel()
        latestProxyGeneration = 0L
        activeTileRequestID = 0L
        pendingImageInfoByKey.clear()
        _uiState.update {
            it.copy(
                proxyBitmap = null,
                proxyInfo = null,
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
                "%.2f\"×%.2f\" · %s×%s (%s raw)",
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
                        statusDetail = "${formatMegabytes(progress.bytesReceived)} / ${formatMegabytes(progress.expectedBytes)} · ${formatElapsedSeconds(progress.elapsedSeconds)}"
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
