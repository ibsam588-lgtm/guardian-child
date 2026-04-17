package com.guardian.child

import android.app.Activity
import android.app.AlertDialog
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.core.app.NotificationCompat
import com.google.firebase.FirebaseApp
import com.google.firebase.Timestamp
import com.google.firebase.firestore.FirebaseFirestore

class AppBlockedActivity : Activity() {

    companion object {
        const val EXTRA_PACKAGE_NAME = "packageName"
        const val EXTRA_APP_NAME = "appName"
        /** "blocked" — parent hard-blocked; "limit_reached" — daily limit hit. */
        const val EXTRA_REASON = "reason"
        const val EXTRA_ALLOW_TIME_REQUESTS = "allowTimeRequests"

        const val REASON_BLOCKED = "blocked"
        const val REASON_LIMIT_REACHED = "limit_reached"

        private const val TAG = "AppBlockedActivity"
        private const val BLOCK_CHANNEL_ID = "guardian_block_channel"
        private const val BLOCK_NOTIFICATION_ID = 2001

        /**
         * Bring the block screen to the foreground over whatever the child is
         * currently doing. Tries a direct activity launch first (works when
         * MainActivity still has the "background launch" grace window or when
         * the accessibility service is alive to proxy it); falls back to a
         * full-screen-intent notification which Android guarantees to surface
         * even from a backgrounded app — this is the mechanism alarm / call
         * apps rely on and it's the only path that reliably works on API 29+.
         */
        fun launchOver(
            context: Context,
            blockedPackage: String,
            appName: String,
            reason: String,
            allowTimeRequests: Boolean,
        ) {
            val intent = Intent(context, AppBlockedActivity::class.java).apply {
                putExtra(EXTRA_PACKAGE_NAME, blockedPackage)
                putExtra(EXTRA_APP_NAME, appName)
                putExtra(EXTRA_REASON, reason)
                putExtra(EXTRA_ALLOW_TIME_REQUESTS, allowTimeRequests)
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TASK
                )
            }

            // Preferred path — accessibility service has implicit permission
            // to start activities from anywhere, so if BrowserMonitorService
            // is connected we use it.
            if (BrowserMonitorService.startActivitySafely(intent)) {
                return
            }

            // Fallback 1 — try a plain start. On API 28- this works; on
            // API 29+ it may be dropped by the OS if nothing in our process
            // is in the foreground. We catch any SecurityException silently.
            try {
                context.startActivity(intent)
            } catch (e: Exception) {
                Log.w(TAG, "direct activity launch failed: ${e.message}")
            }

            // Fallback 2 — full-screen-intent notification. This is the
            // belt-and-suspenders path: even if the direct start was
            // swallowed, Android will foreground the activity from the
            // notification's fullScreenIntent field.
            postFullScreenNotification(context, intent, appName, reason)
        }

        private fun postFullScreenNotification(
            context: Context,
            blockIntent: Intent,
            appName: String,
            reason: String,
        ) {
            try {
                val nm = context.getSystemService(NotificationManager::class.java) ?: return

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val channel = NotificationChannel(
                        BLOCK_CHANNEL_ID,
                        "GuardIan Blocks",
                        NotificationManager.IMPORTANCE_HIGH
                    ).apply {
                        description = "Shown when an app is blocked or hits its limit."
                        setBypassDnd(true)
                    }
                    nm.createNotificationChannel(channel)
                }

                val piFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                else
                    PendingIntent.FLAG_UPDATE_CURRENT
                val pi = PendingIntent.getActivity(context, 0, blockIntent, piFlags)

                val title = if (reason == REASON_BLOCKED) "$appName is blocked"
                else "$appName's time is up"
                val body = if (reason == REASON_BLOCKED)
                    "Your parent has blocked this app. Tap to request access."
                else
                    "You've used your daily limit. Tap to ask for more time."

                val notif = NotificationCompat.Builder(context, BLOCK_CHANNEL_ID)
                    .setSmallIcon(android.R.drawable.ic_lock_lock)
                    .setContentTitle(title)
                    .setContentText(body)
                    .setPriority(NotificationCompat.PRIORITY_MAX)
                    .setCategory(NotificationCompat.CATEGORY_ALARM)
                    .setOngoing(true)
                    .setAutoCancel(true)
                    .setFullScreenIntent(pi, true)
                    .setContentIntent(pi)
                    .build()

                nm.notify(BLOCK_NOTIFICATION_ID, notif)
            } catch (e: Exception) {
                Log.w(TAG, "full-screen notification failed: ${e.message}")
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Keep screen on and show above lock screen so the block screen stays visible
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
        )

        val blockedPackage = intent.getStringExtra(EXTRA_PACKAGE_NAME) ?: ""
        val appName = intent.getStringExtra(EXTRA_APP_NAME)?.takeIf { it.isNotBlank() }
            ?: prettyName(blockedPackage)
        val reason = intent.getStringExtra(EXTRA_REASON) ?: REASON_LIMIT_REACHED
        val allowTimeRequests = intent.getBooleanExtra(EXTRA_ALLOW_TIME_REQUESTS, true)

        val (titleText, subtitleText, askLabel) = when (reason) {
            REASON_BLOCKED -> Triple(
                "App Blocked",
                "$appName has been blocked by your parent.",
                "Request Unblock"
            )
            else -> Triple(
                "App Limit Reached",
                "You've used all your time for $appName today.",
                "Request More Time"
            )
        }

        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.parseColor("#1E293B"))
            setPadding(64, 64, 64, 64)
        }

        val icon = TextView(this).apply {
            text = if (reason == REASON_BLOCKED) "\uD83D\uDD12" else "\u23F1\uFE0F"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 72f)
            gravity = Gravity.CENTER
        }

        val title = TextView(this).apply {
            text = titleText
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 24f)
            gravity = Gravity.CENTER
            setPadding(0, 32, 0, 16)
        }

        val subtitle = TextView(this).apply {
            text = subtitleText
            setTextColor(Color.parseColor("#94A3B8"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, 48)
        }

        layout.addView(icon)
        layout.addView(title)
        layout.addView(subtitle)

        if (allowTimeRequests) {
            val askBtn = Button(this).apply {
                text = askLabel
                setTextColor(Color.WHITE)
                background = roundedBg(Color.parseColor("#3B82F6"))
                setPadding(48, 24, 48, 24)
                setOnClickListener {
                    // Show the request form inline inside the block overlay.
                    // Previously this relaunched the Guardian Child app with
                    // a deep-link route, which yanked the child out of the
                    // block screen entirely — clunky UX and unnecessary since
                    // the request is just a single Firestore write.
                    showRequestDialog(blockedPackage, appName, reason)
                }
            }
            layout.addView(askBtn, buttonParams())
        }

        val closeBtn = Button(this).apply {
            text = "Go to Home Screen"
            setTextColor(Color.WHITE)
            background = roundedBg(Color.parseColor("#475569"))
            setPadding(48, 24, 48, 24)
            setOnClickListener {
                val homeIntent = Intent(Intent.ACTION_MAIN).apply {
                    addCategory(Intent.CATEGORY_HOME)
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
                startActivity(homeIntent)
                finish()
            }
        }
        layout.addView(closeBtn, buttonParams())

        setContentView(layout)
    }

    private fun buttonParams(): LinearLayout.LayoutParams {
        return LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply {
            topMargin = 16
        }
    }

    private fun roundedBg(color: Int): GradientDrawable {
        return GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = 24f
            setColor(color)
        }
    }

    private fun prettyName(pkg: String): String {
        if (pkg.isBlank()) return "this app"
        val parts = pkg.split('.')
        val last = parts.lastOrNull()?.takeIf { it.isNotBlank() } ?: return pkg
        return last.replaceFirstChar { it.uppercase() }
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        // Prevent dismissing the block screen via back button
    }

    /**
     * Inline unblock / extra-time request. We build a one-field dialog
     * right on top of the block screen so the child never leaves this
     * activity. The submission goes straight to Firestore — the child
     * app (and its FlutterEngine) does not need to be running.
     */
    private fun showRequestDialog(pkg: String, appName: String, reason: String) {
        val isUnblock = reason == REASON_BLOCKED
        val titleText = if (isUnblock) "Ask to unblock $appName" else "Ask for more time on $appName"
        val hint = if (isUnblock)
            "Optional: why do you want this unblocked?"
        else
            "Optional: why do you need more time?"

        val note = EditText(this).apply {
            setHint(hint)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            maxLines = 4
            setPadding(32, 32, 32, 32)
        }

        AlertDialog.Builder(this)
            .setTitle(titleText)
            .setView(note)
            .setPositiveButton("Send") { _, _ ->
                submitTimeRequest(pkg, appName, reason, note.text.toString().trim())
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    /**
     * Writes a timeRequests doc the parent's home-screen listener picks
     * up. Fields match what TimeRequestService expects so the same
     * approve/deny dialog renders without special-casing the source.
     *
     * kind = "permission" for blocked-app unblock requests (so a parent
     * approval flips appLimits/{pkg}.isBlocked back to false permanently),
     * or "time" for an extra-minutes top-up on a limit-reached app.
     */
    private fun submitTimeRequest(
        pkg: String,
        appName: String,
        reason: String,
        childNote: String,
    ) {
        val childId = readChildId()
        val parentUid = readParentUid()
        if (childId.isBlank() || parentUid.isBlank()) {
            Toast.makeText(
                this,
                "Can't send right now — device not paired. Open Guardian Child and try again.",
                Toast.LENGTH_LONG
            ).show()
            return
        }

        // Ensure Firebase is initialised in this process. AppBlockedActivity
        // can be launched by the accessibility service before the main
        // FirebaseInitProvider has run on some OEMs.
        try { FirebaseApp.getInstance() } catch (_: IllegalStateException) {
            try { FirebaseApp.initializeApp(applicationContext) } catch (e: Exception) {
                Log.w(TAG, "Firebase init failed: ${e.message}")
            }
        }

        val kind = if (reason == REASON_BLOCKED) "permission" else "time"
        val requestedMinutes = if (reason == REASON_BLOCKED) 0 else 15
        val expiresAt = Timestamp(
            Timestamp.now().seconds + 10 * 60,  // 10-minute TTL
            0
        )

        val childName = readChildName().ifBlank { "Your child" }
        val payload = hashMapOf<String, Any>(
            "parentUid" to parentUid,
            "childId" to childId,
            "childName" to childName,
            "appName" to appName,
            "packageName" to pkg,
            "requestedMinutes" to requestedMinutes,
            "childNote" to childNote,
            "kind" to kind,
            "status" to "pending",
            "createdAt" to Timestamp.now(),
            "expiresAt" to expiresAt,
        )

        FirebaseFirestore.getInstance()
            .collection("timeRequests")
            .add(payload)
            .addOnSuccessListener {
                Toast.makeText(
                    this,
                    if (kind == "permission")
                        "Unblock request sent to your parent."
                    else
                        "Request sent — ask your parent to approve.",
                    Toast.LENGTH_LONG
                ).show()
            }
            .addOnFailureListener { e ->
                Log.w(TAG, "submitTimeRequest failed: ${e.message}")
                Toast.makeText(
                    this,
                    "Couldn't send request: ${e.message}",
                    Toast.LENGTH_LONG
                ).show()
            }
    }

    private fun readChildId(): String {
        return try {
            val sp = applicationContext.getSharedPreferences(
                "FlutterSharedPreferences", Context.MODE_PRIVATE)
            sp.getString("flutter.paired_child_id", null).orEmpty()
        } catch (_: Exception) { "" }
    }

    private fun readParentUid(): String {
        return try {
            val sp = applicationContext.getSharedPreferences(
                "FlutterSharedPreferences", Context.MODE_PRIVATE)
            sp.getString("flutter.paired_parent_uid", null).orEmpty()
        } catch (_: Exception) { "" }
    }

    private fun readChildName(): String {
        return try {
            val sp = applicationContext.getSharedPreferences(
                "FlutterSharedPreferences", Context.MODE_PRIVATE)
            sp.getString("flutter.paired_child_name", null).orEmpty()
        } catch (_: Exception) { "" }
    }
}
