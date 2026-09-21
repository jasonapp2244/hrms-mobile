import 'dart:convert';
import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/locale.dart';
import 'package:attendance/core/models.dart' show AppUser;
import 'package:attendance/core/offline_cache.dart';
import 'package:attendance/core/session.dart';
import 'package:attendance/core/theme.dart';
import 'package:attendance/l10n/generated/app_localizations.dart';
import 'package:attendance/main.dart';
import 'package:attendance/screens/hr_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// HR's area in the app (client requirement, 2026-09-22).
///
/// **The gate is the half worth testing hardest.** This tab decides company
/// leave — approving from it spends somebody's balance — and the same mistake
/// has already been made once on this codebase in the other direction: the Team
/// tab used to hang off `approve-leave` alone, which gave every HR user a
/// permanently empty manager inbox. The rule then lived in Dart and in the
/// route table at once.
///
/// So it lives on the server now and the app reads it. What these tests pin is
/// that the app really does read it — including the case that matters most, an
/// older server that sends no answer at all, where the tab must be **absent**
/// rather than assumed.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('hr_area_test');
    FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});
  });

  tearDown(() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // The cache writes without the test awaiting it, so on Windows the file
      // can still be held open when the test ends. Harness tidying.
    }
  });

  // -------------------------------------------------------------------------
  // The gate, as pure data
  // -------------------------------------------------------------------------

  group('capabilities', () {
    AppUser user(Map<String, dynamic> extra) => AppUser.fromJson({
          'id': 1,
          'name': 'Hal HR',
          'email': 'hr@acme.test',
          'roles': ['hr'],
          'permissions': ['approve-leave', 'manage-leave', 'manage-employees'],
          ...extra,
        });

    test('HR is given the desk when the server says so', () {
      final hr = user({
        'can': {
          'lead_team': false,
          'decide_leave': true,
          'view_employees': true,
        },
      });

      expect(hr.decidesLeave, isTrue);
      expect(hr.viewsEmployees, isTrue);
      expect(hr.hasHrArea, isTrue);
      // And still no Team tab: HR holds approve-leave and leads nobody, which
      // is the pair this whole design exists to tell apart.
      expect(hr.leadsATeam, isFalse);
    });

    test('a manager gets the team and not the desk', () {
      final manager = user({
        'permissions': ['approve-leave'],
        'employee': {'id': 2, 'full_name': 'Mia', 'is_manager': true},
        'can': {
          'lead_team': true,
          'decide_leave': false,
          'view_employees': false,
        },
      });

      expect(manager.leadsATeam, isTrue);
      expect(manager.hasHrArea, isFalse);
    });

    test('an older server with no can block gets no HR area at all', () {
      // The important direction. `decide_leave` has no local fallback on
      // purpose: an app that cannot ask whether it may spend leave balance must
      // not decide for itself that it may.
      final hr = user({});

      expect(hr.can, isNull);
      expect(hr.decidesLeave, isFalse);
      expect(hr.viewsEmployees, isFalse);
      expect(hr.hasHrArea, isFalse);
    });

    test('the Team tab still works against an older server', () {
      // The one rule that keeps its local fallback, because it predates the
      // `can` block and an app talking to an older server should not lose a
      // feature it already had.
      final manager = user({
        'permissions': ['approve-leave'],
        'employee': {'id': 2, 'full_name': 'Mia', 'is_manager': true},
      });

      expect(manager.can, isNull);
      expect(manager.leadsATeam, isTrue);
    });

    test('a manager with nobody reporting to them gets no team', () {
      final lonely = user({
        'permissions': ['approve-leave'],
        'employee': {'id': 2, 'full_name': 'Mia', 'is_manager': false},
      });

      expect(lonely.leadsATeam, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // The screen
  // -------------------------------------------------------------------------

  group('the HR screen', () {
    late List<String> asked;

    Session hrSession(
      WidgetTester tester, {
      bool decideLeave = true,
      bool viewEmployees = true,
      Map<String, dynamic>? pending,
    }) {
      asked = <String>[];

      return Session(
        cache: OfflineCache(directory: dir),
        api: ApiClient(
          client: MockClient((request) async {
            asked.add(request.url.path);

            if (request.url.path.endsWith('/auth/me')) {
              return _json({
                'ok': true,
                'user': {
                  'id': 1,
                  'name': 'Hal HR',
                  'email': 'hr@acme.test',
                  'roles': ['hr'],
                  'permissions': ['approve-leave', 'manage-leave'],
                  'employee': {
                    'id': 6,
                    'full_name': 'Hal HR',
                    'is_manager': false,
                  },
                  'can': {
                    'lead_team': false,
                    'decide_leave': decideLeave,
                    'view_employees': viewEmployees,
                  },
                },
              });
            }

            if (request.url.path.contains('/hr/leave/approvals')) {
              return _json(
                pending ?? {'ok': true, 'pending': [], 'pending_count': 0},
              );
            }

            // The sibling calls answer empty so none of them throws while the
            // tab under test is doing its work.
            return _json({
              'ok': true,
              'requests': [],
              'pending': [],
              'people': [],
            });
          }),
        ),
      );
    }

    /// Sign in and draw the screen.
    ///
    /// `restore()` runs inside `runAsync` because it touches the keystore and
    /// the disk cache, and a pumped clock never gives either of them real time
    /// — the future simply never completes and the test hangs rather than
    /// failing.
    Future<void> pumpHr(WidgetTester tester, Session session) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(390, 844));

      await tester.runAsync(() => session.restore());

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocale.supported,
        home: SessionScope(
          notifier: session,
          child: HrScreen(visible: ValueNotifier(true)),
        ),
      ));

      // A load is a chain of continuations that only advance when the disk and
      // the mock client are given real time, so the two have to alternate.
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('an empty queue says why rather than showing nothing',
        (tester) async {
      await pumpHr(tester, hrSession(tester));

      expect(find.text('Nothing waiting'), findsOneWidget);
      // Named rather than left blank: a queue that is empty because requests
      // are still with a manager reads exactly like a broken fetch.
      expect(
        find.textContaining('once a line manager has seconded them'),
        findsOneWidget,
      );
    });

    testWidgets('a waiting request carries the balance and the manager step',
        (tester) async {
      await pumpHr(
        tester,
        hrSession(tester, pending: {
          'ok': true,
          'pending_count': 1,
          'pending': [
            {
              'id': 7,
              'employee': 'Ann Lee',
              'department': 'Ops',
              'leave_type': 'Annual Leave',
              'start_date': '2026-11-02',
              'end_date': '2026-11-03',
              'days': 2,
              'is_half_day': false,
              'manager_approved_by': 'Mia Manager',
              'manager_note': 'Cover arranged.',
              'balance': {
                'entitled': 20,
                'used': 4,
                'available': 16,
                'capped': true,
                'would_exceed': false,
              },
              'clashes': [],
            },
          ],
        }),
      );

      expect(find.text('Ann Lee'), findsOneWidget);
      // The number that decides the answer.
      expect(find.textContaining('16 of 20 days left'), findsOneWidget);
      // Seconded, rather than arriving unread.
      expect(find.textContaining('Seconded by Mia Manager'), findsOneWidget);
      expect(find.text('Cover arranged.'), findsOneWidget);
    });

    testWidgets('a request that would overspend says so before the tap',
        (tester) async {
      // The server makes the same comparison `approve()` will make. Finding
      // out after the tap is the web's behaviour; a phone should warn first.
      await pumpHr(
        tester,
        hrSession(tester, pending: {
          'ok': true,
          'pending_count': 1,
          'pending': [
            {
              'id': 7,
              'employee': 'Ann Lee',
              'leave_type': 'Annual Leave',
              'start_date': '2026-11-02',
              'end_date': '2026-11-03',
              'days': 2,
              'is_half_day': false,
              'balance': {
                'entitled': 20,
                'used': 19,
                'available': 1,
                'capped': true,
                'would_exceed': true,
              },
              'clashes': [],
            },
          ],
        }),
      );

      expect(find.textContaining('past their entitlement'), findsOneWidget);
    });

    testWidgets('an employee with no line manager is named as such',
        (tester) async {
      // Absent is an answer, not a gap: somebody who reports to nobody skips
      // the manager step by design, and a blank there would read as a request
      // that slipped through it.
      await pumpHr(
        tester,
        hrSession(tester, pending: {
          'ok': true,
          'pending_count': 1,
          'pending': [
            {
              'id': 7,
              'employee': 'Ann Lee',
              'leave_type': 'Annual Leave',
              'start_date': '2026-11-02',
              'end_date': '2026-11-03',
              'days': 2,
              'is_half_day': false,
              'manager_approved_by': null,
              'clashes': [],
            },
          ],
        }),
      );

      expect(find.textContaining('reports to nobody'), findsOneWidget);
    });

    testWidgets('only the granted half of the area is drawn', (tester) async {
      // A client who wants the register and not the desk, or the reverse. One
      // capability means one tab and no tab bar to choose between.
      await pumpHr(tester, hrSession(tester, decideLeave: false));

      expect(find.byType(TabBar), findsNothing,
          reason: 'a single area needs no tab bar');
      // And the queue was never asked for, because its tab does not exist.
      expect(asked.where((p) => p.contains('/hr/leave/approvals')), isEmpty);
    });
  });
}

http.Response _json(Map<String, dynamic> body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
