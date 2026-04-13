package com.guardian.child

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.app.ServiceInfo
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Foreground service that plays a loud siren alarm.
 *
 * Running as a foreground service ensures the siren keeps playing even when
 * the child closes the app or presses the back button. The persistent
 * notification cannot be dismissed while the service is running.
 *
 * Only a `siren_stop` command from the parent (via CommandService) can stop it.
 */
class SirenService : Service() {

    companion object {
        private const val TAG = "SirenService"
        private const val NOTIFICATION_ID = 9001
        private const val CHANNEL_ID = "guardian_siren_channel"

        fun start(context: Context) {
            val intent = Intent(context, SirenService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, SirenService::class.java))
        }
    }

    private var sirenPlayer: MediaPlayer? = null
    private var originalVolume: Int = -1

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createNotificationChannel()
        // Pass FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK on API 29+ so the OS knows
        // this service plays audio. Required for the mediaPlayback foreground service
        // type declared in the manifest (avoids a 3-minute kill limit from shortService).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                buildNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIFICATION_ID, buildNotification())
        }
        playSiren()
        // START_STICKY: if the OS kills this service, restart it automatically
        return START_STICKY
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Guardian Siren Alert",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Alarm triggered by parent guardian"
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                // Do not bypass DND for the notification itself (alarm audio handles volume)
                setBypassDnd(false)
            }
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_silent_mode_off)
            .setContentTitle("GuardIan Alert")
            .setContentText("An alarm has been triggered by your guardian")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setOngoing(true)       // cannot be swiped away by the user
            .setAutoCancel(false)
            .build()
    }

    private fun playSiren() {
        try {
            stopSiren() // release any previous instance

            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

            // Save and maximise alarm volume — works even in silent/vibrate mode
            originalVolume = audioManager.getStreamVolume(AudioManager.STREAM_ALARM)
            val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_ALARM)
            audioManager.setStreamVolume(AudioManager.STREAM_ALARM, maxVolume, 0)

            // Pick best available alarm sound
            var alarmUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            if (alarmUri == null) {
                alarmUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            }
            if (alarmUri == null) {
                alarmUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            }

            if (alarmUri == null) {
                Log.e(TAG, "No alarm sound available on this device — cannot play siren")
                return
            }

            sirenPlayer = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                setOnErrorListener { _, what, extra ->
                    Log.e(TAG, "MediaPlayer error: what=$what extra=$extra")
                    false
                }
                setDataSource(this@SirenService, alarmUri)
                isLooping = true
                prepare()
                start()
            }
            Log.d(TAG, "Siren started at max volume ($maxVolume)")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to play siren", e)
        }
    }

    private fun stopSiren() {
        try {
            sirenPlayer?.let { player ->
                if (player.isPlaying) player.stop()
                player.release()
            }
            sirenPlayer = null

            if (originalVolume >= 0) {
                val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                audioManager.setStreamVolume(AudioManager.STREAM_ALARM, originalVolume, 0)
                originalVolume = -1
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping siren: ${e.message}")
        }
    }

    override fun onDestroy() {
        stopSiren()
        super.onDestroy()
    }
}
