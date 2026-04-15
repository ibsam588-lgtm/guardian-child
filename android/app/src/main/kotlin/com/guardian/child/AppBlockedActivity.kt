package com.guardian.child

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

class AppBlockedActivity : Activity() {

    companion object {
        const val EXTRA_PACKAGE_NAME = "packageName"
        const val EXTRA_APP_NAME = "appName"
        /** "blocked" — parent hard-blocked; "limit_reached" — daily limit hit. */
        const val EXTRA_REASON = "reason"
        const val EXTRA_ALLOW_TIME_REQUESTS = "allowTimeRequests"

        const val REASON_BLOCKED = "blocked"
        const val REASON_LIMIT_REACHED = "limit_reached"
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
                "Ask Parent for Permission"
            )
            else -> Triple(
                "App Limit Reached",
                "You've used all your time for $appName today.",
                "Ask Parent for More Time"
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
