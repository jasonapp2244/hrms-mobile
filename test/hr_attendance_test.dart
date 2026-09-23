import 'dart:convert';
import 'dart:io' as io;

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/locale.dart';
import 'package:attendance/core/models.dart';
import 'package:attendance/core/offline_cache.dart';
import 'package:attendance/core/session.dart';
import 'package:attendance/core/theme.dart';
import 'package:attendance/l10n/generated/app_localizations.dart';
import 'package:attendance/main.dart';
import 'package:attendance/screens/hr_attendance_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/settle.dart';

/// HR reading one employee's attendance day by day.
///
/// **The mock server below lives in April 2025**, nowhere near the machine
/// running the tests, and that is the whole point of the file. The app must ask
/// for a *period* and take its dates from the reply; a screen that worked a
/// window out from `DateTime.now()` would ask for the real current month, get
/// April 2025 back, and fail here on the first expectation instead of passing
/// quietly for eleven months of the year.
///
/// It is the same rule `history_window_test` and `history_calendar_test` pin
/// for the employee's own history, and trap 30 in CLAUDE.md is the record of
/// the four times this codebase has paid for getting it wrong.
void main() {
  late List<String> asked;
  late io.Directory dir;

  setUp(() async {
    asked = [];
    dir = await io.Directory.systemTemp.createTemp('hr_attendance_test');
    FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});
  });

  tearDown(() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on io.FileSystemException {
      // The cache writes without the test awaiting it, so on Windows the file
      // can still be held when the directory is removed.
    }
  });

  /// One day of the shape `/hr/employees/{id}/attendance` returns.
  Map<String, dynamic> day({
    required String date,
    required String weekday,
    String status = 'present',
    bool late = false,
    bool earlyLeave = false,
    String? firstIn,
    String? lastOut,
    String? breakStart,
    String? breakEnd,
    int? breakCount,
    int? breakMinutes,
    int workedMinutes = 0,
    int punches = 0,
    String? remarks,
  }) => {
        'date': date,
        'weekday': weekday,
        'status': status,
        'late': late,
        'early_leave': earlyLeave,
        'first_in': firstIn,
        'last_out': lastOut,
        'break_start': breakStart,
        'break_end': breakEnd,
        if (breakCount != null) 'break_count': breakCount,
        'break_minutes': breakMinutes,
        'worked_minutes': workedMinutes,
        'punches': punches,
        'holiday': null,
        'shift': 'Morning Shift',
        'remarks': remarks,
      };

  Session hrSession({Map<String, dynamic>? reply}) => Session(
        cache: OfflineCache(directory: dir),
        api: ApiClient(
          client: MockClient((request) async {
            asked.add('${request.url.path}?${request.url.query}');

            if (request.url.path.endsWith('/auth/me')) {
              return _json({
                'ok': true,
                'user': {
                  'id': 1,
                  'name': 'HR Manager',
                  'email': 'hr@acme.test',
                  'roles': ['hr'],
                  'permissions': <String>[],
                  'can': {
                    'lead_team': false,
                    'decide_leave': true,
                    'view_employees': true,
                  },
                },
              });
            }

            if (request.url.path.contains('/attendance')) {
              return _json(reply ?? _emptyWindow());
            }

            return _json({'ok': true});
          }),
        ),
      );

  Future<void> pump(WidgetTester tester, Session session) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 900));
    await tester.runAsync(() => session.restore());

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocale.supported,
        home: SessionScope(
          notifier: session,
          child: const HrAttendanceScreen(
            person: HrEmployeeSummary(id: 7, name: 'Ann Lee', status: 'active'),
          ),
        ),
      ),
    );

    await settle(tester);
  }

  // ---------------------------------------------------------------------------
  // The dates are the server's
  // ---------------------------------------------------------------------------

  testWidgets('it asks for a period and never for a date', (tester) async {
    await pump(tester, hrSession());

    final call = asked.firstWhere((p) => p.contains('/hr/employees/7/attendance'));

    expect(call, contains('period=daily'));
    // The two that would give the handset a vote.
    expect(call, isNot(contains('from=')));
    expect(call, isNot(contains('to=')));
  });

  testWidgets('switching period re-asks with the new word, still no dates',
      (tester) async {
    await pump(tester, hrSession());
    asked.clear();

    await tester.tap(find.text('Monthly'));
    await settle(tester);

    final call = asked.firstWhere((p) => p.contains('/hr/employees/7/attendance'));

    expect(call, contains('period=monthly'));
    expect(call, isNot(contains('from=')));
  });

  testWidgets('the window drawn is the one the server named', (tester) async {
    // April 2025, nowhere near the test machine's clock. A heading built from
    // DateTime.now() cannot produce this.
    await pump(
      tester,
      hrSession(
        reply: {
          'ok': true,
          'period': 'monthly',
          'from': '2025-04-01',
          'to': '2025-04-11',
          'today': '2025-04-11',
          'days': [
            day(
              date: '2025-04-03',
              weekday: 'Thu',
              firstIn: '2025-04-03T09:00:00-04:00',
              lastOut: '2025-04-03T18:00:00-04:00',
              breakStart: '2025-04-03T13:00:00-04:00',
              breakEnd: '2025-04-03T14:00:00-04:00',
              breakMinutes: 60,
              workedMinutes: 480,
              punches: 4,
            ),
          ],
          'totals': {
            'present_days': 1, 'absent_days': 0, 'leave_days': 0,
            'late_days': 0, 'early_leave_days': 0,
            'worked_minutes': 480, 'break_minutes': 60,
          },
        },
      ),
    );

    expect(find.textContaining('Apr'), findsWidgets);
    expect(find.text('3 Apr'), findsOneWidget);
  });

  // ---------------------------------------------------------------------------
  // What a day says
  // ---------------------------------------------------------------------------

  testWidgets('a day shows its break times and the total', (tester) async {
    await pump(
      tester,
      hrSession(
        reply: _window([
          day(
            date: '2025-04-03',
            weekday: 'Thu',
            firstIn: '2025-04-03T09:00:00-04:00',
            lastOut: '2025-04-03T18:00:00-04:00',
            breakStart: '2025-04-03T13:00:00-04:00',
            breakEnd: '2025-04-03T14:00:00-04:00',
            breakMinutes: 60,
            workedMinutes: 480,
            punches: 4,
          ),
        ]),
      ),
    );

    // Fmt.duration drops a zero minute part, so an hour is "1h".
    expect(find.textContaining('Break 13:00 – 14:00'), findsOneWidget);
    expect(find.textContaining('· 1h'), findsOneWidget);
    expect(find.text('8h'), findsOneWidget);
  });

  testWidgets('a break left open says so rather than showing a total',
      (tester) async {
    // Its length is unknown, so it costs nothing — and the worked total beside
    // it only reads correctly because the row says why.
    await pump(
      tester,
      hrSession(
        reply: _window([
          day(
            date: '2025-04-04',
            weekday: 'Fri',
            firstIn: '2025-04-04T09:00:00-04:00',
            lastOut: '2025-04-04T17:00:00-04:00',
            breakStart: '2025-04-04T13:00:00-04:00',
            breakMinutes: 0,
            workedMinutes: 480,
            punches: 3,
          ),
        ]),
      ),
    );

    expect(find.textContaining('not ended'), findsOneWidget);
  });

  testWidgets('several breaks show the count, not the envelope', (tester) async {
    // Three breaks, the last never ended. The two times are the first start
    // and the last end — 11:00 and 13:45 — which span 2h45m while only an
    // hour of it was break. Drawn as "Break 11:00 – 13:45 · 1h" that reads as
    // broken arithmetic, and the open third break does not appear at all.
    await pump(
      tester,
      hrSession(
        reply: _window([
          day(
            date: '2025-04-03',
            weekday: 'Thu',
            firstIn: '2025-04-03T09:00:00-04:00',
            lastOut: '2025-04-03T17:00:00-04:00',
            breakStart: '2025-04-03T11:00:00-04:00',
            breakEnd: '2025-04-03T13:45:00-04:00',
            breakCount: 3,
            breakMinutes: 60,
            workedMinutes: 420,
            punches: 7,
          ),
        ]),
      ),
    );

    expect(find.textContaining('3 breaks · 1h'), findsOneWidget);
    expect(find.textContaining('11:00 – 13:45'), findsNothing);
  });

  testWidgets('a single break still shows its times', (tester) async {
    await pump(
      tester,
      hrSession(
        reply: _window([
          day(
            date: '2025-04-03',
            weekday: 'Thu',
            firstIn: '2025-04-03T09:00:00-04:00',
            lastOut: '2025-04-03T18:00:00-04:00',
            breakStart: '2025-04-03T13:00:00-04:00',
            breakEnd: '2025-04-03T14:00:00-04:00',
            breakCount: 1,
            breakMinutes: 60,
            workedMinutes: 480,
            punches: 4,
          ),
        ]),
      ),
    );

    expect(find.textContaining('Break 13:00 – 14:00'), findsOneWidget);
    expect(find.textContaining('breaks ·'), findsNothing);
  });

  testWidgets('an early check-out is flagged', (tester) async {
    await pump(
      tester,
      hrSession(
        reply: _window([
          day(
            date: '2025-04-07',
            weekday: 'Mon',
            late: true,
            earlyLeave: true,
            firstIn: '2025-04-07T09:45:00-04:00',
            lastOut: '2025-04-07T15:00:00-04:00',
            workedMinutes: 315,
            punches: 2,
          ),
        ]),
      ),
    );

    expect(find.text('late'), findsOneWidget);
    expect(find.text('left early'), findsOneWidget);
  });

  testWidgets('a day the server reports no breaks for says nothing about them',
      (tester) async {
    // This is how the employee's own history renders through the same widget:
    // /attendance/history sends no break keys at all.
    await pump(
      tester,
      hrSession(
        reply: {
          'ok': true,
          'period': 'daily',
          'from': '2025-03-13',
          'to': '2025-04-11',
          'today': '2025-04-11',
          'days': [
            {
              'date': '2025-04-08',
              'weekday': 'Tue',
              'status': 'present',
              'late': false,
              'first_in': '2025-04-08T09:00:00-04:00',
              'last_out': '2025-04-08T17:00:00-04:00',
              'worked_minutes': 480,
              'punches': 2,
              'holiday': null,
            },
          ],
          // No break_minutes either, exactly as /attendance/history answers.
          'totals': {
            'present_days': 1, 'absent_days': 0, 'leave_days': 0,
            'late_days': 0, 'worked_minutes': 480,
          },
        },
      ),
    );

    // Not the row's break line, and not the totals card's Break stat.
    expect(find.textContaining('Break'), findsNothing);
    // Twice: the day's own total, and the window's Worked stat above it.
    expect(find.text('8h'), findsNWidgets(2));
  });

  testWidgets('an empty window says so', (tester) async {
    await pump(tester, hrSession());

    expect(find.text('No days in this window.'), findsOneWidget);
  });

  // ---------------------------------------------------------------------------
  // The model
  // ---------------------------------------------------------------------------

  test('an older server sending no break keys is not a crash', () {
    final parsed = HistoryDay.fromJson({
      'date': '2025-04-08',
      'weekday': 'Tue',
      'status': 'present',
      'late': false,
      'worked_minutes': 480,
      'punches': 2,
    });

    // Null, not zero: zero would mean a day with no break taken, which is a
    // fact this reply does not carry.
    expect(parsed.breakMinutes, isNull);
    expect(parsed.breakStart, isNull);
    expect(parsed.earlyLeave, isFalse);
    expect(parsed.workedMinutes, 480);
  });

  test('the history wrapper takes its dates from the reply', () {
    final parsed = HrAttendanceHistory.fromJson({
      'period': 'weekly',
      'from': '2025-04-07',
      'to': '2025-04-11',
      'today': '2025-04-11',
      'days': <Map<String, dynamic>>[],
      'totals': {'present_days': 0, 'break_minutes': 45},
    });

    expect(parsed.period, 'weekly');
    expect(parsed.from, '2025-04-07');
    expect(parsed.today, '2025-04-11');
    expect(parsed.totals.breakMinutes, 45);
  });

  test('a register row carries days, not punches', () {
    final parsed = HrEmployeeSummary.fromJson({
      'id': 7,
      'name': 'Ann Lee',
      'status': 'active',
      'attendance': {
        'present_days': 18,
        'late_days': 2,
        'early_leave_days': 1,
        'worked_minutes': 8640,
        'break_minutes': 1080,
      },
    });

    expect(parsed.attendance?.presentDays, 18);
    expect(parsed.attendance?.lateDays, 2);
  });

  test('a register row from a server that does not report attendance is null', () {
    final parsed = HrEmployeeSummary.fromJson({
      'id': 7,
      'name': 'Ann Lee',
      'status': 'active',
    });

    expect(parsed.attendance, isNull);
  });
}

Map<String, dynamic> _emptyWindow() => {
      'ok': true,
      'period': 'daily',
      'from': '2025-03-13',
      'to': '2025-04-11',
      'today': '2025-04-11',
      'days': <Map<String, dynamic>>[],
      'totals': {
        'present_days': 0, 'absent_days': 0, 'leave_days': 0,
        'late_days': 0, 'early_leave_days': 0,
        'worked_minutes': 0, 'break_minutes': 0,
      },
    };

Map<String, dynamic> _window(List<Map<String, dynamic>> days) => {
      ..._emptyWindow(),
      'days': days,
    };

http.Response _json(Map<String, dynamic> body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
