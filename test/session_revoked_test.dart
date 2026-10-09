import 'dart:convert';
import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/offline_cache.dart';
import 'package:attendance/core/punch_queue.dart';
import 'package:attendance/core/session.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A session the server revokes while the app is open.
///
/// A password reset, logout-all from another phone or an account switched off
/// all delete the token server-side. The app used to notice only at the next
/// cold start: until then every screen said "Authentication required" over a
/// Try again button that could only fail the same way. Found on a real handset
/// on live, after HR reset the seeded passwords.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('session_revoked_test');
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows can still hold the cache file open. Harness tidying.
    }
  });

  /// Sign-out clears files on disk, so it finishes on real time rather than on
  /// the next microtask. Waits for [done], failing after a few seconds.
  Future<void> until(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  http.Response json(Object body, int status) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );

  /// Signs in fine; every other call answers [status] with [error].
  Session sessionAnswering(int status, String error) {
    final api = ApiClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth/login')) {
          return json({
            'ok': true,
            'token': 'tok',
            'user': {
              'id': 1,
              'name': 'Ann Lee',
              'email': 'ann@acme.test',
              'roles': ['employee'],
              'permissions': <String>[],
            },
          }, 200);
        }
        return json({'ok': false, 'error': error, 'message': 'Authentication required.'}, status);
      }),
    );

    return Session(
      api: api,
      cache: OfflineCache(directory: dir),
      queue: PunchQueue(directory: dir),
    );
  }

  test('a 401 mid-session signs the person out', () async {
    final session = sessionAnswering(401, 'unauthenticated');
    await session.login(email: 'ann@acme.test', password: 'password');
    expect(session.isSignedIn, isTrue);

    var notified = false;
    session.addListener(() => notified = true);

    await expectLater(session.api.get('/attendance/today'), throwsA(isA<ApiException>()));
    // The sign-out runs off the failing request; let it finish.
    await until(() => !session.isSignedIn);

    expect(session.isSignedIn, isFalse);
    expect(session.api.token, isNull);
    expect(notified, isTrue, reason: 'the root rebuilds onto the login screen');
  });

  test('several 401s at once sign out once, without throwing', () async {
    final session = sessionAnswering(401, 'unauthenticated');
    await session.login(email: 'ann@acme.test', password: 'password');

    final calls = [
      for (final path in ['/attendance/today', '/notifications', '/schedule'])
        session.api.get(path).catchError((_) => <String, dynamic>{}),
    ];
    await Future.wait(calls);
    await until(() => !session.isSignedIn);

    expect(session.isSignedIn, isFalse);
  });

  test('any other refusal leaves the session alone', () async {
    final session = sessionAnswering(403, 'forbidden');
    await session.login(email: 'ann@acme.test', password: 'password');

    await expectLater(session.api.get('/team/attendance'), throwsA(isA<ApiException>()));
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(session.isSignedIn, isTrue);
    expect(session.api.token, 'tok');
  });
}
