package com.chromascan.companion

import android.Manifest
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.chromascan.companion.store.AuthPhase
import com.chromascan.companion.store.RemoteSessionStore
import com.chromascan.companion.ui.PairingScreen
import com.chromascan.companion.ui.RemoteWorkspaceScreen
import com.chromascan.companion.ui.theme.ChromaScanTheme

class MainActivity : ComponentActivity() {
    private lateinit var store: RemoteSessionStore

    private val notificationPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { _ -> }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
        )
        window.colorMode = ActivityInfo.COLOR_MODE_WIDE_COLOR_GAMUT

        store = RemoteSessionStore.getInstance(applicationContext)
        requestNotificationsPermissionIfNeeded()
        handleLaunchIntent(intent)

        setContent {
            ChromaScanTheme {
                ChromaScanCompanionApp(store = store)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleLaunchIntent(intent)
    }

    override fun onStart() {
        super.onStart()
        store.onAppForegrounded()
    }

    override fun onStop() {
        super.onStop()
        store.onAppBackgrounded()
    }

    private fun handleLaunchIntent(intent: Intent?) {
        if (intent == null) return
        val host = intent.getStringExtra(EXTRA_CONNECT_HOST)?.trim()
        val port = intent.getIntExtra(EXTRA_CONNECT_PORT, 0)
        val pin = intent.getStringExtra(EXTRA_CONNECT_PIN)?.trim()?.takeIf { it.isNotEmpty() }
        if (!host.isNullOrEmpty() && port in 1..65535) {
            store.connectManual(host = host, port = port, pin = pin)
        }
    }

    private fun requestNotificationsPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) {
                notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
    }

    companion object {
        const val EXTRA_CONNECT_HOST = "connect_host"
        const val EXTRA_CONNECT_PORT = "connect_port"
        const val EXTRA_CONNECT_PIN = "connect_pin"
    }
}

@Composable
private fun ChromaScanCompanionApp(store: RemoteSessionStore) {
    val state by store.uiState.collectAsStateWithLifecycle()
    val hosts by store.browser.hosts.collectAsStateWithLifecycle()
    val browseError by store.browser.browseError.collectAsStateWithLifecycle()

    when (val phase = state.phase) {
        is AuthPhase.Connected -> {
            RemoteWorkspaceScreen(
                state = state,
                hostName = phase.hostName,
                onSelectScanner = store::selectScanner,
                onRefreshScanners = store::refreshScanners,
                onAddManualScanner = store::addManualScanner,
                onUpdateSettings = store::updateSettings,
                onCropChanged = store::setCropRect,
                onResetCrop = store::resetCrop,
                onTrimEmptySpace = store::trimEmptySpace,
                onSetViewMode = store::setViewMode,
                onTriggerPreview = store::triggerPreview,
                onTriggerScan = store::triggerScan,
                onTriggerExport = store::triggerExport,
                onCancelOperation = store::cancelActiveOperation,
                onRequestTile = store::requestHighResTile,
                onClearTile = store::clearHighResTile,
                onToggleNotify = store::setNotifyOnScanComplete,
                onSaveCopyToPhotos = store::saveCopyToPhotos,
                onDisconnect = store::disconnect,
                onDismissError = store::dismissErrorAlert
            )
        }

        else -> {
            PairingScreen(
                phase = phase,
                hosts = hosts,
                browseError = browseError,
                initialManualHost = store.tokenStore.lastManualHost,
                initialManualPort = store.tokenStore.lastManualPort,
                onRefreshHosts = { store.browser.start() },
                onConnectHost = store::connect,
                onConnectManual = { host, port -> store.connectManual(host, port) },
                onSubmitPin = store::submitPIN,
                onCancelConnection = store::disconnect
            )
        }
    }
}
