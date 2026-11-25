package com.chromascan.companion.network

import android.util.Log
import com.chromascan.companion.model.ClientMessage
import com.chromascan.companion.model.CompanionBinaryFrame
import com.chromascan.companion.model.CompanionConstants
import com.chromascan.companion.model.CompanionJson
import com.chromascan.companion.model.HostMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
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
    abstract val wsUrl: String

    data class Bonjour(
        val name: String,
        val hostAddress: String,
        val port: Int,
        val hostID: String?
    ) : CompanionTarget() {
        override val displayName: String get() = name
        override val tokenKey: String get() = hostID ?: "bonjour:$name"
        override val wsUrl: String get() = buildWsUrl(hostAddress, port)
    }

    data class Manual(
        val host: String,
        val port: Int
    ) : CompanionTarget() {
        override val displayName: String get() = "$host:$port"
        override val tokenKey: String get() = "manual:$host:$port"
        override val wsUrl: String get() = buildWsUrl(host, port)
    }

    companion object {
        fun buildWsUrl(host: String, port: Int): String {
            val clean = host.trim()
            val formattedHost = if (clean.contains(":") && !clean.startsWith("[")) "[$clean]" else clean
            return "ws://$formattedHost:$port/"
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

    fun connect(target: CompanionTarget, pin: String? = null) {
        disconnect(clearTarget = false)
        currentTarget = target
        pendingPIN = pin
        intentionallyDisconnected = false
        reconnectAttempt = 0
        openConnection(target)
    }

    fun submitPIN(pin: String) {
        pendingPIN = pin
        if (status == ConnectionStatus.Connected && webSocket != null) {
            send(
                ClientMessage.Hello(
                    protocolVersion = CompanionConstants.PROTOCOL_VERSION,
                    clientName = clientName,
                    pin = pin,
                    authToken = null
                )
            )
        } else {
            currentTarget?.let { openConnection(it) }
        }
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
        webSocket?.cancel()
        webSocket = null
        if (clearTarget) {
            currentTarget = null
            pendingPIN = null
        }
        status = ConnectionStatus.Disconnected
    }

    fun send(message: ClientMessage) {
        val ws = webSocket ?: return
        if (status != ConnectionStatus.Connected) return
        try {
            val json = CompanionJson.encodeToString<ClientMessage>(message)
            ws.send(json)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to encode/send message $message", e)
        }
    }

    private fun openConnection(target: CompanionTarget) {
        connectionEpoch += 1
        val epoch = connectionEpoch

        webSocket?.cancel()
        webSocket = null

        status = if (reconnectAttempt == 0) {
            ConnectionStatus.Connecting
        } else {
            ConnectionStatus.Reconnecting(reconnectAttempt)
        }

        Log.i(TAG, "Opening WebSocket to ${target.wsUrl} (attempt=$reconnectAttempt)")
        val request = Request.Builder()
            .url(target.wsUrl)
            .build()

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
                scope.launch {
                    if (epoch != connectionEpoch) return@launch
                    try {
                        val frame = CompanionBinaryFrame.unpack(bytes.toByteArray())
                        onBinaryFrame?.invoke(frame)
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to unpack binary frame: ${e.message}")
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
                pin = pin,
                authToken = if (pin == null) savedToken else null
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
                openConnection(target)
            }
        }
    }

    companion object {
        private const val TAG = "ChromaCompanionClient"
    }
}
