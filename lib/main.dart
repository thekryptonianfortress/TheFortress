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

// ignore_for_file: unused_import

/// FCM background message handler — notification display is handled natively
/// by FcmNotificationService (Kotlin) so inline reply works without a spinner.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  // FcmNotificationService.kt shows the notification natively with QuickReplyReceiver.
}

/// Handles local notification actions when the app is backgrounded/killed.
@pragma('vm:entry-point')
void notificationBackgroundHandler(NotificationResponse response) async {
  if (response.actionId == 'reject') {
    // Reject an incoming call via HTTP (no socket available in background isolate)
    final payload = response.payload ?? '';
    String callId = '';
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      callId = data['call_id'] as String? ?? '';
    } catch (_) {}
    if (callId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('pager_auth_token');
      final serverUrl = prefs.getString('pager_server_url') ?? 'http://137.184.168.242:4000';
      if (token == null || token.isEmpty) return;
      final client = HttpClient();
      final req = await client.postUrl(Uri.parse('$serverUrl/calls/reject'));
      req.headers.set('Content-Type', 'application/json');
      req.headers.set('Authorization', 'Bearer $token');
      req.write(jsonEncode({'call_id': callId}));
      final res = await req.close();
      await res.drain<void>();
      client.close();
    } catch (_) {}
    return;
  }

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
