import 'dart:convert';
import 'dart:developer' as dev;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationService {
  static final _local = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static const _callChannelId   = 'fortress_calls';
  static const _msgChannelId    = 'fortress_messages';
  static const _ringtoneChannel = MethodChannel('pager/ringtone');
  static const _nativeNotifChannel = MethodChannel('pager/notification');
  static const _msgSoundUri =
      'android.resource://com.pager.pager/raw/fortress_alert';

  /// Set by CallProvider to handle answer/reject actions from notification buttons.
  static Function(String action)? onCallAction;

  /// Set by MessagesProvider to handle quick-reply from notification.
  /// Called with (senderVirtualId, replyText).
  static Function(String senderVirtualId, String replyText)? onMessageReply;

  /// Virtual ID of the contact whose chat should be opened when app comes to foreground.
  static String? pendingOpenChatVirtualId;

  /// Called by the app when it has processed pendingOpenChatVirtualId.
  static void clearPendingOpenChat() => pendingOpenChatVirtualId = null;

  /// Initialize local notifications — does NOT require Firebase.
  static Future<void> init({
    DidReceiveBackgroundNotificationResponseCallback? backgroundHandler,
  }) async {
    if (_initialized) return;

    // Request notification permission on Android 13+
    await Permission.notification.request();

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _local.initialize(
      const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: _onNotificationTap,
      onDidReceiveBackgroundNotificationResponse: backgroundHandler,
    );

    await _local
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          _callChannelId,
          'Calls',
          description: 'Incoming call notifications',
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
        ));

    await _local
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(AndroidNotificationChannel(
          _msgChannelId,
          'Messages',
          description: 'New message notifications',
          importance: Importance.high,
          playSound: true,
          sound: UriAndroidNotificationSound(_msgSoundUri),
        ));

    // Disable FCM's own heads-up notification on Android (we show our own)
    await FirebaseMessaging.instance
        .setForegroundNotificationPresentationOptions(alert: false, badge: false, sound: false);

    // Handle FCM messages while app is in foreground — show local notification
    FirebaseMessaging.onMessage.listen(_onFcmForeground);

    // When user taps a notification that launched the app from terminated state
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) _handleFcmData(initial.data);

    // When user taps notification with app in background (not killed)
    FirebaseMessaging.onMessageOpenedApp.listen((msg) => _handleFcmData(msg.data));

    // Cold-start: read sender stored natively in FlutterSharedPreferences
    final prefs = await SharedPreferences.getInstance();
    final storedVirtualId = prefs.getString('pending_open_chat') ?? '';
    if (storedVirtualId.isNotEmpty) {
      pendingOpenChatVirtualId = storedVirtualId;
      await prefs.remove('pending_open_chat');
    }

    // Background tap: native onNewIntent invokes 'openChat' on this channel
    _nativeNotifChannel.setMethodCallHandler((call) async {
      if (call.method == 'openChat') {
        final virtualId = call.arguments as String? ?? '';
        if (virtualId.isNotEmpty) {
          pendingOpenChatVirtualId = virtualId;
        }
      }
    });

    _initialized = true;
    dev.log('[NotificationService] initialized');
  }

  static Future<void> _onFcmForeground(RemoteMessage message) async {
    final data = message.data;
    final type = data['type'] ?? '';
    if (type == 'new_message') {
      final senderName = data['sender_username'] ?? 'New message';
      final preview = data['preview'] ?? 'You have a new message';
      final senderVirtualId = data['sender_virtual_id'] ?? '';
      await showMessageNotification(
        senderName: senderName,
        preview: preview,
        senderVirtualId: senderVirtualId,
      );
    } else if (type == 'incoming_call') {
      final callerName = data['caller_username'] ?? 'Unknown';
      final callId = data['call_id'] ?? '';
      final callerVirtualId = data['caller_virtual_id'] ?? '';
      await showCallNotification(
        callerName: callerName,
        callerVirtualId: callerVirtualId,
        callId: callId,
      );
    }
  }

  static void _handleFcmData(Map<String, dynamic> data) {
    final type = data['type'] ?? '';
    if (type == 'new_message') {
      final virtualId = data['sender_virtual_id'] ?? '';
      if (virtualId.isNotEmpty) {
        pendingOpenChatVirtualId = virtualId;
      }
    }
  }

  static void _onNotificationTap(NotificationResponse response) {
    final action = response.actionId;
    if (action == 'answer' || action == 'reject') {
      onCallAction?.call(action!);
      return;
    }
    if (action == 'msg_reply' || response.actionId == null) {
      // Notification body or Reply tapped — open the chat
      final payload = response.payload ?? '';
      if (payload.isNotEmpty) {
        try {
          final data = jsonDecode(payload) as Map<String, dynamic>;
          final virtualId = data['sender_virtual_id'] as String? ?? '';
          if (virtualId.isNotEmpty) {
            pendingOpenChatVirtualId = virtualId;
          }
        } catch (_) {}
      }
    }
  }

  /// Returns the FCM registration token for this device.
  static Future<String?> getFcmToken() async {
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      dev.log('[NotificationService] getFcmToken error: $e');
      return null;
    }
  }

  static Future<void> showCallNotification({
    required String callerName,
    required String callerVirtualId,
    required String callId,
  }) async {
    if (!_initialized) return;
    try {
      await _local.show(
        1,
        'Incoming Call',
        '$callerName ($callerVirtualId) is calling...',
        NotificationDetails(
          android: AndroidNotificationDetails(
            _callChannelId,
            'Calls',
            importance: Importance.max,
            priority: Priority.max,
            fullScreenIntent: true,
            category: AndroidNotificationCategory.call,
            actions: [
              const AndroidNotificationAction(
                'answer',
                'Answer',
                showsUserInterface: true,
              ),
              const AndroidNotificationAction(
                'reject',
                'Reject',
                showsUserInterface: false,
                cancelNotification: true,
              ),
            ],
          ),
        ),
        payload: jsonEncode({'type': 'call', 'call_id': callId}),
      );
    } catch (e) {
      dev.log('[NotificationService] showCallNotification error: $e');
    }
  }

  /// Play the device's default ringtone on loop.
  static Future<void> startRingtone() async {
    try {
      await _ringtoneChannel.invokeMethod('play');
    } catch (e) {
      dev.log('[NotificationService] startRingtone error: $e');
    }
  }

  /// Stop the ringtone.
  static Future<void> stopRingtone() async {
    try {
      await _ringtoneChannel.invokeMethod('stop');
    } catch (e) {
      dev.log('[NotificationService] stopRingtone error: $e');
    }
  }

  /// Show a message notification.
  /// When MainActivity is active (foreground/background), uses the native
  /// MethodChannel so QuickReplyReceiver handles inline reply without opening
  /// the app. Falls back to flutter_local_notifications for killed-app FCM case.
  static Future<void> showMessageNotification({
    required String senderName,
    required String preview,
    required String senderVirtualId,
    bool nativeOnly = false,
  }) async {
    // Try native channel first (requires MainActivity to be alive)
    try {
      await _nativeNotifChannel.invokeMethod('showMessage', {
        'senderName': senderName,
        'preview': preview,
        'senderVirtualId': senderVirtualId,
      });
      return;
    } catch (_) {
      // MainActivity not active (app killed) — fall through to local plugin
    }

    if (!_initialized || nativeOnly) return;
    try {
      await _local.show(
        2,
        senderName,
        preview,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _msgChannelId,
            'Messages',
            importance: Importance.high,
            priority: Priority.high,
            playSound: true,
            sound: const UriAndroidNotificationSound(
                'android.resource://com.pager.pager/raw/fortress_alert'),
            styleInformation: BigTextStyleInformation(preview),
            largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
            color: const Color(0xFF5288C1),
          ),
        ),
        payload: jsonEncode({
          'type': 'message',
          'sender_virtual_id': senderVirtualId,
        }),
      );
    } catch (e) {
      dev.log('[NotificationService] showMessageNotification error: $e');
    }
  }

  static Future<void> _queueReply(String payload, String replyText) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = prefs.getStringList('pending_notification_replies') ?? [];
      pending.add(jsonEncode({'payload': payload, 'reply': replyText}));
      await prefs.setStringList('pending_notification_replies', pending);
    } catch (_) {}
  }

  static Future<void> cancelAll() async {
    if (!_initialized) return;
    await _local.cancelAll();
  }
}
