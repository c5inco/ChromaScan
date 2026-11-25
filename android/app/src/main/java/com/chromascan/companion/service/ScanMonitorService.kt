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
        when (intent?.action) {
            ACTION_CANCEL_SCAN -> {
                RemoteSessionStore.peekInstance()?.cancelActiveOperation()
                stopSelf()
                return START_NOT_STICKY
            }

            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }

            else -> {
                val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Scanning on Mac"
                val detail = intent?.getStringExtra(EXTRA_DETAIL) ?: "Starting scanner…"
                val progressPct = intent?.getIntExtra(EXTRA_PROGRESS_PCT, -1) ?: -1
                val notification = buildProgressNotification(title, detail, progressPct)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(
                        PROGRESS_NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                    )
                } else {
                    startForeground(PROGRESS_NOTIFICATION_ID, notification)
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun buildProgressNotification(
        title: String,
        detail: String,
        progressPct: Int
    ): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val openPending = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val cancelIntent = Intent(this, ScanMonitorService::class.java).apply {
            action = ACTION_CANCEL_SCAN
        }
        val cancelPending = PendingIntent.getService(
            this,
            1,
            cancelIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(this, CHANNEL_PROGRESS)
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

    companion object {
        const val CHANNEL_PROGRESS = "chromascan_scan_progress"
        const val CHANNEL_COMPLETE = "chromascan_scan_complete"
        private const val PROGRESS_NOTIFICATION_ID = 4101
        private const val COMPLETE_NOTIFICATION_ID = 4102

        private const val ACTION_UPDATE = "com.chromascan.companion.ACTION_UPDATE_PROGRESS"
        private const val ACTION_STOP = "com.chromascan.companion.ACTION_STOP_MONITOR"
        private const val ACTION_CANCEL_SCAN = "com.chromascan.companion.ACTION_CANCEL_SCAN"

        private const val EXTRA_TITLE = "extra_title"
        private const val EXTRA_DETAIL = "extra_detail"
        private const val EXTRA_PROGRESS_PCT = "extra_progress_pct"

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

        fun updateProgress(context: Context, title: String, detail: String, fraction: Double?) {
            val pct = fraction?.let { (it.coerceIn(0.0, 1.0) * 100.0).roundToInt() } ?: -1
            val intent = Intent(context, ScanMonitorService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_DETAIL, detail)
                putExtra(EXTRA_PROGRESS_PCT, pct)
            }
            runCatching {
                context.startForegroundService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, ScanMonitorService::class.java).apply {
                action = ACTION_STOP
            }
            runCatching {
                context.stopService(intent)
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
