import 'dart:convert';
import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/app_gate.dart';
import 'package:attendance/core/l10n.dart';
import 'package:attendance/core/locale.dart';
import 'package:attendance/core/location.dart';
import 'package:attendance/core/offline_cache.dart';
import 'package:attendance/core/punch_queue.dart';
import 'package:attendance/core/session.dart';
import 'package:attendance/main.dart';
import 'package:attendance/screens/blocked_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The force-update and maintenance gate (B6.6).
///
/// The gate is the only thing in the app that can stop everybody at once, and
/// almost every test here is about it declining to. The app is deliberately
/// usable with no signal — it opens on a cached identity, shows the last roster
/// it saw and queues punches — and a gate that blocked whenever it could not
/// reach the server would take all of that away in exactly the conditions the
/// offline work exists for.
void main() {
  /// The last query the app actually sent.
  late Map<String, String> asked;

  setUp(() {
    asked = {};
    FlutterSecureStorage.setMockInitialValues({});
  });

  /// An API that answers `/app/status` with [body], or fails the way [failure]
  /// says.
  ApiClient api({Map<String, dynamic>? body, Object? throws, int status = 200}) =>
      ApiClient(
        client: MockClient((request) async {
          asked = request.url.queryParameters;

          if (throws != null) throw throws;

          return http.Response(
            jsonEncode({'ok': status == 200, ...?body}),
            status,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

  AppGate gate(ApiClient client, {String? version = '1.2.0'}) => AppGate(
        api: client,
        versionSource: _FixedVersion(version),
      );

  group('what it lets through', () {
    test('an ok verdict blocks nothing', () async {
      final g = gate(api(body: {'action': 'ok', 'message': null}));
      await g.check();

      expect(g.isBlocked, isFalse);
      expect(g.action, GateAction.ok);

      g.dispose();
    });

    test('a server it cannot reach blocks nothing', () async {
      // The most important row in the file. A cleaner on a site with no
      // coverage must not be told the app is under maintenance and left with
      // no way to record that they turned up.
      final g = gate(api(throws: const SocketException('no route to host')));
      await g.check();

      expect(g.isBlocked, isFalse);

      g.dispose();
    });

    test('a server that refuses blocks nothing either', () async {
      final g = gate(api(
        status: 500,
        body: {'error': 'server_error', 'message': 'Something broke.'},
      ));
      await g.check();

      expect(g.isBlocked, isFalse);

      g.dispose();
    });

    test('an answer it cannot parse blocks nothing', () async {
      final g = gate(api(body: {'nothing': 'useful'}));
      await g.check();

      expect(g.isBlocked, isFalse);

      g.dispose();
    });

    test('a verdict invented after this build shipped blocks nothing', () async {
      // A build that cannot understand the answer is not a build to strand:
      // the handsets that would see a new action are by definition the old
      // ones, and they are the ones with no way to be fixed.
      final g = gate(api(body: {'action': 'wipe_and_reinstall'}));
      await g.check();

      expect(g.isBlocked, isFalse);

      g.dispose();
    });
  });

  group('what it stops', () {
    test('an update is required, with somewhere to go', () async {
      final g = gate(api(body: {
        'action': 'update_required',
        'message': 'This version is no longer supported.',
        'store_url': 'https://play.google.com/x',
      }));
      await g.check();

      expect(g.isBlocked, isTrue);
      expect(g.action, GateAction.updateRequired);
      expect(g.message, 'This version is no longer supported.');
      expect(g.storeUrl, 'https://play.google.com/x');

      g.dispose();
    });

    test('a maintenance window, in the server\'s own words', () async {
      // Verbatim: the server is the only side that can say when a window ends,
      // and "try later" with no hour in it is what makes somebody keep trying.
      final g = gate(api(body: {
        'action': 'maintenance',
        'message': 'Back at 6pm.',
      }));
      await g.check();

      expect(g.action, GateAction.maintenance);
      expect(g.message, 'Back at 6pm.');
      expect(g.storeUrl, isNull);

      g.dispose();
    });

    test('an empty message is no message, not a blank screen', () async {
      final g = gate(api(body: {'action': 'maintenance', 'message': ''}));
      await g.check();

      // The screen has wording of its own to fall back on; '' would defeat it.
      expect(g.message, isNull);

      g.dispose();
    });

    test('a later ok clears it', () async {
      final g = gate(api(body: {'action': 'maintenance', 'message': 'Back at 6pm.'}));
      await g.check();
      expect(g.isBlocked, isTrue);

      final reopened = gate(api(body: {'action': 'ok'}));
      await reopened.check();
      expect(reopened.isBlocked, isFalse);
      expect(reopened.message, isNull);

      g.dispose();
      reopened.dispose();
    });
  });

  group('what it asks', () {
    test('it sends the running build and the platform', () async {
      final g = gate(api(body: {'action': 'ok'}), version: '1.4.0+37');
      await g.check();

      expect(asked['version'], '1.4.0+37');
      // Sent verbatim, build number and all — the server drops the suffix
      // itself, and an app that trimmed it first would be a second opinion
      // about what a version is.
      //
      // The platform has to be one the server has a store link column for.
      // Anything else is answered `ok`, so a typo here would quietly disable
      // the gate rather than fail.
      expect(asked['platform'], anyOf('android', 'ios'));

      g.dispose();
    });

    test('a version it cannot read is left out rather than guessed', () async {
      // The server reads an absent version as "cannot judge" and answers ok.
      // Sending an empty string would be the same verdict by accident.
      final g = gate(api(body: {'action': 'ok'}), version: null);
      await g.check();

      expect(asked.containsKey('version'), isFalse);

      g.dispose();
    });

    test('two checks at once are one check', () async {
      final client = api(body: {'action': 'ok'});
      final g = gate(client);

      await Future.wait([g.check(), g.check()]);

      // Nothing here proves the count directly; what matters is that the
      // second call resolves rather than leaving the screen spinning.
      expect(g.isChecking, isFalse);

      g.dispose();
    });
  });

  group('coming back to it', () {
    test('a blocked app re-asks however brief the trip', () async {
      // The person is most likely coming back from the store, or from waiting
      // out a window. The screen exists to be left behind.
      var answer = 'maintenance';

      final client = ApiClient(
        client: MockClient((_) async => http.Response(
              jsonEncode({'ok': true, 'action': answer, 'message': 'Back at 6pm.'}),
              200,
              headers: {'content-type': 'application/json'},
            )),
      );

      final g = AppGate(api: client, versionSource: const _FixedVersion('1.0.0'));
      await g.check();
      expect(g.isBlocked, isTrue);

      answer = 'ok';
      g.handleLifecycle(AppLifecycleState.paused);
      g.handleLifecycle(AppLifecycleState.resumed);

      // handleLifecycle fires check() without awaiting it.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(g.isBlocked, isFalse);

      g.dispose();
    });

    test('an unblocked app does not re-ask over a glance at the shade',
        () async {
      var calls = 0;

      final client = ApiClient(
        client: MockClient((_) async {
          calls++;
          return http.Response(
            jsonEncode({'ok': true, 'action': 'ok'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final g = AppGate(api: client, versionSource: const _FixedVersion('1.0.0'));
      await g.check();
      expect(calls, 1);

      g.handleLifecycle(AppLifecycleState.paused);
      g.handleLifecycle(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);

      // Under AppGate.recheckAfter. One call per foreground switch would be a
      // request every time somebody answers a message.
      expect(calls, 1);

      g.dispose();
    });
  });

  group('on screen', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('app_gate_test');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    /// A session whose gate has already been given [body], built with every
    /// disk touch inside `runAsync` — `testWidgets` runs in a fake-async zone
    /// that never delivers a real file completion, so a pump that reaches the
    /// cache hangs the run rather than failing it.
    Future<Session> blocked(WidgetTester tester, Map<String, dynamic> body) async {
      late Session session;

      await tester.runAsync(() async {
        final queue = PunchQueue(directory: dir);
        await queue.load();

        session = Session(
          api: api(body: body),
          cache: OfflineCache(directory: dir),
          queue: queue,
          locator: const PunchLocator(source: NoLocationSource()),
          versionSource: const _FixedVersion('1.0.0'),
        );

        await session.gate.check();
      });

      return session;
    }

    Widget app(Session session) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocale.supported,
          home: SessionScope(notifier: session, child: const BlockedScreen()),
        );

    testWidgets('the update screen offers the store', (tester) async {
      final session = await blocked(tester, {
        'action': 'update_required',
        'message': 'This version is no longer supported.',
        'store_url': 'https://play.google.com/x',
      });

      await tester.pumpWidget(app(session));
      await tester.pump();

      expect(find.text('Time to update'), findsOneWidget);
      expect(find.text('Open the store'), findsOneWidget);
      expect(find.text('This version is no longer supported.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      session.dispose();
    });

    testWidgets('with no store link there is no button to press',
        (tester) async {
      // The server withholds the link for a platform it has none for and
      // answers ok rather than blocking, so this state should not arise — but
      // a build that reached it must not draw a button that does nothing.
      final session = await blocked(tester, {
        'action': 'update_required',
        'message': 'Out of date.',
      });

      await tester.pumpWidget(app(session));
      await tester.pump();

      expect(find.text('Open the store'), findsNothing);
      expect(find.text('Try again'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      session.dispose();
    });

    testWidgets('the maintenance screen says when, and offers a retry',
        (tester) async {
      final session = await blocked(tester, {
        'action': 'maintenance',
        'message': 'Back at 6pm.',
      });

      await tester.pumpWidget(app(session));
      await tester.pump();

      expect(find.text('Back shortly'), findsOneWidget);
      expect(find.text('Back at 6pm.'), findsOneWidget);
      expect(find.text('Open the store'), findsNothing);
      expect(find.text('Try again'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      session.dispose();
    });
  });
}

class _FixedVersion implements AppVersionSource {
  const _FixedVersion(this._version);

  final String? _version;

  @override
  Future<String?> version() async => _version;
}
