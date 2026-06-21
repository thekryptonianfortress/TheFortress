package com.pager.pager

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.RemoteInput
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

class QuickReplyReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_QUICK_REPLY = "com.pager.pager.QUICK_REPLY"
        const val EXTRA_NOTIFICATION_ID = "notification_id"
        const val EXTRA_SENDER_VIRTUAL_ID = "sender_virtual_id"
        const val KEY_TEXT_REPLY = "key_text_reply"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val bundle = RemoteInput.getResultsFromIntent(intent) ?: return
        val replyText = bundle.getCharSequence(KEY_TEXT_REPLY)?.toString()?.trim() ?: return
        if (replyText.isEmpty()) return

        val notificationId = intent.getIntExtra(EXTRA_NOTIFICATION_ID, 2)
        val senderVirtualId = intent.getStringExtra(EXTRA_SENDER_VIRTUAL_ID) ?: return

        // Cancel notification immediately — stops the Android loading spinner
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(notificationId)

        // Read credentials from regular SharedPreferences (mirrored by Flutter on login)
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val token = prefs.getString("flutter.pager_auth_token", null) ?: return
        val serverUrl = prefs.getString("flutter.pager_server_url", "http://137.184.168.242:4000")
            ?: "http://137.184.168.242:4000"

        Thread {
            try {
                val url = URL("$serverUrl/messages/quick-reply")
                val conn = url.openConnection() as HttpURLConnection
                conn.requestMethod = "POST"
                conn.setRequestProperty("Content-Type", "application/json")
                conn.setRequestProperty("Authorization", "Bearer $token")
                conn.doOutput = true
                conn.connectTimeout = 10_000
                conn.readTimeout = 10_000

                val body = JSONObject().apply {
                    put("recipient_virtual_id", senderVirtualId)
                    put("content", replyText)
                }.toString().toByteArray(Charsets.UTF_8)

                conn.outputStream.use { it.write(body) }
                conn.responseCode // execute the request
                conn.disconnect()
            } catch (_: Exception) {}
        }.start()
    }
}
