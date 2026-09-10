import 'dart:convert';
import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/l10n.dart';
import 'package:attendance/core/locale.dart';
import 'package:attendance/core/location.dart';
import 'package:attendance/core/offline_cache.dart';
import 'package:attendance/core/punch_queue.dart';
import 'package:attendance/core/session.dart';
import 'package:attendance/main.dart';
import 'package:attendance/screens/punch_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The offline cache (B6.3).
///
/// The interesting behaviour is all in what it refuses. A cache that serves a
/// saved copy over a 403 hides an account that lost its employee record; one
/// that serves yesterday's clock screen tells somebody they are already at
/// work; and one that outlives a sign-out hands the next person on a shared
/// handset the previous person's roster.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('offline_cache_test');
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  OfflineCache cache() => OfflineCache(directory: dir);

  File cacheFile() => File('${dir.path}${Platform.pathSeparator}offline_cache.json');

  /// An API that answers every GET with [body], or refuses with [error].
  ApiClient api({
    Map<String, dynamic>? body,
    ApiException? refuse,
    bool offline = false,
    List<String>? calls,
  }) =>
      ApiClient(
        client: MockClient((request) async {
          calls?.add(request.url.path);

          if (offline) throw const SocketException('no route to host');

          if (refuse != null) {
            return http.Response(
              jsonEncode({
                'ok': false,
                'error': refuse.error,
                'message': refuse.message,
              }),
              refuse.statusCode ?? 400,
              headers: {'content-type': 'application/json'},
            );
          }

          return http.Response(
            jsonEncode({'ok': true, ...?body}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

  group('serving a saved copy', () {
    test('a fresh answer is not stale, and is kept', () async {
      final store = cache();

      final res = await store.fetch(
        api(body: {'days': []}),
        '/schedule',
        key: OfflineCache.keySchedule,
      );

      expect(res.isStale, isFalse);
      expect(res.cachedAt, isNull);

      // Kept, and readable by a second instance — the app is force-quit
      // between launches and the cache has to survive that.
      final reopened = await cache().read(OfflineCache.keySchedule);
      expect(reopened, isNotNull);
      expect(reopened!.body['days'], isEmpty);
      expect(reopened.cachedAt, isNotNull);
    });

    test('a request that never arrives falls back to the saved copy', () async {
      final store = cache();

      await store.fetch(
        api(body: {'days': ['monday']}),
        '/schedule',
        key: OfflineCache.keySchedule,
      );

      final offline = await store.fetch(
        api(offline: true),
        '/schedule',
        key: OfflineCache.keySchedule,
      );

      expect(offline.isStale, isTrue);
      expect(offline.cachedAt, isNotNull);
      expect(offline.body['days'], ['monday']);
    });

    test('with nothing saved, a dead network is still an error', () async {
      // Otherwise the first launch on a handset with no signal would show an
      // empty roster rather than saying it could not be fetched.
      expect(
        () => cache().fetch(
          api(offline: true),
          '/schedule',
          key: OfflineCache.keySchedule,
        ),
        throwsA(isA<ApiException>().having((e) => e.isNetworkFailure, 'network', isTrue)),
      );
    });
  });

  group('what is refused', () {
    test('a refusal is an answer, and is not papered over', () async {
      final store = cache();

      await store.fetch(
        api(body: {'days': ['monday']}),
        '/schedule',
        key: OfflineCache.keySchedule,
      );

      // The account lost its employee record between the two calls. Serving
      // the saved roster would hide that entirely.
      expect(
        () => store.fetch(
          api(refuse: ApiException(
            error: 'forbidden',
            message: 'No employee record is linked to this account.',
            statusCode: 403,
          )),
          '/schedule',
          key: OfflineCache.keySchedule,
        ),
        throwsA(isA<ApiException>().having((e) => e.error, 'error', 'forbidden')),
      );
    });

    test('a copy that has expired on its own is not served', () async {
      final store = cache();

      await store.fetch(
        api(body: {'date': '2026-08-03', 'next_action': 'out'}),
        '/attendance/today',
        key: OfflineCache.keyToday,
      );

      // Yesterday's clock screen says "clocked in since 09:00". Showing it
      // this morning would have somebody believe they had already started.
      expect(
        () => store.fetch(
          api(offline: true),
          '/attendance/today',
          key: OfflineCache.keyToday,
          stillValid: (body) => body['date'] == '2026-08-04',
        ),
        throwsA(isA<ApiException>()),
      );

      // And the same copy is served when it is still today.
      final same = await store.fetch(
        api(offline: true),
        '/attendance/today',
        key: OfflineCache.keyToday,
        stillValid: (body) => body['date'] == '2026-08-03',
      );

      expect(same.isStale, isTrue);
    });

    test('the ranges do not answer for each other', () async {
      final store = cache();

      await store.fetch(
        api(body: {'days': ['a week']}),
        '/attendance/history',
        key: OfflineCache.historyKey(7),
      );

      // Nothing saved for 30 days, so offline it fails rather than showing a
      // week's rows under a month's heading.
      expect(
        () => store.fetch(
          api(offline: true),
          '/attendance/history',
          key: OfflineCache.historyKey(30),
        ),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('surviving the file', () {
    test('a corrupt cache is an empty cache, not a dead app', () async {
      await cacheFile().writeAsString('{ this is not json');

      expect(await cache().read(OfflineCache.keySchedule), isNull);

      // And it recovers: the next good answer overwrites the mess.
      final store = cache();
      await store.write(OfflineCache.keySchedule, {'days': []});
      expect(await cache().read(OfflineCache.keySchedule), isNotNull);
    });

    test('an entry it cannot read is skipped, not fatal', () async {
      await cacheFile().writeAsString(jsonEncode({
        'left.behind': 'a string where an entry should be',
        OfflineCache.keySchedule: {
          'saved_at': DateTime.now().toUtc().toIso8601String(),
          'body': {'days': []},
        },
      }));

      expect(await cache().read('left.behind'), isNull);
      expect(await cache().read(OfflineCache.keySchedule), isNotNull);
    });

    test('clear leaves nothing behind', () async {
      final store = cache();
      await store.write(OfflineCache.keySchedule, {'days': []});
      await store.clear();

      expect(await store.read(OfflineCache.keySchedule), isNull);
      // On disk too, not only in memory — the next launch reads the file.
      expect(await cache().read(OfflineCache.keySchedule), isNull);
    });
  });

  // Opening the app with no signal at all. Without this the offline punch
  // queue is close to unreachable: restore fails, the login screen appears,
  // and login needs the network too.
  group('opening offline', () {
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

    Session session(ApiClient client) =>
        Session(api: client, cache: cache());

    test('a verified launch caches the user and is not offline', () async {
      FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});

      final s = session(api(body: me()));
      await s.restore();

      expect(s.isSignedIn, isTrue);
      expect(s.isOffline, isFalse);
      expect(s.offlineSince, isNull);
      expect(await cache().read(OfflineCache.keyProfile), isNotNull);

      s.dispose();
    });

    test('a launch with no signal opens on the saved user', () async {
      FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});

      final first = session(api(body: me()));
      await first.restore();
      first.dispose();

      final calls = <String>[];
      final second = session(api(offline: true, calls: calls));
      await second.restore();

      expect(second.isSignedIn, isTrue);
      expect(second.user?.employee?.employeeCode, 'EMP-0001');
      expect(second.isOffline, isTrue);
      expect(second.offlineSince, isNotNull);
      expect(second.restoreError, isNull);
      // It did try first. Trying is the only honest test of a connection.
      expect(calls, ['/api/v1/auth/me']);

      second.dispose();
    });

    test('with nothing saved it still asks for a sign-in', () async {
      FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});

      final s = session(api(offline: true));
      await s.restore();

      expect(s.isSignedIn, isFalse);
      expect(s.restoreError, isNotNull);

      s.dispose();
    });

    test('a cached identity past the grace is refused', () async {
      FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});

      final tooOld = DateTime.now()
          .subtract(Session.offlineIdentityGrace + const Duration(days: 1));

      await cacheFile().writeAsString(jsonEncode({
        OfflineCache.keyProfile: {
          'saved_at': tooOld.toUtc().toIso8601String(),
          'body': me(),
        },
      }));

      final s = session(api(offline: true));
      await s.restore();

      // Roles, permissions and whether somebody still works here are only
      // re-read when the server is reachable. Past the grace the app stops
      // trusting what it last knew.
      expect(s.isSignedIn, isFalse);
      expect(s.restoreError, isNotNull);

      s.dispose();
    });

    test('a revoked token takes the saved copy with it', () async {
      FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});

      final first = session(api(body: me()));
      await first.restore();
      first.dispose();

      final revoked = session(api(refuse: ApiException(
        error: 'unauthenticated',
        message: 'Unauthenticated.',
        statusCode: 401,
      )));
      await revoked.restore();

      expect(revoked.isSignedIn, isFalse);
      // Signed out on another device after a lost phone. Leaving the copy
      // would let the handset reopen offline as somebody who was signed out.
      expect(await cache().read(OfflineCache.keyProfile), isNull);

      revoked.dispose();
    });

    test('signing out takes it too', () async {
      FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});

      final s = session(api(body: me()));
      await s.restore();
      await s.logout();

      expect(await cache().read(OfflineCache.keyProfile), isNull);

      s.dispose();
    });

    test('the bearer token is never written to the cache file', () async {
      final s = session(api(body: {'token': 'secret-bearer-token', ...me()}));
      await s.login(email: 'james@acme.test', password: 'password');

      expect(s.isSignedIn, isTrue);

      // The cache is a plain JSON file; the token lives in the keystore
      // precisely so that it never lands in one.
      expect(await cacheFile().readAsString(), isNot(contains('secret-bearer-token')));

      s.dispose();
    });
  });

  // The clock screen is the one that matters most with no signal: it carries
  // the button B2.4's queue is filled from. Before B6.3 the first refresh
  // after the signal went replaced the whole screen with a "try again", and
  // there was no way left to record that somebody had turned up.
  //
  // Every disk touch here happens inside `runAsync`. `testWidgets` runs in a
  // fake-async zone that never delivers a real file completion, so a `pump`
  // that reaches the cache or the queue hangs the whole test rather than
  // failing it. Priming both stores first leaves the pumped screen reading
  // memory, which is what it does on a real handset after the first launch
  // anyway.
  group('the clock screen with no signal', () {
    Map<String, dynamic> employee() => {
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

    Widget app(Session session) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocale.supported,
          home: SessionScope(
            notifier: session,
            child: PunchScreen(visible: ValueNotifier<bool>(true)),
          ),
        );

    Session clockSession(OfflineCache store, PunchQueue queue) => Session(
          api: api(offline: true),
          cache: store,
          queue: queue,
          // No platform channel in a headless test, and a punch is never lost
          // to a missing coordinate anyway.
          locator: const PunchLocator(source: NoLocationSource()),
        );

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('offers a punch when today cannot be read at all',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});

      late final Session session;

      await tester.runAsync(() async {
        final store = cache();
        await store.write(OfflineCache.keyProfile, employee());

        final queue = PunchQueue(directory: dir);
        await queue.load();

        session = clockSession(store, queue);
        await session.restore();
      });

      // Signed in from the saved copy, and nothing saved for today — the
      // ordinary case of arriving at a site having last opened the app
      // yesterday evening.
      expect(session.isOffline, isTrue);

      await tester.pumpWidget(app(session));
      await settle(tester);

      expect(find.text('No connection'), findsOneWidget);
      expect(find.text('Save a punch'), findsOneWidget);
      // Not the error page. Its only offer is "Try again", which is the one
      // thing that cannot work here.
      expect(find.byIcon(Icons.refresh), findsOneWidget); // the app bar's
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.pumpWidget(const SizedBox());
      session.dispose();
    });

    testWidgets("today's saved copy is shown, and labelled", (tester) async {
      FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});

      final now = DateTime.now();
      final ymd = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';

      late final Session session;

      await tester.runAsync(() async {
        final store = cache();
        await store.write(OfflineCache.keyProfile, employee());
        await store.write(OfflineCache.keyToday, {
          'date': ymd,
          'next_action': 'out',
          'is_clocked_in': true,
          'worked_minutes': 125,
          'punches': const [],
        });

        final queue = PunchQueue(directory: dir);
        await queue.load();

        session = clockSession(store, queue);
        await session.restore();
      });

      await tester.pumpWidget(app(session));
      await settle(tester);

      expect(find.text('Clocked in'), findsOneWidget);
      expect(find.text('2h 5m'), findsOneWidget);
      // Never unlabelled: a card that is quietly three hours old is worse than
      // no card, because nothing on it gives a reason to doubt it.
      expect(
        find.textContaining('Offline — showing the copy saved'),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox());
      session.dispose();
    });
  });
}
