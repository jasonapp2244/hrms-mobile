import 'dart:async';

import 'package:attendance/core/device_integrity.dart';
import 'package:attendance/core/location.dart';
import 'package:attendance/core/punch_queue.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the handset says about itself when it punches (B2.7).
///
/// Attendance drives pay, so the one thing worth knowing about a set of
/// coordinates is whether they were real. Android has reported since API 18
/// whether a fix came from a mock provider and iOS 15 reports the same for a
/// simulated one — the app simply never passed it on, so a punch made with a
/// free spoofing app was indistinguishable from one made at the door.
///
/// Two rules run through every test below.
///
/// **Unknown is not clean.** A missing answer is omitted from the payload, and
/// the server stores null for it, because "this build cannot tell" and "this
/// device is fine" are different claims and only one of them is evidence.
///
/// **Nothing here may cost a punch.** An integrity check is a note attached to
/// a clock-in; a note must never be the reason the clock-in does not happen.
void main() {
  group('the fix carries its own mocked flag', () {
    test('a real fix says so, and a mocked one says so too', () async {
      const real = PunchLocator(
        source: _FixedFix(Coordinates(latitude: 1, longitude: 2)),
      );
      const mocked = PunchLocator(
        source: _FixedFix(
          Coordinates(latitude: 1, longitude: 2, isMocked: true),
        ),
      );

      expect((await real.punchBody())['location_mocked'], false);
      expect((await mocked.punchBody())['location_mocked'], true);
    });

    test('with no fix there is nothing to say about one', () async {
      const locator = PunchLocator(source: NoLocationSource());

      // Not `'location_mocked': false` — there are no coordinates for that to
      // be a statement about.
      expect(await locator.punchBody(), isNot(contains('location_mocked')));
    });

    test('two fixes are only equal if they agree about being mocked', () {
      const real = Coordinates(latitude: 1, longitude: 2);
      const mocked = Coordinates(latitude: 1, longitude: 2, isMocked: true);

      // The same point, and not the same reading. A value type that lost this
      // distinction would let a mocked fix be substituted for a real one
      // anywhere the two are compared.
      expect(real, isNot(mocked));
    });
  });

  group('the device flags', () {
    test('are sent when known, and omitted when not', () async {
      const known = PunchLocator(
        source: NoLocationSource(),
        integrity: _StubIntegrity(rooted: true, emulator: false),
      );

      expect(await known.punchBody(), {
        'device_rooted': true,
        'device_emulator': false,
      });

      // The default. A desktop build and a headless test can say nothing
      // truthful about the hardware, so they say nothing at all.
      const unknown = PunchLocator(source: NoLocationSource());
      expect(await unknown.punchBody(), isEmpty);
    });

    test('are sent even when the satellites never answered', () async {
      // "This phone is rooted" is true whether or not there was a fix, and a
      // punch with no coordinates is exactly the one worth knowing it about.
      const locator = PunchLocator(
        source: NoLocationSource(),
        integrity: _StubIntegrity(rooted: true, emulator: true),
      );

      expect((await locator.punchBody())['device_rooted'], true);
      expect((await locator.punchBody())['device_emulator'], true);
    });

    test('a source that throws costs nothing but the flag', () async {
      const locator = PunchLocator(
        source: _FixedFix(Coordinates(latitude: 1, longitude: 2)),
        integrity: _ThrowingIntegrity(),
      );

      final body = await locator.punchBody();

      // The punch still carries its coordinates. Losing a clock-in to a
      // diagnostic about the clock-in would be the worst possible trade.
      expect(body['latitude'], 1);
      expect(body, isNot(contains('device_rooted')));
    });

    test('a source that hangs costs nothing but the flag', () async {
      const locator = PunchLocator(
        source: _FixedFix(Coordinates(latitude: 1, longitude: 2)),
        integrity: _HangingIntegrity(),
      );

      final body = await locator.punchBody().timeout(const Duration(seconds: 8));

      expect(body['latitude'], 1);
      expect(body, isNot(contains('device_rooted')));
    });
  });

  group('a queued punch keeps what was true when it was tapped', () {
    test('the flags survive the round trip through the queue file', () {
      const punch = QueuedPunch(
        occurredAt: '2026-09-15T08:00:00.000Z',
        intendedType: 'in',
        latitude: 1,
        longitude: 2,
        locationMocked: true,
        deviceRooted: false,
      );

      final restored = QueuedPunch.fromJson(punch.toJson());

      expect(restored.locationMocked, true);
      expect(restored.deviceRooted, false);
      // Never set, so still unknown rather than false.
      expect(restored.deviceEmulator, isNull);
    });

    test('a punch queued by an older build stays unknown', () {
      // The queue file survives an app update, so entries written before this
      // feature existed are read back by the build that has it. They said
      // nothing, and must not be read as having said no.
      final restored = QueuedPunch.fromJson(const {
        'occurred_at': '2026-09-15T08:00:00.000Z',
        'intended_type': 'in',
        'latitude': 1,
        'longitude': 2,
      });

      expect(restored.locationMocked, isNull);
      expect(restored.deviceRooted, isNull);
      expect(restored.deviceEmulator, isNull);

      // And an unknown flag is left off the wire entirely, so the server writes
      // null rather than a denial the handset never made.
      expect(restored.toWire(), isNot(contains('location_mocked')));
    });
  });
}

class _FixedFix implements LocationSource {
  const _FixedFix(this.fix);

  final Coordinates fix;

  @override
  Future<Coordinates?> currentPosition() async => fix;
}

class _StubIntegrity implements DeviceIntegrity {
  const _StubIntegrity({this.rooted, this.emulator});

  final bool? rooted;
  final bool? emulator;

  @override
  Future<bool?> isRooted() async => rooted;

  @override
  Future<bool?> isEmulator() async => emulator;
}

class _ThrowingIntegrity implements DeviceIntegrity {
  const _ThrowingIntegrity();

  @override
  Future<bool?> isRooted() async => throw StateError('no channel');

  @override
  Future<bool?> isEmulator() async => throw StateError('no channel');
}

class _HangingIntegrity implements DeviceIntegrity {
  const _HangingIntegrity();

  @override
  Future<bool?> isRooted() => Completer<bool?>().future;

  @override
  Future<bool?> isEmulator() => Completer<bool?>().future;
}
