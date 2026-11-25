package com.chromascan.companion.network

import android.content.Context
import android.content.SharedPreferences

class TokenStore(context: Context) {
    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun token(key: String): String? =
        prefs.getString("$TOKEN_PREFIX$key", null)?.takeIf { it.isNotEmpty() }

    fun saveToken(token: String, key: String) {
        prefs.edit().putString("$TOKEN_PREFIX$key", token).apply()
    }

    fun deleteToken(key: String) {
        prefs.edit().remove("$TOKEN_PREFIX$key").apply()
    }

    var lastManualHost: String
        get() = prefs.getString(KEY_LAST_MANUAL_HOST, "") ?: ""
        set(value) = prefs.edit().putString(KEY_LAST_MANUAL_HOST, value).apply()

    var lastManualPort: String
        get() = prefs.getString(KEY_LAST_MANUAL_PORT, "") ?: ""
        set(value) = prefs.edit().putString(KEY_LAST_MANUAL_PORT, value).apply()

    var notifyOnScanComplete: Boolean
        get() = prefs.getBoolean(KEY_NOTIFY_ON_COMPLETE, true)
        set(value) = prefs.edit().putBoolean(KEY_NOTIFY_ON_COMPLETE, value).apply()

    companion object {
        private const val PREFS_NAME = "chromascan_companion_prefs"
        private const val TOKEN_PREFIX = "token."
        private const val KEY_LAST_MANUAL_HOST = "lastManualHost"
        private const val KEY_LAST_MANUAL_PORT = "lastManualPort"
        private const val KEY_NOTIFY_ON_COMPLETE = "notifyOnScanComplete"
    }
}
