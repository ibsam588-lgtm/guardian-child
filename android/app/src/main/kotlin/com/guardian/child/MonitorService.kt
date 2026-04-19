package com.guardian.child

import android.Manifest
import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.app.NotificationCompat
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

class MonitorService : Service() {

    companion object {
        const val CHANNEL_ID = "guardian_monitor_channel"
        const val NOTIFICATION_ID = 1001
        private const val TAG = "MonitorService"

        fun start(context: Context) {
            try {
                val intent = Intent(context, MonitorService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.w(TAG, "Could not start foreground service: ${e.message}")
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, MonitorService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "Could not stop service: ${e.message}")
            }
        }

        fun hasLocationPermission(context: Context): Boolean {
            return ContextCompat.checkSelfPermission(
                context, Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(
                context, Manifest.permission.ACCESS_COARSE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()

        // On Android 14+, foregroundServiceType=location requires location
        // permission. If missing, start without the location type so monitoring
        // (app limits, browser, SOS) continues even without location access.
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE
                && !hasLocationPermission(this)) {
                Log.w(TAG, "Location permission not granted — starting without location type")
                // Start foreground without specifying a service type so Android
                // doesn't require the location permission for the notification.
                startForeground(NOTIFICATION_ID, buildNotification(), 0)
            } else {
                startForeground(NOTIFICATION_ID, buildNotification())
            }
        } catch (e: Exception) {
            Log.w(TAG, "startForeground failed — retrying without type: ${e.message}")
            try {
                startForeground(NOTIFICATION_ID, buildNotification())
            } catch (e2: Exception) {
                Log.e(TAG, "startForeground completely failed: ${e2.message}")
                // Do NOT stopSelf — let the service stay alive for app monitoring
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * Called when the user swipes the app away from the recents screen.
     * Schedules a WorkManager one-time task to restart the service after a
     * short delay. WorkManager is reliable on Android 12+ whereas AlarmManager
     * exact alarms require the SCHEDULE_EXACT_ALARM permission and starting a
     * foreground service from background is blocked on Android 12+.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.d(TAG, "onTaskRemoved — scheduling WorkManager restart in 2 s")
        try {
            val restartRequest = OneTimeWorkRequestBuilder<ServiceWatchdogWorker>()
                .setInitialDelay(2, TimeUnit.SECONDS)
                .build()
            WorkManager.getInstance(applicationContext).enqueue(restartRequest)
        } catch (e: Exception) {
            Log.w(TAG, "Could not schedule watchdog restart: ${e.message}")
        }
        super.onTaskRemoved(rootIntent)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "GuardIan Monitor",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps GuardIan running in the background"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val openAppIntent = packageManager
            .getLaunchIntentForPackage(packageName)
            ?.apply { flags = Intent.FLAG_ACTIVITY_SINGLE_TOP }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("GuardIan is active")
            .setContentText("Your parent can see you're safe 🛡️")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
}
