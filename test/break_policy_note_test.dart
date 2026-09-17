import 'dart:convert';
import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/l10n.dart';
import 'package:attendance/core/locale.dart';
import 'package:attendance/core/location.dart';
// `show`, because models.dart exports a Directory of its own — the colleague
// directory (B3.8) — which otherwise shadows dart:io's.
import 'package:attendance/core/models.dart' show ShiftInfo;
import 'package:attendance/core/offline_cache.dart';
import 'package:attendance/core/punch_queue.dart';
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

/// What a break costs, said on the screen with the break button (A5.7).
///
/// The server has computed paid-versus-unpaid breaks since the policy shipped
/// and told nobody: `/attendance/today` carried the shift's name, window and
/// grace period but nothing about its break, so the app could not answer the
/// one question somebody has before pressing that button.
///
/// The line states the **consequence**, not the setting. "Unpaid" is a payroll
/// word; "comes off your hours" is what somebody deciding whether to take lunch
/// actually needs. The minimum rule gets its own wording because under it,
/// cutting a break short buys nothing — which changes what people do.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('break_policy_test');
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

  Map<String, dynamic> me() => {
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

  /// Today, on the clock, under a shift with the given break policy.
  Map<String, dynamic> today({
    int breakMinutes = 30,
    bool paid = false,
    bool minimum = false,
    bool withShift = true,
  }) =>
      {
        'ok': true,
        'date': '2026-09-15',
        'next_action': 'out',
        'is_clocked_in': true,
        'on_break': false,
        'can_check': true,
        'can_break': true,
        'next_break_action': 'start',
        'worked_minutes': 120,
        'punches': const <Map<String, dynamic>>[],
        'shift': withShift
            ? {
                'id': 1,
                'name': 'Day',
                'start_time': '09:00:00',
                'end_time': '17:00:00',
                'late_grace_minutes': 15,
                'crosses_midnight': false,
                'break_minutes': breakMinutes,
                'break_is_paid': paid,
                'break_is_minimum': minimum,
              }
            : null,
        'is_day_off': false,
        'holiday': null,
        'leave': null,
      };

  Future<Session> signedIn(WidgetTester tester, Map<String, dynamic> status) async {
    late Session session;

    await tester.runAsync(() async {
      final store = OfflineCache(directory: dir);
      await store.write(OfflineCache.keyProfile, me());

      final queue = PunchQueue(directory: dir);
      await queue.load();

      session = Session(
        api: ApiClient(
          client: MockClient((request) async {
            final body = request.url.path.contains('/attendance/today')
                ? status
                : {'ok': true, ...me()};

            return http.Response(
              jsonEncode(body),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
        cache: store,
        queue: queue,
        locator: const PunchLocator(source: NoLocationSource()),
      );

      await session.restore();
    });

    return session;
  }

  Future<void> pumpClock(WidgetTester tester, Session session) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 900));

    await tester.pumpWidget(SessionScope(
      notifier: session,
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocale.supported,
        home: PunchScreen(visible: ValueNotifier(true)),
      ),
    ));
    await settle(tester);
  }

  testWidgets('an unpaid break says it comes off your hours', (tester) async {
    final session = await signedIn(tester, today());
    await pumpClock(tester, session);

    expect(find.text('A 30-minute break comes off your hours.'), findsOneWidget);

    session.dispose();
  });

  testWidgets('a paid break says it stays on the clock', (tester) async {
    final session = await signedIn(tester, today(paid: true));
    await pumpClock(tester, session);

    expect(
      find.text('Your 30-minute break is paid — it stays on the clock.'),
      findsOneWidget,
    );

    session.dispose();
  });

  testWidgets('a minimum break says a shorter one buys nothing', (tester) async {
    final session = await signedIn(tester, today(minimum: true));
    await pumpClock(tester, session);

    // The rule that actually changes behaviour: under it there is no point
    // cutting lunch short, and nothing else on the screen would say so.
    expect(
      find.text('30 minutes comes off your hours, even if you take less.'),
      findsOneWidget,
    );

    session.dispose();
  });

  testWidgets('paid wins over minimum, the same way the payroll figure does',
      (tester) async {
    final session = await signedIn(tester, today(paid: true, minimum: true));
    await pumpClock(tester, session);

    expect(find.textContaining('is paid'), findsOneWidget);
    expect(find.textContaining('even if you take less'), findsNothing);

    session.dispose();
  });

  testWidgets('a shift with no break configured says nothing at all',
      (tester) async {
    final session = await signedIn(tester, today(breakMinutes: 0));
    await pumpClock(tester, session);

    // Better than "0 minutes, unpaid", which reads as a policy rather than as
    // the absence of one.
    expect(find.textContaining('comes off your hours'), findsNothing);
    expect(find.textContaining('is paid'), findsNothing);

    session.dispose();
  });

  testWidgets('a day with no shift at all says nothing', (tester) async {
    final session = await signedIn(tester, today(withShift: false));
    await pumpClock(tester, session);

    expect(find.textContaining('your hours'), findsNothing);

    session.dispose();
  });

  test('a saved copy from before the policy shipped reads as the old behaviour',
      () {
    // `/schedule` and `/team/*` do not carry the break policy either, and an
    // offline copy taken before A5.7 has no such keys. Defaulting to the old
    // behaviour means a screen shows nothing rather than something wrong.
    final old = ShiftInfo.fromJson(const {
      'name': 'Day',
      'start_time': '09:00:00',
      'end_time': '17:00:00',
    });

    expect(old.breakMinutes, 0);
    expect(old.breakIsPaid, isFalse);
    expect(old.breakIsMinimum, isFalse);
    expect(old.hasBreakPolicy, isFalse);
  });
}
