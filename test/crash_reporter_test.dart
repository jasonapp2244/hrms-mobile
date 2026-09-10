import 'dart:convert';
import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/crash_reporter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Crash reporting (B6.5).
///
/// The reporter runs inside an error handler, on a process that may be about to
/// die, and it talks to a server that may not be reachable. Every test here is
/// about one of those three: it must not throw, it must not lose a report it
/// failed to deliver, and it must not hold one the server will refuse for ever.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('crash_reporter_test');
  });

  tearDown(() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // record() writes without awaiting — an error handler cannot await — so
      // on Windows the file can still be held open when the test ends. That is
      // the harness tidying up, not the thing under test.
    }
  });

  /// What the last POST carried.
  Map<String, dynamic>? sent;
  int calls = 0;

  setUp(() {
    sent = null;
    calls = 0;
  });

  ApiClient api({Object? throws, int status = 201, Map<String, dynamic>? body}) =>
      ApiClient(
        client: MockClient((request) async {
          calls++;
          sent = jsonDecode(request.body) as Map<String, dynamic>;

          if (throws != null) throw throws;

          return http.Response(
            jsonEncode({'ok': status < 400, ...?body}),
            status,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

  CrashReporter reporter(ApiClient client) =>
      CrashReporter(api: client, directory: dir);

  File file() => File('${dir.path}${Platform.pathSeparator}pending_crashes.json');

  group('recording', () {
    test('a crash survives being force-quit', () async {
      final r = reporter(api());
      await r.load();

      r.record(StateError('boom'), StackTrace.fromString('#0 Punch.build (a.dart:1:1)'));

      // record() is synchronous for its caller — an error handler cannot await
      // — so the write is in flight when it returns.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final reopened = reporter(api());
      await reopened.load();

      expect(reopened.pending, hasLength(1));
      expect(reopened.pending.single.exception, 'StateError');
      expect(reopened.pending.single.stack, contains('Punch.build'));
    });

    test('the exception class is recorded, not its toString', () async {
      final r = reporter(api());
      await r.load();

      r.record(StateError('a message with detail in it'), StackTrace.empty);

      expect(r.pending.single.exception, 'StateError');
      // The message is kept separately and truncated; the class is what the
      // server fingerprints on, and 'Bad state: ...' would make every distinct
      // message its own bug.
      expect(r.pending.single.message, contains('a message with detail in it'));
    });

    test('an enormous stack is trimmed before it is written', () async {
      final r = reporter(api());
      await r.load();

      r.record(
        StateError('boom'),
        StackTrace.fromString('x' * (CrashRecord.stackLimit + 5000)),
      );

      expect(r.pending.single.stack!.length, CrashRecord.stackLimit);
    });

    test('only the newest few are kept', () async {
      // A crash loop would otherwise fill the file, and the sixth copy of one
      // stack says nothing the first did not.
      final r = reporter(api());
      await r.load();

      for (var i = 0; i < CrashReporter.maxPending + 4; i++) {
        r.record(StateError('boom $i'), StackTrace.empty);
      }

      expect(r.pending, hasLength(CrashReporter.maxPending));
      // The last one is where the loop ended up, which is the interesting end.
      expect(r.pending.last.message, contains('boom 8'));
    });

    test('a corrupt file is not a reason to refuse to start', () async {
      await file().writeAsString('{ this is not json');

      final r = reporter(api());
      await r.load();

      expect(r.pending, isEmpty);
    });
  });

  group('delivering', () {
    test('what is waiting is sent and then forgotten', () async {
      final r = reporter(api());
      await r.load();
      r.record(StateError('boom'), StackTrace.empty);

      await r.flush();

      expect(calls, 1);
      expect((sent!['reports'] as List), hasLength(1));
      expect(r.pending, isEmpty);

      // And gone from disk, so the next launch does not send them again.
      final reopened = reporter(api());
      await reopened.load();
      expect(reopened.pending, isEmpty);
    });

    test('nothing waiting is not a request', () async {
      final r = reporter(api());
      await r.flush();

      expect(calls, 0);
    });

    test('a report the server never received is kept', () async {
      // A handset on a site with no coverage delivers next time. A crash is
      // worth more late than not at all.
      final r = reporter(api(throws: const SocketException('no route to host')));
      await r.load();
      r.record(StateError('boom'), StackTrace.empty);

      await r.flush();

      expect(r.pending, hasLength(1));
    });

    test('a report the server refuses is dropped', () async {
      // A shape it will refuse every time. Holding it would mean retrying the
      // same rejection at every launch for ever.
      final r = reporter(api(
        status: 422,
        body: {'error': 'validation_failed', 'message': 'The given data was invalid.'},
      ));
      await r.load();
      r.record(StateError('boom'), StackTrace.empty);

      await r.flush();

      expect(r.pending, isEmpty);
    });

    test('a crash during the flush is not lost with the batch', () async {
      // The likeliest moment for one: a launch that reports is a launch that
      // crashed, and the next crash may well arrive mid-call.
      late CrashReporter r;

      final client = ApiClient(
        client: MockClient((request) async {
          calls++;
          r.record(StateError('second'), StackTrace.empty);

          return http.Response(
            jsonEncode({'ok': true, 'stored': 1}),
            201,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      r = reporter(client);
      await r.load();
      r.record(StateError('first'), StackTrace.empty);

      await r.flush();

      expect(r.pending, hasLength(1));
      expect(r.pending.single.message, contains('second'));
    });

    test('two flushes at once are one delivery', () async {
      final r = reporter(api());
      await r.load();
      r.record(StateError('boom'), StackTrace.empty);

      await Future.wait([r.flush(), r.flush()]);

      expect(calls, 1);
    });
  });

  group('what is sent', () {
    test('it names the build that crashed', () async {
      final r = reporter(api());
      await r.load();
      r.install(appVersion: '1.4.0', platform: 'android', osVersion: 'Android 14');

      r.record(StateError('boom'), StackTrace.empty);
      await r.flush();

      final report = (sent!['reports'] as List).single as Map<String, dynamic>;

      expect(report['app_version'], '1.4.0');
      expect(report['platform'], 'android');
      expect(report['os_version'], 'Android 14');
      // UTC with the Z, so the server reads the right instant from a handset
      // that has been carried across a timezone.
      expect(report['occurred_at'], endsWith('Z'));
    });

    test('a report carries no identity of its own', () async {
      // Whose handset it was is the token's job, not the body's. Nothing here
      // may name a person: this lands in a table an administrator reads.
      final r = reporter(api());
      await r.load();
      r.install(appVersion: '1.4.0', platform: 'android');

      r.record(StateError('boom'), StackTrace.empty);
      await r.flush();

      final report = (sent!['reports'] as List).single as Map<String, dynamic>;

      expect(
        report.keys,
        everyElement(isIn(const [
          'exception', 'occurred_at', 'message', 'stack',
          'app_version', 'platform', 'os_version',
        ])),
      );
    });
  });
}
