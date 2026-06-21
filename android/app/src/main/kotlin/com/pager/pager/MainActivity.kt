package com.pager.pager

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.graphics.Color
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.media.Ringtone
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val ringtoneChannel = "pager/ringtone"
    private val notifChannel = "pager/notification"
    private var ringtone: Ringtone? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        storeNotificationIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val senderVirtualId = intent.getStringExtra("sender_virtual_id") ?: return
        if (senderVirtualId.isNotEmpty()) {
            // Persist so Flutter can reliably read it after resume
            storeNotificationIntent(intent)
            // Also notify Flutter directly if the engine is ready
            flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
                MethodChannel(messenger, notifChannel).invokeMethod("openChat", senderVirtualId)
            }
        }
    }

    private fun storeNotificationIntent(intent: Intent?) {
        val senderVirtualId = intent?.getStringExtra("sender_virtual_id") ?: return
        if (senderVirtualId.isNotEmpty()) {
            // Cold-start: store for Flutter to read after init
            getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
                .edit()
                .putString("flutter.pending_open_chat", senderVirtualId)
                .apply()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Ringtone channel (existing)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ringtoneChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "play" -> {
                        try {
                            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                            ringtone?.stop()
                            ringtone = RingtoneManager.getRingtone(applicationContext, uri)
                            ringtone?.isLooping = true
                            ringtone?.play()
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("RINGTONE_ERROR", e.message, null)
                        }
                    }
                    "stop" -> {
                        ringtone?.stop()
                        ringtone = null
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Notification channel — shows message notifications with native inline reply
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, notifChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "showMessage" -> {
                        try {
                            val senderName = call.argument<String>("senderName") ?: "New message"
                            val preview = call.argument<String>("preview") ?: ""
                            val senderVirtualId = call.argument<String>("senderVirtualId") ?: ""
                            showMessageNotification(senderName, preview, senderVirtualId)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("NOTIF_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun showMessageNotification(senderName: String, preview: String, senderVirtualId: String) {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager

        // Unique ID per sender so notifications from different people stack
        val notifId = notifIdForSender(senderVirtualId)

        // Accumulate badge count across messages from the same sender
        val badgeCount = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            (nm.activeNotifications.find { it.id == notifId }?.notification?.number ?: 0) + 1
        } else 1

        // Ensure the notification channel exists with custom sound
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val soundUri = Uri.parse(
                "android.resource://${packageName}/raw/fortress_alert"
            )
            val audioAttr = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            val chan = NotificationChannel(
                MSG_CHANNEL_ID, "Messages", NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "New message notifications"
                enableVibration(true)
                setSound(soundUri, audioAttr)
            }
            nm.createNotificationChannel(chan)
        }

        // RemoteInput for inline reply
        val remoteInput = RemoteInput.Builder(QuickReplyReceiver.KEY_TEXT_REPLY)
            .setLabel("Reply…")
            .build()

        // PendingIntent → QuickReplyReceiver (handles reply natively, no app open)
        val replyIntent = Intent(this, QuickReplyReceiver::class.java).apply {
            action = QuickReplyReceiver.ACTION_QUICK_REPLY
            putExtra(QuickReplyReceiver.EXTRA_NOTIFICATION_ID, notifId)
            putExtra(QuickReplyReceiver.EXTRA_SENDER_VIRTUAL_ID, senderVirtualId)
        }
        val replyPendingIntent = PendingIntent.getBroadcast(
            this, notifId, replyIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        )
        val replyAction = NotificationCompat.Action.Builder(
            android.R.drawable.ic_menu_send, "Reply", replyPendingIntent
        ).addRemoteInput(remoteInput).build()

        // Tapping the notification body opens the app to the right chat
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("sender_virtual_id", senderVirtualId)
        }
        val openPendingIntent = PendingIntent.getActivity(
            this, notifId, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, MSG_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(senderName)
            .setContentText(preview)
            .setStyle(NotificationCompat.BigTextStyle().bigText(preview))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setColor(Color.parseColor("#5288C1"))
            .setNumber(badgeCount)
            .setAutoCancel(true)
            .setContentIntent(openPendingIntent)
            .addAction(replyAction)
            .build()

        nm.notify(notifId, notification)
    }

    companion object {
        const val MSG_CHANNEL_ID = "fortress_messages"
        const val MSG_NOTIFICATION_ID = 2 // kept for legacy; prefer notifIdForSender()

        /** Stable notification ID derived from sender virtual ID (avoids collision with call ID 1). */
        fun notifIdForSender(senderVirtualId: String): Int =
            (senderVirtualId.hashCode() and 0x7FFFFFFF) % 9000 + 100
    }
}
