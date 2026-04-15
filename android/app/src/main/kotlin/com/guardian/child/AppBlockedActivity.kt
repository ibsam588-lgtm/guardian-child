package com.guardian.child

import android.app.Activity
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
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.NotificationCompat

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
                    val launch = packageManager.getLaunchIntentForPackage(this@AppBlockedActivity.packageName)
                    if (launch != null) {
                        launch.addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP
                        )
                        launch.putExtra("route", "/time-request")
                        launch.putExtra(EXTRA_PACKAGE_NAME, blockedPackage)
                        launch.putExtra(EXTRA_APP_NAME, appName)
                        launch.putExtra(EXTRA_REASON, reason)
                        startActivity(launch)
                    }
                    finish()
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
}
