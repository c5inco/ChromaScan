package com.chromascan.companion.network

import android.util.Log
import com.chromascan.companion.model.ClientMessage
import com.chromascan.companion.model.CompanionBinaryFrame
import com.chromascan.companion.model.CompanionConstants
import com.chromascan.companion.model.CompanionJson
import com.chromascan.companion.model.HostMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import java.util.concurrent.TimeUnit
import kotlin.math.min
import kotlin.math.pow

sealed class CompanionTarget {
    abstract val displayName: String
    abstract val tokenKey: String
    abstract val hostAddress: String
    abstract val port: Int

    fun buildValidatedWsUrl(): String? = buildWsUrl(hostAddress, port)

    data class Bonjour(
        val name: String,
        override val hostAddress: String,
        override val port: Int,
        val hostID: String?
    ) : CompanionTarget() {
        override val displayName: String get() = name
        override val tokenKey: String get() = hostID ?: "bonjour:$name"
    }

    data class Manual(
        override val hostAddress: String,
        override val port: Int
    ) : CompanionTarget() {
        override val displayName: String get() = "$hostAddress:$port"
        override val tokenKey: String get() = "manual:$hostAddress:$port"
    }

    companion object {
        fun buildWsUrl(host: String, port: Int): String? {
            if (port !in 1..65535) return null
            val clean = host.trim()
                .removePrefix("ws://")
                .removePrefix("wss://")
                .removePrefix("http://")
                .removePrefix("https://")
                .trimEnd('/')
            if (clean.isEmpty() || clean.any { it.isWhitespace() || it == '/' || it == '?' || it == '#' }) {
                return null
            }
            val strippedBrackets = if (clean.startsWith("[") && clean.endsWith("]")) {
                clean.substring(1, clean.length - 1)
            } else {
                clean
            }
            return runCatching {
                val httpUrl = HttpUrl.Builder()
                    .scheme("http")
                    .host(strippedBrackets)
                    .port(port)
                    .build()
                httpUrl.toString().replaceFirst("http://", "ws://")
            }.getOrNull()
        }
    }
}

sealed class ConnectionStatus {
    data object Disconnected : ConnectionStatus()
    data object Connecting : ConnectionStatus()
    data object Connected : ConnectionStatus()
    data class Reconnecting(val attempt: Int) : ConnectionStatus()
}

/**
 * Persistent WebSocket client speaking the ChromaScan Companion Protocol over OkHttp.
 */
class CompanionClient(
    private val clientName: String,
    private val tokenStore: TokenStore,
    private val scope: CoroutineScope
) {
    var onStatusChanged: ((ConnectionStatus) -> Unit)? = null
    var onHostMessage: ((HostMessage) -> Unit)? = null
    var onBinaryFrame: ((CompanionBinaryFrame) -> Unit)? = null
    var onInvalidTarget: ((String) -> Unit)? = null

    private val okHttpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .pingInterval(15, TimeUnit.SECONDS)
        .build()

    private var webSocket: WebSocket? = null
    private var currentTarget: CompanionTarget? = null
    private var pendingPIN: String? = null
    private var reconnectJob: Job? = null
    private var reconnectAttempt: Int = 0
    private var intentionallyDisconnected: Boolean = true
    private var connectionEpoch: Long = 0

    @Volatile
    var status: ConnectionStatus = ConnectionStatus.Disconnected
        private set(value) {
            if (field != value) {
                field = value
                onStatusChanged?.invoke(value)
            }
        }

    val activeTarget: CompanionTarget?
        get() = currentTarget

    fun connect(target: CompanionTarget, pin: String? = null): Boolean {
        if (target.buildValidatedWsUrl() == null) {
            onInvalidTarget?.invoke("Invalid host address or port: ${target.displayName}")
            return false
        }
        disconnect(clearTarget = false)
        currentTarget = target
        pendingPIN = pin?.filter { it.isDigit() }?.takeIf { it.length == 6 }
        intentionallyDisconnected = false
        reconnectAttempt = 0
        openConnection(target)
        return true
    }

    /**
     * Updates the resolved Bonjour host address/port (e.g., after Mac relaunch assigns
     * a new ephemeral port) and triggers an immediate reconnect if currently retrying.
     */
    fun updateBonjourEndpoint(hostAddress: String, port: Int) {
        val current = currentTarget as? CompanionTarget.Bonjour ?: return
        if (current.hostAddress == hostAddress && current.port == port) return
        val updated = current.copy(hostAddress = hostAddress, port = port)
        if (updated.buildValidatedWsUrl() == null) return
        currentTarget = updated
        if (!intentionallyDisconnected && status is ConnectionStatus.Reconnecting) {
            Log.i(TAG, "Updated Bonjour endpoint for ${updated.name} -> $hostAddress:$port; reconnecting immediately")
            reconnectJob?.cancel()
            reconnectJob = null
            reconnectAttempt = 0
            openConnection(updated)
        }
    }

    fun submitPIN(pin: String) {
        val clean = pin.filter { it.isDigit() }
        if (clean.length != 6) return
        pendingPIN = clean
        if (status == ConnectionStatus.Connected && webSocket != null) {
            send(
                ClientMessage.Hello(
                    protocolVersion = CompanionConstants.PROTOCOL_VERSION,
                    clientName = clientName,
                    pin = clean,
                    authToken = null
                )
            )
        } else {
            currentTarget?.let { openConnection(it) }
        }
    }

    /** Clears one-time PIN once authenticated so reconnects always use the persisted authToken. */
    fun markAuthenticated() {
        pendingPIN = null
    }

    /** Clears a rejected PIN so reconnects do not re-submit an invalid PIN. */
    fun clearPendingPin() {
        pendingPIN = null
    }

    fun saveAuthToken(token: String, hostID: String) {
        tokenStore.saveToken(token, hostID)
        val key = currentTarget?.tokenKey
        if (key != null && key != hostID) {
            tokenStore.saveToken(token, key)
        }
    }

    fun clearSavedToken(hostID: String? = null) {
        if (hostID != null) {
            tokenStore.deleteToken(hostID)
        }
        currentTarget?.tokenKey?.let { tokenStore.deleteToken(it) }
    }

    fun reconnectIfNeeded() {
        val target = currentTarget ?: return
        if (intentionallyDisconnected) return
        if (status == ConnectionStatus.Connected) {
            send(ClientMessage.Ping)
            return
        }
        reconnectJob?.cancel()
        reconnectJob = null
        openConnection(target)
    }

    fun disconnect(clearTarget: Boolean = true) {
        intentionallyDisconnected = true
        connectionEpoch += 1
        reconnectJob?.cancel()
        reconnectJob = null
        webSocket?.close(1000, "Client disconnect")
        webSocket = null
        if (clearTarget) {
            currentTarget = null
            pendingPIN = null
        }
        status = ConnectionStatus.Disconnected
    }

    fun send(message: ClientMessage): Boolean {
        val ws = webSocket ?: return false
        if (status != ConnectionStatus.Connected) return false
        return try {
            val json = CompanionJson.encodeToString<ClientMessage>(message)
            ws.send(json)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to encode/send message $message", e)
            false
        }
    }

    private fun openConnection(target: CompanionTarget) {
        val wsUrl = target.buildValidatedWsUrl()
        if (wsUrl == null) {
            intentionallyDisconnected = true
            status = ConnectionStatus.Disconnected
            onInvalidTarget?.invoke("Invalid host address or port: ${target.displayName}")
            return
        }

        connectionEpoch += 1
        val epoch = connectionEpoch

        webSocket?.cancel()
        webSocket = null

        status = if (reconnectAttempt == 0) {
            ConnectionStatus.Connecting
        } else {
            ConnectionStatus.Reconnecting(reconnectAttempt)
        }

        Log.i(TAG, "Opening WebSocket to $wsUrl (attempt=$reconnectAttempt)")
        val request = try {
            Request.Builder().url(wsUrl).build()
        } catch (e: IllegalArgumentException) {
            intentionallyDisconnected = true
            status = ConnectionStatus.Disconnected
            onInvalidTarget?.invoke(e.localizedMessage ?: "Invalid WebSocket URL")
            return
        }

        webSocket = okHttpClient.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                scope.launch {
                    if (epoch != connectionEpoch) return@launch
                    Log.i(TAG, "WebSocket opened to ${target.displayName}")
                    reconnectAttempt = 0
                    status = ConnectionStatus.Connected
                    sendHello(target)
                }
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                scope.launch {
                    if (epoch != connectionEpoch) return@launch
                    try {
                        val msg = CompanionJson.decodeFromString<HostMessage>(text)
                        onHostMessage?.invoke(msg)
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to decode HostMessage: ${e.message}")
                    }
                }
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                if (bytes.size > CompanionConstants.MAXIMUM_MESSAGE_SIZE) {
                    Log.w(TAG, "Dropping oversized binary frame (${bytes.size} bytes > ${CompanionConstants.MAXIMUM_MESSAGE_SIZE})")
                    return
                }
                // Unpack off the main thread so large proxy/gallery payloads don't stall UI frames
                scope.launch(Dispatchers.Default) {
                    val frame = try {
                        CompanionBinaryFrame.unpack(bytes.toByteArray())
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to unpack binary frame: ${e.message}")
                        return@launch
                    }
                    scope.launch {
                        if (epoch != connectionEpoch) return@launch
                        onBinaryFrame?.invoke(frame)
                    }
                }
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(code, reason)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                scope.launch {
                    if (epoch != connectionEpoch) return@launch
                    Log.i(TAG, "WebSocket closed ($code): $reason")
                    handleDrop()
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                scope.launch {
                    if (epoch != connectionEpoch) return@launch
                    Log.w(TAG, "WebSocket failure: ${t.message}")
                    handleDrop()
                }
            }
        })
    }

    private fun sendHello(target: CompanionTarget) {
        val savedToken = tokenStore.token(target.tokenKey)
        val pin = pendingPIN
        send(
            ClientMessage.Hello(
                protocolVersion = CompanionConstants.PROTOCOL_VERSION,
                clientName = clientName,
                pin = if (savedToken != null && pin == null) null else pin,
                authToken = savedToken
            )
        )
    }

    private fun handleDrop() {
        webSocket?.cancel()
        webSocket = null

        val target = currentTarget
        if (intentionallyDisconnected || target == null) {
            status = ConnectionStatus.Disconnected
            return
        }

        reconnectAttempt += 1
        status = ConnectionStatus.Reconnecting(reconnectAttempt)
        val delayMs = (min(8.0, 2.0.pow(min(reconnectAttempt - 1, 3).toDouble())) * 1000.0).toLong()

        reconnectJob?.cancel()
        reconnectJob = scope.launch {
            delay(delayMs)
            if (!intentionallyDisconnected && currentTarget != null) {
                openConnection(currentTarget ?: target)
            }
        }
    }

    companion object {
        private const val TAG = "ChromaCompanionClient"
    }
}
