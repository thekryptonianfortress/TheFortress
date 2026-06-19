import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'core/theme.dart';
import 'data/models/contact.dart';
import 'providers/auth_provider.dart';
import 'providers/call_provider.dart';
import 'providers/contacts_provider.dart';
import 'providers/messages_provider.dart';
import 'services/messaging_service.dart';
import 'services/mdns_service.dart';
import 'services/signaling_service.dart';
import 'services/webrtc_service.dart';
import 'ui/screens/auth/login_screen.dart';
import 'ui/screens/auth/register_screen.dart';
import 'ui/screens/call/active_call_screen.dart';
import 'ui/screens/call/incoming_call_screen.dart';
import 'ui/screens/call/outgoing_call_screen.dart';
import 'ui/screens/chat/chat_screen.dart';
import 'ui/screens/contacts/add_contact_screen.dart';
import 'ui/screens/home/home_screen.dart';
import 'ui/screens/splash_screen.dart';

// Global navigator key so incoming calls can push from anywhere
final _navigatorKey = GlobalKey<NavigatorState>();

class PagerApp extends StatelessWidget {
  const PagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final signaling = SignalingService();
    final webrtc = WebRTCService(signaling);

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => ContactsProvider()),
        ChangeNotifierProvider(
          create: (_) => MessagesProvider(MessagingService(signaling), signaling),
        ),
        ChangeNotifierProvider(
          create: (_) => CallProvider(signaling, webrtc),
        ),
        Provider<SignalingService>.value(value: signaling),
        Provider<MdnsService>(create: (_) => MdnsService()),
      ],
      child: MaterialApp(
        navigatorKey: _navigatorKey,
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
  bool _navigating = false;

  @override
  Widget build(BuildContext context) {
    final call = context.watch<CallProvider>();

    if (call.incomingCall != null && !_navigating) {
      _navigating = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _navigatorKey.currentState
            ?.pushNamed('/call/incoming')
            .then((_) => _navigating = false);
      });
    }

    // Reset flag when incoming call is cleared (rejected/answered)
    if (call.incomingCall == null && _navigating) {
      _navigating = false;
    }

    return widget.child;
  }
}
