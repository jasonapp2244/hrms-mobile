import 'dart:convert';
import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/l10n.dart';
import 'package:attendance/core/locale.dart';
import 'package:attendance/core/location.dart';
// The models library exports its own `Directory` — the company one, B3.8 —
// which would shadow dart:io's for the temp folders below.
import 'package:attendance/core/models.dart' hide Directory;
import 'package:attendance/core/offline_cache.dart';
import 'package:attendance/core/punch_queue.dart';
import 'package:attendance/core/push.dart';
import 'package:attendance/core/session.dart';
import 'package:attendance/main.dart';
import 'package:attendance/screens/notifications_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

/// The notification history (B5.6).
///
/// The point of the screen is that a notification survives the OS banner being
/// swiped away, so what is worth pinning is the parsing — including a route
/// this build has never heard of, which is the exact failure that made every
/// roster push land nowhere for months — and the badge, which is the only
/// piece of shared state the rest of the app reads.
void main() {
  group('parsing a row', () {
    test('reads what the server publishes', () {
      final n = AppNotification.fromJson({
        'id': '9b1f-aaaa',
        'type': 'leave.approved',
        'title': 'Your leave was approved',
        'body': 'Your Annual Leave for 12 to 14 Sep has been approved.',
        'route': 'leave',
        'read_at': null,
        'created_at': '2026-09-09T14:02:11+00:00',
      });

      expect(n.id, '9b1f-aaaa');
      expect(n.type, 'leave.approved');
      expect(n.route, PushRoute.leave);
      expect(n.isUnread, isTrue);
    });

    test('a route this build has never heard of is not a crash', () {
      // The failure that made every roster notification land nowhere: the
      // server sent `schedule` for months and the enum had no row for it.
      // Parsing through the same enum a push tap uses keeps them one list.
      final n = AppNotification.fromJson({
        'id': 'x',
        'title': 'Something new',
        'route': 'payroll',
        'created_at': '2026-09-09T14:02:11+00:00',
      });

      expect(n.route, isNull);
    });

    test('a notification with nowhere to go parses fine', () {
      // Addressed to HR, who work at a desk. Null is the honest answer.
      final n = AppNotification.fromJson({
        'id': 'y',
        'type': 'document_expiring',
        'title': 'An ID expires soon',
        'route': null,
        'read_at': '2026-09-09T15:00:00+00:00',
        'created_at': '2026-09-09T14:02:11+00:00',
      });

      expect(n.route, isNull);
      expect(n.isUnread, isFalse);
    });

    test('a row missing everything optional is still readable', () {
      // The server guarantees four keys; a body is not one of them.
      final n = AppNotification.fromJson({'id': 'z', 'created_at': ''});

      // Empty rather than an English fallback: the word for an untitled
      // notification is the screen's to choose, in the reader's language (B6.2).
      expect(n.title, isEmpty);
      expect(n.body, isNull);
      expect(n.type, isNull);
      expect(n.isUnread, isTrue);
    });
  });

  group('the badge', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('notifications_test');
      FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});
    });

    tearDown(() async {
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } on FileSystemException {
        // Windows can hold a file the app wrote without awaiting.
      }
    });

    Map<String, dynamic> me() => {
          'user': {
            'id': 3,
            'name': 'James Smith',
            'email': 'james@acme.test',
            'roles': ['employee'],
            'permissions': ['view-attendance'],
            'employee': {
              'id': 1,
              'employee_code': 'EMP-0001',
              'full_name': 'James Smith',
              'is_manager': false,
            },
          },
        };

    /// Answers `/auth/me` and `/notifications`, and records what was asked.
    ({ApiClient client, List<String> calls}) api({
      int unread = 0,
      List<Map<String, dynamic>> notifications = const [],
      Object? notificationsThrow,
    }) {
      final calls = <String>[];

      final client = ApiClient(
        client: MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');

          if (request.url.path.contains('/notifications')) {
            if (notificationsThrow != null) throw notificationsThrow;

            return http.Response(
              jsonEncode({
                'ok': true,
                'notifications': notifications,
                'unread': unread,
                'meta': {'current_page': 1, 'last_page': 1, 'per_page': 25, 'total': notifications.length},
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }

          return http.Response(
            jsonEncode({'ok': true, ...me()}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      return (client: client, calls: calls);
    }

    Session session(ApiClient client) => Session(
          api: client,
          cache: OfflineCache(directory: dir),
          queue: PunchQueue(directory: dir),
          locator: const PunchLocator(source: NoLocationSource()),
        );

    test('a launch asks for the count', () async {
      final fake = api(unread: 4);
      final s = session(fake.client);

      await s.restore();
      // refreshUnread is fired without being awaited, so let it land.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(s.unreadNotifications.value, 4);

      s.dispose();
    });

    test('no signal leaves the last count alone rather than zeroing it',
        () async {
      // A badge is not worth an error, and a handset on a site with no
      // reception should not be told it has nothing waiting.
      final s = session(api(notificationsThrow: const SocketException('offline')).client);

      await s.restore();
      s.unreadNotifications.value = 3;
      await s.refreshUnread();

      expect(s.unreadNotifications.value, 3);

      s.dispose();
    });

    test('nobody signed in is asked nothing', () async {
      FlutterSecureStorage.setMockInitialValues({});

      final fake = api(unread: 9);
      final s = session(fake.client);

      await s.refreshUnread();

      expect(fake.calls, isEmpty);
      expect(s.unreadNotifications.value, 0);

      s.dispose();
    });

    test('signing out clears it', () async {
      final s = session(api(unread: 7).client);
      await s.restore();
      await s.refreshUnread();
      expect(s.unreadNotifications.value, 7);

      await s.logout();

      // The next person on a shared handset must not inherit somebody else's
      // count.
      expect(s.unreadNotifications.value, 0);

      s.dispose();
    });
  });

  group('on screen', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('notifications_screen_test');
      FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});
    });

    tearDown(() async {
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } on FileSystemException {
        // As above.
      }
    });

    Future<Session> primed(
      WidgetTester tester,
      List<Map<String, dynamic>> notifications, {
      int unread = 0,
    }) async {
      late Session session;

      await tester.runAsync(() async {
        final queue = PunchQueue(directory: dir);
        await queue.load();

        session = Session(
          api: ApiClient(
            client: MockClient((request) async => http.Response(
                  jsonEncode({
                    'ok': true,
                    'notifications': notifications,
                    'unread': unread,
                  }),
                  200,
                  headers: {'content-type': 'application/json'},
                )),
          ),
          cache: OfflineCache(directory: dir),
          queue: queue,
          locator: const PunchLocator(source: NoLocationSource()),
        );
      });

      return session;
    }

    Widget app(Session session) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocale.supported,
          home: SessionScope(
            notifier: session,
            child: const NotificationsScreen(),
          ),
        );

    testWidgets('a message is readable after the banner is gone',
        (tester) async {
      final session = await primed(tester, [
        {
          'id': 'a',
          'type': 'leave.approved',
          'title': 'Your leave was approved',
          'body': 'Your Annual Leave for 12 to 14 Sep has been approved.',
          'route': 'leave',
          'read_at': null,
          'created_at': '2026-09-09T14:02:11+00:00',
        },
      ], unread: 1);

      await tester.pumpWidget(app(session));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Your leave was approved'), findsOneWidget);
      // The whole message, not a truncated banner's worth of it.
      expect(
        find.text('Your Annual Leave for 12 to 14 Sep has been approved.'),
        findsOneWidget,
      );
      // Somewhere to go, named by the tab that answers it.
      expect(find.text('Open Leave'), findsOneWidget);
      expect(find.text('Mark all read'), findsOneWidget);

      // And the badge behind this screen now agrees with the server.
      expect(session.unreadNotifications.value, 1);

      await tester.pumpWidget(const SizedBox());
      session.dispose();
    });

    testWidgets('one with nowhere to go offers no button', (tester) async {
      final session = await primed(tester, [
        {
          'id': 'b',
          'type': 'document_expiring',
          'title': 'An ID expires soon',
          'body': 'Ann Lee\'s passport expires in 30 days.',
          'route': null,
          'read_at': '2026-09-09T15:00:00+00:00',
          'created_at': '2026-09-09T14:02:11+00:00',
        },
      ]);

      await tester.pumpWidget(app(session));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('An ID expires soon'), findsOneWidget);
      expect(find.textContaining('Open '), findsNothing);
      // Nothing unread, so nothing to mark.
      expect(find.text('Mark all read'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      session.dispose();
    });

    testWidgets('an empty history says what will appear here', (tester) async {
      final session = await primed(tester, const []);

      await tester.pumpWidget(app(session));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Nothing yet'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      session.dispose();
    });
  });
}
