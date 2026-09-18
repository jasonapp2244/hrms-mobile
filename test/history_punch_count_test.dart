import 'dart:convert';
import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/locale.dart';
import 'package:attendance/core/offline_cache.dart';
import 'package:attendance/core/session.dart';
import 'package:attendance/core/theme.dart';
import 'package:attendance/l10n/generated/app_localizations.dart';
import 'package:attendance/main.dart';
import 'package:attendance/screens/history_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/settle.dart';

/// A day with more than one in-and-out has to say so.
///
/// The two times on a history row are the **first** entry and the **last**
/// exit, and the total beside them is the sum of the stretches — which is not
/// the span between those two times. A day running 15:09 to 16:42 with an hour
/// away in the middle reads "In 15:09 · Out 16:42 · 22m", and every part of
/// that is correct while the row as a whole looks like broken arithmetic.
///
/// `punches` has been in the payload and in the app's model all along, parsed
/// and then dropped on the floor. Rendering it is the cheapest thing that makes
/// the row legible, and it is deliberately absent from an ordinary day so the
/// list does not grow a number that says "2" on every line.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('history_punch_count_test');
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // The cache writes without the test awaiting it; on Windows the file can
      // still be held open when the test ends. Harness tidying.
    }
  });

  final serverToday = DateUtils.dateOnly(
    DateTime.now().subtract(const Duration(days: 1)),
  );

  String iso(DateTime d) => d.toIso8601String().substring(0, 10);

  /// One history row, shaped as `AttendanceController::history` builds it.
  Map<String, dynamic> day(
    DateTime d, {
    required int punches,
    String status = 'present',
    int workedMinutes = 22,
  }) {
    final date = iso(d);
    final absent = status == 'absent';

    return {
      'date': date,
      'weekday': const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1],
      'status': status,
      'late': false,
      'first_in': absent ? null : '${date}T15:09:00+05:00',
      'last_out': absent ? null : '${date}T16:42:00+05:00',
      'worked_minutes': absent ? 0 : workedMinutes,
      'punches': punches,
      'holiday': null,
    };
  }

  Session sessionServing(List<Map<String, dynamic>> days) {
    final api = ApiClient(
      client: MockClient((request) async {
        if (request.url.path.contains('/attendance/history')) {
          return http.Response(
            jsonEncode({
              'ok': true,
              'from': iso(serverToday.subtract(const Duration(days: 29))),
              'to': iso(serverToday),
              'days': days,
              'totals': {
                'present_days': days.where((d) => d['status'] == 'present').length,
                'late_days': 0,
                'leave_days': 0,
                'absent_days': days.where((d) => d['status'] == 'absent').length,
                'worked_minutes':
                    days.fold<int>(0, (a, d) => a + (d['worked_minutes'] as int)),
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        return http.Response(
          jsonEncode({'ok': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    return Session(api: api, cache: OfflineCache(directory: dir));
  }

  Future<void> pumpHistory(WidgetTester tester, Session session) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocale.supported,
      home: SessionScope(
        notifier: session,
        child: HistoryScreen(visible: ValueNotifier(true)),
      ),
    ));
    await settle(tester);
  }

  testWidgets('a day with several in-and-outs says how many punches it had',
      (tester) async {
    await pumpHistory(tester, sessionServing([day(serverToday, punches: 8)]));

    expect(find.textContaining('8 punches'), findsOneWidget,
        reason: 'the row shows a 93-minute span against a 22m total and never '
            'explains why');
  });

  testWidgets('the count sits alongside the first entry and the last exit',
      (tester) async {
    await pumpHistory(tester, sessionServing([day(serverToday, punches: 6)]));

    // One Text, so the times and the count have to read as one sentence rather
    // than the count arriving detached from what it qualifies.
    expect(find.textContaining('In 15:09'), findsOneWidget);
    expect(find.textContaining('Out 16:42'), findsOneWidget);
    expect(find.textContaining('6 punches'), findsOneWidget);
  });

  testWidgets('an ordinary in-and-out day does not carry a count',
      (tester) async {
    await pumpHistory(tester, sessionServing([day(serverToday, punches: 2)]));

    // Two punches is the shape of nearly every day. A "2 punches" on all of
    // them would be noise that trains people to stop reading the line.
    expect(find.textContaining('punches'), findsNothing);
    expect(find.textContaining('In 15:09'), findsOneWidget);
  });

  testWidgets('a day nobody turned up to carries no count either',
      (tester) async {
    await pumpHistory(
      tester,
      sessionServing([
        day(serverToday, punches: 0, status: 'absent', workedMinutes: 0),
      ]),
    );

    expect(find.textContaining('punches'), findsNothing);
  });

  testWidgets('only the days that need the count get it', (tester) async {
    await pumpHistory(
      tester,
      sessionServing([
        day(serverToday, punches: 8),
        day(serverToday.subtract(const Duration(days: 1)), punches: 2),
        day(serverToday.subtract(const Duration(days: 2)), punches: 4),
      ]),
    );

    // Three days, two of them broken into stretches: the count appears twice
    // and not on the ordinary day between them.
    expect(find.textContaining('8 punches'), findsOneWidget);
    expect(find.textContaining('4 punches'), findsOneWidget);
    expect(find.textContaining('2 punches'), findsNothing);
  });
}
