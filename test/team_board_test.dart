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

/// The manager's attendance board, and the day it is asking about (A10.4 on
/// the phone).
///
/// `GET /team/attendance` has taken a `date` since it shipped and the app only
/// ever asked for today, so a manager could not answer "was she in yesterday?"
/// from a handset. These cover the two things that can go wrong now that it
/// can: asking for the wrong day, and asking for a day the server refuses.
///
/// **The mock's today is deliberately not the handset's.** Attendance is judged
/// in the company's timezone and the phone is wherever its owner is, so the two
/// disagree for part of every day — a phone in Karachi is already on the 12th
/// while a New York office is still on the 11th. An earlier version of this
/// screen built the date from `DateTime.now()` and every one of these tests
/// passed, because the test device and the fake server shared a clock. On a
/// real handset it asked for tomorrow and the board died on "That day has not
/// happened yet". Keep the skew below.
void main() {
  /// Every URL the app asked for, in order, query string and all.
  late List<String> asked;

  /// The company's today, one day behind the device running these tests —
  /// standing in for a handset east of the office.
  final serverToday = DateUtils.dateOnly(
    DateTime.now().subtract(const Duration(days: 1)),
  );

  String iso(DateTime date) => date.toIso8601String().substring(0, 10);

  String serverDaysAgo(int n) => iso(serverToday.subtract(Duration(days: n)));

  Session managerSession() {
    asked = <String>[];

    final api = ApiClient(
      client: MockClient((request) async {
        asked.add('${request.url.path}?${request.url.query}');

        if (request.url.path.contains('/team/roster')) {
          // The real endpoint starts on its own today when given no `from`,
          // takes whatever day it *is* given without complaint, and echoes the
          // window it used. That echo is how the app learns what today means
          // here — and the silence on a bad `from` is why getting it wrong
          // here is invisible rather than loud.
          final from = request.url.queryParameters['from'] ?? iso(serverToday);

          return http.Response(
            jsonEncode({
              'ok': true,
              'from': from,
              'to': iso(DateTime.parse(from).add(const Duration(days: 6))),
              'timezone': 'America/New_York',
              'team': [
                {
                  'employee_id': 1,
                  'name': 'Ana Ruiz',
                  'employee_code': 'E1',
                  'schedule': const <Map<String, dynamic>>[],
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        if (request.url.path.contains('/team/attendance')) {
          final requested = request.url.queryParameters['date'];

          // The real endpoint answers for its own today when no date is given,
          // and echoes whichever day it used. That echo is how the app learns
          // what today means here.
          return http.Response(
            jsonEncode({
              'ok': true,
              'date': requested ?? iso(serverToday),
              'timezone': 'America/New_York',
              'summary': {'headcount': 1, 'present': 1, 'late': 0, 'leave': 0, 'absent': 0, 'in_now': 1},
              'team': [
                {
                  'id': 1,
                  'name': 'Ana Ruiz',
                  'status': 'present',
                  'checked_in_at': '09:02',
                  'checked_out_at': null,
                  'is_in_now': true,
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        // Anything else — /leave/approvals, /team/roster — answers empty so the
        // sibling tabs do not throw while this one is under test.
        return http.Response(
          jsonEncode({'ok': true, 'requests': [], 'team': []}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    return Session(api: api);
  }

  List<String> boardCalls() =>
      asked.where((u) => u.contains('/team/attendance')).toList();

  Future<void> pumpBoard(WidgetTester tester, Session session) async {
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

    // The board is the second tab; the first is the approvals inbox.
    await tester.tap(find.byType(Tab).at(1));
    await tester.pumpAndSettle();
  }

  testWidgets('it opens on today by asking the server which day that is',
      (tester) async {
    final session = managerSession();
    await pumpBoard(tester, session);

    final board = boardCalls();
    expect(board, isNotEmpty, reason: 'the board never called the endpoint');

    // No date at all on the first request. The handset does not get a vote on
    // what today is — only the server knows the company's timezone.
    expect(board.first, isNot(contains('date=')));
  });

  testWidgets('stepping back asks for the day before the SERVER\'s today',
      (tester) async {
    final session = managerSession();
    await pumpBoard(tester, session);

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();

    // The regression: built from the handset's clock this would be one day
    // behind the *device*, which here is the server's today — a day on which
    // the board would quietly show the wrong people.
    expect(boardCalls().last, contains('date=${serverDaysAgo(1)}'));
    expect(
      boardCalls().last,
      isNot(contains('date=${iso(DateUtils.dateOnly(DateTime.now()))}')),
      reason: 'stepped back to the handset\'s today instead of the server\'s',
    );
  });

  testWidgets('two steps back keeps counting from the server\'s today',
      (tester) async {
    final session = managerSession();
    await pumpBoard(tester, session);

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();

    expect(boardCalls().last, contains('date=${serverDaysAgo(2)}'));
  });

  testWidgets('the forward arrow is dead on today, so no future date is ever sent',
      (tester) async {
    final session = managerSession();
    await pumpBoard(tester, session);

    final before = boardCalls().length;

    // The endpoint refuses a future date with a 422. A control that reliably
    // produces an error is a trap, so this one is disabled rather than left to
    // fail — tapping it must do nothing at all, not even a request.
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();

    expect(boardCalls().length, before);

    final forward = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.chevron_right),
        matching: find.byType(IconButton),
      ).first,
    );
    expect(forward.onPressed, isNull, reason: 'forward arrow should be disabled on today');
  });

  testWidgets('and comes back to life once the board is in the past', (tester) async {
    final session = managerSession();
    await pumpBoard(tester, session);

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();

    // Back where it started: today again, and today is still the server's to
    // name, so the date comes off the request rather than being recomputed.
    expect(boardCalls().last, isNot(contains('date=')));
  });

  // =========================================================================
  // The roster tab, which had the same bug in a quieter form (B7.3)
  // =========================================================================

  List<String> rosterCalls() =>
      asked.where((u) => u.contains('/team/roster')).toList();

  /// Open the Team screen on the roster, which is the third tab.
  Future<void> pumpRoster(WidgetTester tester, Session session) async {
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

    // The tab bar scrolls — four labels do not fit as equal quarters on a
    // handset — so the tab has to be brought on screen before it is tapped.
    final tab = find.byType(Tab).at(2);
    await tester.ensureVisible(tab);
    await tester.pumpAndSettle();
    await tester.tap(tab);
    await tester.pumpAndSettle();
  }

  testWidgets('this week is the server\'s week, asked for by name',
      (tester) async {
    await pumpRoster(tester, managerSession());

    expect(rosterCalls(), isNotEmpty, reason: 'the roster never called the endpoint');

    // No `from` at all on this week. Unlike the board's `date`, this endpoint
    // accepts whatever day it is handed, so a handset a day ahead was shown
    // Tuesday-to-Monday under a heading that said "This week" — and nothing
    // anywhere said so.
    expect(rosterCalls().first, isNot(contains('from=')));
  });

  testWidgets('next week counts from the SERVER\'s today', (tester) async {
    await pumpRoster(tester, managerSession());

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();

    expect(rosterCalls().last, contains('from=${iso(serverToday.add(const Duration(days: 7)))}'));

    // The regression: built from the handset this would be seven days past the
    // *device's* today, a whole day adrift of the week it claims to show.
    final deviceToday = DateUtils.dateOnly(DateTime.now());
    expect(
      rosterCalls().last,
      isNot(contains('from=${iso(deviceToday.add(const Duration(days: 7)))}')),
      reason: 'counted from the handset\'s today instead of the server\'s',
    );
  });

  testWidgets('two weeks back keeps counting from the server\'s today',
      (tester) async {
    await pumpRoster(tester, managerSession());

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();

    // From the anchor every time, not from the window last shown — an offset
    // applied to the previous answer would walk further out with every press.
    expect(
      rosterCalls().last,
      contains('from=${iso(serverToday.subtract(const Duration(days: 14)))}'),
    );
  });

  testWidgets('coming back to this week re-asks rather than recomputing',
      (tester) async {
    await pumpRoster(tester, managerSession());

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();

    // This is what makes a session left open across midnight correct itself:
    // this week always asks the server afresh, so the anchor is re-learned
    // rather than drifting a day further out each time.
    expect(rosterCalls().last, isNot(contains('from=')));
  });
}
