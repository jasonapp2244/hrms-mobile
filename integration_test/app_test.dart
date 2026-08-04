import 'package:attendance/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// End-to-end walkthrough against a live Laravel server.
///
/// Driven in-process rather than through `adb shell input`, which cannot reach
/// these fields reliably: '@' does not survive `input text`, the soft keyboard
/// shifts the layout out from under tap coordinates, and disabling the IME
/// removes the channel the text arrives on. `enterText` has none of those
/// problems because it talks to the widget, not the window.
///
/// Requires:
///   php artisan serve --host=0.0.0.0 --port=8000
///   flutter test integration_test -d emulator-5554
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The token survives in the keychain between tests — which is the whole
  // point of it in production, and wrong here: the second test would restore
  // the first one's session and never reach the login screen. Clear it so
  // every test starts signed out, and so a test signing in as one role cannot
  // leak that role into the next.
  setUp(() async {
    await const FlutterSecureStorage().deleteAll();
  });

  /// Longer than a unit test would need: every one of these settles waits on a
  /// real HTTP round trip to the host machine.
  Future<void> settle(WidgetTester tester, [int seconds = 6]) async {
    await tester.pumpAndSettle(const Duration(milliseconds: 250));
    for (var i = 0; i < seconds * 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.pumpAndSettle(const Duration(milliseconds: 250));
  }

  Future<void> signIn(
    WidgetTester tester, {
    required String email,
    required String password,
  }) async {
    await tester.pumpWidget(const HrmsApp());
    await settle(tester, 4);

    expect(
      find.text('Sign in with your work account'),
      findsOneWidget,
      reason: 'Login screen did not render — is a stale session restored?',
    );

    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), email);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      password,
    );
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await settle(tester, 8);
  }

  group('employee', () {
    testWidgets('signs in and lands on the clock screen', (tester) async {
      await signIn(
        tester,
        email: 'emily.johnson@acme.test',
        password: 'password',
      );

      // Getting off the login screen at all proves the whole chain: base URL
      // reachable from the emulator, Sanctum token issued, /auth/me parsed.
      expect(find.text('Sign in with your work account'), findsNothing);
      expect(find.text('Clock'), findsOneWidget);
      expect(find.text('Emily Johnson'), findsWidgets);
    });

    testWidgets('sees no Team tab without approve-leave', (tester) async {
      await signIn(
        tester,
        email: 'emily.johnson@acme.test',
        password: 'password',
      );

      // The manager section is permission-gated on the server too, so showing
      // the tab here would only produce a 403 screen.
      expect(find.text('Team'), findsNothing);
      expect(find.text('Leave'), findsOneWidget);
      expect(find.text('Schedule'), findsOneWidget);
    });

    testWidgets('the punch button offers a real action', (tester) async {
      await signIn(
        tester,
        email: 'emily.johnson@acme.test',
        password: 'password',
      );

      // The server decides the direction from what is already on record, so
      // either label is correct — what matters is that one of them rendered,
      // which means /attendance/today parsed.
      final checkIn = find.text('Check in');
      final checkOut = find.text('Check out');
      expect(
        checkIn.evaluate().isNotEmpty || checkOut.evaluate().isNotEmpty,
        isTrue,
        reason: 'Neither punch label rendered — /attendance/today failed.',
      );

      expect(find.textContaining('worked today'), findsOneWidget);
    });

    testWidgets('history loads with day rows', (tester) async {
      await signIn(
        tester,
        email: 'emily.johnson@acme.test',
        password: 'password',
      );

      await tester.tap(find.text('History'));
      await settle(tester);

      expect(find.text('Nothing recorded yet').evaluate().isEmpty, isTrue,
          reason: 'History came back empty — is the demo data seeded?');
      expect(find.textContaining('LAST'), findsOneWidget);
    });

    testWidgets('leave shows balances and the apply button', (tester) async {
      await signIn(
        tester,
        email: 'emily.johnson@acme.test',
        password: 'password',
      );

      await tester.tap(find.text('Leave'));
      await settle(tester);

      expect(find.text('BALANCES'), findsOneWidget);
      expect(find.text('YOUR REQUESTS'), findsOneWidget);
      expect(find.widgetWithText(FloatingActionButton, 'Apply'), findsOneWidget);
    });

    testWidgets('schedule loads the published roster', (tester) async {
      await signIn(
        tester,
        email: 'emily.johnson@acme.test',
        password: 'password',
      );

      await tester.tap(find.text('Schedule'));
      await settle(tester);

      // Either a roster or the honest empty state — both mean the endpoint
      // answered and parsed. A thrown exception would fail before here.
      final hasRoster = find.text('Standing shift').evaluate().isNotEmpty;
      final hasEmpty = find.text('No schedule published').evaluate().isNotEmpty;
      expect(hasRoster || hasEmpty, isTrue);
    });
  });

  group('manager', () {
    testWidgets('gets the Team tab', (tester) async {
      await signIn(
        tester,
        email: 'james.smith@acme.test',
        password: 'password',
      );

      expect(find.text('Team'), findsOneWidget);
    });

    testWidgets('approvals and team attendance both load', (tester) async {
      await signIn(
        tester,
        email: 'james.smith@acme.test',
        password: 'password',
      );

      await tester.tap(find.text('Team'));
      await settle(tester);

      expect(find.text('My team'), findsOneWidget);
      expect(find.text('Approvals'), findsOneWidget);
      expect(find.text('In today'), findsOneWidget);

      // The team tab answers a different question from the inbox: who is on
      // the floor, not who is waiting on a decision.
      await tester.tap(find.text('In today'));
      await settle(tester);

      final hasSummary =
          find.textContaining('on the floor now').evaluate().isNotEmpty;
      final hasEmpty =
          find.text('Nobody reports to you').evaluate().isNotEmpty;
      expect(hasSummary || hasEmpty, isTrue,
          reason: '/team/attendance neither rendered nor emptied cleanly.');
    });
  });

  group('admin', () {
    testWidgets('signs in but is told it has no employee record',
        (tester) async {
      // An admin account has no employee row, so every employee-scoped
      // endpoint answers 403. The app has to say so rather than leaving
      // somebody to discover it one empty screen at a time.
      await signIn(
        tester,
        email: 'admin@hrms.test',
        password: 'password',
      );

      expect(find.text('Sign in with your work account'), findsNothing);

      await tester.tap(find.text('Profile'));
      await settle(tester);

      expect(
        find.textContaining('not linked to an employee record'),
        findsOneWidget,
      );
    });
  });

  group('bad credentials', () {
    testWidgets('are refused without saying which half was wrong',
        (tester) async {
      await signIn(
        tester,
        email: 'emily.johnson@acme.test',
        password: 'not-the-password',
      );

      expect(find.text('That email and password do not match.'), findsOneWidget);
      expect(find.text('Clock'), findsNothing);
    });
  });
}
