package com.chromascan.companion.network

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import com.chromascan.companion.model.CompanionConstants
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.net.Inet4Address
import java.net.InetAddress
import java.util.ArrayDeque
import java.util.concurrent.Executors

data class DiscoveredHost(
    val id: String,
    val name: String,
    val hostAddress: String,
    val port: Int,
    val hostID: String?,
    val scannerName: String?,
    val protocolVersion: Int
)

/**
 * Discovers ChromaScan Mac hosts over mDNS/Bonjour (`_chromascan._tcp.`).
 * Acquires a Wi-Fi multicast lock while browsing and serializes `NsdManager.resolveService`
 * calls on API < 34 to avoid `FAILURE_ALREADY_ACTIVE`.
 */
class HostBrowser(context: Context) {
    private val appContext = context.applicationContext
    private val nsdManager = appContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifiManager = appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private val callbackExecutor = Executors.newSingleThreadExecutor()

    private val _hosts = MutableStateFlow<List<DiscoveredHost>>(emptyList())
    val hosts: StateFlow<List<DiscoveredHost>> = _hosts.asStateFlow()

    private val _isSearching = MutableStateFlow(false)
    val isSearching: StateFlow<Boolean> = _isSearching.asStateFlow()

    private val _browseError = MutableStateFlow<String?>(null)
    val browseError: StateFlow<String?> = _browseError.asStateFlow()

    private val lock = Any()
    private val resolvedByServiceName = LinkedHashMap<String, DiscoveredHost>()
    private val pendingResolveQueue = ArrayDeque<NsdServiceInfo>()
    private var isResolving = false
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private val activeInfoCallbacks = mutableMapOf<String, NsdManager.ServiceInfoCallback>()

    fun start() {
        stop()
        _browseError.value = null
        _isSearching.value = true

        try {
            multicastLock = wifiManager?.createMulticastLock("ChromaScanNsdLock")?.apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not acquire multicast lock: ${e.message}")
        }

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) {
                Log.i(TAG, "mDNS discovery started for $regType")
                _isSearching.value = true
                _browseError.value = null
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "Found service: ${serviceInfo.serviceName} (${serviceInfo.serviceType})")
                resolveServiceInfo(serviceInfo)
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "Lost service: ${serviceInfo.serviceName}")
                synchronized(lock) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        activeInfoCallbacks.remove(serviceInfo.serviceName)?.let { cb ->
                            runCatching { nsdManager.unregisterServiceInfoCallback(cb) }
                        }
                    }
                    resolvedByServiceName.remove(serviceInfo.serviceName)
                    publishHostsLocked()
                }
            }

            override fun onDiscoveryStopped(serviceType: String) {
                Log.i(TAG, "mDNS discovery stopped for $serviceType")
                _isSearching.value = false
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "Start discovery failed: $errorCode")
                _isSearching.value = false
                _browseError.value = "Discovery failed (code $errorCode)"
                runCatching { nsdManager.stopServiceDiscovery(this) }
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "Stop discovery failed: $errorCode")
            }
        }

        discoveryListener = listener
        try {
            nsdManager.discoverServices(
                CompanionConstants.BONJOUR_SERVICE_TYPE,
                NsdManager.PROTOCOL_DNS_SD,
                listener
            )
        } catch (e: Exception) {
            Log.e(TAG, "discoverServices threw", e)
            _isSearching.value = false
            _browseError.value = e.localizedMessage ?: "Unable to start mDNS discovery"
        }
    }

    fun stop() {
        discoveryListener?.let { listener ->
            runCatching { nsdManager.stopServiceDiscovery(listener) }
        }
        discoveryListener = null

        synchronized(lock) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                for (cb in activeInfoCallbacks.values) {
                    runCatching { nsdManager.unregisterServiceInfoCallback(cb) }
                }
                activeInfoCallbacks.clear()
            }
            pendingResolveQueue.clear()
            isResolving = false
        }

        multicastLock?.let { lock ->
            runCatching { if (lock.isHeld) lock.release() }
        }
        multicastLock = null
        _isSearching.value = false
    }

    private fun resolveServiceInfo(serviceInfo: NsdServiceInfo) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            synchronized(lock) {
                if (activeInfoCallbacks.containsKey(serviceInfo.serviceName)) return
                val cb = object : NsdManager.ServiceInfoCallback {
                    override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
                        Log.w(TAG, "ServiceInfoCallback registration failed: $errorCode")
                    }

                    override fun onServiceUpdated(updated: NsdServiceInfo) {
                        recordResolved(updated)
                    }

                    override fun onServiceLost() {
                        synchronized(lock) {
                            resolvedByServiceName.remove(serviceInfo.serviceName)
                            publishHostsLocked()
                        }
                    }

                    override fun onServiceInfoCallbackUnregistered() = Unit
                }
                activeInfoCallbacks[serviceInfo.serviceName] = cb
                runCatching {
                    nsdManager.registerServiceInfoCallback(serviceInfo, callbackExecutor, cb)
                }.onFailure {
                    activeInfoCallbacks.remove(serviceInfo.serviceName)
                    Log.w(TAG, "registerServiceInfoCallback failed: ${it.message}")
                }
            }
        } else {
            synchronized(lock) {
                pendingResolveQueue.addLast(serviceInfo)
                drainResolveQueueLocked()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun drainResolveQueueLocked() {
        if (isResolving) return
        val next = pendingResolveQueue.pollFirst() ?: return
        isResolving = true

        nsdManager.resolveService(next, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "Resolve failed for ${serviceInfo.serviceName}: code $errorCode")
                synchronized(lock) {
                    isResolving = false
                    drainResolveQueueLocked()
                }
            }

            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                recordResolved(serviceInfo)
                synchronized(lock) {
                    isResolving = false
                    drainResolveQueueLocked()
                }
            }
        })
    }

    private fun recordResolved(serviceInfo: NsdServiceInfo) {
        val address = pickBestAddress(serviceInfo) ?: return
        val port = serviceInfo.port
        if (port <= 0) return

        val attrs = parseAttributes(serviceInfo)
        val hostID = attrs["id"]
        val scanner = attrs["scanner"]
        val version = attrs["v"]?.toIntOrNull() ?: 1
        val stableId = hostID ?: "${serviceInfo.serviceType}|${serviceInfo.serviceName}"

        val host = DiscoveredHost(
            id = stableId,
            name = serviceInfo.serviceName,
            hostAddress = address,
            port = port,
            hostID = hostID,
            scannerName = scanner,
            protocolVersion = version
        )

        Log.i(TAG, "Resolved host: ${host.name} -> ${host.hostAddress}:${host.port} (scanner=${host.scannerName})")
        synchronized(lock) {
            resolvedByServiceName[serviceInfo.serviceName] = host
            publishHostsLocked()
        }
    }

    @Suppress("DEPRECATION")
    private fun pickBestAddress(info: NsdServiceInfo): String? {
        val candidates: List<InetAddress> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            info.hostAddresses
        } else {
            listOfNotNull(info.host)
        }
        val best = candidates.firstOrNull { it is Inet4Address && !it.isLoopbackAddress }
            ?: candidates.firstOrNull { !it.isLinkLocalAddress && !it.isLoopbackAddress }
            ?: candidates.firstOrNull()
        return best?.hostAddress?.substringBefore('%')
    }

    private fun parseAttributes(info: NsdServiceInfo): Map<String, String> {
        val out = mutableMapOf<String, String>()
        val rawAttrs = info.attributes ?: return out
        for ((k, v) in rawAttrs) {
            if (v != null) {
                out[k.lowercase()] = v.toString(Charsets.UTF_8)
            }
        }
        return out
    }

    private fun publishHostsLocked() {
        val deduped = LinkedHashMap<String, DiscoveredHost>()
        for (host in resolvedByServiceName.values) {
            deduped[host.id] = host
        }
        _hosts.value = deduped.values.sortedBy { it.name.lowercase() }
    }

    companion object {
        private const val TAG = "ChromaHostBrowser"
    }
}
