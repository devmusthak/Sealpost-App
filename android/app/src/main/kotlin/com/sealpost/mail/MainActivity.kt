package com.sealpost.mail

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ContentResolver
import android.content.Intent
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    companion object {
        const val EXTRA_SEALPOST_CALLKIT_CONTENT = "sealpost_callkit_notification_content"
        const val EXTRA_SEALPOST_CALLKIT_JSON = "sealpost_callkit_notification_json"

        private const val CALL_KIT_CHANNEL = "com.sealpost.mail/call_kit_incoming"

        private val callKitLock = Any()
        private var pendingCallKitJson: String? = null

        internal fun enqueueCallKitContentJson(json: String) {
            synchronized(callKitLock) {
                pendingCallKitJson = json
            }
        }

        private fun takePendingCallKitJson(): String? {
            synchronized(callKitLock) {
                val j = pendingCallKitJson
                pendingCallKitJson = null
                return j
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        val splashScreen = installSplashScreen()
        super.onCreate(savedInstanceState)
        // Skip the Android 12+ exit animation so handoff to Flutter is immediate (~ms, not hundreds of ms).
        splashScreen.setOnExitAnimationListener { view -> view.remove() }
        captureCallKitIntent(intent)
        // Android 15+ enforces edge-to-edge for targetSdk 35; enable it explicitly
        // for consistent behavior on earlier versions as well.
        WindowCompat.setDecorFitsSystemWindows(window, false)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureCallKitIntent(intent)
        flutterEngine?.let { deliverCallKitPayloadIfPending(it) }
    }

    override fun onResume() {
        super.onResume()
        flutterEngine?.let { deliverCallKitPayloadIfPending(it) }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        deliverCallKitPayloadIfPending(flutterEngine)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Distinct id so upgrades replace any old channel that used the system default sound.
            val channelId = "sealpost_mail_custom"
            val channel = NotificationChannel(
                channelId,
                "Mail",
                NotificationManager.IMPORTANCE_HIGH,
            )
            channel.description = "New message notifications"
            val soundUri = Uri.parse(
                "${ContentResolver.SCHEME_ANDROID_RESOURCE}://${applicationContext.packageName}/raw/notification",
            )
            val audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            channel.setSound(soundUri, audioAttributes)
            channel.enableVibration(true)
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }
    }

    private fun captureCallKitIntent(intent: Intent?) {
        if (intent == null) return
        if (!intent.getBooleanExtra(EXTRA_SEALPOST_CALLKIT_CONTENT, false)) return
        val json = intent.getStringExtra(EXTRA_SEALPOST_CALLKIT_JSON)?.trim()
        if (json.isNullOrEmpty()) return
        enqueueCallKitContentJson(json)
        intent.removeExtra(EXTRA_SEALPOST_CALLKIT_CONTENT)
        intent.removeExtra(EXTRA_SEALPOST_CALLKIT_JSON)
    }

    private fun deliverCallKitPayloadIfPending(flutterEngine: FlutterEngine) {
        val json = takePendingCallKitJson() ?: return
        val map = HashMap<String, String>()
        try {
            val o = JSONObject(json)
            val keys = o.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                map[k] = o.optString(k, "")
            }
        } catch (_: Exception) {
            return
        }
        if (map.isEmpty()) return
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CALL_KIT_CHANNEL,
        ).invokeMethod("onCallKitNotificationContent", map)
    }
}
