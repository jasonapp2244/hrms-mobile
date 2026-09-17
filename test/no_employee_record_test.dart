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
import 'package:attendance/screens/leave_screen.dart';
import 'package:attendance/screens/schedule_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/settle.dart';

/// An account with no employee record, on the tabs that need one.
///
/// HR and administrator accounts are not required to be employees — HR's work
/// is on the web dashboard, and `emp:install` creates an administrator with no
/// employee row at all. Signing one into the app is therefore an ordinary
/// thing to do, not a broken state, and every employee-facing endpoint answers
/// such an account with `403 forbidden`.
///
/// Found on a real handset: all four data tabs rendered the ordinary error
/// card, each offering **Try again** — for a condition that will still be true
/// on the hundredth press, because it is a fact about the account rather than
/// about the network. The Profile tab already said the true thing and pointed
/// at the web dashboard; the rest invited the user to keep pressing.
///
/// So: the right message, and **no retry button**. A retry that cannot work is
/// worse than no retry, because it implies the failure is temporary.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('no_employee_record_test');
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // The cache writes without the test awaiting it, so on Windows the file
      // can still be held open when the test ends. Harness tidying.
    }
  });

  /// Answers every request the way the API answers an account with no employee
  /// record: the resolver every employee-facing endpoint runs through refuses,
  /// and nothing further is reached.
  Session refusingSession() {
    final api = ApiClient(
      client: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'ok': false,
            'error': 'forbidden',
            'message': 'This account has no employee record.',
          }),
          403,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    return Session(api: api, cache: OfflineCache(directory: dir));
  }

  /// A refusal that a retry **could** clear, for the other half of the claim.
  Session unreachableSession() {
    final api = ApiClient(
      client: MockClient((request) async {
        throw const SocketException('no route to host');
      }),
    );

    return Session(api: api, cache: OfflineCache(directory: dir));
  }

  Future<void> pump(WidgetTester tester, Session session, Widget screen) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocale.supported,
      home: SessionScope(notifier: session, child: screen),
    ));
    await settle(tester);
  }

  final screens = <String, Widget Function()>{
    'History': () => HistoryScreen(visible: ValueNotifier(true)),
    'Leave': () => LeaveScreen(visible: ValueNotifier(true)),
    'Schedule': () => ScheduleScreen(visible: ValueNotifier(true)),
  };

  for (final entry in screens.entries) {
    testWidgets('${entry.key} says why, and offers no retry that cannot work',
        (tester) async {
      await pump(tester, refusingSession(), entry.value());

      // The account is named as the reason, rather than a generic failure.
      expect(
        find.textContaining('no employee record'),
        findsOneWidget,
        reason: '${entry.key} did not say why it is empty',
      );

      expect(
        find.text('Try again'),
        findsNothing,
        reason: '${entry.key} offers a retry for a permanent condition',
      );
    });

    testWidgets('${entry.key} still offers a retry when the network is the problem',
        (tester) async {
      await pump(tester, unreachableSession(), entry.value());

      // The guard has to be about *this* failure and not about failure in
      // general: a screen that dropped its retry button whenever anything went
      // wrong would strand a user with no signal.
      expect(
        find.text('Try again'),
        findsOneWidget,
        reason: '${entry.key} dropped the retry on an ordinary network failure',
      );
    });
  }
}
