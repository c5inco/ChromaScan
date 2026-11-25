package com.chromascan.companion.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonGroupDefaults
import androidx.compose.material3.ContainedLoadingIndicator
import androidx.compose.material3.ElevatedAssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.FloatingToolbarDefaults
import androidx.compose.material3.HorizontalFloatingToolbar
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.LinearWavyProgressIndicator
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.ToggleButton
import androidx.compose.material3.ToggleButtonDefaults
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.toShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
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
import com.chromascan.companion.store.RemoteUiState
import com.chromascan.companion.ui.theme.ChromaPalette
import com.chromascan.companion.ui.theme.GoogleSansFlexFamily
import com.chromascan.companion.ui.theme.MaterialSymbol

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

    val snap = state.snapshot
    val isBusy = snap?.isBusy == true
    val canvasBottomPad = if (isBusy) 182.dp else 142.dp

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
                            topContentPadding = 88.dp,
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
                                .padding(bottom = canvasBottomPad)
                        )
                    }

                    // Top floating output pill + expressive Trim / Full Page chips
                    Column(
                        modifier = Modifier
                            .align(Alignment.TopCenter)
                            .fillMaxWidth()
                            .padding(horizontal = 14.dp, vertical = 10.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        if (snap.outputPreviewSummary.isNotBlank() && proxy != null) {
                            Surface(
                                shape = RoundedCornerShape(50),
                                color = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.90f),
                                tonalElevation = 2.dp
                            ) {
                                Text(
                                    text = snap.outputPreviewSummary,
                                    color = MaterialTheme.colorScheme.onSurface,
                                    style = MaterialTheme.typography.labelSmall.copy(
                                        fontFamily = GoogleSansFlexFamily,
                                        fontFeatureSettings = "tnum"
                                    ),
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 5.dp)
                                )
                            }
                        }

                        if (proxy != null) {
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                ElevatedAssistChip(
                                    onClick = onTrimEmptySpace,
                                    enabled = state.isConnected && !snap.isBusy && !(showingScan && snap.isScanTrimmed),
                                    shape = RoundedCornerShape(50),
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
                                AnimatedVisibility(
                                    visible = !showingScan && !snap.cropRect.isFull,
                                    enter = fadeIn() + scaleIn(initialScale = 0.9f),
                                    exit = fadeOut() + scaleOut(targetScale = 0.9f)
                                ) {
                                    ElevatedAssistChip(
                                        onClick = onResetCrop,
                                        enabled = state.isConnected && !snap.isBusy,
                                        shape = RoundedCornerShape(50),
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
                    transitionSpec = {
                        (fadeIn() + slideInVertically { it / 4 }) togetherWith
                            (fadeOut() + slideOutVertically { it / 4 })
                    },
                    label = "floating_bottom_dock"
                ) { busy ->
                    if (busy) {
                        ExpressiveActiveScanCard(
                            state = state,
                            onCancelOperation = onCancelOperation,
                            onOpenControls = { showControlsSheet = true }
                        )
                    } else {
                        ExpressiveFloatingActionDock(
                            state = state,
                            snap = snap,
                            onTriggerPreview = onTriggerPreview,
                            onTriggerScan = onTriggerScan,
                            onTriggerExport = onTriggerExport,
                            onOpenControls = { showControlsSheet = true }
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
            val scanner = state.snapshot?.selectedScanner
            if (scanner != null) {
                "${scanner.displayTitle} · ${state.snapshot.settings.resolution} DPI"
            } else {
                "No scanner selected"
            }
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
                        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp)
                    ) {
                        Text("Preview", style = MaterialTheme.typography.labelLarge, maxLines = 1)
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
                        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp)
                    ) {
                        Text("Scan", style = MaterialTheme.typography.labelLarge, maxLines = 1)
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

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun ExpressiveFloatingActionDock(
    state: RemoteUiState,
    snap: SessionSnapshot,
    onTriggerPreview: () -> Unit,
    onTriggerScan: () -> Unit,
    onTriggerExport: () -> Unit,
    onOpenControls: () -> Unit
) {
    val ready = state.isConnected && snap.selectedScannerID != null && snap.capabilities != null

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        // Subtle floating capture dimensions / status pill
        val readout = state.dimensionsReadout
        if (readout.isNotBlank() || snap.statusText.isNotBlank()) {
            Surface(
                shape = RoundedCornerShape(50),
                color = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.88f)
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 5.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    if (readout.isNotBlank()) {
                        Text(
                            text = readout,
                            style = MaterialTheme.typography.labelSmall.copy(
                                fontFamily = GoogleSansFlexFamily,
                                fontFeatureSettings = "tnum"
                            ),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    if (snap.isErrorStatus && snap.statusText.isNotBlank()) {
                        Text(
                            text = snap.statusText,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.error,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
        }

        // Material 3 Expressive HorizontalFloatingToolbar + detached primary Scan FAB
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            HorizontalFloatingToolbar(
                expanded = true,
                colors = FloatingToolbarDefaults.standardFloatingToolbarColors(
                    toolbarContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    toolbarContentColor = MaterialTheme.colorScheme.onSurface
                )
            ) {
                FilledTonalButton(
                    onClick = onTriggerPreview,
                    enabled = ready && snap.capabilities.platen != null,
                    shape = RoundedCornerShape(50),
                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 10.dp),
                    colors = ButtonDefaults.filledTonalButtonColors(
                        containerColor = MaterialTheme.colorScheme.surfaceContainerHighest,
                        contentColor = MaterialTheme.colorScheme.onSurface
                    )
                ) {
                    MaterialSymbol(
                        iconRes = R.drawable.ms_visibility,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(Modifier.width(6.dp))
                    Text("Preview", style = MaterialTheme.typography.labelLarge)
                }

                Spacer(Modifier.width(4.dp))

                IconButton(
                    onClick = onTriggerExport,
                    enabled = state.isConnected && snap.hasScanImage
                ) {
                    MaterialSymbol(
                        iconRes = R.drawable.ms_download,
                        contentDescription = "Export scan",
                        tint = if (state.isConnected && snap.hasScanImage) {
                            MaterialTheme.colorScheme.primary
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.38f)
                        },
                        modifier = Modifier.size(22.dp)
                    )
                }

                IconButton(onClick = onOpenControls) {
                    MaterialSymbol(
                        iconRes = R.drawable.ms_tune,
                        contentDescription = "Scan controls",
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(22.dp)
                    )
                }
            }

            if (ready) {
                ExtendedFloatingActionButton(
                    onClick = onTriggerScan,
                    containerColor = MaterialTheme.colorScheme.primary,
                    contentColor = MaterialTheme.colorScheme.onPrimary,
                    shape = RoundedCornerShape(20.dp),
                    icon = {
                        MaterialSymbol(
                            iconRes = R.drawable.ms_scanner,
                            contentDescription = null,
                            modifier = Modifier.size(22.dp)
                        )
                    },
                    text = {
                        Text(
                            text = "Scan",
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.Bold
                        )
                    }
                )
            } else {
                FilledTonalButton(
                    onClick = {},
                    enabled = false,
                    shape = RoundedCornerShape(20.dp),
                    contentPadding = PaddingValues(horizontal = 20.dp, vertical = 16.dp),
                    modifier = Modifier.height(56.dp)
                ) {
                    MaterialSymbol(
                        iconRes = R.drawable.ms_scanner,
                        contentDescription = null,
                        modifier = Modifier.size(22.dp)
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(
                        text = "Scan",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun ExpressiveActiveScanCard(
    state: RemoteUiState,
    onCancelOperation: () -> Unit,
    onOpenControls: () -> Unit
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
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = info.title,
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text(
                        text = info.statusDetail,
                        style = MaterialTheme.typography.labelMedium.copy(
                            fontFamily = GoogleSansFlexFamily,
                            fontWeight = FontWeight.Medium,
                            fontFeatureSettings = "tnum"
                        ),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }

                FilledTonalIconButton(
                    onClick = onOpenControls,
                    colors = IconButtonDefaults.filledTonalIconButtonColors(
                        containerColor = MaterialTheme.colorScheme.surfaceContainerHighest,
                        contentColor = MaterialTheme.colorScheme.primary
                    ),
                    modifier = Modifier.size(38.dp)
                ) {
                    MaterialSymbol(
                        iconRes = R.drawable.ms_tune,
                        contentDescription = "Scan controls",
                        modifier = Modifier.size(18.dp)
                    )
                }

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

            // Official Material 3 Expressive Wavy Progress Indicator
            val fraction = info.progressFraction
            if (fraction != null) {
                LinearWavyProgressIndicator(
                    progress = { fraction.toFloat().coerceIn(0f, 1f) },
                    color = MaterialTheme.colorScheme.secondary,
                    trackColor = MaterialTheme.colorScheme.surfaceContainerHighest,
                    modifier = Modifier.fillMaxWidth()
                )
            } else {
                LinearWavyProgressIndicator(
                    color = MaterialTheme.colorScheme.secondary,
                    trackColor = MaterialTheme.colorScheme.surfaceContainerHighest,
                    modifier = Modifier.fillMaxWidth()
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                if (info.metadataSummary.isNotBlank()) {
                    Text(
                        text = info.metadataSummary,
                        style = MaterialTheme.typography.labelSmall.copy(
                            fontFamily = GoogleSansFlexFamily,
                            fontFeatureSettings = "tnum"
                        ),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f)
                    )
                } else {
                    Spacer(Modifier.weight(1f))
                }
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
        }
    }
}
