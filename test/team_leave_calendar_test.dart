import 'dart:convert';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/l10n.dart';
import 'package:attendance/core/locale.dart';
import 'package:attendance/core/session.dart';
import 'package:attendance/core/theme.dart';
import 'package:attendance/l10n/generated/app_localizations.dart';
import 'package:attendance/main.dart';
import 'package:attendance/screens/approvals_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The manager's team leave calendar (B4.6).
///
/// **The mock's month is deliberately not the handset's.** Leave is judged in
/// the company's timezone and the phone is wherever its owner is, so on the 1st
/// or the 31st the two disagree about which *month* it is — and a screen that
/// opened on the wrong grid would say so nowhere. The same mistake has now been
/// made twice on this codebase, on the team board and on attendance history,
/// and both times every test passed because the fake server and the test device
/// shared a clock. The skew below is the only reason any of this is catchable
/// in a headless test.
void main() {
  /// Every URL the app asked for, in order, query string and all.
  late List<String> asked;

  /// The company's current month, one behind the device running these tests.
  final serverMonth = _shift(_ym(DateTime.now()), -1);

  Session managerSession({int teamSize = 4}) {
    asked = <String>[];

    final api = ApiClient(
      client: MockClient((request) async {
        asked.add('${request.url.path}?${request.url.query}');

        if (request.url.path.contains('/team/leave-calendar')) {
          // The real controller: `month` defaults to the company's own current
          // month, and the answer names whichever month it used. That echo is
          // how the app learns what month it is here.
          final month = request.url.queryParameters['month'] ?? serverMonth;

          return http.Response(
            jsonEncode(_month(month, teamSize: teamSize)),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        // The sibling tabs — approvals, the board, the roster — answer empty so
        // none of them throws while this one is under test.
        return http.Response(
          jsonEncode({
            'ok': true,
            'requests': [],
            'pending': [],
            'team': [],
            'summary': {
              'headcount': 0, 'present': 0, 'late': 0,
              'leave': 0, 'absent': 0, 'in_now': 0,
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    return Session(api: api);
  }

  List<String> calendarCalls() =>
      asked.where((u) => u.contains('/team/leave-calendar')).toList();

  /// Open the Team screen and move to the leave tab, which is the fourth.
  ///
  /// The tab bar scrolls — four labels do not fit as equal quarters on a
  /// handset — so the tab has to be brought on screen before it can be tapped.
  Future<void> pumpCalendar(WidgetTester tester, Session session) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocale.supported,
      home: SessionScope(
        notifier: session,
        child: ApprovalsScreen(visible: ValueNotifier(true)),
      ),
    ));
    await tester.pumpAndSettle();

    final tab = find.byType(Tab).at(3);
    await tester.ensureVisible(tab);
    await tester.pumpAndSettle();
    await tester.tap(tab);
    await tester.pumpAndSettle();
  }

  testWidgets('the first month is the server\'s own, asked for by name',
      (tester) async {
    await pumpCalendar(tester, managerSession());

    expect(calendarCalls(), isNotEmpty, reason: 'the tab never called the endpoint');

    // No month at all on the first request. The handset does not get a vote on
    // which month it is — only the server knows the company's timezone.
    expect(calendarCalls().first, isNot(contains('month=')));
  });

  testWidgets('stepping forward counts from the SERVER\'s month',
      (tester) async {
    await pumpCalendar(tester, managerSession());

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();

    expect(calendarCalls().last, contains('month=${_shift(serverMonth, 1)}'));

    // The regression: built from the handset this would be one month past the
    // *device's* month, a whole month adrift, and every name on the grid would
    // belong to the wrong weeks.
    expect(
      calendarCalls().last,
      isNot(contains('month=${_shift(_ym(DateTime.now()), 1)}')),
      reason: 'stepped from the handset\'s month instead of the server\'s',
    );
  });

  testWidgets('stepping back and forward lands where it started',
      (tester) async {
    await pumpCalendar(tester, managerSession());

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(calendarCalls().last, contains('month=${_shift(serverMonth, -1)}'));

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(calendarCalls().last, contains('month=$serverMonth'));
  });

  testWidgets('the forward arrow works, because leave is booked ahead',
      (tester) async {
    // Unlike the attendance board's, which is disabled on today: a future month
    // is the most useful month this screen can answer for, and a calendar that
    // would not look at next month is a calendar that cannot plan cover.
    await pumpCalendar(tester, managerSession());

    final forward = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.chevron_right),
        matching: find.byType(IconButton),
      ).first,
    );

    expect(forward.onPressed, isNotNull);
  });

  testWidgets('a day names everybody off on it, and flags the unsettled one',
      (tester) async {
    await pumpCalendar(tester, managerSession());

    // The 11th is the overlap the mock builds: Ana's approved stretch and Bob's
    // pending single day. Counting by the header rather than by the badge in
    // the cell, which shares its digits with the day numbers around it.
    await tester.tap(find.text('11'));
    await tester.pumpAndSettle();

    expect(find.text('2 people off'), findsOneWidget);
    expect(find.text('Ana Ruiz'), findsOneWidget);
    expect(find.text('Bob Shaw'), findsOneWidget);

    // Pending is on the grid on purpose: a month showing only granted leave is
    // a month a manager can approve a second person onto.
    expect(find.text('Pending'), findsOneWidget);
  });

  testWidgets('a day nobody is off says so rather than showing an empty card',
      (tester) async {
    await pumpCalendar(tester, managerSession());

    await tester.tap(find.text('5'));
    await tester.pumpAndSettle();

    expect(find.text('Nobody off'), findsOneWidget);
    expect(find.text('Ana Ruiz'), findsNothing);
  });

  testWidgets('one person off reads as one, not as a bare number',
      (tester) async {
    await pumpCalendar(tester, managerSession());

    await tester.tap(find.text('10'));
    await tester.pumpAndSettle();

    expect(find.text('1 person off'), findsOneWidget);
  });

  testWidgets('a manager with nobody reporting gets the empty state',
      (tester) async {
    await pumpCalendar(tester, managerSession(teamSize: 0));

    expect(find.text('Nobody reports to you'), findsOneWidget);
  });
}

/// `DateTime` → `YYYY-MM`.
String _ym(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

/// `2026-12` + 1 → `2027-01`.
String _shift(String ym, int by) {
  final parts = ym.split('-');
  final moved = DateTime(int.parse(parts[0]), int.parse(parts[1]) + by);

  return _ym(moved);
}

/// A month's worth of grid, shaped exactly as `TeamController::leaveCalendar`
/// builds it: every day present, weekends flagged, leave expanded into each day
/// it covers with the whole stretch travelling alongside.
Map<String, dynamic> _month(String ym, {required int teamSize}) {
  final first = DateTime(int.parse(ym.split('-')[0]), int.parse(ym.split('-')[1]));
  final lastDay = DateTime(first.year, first.month + 1, 0).day;

  String on(int day) =>
      '$ym-${day.toString().padLeft(2, '0')}';

  Map<String, dynamic> person(
    int id,
    String name,
    int from,
    int to, {
    String status = 'approved',
  }) =>
      {
        'employee_id': id,
        'name': name,
        'employee_code': 'E$id',
        'leave_type': 'Annual',
        'status': status,
        'is_half_day': false,
        'half_day_period': null,
        'start_date': on(from),
        'end_date': on(to),
      };

  return {
    'ok': true,
    'month': ym,
    'from': on(1),
    'to': on(lastDay),
    'timezone': 'America/New_York',
    // The company's today, which the test device is a month past.
    'today': on(3),
    'team_size': teamSize,
    'days': [
      for (var day = 1; day <= lastDay; day++)
        {
          'date': on(day),
          'weekend': DateTime(first.year, first.month, day).weekday >= 6,
          'holiday': null,
          'people': teamSize == 0
              ? const []
              : [
                  if (day >= 10 && day <= 12) person(1, 'Ana Ruiz', 10, 12),
                  if (day == 11) person(2, 'Bob Shaw', 11, 11, status: 'pending'),
                ],
        },
    ],
  };
}
