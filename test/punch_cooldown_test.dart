import 'dart:convert';
import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/locale.dart';
import 'package:attendance/core/location.dart';
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

/// The clock screen lets go of the cooldown on its own.
///
/// `/attendance/today` says only *that* the duplicate-punch cooldown is
/// running (`can_check: false`), never when it ends, and nothing used to ask
/// again — so after every punch the buttons sat grey under "still registering"
/// until somebody pulled to refresh. Found on a handset: somebody going on a
/// break waited over a minute at a screen that looked frozen.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('punch_cooldown_test');
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

  /// Today, clocked in. The date is the handset's own so the saved copy is
  /// never refused as yesterday's.
  Map<String, dynamic> today({required bool canCheck}) {
    final now = DateTime.now();
    final date = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';

    return {
      'ok': true,
      'date': date,
      'next_action': 'out',
      'is_clocked_in': true,
      'on_break': false,
      'can_check': canCheck,
      'can_break': canCheck,
      'next_break_action': 'start',
      'worked_minutes': 60,
      'punches': const <Map<String, dynamic>>[],
      'shift': null,
      'is_day_off': false,
      'holiday': null,
      'leave': null,
    };
  }

  /// A server whose cooldown lasts for the first [coolingFor] answers.
  Future<(Session, List<int>)> signedIn(
    WidgetTester tester, {
    required int coolingFor,
  }) async {
    late Session session;
    final asked = <int>[0];

    await tester.runAsync(() async {
      final store = OfflineCache(directory: dir);
      await store.write(OfflineCache.keyProfile, me());

      final queue = PunchQueue(directory: dir);
      await queue.load();

      session = Session(
        api: ApiClient(
          client: MockClient((request) async {
            final Map<String, dynamic> body;
            if (request.url.path.contains('/attendance/today')) {
              asked[0]++;
              body = today(canCheck: asked[0] > coolingFor);
            } else {
              body = {'ok': true, ...me()};
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
        locator: const PunchLocator(source: NoLocationSource()),
      );

      await session.restore();
    });

    return (session, asked);
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

  const cooling = 'Just a moment — your last punch is still registering';

  testWidgets('the buttons come back without anybody refreshing',
      (tester) async {
    final (session, asked) = await signedIn(tester, coolingFor: 1);
    await pumpClock(tester, session);

    expect(find.text(cooling), findsOneWidget);
    expect(asked[0], 1);

    await tester.pump(const Duration(seconds: 10));
    await settle(tester);

    expect(asked[0], 2, reason: 'the screen should have asked again');
    expect(find.text(cooling), findsNothing);

    session.dispose();
  });

  testWidgets('it keeps asking for as long as the cooldown runs',
      (tester) async {
    final (session, asked) = await signedIn(tester, coolingFor: 3);
    await pumpClock(tester, session);

    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 10));
      await settle(tester);
    }

    expect(asked[0], 4);
    expect(find.text(cooling), findsNothing);

    session.dispose();
  });

  testWidgets('nothing is polled when there is no cooldown', (tester) async {
    final (session, asked) = await signedIn(tester, coolingFor: 0);
    await pumpClock(tester, session);

    await tester.pump(const Duration(seconds: 25));
    await settle(tester);

    // One answer, and it said the buttons were free. The 30-second worked-time
    // ticker is a repaint, not a request.
    expect(asked[0], 1);

    session.dispose();
  });
}
