import 'dart:convert';
import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/l10n.dart';
import 'package:attendance/core/locale.dart';
import 'package:attendance/core/location.dart';
import 'package:attendance/core/offline_cache.dart';
import 'package:attendance/core/punch_queue.dart';
import 'package:attendance/core/session.dart';
import 'package:attendance/core/theme.dart';
import 'package:attendance/l10n/generated/app_localizations.dart';
import 'package:attendance/main.dart';
import 'package:attendance/screens/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Where somebody lives and who to call if something happens to them (B3.2).
///
/// These seven fields sit on the **employee record**, not on the account, and
/// until now the API had no way to write them at all — an employee could not
/// correct their own emergency contact from the phone, which is the one field
/// in an HR record that is only ever read on the worst day.
///
/// The two rules that are easy to get wrong and invisible when you do: a field
/// the client never sent must be left alone rather than cleared, and a field
/// the user emptied must actually be sent, or it can never be emptied again.
void main() {
  late Directory dir;

  /// Every write the app made, decoded.
  late List<Map<String, dynamic>> saved;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('profile_details_test');
    FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});
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

  Map<String, dynamic> me({bool withEmployee = true}) => {
        'user': {
          'id': 3,
          'name': 'Ann Lee',
          'email': 'ann@acme.test',
          'roles': ['employee'],
          'permissions': ['view-attendance'],
          'employee': withEmployee
              ? {
                  'id': 1,
                  'employee_code': 'EMP-0001',
                  'full_name': 'Ann Lee',
                  'is_manager': false,
                }
              : null,
        },
      };

  /// A signed-in session whose server answers.
  ///
  /// [details] is the `employee` block `GET /profile` returns — what the sheet
  /// prefills from. Every disk touch is inside `runAsync`: `testWidgets` runs
  /// in a fake-async zone that never delivers a real file completion, so a
  /// pump that reaches the cache hangs the run rather than failing it.
  Future<Session> signedIn(
    WidgetTester tester, {
    Map<String, dynamic> details = const {},
    bool withEmployee = true,
    Map<String, dynamic>? refuseWith,
  }) async {
    saved = <Map<String, dynamic>>[];
    late Session session;

    await tester.runAsync(() async {
      final store = OfflineCache(directory: dir);
      await store.write(OfflineCache.keyProfile, me(withEmployee: withEmployee));

      final queue = PunchQueue(directory: dir);
      await queue.load();

      session = Session(
        api: ApiClient(
          client: MockClient((request) async {
            if (request.method == 'PUT' &&
                request.url.path.contains('/profile/details')) {
              saved.add(jsonDecode(request.body) as Map<String, dynamic>);

              if (refuseWith != null) {
                return http.Response(
                  jsonEncode(refuseWith),
                  422,
                  headers: {'content-type': 'application/json'},
                );
              }

              return http.Response(
                jsonEncode({'ok': true, 'message': 'Profile updated.', 'employee': details}),
                200,
                headers: {'content-type': 'application/json'},
              );
            }

            if (request.url.path.endsWith('/profile')) {
              return http.Response(
                jsonEncode({
                  'ok': true,
                  'account': {'id': 3, 'name': 'Ann Lee', 'email': 'ann@acme.test'},
                  'employee': withEmployee ? details : null,
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }

            return http.Response(
              jsonEncode({'ok': true, ...me(withEmployee: withEmployee)}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
        cache: store,
        queue: queue,
        locator: const PunchLocator(source: NoLocationSource()),
      );

      await session.restore();
    });

    return session;
  }

  /// Let a load that touches the disk finish.
  ///
  /// `runAsync` gives the disk real time and `pump` drains the continuations
  /// that finish because of it; a load is a chain of them, so the two have to
  /// alternate rather than run once each.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> pumpProfile(WidgetTester tester, Session session) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));

    // Above `MaterialApp`, exactly as `_Root` puts it. A modal bottom sheet is
    // built in the root navigator's overlay, which is *outside* `home:` — a
    // scope nested in there is invisible to the sheet, and the sheet is the
    // thing under test.
    await tester.pumpWidget(SessionScope(
      notifier: session,
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocale.supported,
        home: const ProfileScreen(),
      ),
    ));
    await settle(tester);
  }

  Future<void> openSheet(WidgetTester tester) async {
    // By its label rather than by widget type: `OutlinedButton.icon` builds a
    // private subclass, which `find.byType(OutlinedButton)` does not match.
    final button = find.text('Home & emergency contact');

    // The profile list is taller than a handset, so the button is in the tree
    // but below the fold. `pumpAndSettle` after the scroll rather than [settle]:
    // this one is an animation, not a disk read.
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await settle(tester);
  }

  /// Scroll to the Save button and press it.
  ///
  /// Seven fields is taller than the sheet, so the button starts below the
  /// fold — a tap without this lands outside the render tree.
  Future<void> save(WidgetTester tester) async {
    final button = find.widgetWithText(FilledButton, 'Save');

    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await settle(tester);
  }

  /// What was typed into the field with this label.
  String typedIn(WidgetTester tester, String label) {
    final field = find.ancestor(
      of: find.text(label),
      matching: find.byType(TextField),
    );

    return tester.widget<TextField>(field.first).controller?.text ?? '';
  }

  testWidgets('the sheet opens prefilled from the employee record',
      (tester) async {
    final session = await signedIn(tester, details: const {
      'address': '4 Mill Lane',
      'city': 'Leeds',
      'country': 'United Kingdom',
      'personal_email': 'ann@home.test',
      'emergency_contact_name': 'Sam Lee',
      'emergency_contact_phone': '555-0199',
      'emergency_contact_relation': 'Brother',
    });

    await pumpProfile(tester, session);
    await openSheet(tester);

    // Opening this sheet is how the emergency contact is *read* — it has no
    // display of its own, so a blank form would read as "we have nobody for
    // you" and invite somebody to retype what they had already given.
    expect(typedIn(tester, 'Address'), '4 Mill Lane');
    expect(typedIn(tester, 'City'), 'Leeds');
    expect(typedIn(tester, 'Who to call'), 'Sam Lee');
    expect(typedIn(tester, 'Their phone number'), '555-0199');
    expect(typedIn(tester, 'How you know them'), 'Brother');

    session.dispose();
  });

  testWidgets('it says who can read this before the first field',
      (tester) async {
    final session = await signedIn(tester);

    await pumpProfile(tester, session);
    await openSheet(tester);

    // Somebody deciding whether to type their home address needs to know who
    // reads it while they are deciding, not afterwards.
    expect(
      find.text('Only you and HR can see this. Colleagues and your manager cannot.'),
      findsOneWidget,
    );

    session.dispose();
  });

  testWidgets('saving sends every field, trimmed', (tester) async {
    final session = await signedIn(tester);

    await pumpProfile(tester, session);
    await openSheet(tester);

    await tester.enterText(
      find.ancestor(of: find.text('Who to call'), matching: find.byType(TextField)).first,
      '  Sam Lee  ',
    );
    await save(tester);

    expect(saved, hasLength(1));
    expect(saved.single['emergency_contact_name'], 'Sam Lee');

    // All seven, every time. The server leaves an omitted key alone, so a
    // client that sent only what was filled in could never empty anything.
    expect(saved.single.keys, hasLength(7));
    expect(saved.single.containsKey('address'), isTrue);
    expect(saved.single.containsKey('personal_email'), isTrue);
    expect(saved.single.containsKey('emergency_contact_relation'), isTrue);

    session.dispose();
  });

  testWidgets('a contact who is no longer the right person can be cleared',
      (tester) async {
    final session = await signedIn(tester, details: const {
      'emergency_contact_name': 'Sam Lee',
      'emergency_contact_phone': '555-0199',
    });

    await pumpProfile(tester, session);
    await openSheet(tester);

    await tester.enterText(
      find.ancestor(of: find.text('Who to call'), matching: find.byType(TextField)).first,
      '',
    );
    await save(tester);

    // Empty, and *sent* — the server reads an empty string as "clear this".
    // Dropping the key instead would leave Sam on the record for ever.
    expect(saved.single['emergency_contact_name'], '');
    expect(saved.single['emergency_contact_phone'], '555-0199');

    session.dispose();
  });

  testWidgets('a field the server refuses is marked on that field',
      (tester) async {
    final session = await signedIn(tester, refuseWith: const {
      'ok': false,
      'error': 'validation_failed',
      'message': 'Check the form.',
      'errors': {
        'personal_email': ['That is not a valid address.'],
      },
    });

    await pumpProfile(tester, session);
    await openSheet(tester);

    await tester.enterText(
      find.ancestor(of: find.text('Personal email'), matching: find.byType(TextField)).first,
      'not-an-address',
    );
    await save(tester);

    // Under the field it belongs to, not as a banner over a form of seven.
    expect(find.text('That is not a valid address.'), findsOneWidget);

    session.dispose();
  });

  testWidgets('an account with no employee record is not offered the button',
      (tester) async {
    final session = await signedIn(tester, withEmployee: false);

    await pumpProfile(tester, session);

    // There is no record to write to, and the endpoint would 403. A button
    // that reliably produces a refusal is a trap.
    expect(find.text('Home & emergency contact'), findsNothing);

    session.dispose();
  });
}
