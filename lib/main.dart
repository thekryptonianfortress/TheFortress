import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app.dart';
import 'services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // Local notifications always initialized (no Firebase dependency)
  try {
    await NotificationService.init();
  } catch (_) {}

  // Firebase is optional — FCM push won't work until flutterfire configure is run
  // try { await Firebase.initializeApp(); } catch (_) {}

  runApp(const PagerApp());
}
