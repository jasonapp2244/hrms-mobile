import 'dart:convert';
import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/l10n.dart';
import 'package:attendance/core/locale.dart';
import 'package:attendance/core/location.dart';
import 'package:attendance/core/offline_cache.dart';
import 'package:attendance/core/punch_queue.dart';
import 'package:attendance/core/quick_actions.dart';
import 'package:attendance/core/session.dart';
import 'package:attendance/core/theme.dart';
import 'package:attendance/l10n/generated/app_localizations.dart';
import 'package:attendance/main.dart';
import 'package:attendance/screens/punch_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/settle.dart';

/// The launcher shortcut that clocks somebody in (B2.8).
///
/// Long-press the app icon, tap one item, and the punch is made. The whole
/// feature is a convenience wrapped around a button that already worked, and
/// that shapes every rule below: it is allowed to be absent, it is not allowed
/// to be wrong.
///
/// Four properties are what this file is really about.
///
/// **The label is translated and the identifier is not.** The OS keeps the
/// `type` string on the launcher between runs and hands it straight back, so a
/// type that changed with the language would come back unrecognisable — trap 18
/// in `CLAUDE.md`, and the shortcut is the only place in this app where a
/// string outlives the process that wrote it.
///
/// **A tap made before the app exists is held, not dropped.** Launching from
/// the shortcut *is* the feature, so the tap always arrives while the first
/// `/attendance/today` is still in flight. Dropping it there would leave B2.8
/// working only when the app was already open, which is when nobody needs it.
///
/// **One shortcut, matching the day.** The server decides the direction of a
/// punch from the ones before it, so a menu offering both would let somebody
/// pick the one that is not true and still succeed — a label that lied about
/// what it did.
///
/// **It comes off the launcher on sign-out.** A shared work handset is the
/// case: a "Clock out" left behind by the last person is one tap from clocking
/// out the next one, and it sits there whether or not the app is running.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('quick_actions_test');
    FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});
  });

  tearDown(() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows can still hold a file the cache wrote without the test
      // awaiting it. Harness tidying, not the thing under test.
    }
  });

  group('the wire value is an identifier', () {
    test('each action parses back from the string it publishes', () {
      for (final action in QuickAction.values) {
        expect(QuickAction.parse(action.wireValue), action);
      }
    });

    test('a string this build has never seen opens the app normally', () {
      // The launcher holds whatever the *previous* build published. A rename,
      // or a downgrade, hands this code a type of its own that it no longer
      // recognises — and the honest answer is to open the app rather than to
      // guess which punch was meant.
      expect(QuickAction.parse('clock_sideways'), isNull);
      expect(QuickAction.parse(null), isNull);
      expect(QuickAction.parse(42), isNull);
    });

    test('the direction is read from the same next_action the button reads', () {
      expect(
        QuickAction.forNextPunch(willClockIn: true),
        QuickAction.clockIn,
      );
      expect(
        QuickAction.forNextPunch(willClockIn: false),
        QuickAction.clockOut,
      );
    });
  });

  group('what goes on the launcher', () {
    test('one item, carrying the wire value and the translated title', () async {
      final provider = _RecordingProvider();
      final actions = QuickActionService(provider: provider);

      await actions.publish(willClockIn: true, title: 'Fichar entrada');

      expect(provider.posts, hasLength(1));
      expect(provider.posts.single, hasLength(1));

      // The half the person reads is Spanish; the half the OS hands back is
      // not. Publishing the title as the type would come back as a string
      // `parse` has never heard of the moment somebody switches language.
      expect(provider.posts.single.single.title, 'Fichar entrada');
      expect(provider.posts.single.single.type, 'clock_in');

      actions.dispose();
    });

    test('never both directions at once', () async {
      final provider = _RecordingProvider();
      final actions = QuickActionService(provider: provider);

      await actions.publish(willClockIn: false, title: 'Check out');

      expect(provider.posts.single, hasLength(1));
      expect(provider.posts.single.single.type, 'clock_out');

      actions.dispose();
    });

    test('an unchanged day is not reposted', () async {
      final provider = _RecordingProvider();
      final actions = QuickActionService(provider: provider);

      // The Clock screen reloads on every return to the tab and on every
      // resume, so this runs constantly. Reposting an identical list makes the
      // launcher rebuild its menu for nothing.
      await actions.publish(willClockIn: true, title: 'Check in');
      await actions.publish(willClockIn: true, title: 'Check in');
      await actions.publish(willClockIn: true, title: 'Check in');

      expect(provider.posts, hasLength(1));

      actions.dispose();
    });

    test('a punch changes it, and so does a change of language', () async {
      final provider = _RecordingProvider();
      final actions = QuickActionService(provider: provider);

      await actions.publish(willClockIn: true, title: 'Check in');
      // Clocked in since.
      await actions.publish(willClockIn: false, title: 'Check out');
      // Same day, Spanish now. The title is part of what is published, so a
      // language switch has to reach the launcher too — it is the one piece of
      // this app's vocabulary that lives outside the app.
      await actions.publish(willClockIn: false, title: 'Fichar salida');

      expect(provider.posts, hasLength(3));
      expect(provider.posts[2].single.title, 'Fichar salida');
      expect(provider.posts[2].single.type, 'clock_out');

      actions.dispose();
    });
  });

  group('a tap', () {
    test('is recorded for the screen to act on', () async {
      final provider = _RecordingProvider();
      final actions = QuickActionService(provider: provider);
      await actions.start();

      expect(actions.pending.value, isNull);
      provider.tap('clock_in');
      expect(actions.pending.value, QuickAction.clockIn);

      actions.dispose();
    });

    test('on an unrecognised shortcut leaves nothing waiting', () async {
      final provider = _RecordingProvider();
      final actions = QuickActionService(provider: provider);
      await actions.start();

      provider.tap('clock_sideways');

      // Not "opens the app on whatever it can find" — nothing is pending, so
      // the app launches normally and the person uses the button.
      expect(actions.pending.value, isNull);

      actions.dispose();
    });

    test('listening starts once, however many times it is asked for', () async {
      final provider = _RecordingProvider();
      final actions = QuickActionService(provider: provider);

      // `start` runs on every launch and every sign-in.
      await actions.start();
      await actions.start();
      await actions.start();

      expect(provider.initialisations, 1);

      actions.dispose();
    });
  });

  group('signing out', () {
    test('takes the shortcut off the launcher and drops the tap', () async {
      final provider = _RecordingProvider();
      final actions = QuickActionService(provider: provider);
      await actions.start();
      await actions.publish(willClockIn: true, title: 'Check in');
      provider.tap('clock_in');

      await actions.withdraw();

      expect(provider.clears, 1);
      // The tap belonged to whoever made it. Carrying it across a sign-out
      // would punch for the next person on a shared handset.
      expect(actions.pending.value, isNull);

      actions.dispose();
    });

    test('the next publish is not swallowed as a repeat', () async {
      final provider = _RecordingProvider();
      final actions = QuickActionService(provider: provider);

      await actions.publish(willClockIn: true, title: 'Check in');
      await actions.withdraw();
      // The same item as before, but the launcher no longer has it — so the
      // "do not repost an identical list" shortcut must not apply here.
      await actions.publish(willClockIn: true, title: 'Check in');

      expect(provider.posts, hasLength(2));

      actions.dispose();
    });
  });

  group('on the Clock screen', () {
    testWidgets('a day off the clock publishes Check in', (tester) async {
      final provider = _RecordingProvider();
      final session = await _signedIn(tester, dir, today(clockedIn: false),
          actions: provider);
      await _pumpClock(tester, session);

      expect(provider.posts.last.single.type, 'clock_in');
      expect(provider.posts.last.single.title, 'Check in');

      session.dispose();
    });

    testWidgets('a day on the clock publishes Check out', (tester) async {
      final provider = _RecordingProvider();
      final session = await _signedIn(tester, dir, today(clockedIn: true),
          actions: provider);
      await _pumpClock(tester, session);

      expect(provider.posts.last.single.type, 'clock_out');
      expect(provider.posts.last.single.title, 'Check out');

      session.dispose();
    });

    testWidgets('the title follows the language and the type does not',
        (tester) async {
      final provider = _RecordingProvider();
      final session = await _signedIn(tester, dir, today(clockedIn: false),
          actions: provider);
      await _pumpClock(tester, session, locale: const Locale('es'));

      expect(provider.posts.last.single.title, 'Fichar entrada');

      // The whole point. A Spanish handset publishes a Spanish label and an
      // English identifier, because the identifier is not a word.
      expect(provider.posts.last.single.type, 'clock_in');

      session.dispose();
    });

    testWidgets('a tap made before the app existed still punches',
        (tester) async {
      final posted = <String>[];
      final provider = _RecordingProvider();
      final session = await _signedIn(
        tester,
        dir,
        today(clockedIn: false),
        actions: provider,
        onPost: posted.add,
      );

      // The cold launch, which is the normal way this feature is used: the OS
      // resolved the tap while the app was still starting, so the value is
      // already waiting before any screen is built.
      session.actions.pending.value = QuickAction.clockIn;

      await _pumpClock(tester, session);

      expect(posted.where(_isCheck), isNotEmpty);
      // Spent, not left to fire again on the next refresh.
      expect(session.actions.pending.value, isNull);

      session.dispose();
    });

    testWidgets('a tap while the app is open punches too', (tester) async {
      final posted = <String>[];
      final provider = _RecordingProvider();
      final session = await _signedIn(
        tester,
        dir,
        today(clockedIn: true),
        actions: provider,
        onPost: posted.add,
      );
      await _pumpClock(tester, session);

      expect(posted.where(_isCheck), isEmpty);

      provider.tap('clock_out');
      await settle(tester);

      expect(posted.where(_isCheck), isNotEmpty);

      session.dispose();
    });

    testWidgets('the cooldown refuses the shortcut as it refuses the button',
        (tester) async {
      final posted = <String>[];
      final provider = _RecordingProvider();
      final session = await _signedIn(
        tester,
        dir,
        // can_check false is the duplicate-punch cooldown. The button is greyed
        // in this state; the shortcut has to obey the same rule, or B2.8 would
        // be a way round the one guard that stops a double punch.
        today(clockedIn: false, canCheck: false),
        actions: provider,
        onPost: posted.add,
      );
      await _pumpClock(tester, session);

      provider.tap('clock_in');
      await settle(tester);

      expect(posted.where(_isCheck), isEmpty);
      // Spent regardless. A tap that could not be acted on must not sit in the
      // notifier and fire minutes later, when the cooldown clears.
      expect(session.actions.pending.value, isNull);

      session.dispose();
    });
  });
}

/// A punch actually left the handset.
///
/// Matched on the suffix rather than the whole path: the client prefixes
/// `/api/v1`, and a test that hardcoded that would fail on the day the API is
/// versioned rather than on the day this feature breaks.
bool _isCheck(String path) => path.endsWith('/attendance/check');

/// Today, off or on the clock.
Map<String, dynamic> today({required bool clockedIn, bool canCheck = true}) => {
      'ok': true,
      'date': '2026-09-15',
      'next_action': clockedIn ? 'out' : 'in',
      'is_clocked_in': clockedIn,
      'on_break': false,
      'can_check': canCheck,
      'can_break': false,
      'next_break_action': 'start',
      'worked_minutes': clockedIn ? 120 : 0,
      'punches': const <Map<String, dynamic>>[],
      'shift': null,
      'is_day_off': false,
      'holiday': null,
      'leave': null,
    };

Map<String, dynamic> _me() => {
      'user': {
        'id': 3,
        'name': 'Ann Lee',
        'email': 'ann@acme.test',
        'roles': ['employee'],
        'permissions': ['view-attendance'],
        'employee': {
          'id': 1,
          'employee_code': 'E1',
          'full_name': 'Ann Lee',
          'is_manager': false,
        },
      },
    };

Future<Session> _signedIn(
  WidgetTester tester,
  Directory dir,
  Map<String, dynamic> status, {
  required QuickActionProvider actions,
  void Function(String path)? onPost,
}) async {
  late Session session;

  await tester.runAsync(() async {
    final store = OfflineCache(directory: dir);
    await store.write(OfflineCache.keyProfile, _me());

    final queue = PunchQueue(directory: dir);
    await queue.load();

    session = Session(
      api: ApiClient(
        client: MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'POST') onPost?.call(path);

          final Map<String, dynamic> body;
          if (path.contains('/attendance/check')) {
            body = {
              'ok': true,
              'message': 'Checked in at 09:02',
              'punch': {
                'id': 9,
                'type': 'in',
                'status': 'present',
                'time': '09:02',
              },
            };
          } else if (path.contains('/attendance/today')) {
            body = status;
          } else {
            body = {'ok': true, ..._me()};
          }

          return http.Response(
            jsonEncode(body),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      ),
      cache: store,
      queue: queue,
      quickActions: actions,
      locator: const PunchLocator(source: NoLocationSource()),
    );

    await session.restore();
  });

  return session;
}

Future<void> _pumpClock(
  WidgetTester tester,
  Session session, {
  Locale? locale,
}) async {
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.binding.setSurfaceSize(const Size(390, 900));

  await tester.pumpWidget(SessionScope(
    notifier: session,
    child: MaterialApp(
      theme: AppTheme.light(),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocale.supported,
      home: PunchScreen(visible: ValueNotifier(true)),
    ),
  ));
  await settle(tester);
}

/// A launcher that remembers what it was handed.
///
/// Stands in for the platform channel the same way the fake `PushProvider` and
/// `LocationSource` do — a headless test has no home screen to long-press.
class _RecordingProvider implements QuickActionProvider {
  final List<List<QuickActionItem>> posts = [];
  int clears = 0;
  int initialisations = 0;

  void Function(String type)? _onSelected;

  @override
  Future<void> initialize(void Function(String type) onSelected) async {
    initialisations++;
    _onSelected = onSelected;
  }

  @override
  Future<void> setItems(List<QuickActionItem> items) async => posts.add(items);

  @override
  Future<void> clearItems() async => clears++;

  /// Somebody long-pressed the icon and chose this item.
  void tap(String type) => _onSelected?.call(type);
}
