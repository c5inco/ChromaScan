package com.chromascan.companion

import com.chromascan.companion.model.CanvasViewMode
import com.chromascan.companion.model.ClientMessage
import com.chromascan.companion.model.ColorProfileMode
import com.chromascan.companion.model.CompanionBinaryFrame
import com.chromascan.companion.model.CompanionBinaryFrameException
import com.chromascan.companion.model.CompanionConstants
import com.chromascan.companion.model.CompanionFrameKind
import com.chromascan.companion.model.CompanionImageKind
import com.chromascan.companion.model.CompanionJson
import com.chromascan.companion.model.CompanionOperation
import com.chromascan.companion.model.HostMessage
import com.chromascan.companion.model.NormalizedCropRect
import com.chromascan.companion.model.OutputFormat
import com.chromascan.companion.model.ScanRotation
import com.chromascan.companion.model.ScanSettingsPatch
import com.chromascan.companion.model.SessionSnapshot
import com.chromascan.companion.network.CompanionTarget
import com.chromascan.companion.store.RemoteSessionStore
import kotlinx.serialization.encodeToString
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CompanionProtocolTest {

    @Test
    fun clientHelloWireFormatMatchesSwift() {
        val msg: ClientMessage = ClientMessage.Hello(
            protocolVersion = CompanionConstants.PROTOCOL_VERSION,
            clientName = "Pixel 4 XL",
            pin = "482910",
            authToken = null
        )
        val encoded = CompanionJson.encodeToString(msg)
        assertTrue(encoded.contains("\"type\":\"hello\""))
        assertTrue(encoded.contains("\"protocolVersion\":1"))
        assertTrue(encoded.contains("\"clientName\":\"Pixel 4 XL\""))
        assertTrue(encoded.contains("\"pin\":\"482910\""))
        assertFalse(encoded.contains("authToken"))
    }

    @Test
    fun updateSettingsPatchEncodesRotationAsIntAndOmitsNulls() {
        val patch = ScanSettingsPatch(
            resolution = 1200,
            rotation = ScanRotation.DEG_90,
            colorProfile = ColorProfileMode.DISPLAY_P3_CONVERT
        )
        val encoded = CompanionJson.encodeToString<ClientMessage>(ClientMessage.UpdateSettings(patch))
        assertTrue(encoded.contains("\"type\":\"updateSettings\""))
        assertTrue(encoded.contains("\"resolution\":1200"))
        assertTrue(encoded.contains("\"rotation\":90"))
        assertTrue(encoded.contains("\"colorProfile\":\"p3_convert\""))
        assertFalse(encoded.contains("hardwareBrightness"))
    }

    @Test
    fun hostWelcomeAndImageReadyDecodeFromSwiftJson() {
        val swiftWelcomeJson = """
            {
              "type": "welcome",
              "protocolVersion": 1,
              "hostID": "host-123",
              "hostName": "Mac Studio",
              "authToken": "tok-abc",
              "snapshot": {
                "scanners": [],
                "settings": {
                  "inputSource": "Platen",
                  "resolution": 1200,
                  "colorMode": "RGB24",
                  "intent": "Photo",
                  "transferFormat": "application/octet-stream",
                  "rotation": 270,
                  "autoTrimEmptySpace": false,
                  "hardwareBrightness": 1000,
                  "hardwareContrast": 1000,
                  "colorProfile": "p3_assign",
                  "outputFormat": "tiff_lzw",
                  "quality": 0.92,
                  "previewCompressionEnabled": true,
                  "toneAdjustments": { "blackPoint": 0.0, "whitePoint": 1.0, "gamma": 1.0 },
                  "baseFilename": "scan-001",
                  "autoIncrement": true
                },
                "cropRect": { "x": 0.1, "y": 0.2, "width": 0.5, "height": 0.6 },
                "viewMode": "preview",
                "isBusy": false,
                "statusText": "Ready",
                "isErrorStatus": false,
                "hasPreviewImage": true,
                "hasScanImage": false,
                "platenAspectRatio": 0.77,
                "saveFolderDisplayName": "Scans",
                "outputPreviewSummary": "Display P3 · TIFF",
                "activeImageGeneration": 4,
                "isScanTrimmed": false
              }
            }
        """.trimIndent()

        val decoded = CompanionJson.decodeFromString<HostMessage>(swiftWelcomeJson)
        assertTrue(decoded is HostMessage.Welcome)
        val welcome = decoded as HostMessage.Welcome
        assertEquals("Mac Studio", welcome.hostName)
        assertEquals(ScanRotation.DEG_270, welcome.snapshot.settings.rotation)
        assertEquals(ColorProfileMode.DISPLAY_P3_ASSIGN, welcome.snapshot.settings.colorProfile)
        assertEquals(CanvasViewMode.PREVIEW, welcome.snapshot.viewMode)

        val swiftImageReady = """
            {
              "type": "imageReady",
              "kind": "highResTile",
              "generation": 7,
              "requestID": 42,
              "width": 1200,
              "height": 1600,
              "trueWidth": 10200,
              "trueHeight": 13200,
              "dpi": 1200,
              "normalizedRect": { "x": 0.35, "y": 0.40, "width": 0.15, "height": 0.20 },
              "summaryText": "Live: Display P3"
            }
        """.trimIndent()
        val imgMsg = CompanionJson.decodeFromString<HostMessage>(swiftImageReady) as HostMessage.ImageReady
        assertEquals(CompanionImageKind.HIGH_RES_TILE, imgMsg.kind)
        assertEquals(42L, imgMsg.requestID)
        assertEquals(0.35, imgMsg.normalizedRect!!.x, 1e-6)
    }

    @Test
    fun binaryFramePackUnpackRoundTrip() {
        val payload = byteArrayOf(0x00, 0x01, 0x7F, -128, -1, 42)
        val frame = CompanionBinaryFrame(
            kind = CompanionFrameKind.SCAN_PROXY,
            generation = 0x01020304L,
            requestID = 0xAABBCCDDL,
            payload = payload
        )
        val packed = frame.pack()
        assertEquals(CompanionConstants.BINARY_HEADER_LENGTH + payload.size, packed.size)
        assertEquals(2.toByte(), packed[0])
        assertEquals(0x01.toByte(), packed[1])
        assertEquals(0x04.toByte(), packed[4])
        assertEquals(0xAA.toByte(), packed[5])
        assertEquals(0xDD.toByte(), packed[8])

        val unpacked = CompanionBinaryFrame.unpack(packed)
        assertEquals(frame.kind, unpacked.kind)
        assertEquals(frame.generation, unpacked.generation)
        assertEquals(frame.requestID, unpacked.requestID)
        assertArrayEquals(payload, unpacked.payload)
    }

    @Test(expected = CompanionBinaryFrameException.TruncatedHeader::class)
    fun binaryFrameRejectsShortHeader() {
        CompanionBinaryFrame.unpack(byteArrayOf(1, 2, 3))
    }

    @Test
    fun cropRotationRoundTripAcrossAllOrientations() {
        val original = NormalizedCropRect(x = 0.12, y = 0.25, width = 0.48, height = 0.35)
        for (rot in ScanRotation.entries) {
            val disp = original.physicalToDisplay(rot)
            val back = NormalizedCropRect.fromDisplayRect(disp, rot)
            assertEquals(original.x, back.x, 1e-6)
            assertEquals(original.y, back.y, 1e-6)
            assertEquals(original.width, back.width, 1e-6)
            assertEquals(original.height, back.height, 1e-6)
        }
    }

    @Test
    fun progressAndReadoutFormatting() {
        assertEquals("1m 12s", RemoteSessionStore.formatElapsedSeconds(72.0))
        assertEquals("45s", RemoteSessionStore.formatElapsedSeconds(45.2))
        val snap = SessionSnapshot(
            viewMode = CanvasViewMode.PREVIEW,
            statusText = "Ready"
        )
        val readout = RemoteSessionStore.computePlannedCaptureReadout(snap)
        assertTrue(readout.contains("8.50\"×11.69\""))
        assertEquals(CompanionOperation.SCAN, CompanionJson.decodeFromString<CompanionOperation>("\"scan\""))
        assertEquals(OutputFormat.HEIC, CompanionJson.decodeFromString<OutputFormat>("\"heic\""))
    }

    @Test
    fun wsUrlValidationRejectsMalformedHostsAndPorts() {
        assertEquals("ws://192.168.4.45:55745/", CompanionTarget.buildWsUrl("192.168.4.45", 55745))
        assertEquals("ws://mac-studio.local:8080/", CompanionTarget.buildWsUrl("mac-studio.local", 8080))
        assertNull(CompanionTarget.buildWsUrl("bad host with spaces", 8080))
        assertNull(CompanionTarget.buildWsUrl("192.168.1.1/path", 8080))
        assertNull(CompanionTarget.buildWsUrl("192.168.1.1", 0))
        assertNull(CompanionTarget.buildWsUrl("192.168.1.1", 70000))
    }

    @Test(expected = IllegalArgumentException::class)
    fun binaryFrameRejectsOutOfRangeUInt32Generation() {
        CompanionBinaryFrame(
            kind = CompanionFrameKind.PREVIEW_PROXY,
            generation = 0x1_0000_0000L,
            requestID = 0L,
            payload = byteArrayOf(1)
        ).pack()
    }
}
