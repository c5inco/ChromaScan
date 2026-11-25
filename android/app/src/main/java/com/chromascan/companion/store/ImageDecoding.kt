package com.chromascan.companion.store

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.util.Log
import java.nio.ByteBuffer

object ImageDecoding {
    private const val TAG = "ChromaImageDecoding"

    /**
     * Decodes HEIC or JPEG bytes while preserving embedded Display P3 / sRGB ICC color spaces
     * via Android's API 28+ `ImageDecoder`.
     */
    fun decodeWideGamutBitmap(bytes: ByteArray): Bitmap? {
        if (bytes.isEmpty()) return null
        return try {
            val source = ImageDecoder.createSource(ByteBuffer.wrap(bytes))
            ImageDecoder.decodeBitmap(source) { decoder, _, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                decoder.isMutableRequired = false
            }
        } catch (e: Exception) {
            Log.w(TAG, "ImageDecoder failed (${e.message}), trying BitmapFactory fallback")
            runCatching {
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            }.getOrNull()
        }
    }

    fun isLikelyHeic(bytes: ByteArray): Boolean {
        if (bytes.size < 12) return false
        // ISO BMFF header: bytes 4..7 == "ftyp"
        return bytes[4] == 'f'.code.toByte() &&
            bytes[5] == 't'.code.toByte() &&
            bytes[6] == 'y'.code.toByte() &&
            bytes[7] == 'p'.code.toByte()
    }
}
