import 'dart:convert';
import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/l10n.dart';
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

/// Which days the attendance history asks for.
///
/// The handset does not get a vote. Attendance is judged in the company's
/// timezone and the phone is wherever its owner is, so for part of every day
/// the two disagree about the date — a phone in Karachi is on the 12th while a
/// New York company is still on the 11th.
///
/// That disagreement is quiet here in a way it is not elsewhere: rather than
/// refusing a `to` in the future, `AttendanceController::history` clamps it
/// back to its own today. A phone a day ahead therefore asked for
/// `from = today-6, to = tomorrow`, got `today-6 .. today` back, and rendered
/// six days under a heading that said seven — with the totals and the
/// attendance score computed over the short window. Nothing errored.
///
/// So: `to` is never sent, and `from` counts back from the date the server
/// itself reported. The mock below keeps a deliberate skew between its own
/// today and the test device's, because with a shared clock every one of these
/// passes against the broken code.
void main() {
  late List<String> asked;
  late Directory dir;

  /// The history screen reads through the offline cache, which wants somewhere
  /// on disk and a keychain. Both are per-test so nothing leaks between them.
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('history_window_test');
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

  /// The company's today, a day behind the device running the tests.
  final serverToday = DateUtils.dateOnly(
    DateTime.now().subtract(const Duration(days: 1)),
  );

  String iso(DateTime d) => d.toIso8601String().substring(0, 10);

  Session historySession() {
    asked = <String>[];

    final api = ApiClient(
      client: MockClient((request) async {
        asked.add('${request.url.path}?${request.url.query}');

        if (request.url.path.contains('/attendance/history')) {
          final q = request.url.queryParameters;

          // The real controller: `to` defaults to the company's today and is
          // clamped to it, `from` defaults to 29 days before `to`, and both
          // ends are echoed back.
          var to = q['to'] == null ? serverToday : DateTime.parse(q['to']!);
          if (to.isAfter(serverToday)) to = serverToday;

          final from = q['from'] == null
              ? to.subtract(const Duration(days: 29))
              : DateTime.parse(q['from']!);

          return http.Response(
            jsonEncode({
              'ok': true,
              'from': iso(from),
              'to': iso(to),
              'days': <Map<String, dynamic>>[],
              'totals': {'present': 0, 'late': 0, 'absent': 0, 'leave': 0, 'worked_minutes': 0},
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

  List<String> historyCalls() =>
      asked.where((u) => u.contains('/attendance/history')).toList();

  testWidgets('the first window is the server\'s own, asked for by name',
      (tester) async {
    await pumpHistory(tester, historySession());

    expect(historyCalls(), isNotEmpty, reason: 'history never called the endpoint');

    // No window at all on the first request: the default *is* the 30 days the
    // screen opens on, and it is anchored on the right day by definition.
    expect(historyCalls().first, isNot(contains('from=')));
    expect(historyCalls().first, isNot(contains('to=')));
  });

  testWidgets('a narrower range counts back from the SERVER\'s today',
      (tester) async {
    final session = historySession();
    await pumpHistory(tester, session);

    // Pick the 7-day range from the menu.
    expect(find.byType(PopupMenuButton<int>), findsOneWidget, reason: 'no range menu button');
    await tester.tap(find.byType(PopupMenuButton<int>).first);
    await settle(tester);
    expect(find.text('Last 7 days'), findsWidgets, reason: 'menu did not open');
    await tester.tap(find.text('Last 7 days').last);
    // onSelected fires only once the menu route has finished popping, and the
    // reload it starts is another frame after that.
    await settle(tester);
    await settle(tester);

    expect(historyCalls().length, greaterThan(1), reason: 'calls so far: $asked');
    final last = historyCalls().last;

    // Seven days inclusive, ending on the server's today — so `from` is six
    // days before it, and `to` is still the server's business.
    expect(last, contains('from=${iso(serverToday.subtract(const Duration(days: 6)))}'));
    expect(last, isNot(contains('to=')));

    // The regression: built from the handset this would be six days before the
    // *device's* today, a whole day adrift, and the window would come back one
    // day short of the heading.
    final deviceToday = DateUtils.dateOnly(DateTime.now());
    expect(
      last,
      isNot(contains('from=${iso(deviceToday.subtract(const Duration(days: 6)))}')),
      reason: 'counted back from the handset\'s today instead of the server\'s',
    );
  });

  testWidgets('never asks for a day the company has not reached', (tester) async {
    final session = historySession();
    await pumpHistory(tester, session);

    await tester.tap(find.byType(PopupMenuButton<int>).first);
    await settle(tester);
    await tester.tap(find.text('Last 7 days').last);
    // onSelected fires only once the menu route has finished popping, and the
    // reload it starts is another frame after that.
    await settle(tester);
    await settle(tester);

    // Every date this screen has ever named must be on or before the company's
    // today. Asking beyond it is silently clamped, which is how the original
    // bug stayed invisible.
    for (final call in historyCalls()) {
      for (final match in RegExp(r'(?:from|to)=(\d{4}-\d{2}-\d{2})').allMatches(call)) {
        final asked = DateTime.parse(match.group(1)!);
        expect(
          asked.isAfter(serverToday),
          isFalse,
          reason: '$call asks for ${match.group(1)}, past the company today ${iso(serverToday)}',
        );
      }
    }
  });
}
