package com.chromascan.companion.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ContainedLoadingIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.LargeFlexibleTopAppBar
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.toShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.chromascan.companion.R
import com.chromascan.companion.network.CompanionTarget
import com.chromascan.companion.network.DiscoveredHost
import com.chromascan.companion.store.AuthPhase
import com.chromascan.companion.ui.theme.ChromaPalette
import com.chromascan.companion.ui.theme.GoogleSansFlexFamily
import com.chromascan.companion.ui.theme.MaterialSymbol

@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun PairingScreen(
    phase: AuthPhase,
    hosts: List<DiscoveredHost>,
    browseError: String?,
    initialManualHost: String,
    initialManualPort: String,
    onRefreshHosts: () -> Unit,
    onConnectHost: (DiscoveredHost) -> Unit,
    onConnectManual: (String, Int) -> Unit,
    onSubmitPin: (String) -> Unit,
    onCancelConnection: () -> Unit
) {
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    var manualHost by rememberSaveable { mutableStateOf(initialManualHost) }
    var manualPort by rememberSaveable { mutableStateOf(initialManualPort) }
    var showManualSection by rememberSaveable { mutableStateOf(false) }
    var pinInput by rememberSaveable { mutableStateOf("") }

    LaunchedEffect(phase) {
        if (phase is AuthPhase.NeedsPin && !phase.reason.isNullOrBlank()) {
            pinInput = ""
        }
    }

    Scaffold(
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            LargeFlexibleTopAppBar(
                title = {
                    Text(
                        text = "ChromaScan",
                        fontWeight = FontWeight.Bold
                    )
                },
                subtitle = {
                    Text(
                        text = "Connect to your Mac scanning host",
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                },
                actions = {
                    FilledTonalIconButton(
                        onClick = onRefreshHosts,
                        colors = IconButtonDefaults.filledTonalIconButtonColors(
                            containerColor = MaterialTheme.colorScheme.surfaceContainerHighest,
                            contentColor = MaterialTheme.colorScheme.primary
                        )
                    ) {
                        MaterialSymbol(
                            iconRes = R.drawable.ms_refresh,
                            contentDescription = "Refresh Macs",
                            modifier = Modifier.size(22.dp)
                        )
                    }
                    Spacer(Modifier.width(8.dp))
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background,
                    scrolledContainerColor = MaterialTheme.colorScheme.surfaceContainer
                ),
                scrollBehavior = scrollBehavior
            )
        }
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .consumeWindowInsets(innerPadding)
                .imePadding(),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            if (phase is AuthPhase.NeedsPin) {
                item(key = "pin_section") {
                    ExpressivePinCard(
                        hostName = phase.hostName,
                        reason = phase.reason,
                        pinInput = pinInput,
                        onPinChanged = { newVal ->
                            val filtered = newVal.filter { it.isDigit() }.take(6)
                            pinInput = filtered
                            if (filtered.length == 6) {
                                onSubmitPin(filtered)
                            }
                        },
                        onPair = { onSubmitPin(pinInput) },
                        onCancel = {
                            pinInput = ""
                            onCancelConnection()
                        }
                    )
                }
            }

            if (phase is AuthPhase.Connecting) {
                item(key = "connecting_section") {
                    Surface(
                        shape = RoundedCornerShape(28.dp),
                        color = MaterialTheme.colorScheme.surfaceContainerHigh
                    ) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 18.dp, vertical = 16.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(14.dp)
                        ) {
                            ContainedLoadingIndicator(
                                modifier = Modifier.size(44.dp),
                                containerColor = MaterialTheme.colorScheme.primaryContainer,
                                indicatorColor = MaterialTheme.colorScheme.primary
                            )
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = "Connecting to ${phase.hostName}",
                                    style = MaterialTheme.typography.titleMedium,
                                    color = MaterialTheme.colorScheme.onSurface
                                )
                                Text(
                                    text = "Completing companion handshake…",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            FilledTonalButton(onClick = onCancelConnection) {
                                Text("Cancel")
                            }
                        }
                    }
                }
            }

            item(key = "nearby_header") {
                Text(
                    text = "Nearby Macs",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(start = 8.dp, top = 4.dp)
                )
            }

            if (hosts.isEmpty()) {
                item(key = "searching_empty") {
                    Surface(
                        shape = RoundedCornerShape(28.dp),
                        color = MaterialTheme.colorScheme.surfaceContainerHigh
                    ) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(20.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(16.dp)
                        ) {
                            ContainedLoadingIndicator(
                                modifier = Modifier.size(48.dp),
                                containerColor = MaterialTheme.colorScheme.primaryContainer,
                                indicatorColor = MaterialTheme.colorScheme.primary
                            )
                            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(
                                    text = "Looking for ChromaScan on Wi-Fi…",
                                    style = MaterialTheme.typography.titleSmall,
                                    color = MaterialTheme.colorScheme.onSurface
                                )
                                Text(
                                    text = "Open ChromaScan on your Mac on the same network to appear automatically.",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }
                }
            } else {
                itemsIndexed(hosts, key = { _, host -> host.id }) { index, host ->
                    val shape = expressiveGroupedShape(index, hosts.size)
                    ExpressiveHostCard(
                        host = host,
                        shape = shape,
                        onClick = {
                            pinInput = ""
                            onConnectHost(host)
                        }
                    )
                }
            }

            item(key = "bonjour_caption") {
                Text(
                    text = browseError?.let { "mDNS notice: $it" }
                        ?: "Automatic LAN discovery via Bonjour (_chromascan._tcp).",
                    style = MaterialTheme.typography.bodySmall,
                    color = if (browseError != null) ChromaPalette.Warning else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 8.dp)
                )
            }

            item(key = "manual_section") {
                Spacer(Modifier.height(4.dp))
                Surface(
                    shape = RoundedCornerShape(24.dp),
                    color = MaterialTheme.colorScheme.surfaceContainerHigh
                ) {
                    Column(modifier = Modifier.fillMaxWidth()) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(24.dp))
                                .clickable { showManualSection = !showManualSection }
                                .padding(horizontal = 18.dp, vertical = 16.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(14.dp)
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(40.dp)
                                    .background(
                                        MaterialTheme.colorScheme.surfaceContainerHighest,
                                        MaterialShapes.SoftBurst.toShape()
                                    ),
                                contentAlignment = Alignment.Center
                            ) {
                                MaterialSymbol(
                                    iconRes = R.drawable.ms_wifi,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier.size(20.dp)
                                )
                            }
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = "Connect manually",
                                    style = MaterialTheme.typography.titleSmall,
                                    color = MaterialTheme.colorScheme.onSurface
                                )
                                Text(
                                    text = "Direct IP address or Tailscale",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            MaterialSymbol(
                                iconRes = if (showManualSection) R.drawable.ms_expand_less else R.drawable.ms_expand_more,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(22.dp)
                            )
                        }

                        AnimatedVisibility(
                            visible = showManualSection,
                            enter = expandVertically() + fadeIn(),
                            exit = shrinkVertically() + fadeOut()
                        ) {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(start = 18.dp, end = 18.dp, bottom = 18.dp),
                                verticalArrangement = Arrangement.spacedBy(12.dp)
                            ) {
                                OutlinedTextField(
                                    value = manualHost,
                                    onValueChange = { manualHost = it },
                                    label = { Text("Host or IP (e.g. 192.168.4.45)") },
                                    singleLine = true,
                                    shape = RoundedCornerShape(16.dp),
                                    modifier = Modifier.fillMaxWidth()
                                )
                                OutlinedTextField(
                                    value = manualPort,
                                    onValueChange = { manualPort = it.filter { ch -> ch.isDigit() }.take(5) },
                                    label = { Text("Port") },
                                    singleLine = true,
                                    shape = RoundedCornerShape(16.dp),
                                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                    modifier = Modifier.fillMaxWidth()
                                )
                                val parsedPort = manualPort.trim().toIntOrNull()
                                val canConnect = parsedPort != null &&
                                    CompanionTarget.buildWsUrl(manualHost.trim(), parsedPort) != null
                                Button(
                                    onClick = {
                                        if (parsedPort != null) {
                                            pinInput = ""
                                            onConnectManual(manualHost.trim(), parsedPort)
                                        }
                                    },
                                    enabled = canConnect,
                                    shape = RoundedCornerShape(50),
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .height(50.dp)
                                ) {
                                    Text("Connect to host")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun ExpressiveHostCard(
    host: DiscoveredHost,
    shape: RoundedCornerShape,
    onClick: () -> Unit
) {
    Surface(
        shape = shape,
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .clickable(onClick = onClick)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 18.dp, vertical = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(48.dp)
                    .background(
                        MaterialTheme.colorScheme.primaryContainer,
                        MaterialShapes.Cookie9Sided.toShape()
                    ),
                contentAlignment = Alignment.Center
            ) {
                MaterialSymbol(
                    iconRes = R.drawable.ms_desktop_mac,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onPrimaryContainer,
                    modifier = Modifier.size(22.dp)
                )
            }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    text = host.name,
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                if (!host.scannerName.isNullOrBlank()) {
                    Surface(
                        shape = RoundedCornerShape(50),
                        color = MaterialTheme.colorScheme.surfaceContainerHighest
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            MaterialSymbol(
                                iconRes = R.drawable.ms_scanner,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(13.dp)
                            )
                            Text(
                                text = host.scannerName,
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                } else {
                    Text(
                        text = "${host.hostAddress}:${host.port}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
            MaterialSymbol(
                iconRes = R.drawable.ms_chevron_right,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(22.dp)
            )
        }
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun ExpressivePinCard(
    hostName: String,
    reason: String?,
    pinInput: String,
    onPinChanged: (String) -> Unit,
    onPair: () -> Unit,
    onCancel: () -> Unit
) {
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(Unit) {
        runCatching { focusRequester.requestFocus() }
    }

    Surface(
        shape = RoundedCornerShape(28.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHighest
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size(46.dp)
                        .background(
                            MaterialTheme.colorScheme.secondaryContainer,
                            MaterialShapes.Clover4Leaf.toShape()
                        ),
                    contentAlignment = Alignment.Center
                ) {
                    MaterialSymbol(
                        iconRes = R.drawable.ms_lock,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSecondaryContainer,
                        modifier = Modifier.size(22.dp)
                    )
                }
                Column {
                    Text(
                        text = "Pair with $hostName",
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                    Text(
                        text = "Enter the 6-digit PIN shown in ChromaScan on your Mac.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            if (!reason.isNullOrBlank()) {
                Surface(
                    shape = RoundedCornerShape(14.dp),
                    color = MaterialTheme.colorScheme.errorContainer
                ) {
                    Text(
                        text = reason,
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onErrorContainer,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)
                    )
                }
            }

            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                OutlinedTextField(
                    value = pinInput,
                    onValueChange = onPinChanged,
                    placeholder = { Text("6-digit PIN") },
                    singleLine = true,
                    shape = RoundedCornerShape(16.dp),
                    textStyle = MaterialTheme.typography.titleLarge.copy(
                        fontFamily = GoogleSansFlexFamily,
                        fontWeight = FontWeight.Bold,
                        fontFeatureSettings = "tnum",
                        letterSpacing = 4.sp
                    ),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                    modifier = Modifier
                        .weight(1f)
                        .focusRequester(focusRequester)
                )
                val canSubmit = pinInput.count { it.isDigit() } == 6
                Button(
                    onClick = onPair,
                    enabled = canSubmit,
                    shape = RoundedCornerShape(50),
                    contentPadding = PaddingValues(horizontal = 22.dp),
                    modifier = Modifier.height(56.dp)
                ) {
                    Text("Pair", style = MaterialTheme.typography.labelLarge)
                }
            }

            TextButton(
                onClick = onCancel,
                contentPadding = PaddingValues(horizontal = 6.dp, vertical = 0.dp)
            ) {
                Text("Cancel pairing", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

private fun expressiveGroupedShape(index: Int, count: Int): RoundedCornerShape {
    if (count <= 1) return RoundedCornerShape(24.dp)
    return when (index) {
        0 -> RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp, bottomStart = 8.dp, bottomEnd = 8.dp)
        count - 1 -> RoundedCornerShape(topStart = 8.dp, topEnd = 8.dp, bottomStart = 24.dp, bottomEnd = 24.dp)
        else -> RoundedCornerShape(8.dp)
    }
}
