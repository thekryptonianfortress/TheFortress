import 'dart:convert';
import 'dart:developer' as dev;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// Firebase imports kept for when FCM is configured
// import 'package:firebase_core/firebase_core.dart';
// import 'package:firebase_messaging/firebase_messaging.dart';

class NotificationService {
  static final _local = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static const _callChannelId = 'pager_calls';
  static const _msgChannelId = 'pager_messages';

  /// Initialize local notifications — does NOT require Firebase.
  static Future<void> init() async {
    if (_initialized) return;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _local.initialize(
      const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: _onNotificationTap,
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
        ?.createNotificationChannel(const AndroidNotificationChannel(
          _msgChannelId,
          'Messages',
          description: 'New message notifications',
          importance: Importance.high,
        ));

    _initialized = true;
    dev.log('[NotificationService] initialized');
  }

  static void _onNotificationTap(NotificationResponse response) {
    // Navigation handled by provider listeners
  }

  /// Returns null if FCM/Firebase is not configured.
  static Future<String?> getFcmToken() async {
    try {
      // Only works when firebase_messaging is configured
      // ignore: avoid_dynamic_calls
      final dynamic fcm = _getFcmInstance();
      if (fcm == null) return null;
      return await (fcm.getToken() as Future<String?>);
    } catch (_) {
      return null;
    }
  }

  static dynamic _getFcmInstance() {
    try {
      // Will throw if firebase_messaging is not initialized
      // Return null to skip FCM silently
      return null;
    } catch (_) {
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
              const AndroidNotificationAction('answer', 'Answer'),
              const AndroidNotificationAction('reject', 'Reject'),
            ],
          ),
        ),
        payload: jsonEncode({'type': 'call', 'call_id': callId}),
      );
    } catch (e) {
      dev.log('[NotificationService] showCallNotification error: $e');
    }
  }

  static Future<void> showMessageNotification({
    required String senderName,
    required String preview,
  }) async {
    if (!_initialized) return;
    try {
      await _local.show(
        2,
        senderName,
        preview,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _msgChannelId,
            'Messages',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    } catch (e) {
      dev.log('[NotificationService] showMessageNotification error: $e');
    }
  }

  static Future<void> cancelAll() async {
    if (!_initialized) return;
    await _local.cancelAll();
  }
}
