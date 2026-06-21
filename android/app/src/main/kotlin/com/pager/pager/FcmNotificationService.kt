package com.pager.pager

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.graphics.Color
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Native FCM service. Extends FirebaseMessagingService directly so we have
 * full access to Firebase classes. Registered with higher priority than
 * FlutterFirebaseMessagingService so we handle all FCM delivery.
 *
 * Foreground messages come via WebSocket (no FCM needed).
 * Background/killed messages are shown here using QuickReplyReceiver so
 * inline reply works instantly with no spinner.
 */
class FcmNotificationService : FirebaseMessagingService() {

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        val type = data["type"] ?: return

        // Only show notification when app is not in the foreground
        // (foreground messages arrive via WebSocket instead)
        if (isForegrounded()) return

        when (type) {
            "new_message" -> showMessageNotification(
                senderName = data["sender_username"] ?: "New message",
                preview = data["preview"] ?: "You have a new message",
                senderVirtualId = data["sender_virtual_id"] ?: "",
            )
        }
    }

    private fun isForegrounded(): Boolean = try {
        ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
    } catch (_: Exception) { false }

    private fun showMessageNotification(
        senderName: String,
        preview: String,
        senderVirtualId: String,
    ) {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val notifId = 2

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val soundUri = Uri.parse("android.resource://${packageName}/raw/fortress_alert")
            val audioAttr = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            nm.createNotificationChannel(
                NotificationChannel(
                    MainActivity.MSG_CHANNEL_ID, "Messages",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    enableVibration(true)
                    setSound(soundUri, audioAttr)
                }
            )
        }

        // Inline reply → QuickReplyReceiver (cancels notification natively, zero spinner)
        val remoteInput = RemoteInput.Builder(QuickReplyReceiver.KEY_TEXT_REPLY)
            .setLabel("Reply…").build()

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

        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("sender_virtual_id", senderVirtualId)
        }
        val openPendingIntent = PendingIntent.getActivity(
            this, 0, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        nm.notify(
            notifId,
            NotificationCompat.Builder(this, MainActivity.MSG_CHANNEL_ID)
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
        )
    }
}
