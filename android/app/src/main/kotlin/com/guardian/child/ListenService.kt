package com.guardian.child

import android.Manifest
import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Base64
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.google.firebase.Timestamp
import com.google.firebase.firestore.FirebaseFirestore
import java.io.File

/**
 * Ambient listening foreground service.
 *
 * When the parent hits "Listen Live" in the parent app, a `listen_start`
 * command is written to Firestore. The Dart CommandService forwards it
 * through a MethodChannel to MainActivity, which starts this service.
 *
 * This service records 5-second AAC chunks via [MediaRecorder], reads
 * each chunk as bytes, base64-encodes it, and writes it to
 * `children/{childId}/listen_chunks/{autoId}`. The parent app streams
 * that subcollection, decodes, and plays chunks in order.
 *
 * `listen_stop` from the parent triggers [stop] via the same channel.
 *
 * Safety TTL: the service auto-stops after [MAX_SESSION_MS] so a
 * forgotten-open session doesn't drain the child's battery indefinitely.
 */
class ListenService : Service() {

    companion object {
        const val CHANNEL_ID = "guardian_listen_channel"
        const val NOTIFICATION_ID = 1003
        private const val TAG = "ListenService"

        private const val CHUNK_MS: Long = 5_000L          // 5s per chunk
        private const val MAX_SESSION_MS: Long = 15 * 60_000L // 15min absolute safety TTL

        const val EXTRA_CHILD_ID = "childId"
        /** Requested recording duration in seconds. The service stops itself after
         *  this many seconds, capped at MAX_SESSION_MS. 0 / negative means unlimited
         *  (use the 15-minute safety TTL). */
        const val EXTRA_DURATION_SECONDS = "durationSeconds"

        /**
         * Write a status update to children/{childId}/listen_status/current
         * so the parent UI can show "recording", "no mic permission", etc.
         * instead of sitting on "Connecting…" forever when something goes
         * wrong on the child.
         */
        private fun writeStatus(childId: String, state: String, message: String? = null) {
            if (childId.isBlank()) return
            try {
                val data = hashMapOf<String, Any>(
                    "state" to state,
                    "updatedAt" to Timestamp.now(),
                )
                if (message != null) data["message"] = message
                FirebaseFirestore.getInstance()
                    .collection("children")
                    .document(childId)
                    .collection("listen_status")
                    .document("current")
                    .set(data)
            } catch (e: Exception) {
                Log.w(TAG, "writeStatus failed: ${e.message}")
            }
        }

        fun start(context: Context, childId: String, durationSeconds: Int = 0) {
            // Mic permission must be granted — otherwise Android will
            // kill the foreground service with a SecurityException the
            // moment MediaRecorder tries to start.
            if (ContextCompat.checkSelfPermission(
                    context, Manifest.permission.RECORD_AUDIO
                ) != PackageManager.PERMISSION_GRANTED) {
                Log.w(TAG, "RECORD_AUDIO not granted — aborting start")
                writeStatus(childId, "error", "Microphone permission not granted on child device")
                return
            }
            writeStatus(childId, "starting")
            val intent = Intent(context, ListenService::class.java)
                .putExtra(EXTRA_CHILD_ID, childId)
                .putExtra(EXTRA_DURATION_SECONDS, durationSeconds)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.w(TAG, "start failed: ${e.message}")
                writeStatus(childId, "error", "Could not start listen service: ${e.message}")
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, ListenService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "stop failed: ${e.message}")
            }
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private var recorder: MediaRecorder? = null
    private var currentFile: File? = null
    private var childId: String = ""
    private var running = false
    private val db by lazy { FirebaseFirestore.getInstance() }
    private var startedAtMs: Long = 0L
    /** Effective session TTL — set from EXTRA_DURATION_SECONDS (if > 0), else MAX_SESSION_MS. */
    private var sessionMaxMs: Long = MAX_SESSION_MS

    private val rotateChunkRunnable = object : Runnable {
        override fun run() {
            if (!running) return
            // Enforce per-session TTL (duration requested by parent, or 15-min safety cap)
            if (System.currentTimeMillis() - startedAtMs >= sessionMaxMs) {
                Log.i(TAG, "Session TTL reached — stopping")
                stopSelf()
                return
            }
            try {
                stopChunk()
                uploadCurrentChunk()
                startChunk()
            } catch (e: Exception) {
                Log.w(TAG, "rotation error: ${e.message}")
            }
            handler.postDelayed(this, CHUNK_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        try {
            startForeground(NOTIFICATION_ID, buildNotification())
        } catch (e: Exception) {
            Log.w(TAG, "startForeground failed: ${e.message}")
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getStringExtra(EXTRA_CHILD_ID).orEmpty()
        if (id.isBlank()) {
            Log.w(TAG, "No childId supplied — stopping")
            stopSelf()
            return START_NOT_STICKY
        }
        childId = id

        // Apply the requested duration as the session TTL, capped at the
        // absolute safety limit. durationSeconds <= 0 means "use the default".
        val durationSec = intent?.getIntExtra(EXTRA_DURATION_SECONDS, 0) ?: 0
        sessionMaxMs = if (durationSec > 0) {
            minOf(durationSec * 1_000L, MAX_SESSION_MS)
        } else {
            MAX_SESSION_MS
        }

        if (!running) {
            running = true
            startedAtMs = System.currentTimeMillis()
            try {
                startChunk()
                writeStatus(childId, "recording")
                handler.postDelayed(rotateChunkRunnable, CHUNK_MS)
            } catch (e: Exception) {
                Log.e(TAG, "failed to start recording: ${e.message}")
                writeStatus(childId, "error", "MediaRecorder failed: ${e.message}")
                stopSelf()
            }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        running = false
        handler.removeCallbacks(rotateChunkRunnable)
        try {
            stopChunk()
            // Upload the final partial chunk so the parent hears the
            // tail of the session rather than having it silently dropped.
            uploadCurrentChunk()
        } catch (e: Exception) {
            Log.w(TAG, "onDestroy cleanup: ${e.message}")
        }
        writeStatus(childId, "stopped")
        super.onDestroy()
    }

    private fun startChunk() {
        val file = File(cacheDir, "listen_${System.currentTimeMillis()}.aac")
        currentFile = file
        @Suppress("DEPRECATION")
        val r = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(this)
        } else {
            MediaRecorder()
        }
        r.setAudioSource(MediaRecorder.AudioSource.MIC)
        r.setOutputFormat(MediaRecorder.OutputFormat.AAC_ADTS)
        r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
        r.setAudioSamplingRate(16_000)
        r.setAudioChannels(1)
        r.setAudioEncodingBitRate(24_000)
        r.setOutputFile(file.absolutePath)
        r.prepare()
        r.start()
        recorder = r
    }

    private fun stopChunk() {
        recorder?.let {
            try { it.stop() } catch (_: Exception) {}
            try { it.release() } catch (_: Exception) {}
        }
        recorder = null
    }

    private fun uploadCurrentChunk() {
        val f = currentFile ?: return
        currentFile = null
        if (!f.exists() || f.length() <= 0L) {
            f.delete()
            return
        }
        try {
            val bytes = f.readBytes()
            // Safety: Firestore caps documents at 1 MB. Our chunks are
            // ~15 KB at 24kbps mono, but an unexpected recorder blip
            // could produce something huge — bail rather than corrupt
            // the document.
            if (bytes.size > 900_000) {
                Log.w(TAG, "chunk too large (${bytes.size} B) — skipping")
                return
            }
            val b64 = Base64.encodeToString(bytes, Base64.NO_WRAP)
            db.collection("children")
                .document(childId)
                .collection("listen_chunks")
                .add(
                    mapOf(
                        "data" to b64,
                        "mime" to "audio/aac",
                        "durationMs" to CHUNK_MS,
                        "timestamp" to Timestamp.now(),
                    )
                )
        } catch (e: Exception) {
            Log.w(TAG, "upload failed: ${e.message}")
        } finally {
            f.delete()
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "GuardIan Listen",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Ambient listening session"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("GuardIan is active")
            .setContentText("Your parent can see you're safe 🛡️")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
}
