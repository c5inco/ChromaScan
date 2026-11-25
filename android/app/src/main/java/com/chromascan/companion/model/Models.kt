package com.chromascan.companion.model

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// MARK: - Discovered Scanner

@Serializable
data class DiscoveredScanner(
    val id: String,
    val name: String,
    val host: String,
    val port: Int,
    val useTLS: Boolean,
    val rootPath: String,
    val modelName: String? = null,
    val uuid: String? = null
) {
    val displayTitle: String get() = name
}

// MARK: - eSCL Capabilities

@Serializable
data class ScannerCapabilities(
    val version: String,
    val makeAndModel: String,
    val serialNumber: String? = null,
    val platen: InputSourceCaps? = null,
    val adf: InputSourceCaps? = null,
    val brightnessRange: ToneRange? = null,
    val contrastRange: ToneRange? = null
) {
    @Serializable
    data class ToneRange(
        val min: Int,
        val max: Int,
        val normal: Int,
        val step: Int
    )

    @Serializable
    data class InputSourceCaps(
        val minWidth: Int,
        val maxWidth: Int,
        val minHeight: Int,
        val maxHeight: Int,
        val discreteResolutions: List<Int>,
        val colorModes: List<String>,
        val documentFormats: List<String>,
        val intents: List<String>,
        val contentTypes: List<String>,
        val maxOpticalResolution: Int
    ) {
        val supportsRawOctetStream: Boolean
            get() = documentFormats.contains("application/octet-stream")
        val supportsJPEG: Boolean
            get() = documentFormats.contains("image/jpeg")
    }

    fun caps(forSource: ScanInputSource): InputSourceCaps? = when (forSource) {
        ScanInputSource.PLATEN -> platen
        ScanInputSource.FEEDER -> adf
    }
}

@Serializable
data class ScannerStatus(
    val state: String,
    val adfState: String? = null
)

// MARK: - Canvas View Mode & Scan Options

@Serializable
enum class CanvasViewMode(val wireValue: String) {
    @SerialName("preview")
    PREVIEW("preview"),

    @SerialName("scan")
    SCAN("scan")
}

@Serializable
enum class ScanInputSource(val displayName: String) {
    @SerialName("Platen")
    PLATEN("Flatbed"),

    @SerialName("Feeder")
    FEEDER("Document Feeder (ADF)")
}

@Serializable
enum class ScanColorMode(val rawValue: String, val displayName: String, val bytesPerPixel: Int) {
    @SerialName("RGB24")
    RGB24("RGB24", "Color (24-bit RGB)", 3),

    @SerialName("Grayscale8")
    GRAYSCALE8("Grayscale8", "Grayscale (8-bit)", 1)
}

@Serializable
enum class ScanIntent(val displayName: String) {
    @SerialName("Photo")
    PHOTO("Photo"),

    @SerialName("Document")
    DOCUMENT("Document"),

    @SerialName("TextAndGraphic")
    TEXT_AND_GRAPHIC("Text & Graphic")
}

@Serializable
enum class TransferFormat(val displayName: String) {
    @SerialName("application/octet-stream")
    RAW_OCTET_STREAM("RAW (Lossless)"),

    @SerialName("image/jpeg")
    JPEG("Fast Wi-Fi (JPEG)")
}

object ScanRotationSerializer : KSerializer<ScanRotation> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("ScanRotation", PrimitiveKind.INT)

    override fun serialize(encoder: Encoder, value: ScanRotation) {
        encoder.encodeInt(value.degrees)
    }

    override fun deserialize(decoder: Decoder): ScanRotation {
        val deg = decoder.decodeInt()
        return ScanRotation.fromDegrees(deg)
    }
}

@Serializable(with = ScanRotationSerializer::class)
enum class ScanRotation(val degrees: Int) {
    DEG_0(0),
    DEG_90(90),
    DEG_180(180),
    DEG_270(270);

    val displayName: String get() = "${degrees}°"

    companion object {
        fun fromDegrees(deg: Int): ScanRotation = entries.firstOrNull { it.degrees == deg } ?: DEG_0
    }
}

@Serializable
enum class ColorProfileMode(val displayName: String, val shortName: String) {
    @SerialName("p3_convert")
    DISPLAY_P3_CONVERT("Display P3 (Convert from sRGB)", "Display P3 (Accurate)"),

    @SerialName("p3_assign")
    DISPLAY_P3_ASSIGN("Display P3 (Assign — Vivid)", "Display P3 (Vivid)"),

    @SerialName("srgb")
    SRGB("sRGB IEC61966-2.1", "sRGB")
}

@Serializable
enum class OutputFormat(val displayName: String, val fileExtension: String) {
    @SerialName("tiff_lzw")
    TIFF_LZW("TIFF (LZW Lossless)", "tiff"),

    @SerialName("tiff_uncompressed")
    TIFF_UNCOMPRESSED("TIFF (Uncompressed)", "tiff"),

    @SerialName("png")
    PNG("PNG (Lossless)", "png"),

    @SerialName("jpeg")
    JPEG("JPEG", "jpg"),

    @SerialName("heic")
    HEIC("HEIC", "heic");

    val supportsQuality: Boolean get() = this == JPEG || this == HEIC
}

@Serializable
data class ToneAdjustments(
    val blackPoint: Double = 0.0,
    val whitePoint: Double = 1.0,
    val gamma: Double = 1.0
) {
    val isIdentity: Boolean
        get() = abs(blackPoint) < 0.0001 && abs(whitePoint - 1.0) < 0.0001 && abs(gamma - 1.0) < 0.0001
}

data class NormalizedPoint(val x: Double, val y: Double)

data class DisplayRect(val x: Double, val y: Double, val width: Double, val height: Double) {
    val minX: Double get() = x
    val minY: Double get() = y
    val maxX: Double get() = x + width
    val maxY: Double get() = y + height
}

data class ESCLRegion(val xOffset: Int, val yOffset: Int, val width: Int, val height: Int)

/**
 * Normalized crop rectangle in physical flatbed coordinates (origin top-left, 0..1).
 * Mirrors `NormalizedCropRect` in `Sources/Core/Models.swift`.
 */
@Serializable
data class NormalizedCropRect(
    val x: Double = 0.0,
    val y: Double = 0.0,
    val width: Double = 1.0,
    val height: Double = 1.0
) {
    val isFull: Boolean
        get() = abs(x) < 0.001 && abs(y) < 0.001 && abs(width - 1.0) < 0.001 && abs(height - 1.0) < 0.001

    fun clamped(minSize: Double = 0.02): NormalizedCropRect {
        val cx = max(0.0, min(1.0 - minSize, x))
        val cy = max(0.0, min(1.0 - minSize, y))
        val cw = max(minSize, min(1.0 - cx, width))
        val ch = max(minSize, min(1.0 - cy, height))
        return NormalizedCropRect(x = cx, y = cy, width = cw, height = ch)
    }

    fun toESCLRegion(maxWidth: Int, maxHeight: Int): ESCLRegion {
        val c = clamped()
        val xOff = max(0, (c.x * maxWidth.toDouble()).roundToInt())
        val yOff = max(0, (c.y * maxHeight.toDouble()).roundToInt())
        val w = max(8, min(maxWidth - xOff, (c.width * maxWidth.toDouble()).roundToInt()))
        val h = max(8, min(maxHeight - yOff, (c.height * maxHeight.toDouble()).roundToInt()))
        return ESCLRegion(xOff, yOff, w, h)
    }

    fun physicalToDisplay(rotation: ScanRotation): DisplayRect {
        val p1 = mapPointToDisplay(NormalizedPoint(x, y), rotation)
        val p2 = mapPointToDisplay(NormalizedPoint(x + width, y + height), rotation)
        val minX = min(p1.x, p2.x)
        val minY = min(p1.y, p2.y)
        return DisplayRect(
            x = minX,
            y = minY,
            width = abs(p2.x - p1.x),
            height = abs(p2.y - p1.y)
        )
    }

    companion object {
        val FULL = NormalizedCropRect(0.0, 0.0, 1.0, 1.0)

        fun fromDisplayRect(rect: DisplayRect, rotation: ScanRotation): NormalizedCropRect {
            val p1 = mapPointToPhysical(NormalizedPoint(rect.minX, rect.minY), rotation)
            val p2 = mapPointToPhysical(NormalizedPoint(rect.maxX, rect.maxY), rotation)
            val minX = min(p1.x, p2.x)
            val minY = min(p1.y, p2.y)
            return NormalizedCropRect(
                x = minX,
                y = minY,
                width = abs(p2.x - p1.x),
                height = abs(p2.y - p1.y)
            ).clamped()
        }

        fun mapPointToDisplay(p: NormalizedPoint, rotation: ScanRotation): NormalizedPoint = when (rotation) {
            ScanRotation.DEG_0 -> p
            ScanRotation.DEG_90 -> NormalizedPoint(1.0 - p.y, p.x)
            ScanRotation.DEG_180 -> NormalizedPoint(1.0 - p.x, 1.0 - p.y)
            ScanRotation.DEG_270 -> NormalizedPoint(p.y, 1.0 - p.x)
        }

        fun mapPointToPhysical(p: NormalizedPoint, rotation: ScanRotation): NormalizedPoint = when (rotation) {
            ScanRotation.DEG_0 -> p
            ScanRotation.DEG_90 -> NormalizedPoint(p.y, 1.0 - p.x)
            ScanRotation.DEG_180 -> NormalizedPoint(1.0 - p.x, 1.0 - p.y)
            ScanRotation.DEG_270 -> NormalizedPoint(1.0 - p.y, p.x)
        }
    }
}

// MARK: - Session Settings & Patch

@Serializable
data class ScanSessionSettings(
    val inputSource: ScanInputSource = ScanInputSource.PLATEN,
    val resolution: Int = 1200,
    val colorMode: ScanColorMode = ScanColorMode.RGB24,
    val intent: ScanIntent = ScanIntent.PHOTO,
    val transferFormat: TransferFormat = TransferFormat.RAW_OCTET_STREAM,
    val rotation: ScanRotation = ScanRotation.DEG_0,
    val autoTrimEmptySpace: Boolean = false,
    val hardwareBrightness: Int = 1000,
    val hardwareContrast: Int = 1000,
    val colorProfile: ColorProfileMode = ColorProfileMode.DISPLAY_P3_CONVERT,
    val outputFormat: OutputFormat = OutputFormat.TIFF_LZW,
    val quality: Double = 0.92,
    val previewCompressionEnabled: Boolean = true,
    val toneAdjustments: ToneAdjustments = ToneAdjustments(),
    val baseFilename: String = "scan-001",
    val autoIncrement: Boolean = true
)

@Serializable
data class ScanSettingsPatch(
    val inputSource: ScanInputSource? = null,
    val resolution: Int? = null,
    val colorMode: ScanColorMode? = null,
    val intent: ScanIntent? = null,
    val transferFormat: TransferFormat? = null,
    val rotation: ScanRotation? = null,
    val autoTrimEmptySpace: Boolean? = null,
    val hardwareBrightness: Int? = null,
    val hardwareContrast: Int? = null,
    val resetHardwareTone: Boolean? = null,
    val colorProfile: ColorProfileMode? = null,
    val outputFormat: OutputFormat? = null,
    val quality: Double? = null,
    val previewCompressionEnabled: Boolean? = null,
    val toneAdjustments: ToneAdjustments? = null,
    val resetSoftwareTone: Boolean? = null,
    val baseFilename: String? = null,
    val autoIncrement: Boolean? = null
)
