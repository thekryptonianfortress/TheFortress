import 'dart:convert';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'services/notification_service.dart';

/// FCM background message handler — called when the app is killed or backgrounded.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  final data = message.data;
  final type = data['type'] ?? '';

  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
    onDidReceiveBackgroundNotificationResponse: notificationBackgroundHandler,
  );

  if (type == 'new_message') {
    final senderName = data['sender_username'] ?? 'New message';
    final preview = data['preview'] ?? 'You have a new message';
    final senderVirtualId = data['sender_virtual_id'] ?? '';

    await plugin.show(
      2,
      senderName,
      preview,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'fortress_messages',
          'Messages',
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          sound: const UriAndroidNotificationSound(
              'android.resource://com.pager.pager/raw/fortress_alert'),
          color: const Color(0xFF5288C1),
          actions: [
            const AndroidNotificationAction(
              'msg_reply',
              'Reply',
              showsUserInterface: false,
              cancelNotification: true,
              inputs: [
                AndroidNotificationActionInput(label: 'Reply…'),
              ],
            ),
          ],
        ),
      ),
      payload: jsonEncode({
        'type': 'message',
        'sender_virtual_id': senderVirtualId,
      }),
    );
  } else if (type == 'incoming_call') {
    final callerName = data['caller_username'] ?? 'Unknown';
    await plugin.show(
      1,
      'Incoming Call',
      '$callerName is calling…',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'fortress_calls',
          'Calls',
          importance: Importance.max,
          priority: Priority.max,
          fullScreenIntent: true,
          category: AndroidNotificationCategory.call,
        ),
      ),
    );
  }
}

/// Handles local notification actions when the app is backgrounded/killed.
@pragma('vm:entry-point')
void notificationBackgroundHandler(NotificationResponse response) async {
  if (response.actionId != 'msg_reply') return;

  final replyText = response.input?.trim() ?? '';
  final payload = response.payload ?? '';
  if (replyText.isEmpty || payload.isEmpty) return;

  String senderVirtualId = '';
  try {
    final data = jsonDecode(payload) as Map<String, dynamic>;
    senderVirtualId = data['sender_virtual_id'] as String? ?? '';
  } catch (_) {}
  if (senderVirtualId.isEmpty) return;

  // Cancel notification to stop any spinner
  try {
    WidgetsFlutterBinding.ensureInitialized();
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ));
    await plugin.cancel(2);
  } catch (_) {}

  // Read token + server URL from SharedPreferences (mirrored there on login)
  try {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('pager_auth_token');
    final serverUrl = prefs.getString('pager_server_url')
        ?? 'http://137.184.168.242:4000';
    if (token == null || token.isEmpty) return;

    // Send via HTTP — dart:io works in any Dart isolate without platform channels
    final client = HttpClient();
    final req = await client.postUrl(Uri.parse('$serverUrl/messages/quick-reply'));
    req.headers.set('Content-Type', 'application/json');
    req.headers.set('Authorization', 'Bearer $token');
    req.write(jsonEncode({
      'recipient_virtual_id': senderVirtualId,
      'content': replyText,
    }));
    final res = await req.close();
    await res.drain<void>();
    client.close();
  } catch (_) {}
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  try {
    await NotificationService.init(backgroundHandler: notificationBackgroundHandler);
  } catch (_) {}

  runApp(const PagerApp());
}
