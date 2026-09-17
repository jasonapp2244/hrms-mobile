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

/// The month grid on the attendance history (B3.4).
///
/// The list beside it already refuses to build a window from the handset's
/// clock — `history_window_test` is the record of why. A calendar is the same
/// hazard with more surface: it names a month in a heading, draws a box for
/// every day in it, and rings one of them as today. Every one of those is a
/// date, and not one of them may come from `DateTime.now()`.
///
/// So the mock server below lives in **April 2025**, nowhere near the device
/// running the tests. A grid built from the handset would open on the real
/// current month, ask for its days, and fail here on the first expectation
/// rather than passing quietly for eleven months of the year.
void main() {
  late List<String> asked;
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('history_calendar_test');
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // The cache writes without the test awaiting it, so on Windows the file
      // can still be held open when the test ends. Harness tidying, not the
      // thing under test.
    }
  });

  /// The company's today. Fixed, and deliberately in neither the month nor the
  /// year the test machine is in.
  final serverToday = DateTime(2025, 4, 10);

  String iso(DateTime d) => d.toIso8601String().substring(0, 10);

  /// One row per day, as `AttendanceController::history` builds them: newest
  /// first, one 'absent' and one late arrival so the grid has something other
  /// than a run of green to draw.
  List<Map<String, dynamic>> daysBetween(DateTime from, DateTime to) {
    final days = <Map<String, dynamic>>[];

    for (var d = to; !d.isBefore(from); d = d.subtract(const Duration(days: 1))) {
      final date = iso(d);
      final absent = date == '2025-04-07';
      final late = date == '2025-04-03';

      days.add({
        'date': date,
        'weekday': const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1],
        'status': absent ? 'absent' : 'present',
        'late': late,
        'first_in': absent ? null : '${date}T09:0${late ? 5 : 0}:00+05:00',
        'last_out': absent ? null : '${date}T17:30:00+05:00',
        'worked_minutes': absent ? 0 : 480,
        'punches': absent ? 0 : 2,
        'holiday': null,
      });
    }

    return days;
  }

  Session calendarSession() {
    // Captured, not read back off `asked` inside the handler. `settle` gives
    // real time to the disk, so a request started by an earlier test can land
    // during a later one — and a handler that wrote to whatever `asked` points
    // at *now* would file that call under the test that is running, which
    // reads as the screen asking a question it never asked.
    final calls = asked = <String>[];

    final api = ApiClient(
      client: MockClient((request) async {
        calls.add('${request.url.path}?${request.url.query}');

        if (request.url.path.contains('/attendance/history')) {
          final q = request.url.queryParameters;

          // The real controller: `to` defaults to the company's today and is
          // clamped back to it, `from` defaults to 29 days before `to`, and
          // both ends are echoed.
          var to = q['to'] == null ? serverToday : DateTime.parse(q['to']!);
          if (to.isAfter(serverToday)) to = serverToday;

          final from = q['from'] == null
              ? to.subtract(const Duration(days: 29))
              : DateTime.parse(q['from']!);

          final days = daysBetween(from, to);

          return http.Response(
            jsonEncode({
              'ok': true,
              'from': iso(from),
              'to': iso(to),
              'days': days,
              'totals': {
                'present_days': days.where((d) => d['status'] == 'present').length,
                'late_days': days.where((d) => d['late'] == true).length,
                'leave_days': 0,
                'absent_days': days.where((d) => d['status'] == 'absent').length,
                'worked_minutes': days.fold<int>(0, (a, d) => a + (d['worked_minutes'] as int)),
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

  /// Open the grid. The screen starts as a list, which is where the only
  /// request that can learn the server's day is made.
  Future<void> openCalendar(WidgetTester tester) async {
    expect(find.byTooltip('Calendar view'), findsOneWidget,
        reason: 'no way to reach the calendar');
    await tester.tap(find.byTooltip('Calendar view'));
    // One settle for the toggle's reload, one for the reload that follows it
    // once a month has been named.
    await settle(tester);
    await settle(tester);
  }

  List<String> historyCalls() =>
      asked.where((u) => u.contains('/attendance/history')).toList();

  /// A cell is a number and a 15px glyph; which day it is and what happened on
  /// it are only spelled out in the semantics tree, which is off unless a test
  /// turns it on. That tree is also what a screen reader reads, so reaching for
  /// cells through it tests the accessible screen rather than working around
  /// the visible one.
  ///
  /// Disposed here rather than in `addTearDown`: the handle-leak check runs
  /// before the tear-downs do.
  Future<void> withSemantics(
    WidgetTester tester,
    Future<void> Function() body,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      // The tree is built on the next frame, not on the call above.
      await tester.pump();
      await body();
    } finally {
      handle.dispose();
    }
  }

  testWidgets('the month it opens on is the server\'s, named both ends',
      (tester) async {
    await pumpHistory(tester, calendarSession());
    await openCalendar(tester);

    // The one window this screen sends both ends of. `to` is the last day of
    // the month rather than today: the endpoint clamps it, and a month name in
    // the heading stays true when it does — unlike "Last 7 days".
    expect(historyCalls().last, contains('from=2025-04-01'));
    expect(historyCalls().last, contains('to=2025-04-30'));

    // The heading names it, in words rather than as the wire format.
    expect(find.text('April 2025'), findsOneWidget);

    // The regression this whole file exists for. A grid built from the handset
    // would have asked for the real current month.
    final device = DateTime.now();
    expect(
      historyCalls().last,
      isNot(contains('from=${device.year}-${device.month.toString().padLeft(2, '0')}-01')),
      reason: 'asked for the handset\'s month instead of the server\'s',
    );
  });

  testWidgets('there is no arrow into a month the company has not reached',
      (tester) async {
    await pumpHistory(tester, calendarSession());
    await openCalendar(tester);

    final forward = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.chevron_right),
        matching: find.byType(IconButton),
      ),
    );

    // Dead on the current month: the days after today have no attendance to
    // report, and a grid of empty cells reads as a month somebody failed to
    // turn up for.
    expect(forward.onPressed, isNull);
  });

  testWidgets('stepping back asks for the month before, and can come back',
      (tester) async {
    await pumpHistory(tester, calendarSession());
    await openCalendar(tester);

    await tester.tap(find.byIcon(Icons.chevron_left));
    await settle(tester);

    expect(historyCalls().last, contains('from=2025-03-01'));
    expect(historyCalls().last, contains('to=2025-03-31'));
    expect(find.text('March 2025'), findsOneWidget);

    // Forward is live now that there is somewhere to go.
    final forward = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.chevron_right),
        matching: find.byType(IconButton),
      ),
    );
    expect(forward.onPressed, isNotNull);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await settle(tester);

    expect(find.text('April 2025'), findsOneWidget);
  });

  testWidgets('a day the month has not reached is blank, not an absence',
      (tester) async {
    await pumpHistory(tester, calendarSession());
    await openCalendar(tester);

    await withSemantics(tester, () async {
      // The 10th is the company's today and came back with a row; the 11th
      // onwards is three weeks of April that have not happened yet. Neither
      // the grid nor the detail under it may call that an absence — it is a
      // day the employee could not have turned up for, and marking it against
      // them is a charge they have no way to answer.
      expect(find.bySemanticsLabel('11 Apr, No record'), findsOneWidget);
      expect(find.bySemanticsLabel('10 Apr, Present'), findsOneWidget);

      // And the two days the fixture made interesting, so the grid is reading
      // the status rather than painting everything the same.
      expect(find.bySemanticsLabel('7 Apr, Absent'), findsOneWidget);
      expect(find.bySemanticsLabel('3 Apr, Late'), findsOneWidget);
    });
  });

  testWidgets('tapping a day spells it out underneath', (tester) async {
    await pumpHistory(tester, calendarSession());
    await openCalendar(tester);

    await withSemantics(tester, () async {
      await tester.tap(find.bySemanticsLabel('7 Apr, Absent'));
      await settle(tester);

      // The same row the list draws, so there is one rendering of a day rather
      // than two to keep in agreement.
      expect(find.text('Absent'), findsWidgets);

      await tester.tap(find.bySemanticsLabel('11 Apr, No record'));
      await settle(tester);

      expect(find.text('11 April 2025'), findsOneWidget);
      expect(find.text('No record'), findsWidgets);
    });
  });

  testWidgets('going back to the list restores its own window', (tester) async {
    await pumpHistory(tester, calendarSession());
    await openCalendar(tester);

    // Through a past month on the way out, which is the part that used to do
    // the damage: March's reply says `to: 2025-03-31`, and taking that as the
    // day the company is on left the list asking for a window that ended three
    // weeks before today. The grid looked fine; the list it handed back did
    // not, and nothing connected the two.
    await tester.tap(find.byIcon(Icons.chevron_left));
    await settle(tester);

    expect(find.byTooltip('List view'), findsOneWidget);
    await tester.tap(find.byTooltip('List view'));
    await settle(tester);

    // 30 days counted back from the server's today, not a month — and still no
    // `to`, which is the list's own rule.
    expect(
      historyCalls().last,
      contains('from=${iso(serverToday.subtract(const Duration(days: 29)))}'),
      reason: 'calls: $asked',
    );
    expect(historyCalls().last, isNot(contains('to=')));
  });

  testWidgets('never names a day the company has not reached', (tester) async {
    await pumpHistory(tester, calendarSession());
    await openCalendar(tester);

    await tester.tap(find.byIcon(Icons.chevron_left));
    await settle(tester);

    // `to` is the exception and is allowed past today — the endpoint clamps it
    // and echoes what it used, which is what the heading and the grid read.
    // `from` never may be: a window starting after today comes back empty and
    // looks like a month with no attendance in it.
    for (final call in historyCalls()) {
      for (final match in RegExp(r'from=(\d{4}-\d{2}-\d{2})').allMatches(call)) {
        expect(
          DateTime.parse(match.group(1)!).isAfter(serverToday),
          isFalse,
          reason: '$call starts at ${match.group(1)}, past the company today ${iso(serverToday)}',
        );
      }
    }
  });
}
