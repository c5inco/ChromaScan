package com.chromascan.companion.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.chromascan.companion.MainActivity
import com.chromascan.companion.R
import com.chromascan.companion.store.RemoteSessionStore
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Foreground service that keeps the local WebSocket alive while a multi-minute 1200 DPI scan
 * runs on the Mac host, displaying live scan progress in the shade & lock screen and posting
 * a completion alert when done—zero cloud push setup required.
 */
class ScanMonitorService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannels(this)
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Scanning on Mac"
        val detail = intent?.getStringExtra(EXTRA_DETAIL) ?: "Starting scanner…"
        val progressPct = intent?.getIntExtra(EXTRA_PROGRESS_PCT, -1) ?: -1

        // Always satisfy Android's startForeground() contract even if stopping immediately
        val notification = buildProgressNotification(this, title, detail, progressPct)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                PROGRESS_NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(PROGRESS_NOTIFICATION_ID, notification)
        }

        when (intent?.action) {
            ACTION_CANCEL_SCAN -> {
                RemoteSessionStore.peekInstance()?.cancelActiveOperation()
                stopSelfCleanly()
            }

            ACTION_STOP -> {
                stopSelfCleanly()
            }

            else -> {
                isServiceRunning = true
            }
        }
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelfCleanly()
    }

    override fun onDestroy() {
        isServiceRunning = false
        super.onDestroy()
    }

    private fun stopSelfCleanly() {
        isServiceRunning = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    companion object {
        const val CHANNEL_PROGRESS = "chromascan_scan_progress"
        const val CHANNEL_COMPLETE = "chromascan_scan_complete"
        private const val PROGRESS_NOTIFICATION_ID = 4101
        private const val COMPLETE_NOTIFICATION_ID = 4102

        private const val ACTION_START = "com.chromascan.companion.ACTION_START_MONITOR"
        private const val ACTION_STOP = "com.chromascan.companion.ACTION_STOP_MONITOR"
        private const val ACTION_CANCEL_SCAN = "com.chromascan.companion.ACTION_CANCEL_SCAN"

        private const val EXTRA_TITLE = "extra_title"
        private const val EXTRA_DETAIL = "extra_detail"
        private const val EXTRA_PROGRESS_PCT = "extra_progress_pct"

        @Volatile
        private var isServiceRunning = false

        fun ensureChannels(context: Context) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_PROGRESS) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_PROGRESS,
                        "Active Scan Progress",
                        NotificationManager.IMPORTANCE_LOW
                    ).apply {
                        description = "Shows live scan progress while ChromaScan captures on your Mac."
                        setShowBadge(false)
                    }
                )
            }
            if (nm.getNotificationChannel(CHANNEL_COMPLETE) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_COMPLETE,
                        "Scan Completed",
                        NotificationManager.IMPORTANCE_HIGH
                    ).apply {
                        description = "Notifies when a full-resolution scan finishes saving on your Mac."
                    }
                )
            }
        }

        private fun buildProgressNotification(
            context: Context,
            title: String,
            detail: String,
            progressPct: Int
        ): Notification {
            val openIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val openPending = PendingIntent.getActivity(
                context,
                0,
                openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val cancelIntent = Intent(context, ScanMonitorService::class.java).apply {
                action = ACTION_CANCEL_SCAN
            }
            val cancelPending = PendingIntent.getService(
                context,
                1,
                cancelIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val builder = NotificationCompat.Builder(context, CHANNEL_PROGRESS)
                .setSmallIcon(R.drawable.ms_scanner)
                .setContentTitle(title)
                .setContentText(detail)
                .setContentIntent(openPending)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setCategory(NotificationCompat.CATEGORY_PROGRESS)
                .addAction(0, "Cancel Scan", cancelPending)

            if (progressPct in 0..100) {
                builder.setProgress(100, progressPct, false)
            } else {
                builder.setProgress(0, 0, true)
            }
            return builder.build()
        }

        /**
         * Starts the foreground service once (when allowed) or updates its existing notification
         * directly via NotificationManager without repeatedly calling startForegroundService().
         */
        fun updateProgress(
            context: Context,
            title: String,
            detail: String,
            fraction: Double?,
            allowStartService: Boolean
        ) {
            ensureChannels(context)
            val pct = fraction?.let { (it.coerceIn(0.0, 1.0) * 100.0).roundToInt() } ?: -1
            if (isServiceRunning) {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                runCatching {
                    nm.notify(PROGRESS_NOTIFICATION_ID, buildProgressNotification(context, title, detail, pct))
                }
                return
            }
            if (!allowStartService) return

            val intent = Intent(context, ScanMonitorService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_DETAIL, detail)
                putExtra(EXTRA_PROGRESS_PCT, pct)
            }
            runCatching {
                isServiceRunning = true
                context.startForegroundService(intent)
            }.onFailure {
                isServiceRunning = false
            }
        }

        fun stop(context: Context) {
            if (!isServiceRunning) return
            val intent = Intent(context, ScanMonitorService::class.java).apply {
                action = ACTION_STOP
            }
            runCatching {
                context.startService(intent)
            }.onFailure {
                isServiceRunning = false
                runCatching { context.stopService(Intent(context, ScanMonitorService::class.java)) }
            }
        }

        fun postScanCompleted(
            context: Context,
            filename: String,
            pixelWidth: Int,
            pixelHeight: Int,
            fileSizeBytes: Long,
            elapsedSeconds: Double
        ) {
            ensureChannels(context)
            val openIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val openPending = PendingIntent.getActivity(
                context,
                2,
                openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val mb = fileSizeBytes.toDouble() / (1024.0 * 1024.0)
            val body = String.format(
                Locale.US,
                "%s · %d×%d px · %.1f MB (%s)",
                filename,
                pixelWidth,
                pixelHeight,
                mb,
                RemoteSessionStore.formatElapsedSeconds(elapsedSeconds)
            )
            val notification = NotificationCompat.Builder(context, CHANNEL_COMPLETE)
                .setSmallIcon(R.drawable.ms_photo_library)
                .setContentTitle("Scan Complete")
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setContentIntent(openPending)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .build()

            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            runCatching {
                nm.notify(COMPLETE_NOTIFICATION_ID, notification)
            }
        }
    }
}
