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
 * Acquires a Wi-Fi multicast lock while browsing, isolates each browse session with a
 * monotonic generation token, and serializes `NsdManager.resolveService` on API < 34.
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
    private val pendingResolveQueue = ArrayDeque<Pair<Long, NsdServiceInfo>>()
    private var isResolving = false
    private var browseGeneration: Long = 0L
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private val activeInfoCallbacks = mutableMapOf<String, NsdManager.ServiceInfoCallback>()

    fun start(clearExisting: Boolean = true) {
        stop(clearHosts = clearExisting)
        val gen = synchronized(lock) {
            browseGeneration += 1L
            browseGeneration
        }

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
                if (!isCurrentGeneration(gen)) return
                Log.i(TAG, "mDNS discovery started for $regType (gen=$gen)")
                _isSearching.value = true
                _browseError.value = null
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (!isCurrentGeneration(gen)) return
                Log.d(TAG, "Found service: ${serviceInfo.serviceName} (${serviceInfo.serviceType})")
                resolveServiceInfo(gen, serviceInfo)
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                synchronized(lock) {
                    if (gen != browseGeneration) return
                    Log.d(TAG, "Lost service: ${serviceInfo.serviceName}")
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
                if (!isCurrentGeneration(gen)) return
                Log.i(TAG, "mDNS discovery stopped for $serviceType")
                _isSearching.value = false
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                if (!isCurrentGeneration(gen)) return
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

    fun stop(clearHosts: Boolean = false) {
        synchronized(lock) {
            browseGeneration += 1L
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                for (cb in activeInfoCallbacks.values) {
                    runCatching { nsdManager.unregisterServiceInfoCallback(cb) }
                }
                activeInfoCallbacks.clear()
            }
            pendingResolveQueue.clear()
            if (clearHosts) {
                resolvedByServiceName.clear()
                _hosts.value = emptyList()
            }
        }

        discoveryListener?.let { listener ->
            runCatching { nsdManager.stopServiceDiscovery(listener) }
        }
        discoveryListener = null

        multicastLock?.let { lock ->
            runCatching { if (lock.isHeld) lock.release() }
        }
        multicastLock = null
        _isSearching.value = false
    }

    private fun isCurrentGeneration(gen: Long): Boolean = synchronized(lock) { gen == browseGeneration }

    private fun resolveServiceInfo(gen: Long, serviceInfo: NsdServiceInfo) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            synchronized(lock) {
                if (gen != browseGeneration) return
                if (activeInfoCallbacks.containsKey(serviceInfo.serviceName)) return
                val serviceName = serviceInfo.serviceName
                val cb = object : NsdManager.ServiceInfoCallback {
                    override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
                        Log.w(TAG, "ServiceInfoCallback registration failed for $serviceName: $errorCode")
                        synchronized(lock) {
                            activeInfoCallbacks.remove(serviceName)
                        }
                    }

                    override fun onServiceUpdated(updated: NsdServiceInfo) {
                        recordResolved(gen, updated)
                    }

                    override fun onServiceLost() {
                        synchronized(lock) {
                            if (gen != browseGeneration) return
                            activeInfoCallbacks.remove(serviceName)
                            resolvedByServiceName.remove(serviceName)
                            publishHostsLocked()
                        }
                    }

                    override fun onServiceInfoCallbackUnregistered() = Unit
                }
                activeInfoCallbacks[serviceName] = cb
                runCatching {
                    nsdManager.registerServiceInfoCallback(serviceInfo, callbackExecutor, cb)
                }.onFailure {
                    activeInfoCallbacks.remove(serviceName)
                    Log.w(TAG, "registerServiceInfoCallback failed: ${it.message}")
                }
            }
        } else {
            synchronized(lock) {
                if (gen != browseGeneration) return
                pendingResolveQueue.addLast(gen to serviceInfo)
                drainResolveQueueLocked()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun drainResolveQueueLocked() {
        if (isResolving) return
        while (pendingResolveQueue.isNotEmpty()) {
            val (gen, next) = pendingResolveQueue.pollFirst() ?: return
            if (gen != browseGeneration) continue
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
                    recordResolved(gen, serviceInfo)
                    synchronized(lock) {
                        isResolving = false
                        drainResolveQueueLocked()
                    }
                }
            })
            return
        }
    }

    private fun recordResolved(gen: Long, serviceInfo: NsdServiceInfo) {
        val address = pickBestAddress(serviceInfo) ?: return
        val port = serviceInfo.port
        if (port !in 1..65535) return

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

        synchronized(lock) {
            if (gen != browseGeneration) return
            Log.i(TAG, "Resolved host: ${host.name} -> ${host.hostAddress}:${host.port} (scanner=${host.scannerName})")
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
            ?: candidates.firstOrNull { !it.isLoopbackAddress }
            ?: candidates.firstOrNull()
        // Keep IPv6 %scope intact for link-local addresses so routing works; strip only if non-link-local
        val addr = best?.hostAddress ?: return null
        return if (best.isLinkLocalAddress) addr else addr.substringBefore('%')
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
