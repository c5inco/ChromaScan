package com.chromascan.companion.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonGroupDefaults
import androidx.compose.material3.ContainedLoadingIndicator
import androidx.compose.material3.ElevatedAssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.ToggleButton
import androidx.compose.material3.ToggleButtonDefaults
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.toShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.chromascan.companion.R
import com.chromascan.companion.model.CanvasViewMode
import com.chromascan.companion.model.NormalizedCropRect
import com.chromascan.companion.model.ScanSettingsPatch
import com.chromascan.companion.model.SessionSnapshot
import com.chromascan.companion.network.ConnectionStatus
import com.chromascan.companion.store.RemoteSessionStore
import com.chromascan.companion.store.RemoteUiState
import com.chromascan.companion.ui.theme.ChromaPalette
import com.chromascan.companion.ui.theme.GoogleSansFlexFamily
import com.chromascan.companion.ui.theme.MaterialSymbol
import kotlin.math.PI
import kotlin.math.sin

@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun RemoteWorkspaceScreen(
    state: RemoteUiState,
    hostName: String,
    onSelectScanner: (String) -> Unit,
    onRefreshScanners: () -> Unit,
    onAddManualScanner: (String, Int, Boolean) -> Unit,
    onUpdateSettings: (ScanSettingsPatch) -> Unit,
    onCropChanged: (NormalizedCropRect, Boolean) -> Unit,
    onResetCrop: () -> Unit,
    onTrimEmptySpace: () -> Unit,
    onSetViewMode: (CanvasViewMode) -> Unit,
    onTriggerPreview: () -> Unit,
    onTriggerScan: () -> Unit,
    onTriggerExport: () -> Unit,
    onCancelOperation: () -> Unit,
    onRequestTile: (NormalizedCropRect, Int) -> Unit,
    onClearTile: () -> Unit,
    onToggleNotify: (Boolean) -> Unit,
    onSaveCopyToPhotos: () -> Unit,
    onDisconnect: () -> Unit,
    onDismissError: () -> Unit
) {
    var showControlsSheet by remember { mutableStateOf(false) }
    var showHostDialog by remember { mutableStateOf(false) }
    var showRenameDialog by remember { mutableStateOf(false) }
    var topPillHeightPx by remember { mutableIntStateOf(0) }
    var bottomDockHeightPx by remember { mutableIntStateOf(0) }

    val density = LocalDensity.current
    val snap = state.snapshot
    val isBusy = snap?.isBusy == true
    val hasTopPill = state.topStatusPrimaryLine.isNotBlank() || state.topStatusSecondaryLine.isNotBlank()
    val hasTopChips = state.showsTrimChip || state.showsFullPageChip

    val topPillHeightDp = if (topPillHeightPx > 0) with(density) { topPillHeightPx.toDp() } else 42.dp
    val bottomDockHeightDp = if (bottomDockHeightPx > 0) {
        with(density) { bottomDockHeightPx.toDp() }
    } else if (isBusy) {
        144.dp
    } else {
        80.dp
    }
    val navBottomDp = with(density) { WindowInsets.navigationBars.getBottom(this).toDp() }

    val targetTopPad = (if (hasTopPill) 10.dp + topPillHeightDp else 0.dp) +
        (if (hasTopChips) 40.dp else 0.dp) +
        16.dp
    val targetBottomPad = navBottomDp + 12.dp + bottomDockHeightDp + 16.dp

    val canvasTopPad by animateDpAsState(
        targetValue = targetTopPad,
        animationSpec = tween(durationMillis = 220, easing = FastOutSlowInEasing),
        label = "canvas_top_pad"
    )
    val canvasBottomPad by animateDpAsState(
        targetValue = targetBottomPad,
        animationSpec = tween(durationMillis = 220, easing = FastOutSlowInEasing),
        label = "canvas_bottom_pad"
    )

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
    ) {
        // Full-bleed darkroom canvas stage
        Column(modifier = Modifier.fillMaxSize()) {
            ExpressiveWorkspaceTopBar(
                hostName = hostName,
                state = state,
                onHostPillClick = { showHostDialog = true },
                onSelectMode = onSetViewMode
            )

            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .background(ChromaPalette.SurfaceLowest)
            ) {
                if (snap != null) {
                    val showingScan = snap.viewMode == CanvasViewMode.SCAN && snap.hasScanImage
                    val proxy = state.proxyBitmap
                    if (proxy != null) {
                        val trueW = state.proxyInfo?.trueWidth ?: proxy.width
                        val trueH = state.proxyInfo?.trueHeight ?: proxy.height
                        RemoteCanvas(
                            proxyBitmap = proxy,
                            truePixelWidth = trueW,
                            truePixelHeight = trueH,
                            tileBitmap = state.tileBitmap,
                            tileNormalizedRect = state.tileNormalizedRect,
                            isLoadingTile = state.isLoadingTile,
                            showCropOverlay = !showingScan,
                            isCropEditable = state.isConnected && !snap.isBusy && !state.isAwaitingRotatedProxy,
                            cropRect = snap.cropRect,
                            rotation = state.proxyRotation,
                            topContentPadding = canvasTopPad,
                            bottomContentPadding = canvasBottomPad,
                            onCropChanged = onCropChanged,
                            onRequestTile = onRequestTile,
                            onClearTile = onClearTile,
                            modifier = Modifier.fillMaxSize()
                        )
                    } else {
                        ExpressiveEmptyCanvas(
                            showingScan = showingScan,
                            modifier = Modifier
                                .fillMaxSize()
                                .padding(top = canvasTopPad, bottom = canvasBottomPad)
                        )
                    }

                    // Top floating consolidated live + measurements pill & Trim / Full Page chips
                    Column(
                        modifier = Modifier
                            .align(Alignment.TopCenter)
                            .fillMaxWidth()
                            .padding(horizontal = 14.dp, vertical = 10.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Top
                    ) {
                        val primaryLine = state.topStatusPrimaryLine
                        val secondaryLine = state.topStatusSecondaryLine
                        if (hasTopPill) {
                            Surface(
                                onClick = { showControlsSheet = true },
                                shape = RoundedCornerShape(18.dp),
                                color = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.92f),
                                tonalElevation = 2.dp,
                                modifier = Modifier.onSizeChanged { topPillHeightPx = it.height }
                            ) {
                                Row(
                                    modifier = Modifier.padding(start = 14.dp, end = 8.dp, top = 6.dp, bottom = 6.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                                ) {
                                    Column(
                                        modifier = Modifier.weight(1f, fill = false),
                                        horizontalAlignment = Alignment.Start,
                                        verticalArrangement = Arrangement.spacedBy(1.dp)
                                    ) {
                                        if (primaryLine.isNotBlank()) {
                                            Text(
                                                text = primaryLine,
                                                color = MaterialTheme.colorScheme.onSurface,
                                                style = MaterialTheme.typography.labelSmall.copy(
                                                    fontFamily = GoogleSansFlexFamily,
                                                    fontWeight = FontWeight.SemiBold,
                                                    fontFeatureSettings = "tnum"
                                                ),
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis
                                            )
                                        }
                                        if (secondaryLine.isNotBlank()) {
                                            Text(
                                                text = secondaryLine,
                                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                                style = MaterialTheme.typography.labelSmall.copy(
                                                    fontFamily = GoogleSansFlexFamily,
                                                    fontSize = 10.5.sp,
                                                    fontFeatureSettings = "tnum"
                                                ),
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis
                                            )
                                        }
                                    }

                                    Box(
                                        modifier = Modifier
                                            .size(30.dp)
                                            .background(
                                                MaterialTheme.colorScheme.surfaceContainerHighest,
                                                CircleShape
                                            ),
                                        contentAlignment = Alignment.Center
                                    ) {
                                        MaterialSymbol(
                                            iconRes = R.drawable.ms_tune,
                                            contentDescription = "Scan controls",
                                            tint = MaterialTheme.colorScheme.primary,
                                            modifier = Modifier.size(16.dp)
                                        )
                                    }
                                }
                            }
                        }

                        val chipEnter = fadeIn(
                            animationSpec = tween(durationMillis = 180, delayMillis = 45, easing = FastOutSlowInEasing)
                        ) + scaleIn(
                            animationSpec = tween(durationMillis = 200, delayMillis = 45, easing = FastOutSlowInEasing),
                            initialScale = 0.9f
                        ) + expandHorizontally(
                            animationSpec = tween(durationMillis = 220, easing = FastOutSlowInEasing),
                            expandFrom = Alignment.CenterHorizontally,
                            clip = false
                        )
                        val chipExit = fadeOut(
                            animationSpec = tween(durationMillis = 110, easing = FastOutSlowInEasing)
                        ) + scaleOut(
                            animationSpec = tween(durationMillis = 140, easing = FastOutSlowInEasing),
                            targetScale = 0.9f
                        ) + shrinkHorizontally(
                            animationSpec = tween(durationMillis = 220, easing = FastOutSlowInEasing),
                            shrinkTowards = Alignment.CenterHorizontally,
                            clip = false
                        )

                        Row(
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            AnimatedVisibility(
                                visible = state.showsTrimChip,
                                enter = chipEnter,
                                exit = chipExit
                            ) {
                                ElevatedAssistChip(
                                    onClick = onTrimEmptySpace,
                                    enabled = state.isConnected && !snap.isBusy,
                                    shape = RoundedCornerShape(50),
                                    modifier = Modifier.padding(horizontal = 4.dp),
                                    label = { Text("Trim", style = MaterialTheme.typography.labelMedium) },
                                    leadingIcon = {
                                        MaterialSymbol(
                                            iconRes = R.drawable.ms_crop,
                                            contentDescription = null,
                                            modifier = Modifier.size(16.dp)
                                        )
                                    },
                                    colors = AssistChipDefaults.elevatedAssistChipColors(
                                        containerColor = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.92f),
                                        labelColor = MaterialTheme.colorScheme.onSurface,
                                        leadingIconContentColor = MaterialTheme.colorScheme.primary
                                    )
                                )
                            }
                            AnimatedVisibility(
                                visible = state.showsFullPageChip,
                                enter = chipEnter,
                                exit = chipExit
                            ) {
                                ElevatedAssistChip(
                                    onClick = onResetCrop,
                                    enabled = state.isConnected && !snap.isBusy,
                                    shape = RoundedCornerShape(50),
                                    modifier = Modifier.padding(horizontal = 4.dp),
                                    label = { Text("Full page", style = MaterialTheme.typography.labelMedium) },
                                    leadingIcon = {
                                        MaterialSymbol(
                                            iconRes = R.drawable.ms_fit_screen,
                                            contentDescription = null,
                                            modifier = Modifier.size(16.dp)
                                        )
                                    },
                                    colors = AssistChipDefaults.elevatedAssistChipColors(
                                        containerColor = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.92f),
                                        labelColor = MaterialTheme.colorScheme.onSurface,
                                        leadingIconContentColor = MaterialTheme.colorScheme.primary
                                    )
                                )
                            }
                        }
                    }
                } else {
                    Column(
                        modifier = Modifier.align(Alignment.Center),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(14.dp)
                    ) {
                        ContainedLoadingIndicator(
                            modifier = Modifier.size(56.dp),
                            containerColor = MaterialTheme.colorScheme.primaryContainer,
                            indicatorColor = MaterialTheme.colorScheme.primary
                        )
                        Text(
                            text = "Syncing session…",
                            style = MaterialTheme.typography.titleSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }

        // Bottom floating toast + M3 Expressive Floating Toolbar / Active Scan Card
        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            AnimatedVisibility(
                visible = !state.toastMessage.isNullOrBlank(),
                enter = slideInVertically(initialOffsetY = { it / 2 }) + fadeIn(),
                exit = slideOutVertically(targetOffsetY = { it / 2 }) + fadeOut()
            ) {
                Surface(
                    shape = RoundedCornerShape(50),
                    color = ChromaPalette.Success,
                    shadowElevation = 4.dp
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 9.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        MaterialSymbol(
                            iconRes = R.drawable.ms_check_circle,
                            contentDescription = null,
                            tint = ChromaPalette.Ink,
                            modifier = Modifier.size(18.dp)
                        )
                        Text(
                            text = state.toastMessage.orEmpty(),
                            color = ChromaPalette.Ink,
                            style = MaterialTheme.typography.labelLarge
                        )
                    }
                }
            }

            if (snap != null) {
                AnimatedContent(
                    targetState = snap.isBusy,
                    modifier = Modifier.onSizeChanged { bottomDockHeightPx = it.height },
                    transitionSpec = {
                        (fadeIn() + slideInVertically { it / 4 }) togetherWith
                            (fadeOut() + slideOutVertically { it / 4 })
                    },
                    label = "floating_bottom_dock"
                ) { busy ->
                    if (busy) {
                        ExpressiveActiveScanCard(
                            state = state,
                            onCancelOperation = onCancelOperation
                        )
                    } else {
                        ExpressiveFloatingActionDock(
                            state = state,
                            snap = snap,
                            onTriggerPreview = onTriggerPreview,
                            onTriggerScan = onTriggerScan,
                            onTriggerExport = onTriggerExport,
                            onRenameFilename = { showRenameDialog = true }
                        )
                    }
                }
            }
        }
    }

    if (showControlsSheet) {
        RemoteControlsSheet(
            state = state,
            onDismiss = { showControlsSheet = false },
            onSelectScanner = onSelectScanner,
            onRefreshScanners = onRefreshScanners,
            onAddManualScanner = onAddManualScanner,
            onUpdateSettings = onUpdateSettings,
            onToggleNotify = onToggleNotify,
            onSaveCopyToPhotos = onSaveCopyToPhotos,
            onDisconnect = onDisconnect
        )
    }

    if (showRenameDialog && snap != null) {
        RenameFilenameDialog(
            currentBaseName = snap.settings.baseFilename,
            fileExtension = snap.settings.outputFormat.fileExtension,
            saveFolderName = snap.saveFolderDisplayName,
            onDismiss = { showRenameDialog = false },
            onConfirm = { draft ->
                val cleaned = RemoteSessionStore.sanitizedBaseFilename(draft, snap.settings.outputFormat)
                if (cleaned.isNotEmpty() && cleaned != snap.settings.baseFilename) {
                    onUpdateSettings(ScanSettingsPatch(baseFilename = cleaned))
                }
                showRenameDialog = false
            }
        )
    }

    if (showHostDialog) {
        AlertDialog(
            onDismissRequest = { showHostDialog = false },
            containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            shape = RoundedCornerShape(28.dp),
            icon = {
                MaterialSymbol(
                    iconRes = R.drawable.ms_desktop_mac,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(26.dp)
                )
            },
            title = { Text(hostName) },
            text = {
                Text(
                    text = state.snapshot?.selectedScanner?.displayTitle?.let { "Active scanner: $it" }
                        ?: "Connected to ChromaScan on $hostName.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            },
            confirmButton = {
                FilledTonalButton(
                    onClick = {
                        showHostDialog = false
                        onRefreshScanners()
                    }
                ) {
                    Text("Refresh scanners")
                }
            },
            dismissButton = {
                TextButton(
                    onClick = {
                        showHostDialog = false
                        onDisconnect()
                    }
                ) {
                    Text("Disconnect", color = MaterialTheme.colorScheme.error)
                }
            }
        )
    }

    state.errorAlert?.let { err ->
        AlertDialog(
            onDismissRequest = onDismissError,
            containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            shape = RoundedCornerShape(28.dp),
            title = { Text(err.title) },
            text = { Text(err.message, color = MaterialTheme.colorScheme.onSurfaceVariant) },
            confirmButton = {
                FilledTonalButton(onClick = onDismissError) {
                    Text("OK")
                }
            }
        )
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun ExpressiveWorkspaceTopBar(
    hostName: String,
    state: RemoteUiState,
    onHostPillClick: () -> Unit,
    onSelectMode: (CanvasViewMode) -> Unit
) {
    val dotColor = when (state.connectionStatus) {
        is ConnectionStatus.Connected -> ChromaPalette.Success
        is ConnectionStatus.Connecting, is ConnectionStatus.Reconnecting -> ChromaPalette.Warning
        is ConnectionStatus.Disconnected -> ChromaPalette.Danger
    }

    val subtitle = when (val cs = state.connectionStatus) {
        is ConnectionStatus.Reconnecting -> "Reconnecting (${cs.attempt})…"
        is ConnectionStatus.Connecting -> "Connecting…"
        is ConnectionStatus.Disconnected -> "Disconnected"
        is ConnectionStatus.Connected -> {
            state.snapshot?.selectedScanner?.displayTitle ?: "No scanner selected"
        }
    }

    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        tonalElevation = 1.dp
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Surface(
                shape = RoundedCornerShape(50),
                color = MaterialTheme.colorScheme.surfaceContainerHigh,
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(50))
                    .clickable(onClick = onHostPillClick)
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(9.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .size(9.dp)
                            .background(dotColor, CircleShape)
                    )
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = hostName,
                            style = MaterialTheme.typography.labelLarge,
                            color = MaterialTheme.colorScheme.onSurface,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            text = subtitle,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }

            state.snapshot?.let { snap ->
                val canSwitchToScan = snap.hasScanImage || snap.viewMode == CanvasViewMode.SCAN
                Row(horizontalArrangement = Arrangement.spacedBy(ButtonGroupDefaults.ConnectedSpaceBetween)) {
                    ToggleButton(
                        checked = snap.viewMode == CanvasViewMode.PREVIEW,
                        onCheckedChange = { if (it) onSelectMode(CanvasViewMode.PREVIEW) },
                        shapes = ButtonGroupDefaults.connectedLeadingButtonShapes(),
                        colors = ToggleButtonDefaults.colors(
                            containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                            contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                            checkedContainerColor = MaterialTheme.colorScheme.primary,
                            checkedContentColor = MaterialTheme.colorScheme.onPrimary
                        ),
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp)
                    ) {
                        Text("Preview", style = MaterialTheme.typography.labelMedium, maxLines = 1, softWrap = false)
                    }
                    ToggleButton(
                        checked = snap.viewMode == CanvasViewMode.SCAN,
                        onCheckedChange = { if (it) onSelectMode(CanvasViewMode.SCAN) },
                        enabled = canSwitchToScan,
                        shapes = ButtonGroupDefaults.connectedTrailingButtonShapes(),
                        colors = ToggleButtonDefaults.colors(
                            containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                            contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                            checkedContainerColor = MaterialTheme.colorScheme.primary,
                            checkedContentColor = MaterialTheme.colorScheme.onPrimary
                        ),
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp)
                    ) {
                        Text("Last Scan", style = MaterialTheme.typography.labelMedium, maxLines = 1, softWrap = false)
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun ExpressiveEmptyCanvas(
    showingScan: Boolean,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier.padding(horizontal = 36.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Box(
            modifier = Modifier
                .size(84.dp)
                .background(
                    MaterialTheme.colorScheme.surfaceContainerHigh,
                    MaterialShapes.SoftBurst.toShape()
                ),
            contentAlignment = Alignment.Center
        ) {
            MaterialSymbol(
                iconRes = R.drawable.ms_scanner,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(38.dp)
            )
        }
        Spacer(Modifier.height(16.dp))
        Text(
            text = if (showingScan) "No scan captured yet" else "Ready on flatbed",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurface
        )
        Spacer(Modifier.height(6.dp))
        Text(
            text = if (showingScan) {
                "Tap Scan to capture a full-resolution Display P3 image on your Mac."
            } else {
                "Tap Preview to frame your artwork, or tap Scan for a full page capture."
            },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )
    }
}

@Composable
private fun ExpressiveFloatingActionDock(
    state: RemoteUiState,
    snap: SessionSnapshot,
    onTriggerPreview: () -> Unit,
    onTriggerScan: () -> Unit,
    onTriggerExport: () -> Unit,
    onRenameFilename: () -> Unit
) {
    val ready = state.isConnected && snap.selectedScannerID != null && snap.capabilities != null
    val canExport = state.isConnected && snap.hasScanImage

    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        if (snap.isErrorStatus && snap.statusText.isNotBlank()) {
            Surface(
                shape = RoundedCornerShape(50),
                color = MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.92f)
            ) {
                Text(
                    text = snap.statusText,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onErrorContainer,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp)
                )
            }
        }

        // Compact tappable output filename chip (tap to rename)
        val outputFilename = state.effectiveOutputFilename
        if (outputFilename.isNotBlank()) {
            Surface(
                onClick = onRenameFilename,
                enabled = state.isConnected && !snap.isBusy,
                shape = RoundedCornerShape(50),
                color = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.92f),
                tonalElevation = 1.dp
            ) {
                Text(
                    text = outputFilename,
                    style = MaterialTheme.typography.labelSmall.copy(
                        fontFamily = GoogleSansFlexFamily,
                        fontWeight = FontWeight.SemiBold,
                        fontFeatureSettings = "tnum"
                    ),
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier
                        .widthIn(max = 220.dp)
                        .padding(horizontal = 12.dp, vertical = 4.dp)
                )
            }
        }

        // Action row mirroring iOS: Preview | Scan (prominent) | Export (icon-only)
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            FilledTonalButton(
                onClick = onTriggerPreview,
                enabled = ready && snap.capabilities.platen != null,
                shape = RoundedCornerShape(50),
                contentPadding = PaddingValues(horizontal = 14.dp, vertical = 12.dp),
                colors = ButtonDefaults.filledTonalButtonColors(
                    containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    contentColor = MaterialTheme.colorScheme.onSurface
                ),
                modifier = Modifier
                    .weight(1f)
                    .height(48.dp)
            ) {
                MaterialSymbol(
                    iconRes = R.drawable.ms_visibility,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp)
                )
                Spacer(Modifier.width(6.dp))
                Text("Preview", style = MaterialTheme.typography.labelLarge, maxLines = 1)
            }

            Button(
                onClick = onTriggerScan,
                enabled = ready,
                shape = RoundedCornerShape(50),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = MaterialTheme.colorScheme.primary,
                    contentColor = MaterialTheme.colorScheme.onPrimary
                ),
                modifier = Modifier
                    .weight(1f)
                    .height(48.dp)
            ) {
                MaterialSymbol(
                    iconRes = R.drawable.ms_scanner,
                    contentDescription = null,
                    modifier = Modifier.size(19.dp)
                )
                Spacer(Modifier.width(7.dp))
                Text(
                    text = "Scan",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold,
                    maxLines = 1
                )
            }

            FilledTonalIconButton(
                onClick = onTriggerExport,
                enabled = canExport,
                shape = CircleShape,
                colors = IconButtonDefaults.filledTonalIconButtonColors(
                    containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    contentColor = MaterialTheme.colorScheme.primary,
                    disabledContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.55f),
                    disabledContentColor = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.38f)
                ),
                modifier = Modifier.size(48.dp)
            ) {
                MaterialSymbol(
                    iconRes = R.drawable.ms_download,
                    contentDescription = "Export scan",
                    modifier = Modifier.size(21.dp)
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun ExpressiveActiveScanCard(
    state: RemoteUiState,
    onCancelOperation: () -> Unit
) {
    val info = state.activeOperationInfo

    Surface(
        shape = RoundedCornerShape(28.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        shadowElevation = 6.dp,
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 18.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                LoadingIndicator(
                    modifier = Modifier.size(28.dp),
                    color = MaterialTheme.colorScheme.secondary
                )
                Text(
                    text = info.title,
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )

                FilledTonalButton(
                    onClick = onCancelOperation,
                    enabled = state.isConnected,
                    shape = RoundedCornerShape(50),
                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 6.dp),
                    colors = ButtonDefaults.filledTonalButtonColors(
                        containerColor = MaterialTheme.colorScheme.errorContainer,
                        contentColor = MaterialTheme.colorScheme.onErrorContainer
                    )
                ) {
                    MaterialSymbol(
                        iconRes = R.drawable.ms_close,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp)
                    )
                    Spacer(Modifier.width(4.dp))
                    Text("Cancel", style = MaterialTheme.typography.labelMedium)
                }
            }

            // Vermilion-to-cyan wavy progress indicator matching macOS, iOS & Live Activity
            PigmentWavyProgressBar(
                fraction = info.progressFraction,
                modifier = Modifier.fillMaxWidth()
            )

            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(3.dp)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Text(
                        text = info.statusDetail,
                        style = MaterialTheme.typography.labelMedium.copy(
                            fontFamily = GoogleSansFlexFamily,
                            fontWeight = FontWeight.Medium,
                            fontFeatureSettings = "tnum"
                        ),
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f)
                    )
                    info.trailingBadge?.let { badge ->
                        Surface(
                            shape = RoundedCornerShape(50),
                            color = MaterialTheme.colorScheme.secondaryContainer
                        ) {
                            Text(
                                text = badge,
                                style = MaterialTheme.typography.labelSmall.copy(
                                    fontFamily = GoogleSansFlexFamily,
                                    fontWeight = FontWeight.Bold,
                                    fontFeatureSettings = "tnum"
                                ),
                                color = MaterialTheme.colorScheme.onSecondaryContainer,
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 3.dp)
                            )
                        }
                    }
                }
                if (info.metadataSummary.isNotBlank()) {
                    Text(
                        text = info.metadataSummary,
                        style = MaterialTheme.typography.labelSmall.copy(
                            fontFamily = GoogleSansFlexFamily,
                            fontFeatureSettings = "tnum"
                        ),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
        }
    }
}

@Composable
private fun PigmentWavyProgressBar(
    fraction: Double?,
    modifier: Modifier = Modifier
) {
    val trackColor = MaterialTheme.colorScheme.surfaceContainerHighest
    val targetFraction = fraction?.toFloat()?.coerceIn(0f, 1f) ?: 0f
    val animatedFraction by animateFloatAsState(
        targetValue = targetFraction,
        animationSpec = tween(durationMillis = 200, easing = FastOutSlowInEasing),
        label = "scan_progress_fraction"
    )
    val infiniteTransition = rememberInfiniteTransition(label = "scan_progress_motion")
    val wavePhase by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = (2.0 * PI).toFloat(),
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 900, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "wave_phase"
    )
    val sweepProgress by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1150, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "indeterminate_sweep"
    )

    Canvas(modifier = modifier.height(10.dp)) {
        val strokePx = 4.5.dp.toPx()
        val halfStroke = strokePx / 2f
        val centerY = size.height / 2f
        val amplitude = ((size.height - strokePx) / 2f).coerceAtLeast(1.5f)
        val wavelength = 24.dp.toPx()
        val gapPx = 5.dp.toPx()
        val minX = halfStroke
        val maxX = (size.width - halfStroke).coerceAtLeast(minX)
        val usableWidth = (maxX - minX).coerceAtLeast(0f)

        fun buildWavePath(startX: Float, endX: Float): Path {
            val path = Path()
            val span = (endX - startX).coerceAtLeast(0f)
            if (span <= 0.5f) {
                path.moveTo(startX, centerY)
                path.lineTo(endX, centerY)
                return path
            }
            val step = 2.dp.toPx().coerceAtLeast(2f)
            var x = startX
            var first = true
            while (x < endX) {
                val angle = ((x - startX) / wavelength) * (2.0 * PI).toFloat() - wavePhase
                val y = centerY + sin(angle.toDouble()).toFloat() * amplitude
                if (first) {
                    path.moveTo(x, y)
                    first = false
                } else {
                    path.lineTo(x, y)
                }
                x += step
            }
            val endAngle = (span / wavelength) * (2.0 * PI).toFloat() - wavePhase
            path.lineTo(endX, centerY + sin(endAngle.toDouble()).toFloat() * amplitude)
            return path
        }

        if (fraction != null) {
            val fillEnd = minX + usableWidth * animatedFraction
            val trackStart = if (animatedFraction > 0f) fillEnd + gapPx else minX
            if (trackStart < maxX) {
                drawLine(
                    color = trackColor,
                    start = Offset(trackStart, centerY),
                    end = Offset(maxX, centerY),
                    strokeWidth = strokePx,
                    cap = StrokeCap.Round
                )
            }
            if (animatedFraction > 0f) {
                val activeEnd = fillEnd.coerceAtLeast(minX + 1f)
                val gradient = Brush.horizontalGradient(
                    colors = listOf(ChromaPalette.Vermilion, ChromaPalette.OpticalCyan),
                    startX = minX,
                    endX = activeEnd.coerceAtLeast(minX + 1f)
                )
                drawPath(
                    path = buildWavePath(minX, activeEnd),
                    brush = gradient,
                    style = Stroke(width = strokePx, cap = StrokeCap.Round, join = StrokeJoin.Round)
                )
            }
        } else {
            drawLine(
                color = trackColor,
                start = Offset(minX, centerY),
                end = Offset(maxX, centerY),
                strokeWidth = strokePx,
                cap = StrokeCap.Round
            )
            val segWidth = (usableWidth * 0.34f).coerceAtLeast(48.dp.toPx()).coerceAtMost(usableWidth)
            val travel = (usableWidth - segWidth).coerceAtLeast(0f)
            val segStart = minX + travel * sweepProgress
            val segEnd = (segStart + segWidth).coerceAtMost(maxX)
            val gradient = Brush.horizontalGradient(
                colors = listOf(ChromaPalette.Vermilion, ChromaPalette.OpticalCyan),
                startX = segStart,
                endX = segEnd.coerceAtLeast(segStart + 1f)
            )
            drawPath(
                path = buildWavePath(segStart, segEnd),
                brush = gradient,
                style = Stroke(width = strokePx, cap = StrokeCap.Round, join = StrokeJoin.Round)
            )
        }
    }
}

@Composable
private fun RenameFilenameDialog(
    currentBaseName: String,
    fileExtension: String,
    saveFolderName: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit
) {
    var draft by remember(currentBaseName) { mutableStateOf(currentBaseName) }
    val trimmed = draft.trim()

    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
        shape = RoundedCornerShape(28.dp),
        title = { Text("Rename output file") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    label = { Text("Filename") },
                    suffix = { Text(".$fileExtension") },
                    singleLine = true,
                    shape = RoundedCornerShape(16.dp),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(
                        onDone = {
                            if (trimmed.isNotEmpty()) {
                                onConfirm(draft)
                            }
                        }
                    ),
                    modifier = Modifier.fillMaxWidth()
                )
                if (saveFolderName.isNotBlank()) {
                    Text(
                        text = "Saves to $saveFolderName on your Mac.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        },
        confirmButton = {
            FilledTonalButton(
                onClick = { onConfirm(draft) },
                enabled = trimmed.isNotEmpty()
            ) {
                Text("Save")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        }
    )
}
