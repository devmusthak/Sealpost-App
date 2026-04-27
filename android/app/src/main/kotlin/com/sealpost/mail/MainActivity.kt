package com.sealpost.mail

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ContentResolver
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 15+ enforces edge-to-edge for targetSdk 35; enable it explicitly
        // for consistent behavior on earlier versions as well.
        WindowCompat.setDecorFitsSystemWindows(window, false)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
}
