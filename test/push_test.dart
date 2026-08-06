import 'dart:async';
import 'dart:convert';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/push.dart';
import 'package:attendance/core/session.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A handset, without a handset.
///
/// Stands in for `FirebasePushProvider` so the registration logic can be driven
/// in a headless test: the real one needs a platform channel and a Firebase
/// project, and `flutter test` has neither.
class FakePushProvider implements PushProvider {
  FakePushProvider({this.permitted = true, this.token = 'token-a'});

  bool permitted;
  String? token;
  PushMessage? launch;
  int discardCount = 0;

  final StreamController<String> refreshes = StreamController.broadcast();
  final StreamController<PushMessage> taps = StreamController.broadcast();
  final StreamController<PushMessage> incoming = StreamController.broadcast();

  @override
  Future<bool> requestPermission() async => permitted;

  @override
  Future<String?> currentToken() async => token;

  @override
  Stream<String> get tokenRefreshes => refreshes.stream;

  @override
  Stream<PushMessage> get foregroundMessages => incoming.stream;

  @override
  Stream<PushMessage> get notificationTaps => taps.stream;

  @override
  Future<PushMessage?> launchMessage() async => launch;

  @override
  Future<void> discardToken() async {
    discardCount++;
    token = null;
  }

  Future<void> close() async {
    await refreshes.close();
    await taps.close();
    await incoming.close();
  }
}

/// Records what the app sent, and answers the way the API documents.
class RecordingApi {
  final List<({String path, Map<String, dynamic> body})> calls = [];

  late final ApiClient client = ApiClient(
    client: MockClient((request) async {
      calls.add((
        path: request.url.path,
        body: request.body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(request.body) as Map<String, dynamic>,
      ));

      return http.Response(
        jsonEncode({'ok': true, 'device': {'id': 1}}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  );

  Iterable<Map<String, dynamic>> bodiesFor(String suffix) =>
      calls.where((c) => c.path.endsWith(suffix)).map((c) => c.body);
}

void main() {
  group('PushRoute', () {
    test('maps the three values the server sends', () {
      // These strings are the contract with the server (Push-Notifications_
      // Setup.md). Changing one here without changing the notification classes
      // silently stops taps landing anywhere.
      expect(PushRoute.parse('clock'), PushRoute.clock);
      expect(PushRoute.parse('leave'), PushRoute.leave);
      expect(PushRoute.parse('approvals'), PushRoute.approvals);
    });

    test('resolves each route to a tab that exists in the shell', () {
      expect(PushRoute.clock.tabLabel, 'Clock');
      expect(PushRoute.leave.tabLabel, 'Leave');
      expect(PushRoute.approvals.tabLabel, 'Team');
    });

    test('ignores anything it does not recognise', () {
      // A newer server sending a route this build has never heard of must open
      // the app normally rather than fail.
      expect(PushRoute.parse('payslip'), isNull);
      expect(PushRoute.parse(null), isNull);
      expect(PushRoute.parse(7), isNull);
    });
  });

  group('PushMessage', () {
    test('reads the notification and data halves of one message', () {
      final message = PushMessage.fromRemote(const RemoteMessage(
        notification: RemoteNotification(
          title: 'Leave approved',
          body: 'Your leave from 12 Aug was approved.',
        ),
        data: {'route': 'leave', 'leave_request_id': '18'},
      ));

      expect(message.title, 'Leave approved');
      expect(message.route, PushRoute.leave);
      expect(message.hasText, isTrue);
    });

    test('survives a data-only message', () {
      final message =
          PushMessage.fromRemote(const RemoteMessage(data: {'route': 'clock'}));

      expect(message.route, PushRoute.clock);
      expect(message.hasText, isFalse);
    });
  });

  group('PushService', () {
    late RecordingApi api;
    late FakePushProvider provider;
    late PushService push;

    setUp(() {
      api = RecordingApi();
      provider = FakePushProvider();
      push = PushService(api: api.client, provider: provider);
    });

    tearDown(() async {
      push.dispose();
      await provider.close();
    });

    test('registers the handset once permission is granted', () async {
      await push.start(deviceName: 'Pixel 7');

      final body = api.bodiesFor('/devices').single;
      expect(body['token'], 'token-a');
      expect(body['device_name'], 'Pixel 7');
      // One of PushDevice::PLATFORMS — anything else is a validation failure.
      expect(['android', 'ios', 'web'], contains(body['platform']));
      expect(push.token, 'token-a');
    });

    test('registers nothing when notifications were refused', () async {
      provider.permitted = false;

      await push.start(deviceName: 'Pixel 7');

      // A token the OS will never deliver to is a row that fails forever.
      expect(api.bodiesFor('/devices'), isEmpty);
      expect(push.token, isNull);
    });

    test('re-registers when the OS reissues the token', () async {
      await push.start(deviceName: 'Pixel 7');
      provider.refreshes.add('token-b');
      await pumpEventQueue();

      // The old token is dead the moment this fires; a server still holding it
      // is a handset that silently stops receiving.
      expect(
        api.bodiesFor('/devices').map((b) => b['token']),
        ['token-a', 'token-b'],
      );
      expect(push.token, 'token-b');
    });

    test('does not double its listeners when start runs again', () async {
      await push.start(deviceName: 'Pixel 7');
      await push.start(deviceName: 'Pixel 7');

      provider.refreshes.add('token-b');
      await pumpEventQueue();

      // Two subscriptions would mean two registrations per refresh, and two
      // banners per foreground message.
      expect(api.bodiesFor('/devices').where((b) => b['token'] == 'token-b'),
          hasLength(1));
    });

    test('holds the route from a tap for whoever is ready to handle it',
        () async {
      await push.start(deviceName: 'Pixel 7');

      provider.taps.add(const PushMessage(route: PushRoute.approvals));
      await pumpEventQueue();

      expect(push.pendingRoute.value, PushRoute.approvals);
    });

    test('picks up the notification that launched the app from cold', () async {
      provider.launch = const PushMessage(
        title: 'Still clocked in',
        route: PushRoute.clock,
      );

      await push.start(deviceName: 'Pixel 7');

      // This tap is resolved before any screen exists, so it has to wait as a
      // value rather than pass as an event.
      expect(push.pendingRoute.value, PushRoute.clock);
    });

    test('passes foreground messages on for the in-app banner', () async {
      await push.start(deviceName: 'Pixel 7');

      final seen = <PushMessage>[];
      push.foregroundMessages.listen(seen.add);

      provider.incoming.add(const PushMessage(body: 'Your shift ended.'));
      provider.incoming.add(const PushMessage()); // no text — nothing to show
      await pumpEventQueue();

      expect(seen, hasLength(1));
      expect(seen.single.body, 'Your shift ended.');
    });

    test('stop reports the token and throws the local one away', () async {
      await push.start(deviceName: 'Pixel 7');

      final token = await push.stop();

      // The caller needs it for POST /auth/logout; the handset must not keep
      // it, or the next person to sign in inherits the address.
      expect(token, 'token-a');
      expect(provider.discardCount, 1);
      expect(push.token, isNull);
    });

    test('a refresh after stop registers nothing', () async {
      await push.start(deviceName: 'Pixel 7');
      await push.stop();

      provider.refreshes.add('token-b');
      await pumpEventQueue();

      // Registering after sign-out would attach the handset to a session that
      // no longer exists — and on a shared phone, to the wrong person.
      expect(api.bodiesFor('/devices').map((b) => b['token']), ['token-a']);
    });
  });

  group('Session', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('unregisters the handset as part of signing out', () async {
      final api = RecordingApi();
      final provider = FakePushProvider();
      final session = Session(api: api.client, pushProvider: provider);

      await session.push.start(deviceName: 'Pixel 7');
      await session.logout();

      // No screen passes a push token to logout — the session knows it. That is
      // what stops a shared handset receiving the previous person's leave
      // decisions.
      expect(api.bodiesFor('/auth/logout').single['push_token'], 'token-a');
      expect(provider.discardCount, 1);

      session.dispose();
      await provider.close();
    });

    test('signing out everywhere drops this handset too', () async {
      final api = RecordingApi();
      final provider = FakePushProvider();
      final session = Session(api: api.client, pushProvider: provider);

      await session.push.start(deviceName: 'Pixel 7');
      await session.logoutEverywhere();

      // The server drops every registered device on this endpoint, so there is
      // nothing to name — but this handset still has to stop listening.
      expect(provider.discardCount, 1);
      expect(session.push.token, isNull);

      session.dispose();
      await provider.close();
    });
  });
}
