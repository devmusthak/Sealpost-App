package com.sealpost.mail

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import com.hiennv.flutter_callkit_incoming.CallkitConstants
import org.json.JSONObject

/**
 * Handles the same implicit intent as [com.hiennv.flutter_callkit_incoming.CallkitIncomingActivity]
 * (notification body tap + full-screen incoming intent from flutter_callkit_incoming).
 *
 * The stock activity shows the plugin's native ringing UI; we forward to [MainActivity] so Flutter
 * can show [AgoraAudioCallScreen] as the ringing surface instead.
 */
class CallKitIncomingRouteActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD,
            )
        }
        val incoming =
            intent?.extras?.getBundle(CallkitConstants.EXTRA_CALLKIT_INCOMING_DATA)
        if (incoming == null) {
            finish()
            return
        }
        val flat = flattenCallKitIncomingBundle(incoming)
        val json = JSONObject()
        for ((k, v) in flat) {
            json.put(k, v)
        }
        val launch = Intent(this, MainActivity::class.java).apply {
            flags =
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(MainActivity.EXTRA_SEALPOST_CALLKIT_CONTENT, true)
            putExtra(MainActivity.EXTRA_SEALPOST_CALLKIT_JSON, json.toString())
        }
        startActivity(launch)
        finish()
    }

    private fun flattenCallKitIncomingBundle(incoming: Bundle): HashMap<String, String> {
        val out = HashMap<String, String>()
        @Suppress("DEPRECATION")
        val extra =
            incoming.getSerializable(CallkitConstants.EXTRA_CALLKIT_EXTRA) as? HashMap<*, *>
        extra?.forEach { (k, v) ->
            val key = k?.toString()?.trim() ?: return@forEach
            if (key.isEmpty()) return@forEach
            out[key] = v?.toString() ?: ""
        }
        val id = incoming.getString(CallkitConstants.EXTRA_CALLKIT_ID, "")?.trim()
        if (!id.isNullOrEmpty()) {
            out.putIfAbsent("callKitId", id)
        }
        return out
    }
}
