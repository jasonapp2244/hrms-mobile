import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/biometrics.dart';
import 'package:attendance/core/l10n.dart';
import 'package:attendance/core/locale.dart';
import 'package:attendance/core/location.dart';
import 'package:attendance/core/offline_cache.dart';
import 'package:attendance/core/punch_queue.dart';
import 'package:attendance/core/session.dart';
import 'package:attendance/main.dart';
import 'package:attendance/screens/lock_screen.dart';
import 'package:attendance/screens/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

/// The biometric lock (B1.3).
///
/// Two things here are worth more than the happy path. A lock that can be
/// switched on without a check that passes locks its owner out of their own
/// app, and the only way back is a reinstall — which also throws away any
/// punch still queued for a signal. And a lock that engages every time the OS
/// borrows the foreground puts itself behind the biometric sheet it just
/// opened.
void main() {
  /// The English strings, standing in for what a screen would hand the lock.
  /// `AppLock` takes them as arguments rather than reading a global, so a test
  /// with no widget tree can still call it.
  final t = lookupAppLocalizations(const Locale('en'));

  /// An authenticator that answers whatever the test tells it to.
  late _FakeBiometrics sensor;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    sensor = _FakeBiometrics();
  });

  AppLock lock({DateTime Function()? clock}) => AppLock(
        authenticator: sensor,
        clock: clock ?? DateTime.now,
      );

  Future<String?> stored() =>
      const FlutterSecureStorage().read(key: AppLock.preferenceKey);

  group('turning it on', () {
    test('needs a check that actually passes', () async {
      sensor.outcome = BiometricOutcome.refused;

      final l = lock();
      final outcome = await l.enable(reason: t.lockPromptReason);

      expect(outcome, BiometricOutcome.refused);
      // The whole point of asking first: saving the preference here would put
      // the app behind a sensor that has just demonstrated it says no.
      expect(l.isEnabled, isFalse);
      expect(await stored(), isNull);

      l.dispose();
    });

    test('a sensor that cannot answer at all does not switch it on', () async {
      sensor.outcome = BiometricOutcome.unavailable;

      final l = lock();
      expect(await l.enable(reason: t.lockPromptReason), BiometricOutcome.unavailable);
      expect(l.isEnabled, isFalse);

      l.dispose();
    });

    test('a check that passes is remembered across launches', () async {
      final first = lock();
      expect(await first.enable(reason: t.lockPromptReason), BiometricOutcome.granted);
      expect(first.isEnabled, isTrue);
      first.dispose();

      // The app is force-quit and opened again.
      final second = lock();
      await second.load(signedIn: true);

      expect(second.isEnabled, isTrue);
      expect(second.isLocked, isTrue);

      second.dispose();
    });

    test('turning it off asks for nothing', () async {
      final l = lock();
      await l.enable(reason: t.lockPromptReason);
      expect(sensor.calls, 1);

      // The switch is on the far side of the lock already. A second check here
      // would be theatre.
      await l.disable();

      expect(sensor.calls, 1);
      expect(l.isEnabled, isFalse);
      expect(await stored(), isNull);

      l.dispose();
    });
  });

  group('at launch', () {
    test('nothing locks when nobody is signed in', () async {
      final l = lock();
      await l.enable(reason: t.lockPromptReason);
      await l.load(signedIn: false);

      // Otherwise the login screen itself would be held behind a check whose
      // preference belongs to a session that has already ended.
      expect(l.isLocked, isFalse);

      l.dispose();
    });

    test('with the preference off, a session opens straight through', () async {
      final l = lock();
      await l.load(signedIn: true);

      expect(l.isLocked, isFalse);
      expect(sensor.calls, 0);

      l.dispose();
    });
  });

  group('unlocking', () {
    test('a check that passes opens it', () async {
      final l = lock();
      await l.enable(reason: t.lockPromptReason);
      await l.load(signedIn: true);

      expect(await l.unlock(reason: t.lockPromptReason), BiometricOutcome.granted);
      expect(l.isLocked, isFalse);
      expect(l.failure, isNull);

      l.dispose();
    });

    test('a refusal keeps it shut and says so', () async {
      final l = lock();
      await l.enable(reason: t.lockPromptReason);
      await l.load(signedIn: true);

      sensor.outcome = BiometricOutcome.refused;
      expect(await l.unlock(reason: t.lockPromptReason), BiometricOutcome.refused);

      expect(l.isLocked, isTrue);
      expect(AppLock.messageFor(t, l.failure!), contains('Try again'));

      l.dispose();
    });

    test('a sensor that has stopped answering points at the password',
        () async {
      // Fingerprints removed, or face data reset, between one launch and the
      // next. There is no check left to pass, so the message has to name the
      // way out the lock screen offers — signing out — rather than telling
      // somebody to try a finger the phone has forgotten.
      final l = lock();
      await l.enable(reason: t.lockPromptReason);
      await l.load(signedIn: true);

      sensor.outcome = BiometricOutcome.unavailable;
      expect(await l.unlock(reason: t.lockPromptReason), BiometricOutcome.unavailable);

      expect(l.isLocked, isTrue);
      expect(AppLock.messageFor(t, l.failure!), contains('password'));

      l.dispose();
    });

    test('a lockout says that waiting is what helps', () async {
      final l = lock();
      await l.enable(reason: t.lockPromptReason);
      await l.load(signedIn: true);

      sensor.outcome = BiometricOutcome.lockedOut;
      await l.unlock(reason: t.lockPromptReason);

      expect(AppLock.messageFor(t, l.failure!), contains('Too many attempts'));

      l.dispose();
    });
  });

  group('coming back to it', () {
    /// A clock the test moves by hand.
    DateTime now = DateTime(2026, 9, 10, 9);
    DateTime clock() => now;

    setUp(() => now = DateTime(2026, 9, 10, 9));

    Future<AppLock> unlocked() async {
      final l = lock(clock: clock);
      await l.enable(reason: t.lockPromptReason);
      await l.load(signedIn: true);
      await l.unlock(reason: t.lockPromptReason);
      expect(l.isLocked, isFalse);
      return l;
    }

    test('a phone put down for a minute locks again', () async {
      final l = await unlocked();

      l.handleLifecycle(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 5));
      l.handleLifecycle(AppLifecycleState.resumed);

      expect(l.isLocked, isTrue);

      l.dispose();
    });

    test('a glance at the notification shade does not', () async {
      final l = await unlocked();

      // The OS backgrounds the app for its own dialogs — the location prompt
      // at the first punch, a document opening in another app. Locking behind
      // each of those puts a second prompt over the first.
      l.handleLifecycle(AppLifecycleState.paused);
      now = now.add(const Duration(seconds: 5));
      l.handleLifecycle(AppLifecycleState.resumed);

      expect(l.isLocked, isFalse);

      l.dispose();
    });

    test('inactive is not leaving', () async {
      final l = await unlocked();

      // `inactive` fires for the app switcher being opened and closed again,
      // and on iOS for a shade pulled halfway down.
      l.handleLifecycle(AppLifecycleState.inactive);
      now = now.add(const Duration(hours: 1));
      l.handleLifecycle(AppLifecycleState.resumed);

      expect(l.isLocked, isFalse);

      l.dispose();
    });

    test('the biometric sheet does not lock the app behind itself', () async {
      final l = lock(clock: clock);
      await l.enable(reason: t.lockPromptReason);
      await l.load(signedIn: true);

      // The system sheet backgrounds the app to draw itself, and somebody
      // taking their time over it is away for longer than the grace. Without
      // the in-flight guard the resume that follows a successful check would
      // lock the app the instant it opened.
      final gate = Completer<BiometricOutcome>();
      sensor.pending = gate;

      final pending = l.unlock(reason: t.lockPromptReason);
      l.handleLifecycle(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 5));

      gate.complete(BiometricOutcome.granted);
      await pending;

      l.handleLifecycle(AppLifecycleState.resumed);

      expect(l.isLocked, isFalse);

      l.dispose();
    });

    test('switching it on mid-session arms it there and then', () async {
      // `load` runs at launch, and signing in does not go through it. Without
      // arming here, somebody who signs in and turns the lock on in the same
      // run would not see it engage until the next cold start — the phone they
      // just secured would sit unlocked on the table all afternoon.
      final l = lock(clock: clock);
      await l.enable(reason: t.lockPromptReason);

      l.handleLifecycle(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 5));
      l.handleLifecycle(AppLifecycleState.resumed);

      expect(l.isLocked, isTrue);

      l.dispose();
    });

    test('with the lock off, nothing happens at all', () async {
      final l = lock(clock: clock);
      await l.load(signedIn: true);

      l.handleLifecycle(AppLifecycleState.paused);
      now = now.add(const Duration(days: 1));
      l.handleLifecycle(AppLifecycleState.resumed);

      expect(l.isLocked, isFalse);

      l.dispose();
    });
  });

  group('on the session', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('biometrics_test');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Map<String, dynamic> me() => {
          'user': {
            'id': 3,
            'name': 'James Smith',
            'email': 'james@acme.test',
            'roles': ['employee'],
            'permissions': ['view-attendance'],
            'employee': {
              'id': 1,
              'employee_code': 'EMP-0001',
              'full_name': 'James Smith',
              'is_manager': false,
            },
          },
        };

    ApiClient api() => ApiClient(
          client: MockClient((_) async => http.Response(
                jsonEncode({'ok': true, ...me()}),
                200,
                headers: {'content-type': 'application/json'},
              )),
        );

    Session session() => Session(
          api: api(),
          biometrics: sensor,
          cache: OfflineCache(directory: dir),
          queue: PunchQueue(directory: dir),
          locator: const PunchLocator(source: NoLocationSource()),
        );

    test('a launch with the lock on is locked before the splash lifts',
        () async {
      FlutterSecureStorage.setMockInitialValues({
        'hrms_api_token': 'tok',
        AppLock.preferenceKey: '1',
      });

      final s = session();
      await s.restore();

      expect(s.isSignedIn, isTrue);
      // Engaged inside restore, so the home shell is never drawn first — which
      // on a shared handset is the whole of what the lock is for.
      expect(s.lock.isLocked, isTrue);
      expect(s.isRestoring, isFalse);

      s.dispose();
    });

    test('signing out takes the preference with it', () async {
      FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});

      final s = session();
      await s.restore();
      await s.lock.enable(reason: t.lockPromptReason);
      expect(await stored(), '1');

      await s.logout();

      // It says "this phone is shared", which is a statement about the person
      // who set it. The next one to sign in here has not been asked.
      expect(await stored(), isNull);
      expect(s.lock.isEnabled, isFalse);
      expect(s.lock.isLocked, isFalse);

      s.dispose();
    });

    test('a lock change reaches anything listening to the session', () async {
      FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});

      final s = session();
      await s.restore();

      var heard = 0;
      s.addListener(() => heard++);

      await s.lock.enable(reason: t.lockPromptReason);

      // Locking and signing out are the same event to every widget above the
      // shell: the thing on screen has to be replaced.
      expect(heard, greaterThan(0));

      s.dispose();
    });
  });

  group('on screen', () => _screens(() => sensor));
}

/// The two screens the lock is visible on.
///
/// Every disk touch happens inside `runAsync`: `testWidgets` runs in a
/// fake-async zone that never delivers a real file completion, so a `pump` that
/// reaches the cache or the queue hangs the run rather than failing it.
void _screens(_FakeBiometrics Function() sensorOf) {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('biometrics_screen_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Map<String, dynamic> employee() => {
        'user': {
          'id': 3,
          'name': 'James Smith',
          'email': 'james@acme.test',
          'roles': ['employee'],
          'permissions': ['view-attendance'],
          'employee': {
            'id': 1,
            'employee_code': 'EMP-0001',
            'full_name': 'James Smith',
            'is_manager': false,
          },
        },
      };

  /// Signed in from the saved copy, so the screen is drawn without a server.
  Future<Session> primed(WidgetTester tester) async {
    late Session session;

    await tester.runAsync(() async {
      final store = OfflineCache(directory: dir);
      await store.write(OfflineCache.keyProfile, employee());

      final queue = PunchQueue(directory: dir);
      await queue.load();

      session = Session(
        api: ApiClient(
          client: MockClient((_) async => throw const SocketException('offline')),
        ),
        biometrics: sensorOf(),
        cache: store,
        queue: queue,
        locator: const PunchLocator(source: NoLocationSource()),
      );
      await session.restore();
    });

    return session;
  }

  Widget app(Session session, Widget child) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocale.supported,
        home: SessionScope(notifier: session, child: child),
      );

  /// The profile screen is a `ListView`, which builds only what fits. On the
  /// default 800×600 test surface the buttons below the info cards are never
  /// constructed at all, so a finder for one reports it missing rather than
  /// off-screen.
  Future<void> tallScreen(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  testWidgets('the lock screen offers a way past a sensor that says no',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      'hrms_api_token': 'tok',
      AppLock.preferenceKey: '1',
    });

    final session = await primed(tester);
    expect(session.lock.isLocked, isTrue);

    sensorOf().outcome = BiometricOutcome.unavailable;

    await tester.pumpWidget(app(session, const LockScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Asked on its own, without a button press to be shown a system sheet.
    expect(sensorOf().calls, 1);

    // And when it cannot answer, the escape is on screen. Without it a phone
    // whose fingerprints were removed is an app that can be neither opened nor
    // signed out of, and the only route back is a reinstall — which throws
    // away any punch still waiting for a signal.
    expect(find.text('Sign out instead'), findsOneWidget);
    expect(find.textContaining('Sign in with your password'), findsOneWidget);
    // Named, so a shared handset says whose session is behind the lock.
    expect(find.textContaining('James Smith'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('the settings switch is drawn only where there is a sensor',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});

    await tallScreen(tester);

    sensorOf().available = false;

    final session = await primed(tester);

    await tester.pumpWidget(app(session, const ProfileScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // A row offering fingerprint unlock on a phone with nothing but a PIN
    // would prompt for that PIN and call it a fingerprint.
    expect(find.text('Unlock with biometrics'), findsNothing);
    expect(find.text('Change password'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('and is drawn where there is one', (tester) async {
    FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});

    await tallScreen(tester);

    final session = await primed(tester);

    await tester.pumpWidget(app(session, const ProfileScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Unlock with biometrics'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isFalse);

    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });
}

class _FakeBiometrics implements BiometricAuthenticator {
  bool available = true;
  BiometricOutcome outcome = BiometricOutcome.granted;
  int calls = 0;

  /// When set, [authenticate] waits on this instead of answering — a system
  /// sheet left open on screen.
  Completer<BiometricOutcome>? pending;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<BiometricOutcome> authenticate(String reason) async {
    calls++;
    final gate = pending;
    if (gate != null) {
      pending = null;
      return gate.future;
    }
    return outcome;
  }
}
