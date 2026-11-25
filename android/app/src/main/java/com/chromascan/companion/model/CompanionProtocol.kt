package com.chromascan.companion.model

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

object CompanionConstants {
    const val BONJOUR_SERVICE_TYPE = "_chromascan._tcp."
    const val PROTOCOL_VERSION = 1
    const val MAXIMUM_MESSAGE_SIZE = 16 * 1024 * 1024
    const val BINARY_HEADER_LENGTH = 9 // 1B frameKind + 4B generation + 4B requestID
}

@OptIn(ExperimentalSerializationApi::class)
val CompanionJson: Json = Json {
    classDiscriminator = "type"
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = true
}

// MARK: - Shared Companion Enums & Snapshot

@Serializable
enum class CompanionOperation {
    @SerialName("preview")
    PREVIEW,

    @SerialName("scan")
    SCAN,

    @SerialName("export")
    EXPORT
}

@Serializable
enum class CompanionImageKind {
    @SerialName("previewProxy")
    PREVIEW_PROXY,

    @SerialName("scanProxy")
    SCAN_PROXY,

    @SerialName("highResTile")
    HIGH_RES_TILE,

    @SerialName("photosCopy")
    PHOTOS_COPY;

    val frameKind: CompanionFrameKind
        get() = when (this) {
            PREVIEW_PROXY -> CompanionFrameKind.PREVIEW_PROXY
            SCAN_PROXY -> CompanionFrameKind.SCAN_PROXY
            HIGH_RES_TILE -> CompanionFrameKind.HIGH_RES_TILE
            PHOTOS_COPY -> CompanionFrameKind.PHOTOS_COPY
        }
}

enum class CompanionFrameKind(val rawValue: Byte) {
    PREVIEW_PROXY(1),
    SCAN_PROXY(2),
    HIGH_RES_TILE(3),
    PHOTOS_COPY(4);

    val imageKind: CompanionImageKind
        get() = when (this) {
            PREVIEW_PROXY -> CompanionImageKind.PREVIEW_PROXY
            SCAN_PROXY -> CompanionImageKind.SCAN_PROXY
            HIGH_RES_TILE -> CompanionImageKind.HIGH_RES_TILE
            PHOTOS_COPY -> CompanionImageKind.PHOTOS_COPY
        }

    companion object {
        fun fromRaw(raw: Byte): CompanionFrameKind? = entries.firstOrNull { it.rawValue == raw }
    }
}

@Serializable
data class SessionSnapshot(
    val scanners: List<DiscoveredScanner> = emptyList(),
    val selectedScannerID: String? = null,
    val capabilities: ScannerCapabilities? = null,
    val scannerStatus: ScannerStatus? = null,
    val settings: ScanSessionSettings = ScanSessionSettings(),
    val cropRect: NormalizedCropRect = NormalizedCropRect.FULL,
    val viewMode: CanvasViewMode = CanvasViewMode.PREVIEW,
    val isBusy: Boolean = false,
    val activeOperation: CompanionOperation? = null,
    val statusText: String = "",
    val isErrorStatus: Boolean = false,
    val hasPreviewImage: Boolean = false,
    val hasScanImage: Boolean = false,
    val platenAspectRatio: Double = 8.5 / 11.0,
    val lastSavedFilename: String? = null,
    val saveFolderDisplayName: String = "",
    val outputPreviewSummary: String = "",
    val activeImageGeneration: Long = 0L,
    val scanPixelWidth: Int? = null,
    val scanPixelHeight: Int? = null,
    val scanDPI: Int? = null,
    val isScanTrimmed: Boolean = false
) {
    val selectedScanner: DiscoveredScanner?
        get() = selectedScannerID?.let { id -> scanners.firstOrNull { it.id == id } }
}

@Serializable
data class CompanionImageReadyInfo(
    val kind: CompanionImageKind,
    val generation: Long,
    val requestID: Long,
    val width: Int,
    val height: Int,
    val trueWidth: Int,
    val trueHeight: Int,
    val dpi: Int,
    val normalizedRect: NormalizedCropRect? = null,
    val summaryText: String = ""
)

// MARK: - Client -> Host Messages

@Serializable
sealed class ClientMessage {
    @Serializable
    @SerialName("hello")
    data class Hello(
        val protocolVersion: Int = CompanionConstants.PROTOCOL_VERSION,
        val clientName: String,
        val pin: String? = null,
        val authToken: String? = null
    ) : ClientMessage()

    @Serializable
    @SerialName("selectScanner")
    data class SelectScanner(val scannerID: String) : ClientMessage()

    @Serializable
    @SerialName("refreshScanners")
    data object RefreshScanners : ClientMessage()

    @Serializable
    @SerialName("addManualScanner")
    data class AddManualScanner(
        val host: String,
        val port: Int,
        val useTLS: Boolean
    ) : ClientMessage()

    @Serializable
    @SerialName("updateSettings")
    data class UpdateSettings(val patch: ScanSettingsPatch) : ClientMessage()

    @Serializable
    @SerialName("setCropRect")
    data class SetCropRect(val cropRect: NormalizedCropRect) : ClientMessage()

    @Serializable
    @SerialName("trimEmptySpace")
    data object TrimEmptySpace : ClientMessage()

    @Serializable
    @SerialName("setViewMode")
    data class SetViewMode(val mode: CanvasViewMode) : ClientMessage()

    @Serializable
    @SerialName("triggerPreview")
    data object TriggerPreview : ClientMessage()

    @Serializable
    @SerialName("triggerScan")
    data object TriggerScan : ClientMessage()

    @Serializable
    @SerialName("triggerExport")
    data object TriggerExport : ClientMessage()

    @Serializable
    @SerialName("cancel")
    data object Cancel : ClientMessage()

    @Serializable
    @SerialName("requestTile")
    data class RequestTile(
        val requestID: Long,
        val normalizedRect: NormalizedCropRect,
        val maxPixelWidth: Int
    ) : ClientMessage()

    @Serializable
    @SerialName("requestPhotosCopy")
    data class RequestPhotosCopy(
        val requestID: Long,
        val format: OutputFormat,
        val quality: Double
    ) : ClientMessage()

    @Serializable
    @SerialName("ping")
    data object Ping : ClientMessage()
}

// MARK: - Host -> Client Messages

@Serializable
sealed class HostMessage {
    @Serializable
    @SerialName("welcome")
    data class Welcome(
        val protocolVersion: Int,
        val hostID: String,
        val hostName: String,
        val authToken: String,
        val snapshot: SessionSnapshot
    ) : HostMessage()

    @Serializable
    @SerialName("authRequired")
    data class AuthRequired(
        val hostID: String,
        val hostName: String,
        val reason: String? = null
    ) : HostMessage()

    @Serializable
    @SerialName("snapshot")
    data class Snapshot(val snapshot: SessionSnapshot) : HostMessage()

    @Serializable
    @SerialName("progress")
    data class Progress(
        val operation: CompanionOperation,
        val bytesReceived: Long,
        val expectedBytes: Long,
        val elapsedSeconds: Double,
        val statusText: String
    ) : HostMessage()

    @Serializable
    @SerialName("imageReady")
    data class ImageReady(
        val kind: CompanionImageKind,
        val generation: Long,
        val requestID: Long,
        val width: Int,
        val height: Int,
        val trueWidth: Int,
        val trueHeight: Int,
        val dpi: Int,
        val normalizedRect: NormalizedCropRect? = null,
        val summaryText: String = ""
    ) : HostMessage() {
        fun toInfo(): CompanionImageReadyInfo = CompanionImageReadyInfo(
            kind = kind,
            generation = generation,
            requestID = requestID,
            width = width,
            height = height,
            trueWidth = trueWidth,
            trueHeight = trueHeight,
            dpi = dpi,
            normalizedRect = normalizedRect,
            summaryText = summaryText
        )
    }

    @Serializable
    @SerialName("scanCompleted")
    data class ScanCompleted(
        val filename: String,
        val pixelWidth: Int,
        val pixelHeight: Int,
        val fileSizeBytes: Long,
        val elapsedSeconds: Double
    ) : HostMessage()

    @Serializable
    @SerialName("exportCompleted")
    data class ExportCompleted(
        val filename: String,
        val fileSizeBytes: Long,
        val elapsedSeconds: Double
    ) : HostMessage()

    @Serializable
    @SerialName("pushStatus")
    data class PushStatus(val apnsConfigured: Boolean = false) : HostMessage()

    @Serializable
    @SerialName("error")
    data class Error(val title: String, val message: String) : HostMessage()

    @Serializable
    @SerialName("pong")
    data object Pong : HostMessage()
}

// MARK: - Binary Image Frame Pack / Unpack

sealed class CompanionBinaryFrameException(message: String) : Exception(message) {
    class TruncatedHeader(length: Int) : CompanionBinaryFrameException(
        "Binary frame too short ($length bytes; need at least ${CompanionConstants.BINARY_HEADER_LENGTH})."
    )

    class UnknownFrameKind(raw: Int) : CompanionBinaryFrameException(
        "Unknown companion binary frame kind: $raw."
    )

    class EmptyPayload : CompanionBinaryFrameException(
        "Binary frame contained no image payload."
    )
}

data class CompanionBinaryFrame(
    val kind: CompanionFrameKind,
    val generation: Long,
    val requestID: Long,
    val payload: ByteArray
) {
    fun pack(): ByteArray {
        require(generation in 0L..0xFFFF_FFFFL) { "generation out of UInt32 range: $generation" }
        require(requestID in 0L..0xFFFF_FFFFL) { "requestID out of UInt32 range: $requestID" }
        val out = ByteArray(CompanionConstants.BINARY_HEADER_LENGTH + payload.size)
        out[0] = kind.rawValue
        writeUInt32BigEndian(out, 1, generation)
        writeUInt32BigEndian(out, 5, requestID)
        payload.copyInto(out, CompanionConstants.BINARY_HEADER_LENGTH)
        return out
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is CompanionBinaryFrame) return false
        return kind == other.kind &&
            generation == other.generation &&
            requestID == other.requestID &&
            payload.contentEquals(other.payload)
    }

    override fun hashCode(): Int {
        var result = kind.hashCode()
        result = 31 * result + generation.hashCode()
        result = 31 * result + requestID.hashCode()
        result = 31 * result + payload.contentHashCode()
        return result
    }

    companion object {
        fun unpack(data: ByteArray): CompanionBinaryFrame {
            if (data.size < CompanionConstants.BINARY_HEADER_LENGTH) {
                throw CompanionBinaryFrameException.TruncatedHeader(data.size)
            }
            val kindByte = data[0]
            val kind = CompanionFrameKind.fromRaw(kindByte)
                ?: throw CompanionBinaryFrameException.UnknownFrameKind(kindByte.toInt() and 0xFF)
            if (data.size <= CompanionConstants.BINARY_HEADER_LENGTH) {
                throw CompanionBinaryFrameException.EmptyPayload()
            }
            val generation = readUInt32BigEndian(data, 1)
            val requestID = readUInt32BigEndian(data, 5)
            val payload = data.copyOfRange(CompanionConstants.BINARY_HEADER_LENGTH, data.size)
            return CompanionBinaryFrame(
                kind = kind,
                generation = generation,
                requestID = requestID,
                payload = payload
            )
        }

        private fun readUInt32BigEndian(data: ByteArray, offset: Int): Long {
            val b0 = (data[offset].toLong() and 0xFF) shl 24
            val b1 = (data[offset + 1].toLong() and 0xFF) shl 16
            val b2 = (data[offset + 2].toLong() and 0xFF) shl 8
            val b3 = data[offset + 3].toLong() and 0xFF
            return b0 or b1 or b2 or b3
        }

        private fun writeUInt32BigEndian(out: ByteArray, offset: Int, value: Long) {
            out[offset] = ((value ushr 24) and 0xFF).toByte()
            out[offset + 1] = ((value ushr 16) and 0xFF).toByte()
            out[offset + 2] = ((value ushr 8) and 0xFF).toByte()
            out[offset + 3] = (value and 0xFF).toByte()
        }
    }
}
