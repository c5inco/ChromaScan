package com.chromascan.companion.store

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.util.Log
import java.nio.ByteBuffer
import kotlin.math.max
import kotlin.math.roundToInt

object ImageDecoding {
    private const val TAG = "ChromaImageDecoding"
    private const val MAX_DECODE_DIMENSION = 4096

    /**
     * Decodes HEIC or JPEG bytes while preserving embedded Display P3 / sRGB ICC color spaces
     * via Android's API 28+ `ImageDecoder`, capping decoded dimensions to guard RAM budget.
     */
    fun decodeWideGamutBitmap(bytes: ByteArray, maxDimension: Int = MAX_DECODE_DIMENSION): Bitmap? {
        if (bytes.isEmpty()) return null
        return try {
            val source = ImageDecoder.createSource(ByteBuffer.wrap(bytes))
            ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                decoder.isMutableRequired = false
                val w = info.size.width
                val h = info.size.height
                val longest = max(w, h)
                if (longest > maxDimension && w > 0 && h > 0) {
                    val scale = maxDimension.toDouble() / longest.toDouble()
                    decoder.setTargetSize(
                        max(1, (w * scale).roundToInt()),
                        max(1, (h * scale).roundToInt())
                    )
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "ImageDecoder failed (${e.message}), trying BitmapFactory fallback")
            runCatching {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                var sampleSize = 1
                val longest = max(bounds.outWidth, bounds.outHeight)
                while (longest / sampleSize > maxDimension) {
                    sampleSize *= 2
                }
                val opts = BitmapFactory.Options().apply { inSampleSize = sampleSize }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
            }.getOrNull()
        }
    }

    fun isLikelyHeic(bytes: ByteArray): Boolean {
        if (bytes.size < 12) return false
        return bytes[4] == 'f'.code.toByte() &&
            bytes[5] == 't'.code.toByte() &&
            bytes[6] == 'y'.code.toByte() &&
            bytes[7] == 'p'.code.toByte()
    }
}
