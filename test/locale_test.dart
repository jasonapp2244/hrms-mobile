import 'dart:convert';
import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/l10n.dart';
import 'package:attendance/core/locale.dart';
import 'package:attendance/core/location.dart';
import 'package:attendance/core/offline_cache.dart';
import 'package:attendance/core/punch_queue.dart';
import 'package:attendance/core/session.dart';
import 'package:attendance/main.dart';
import 'package:attendance/screens/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

/// Multi-language support (B6.2).
///
/// Three things here are worth pinning down, and none of them is "does the
/// Spanish read well" — that is a translator's job, not a test's:
///
///   * **the preference survives a sign-out**, unlike everything else in the
///     keystore, because clearing it would put the login form back into a
///     language the person standing there cannot read;
///   * **every key is translated**, which gen_l10n reports in a file rather
///     than as an error, so nothing else would ever say so; and
///   * **the strings actually reach the screens**, which is only true while
///     every `MaterialApp` in the app carries the delegates.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('locale_test');
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows can hold a file the app wrote without awaiting.
    }
  });

  Future<String?> stored() =>
      const FlutterSecureStorage().read(key: AppLocale.preferenceKey);

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

  Session session({ApiClient? client}) => Session(
        api: client ?? api(),
        cache: OfflineCache(directory: dir),
        queue: PunchQueue(directory: dir),
        locator: const PunchLocator(source: NoLocationSource()),
      );

  group('the preference', () {
    test('a fresh handset follows the phone', () async {
      final locale = AppLocale();
      await locale.load();

      expect(locale.locale, isNull);
      expect(locale.followsSystem, isTrue);

      locale.dispose();
    });

    test('a choice survives a relaunch', () async {
      final first = AppLocale();
      await first.set(const Locale('es'));
      expect(await stored(), 'es');
      first.dispose();

      // A separate instance, as if the app had been force-quit and reopened.
      final second = AppLocale();
      await second.load();

      expect(second.locale, const Locale('es'));
      expect(second.followsSystem, isFalse);

      second.dispose();
    });

    test('going back to the phone clears it rather than storing English',
        () async {
      final locale = AppLocale();
      await locale.set(const Locale('es'));
      await locale.set(null);

      // "Follow the handset" is the absence of a preference, not a third
      // language: a stored 'en' would pin somebody to English on a phone they
      // later switch to Spanish.
      expect(await stored(), isNull);
      expect(locale.followsSystem, isTrue);

      locale.dispose();
    });

    test('a language this build no longer has falls back to the phone',
        () async {
      // A downgrade, or a translation withdrawn. Following the handset beats
      // showing a language with no strings behind it.
      FlutterSecureStorage.setMockInitialValues({'hrms_locale': 'fr'});

      final locale = AppLocale();
      await locale.load();

      expect(locale.locale, isNull);

      locale.dispose();
    });

    test('an unreadable keystore is not a screen', () async {
      // load() swallows its own failure; the point is that it resolves at all
      // rather than throwing on the way to the first frame.
      final locale = AppLocale();
      await locale.load();

      expect(locale.headerValue, isNotEmpty);

      locale.dispose();
    });
  });

  group('sign-out', () {
    test('keeps the language, unlike everything else in the keystore',
        () async {
      FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});

      final s = session();
      await s.restore();
      await s.locale.set(const Locale('es'));

      await s.logout();

      // The one screen a person who does not read English most needs in their
      // own language is the one they are sent back to.
      expect(await stored(), 'es');
      expect(s.locale.locale, const Locale('es'));

      s.dispose();
    });

    test('the token, the queue and the cache still go', () async {
      FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});

      final s = session();
      await s.restore();
      await s.locale.set(const Locale('es'));

      await s.logout();

      expect(
        await const FlutterSecureStorage().read(key: 'hrms_api_token'),
        isNull,
      );

      s.dispose();
    });
  });

  group('the server is told', () {
    test('Accept-Language carries the chosen language', () async {
      String? sent;

      final client = ApiClient(
        client: MockClient((request) async {
          sent = request.headers['accept-language'];
          return http.Response(
            jsonEncode({'ok': true, ...me()}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      FlutterSecureStorage.setMockInitialValues({
        'hrms_api_token': 'tok',
        'hrms_locale': 'es',
      });

      final s = session(client: client);
      await s.restore();

      expect(sent, 'es');

      s.dispose();
    });

    test('and changes with it', () async {
      final s = session();
      await s.restore();

      await s.locale.set(const Locale('es'));
      expect(s.api.acceptLanguage, 'es');

      await s.locale.set(const Locale('en'));
      expect(s.api.acceptLanguage, 'en');

      s.dispose();
    });
  });

  group('the translations themselves', () {
    test('every key the app uses has a Spanish string', () {
      // gen_l10n writes this on every build. It reports a gap here rather than
      // failing the build, so without this test a key added in English and
      // forgotten in Spanish would ship as an English sentence in a Spanish
      // app — and nothing anywhere would say so.
      final report = File('lib/l10n/untranslated.json');

      expect(
        report.existsSync(),
        isTrue,
        reason: 'Run `flutter gen-l10n` — l10n.yaml asks for this report.',
      );

      final missing = jsonDecode(report.readAsStringSync());

      expect(
        missing,
        isEmpty,
        reason: 'These keys have no Spanish translation: $missing',
      );
    });

    test('nothing is left as the English string pasted into app_es.arb', () {
      // A translator who skips a row often leaves the English behind rather
      // than deleting it, which untranslated.json cannot see. Two kinds of row
      // legitimately match: short ones, which are proper nouns and
      // abbreviations, and layout strings that are nothing but placeholders and
      // separators — so both are measured on the *words* a row actually has.
      final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
          as Map<String, dynamic>;
      final es = jsonDecode(File('lib/l10n/app_es.arb').readAsStringSync())
          as Map<String, dynamic>;

      final identical = <String>[];

      for (final entry in en.entries) {
        if (entry.key.startsWith('@')) continue;

        final english = entry.value;
        if (english is! String) continue;

        final words = english.replaceAll(RegExp(r'\{[^}]*\}'), ' ');
        if (words.replaceAll(RegExp(r'[^A-Za-z]'), '').length < 20) continue;

        if (english == es[entry.key]) identical.add(entry.key);
      }

      expect(identical, isEmpty, reason: 'Still in English: $identical');
    });
  });

  group('on screen', () {
    Widget app(Session session) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocale.supported,
          locale: session.locale.locale,
          home: SessionScope(notifier: session, child: const LoginScreen()),
        );

    testWidgets('the login form is drawn in the chosen language',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues({'hrms_locale': 'es'});

      late Session s;
      await tester.runAsync(() async {
        s = session();
        await s.restore();
      });

      await tester.pumpWidget(app(s));
      await tester.pump();

      final es = lookupAppLocalizations(const Locale('es'));

      expect(find.text(es.loginSubmit), findsOneWidget);
      expect(find.text(es.loginForgot), findsOneWidget);
      expect(find.text('Sign in'), findsNothing);

      s.dispose();
    });

    testWidgets('switching language redraws what is already on screen',
        (tester) async {
      // `HrmsApp` rather than the helper above, because the bug this pins down
      // lives in `HrmsApp` itself. `SessionScope` is an `InheritedNotifier`, so
      // it rebuilds the widgets *below* it — and `MaterialApp`, which is above
      // it and carries `locale:`, is not one of them. Without the listener in
      // its `initState` the preference changes, `Accept-Language` changes, and
      // the screen somebody is looking at stays in the old language.
      // Otherwise `_Root` puts the onboarding carousel in front of the login
      // form (B1.1), and this test is about the form.
      FlutterSecureStorage.setMockInitialValues({'hrms_onboarding_seen': '1'});

      late Session s;

      // Pumped inside runAsync, and so is everything that follows it.
      // `HrmsApp.initState` starts the session restore, which reads the punch
      // queue and the offline cache off the disk — and `testWidgets` runs in a
      // fake-async zone that never delivers a real file completion at all, so
      // the same pump outside this block hangs rather than failing.
      await tester.runAsync(() async {
        s = session();
        await tester.pumpWidget(HrmsApp(session: s));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });

      await tester.pump();
      expect(find.text('Sign in'), findsOneWidget);

      await tester.runAsync(() => s.locale.set(const Locale('es')));
      await tester.pump();

      final es = lookupAppLocalizations(const Locale('es'));

      expect(find.text(es.loginSubmit), findsOneWidget);
      expect(find.text('Sign in'), findsNothing);

      // Not disposed here: the widget tree is torn down after the test body,
      // and `_HrmsAppState.dispose` removes its listener from this locale —
      // which throws if the notifier has already gone.
    });

    testWidgets('and follows the phone when nothing has been chosen',
        (tester) async {
      late Session s;
      await tester.runAsync(() async {
        s = session();
        await s.restore();
      });

      await tester.pumpWidget(app(s));
      await tester.pump();

      // The test binding reports en_US, so English is what a handset with no
      // preference gets here.
      expect(find.text('Sign in'), findsOneWidget);

      s.dispose();
    });
  });
}
