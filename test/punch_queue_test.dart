import 'dart:convert';
import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/punch_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The offline punch queue (B2.4).
///
/// What matters here is not that it sends — it is what it does when sending
/// fails, and what it drops afterwards. A queue that loses a punch costs
/// somebody their hours; one that keeps a settled punch delivers it twice into
/// an append-only table where it can only ever be voided.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('punch_queue_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  PunchQueue queue() => PunchQueue(directory: dir);

  QueuedPunch punch(String at, {String type = 'in'}) =>
      QueuedPunch(occurredAt: at, intendedType: type);

  /// An API that answers /attendance/sync with whatever is handed to it.
  ({ApiClient client, List<Map<String, dynamic>> sent}) api(
    Object Function(List<Map<String, dynamic>> punches) respond, {
    int status = 200,
  }) {
    final sent = <Map<String, dynamic>>[];

    final client = ApiClient(
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final punches = (body['punches'] as List).cast<Map<String, dynamic>>();
        sent.addAll(punches);

        return http.Response(
          jsonEncode(respond(punches)),
          status,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    return (client: client, sent: sent);
  }

  Map<String, dynamic> allAccepted(List<Map<String, dynamic>> punches) => {
        'ok': true,
        'results': [
          for (final p in punches)
            {'occurred_at': p['occurred_at'], 'result': 'accepted'},
        ],
        'accepted': punches.length,
        'duplicate': 0,
        'refused': 0,
      };

  group('holding a punch', () {
    test('a queued punch survives a restart', () async {
      await queue().add(punch('2026-08-03T09:00:00.000Z'));

      // A separate instance, as if the app had been force-quit and reopened.
      final reopened = queue();
      await reopened.load();

      expect(reopened.pending, hasLength(1));
      expect(reopened.pending.single.occurredAt, '2026-08-03T09:00:00.000Z');
      expect(reopened.count.value, 1);
    });

    test('the count is published so the banner does not have to poll', () async {
      final q = queue();
      await q.load();

      expect(q.count.value, 0);
      await q.add(punch('2026-08-03T09:00:00.000Z'));
      expect(q.count.value, 1);
    });

    test('a corrupt queue file does not stop the app starting', () async {
      await File('${dir.path}${Platform.pathSeparator}pending_punches.json')
          .writeAsString('this is not json');

      final q = queue();
      await q.load();

      // Losing an unsent punch is bad; refusing to launch is worse, and a
      // correction can always be asked for.
      expect(q.pending, isEmpty);
    });

    test('signing out takes the queue with the token', () async {
      final q = queue();
      await q.add(punch('2026-08-03T09:00:00.000Z'));

      await q.clear();

      // The next person to sign in on this handset must not inherit somebody
      // else's punches, nor have them posted against their own record.
      expect(q.pending, isEmpty);

      final reopened = queue();
      await reopened.load();
      expect(reopened.pending, isEmpty);
    });
  });

  group('draining', () {
    test('the intended type is kept locally and never sent', () async {
      final q = queue();
      await q.add(punch('2026-08-03T09:00:00.000Z', type: 'out'));

      final fake = api(allAccepted);
      await q.flush(fake.client);

      // The server decides the direction from the punches before that moment.
      // Sending the app's guess would let a stale queue post the wrong one.
      expect(fake.sent.single.containsKey('intended_type'), isFalse);
      expect(fake.sent.single['occurred_at'], '2026-08-03T09:00:00.000Z');
    });

    test('accepted punches leave the queue', () async {
      final q = queue();
      await q.add(punch('2026-08-03T09:00:00.000Z'));
      await q.add(punch('2026-08-03T17:00:00.000Z'));

      final outcome = await q.flush(api(allAccepted).client);

      expect(outcome.accepted, 2);
      expect(outcome.stillQueued, 0);
      expect(q.pending, isEmpty);
    });

    test('a punch the server already has is dropped, not resent for ever', () async {
      final q = queue();
      await q.add(punch('2026-08-03T09:00:00.000Z'));

      final outcome = await q.flush(api((punches) => {
            'ok': true,
            'results': [
              {'occurred_at': punches.single['occurred_at'], 'result': 'duplicate'},
            ],
            'accepted': 0, 'duplicate': 1, 'refused': 0,
          }).client);

      expect(outcome.duplicate, 1);
      expect(q.pending, isEmpty);
    });

    test('a refused punch is dropped and its reason surfaced', () async {
      final q = queue();
      await q.add(punch('2026-08-01T09:00:00.000Z'));

      final outcome = await q.flush(api((punches) => {
            'ok': true,
            'results': [
              {
                'occurred_at': punches.single['occurred_at'],
                'result': 'refused',
                'message': 'That punch is more than 48 hours old.',
              },
            ],
            'accepted': 0, 'duplicate': 0, 'refused': 1,
          }).client);

      // Refused for a reason that will not change on a retry. Keeping it would
      // retry for ever and the banner would never clear — but the person has
      // to be told, because a punch they made is not on their record.
      expect(q.pending, isEmpty);
      expect(outcome.refusals.single, contains('48 hours'));
    });

    test('nothing is dropped when the call never arrives', () async {
      final q = queue();
      await q.add(punch('2026-08-03T09:00:00.000Z'));

      final offline = ApiClient(
        client: MockClient((_) async => throw const SocketException('offline')),
      );

      final outcome = await q.flush(offline);

      // The whole point: a punch is not lost because the network was not there.
      expect(outcome.failed, isTrue);
      expect(outcome.stillQueued, 1);
      expect(q.pending, hasLength(1));
    });

    test('a punch added mid-flight is not dropped with the batch', () async {
      final q = queue();
      await q.add(punch('2026-08-03T09:00:00.000Z'));

      late final Future<void> added;

      final client = ApiClient(
        client: MockClient((request) async {
          // Tapped again while the sync was in the air. Only the entries
          // actually sent may be dropped by its verdict.
          added = q.add(punch('2026-08-03T12:00:00.000Z'));
          await added;

          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final punches = (body['punches'] as List).cast<Map<String, dynamic>>();

          return http.Response(
            jsonEncode(allAccepted(punches)),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      await q.flush(client);

      expect(q.pending, hasLength(1));
      expect(q.pending.single.occurredAt, '2026-08-03T12:00:00.000Z');
    });

    test('an empty queue does not call the server at all', () async {
      final q = queue();
      await q.load();

      final fake = api(allAccepted);
      final outcome = await q.flush(fake.client);

      expect(fake.sent, isEmpty);
      expect(outcome.changedAnything, isFalse);
    });

    test('a partial batch keeps only what the server did not settle', () async {
      final q = queue();
      await q.add(punch('2026-08-03T09:00:00.000Z'));
      await q.add(punch('2026-08-03T17:00:00.000Z'));

      // The server answered for one and said nothing about the other — a
      // truncated response. The unanswered punch stays.
      final outcome = await q.flush(api((punches) => {
            'ok': true,
            'results': [
              {'occurred_at': punches.first['occurred_at'], 'result': 'accepted'},
            ],
            'accepted': 1, 'duplicate': 0, 'refused': 0,
          }).client);

      expect(outcome.stillQueued, 1);
      expect(q.pending.single.occurredAt, '2026-08-03T17:00:00.000Z');
    });
  });

  group('ApiException', () {
    test('tells a failed delivery from a refusal', () {
      // The distinction the whole feature turns on: a punch that was refused is
      // settled, while one that never arrived must not be lost.
      expect(
        ApiException(error: 'network_unreachable', message: '').isNetworkFailure,
        isTrue,
      );
      expect(
        ApiException(error: 'network_error', message: '').isNetworkFailure,
        isTrue,
      );
      expect(
        ApiException(error: 'no_office', message: '').isNetworkFailure,
        isFalse,
      );
      expect(
        ApiException(error: 'outside_geofence', message: '').isNetworkFailure,
        isFalse,
      );
    });
  });
}
