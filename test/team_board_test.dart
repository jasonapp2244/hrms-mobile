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
void main() {
  /// Every URL the app asked for, in order, query string and all.
  late List<String> asked;

  String today() => DateTime.now().toIso8601String().substring(0, 10);

  String daysAgo(int n) => DateUtils.dateOnly(
        DateTime.now().subtract(Duration(days: n)),
      ).toIso8601String().substring(0, 10);

  Session managerSession() {
    asked = <String>[];

    final api = ApiClient(
      client: MockClient((request) async {
        asked.add('${request.url.path}?${request.url.query}');

        if (request.url.path.contains('/team/attendance')) {
          return http.Response(
            jsonEncode({
              'ok': true,
              'date': request.url.queryParameters['date'],
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

  testWidgets('it opens on today, and says so explicitly', (tester) async {
    final session = managerSession();
    await pumpBoard(tester, session);

    final board = asked.where((u) => u.contains('/team/attendance')).toList();
    expect(board, isNotEmpty, reason: 'the board never called the endpoint');

    // Today is sent rather than left to the server's default: a handset left
    // open across midnight would otherwise refresh into a day the header does
    // not name.
    expect(board.first, contains('date=${today()}'));
  });

  testWidgets('stepping back asks for the day before', (tester) async {
    final session = managerSession();
    await pumpBoard(tester, session);

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();

    expect(
      asked.where((u) => u.contains('/team/attendance')).last,
      contains('date=${daysAgo(1)}'),
    );
  });

  testWidgets('the forward arrow is dead on today, so no future date is ever sent',
      (tester) async {
    final session = managerSession();
    await pumpBoard(tester, session);

    final before = asked.where((u) => u.contains('/team/attendance')).length;

    // The endpoint refuses a future date with a 422. A control that reliably
    // produces an error is a trap, so this one is disabled rather than left to
    // fail — tapping it must do nothing at all, not even a request.
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();

    expect(asked.where((u) => u.contains('/team/attendance')).length, before);

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

    // Back where it started, which is the only place the arrow switches off.
    expect(
      asked.where((u) => u.contains('/team/attendance')).last,
      contains('date=${today()}'),
    );
  });
}
