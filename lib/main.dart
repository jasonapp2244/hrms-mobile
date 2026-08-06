import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'core/api_client.dart';
import 'core/push.dart';
import 'core/session.dart';
import 'core/theme.dart';
import 'screens/home_shell.dart';
import 'screens/login_screen.dart';

Future<void> main() async {
  // Before anything renders: a release build pointed at the development server
  // is a build mistake, and it fails as a hang rather than as an error.
  ApiClient.assertSecureBaseUrl();

  // Required before any plugin is touched, and Firebase is touched below.
  WidgetsFlutterBinding.ensureInitialized();

  // Resolves to a provider that receives nothing when this build has no
  // Firebase credentials — which is every build until somebody has done the
  // console work in Push-Notifications_Setup.md. The app is fully usable in
  // that state; it simply gets no notifications.
  //
  // There is deliberately no `onBackgroundMessage` handler. The server sends a
  // `notification` block with every push (FcmClient), so the OS draws the
  // notification itself while the app is backgrounded or dead, and a Dart
  // isolate woken for each message would do nothing but cost battery.
  final push = await FirebasePushProvider.connect(() => Firebase.initializeApp());

  runApp(HrmsApp(pushProvider: push));
}

/// Makes the [Session] reachable from any screen without threading it through
/// every constructor. One inherited notifier for one piece of global state.
class SessionScope extends InheritedNotifier<Session> {
  const SessionScope({super.key, required Session super.notifier, required super.child});

  static Session of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SessionScope>();
    assert(scope?.notifier != null, 'No SessionScope above this widget.');
    return scope!.notifier!;
  }

  /// For callbacks that need the session but must not subscribe to it —
  /// reading it inside a button handler should not rebuild the whole subtree.
  static Session read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<SessionScope>();
    assert(scope?.notifier != null, 'No SessionScope above this widget.');
    return scope!.notifier!;
  }
}

class HrmsApp extends StatefulWidget {
  const HrmsApp({super.key, this.pushProvider = const DisabledPushProvider()});

  /// How this build receives notifications. Injected from [main] so that a
  /// widget test can drive the app without a Firebase project.
  final PushProvider pushProvider;

  @override
  State<HrmsApp> createState() => _HrmsAppState();
}

class _HrmsAppState extends State<HrmsApp> {
  late final Session _session = Session(pushProvider: widget.pushProvider);

  @override
  void initState() {
    super.initState();
    _session.restore();
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SessionScope(
      notifier: _session,
      child: MaterialApp(
        title: 'HR & Attendance',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        home: const _Root(),
      ),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);

    // Hold the splash while the token is verified against /auth/me. Showing the
    // login screen first would flash it at somebody already signed in.
    if (session.isRestoring) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.access_time_filled, size: 52, color: AppTheme.brand),
              SizedBox(height: 20),
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            ],
          ),
        ),
      );
    }

    return session.isSignedIn ? const HomeShell() : const LoginScreen();
  }
}
