import 'dart:convert';
import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/l10n.dart';
import 'package:attendance/core/locale.dart';
import 'package:attendance/core/location.dart';
import 'package:attendance/core/offline_cache.dart';
import 'package:attendance/core/onboarding.dart';
import 'package:attendance/core/punch_queue.dart';
import 'package:attendance/core/session.dart';
import 'package:attendance/main.dart';
import 'package:attendance/screens/onboarding_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

/// The first-run introduction (B1.1).
///
/// The behaviour worth pinning is all about *when it does not appear*: an
/// introduction shown to somebody signing back in after a shift is an insult
/// rather than an introduction, and one that cannot be dismissed is a wall in
/// front of the login form.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('onboarding_test');
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows can hold a file the app wrote without awaiting.
    }
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

  ApiClient api({bool offline = false}) => ApiClient(
        client: MockClient((_) async {
          if (offline) throw const SocketException('offline');

          return http.Response(
            jsonEncode({'ok': true, ...me()}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

  Session session({ApiClient? client}) => Session(
        api: client ?? api(offline: true),
        cache: OfflineCache(directory: dir),
        queue: PunchQueue(directory: dir),
        locator: const PunchLocator(source: NoLocationSource()),
      );

  Future<String?> stored() =>
      const FlutterSecureStorage().read(key: Onboarding.preferenceKey);

  group('the flag', () {
    test('a fresh handset is pending', () async {
      expect(await Onboarding().isPending(), isTrue);
    });

    test('and stays settled once seen, across launches', () async {
      await Onboarding().markSeen();

      // A separate instance, as if the app had been force-quit and reopened.
      expect(await Onboarding().isPending(), isFalse);
      expect(await stored(), '1');
    });
  });

  group('when it appears', () {
    test('on a first launch with nobody signed in', () async {
      final s = session();
      await s.restore();

      expect(s.needsOnboarding, isTrue);

      s.dispose();
    });

    test('never for a session that restored', () async {
      // Somebody signed in on this handset has used it before, whatever the
      // keystore says. A wiped preference must not walk them through it again
      // on the way back in.
      FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});

      final s = session(client: api());
      await s.restore();

      expect(s.isSignedIn, isTrue);
      expect(s.needsOnboarding, isFalse);

      s.dispose();
    });

    test('not once it has been seen', () async {
      FlutterSecureStorage.setMockInitialValues({Onboarding.preferenceKey: '1'});

      final s = session();
      await s.restore();

      expect(s.needsOnboarding, isFalse);

      s.dispose();
    });

    test('finishing it settles the flag and tells the app', () async {
      final s = session();
      await s.restore();
      expect(s.needsOnboarding, isTrue);

      var heard = 0;
      s.addListener(() => heard++);

      await s.completeOnboarding();

      expect(s.needsOnboarding, isFalse);
      expect(await stored(), '1');
      // `_Root` reads this synchronously, so it has to be told to rebuild.
      expect(heard, greaterThan(0));

      s.dispose();
    });

    test('signing out does not bring it back', () async {
      // The flag describes the handset, not the account — unlike the punch
      // queue, the cache and the biometric preference, which all go with the
      // token.
      FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});

      final s = session(client: api());
      await s.restore();
      await s.completeOnboarding();

      await s.logout();

      expect(await stored(), '1');
      expect(await Onboarding().isPending(), isFalse);

      s.dispose();
    });
  });

  group('on screen', () {
    Widget app(Session s) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocale.supported,
          home: SessionScope(notifier: s, child: const OnboardingScreen()),
        );

    Future<Session> primed(WidgetTester tester) async {
      late Session s;

      await tester.runAsync(() async {
        final queue = PunchQueue(directory: dir);
        await queue.load();

        s = Session(
          api: api(offline: true),
          cache: OfflineCache(directory: dir),
          queue: queue,
          locator: const PunchLocator(source: NoLocationSource()),
        );
        await s.restore();
      });

      return s;
    }

    testWidgets('it opens on the first card, with a way past it',
        (tester) async {
      final s = await primed(tester);

      await tester.pumpWidget(app(s));
      await tester.pump();

      expect(find.text('One tap to clock in'), findsOneWidget);
      // The answer to the first question anybody asks about an attendance app.
      expect(find.textContaining('comes from the server'), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);
      expect(find.text('Next'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      s.dispose();
    });

    testWidgets('Next walks through to the end', (tester) async {
      final s = await primed(tester);

      await tester.pumpWidget(app(s));
      await tester.pump();

      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
      }

      expect(find.text('You will be told'), findsOneWidget);
      // The last card offers the finish rather than another Next.
      expect(find.text('Get started'), findsOneWidget);
      expect(find.text('Next'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      s.dispose();
    });

    testWidgets('Skip settles it as firmly as finishing does', (tester) async {
      // Skipping is a decision about this app, not a request to be asked again
      // next launch.
      final s = await primed(tester);
      expect(s.needsOnboarding, isTrue);

      await tester.pumpWidget(app(s));
      await tester.pump();

      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();

      expect(s.needsOnboarding, isFalse);
      expect(await stored(), '1');

      await tester.pumpWidget(const SizedBox());
      s.dispose();
    });
  });
}
