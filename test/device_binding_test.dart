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

/// This handset's own id (B1.6).
///
/// The server decides everything about binding — whether it applies, which
/// handset is trusted, what happens to a second one. The app owns exactly one
/// property, and it is the one that would silently defeat the whole feature if
/// it were wrong:
///
/// **The id survives a sign-out.**
///
/// Signing out clears the token, the punch queue, the cached profile and the
/// biometric preference, because each of those belongs to the person who signed
/// out. The device id does not — it describes the *phone*. If it were cleared
/// with the rest, a borrowed login could sign out, sign in, and be trusted as a
/// brand new handset. That is precisely the move the feature exists to refuse,
/// and nothing on screen would look wrong while it happened.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('device_binding_test');
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows can still hold the cache file open. Harness tidying.
    }
  });

  Session sessionWith(List<http.BaseRequest> sent) {
    final api = ApiClient(
      client: MockClient((request) async {
        sent.add(request);

        if (request.url.path.endsWith('/auth/login')) {
          return http.Response(
            jsonEncode({
              'ok': true,
              'token': 'tok',
              'user': {
                'id': 1,
                'name': 'Ann Lee',
                'email': 'ann@acme.test',
                'roles': ['employee'],
                'permissions': <String>[],
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        return http.Response(
          jsonEncode({'ok': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    return Session(
      api: api,
      cache: OfflineCache(directory: dir),
      queue: PunchQueue(directory: dir),
    );
  }

  String deviceIdOf(http.BaseRequest request) =>
      jsonDecode((request as http.Request).body)['device_id'] as String;

  test('the id is generated once and reused', () async {
    final session = sessionWith([]);

    final first = await session.deviceId();
    final second = await session.deviceId();

    expect(first, second);
    // 128 bits, hex. Long enough not to collide across a workforce, and not a
    // hardware identifier — see the doc on Session.deviceId.
    expect(first, hasLength(32));
    expect(first, matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  test('two installs do not share an id', () async {
    final one = await sessionWith([]).deviceId();

    // A fresh keystore is a fresh install, or a different phone.
    FlutterSecureStorage.setMockInitialValues({});
    final two = await sessionWith([]).deviceId();

    expect(one, isNot(two));
  });

  test('sign-in sends it, and the same one every time', () async {
    final sent = <http.BaseRequest>[];
    final session = sessionWith(sent);

    await session.login(email: 'ann@acme.test', password: 'password');
    await session.login(email: 'ann@acme.test', password: 'password');

    final logins = sent.where((r) => r.url.path.endsWith('/auth/login')).toList();

    expect(logins, hasLength(2));
    expect(deviceIdOf(logins.first), deviceIdOf(logins.last));
  });

  test('signing out does NOT change it', () async {
    final sent = <http.BaseRequest>[];
    final session = sessionWith(sent);

    await session.login(email: 'ann@acme.test', password: 'password');
    final before = await session.deviceId();

    await session.logout();

    final after = await session.deviceId();

    // The assertion this whole file exists for. A borrowed login must not be
    // able to launder itself into a new handset by signing out and back in.
    expect(after, before);

    await session.login(email: 'ann@acme.test', password: 'password');

    final logins = sent.where((r) => r.url.path.endsWith('/auth/login')).toList();
    expect(deviceIdOf(logins.last), before);
  });
}
