package com.chromascan.companion.ui

import androidx.annotation.DrawableRes
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ButtonGroupDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.ToggleButton
import androidx.compose.material3.ToggleButtonDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import com.chromascan.companion.R
import com.chromascan.companion.model.ColorProfileMode
import com.chromascan.companion.model.OutputFormat
import com.chromascan.companion.model.ScanColorMode
import com.chromascan.companion.model.ScanInputSource
import com.chromascan.companion.model.ScanIntent
import com.chromascan.companion.model.ScanRotation
import com.chromascan.companion.model.ScanSettingsPatch
import com.chromascan.companion.model.ScannerTransport
import com.chromascan.companion.model.SessionSnapshot
import com.chromascan.companion.model.TransferFormat
import com.chromascan.companion.store.RemoteUiState
import com.chromascan.companion.ui.theme.GoogleSansFlexFamily
import com.chromascan.companion.ui.theme.MaterialSymbol
import java.util.Locale
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun RemoteControlsSheet(
    state: RemoteUiState,
    onDismiss: () -> Unit,
    onSelectScanner: (String) -> Unit,
    onRefreshScanners: () -> Unit,
    onAddManualScanner: (String, Int, Boolean) -> Unit,
    onUpdateSettings: (ScanSettingsPatch) -> Unit,
    onToggleNotify: (Boolean) -> Unit,
    onSaveCopyToPhotos: () -> Unit,
    onDisconnect: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    var showManualScannerDialog by remember { mutableStateOf(false) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
        containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
        contentColor = MaterialTheme.colorScheme.onSurface,
        dragHandle = { BottomSheetDefaults.DragHandle() }
    ) {
        val snap = state.snapshot
        if (snap == null) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(32.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Text("Not connected to Mac host", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else {
            Column(modifier = Modifier.fillMaxWidth()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp, vertical = 2.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = "Scan controls",
                        style = MaterialTheme.typography.headlineSmall,
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.weight(1f)
                    )
                    FilledTonalButton(
                        onClick = onDismiss,
                        shape = RoundedCornerShape(50),
                        contentPadding = PaddingValues(horizontal = 18.dp, vertical = 8.dp)
                    ) {
                        Text("Done")
                    }
                }

                LazyColumn(
                    modifier = Modifier
                        .fillMaxWidth()
                        .navigationBarsPadding(),
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 14.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp)
                ) {
                    item(key = "scanner_section") {
                        ScannerSection(
                            snap = snap,
                            onSelectScanner = onSelectScanner,
                            onRefreshScanners = onRefreshScanners,
                            onOpenAddManual = { showManualScannerDialog = true }
                        )
                    }

                    item(key = "capture_section") {
                        CaptureSection(snap = snap, onUpdateSettings = onUpdateSettings)
                    }

                    if (snap.capabilities?.brightnessRange != null || snap.capabilities?.contrastRange != null) {
                        item(key = "hw_tone_section") {
                            HardwareToneSection(snap = snap, onUpdateSettings = onUpdateSettings)
                        }
                    }

                    item(key = "color_output_section") {
                        ColorAndOutputSection(snap = snap, onUpdateSettings = onUpdateSettings)
                    }

                    item(key = "sw_tone_section") {
                        SoftwareToneSection(snap = snap, onUpdateSettings = onUpdateSettings)
                    }

                    item(key = "companion_section") {
                        CompanionActionsSection(
                            state = state,
                            snap = snap,
                            onToggleNotify = onToggleNotify,
                            onSaveCopyToPhotos = onSaveCopyToPhotos,
                            onDisconnect = {
                                onDismiss()
                                onDisconnect()
                            }
                        )
                    }

                    item { Spacer(Modifier.height(16.dp)) }
                }
            }
        }
    }

    if (showManualScannerDialog) {
        ManualScannerDialog(
            onDismiss = { showManualScannerDialog = false },
            onAdd = { host, port, useTLS ->
                onAddManualScanner(host, port, useTLS)
                showManualScannerDialog = false
            }
        )
    }
}

@Composable
private fun ExpressiveSectionCard(
    title: String,
    @DrawableRes iconRes: Int,
    footer: String? = null,
    content: @Composable () -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.padding(horizontal = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            MaterialSymbol(
                iconRes = iconRes,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(18.dp)
            )
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.primary
            )
        }
        Surface(
            shape = RoundedCornerShape(24.dp),
            color = MaterialTheme.colorScheme.surfaceContainerHigh
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                content()
            }
        }
        if (!footer.isNullOrBlank()) {
            Text(
                text = footer,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 8.dp)
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun <T> ExposedDropdownField(
    label: String,
    selectedLabel: String,
    options: List<Pair<T, String>>,
    enabled: Boolean = true,
    onSelected: (T) -> Unit
) {
    var expanded by remember { mutableStateOf(false) }

    ExposedDropdownMenuBox(
        expanded = expanded && enabled,
        onExpandedChange = { if (enabled) expanded = it }
    ) {
        OutlinedTextField(
            value = selectedLabel,
            onValueChange = {},
            readOnly = true,
            enabled = enabled,
            label = { Text(label) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded && enabled) },
            shape = RoundedCornerShape(16.dp),
            modifier = Modifier
                .menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable, enabled)
                .fillMaxWidth()
        )
        DropdownMenu(
            expanded = expanded && enabled,
            onDismissRequest = { expanded = false },
            modifier = Modifier.exposedDropdownSize()
        ) {
            options.forEach { (value, display) ->
                DropdownMenuItem(
                    text = { Text(display) },
                    onClick = {
                        expanded = false
                        onSelected(value)
                    }
                )
            }
        }
    }
}

@Composable
private fun ExpressiveToggleRow(
    label: String,
    subtitle: String? = null,
    checked: Boolean,
    enabled: Boolean = true,
    onCheckedChange: (Boolean) -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = label,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
                color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant
            )
            if (!subtitle.isNullOrBlank()) {
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            enabled = enabled,
            colors = SwitchDefaults.colors(
                checkedThumbColor = MaterialTheme.colorScheme.onSecondary,
                checkedTrackColor = MaterialTheme.colorScheme.secondary
            )
        )
    }
}

@Composable
private fun ExpressiveSliderRow(
    label: String,
    valueText: (Float) -> String,
    value: Float,
    range: ClosedFloatingPointRange<Float>,
    step: Float = 0f,
    enabled: Boolean = true,
    onValueCommit: (Float) -> Unit
) {
    val scope = rememberCoroutineScope()
    var localValue by remember { mutableFloatStateOf(value) }
    var isDragging by remember { mutableStateOf(false) }
    var throttleJob by remember { mutableStateOf<Job?>(null) }

    LaunchedEffect(value) {
        if (!isDragging) {
            localValue = value
        }
    }

    fun snap(raw: Float): Float {
        val clamped = raw.coerceIn(range.start, range.endInclusive)
        if (step <= 0f) return clamped
        val offset = ((clamped - range.start) / step).roundToInt() * step
        return (range.start + offset).coerceIn(range.start, range.endInclusive)
    }

    val displayed = localValue.coerceIn(range.start, range.endInclusive)

    Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = label,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
                color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f)
            )
            Surface(
                shape = RoundedCornerShape(50),
                color = MaterialTheme.colorScheme.surfaceContainerHighest
            ) {
                Text(
                    text = valueText(displayed),
                    style = MaterialTheme.typography.labelMedium.copy(
                        fontFamily = GoogleSansFlexFamily,
                        fontFeatureSettings = "tnum"
                    ),
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 3.dp)
                )
            }
        }
        Slider(
            value = displayed,
            onValueChange = { raw ->
                isDragging = true
                val snapped = snap(raw)
                localValue = snapped
                if (throttleJob == null) {
                    throttleJob = scope.launch {
                        delay(120)
                        throttleJob = null
                        onValueCommit(localValue)
                    }
                }
            },
            onValueChangeFinished = {
                throttleJob?.cancel()
                throttleJob = null
                isDragging = false
                onValueCommit(localValue)
            },
            valueRange = range,
            enabled = enabled,
            colors = SliderDefaults.colors(
                thumbColor = MaterialTheme.colorScheme.primary,
                activeTrackColor = MaterialTheme.colorScheme.secondary,
                inactiveTrackColor = MaterialTheme.colorScheme.surfaceContainerHighest
            )
        )
    }
}

@Composable
private fun ScannerSection(
    snap: SessionSnapshot,
    onSelectScanner: (String) -> Unit,
    onRefreshScanners: () -> Unit,
    onOpenAddManual: () -> Unit
) {
    ExpressiveSectionCard(title = "Scanner", iconRes = R.drawable.ms_scanner) {
        if (snap.scanners.isEmpty()) {
            Text(
                text = "No scanners found on Mac",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        } else {
            val selected = snap.selectedScanner
            val transportIcon = when (selected?.transport) {
                ScannerTransport.USB -> R.drawable.ms_usb
                else -> R.drawable.ms_wifi
            }
            ExposedDropdownField(
                label = "Active scanner",
                selectedLabel = selected?.displayTitle ?: "Select scanner",
                options = snap.scanners.map { it.id to it.displayTitle },
                enabled = !snap.isBusy,
                onSelected = onSelectScanner
            )
            if (selected != null) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    MaterialSymbol(
                        iconRes = transportIcon,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(16.dp)
                    )
                    Text(
                        text = when (selected.transport) {
                            ScannerTransport.USB -> "Connected via Direct USB"
                            ScannerTransport.MANUAL -> "Manual IP (${selected.host}:${selected.port})"
                            ScannerTransport.WIFI -> "Connected via Wi-Fi"
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }

        snap.scannerStatus?.let { status ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "Scanner state",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f)
                )
                Surface(
                    shape = RoundedCornerShape(50),
                    color = MaterialTheme.colorScheme.surfaceContainerHighest
                ) {
                    Text(
                        text = status.state,
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp)
                    )
                }
            }
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            FilledTonalButton(
                onClick = onRefreshScanners,
                enabled = !snap.isBusy,
                shape = RoundedCornerShape(50),
                modifier = Modifier.weight(1f)
            ) {
                MaterialSymbol(R.drawable.ms_refresh, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("Refresh")
            }
            OutlinedButton(
                onClick = onOpenAddManual,
                enabled = !snap.isBusy,
                shape = RoundedCornerShape(50),
                modifier = Modifier.weight(1f)
            ) {
                MaterialSymbol(R.drawable.ms_add, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("Add IP")
            }
        }
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun CaptureSection(
    snap: SessionSnapshot,
    onUpdateSettings: (ScanSettingsPatch) -> Unit
) {
    val caps = snap.capabilities
    val inputCaps = caps?.caps(snap.settings.inputSource) ?: caps?.platen
    val resolutions = inputCaps?.discreteResolutions?.takeIf { it.isNotEmpty() }
        ?: listOf(75, 150, 300, 600, 1200)
    val availableSources = buildList {
        if (caps == null || caps.platen != null) add(ScanInputSource.PLATEN)
        if (caps?.adf != null) add(ScanInputSource.FEEDER)
    }.ifEmpty { listOf(ScanInputSource.PLATEN) }
    val availableColorModes = ScanColorMode.entries.filter {
        val list = inputCaps?.colorModes.orEmpty()
        list.isEmpty() || list.contains(it.rawValue)
    }.ifEmpty { listOf(ScanColorMode.RGB24) }
    val availableTransfers = buildList {
        if (inputCaps?.supportsRawOctetStream != false) add(TransferFormat.RAW_OCTET_STREAM)
        if (inputCaps?.supportsJPEG != false) add(TransferFormat.JPEG)
    }.ifEmpty { listOf(TransferFormat.RAW_OCTET_STREAM) }

    ExpressiveSectionCard(title = "Capture", iconRes = R.drawable.ms_tune) {
        // 1-tap Resolution FilterChip strip
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                text = "Resolution",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                resolutions.forEach { dpi ->
                    val selected = snap.settings.resolution == dpi
                    FilterChip(
                        selected = selected,
                        onClick = { onUpdateSettings(ScanSettingsPatch(resolution = dpi)) },
                        enabled = !snap.isBusy,
                        shape = RoundedCornerShape(50),
                        label = {
                            Text(
                                text = "$dpi DPI",
                                style = MaterialTheme.typography.labelLarge.copy(
                                    fontFamily = GoogleSansFlexFamily,
                                    fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                                    fontFeatureSettings = "tnum"
                                )
                            )
                        },
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = MaterialTheme.colorScheme.primary,
                            selectedLabelColor = MaterialTheme.colorScheme.onPrimary
                        )
                    )
                }
            }
        }

        // Expressive connected ToggleButton group for Rotation
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                text = "Rotation",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(ButtonGroupDefaults.ConnectedSpaceBetween)
            ) {
                ScanRotation.entries.forEachIndexed { idx, rot ->
                    val shapes = when (idx) {
                        0 -> ButtonGroupDefaults.connectedLeadingButtonShapes()
                        ScanRotation.entries.lastIndex -> ButtonGroupDefaults.connectedTrailingButtonShapes()
                        else -> ButtonGroupDefaults.connectedMiddleButtonShapes()
                    }
                    ToggleButton(
                        checked = snap.settings.rotation == rot,
                        onCheckedChange = { if (it) onUpdateSettings(ScanSettingsPatch(rotation = rot)) },
                        shapes = shapes,
                        colors = ToggleButtonDefaults.colors(
                            containerColor = MaterialTheme.colorScheme.surfaceContainerHighest,
                            contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                            checkedContainerColor = MaterialTheme.colorScheme.primary,
                            checkedContentColor = MaterialTheme.colorScheme.onPrimary
                        ),
                        modifier = Modifier.weight(1f)
                    ) {
                        Text(rot.displayName, style = MaterialTheme.typography.labelLarge)
                    }
                }
            }
        }

        if (availableSources.size > 1) {
            ExposedDropdownField(
                label = "Source",
                selectedLabel = snap.settings.inputSource.displayName,
                options = availableSources.map { it to it.displayName },
                enabled = !snap.isBusy,
                onSelected = { onUpdateSettings(ScanSettingsPatch(inputSource = it)) }
            )
        }

        ExposedDropdownField(
            label = "Color mode",
            selectedLabel = snap.settings.colorMode.displayName,
            options = availableColorModes.map { it to it.displayName },
            enabled = !snap.isBusy,
            onSelected = { onUpdateSettings(ScanSettingsPatch(colorMode = it)) }
        )

        ExposedDropdownField(
            label = "Transfer",
            selectedLabel = snap.settings.transferFormat.displayName,
            options = availableTransfers.map { it to it.displayName },
            enabled = !snap.isBusy,
            onSelected = { onUpdateSettings(ScanSettingsPatch(transferFormat = it)) }
        )

        ExposedDropdownField(
            label = "Intent",
            selectedLabel = snap.settings.intent.displayName,
            options = ScanIntent.entries.map { it to it.displayName },
            enabled = !snap.isBusy,
            onSelected = { onUpdateSettings(ScanSettingsPatch(intent = it)) }
        )

        ExpressiveToggleRow(
            label = "Auto-trim empty space",
            subtitle = "Detect artwork bounds after scan",
            checked = snap.settings.autoTrimEmptySpace,
            enabled = !snap.isBusy,
            onCheckedChange = { onUpdateSettings(ScanSettingsPatch(autoTrimEmptySpace = it)) }
        )
    }
}

@Composable
private fun HardwareToneSection(
    snap: SessionSnapshot,
    onUpdateSettings: (ScanSettingsPatch) -> Unit
) {
    ExpressiveSectionCard(title = "Scanner tone (hardware)", iconRes = R.drawable.ms_brightness_6) {
        snap.capabilities?.brightnessRange?.let { br ->
            ExpressiveSliderRow(
                label = "Brightness",
                valueText = { "${it.roundToInt()}" },
                value = snap.settings.hardwareBrightness.toFloat(),
                range = br.min.toFloat()..br.max.toFloat(),
                step = br.step.coerceAtLeast(1).toFloat(),
                enabled = !snap.isBusy,
                onValueCommit = { onUpdateSettings(ScanSettingsPatch(hardwareBrightness = it.roundToInt())) }
            )
        }
        snap.capabilities?.contrastRange?.let { cr ->
            ExpressiveSliderRow(
                label = "Contrast",
                valueText = { "${it.roundToInt()}" },
                value = snap.settings.hardwareContrast.toFloat(),
                range = cr.min.toFloat()..cr.max.toFloat(),
                step = cr.step.coerceAtLeast(1).toFloat(),
                enabled = !snap.isBusy,
                onValueCommit = { onUpdateSettings(ScanSettingsPatch(hardwareContrast = it.roundToInt())) }
            )
        }
        TextButton(
            onClick = { onUpdateSettings(ScanSettingsPatch(resetHardwareTone = true)) },
            enabled = !snap.isBusy,
            contentPadding = PaddingValues(horizontal = 4.dp, vertical = 0.dp)
        ) {
            Text("Reset hardware tone")
        }
    }
}

@Composable
private fun ColorAndOutputSection(
    snap: SessionSnapshot,
    onUpdateSettings: (ScanSettingsPatch) -> Unit
) {
    val scope = rememberCoroutineScope()
    val focusManager = LocalFocusManager.current
    var filenameDraft by remember { mutableStateOf(snap.settings.baseFilename) }
    var isEditingFilename by remember { mutableStateOf(false) }
    var filenameDebounceJob by remember { mutableStateOf<Job?>(null) }

    LaunchedEffect(snap.settings.baseFilename) {
        if (!isEditingFilename) {
            filenameDraft = snap.settings.baseFilename
        }
    }

    ExpressiveSectionCard(title = "Color & Mac archive", iconRes = R.drawable.ms_palette) {
        // 1-tap Color Profile chips
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                text = "Color profile",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                ColorProfileMode.entries.forEach { profile ->
                    val selected = snap.settings.colorProfile == profile
                    FilterChip(
                        selected = selected,
                        onClick = { onUpdateSettings(ScanSettingsPatch(colorProfile = profile)) },
                        enabled = snap.settings.colorMode != ScanColorMode.GRAYSCALE8,
                        shape = RoundedCornerShape(50),
                        label = { Text(profile.shortName) },
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = MaterialTheme.colorScheme.primary,
                            selectedLabelColor = MaterialTheme.colorScheme.onPrimary
                        )
                    )
                }
            }
        }

        // 1-tap Format chips
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                text = "Archive format",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                OutputFormat.entries.forEach { fmt ->
                    val selected = snap.settings.outputFormat == fmt
                    FilterChip(
                        selected = selected,
                        onClick = { onUpdateSettings(ScanSettingsPatch(outputFormat = fmt)) },
                        shape = RoundedCornerShape(50),
                        label = { Text(fmt.displayName) },
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = MaterialTheme.colorScheme.primary,
                            selectedLabelColor = MaterialTheme.colorScheme.onPrimary
                        )
                    )
                }
            }
        }

        if (snap.settings.outputFormat.supportsQuality) {
            ExpressiveSliderRow(
                label = "Compression quality",
                valueText = { "${(it * 100f).roundToInt()}%" },
                value = snap.settings.quality.toFloat(),
                range = 0.5f..1.0f,
                onValueCommit = { onUpdateSettings(ScanSettingsPatch(quality = it.toDouble())) }
            )
            ExpressiveToggleRow(
                label = "Preview compression live",
                checked = snap.settings.previewCompressionEnabled,
                onCheckedChange = { onUpdateSettings(ScanSettingsPatch(previewCompressionEnabled = it)) }
            )
        }

        Surface(
            shape = RoundedCornerShape(16.dp),
            color = MaterialTheme.colorScheme.surfaceContainerHighest
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 14.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                MaterialSymbol(
                    iconRes = R.drawable.ms_folder,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(18.dp)
                )
                Text(
                    text = "Mac folder",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f)
                )
                Text(
                    text = snap.saveFolderDisplayName,
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }

        OutlinedTextField(
            value = filenameDraft,
            onValueChange = { updated ->
                filenameDraft = updated
                filenameDebounceJob?.cancel()
                filenameDebounceJob = scope.launch {
                    delay(350)
                    onUpdateSettings(ScanSettingsPatch(baseFilename = updated))
                }
            },
            label = { Text("Filename") },
            singleLine = true,
            enabled = !snap.isBusy,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(
                onDone = {
                    filenameDebounceJob?.cancel()
                    onUpdateSettings(ScanSettingsPatch(baseFilename = filenameDraft))
                    focusManager.clearFocus()
                }
            ),
            shape = RoundedCornerShape(16.dp),
            modifier = Modifier
                .fillMaxWidth()
                .onFocusChanged { focusState ->
                    val wasEditing = isEditingFilename
                    isEditingFilename = focusState.isFocused
                    if (wasEditing && !focusState.isFocused) {
                        filenameDebounceJob?.cancel()
                        onUpdateSettings(ScanSettingsPatch(baseFilename = filenameDraft))
                    }
                }
        )

        ExpressiveToggleRow(
            label = "Auto-increment filename",
            checked = snap.settings.autoIncrement,
            onCheckedChange = { onUpdateSettings(ScanSettingsPatch(autoIncrement = it)) }
        )

        if (snap.outputPreviewSummary.isNotBlank()) {
            Text(
                text = snap.outputPreviewSummary,
                style = MaterialTheme.typography.bodySmall.copy(
                    fontFamily = GoogleSansFlexFamily,
                    fontFeatureSettings = "tnum"
                ),
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun SoftwareToneSection(
    snap: SessionSnapshot,
    onUpdateSettings: (ScanSettingsPatch) -> Unit
) {
    val tone = snap.settings.toneAdjustments
    ExpressiveSectionCard(title = "Tone adjustments (software)", iconRes = R.drawable.ms_contrast) {
        ExpressiveSliderRow(
            label = "Black point",
            valueText = { "${(it * 100f).roundToInt()}%" },
            value = tone.blackPoint.toFloat(),
            range = 0.0f..0.25f,
            onValueCommit = {
                onUpdateSettings(ScanSettingsPatch(toneAdjustments = tone.copy(blackPoint = it.toDouble())))
            }
        )
        ExpressiveSliderRow(
            label = "White point",
            valueText = { "${(it * 100f).roundToInt()}%" },
            value = tone.whitePoint.toFloat(),
            range = 0.75f..1.0f,
            onValueCommit = {
                onUpdateSettings(ScanSettingsPatch(toneAdjustments = tone.copy(whitePoint = it.toDouble())))
            }
        )
        ExpressiveSliderRow(
            label = "Gamma",
            valueText = { String.format(Locale.US, "%.2f", it) },
            value = tone.gamma.toFloat(),
            range = 0.5f..2.0f,
            onValueCommit = {
                onUpdateSettings(ScanSettingsPatch(toneAdjustments = tone.copy(gamma = it.toDouble())))
            }
        )
        TextButton(
            onClick = { onUpdateSettings(ScanSettingsPatch(resetSoftwareTone = true)) },
            enabled = !tone.isIdentity,
            contentPadding = PaddingValues(horizontal = 4.dp, vertical = 0.dp)
        ) {
            Text("Reset tone adjustments")
        }
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun CompanionActionsSection(
    state: RemoteUiState,
    snap: SessionSnapshot,
    onToggleNotify: (Boolean) -> Unit,
    onSaveCopyToPhotos: () -> Unit,
    onDisconnect: () -> Unit
) {
    ExpressiveSectionCard(
        title = "Android companion",
        iconRes = R.drawable.ms_notifications_active,
        footer = if (state.notifyOnScanComplete) {
            "Uses a local foreground notification during long scans so completion alerts arrive even while locked—no cloud push needed."
        } else {
            null
        }
    ) {
        ExpressiveToggleRow(
            label = "Live progress & completion alerts",
            checked = state.notifyOnScanComplete,
            onCheckedChange = onToggleNotify
        )

        FilledTonalButton(
            onClick = onSaveCopyToPhotos,
            enabled = snap.hasScanImage && !state.isSavingToPhotos,
            shape = RoundedCornerShape(50),
            modifier = Modifier
                .fillMaxWidth()
                .height(48.dp)
        ) {
            if (state.isSavingToPhotos) {
                LoadingIndicator(modifier = Modifier.size(20.dp))
            } else {
                MaterialSymbol(R.drawable.ms_photo_library, contentDescription = null, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.width(8.dp))
            Text("Save Display P3 copy to Gallery")
        }

        FilledTonalButton(
            onClick = onDisconnect,
            shape = RoundedCornerShape(50),
            colors = ButtonDefaults.filledTonalButtonColors(
                containerColor = MaterialTheme.colorScheme.errorContainer,
                contentColor = MaterialTheme.colorScheme.onErrorContainer
            ),
            modifier = Modifier
                .fillMaxWidth()
                .height(48.dp)
        ) {
            MaterialSymbol(R.drawable.ms_link_off, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text("Disconnect from Mac")
        }
    }
}

@Composable
private fun ManualScannerDialog(
    onDismiss: () -> Unit,
    onAdd: (String, Int, Boolean) -> Unit
) {
    var host by remember { mutableStateOf("") }
    var portText by remember { mutableStateOf("8080") }
    var useTLS by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
        shape = RoundedCornerShape(28.dp),
        title = { Text("Add eSCL scanner on Mac") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = host,
                    onValueChange = { host = it },
                    label = { Text("Hostname or IP (e.g. 192.168.1.50)") },
                    singleLine = true,
                    shape = RoundedCornerShape(16.dp),
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = portText,
                    onValueChange = { portText = it.filter { ch -> ch.isDigit() }.take(5) },
                    label = { Text("Port") },
                    singleLine = true,
                    shape = RoundedCornerShape(16.dp),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth()
                )
                ExpressiveToggleRow(
                    label = "Use HTTPS (port 443)",
                    checked = useTLS,
                    onCheckedChange = { enabled ->
                        useTLS = enabled
                        if (enabled && portText == "8080") portText = "443"
                        if (!enabled && portText == "443") portText = "8080"
                    }
                )
            }
        },
        confirmButton = {
            val parsedPort = portText.toIntOrNull()
            val validPort = parsedPort != null && parsedPort in 1..65535
            FilledTonalButton(
                onClick = {
                    if (parsedPort != null && parsedPort in 1..65535) {
                        onAdd(host.trim(), parsedPort, useTLS)
                    }
                },
                enabled = host.trim().isNotEmpty() && validPort
            ) {
                Text("Add")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        }
    )
}
