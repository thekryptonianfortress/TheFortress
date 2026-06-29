import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'core/theme.dart';
import 'data/models/contact.dart';
import 'providers/auth_provider.dart';
import 'providers/auto_download_provider.dart';
import 'providers/backup_provider.dart';
import 'providers/call_provider.dart';
import 'providers/contacts_provider.dart';
import 'providers/groups_provider.dart';
import 'providers/messages_provider.dart';
import 'services/groups_service.dart';
import 'services/media_service.dart';
import 'services/messaging_service.dart';
import 'services/signaling_service.dart';
import 'services/webrtc_service.dart';
import 'ui/screens/auth/login_screen.dart';
import 'ui/screens/auth/register_screen.dart';
import 'ui/screens/call/active_call_screen.dart';
import 'ui/screens/call/incoming_call_screen.dart';
import 'ui/screens/call/outgoing_call_screen.dart';
import 'ui/screens/chat/chat_screen.dart';
import 'ui/screens/contacts/add_contact_screen.dart';
import 'ui/screens/groups/create_group_screen.dart';
import 'ui/screens/groups/join_group_screen.dart';
import 'ui/screens/home/home_screen.dart';
import 'ui/screens/splash_screen.dart';

// Global navigator key so incoming calls can push from anywhere
final _navigatorKey = GlobalKey<NavigatorState>();

// Tracks the current top route name so _IncomingCallListener can avoid
// double-pushing /call/active when IncomingCallScreen already navigated there.
final _routeTracker = _RouteNameTracker();

class _RouteNameTracker extends NavigatorObserver {
  String? currentRouteName;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    currentRouteName = route.settings.name;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    currentRouteName = previousRoute?.settings.name;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    currentRouteName = newRoute?.settings.name;
  }
}

class PagerApp extends StatelessWidget {
  const PagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final signaling = SignalingService();
    final webrtc = WebRTCService(signaling);
    final autoDownload = AutoDownloadProvider();
    MediaService.onBytesDownloaded = (bytes) => autoDownload.recordBytesDownloaded(bytes);

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider.value(value: autoDownload),
        ChangeNotifierProvider(create: (_) => BackupProvider()),
        ChangeNotifierProvider(create: (_) => ContactsProvider(signaling)),
        ChangeNotifierProvider(
          create: (_) => MessagesProvider(MessagingService(signaling), signaling),
        ),
        ChangeNotifierProvider(
          create: (_) => CallProvider(signaling, webrtc),
        ),
        ChangeNotifierProvider(
          create: (_) => GroupsProvider(GroupsService(), signaling),
        ),
        Provider<SignalingService>.value(value: signaling),
      ],
      child: MaterialApp(
        navigatorKey: _navigatorKey,
        navigatorObservers: [_routeTracker],
        title: 'Pager',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark,
        initialRoute: '/',
        builder: (context, child) => _IncomingCallListener(child: child!),
        onGenerateRoute: (settings) {
          switch (settings.name) {
            case '/':
              return MaterialPageRoute(builder: (_) => const SplashScreen());
            case '/login':
              return MaterialPageRoute(builder: (_) => const LoginScreen());
            case '/register':
              return MaterialPageRoute(builder: (_) => const RegisterScreen());
            case '/home':
              return MaterialPageRoute(builder: (_) => const HomeScreen());
            case '/contacts/add':
              return MaterialPageRoute(builder: (_) => const AddContactScreen());
            case '/chat':
              final contact = settings.arguments as Contact;
              return MaterialPageRoute(builder: (_) => ChatScreen(contact: contact));
            case '/call/outgoing':
              final contact = settings.arguments as Contact;
              return MaterialPageRoute(builder: (_) => OutgoingCallScreen(contact: contact));
            case '/call/active':
              return MaterialPageRoute(builder: (_) => const ActiveCallScreen());
            case '/call/incoming':
              return MaterialPageRoute(builder: (_) => const IncomingCallScreen());
            case '/groups/create':
              return MaterialPageRoute(builder: (_) => const CreateGroupScreen());
            case '/groups/join':
              return MaterialPageRoute(builder: (_) => const JoinGroupScreen());
            default:
              return MaterialPageRoute(builder: (_) => const SplashScreen());
          }
        },
      ),
    );
  }
}

/// Listens for incoming calls globally and navigates to the incoming call
/// screen regardless of which screen the user is currently on.
class _IncomingCallListener extends StatefulWidget {
  final Widget child;
  const _IncomingCallListener({required this.child});

  @override
  State<_IncomingCallListener> createState() => _IncomingCallListenerState();
}

class _IncomingCallListenerState extends State<_IncomingCallListener> {
  bool _incomingPushed = false;
  bool _activePushed = false;

  @override
  Widget build(BuildContext context) {
    final call = context.watch<CallProvider>();

    // ── Incoming call → push /call/incoming ──────────────────────────────────
    if (call.incomingCall != null && !_incomingPushed) {
      _incomingPushed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _navigatorKey.currentState
            ?.pushNamed('/call/incoming')
            .then((_) => _incomingPushed = false);
      });
    }
    if (call.incomingCall == null && _incomingPushed) {
      _incomingPushed = false;
    }

    // ── Active call → push /call/active (handles notification-answer path) ──
    // IncomingCallScreen uses pushReplacementNamed to get to /call/active.
    // If the user answered via the notification action instead, nobody navigates
    // there — so we do it here, skipping if /call/active is already on top.
    if (call.callState == CallState.active && !_activePushed) {
      _activePushed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_routeTracker.currentRouteName != '/call/active') {
          _navigatorKey.currentState?.pushNamed('/call/active');
        }
      });
    }
    if (call.callState == CallState.idle || call.callState == CallState.ended) {
      _activePushed = false;
    }

    return widget.child;
  }
}
