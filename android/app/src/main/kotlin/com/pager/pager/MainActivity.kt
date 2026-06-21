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

    companion object {
        const val MSG_CHANNEL_ID = "fortress_messages"
        const val MSG_NOTIFICATION_ID = 2
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
            putExtra(QuickReplyReceiver.EXTRA_NOTIFICATION_ID, MSG_NOTIFICATION_ID)
            putExtra(QuickReplyReceiver.EXTRA_SENDER_VIRTUAL_ID, senderVirtualId)
        }
        val replyPendingIntent = PendingIntent.getBroadcast(
            this, MSG_NOTIFICATION_ID, replyIntent,
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
            this, 0, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, MSG_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(senderName)
            .setContentText(preview)
            .setStyle(NotificationCompat.BigTextStyle().bigText(preview))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setColor(Color.parseColor("#5288C1"))
            .setAutoCancel(true)
            .setContentIntent(openPendingIntent)
            .addAction(replyAction)
            .build()

        nm.notify(MSG_NOTIFICATION_ID, notification)
    }
}
