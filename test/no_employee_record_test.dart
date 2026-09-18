import 'dart:convert';
import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/locale.dart';
import 'package:attendance/core/offline_cache.dart';
import 'package:attendance/core/session.dart';
import 'package:attendance/core/theme.dart';
import 'package:attendance/l10n/generated/app_localizations.dart';
import 'package:attendance/main.dart';
import 'package:attendance/screens/directory_screen.dart';
import 'package:attendance/screens/documents_screen.dart';
import 'package:attendance/screens/history_screen.dart';
import 'package:attendance/screens/leave_screen.dart';
import 'package:attendance/screens/punch_screen.dart';
import 'package:attendance/screens/regularisations_screen.dart';
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
/// such an account with `403 no_employee_record`.
///
/// Found on a real handset: every data tab rendered the ordinary error card,
/// each offering **Try again** — for a condition that will still be true on the
/// hundredth press, because it is a fact about the account rather than about
/// the network. The Profile tab already said the true thing and pointed at the
/// web dashboard; the rest invited the user to keep pressing.
///
/// So three claims, on all seven screens:
///
///   * **the right message**, naming the account rather than the network;
///   * **no retry button**, because a retry that cannot work is worse than no
///     retry — it implies the failure is temporary; and
///   * **not a cut-cloud icon**, which said "the network is down" directly
///     above a sentence saying it was not. That was the last piece of this to
///     be fixed, and the one no assertion had ever covered.
///
/// The fourth claim is the one that made the code change necessary at all:
/// `forbidden` must **not** trigger any of it. The API raises that for an
/// employee reaching for somebody else's leave request too, and relabelling
/// that "this account has no employee record" is both untrue and unrecoverable.
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

  /// Answers every request with one refusal, as the API would.
  Session refusing(String code, String message) {
    final api = ApiClient(
      client: MockClient((request) async {
        return http.Response(
          jsonEncode({'ok': false, 'error': code, 'message': message}),
          403,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    return Session(api: api, cache: OfflineCache(directory: dir));
  }

  /// The resolver every employee-facing endpoint runs through, refusing.
  Session orphanedSession() => refusing(
        'no_employee_record',
        'No employee record is linked to this account. Contact HR.',
      );

  /// A different 403 entirely — one about a record, not about the account.
  ///
  /// This is the case that shared a code with the one above until the API grew
  /// `no_employee_record`, and the reason it had to.
  Session notYoursSession() =>
      refusing('forbidden', 'That leave request is not yours.');

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

  /// Every screen that goes through the employee resolver — the four tabs and
  /// the three pages reached from them.
  final screens = <String, Widget Function()>{
    'Clock': () => PunchScreen(visible: ValueNotifier(true)),
    'History': () => HistoryScreen(visible: ValueNotifier(true)),
    'Leave': () => LeaveScreen(visible: ValueNotifier(true)),
    'Schedule': () => ScheduleScreen(visible: ValueNotifier(true)),
    'Documents': () => const DocumentsScreen(),
    'Colleagues': () => const DirectoryScreen(),
    'Corrections': () => const RegularisationsScreen(),
  };

  for (final entry in screens.entries) {
    testWidgets('${entry.key} says why, and offers no retry that cannot work',
        (tester) async {
      await pump(tester, orphanedSession(), entry.value());

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

    testWidgets('${entry.key} does not blame the network for the account',
        (tester) async {
      await pump(tester, orphanedSession(), entry.value());

      // The whole defect in one assertion. The words were right and the
      // picture above them said the connection had dropped, so an
      // administrator was sent to check their wifi over an account setting.
      expect(
        find.byIcon(Icons.cloud_off),
        findsNothing,
        reason: '${entry.key} draws a cut cloud for a permanent account state',
      );

      expect(
        find.byIcon(Icons.badge_outlined),
        findsOneWidget,
        reason: '${entry.key} did not mark this as an account state',
      );
    });

    testWidgets(
        '${entry.key} still offers a retry when the network is the problem',
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

      expect(
        find.byIcon(Icons.cloud_off),
        findsOneWidget,
        reason: '${entry.key} lost the offline icon on a real network failure',
      );
    });

    testWidgets('${entry.key} treats a plain forbidden as recoverable',
        (tester) async {
      await pump(tester, notYoursSession(), entry.value());

      // `forbidden` is not this condition, and must not be relabelled as it.
      // The server's own words stand, and the retry stays.
      expect(
        find.textContaining('no employee record'),
        findsNothing,
        reason: '${entry.key} called an ordinary refusal a missing record',
      );

      expect(
        find.text('Try again'),
        findsOneWidget,
        reason: '${entry.key} stripped the retry from a recoverable refusal',
      );
    });
  }
}
