import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'core/api_client.dart';
import 'core/app_gate.dart';
import 'core/l10n.dart';
import 'core/locale.dart';
import 'core/push.dart';
import 'core/session.dart';
import 'core/theme.dart';
import 'screens/blocked_screen.dart';
import 'screens/home_shell.dart';
import 'screens/lock_screen.dart';
import 'screens/login_screen.dart';
import 'screens/onboarding_screen.dart';

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
  const HrmsApp({
    super.key,
    this.pushProvider = const DisabledPushProvider(),
    this.session,
  });

  /// How this build receives notifications. Injected from [main] so that a
  /// widget test can drive the app without a Firebase project.
  final PushProvider pushProvider;

  /// The session to run on, for the same reason [pushProvider] is injectable.
  /// Null everywhere but a test, where it is the only way to reach the parts of
  /// the app that are settings rather than screens — the language, above all,
  /// which is changed from the Profile screen and redraws `MaterialApp` itself.
  ///
  /// A caller that supplies one owns it: [dispose] leaves it alone, because a
  /// test that pumps the app twice would otherwise be disposing it twice.
  final Session? session;

  @override
  State<HrmsApp> createState() => _HrmsAppState();
}

class _HrmsAppState extends State<HrmsApp> with WidgetsBindingObserver {
  late final Session _session =
      widget.session ?? Session(pushProvider: widget.pushProvider);

  @override
  void initState() {
    super.initState();
    // For the biometric lock (B1.3): a phone put down for longer than
    // AppLock.backgroundGrace locks again on the way back. And for the app
    // gate (B6.6), which re-asks after a spell in the background.
    WidgetsBinding.instance.addObserver(this);

    // The one thing `SessionScope` cannot deliver on its own.
    //
    // It is an `InheritedNotifier`, so a `notifyListeners()` rebuilds the
    // widgets *below* it that read it — `_Root` and the screens. `MaterialApp`
    // is above it and is built here, with `locale:` read once, so nothing would
    // ever hand it the new one: switching language on the Profile screen would
    // change the preference, the header and nothing on screen (B6.2).
    _session.locale.addListener(_redrawInNewLanguage);

    // Not awaited, and not sequenced before the restore: the gate is one
    // unauthenticated GET and the restore is the thing somebody is waiting on.
    // Making the app hold a splash until a status check returns would put a
    // second network round trip in front of every launch, including the ones
    // with no signal, which have no round trips to spare.
    _session.gate.check();

    // Handlers first, so anything the restore throws is caught (B6.5). Not in
    // main(): the reporter shares the session's API client, which is what makes
    // a report delivered after sign-in say whose handset it came from, and the
    // session does not exist until here. The window that costs is one frame.
    _installCrashReporting();

    _session.restore().whenComplete(() {
      // After the restore, not before: by now a signed-in handset has its token
      // on the client, so whatever crashed last time is attributed to whoever
      // was using it. A crash from before sign-in is still delivered, with
      // nobody against it — that is the report the endpoint is public for.
      _session.crashes.flush();
    });
  }

  /// Takes over the error handlers, synchronously.
  ///
  /// Reading the build number is a platform call and therefore an await, and
  /// waiting for it would leave the first frames uncovered — which is where a
  /// launch crash happens. So the handlers go on now with what is already
  /// known, and the version is filled in a moment later; the reporter reads
  /// these fields when a crash is recorded, so at worst the very first report
  /// has no version against it.
  void _installCrashReporting() {
    _session.crashes.install(
      platform: apiPlatformName(),
      // On Android this names the build and the handset, so no second plugin is
      // needed to identify the device; on iOS it is the OS build alone.
      osVersion: Platform.operatingSystemVersion,
    );

    const PackageInfoVersion().version().then((version) {
      _session.crashes.appVersion = version;
    });
  }

  void _redrawInNewLanguage() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _session.lock.handleLifecycle(state);
    _session.gate.handleLifecycle(state);
  }

  @override
  void dispose() {
    // Before the session disposes it, or removing a listener from a disposed
    // notifier throws.
    _session.locale.removeListener(_redrawInNewLanguage);
    WidgetsBinding.instance.removeObserver(this);
    if (widget.session == null) _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SessionScope(
      notifier: _session,
      child: MaterialApp(
        // onGenerateTitle rather than `title`: it is called with a context that
        // has the delegates above it, so the name in the task switcher follows
        // the language like everything else. A plain `title` is resolved before
        // any of them exist and would stay English for ever.
        onGenerateTitle: (context) => context.t.appTitle,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),

        // B6.2. `AppLocalizations.localizationsDelegates` carries Material's
        // and Cupertino's own delegates alongside the app's, so the date
        // picker and the system dialogs translate with everything else.
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocale.supported,

        // Null follows the handset, which is the default and the common case.
        // Set only by somebody who has chosen otherwise on the Profile screen.
        locale: _session.locale.locale,

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

    // Ahead of the splash, deliberately. A verdict that arrives while the
    // restore is still in flight is already final, and during a maintenance
    // window that restore is going to fail anyway — showing a spinner first
    // would only delay the one screen that explains why.
    if (session.gate.isBlocked) return const BlockedScreen();

    // Hold the splash while the token is verified against /auth/me. Showing the
    // login screen first would flash it at somebody already signed in.
    if (session.isRestoring) {
      // Not const: the splash mark is navy on a light handset and gold on a
      // dark one, which a compile-time colour cannot express.
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.access_time_filled, size: 52, color: AppTheme.brandOf(context)),
              const SizedBox(height: 20),
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            ],
          ),
        ),
      );
    }

    // Before the login form, and only on a handset that has never seen it
    // (B1.1). Somebody signing back in after a shift is not introduced to the
    // app again — `needsOnboarding` is false for any session that restored.
    if (session.needsOnboarding) return const OnboardingScreen();

    if (!session.isSignedIn) return const LoginScreen();

    // Replaces the shell rather than covering it: nothing of the signed-in
    // app should be readable behind the lock, in the app switcher included.
    if (session.lock.isLocked) return const LockScreen();

    return const HomeShell();
  }
}
