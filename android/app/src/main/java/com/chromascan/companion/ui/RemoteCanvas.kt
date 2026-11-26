package com.chromascan.companion.ui

import android.graphics.Bitmap
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.chromascan.companion.model.DisplayRect
import com.chromascan.companion.model.NormalizedCropRect
import com.chromascan.companion.model.ScanRotation
import com.chromascan.companion.ui.theme.ChromaPalette
import com.chromascan.companion.ui.theme.GoogleSansFlexFamily
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

private enum class CropHandle {
    TOP_LEFT, TOP, TOP_RIGHT,
    LEFT, RIGHT,
    BOTTOM_LEFT, BOTTOM, BOTTOM_RIGHT
}

private sealed class CropDragMode {
    data object None : CropDragMode()
    data class Move(val startPoint: Offset, val initialDisplayRect: DisplayRect) : CropDragMode()
    data class Resize(val handle: CropHandle, val startPoint: Offset, val initialDisplayRect: DisplayRect) : CropDragMode()
}

/**
 * High-FPS Display P3 canvas supporting pinch-to-zoom, pan, double-tap 1:1 zoom,
 * on-demand 1:1 high-res tile overlay in Scan mode, and 8-handle rotation-aware
 * touch crop editing in Preview mode.
 */
@Composable
fun RemoteCanvas(
    proxyBitmap: Bitmap,
    truePixelWidth: Int,
    truePixelHeight: Int,
    tileBitmap: Bitmap?,
    tileNormalizedRect: NormalizedCropRect?,
    isLoadingTile: Boolean,
    showCropOverlay: Boolean,
    isCropEditable: Boolean,
    cropRect: NormalizedCropRect,
    rotation: ScanRotation,
    topContentPadding: Dp = 88.dp,
    bottomContentPadding: Dp = 142.dp,
    onCropChanged: (NormalizedCropRect, Boolean) -> Unit,
    onRequestTile: (NormalizedCropRect, Int) -> Unit,
    onClearTile: () -> Unit,
    modifier: Modifier = Modifier
) {
    val density = LocalDensity.current
    val viewConfig = LocalViewConfiguration.current
    val scope = rememberCoroutineScope()

    val proxyImage = remember(proxyBitmap) { proxyBitmap.asImageBitmap() }
    val tileImage = remember(tileBitmap) { tileBitmap?.asImageBitmap() }
    val maskPath = remember { Path().apply { fillType = PathFillType.EvenOdd } }

    var viewportSize by remember { mutableStateOf(IntSize.Zero) }
    var zoomScale by remember { mutableFloatStateOf(1f) }
    var panOffset by remember { mutableStateOf(Offset.Zero) }
    var activeDragCrop by remember { mutableStateOf<NormalizedCropRect?>(null) }
    var isDraggingCrop by remember { mutableStateOf(false) }

    var zoomBadgeText by remember { mutableStateOf<String?>(null) }
    var showZoomBadge by remember { mutableStateOf(false) }
    var settleJob by remember { mutableStateOf<Job?>(null) }
    var badgeHideJob by remember { mutableStateOf<Job?>(null) }

    // Keep latest callbacks, padding, and props accessible inside pointerInput without stale closures
    val topPadPx by rememberUpdatedState(with(density) { topContentPadding.toPx() })
    val sidePadPx = with(density) { 18.dp.toPx() }
    val bottomPadPx by rememberUpdatedState(with(density) { bottomContentPadding.toPx() })
    val handleHitRadiusPx = with(density) { 26.dp.toPx() } // 52dp diameter touch target
    val handleDotRadiusPx = with(density) { 7.5.dp.toPx() }
    val doubleTapTimeoutMs = viewConfig.doubleTapTimeoutMillis

    val currentCrop by rememberUpdatedState(cropRect)
    val currentRotation by rememberUpdatedState(rotation)
    val currentShowCrop by rememberUpdatedState(showCropOverlay)
    val currentCropEditable by rememberUpdatedState(isCropEditable)
    val currentOnCropChanged by rememberUpdatedState(onCropChanged)
    val currentOnRequestTile by rememberUpdatedState(onRequestTile)
    val currentOnClearTile by rememberUpdatedState(onClearTile)
    val currentTrueW by rememberUpdatedState(if (truePixelWidth > 0) truePixelWidth else proxyBitmap.width)
    val currentProxyW by rememberUpdatedState(proxyBitmap.width)

    fun computeBasePageRect(vp: IntSize, imgW: Int, imgH: Int): Rect {
        if (vp.width <= 20 || vp.height <= 20 || imgW <= 0 || imgH <= 0) return Rect.Zero
        val availW = max(1f, vp.width - sidePadPx * 2f)
        val availH = max(1f, vp.height - topPadPx - bottomPadPx)
        val fit = min(availW / imgW.toFloat(), availH / imgH.toFloat())
        val w = (imgW * fit).roundToInt().toFloat()
        val h = (imgH * fit).roundToInt().toFloat()
        val left = (vp.width - w) * 0.5f
        val top = topPadPx + (availH - h) * 0.5f
        return Rect(left, top, left + w, top + h)
    }

    fun computeMaxZoom(baseRect: Rect): Float {
        if (baseRect.width <= 1f) return 8f
        val oneToOne = currentTrueW.toFloat() / baseRect.width
        return (oneToOne * 3f).coerceIn(4f, 28f)
    }

    fun clampPan(offset: Offset, scale: Float, baseRect: Rect, vp: IntSize): Offset {
        if (scale <= 1.001f || baseRect == Rect.Zero) return Offset.Zero
        val scaledW = baseRect.width * scale
        val scaledH = baseRect.height * scale
        val centerX = vp.width * 0.5f
        val centerY = vp.height * 0.5f
        val maxDx = max(0f, (scaledW - vp.width) * 0.5f) + abs(centerX - baseRect.center.x)
        val maxDy = max(0f, (scaledH - vp.height) * 0.5f) + abs(centerY - baseRect.center.y)
        return Offset(
            x = offset.x.coerceIn(-maxDx, maxDx),
            y = offset.y.coerceIn(-maxDy, maxDy)
        )
    }

    fun transformedPageRect(baseRect: Rect, scale: Float, pan: Offset): Rect {
        if (baseRect == Rect.Zero) return Rect.Zero
        val cx = baseRect.center.x + pan.x
        val cy = baseRect.center.y + pan.y
        val halfW = baseRect.width * scale * 0.5f
        val halfH = baseRect.height * scale * 0.5f
        return Rect(cx - halfW, cy - halfH, cx + halfW, cy + halfH)
    }

    fun updateZoomBadge(scale: Float, baseRect: Rect, hasTile: Boolean, loading: Boolean) {
        if (scale <= 1.02f || baseRect.width <= 1f) {
            showZoomBadge = false
            return
        }
        val effectivePct = max(1, ((baseRect.width * scale) / max(1, currentTrueW).toFloat() * 100f).roundToInt())
        zoomBadgeText = when {
            hasTile -> "$effectivePct% · 1:1"
            loading -> "$effectivePct% · HD…"
            else -> "$effectivePct%"
        }
        showZoomBadge = true
        badgeHideJob?.cancel()
        if (!loading) {
            badgeHideJob = scope.launch {
                delay(1800)
                showZoomBadge = false
            }
        }
    }

    fun scheduleTileRequest(scale: Float, pan: Offset, baseRect: Rect, vp: IntSize) {
        settleJob?.cancel()
        if (currentShowCrop || currentTrueW <= currentProxyW || baseRect == Rect.Zero) return
        settleJob = scope.launch {
            delay(90)
            val pageRect = transformedPageRect(baseRect, scale, pan)
            val vpRect = Rect(0f, 0f, vp.width.toFloat(), vp.height.toFloat())
            val visible = pageRect.intersect(vpRect)
            if (visible.width <= 4f || visible.height <= 4f || pageRect.width <= 1f || pageRect.height <= 1f) {
                return@launch
            }
            if (pageRect.width <= currentProxyW * 1.05f) {
                currentOnClearTile()
                return@launch
            }
            val pad = 0.015f
            val nx = max(0f, (visible.left - pageRect.left) / pageRect.width - pad)
            val ny = max(0f, (visible.top - pageRect.top) / pageRect.height - pad)
            val maxX = min(1f, (visible.right - pageRect.left) / pageRect.width + pad)
            val maxY = min(1f, (visible.bottom - pageRect.top) / pageRect.height + pad)
            val normRect = NormalizedCropRect(
                x = nx.toDouble(),
                y = ny.toDouble(),
                width = max(0.01f, maxX - nx).toDouble(),
                height = max(0.01f, maxY - ny).toDouble()
            )
            val maxPixelW = (vp.width * 1.15f).roundToInt()
            currentOnRequestTile(normRect, maxPixelW)
        }
    }

    // Reset zoom when image dimensions or view mode change
    LaunchedEffect(proxyBitmap.width, proxyBitmap.height, showCropOverlay) {
        zoomScale = 1f
        panOffset = Offset.Zero
        showZoomBadge = false
        settleJob?.cancel()
    }

    // Update badge when tile arrives or starts loading
    LaunchedEffect(tileBitmap, isLoadingTile) {
        val baseRect = computeBasePageRect(viewportSize, proxyBitmap.width, proxyBitmap.height)
        if (zoomScale > 1.02f) {
            updateZoomBadge(
                scale = zoomScale,
                baseRect = baseRect,
                hasTile = tileBitmap != null && !showCropOverlay,
                loading = isLoadingTile
            )
        }
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .semantics {
                contentDescription = if (showCropOverlay) {
                    "Flatbed preview canvas with crop handles"
                } else {
                    "Full-resolution scan preview canvas"
                }
            }
            .onSizeChanged { viewportSize = it }
            .pointerInput(proxyBitmap.width, proxyBitmap.height) {
                var lastTapTimeMs = 0L
                var lastTapPos = Offset.Zero

                awaitEachGesture {
                    val firstDown = awaitFirstDown(requireUnconsumed = false)
                    val baseRect = computeBasePageRect(viewportSize, proxyBitmap.width, proxyBitmap.height)
                    val curPageRect = transformedPageRect(baseRect, zoomScale, panOffset)

                    val initialCrop = currentCrop
                    var pendingCropMode: CropDragMode = CropDragMode.None
                    if (currentShowCrop && currentCropEditable && curPageRect.width > 10f && curPageRect.height > 10f) {
                        val displayNorm = initialCrop.physicalToDisplay(currentRotation)
                        val selRect = Rect(
                            left = curPageRect.left + displayNorm.minX.toFloat() * curPageRect.width,
                            top = curPageRect.top + displayNorm.minY.toFloat() * curPageRect.height,
                            right = curPageRect.left + displayNorm.maxX.toFloat() * curPageRect.width,
                            bottom = curPageRect.top + displayNorm.maxY.toFloat() * curPageRect.height
                        )
                        val hitHandle = hitTestHandle(firstDown.position, selRect, handleHitRadiusPx)
                        pendingCropMode = when {
                            hitHandle != null -> CropDragMode.Resize(hitHandle, firstDown.position, displayNorm)
                            // Only move trimmed marquee with 1 finger when unzoomed; when zoomed in,
                            // 1-finger drag pans the zoomed canvas and 2-finger pinch always zooms.
                            !initialCrop.isFull && zoomScale <= 1.02f && selRect.contains(firstDown.position) ->
                                CropDragMode.Move(firstDown.position, displayNorm)
                            else -> CropDragMode.None
                        }
                    }

                    val cropTouchSlop = viewConfig.touchSlop
                    var activeCropMode: CropDragMode = CropDragMode.None
                    var latestCrop = initialCrop
                    var moved = false
                    var didTransform = false
                    val startPos = firstDown.position
                    val downTime = System.currentTimeMillis()
                    val maxZoom = computeMaxZoom(baseRect)

                    // For handle grabs, consume immediately once dragging starts; never block a
                    // second finger from seamlessly taking over as pinch-to-zoom.
                    try {
                        while (true) {
                            val event = awaitPointerEvent()
                            val pressed = event.changes.filter { it.pressed }

                            if (pressed.isEmpty()) {
                                if (activeCropMode !is CropDragMode.None) {
                                    currentOnCropChanged(latestCrop, true)
                                } else {
                                    val elapsed = System.currentTimeMillis() - downTime
                                    if (!moved && elapsed < doubleTapTimeoutMs) {
                                        val sinceLastTap = downTime - lastTapTimeMs
                                        val distLast = hypot(
                                            (startPos.x - lastTapPos.x).toDouble(),
                                            (startPos.y - lastTapPos.y).toDouble()
                                        )
                                        if (sinceLastTap < doubleTapTimeoutMs && distLast < 96.0) {
                                            if (zoomScale > 1.05f) {
                                                zoomScale = 1f
                                                panOffset = Offset.Zero
                                                currentOnClearTile()
                                                updateZoomBadge(1f, baseRect, hasTile = false, loading = false)
                                            } else {
                                                val targetScale = (currentTrueW.toFloat() / max(1f, baseRect.width))
                                                    .coerceIn(2.5f, maxZoom)
                                                val rawPan = Offset(
                                                    x = (baseRect.center.x - startPos.x) * (targetScale - 1f),
                                                    y = (baseRect.center.y - startPos.y) * (targetScale - 1f)
                                                )
                                                zoomScale = targetScale
                                                panOffset = clampPan(rawPan, targetScale, baseRect, viewportSize)
                                                updateZoomBadge(targetScale, baseRect, hasTile = false, loading = false)
                                                scheduleTileRequest(zoomScale, panOffset, baseRect, viewportSize)
                                            }
                                            lastTapTimeMs = 0L
                                        } else {
                                            lastTapTimeMs = downTime
                                            lastTapPos = startPos
                                        }
                                    } else if (didTransform) {
                                        scheduleTileRequest(zoomScale, panOffset, baseRect, viewportSize)
                                    }
                                }
                                break
                            }

                            // A second finger always wins for pinch-to-zoom, even inside a trimmed marquee.
                            if (pressed.size >= 2) {
                                if (activeCropMode !is CropDragMode.None) {
                                    // Revert tiny accidental nudge before second finger landed
                                    activeDragCrop = null
                                    isDraggingCrop = false
                                    activeCropMode = CropDragMode.None
                                    currentOnCropChanged(initialCrop, true)
                                }
                                pendingCropMode = CropDragMode.None
                            }

                            // Single-finger crop handle resize or unzoomed trimmed marquee move
                            if (pressed.size == 1 && (activeCropMode !is CropDragMode.None || pendingCropMode !is CropDragMode.None)) {
                                val change = pressed.first()
                                val distFromStart = hypot(
                                    (change.position.x - startPos.x).toDouble(),
                                    (change.position.y - startPos.y).toDouble()
                                ).toFloat()
                                if (activeCropMode is CropDragMode.None) {
                                    val threshold = if (pendingCropMode is CropDragMode.Resize) cropTouchSlop * 0.4f else cropTouchSlop
                                    if (distFromStart >= threshold) {
                                        activeCropMode = pendingCropMode
                                        pendingCropMode = CropDragMode.None
                                        isDraggingCrop = true
                                        moved = true
                                    }
                                }
                                if (activeCropMode !is CropDragMode.None) {
                                    if (change.positionChanged()) {
                                        change.consume()
                                        val updated = applyCropDrag(
                                            mode = activeCropMode,
                                            pt = change.position,
                                            pageRect = curPageRect,
                                            rotation = currentRotation
                                        )
                                        if (updated != null) {
                                            latestCrop = updated
                                            activeDragCrop = updated
                                            currentOnCropChanged(updated, false)
                                        }
                                    }
                                    continue
                                }
                                // Still below touch slop waiting to see if user taps, drags, or places 2nd finger
                                continue
                            }

                            // Pinch-to-zoom and zoomed panning
                            val zoomChange = event.calculateZoom()
                            val panChange = event.calculatePan()
                            val centroid = event.calculateCentroid(useCurrent = false)

                            if (zoomChange != 1f || (zoomScale > 1.01f && panChange != Offset.Zero) ||
                                hypot(
                                    (pressed.first().position.x - startPos.x).toDouble(),
                                    (pressed.first().position.y - startPos.y).toDouble()
                                ) > 12.0
                            ) {
                                moved = true
                            }

                            if (zoomChange != 1f || (zoomScale > 1.01f && panChange != Offset.Zero)) {
                                val oldScale = zoomScale
                                val newScale = (oldScale * zoomChange).coerceIn(1f, maxZoom)
                                val scaleFactor = newScale / oldScale
                                val currentCenter = baseRect.center + panOffset
                                val focalShift = (currentCenter - centroid) * (scaleFactor - 1f)
                                val rawPan = if (newScale <= 1.001f) {
                                    Offset.Zero
                                } else {
                                    panOffset + panChange + focalShift
                                }
                                zoomScale = newScale
                                panOffset = clampPan(rawPan, newScale, baseRect, viewportSize)
                                didTransform = true
                                if (zoomChange != 1f) {
                                    currentOnClearTile()
                                }
                                updateZoomBadge(zoomScale, baseRect, hasTile = false, loading = false)
                                event.changes.forEach { if (it.positionChanged()) it.consume() }
                            }
                        }
                    } finally {
                        activeDragCrop = null
                        isDraggingCrop = false
                    }
                }
            }
    ) {
        // Read zoomScale, panOffset, and activeDragCrop inside DrawScope to avoid recomposing on every gesture frame
        Canvas(modifier = Modifier.fillMaxSize()) {
            val baseRect = computeBasePageRect(
                IntSize(size.width.roundToInt(), size.height.roundToInt()),
                proxyBitmap.width,
                proxyBitmap.height
            )
            val pageRect = transformedPageRect(baseRect, zoomScale, panOffset)
            if (pageRect == Rect.Zero) return@Canvas

            // Soft page shadow & white paper backing
            drawRect(
                color = Color.Black.copy(alpha = 0.32f),
                topLeft = Offset(pageRect.left + 3f, pageRect.top + 8f),
                size = Size(pageRect.width, pageRect.height)
            )
            drawRect(
                color = Color.White,
                topLeft = pageRect.topLeft,
                size = Size(pageRect.width, pageRect.height)
            )

            // Draw proxy image
            drawImage(
                image = proxyImage,
                dstOffset = IntOffset(pageRect.left.roundToInt(), pageRect.top.roundToInt()),
                dstSize = IntSize(max(1, pageRect.width.roundToInt()), max(1, pageRect.height.roundToInt()))
            )

            // Draw 1:1 high-res tile overlay in Scan mode
            if (!showCropOverlay && tileImage != null && tileNormalizedRect != null) {
                val tx = pageRect.left + tileNormalizedRect.x.toFloat() * pageRect.width
                val ty = pageRect.top + tileNormalizedRect.y.toFloat() * pageRect.height
                val tw = tileNormalizedRect.width.toFloat() * pageRect.width
                val th = tileNormalizedRect.height.toFloat() * pageRect.height
                drawImage(
                    image = tileImage,
                    dstOffset = IntOffset(tx.roundToInt(), ty.roundToInt()),
                    dstSize = IntSize(max(1, tw.roundToInt()), max(1, th.roundToInt()))
                )
            }

            // Draw touch-friendly crop overlay in Preview mode
            if (showCropOverlay && pageRect.width > 10f && pageRect.height > 10f) {
                val displayedCrop = activeDragCrop ?: cropRect
                val displayNorm = displayedCrop.physicalToDisplay(rotation)
                val selRect = Rect(
                    left = pageRect.left + displayNorm.minX.toFloat() * pageRect.width,
                    top = pageRect.top + displayNorm.minY.toFloat() * pageRect.height,
                    right = pageRect.left + displayNorm.maxX.toFloat() * pageRect.width,
                    bottom = pageRect.top + displayNorm.maxY.toFloat() * pageRect.height
                )

                // Dim exterior when cropped (reusing pre-allocated Path)
                if (!displayedCrop.isFull) {
                    maskPath.reset()
                    maskPath.fillType = PathFillType.EvenOdd
                    maskPath.addRect(pageRect)
                    maskPath.addRect(selRect)
                    drawPath(path = maskPath, color = Color.Black.copy(alpha = 0.48f))
                }

                // Rule of thirds while dragging
                if (isDraggingCrop) {
                    for (frac in listOf(1f / 3f, 2f / 3f)) {
                        val vx = selRect.left + selRect.width * frac
                        drawLine(
                            color = Color.White.copy(alpha = 0.55f),
                            start = Offset(vx, selRect.top),
                            end = Offset(vx, selRect.bottom),
                            strokeWidth = 1.5f
                        )
                        val hy = selRect.top + selRect.height * frac
                        drawLine(
                            color = Color.White.copy(alpha = 0.55f),
                            start = Offset(selRect.left, hy),
                            end = Offset(selRect.right, hy),
                            strokeWidth = 1.5f
                        )
                    }
                }

                // Selection border
                drawRect(
                    color = ChromaPalette.Cream,
                    topLeft = selRect.topLeft,
                    size = Size(selRect.width, selRect.height),
                    style = Stroke(width = 4f)
                )

                // 8 circular touch handles
                for (handle in CropHandle.entries) {
                    val center = handleCenter(handle, selRect)
                    drawCircle(
                        color = Color.White,
                        radius = handleDotRadiusPx,
                        center = center
                    )
                    drawCircle(
                        color = ChromaPalette.Vermilion,
                        radius = handleDotRadiusPx,
                        center = center,
                        style = Stroke(width = 4.5f)
                    )
                }
            }
        }

        // Zoom badge pill (bottom-right, above floating dock)
        AnimatedVisibility(
            visible = showZoomBadge && !zoomBadgeText.isNullOrEmpty(),
            enter = fadeIn(),
            exit = fadeOut(),
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(end = 14.dp, bottom = bottomContentPadding + 8.dp)
        ) {
            Box(
                modifier = Modifier
                    .background(Color.Black.copy(alpha = 0.68f), RoundedCornerShape(12.dp))
                    .padding(horizontal = 10.dp, vertical = 4.dp)
            ) {
                Text(
                    text = zoomBadgeText.orEmpty(),
                    color = Color.White,
                    fontSize = 11.sp,
                    fontFamily = GoogleSansFlexFamily,
                    fontWeight = FontWeight.SemiBold
                )
            }
        }
    }
}

private fun handleCenter(handle: CropHandle, rect: Rect): Offset = when (handle) {
    CropHandle.TOP_LEFT -> Offset(rect.left, rect.top)
    CropHandle.TOP -> Offset(rect.center.x, rect.top)
    CropHandle.TOP_RIGHT -> Offset(rect.right, rect.top)
    CropHandle.LEFT -> Offset(rect.left, rect.center.y)
    CropHandle.RIGHT -> Offset(rect.right, rect.center.y)
    CropHandle.BOTTOM_LEFT -> Offset(rect.left, rect.bottom)
    CropHandle.BOTTOM -> Offset(rect.center.x, rect.bottom)
    CropHandle.BOTTOM_RIGHT -> Offset(rect.right, rect.bottom)
}

private fun hitTestHandle(pt: Offset, selRect: Rect, hitRadiusPx: Float): CropHandle? {
    var bestHandle: CropHandle? = null
    var bestDist = Float.MAX_VALUE
    for (handle in CropHandle.entries) {
        val c = handleCenter(handle, selRect)
        val d = hypot((pt.x - c.x).toDouble(), (pt.y - c.y).toDouble()).toFloat()
        if (d <= hitRadiusPx && d < bestDist) {
            bestDist = d
            bestHandle = handle
        }
    }
    return bestHandle
}

private fun applyCropDrag(
    mode: CropDragMode,
    pt: Offset,
    pageRect: Rect,
    rotation: ScanRotation
): NormalizedCropRect? {
    val minFrac = 0.04
    val newDisplay: DisplayRect = when (mode) {
        CropDragMode.None -> return null

        is CropDragMode.Move -> {
            val dx = (pt.x - mode.startPoint.x) / pageRect.width.toDouble()
            val dy = (pt.y - mode.startPoint.y) / pageRect.height.toDouble()
            val nx = max(0.0, min(1.0 - mode.initialDisplayRect.width, mode.initialDisplayRect.minX + dx))
            val ny = max(0.0, min(1.0 - mode.initialDisplayRect.height, mode.initialDisplayRect.minY + dy))
            DisplayRect(nx, ny, mode.initialDisplayRect.width, mode.initialDisplayRect.height)
        }

        is CropDragMode.Resize -> {
            val dx = (pt.x - mode.startPoint.x) / pageRect.width.toDouble()
            val dy = (pt.y - mode.startPoint.y) / pageRect.height.toDouble()
            var minX = mode.initialDisplayRect.minX
            var minY = mode.initialDisplayRect.minY
            var maxX = mode.initialDisplayRect.maxX
            var maxY = mode.initialDisplayRect.maxY

            when (mode.handle) {
                CropHandle.TOP_LEFT -> {
                    minX = max(0.0, min(maxX - minFrac, minX + dx))
                    minY = max(0.0, min(maxY - minFrac, minY + dy))
                }
                CropHandle.TOP -> {
                    minY = max(0.0, min(maxY - minFrac, minY + dy))
                }
                CropHandle.TOP_RIGHT -> {
                    maxX = min(1.0, max(minX + minFrac, maxX + dx))
                    minY = max(0.0, min(maxY - minFrac, minY + dy))
                }
                CropHandle.LEFT -> {
                    minX = max(0.0, min(maxX - minFrac, minX + dx))
                }
                CropHandle.RIGHT -> {
                    maxX = min(1.0, max(minX + minFrac, maxX + dx))
                }
                CropHandle.BOTTOM_LEFT -> {
                    minX = max(0.0, min(maxX - minFrac, minX + dx))
                    maxY = min(1.0, max(minY + minFrac, maxY + dy))
                }
                CropHandle.BOTTOM -> {
                    maxY = min(1.0, max(minY + minFrac, maxY + dy))
                }
                CropHandle.BOTTOM_RIGHT -> {
                    maxX = min(1.0, max(minX + minFrac, maxX + dx))
                    maxY = min(1.0, max(minY + minFrac, maxY + dy))
                }
            }
            DisplayRect(minX, minY, maxX - minX, maxY - minY)
        }
    }
    return NormalizedCropRect.fromDisplayRect(newDisplay, rotation)
}
