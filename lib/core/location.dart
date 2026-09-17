import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'device_integrity.dart';

/// A coordinate pair to attach to a punch.
///
/// `latitude` and `longitude` are the two optional fields `POST
/// /attendance/check` accepts (API-Reference_v1.md §3). Both or neither — a
/// half-populated pair is not a location, so they travel together.
@immutable
class Coordinates {
  const Coordinates({
    required this.latitude,
    required this.longitude,
    this.isMocked = false,
  });

  final double latitude;
  final double longitude;

  /// Whether the **operating system** says this fix came from a mock provider
  /// (B2.7).
  ///
  /// Android has reported it since API 18 and iOS 15 reports the equivalent for
  /// a simulated position, so it is not a guess the app is making — it is the
  /// platform stating where the coordinates came from, which is a stronger
  /// signal than anything this app could work out for itself.
  ///
  /// A property of the fix rather than of the device, and recorded per punch
  /// for that reason: somebody can turn a spoofer on between one punch and the
  /// next.
  final bool isMocked;

  /// The server validates −90…90 and −180…180 and rejects the whole punch on a
  /// validation failure. A fix that far out is a broken sensor rather than a
  /// person, and losing the punch would be the worse outcome, so it is dropped
  /// here instead of being sent.
  bool get isPlausible =>
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180 &&
      !latitude.isNaN &&
      !longitude.isNaN;

  @override
  bool operator ==(Object other) =>
      other is Coordinates &&
      other.latitude == latitude &&
      other.longitude == longitude &&
      other.isMocked == isMocked;

  @override
  int get hashCode => Object.hash(latitude, longitude, isMocked);

  @override
  String toString() =>
      'Coordinates(${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)})';
}

/// Where a punch's coordinates come from.
///
/// An interface rather than a direct `Geolocator` call so the punch screen can
/// be driven in a test: the plugin needs a platform channel, which a headless
/// `flutter test` does not have.
abstract class LocationSource {
  /// The handset's position, or null if it cannot be had *for any reason*.
  ///
  /// Implementations must not throw. See [PunchLocator] for why.
  Future<Coordinates?> currentPosition();
}

/// Always declines to supply a location.
///
/// The default in tests, and on desktop where the punch screen is only ever
/// opened by a developer.
class NoLocationSource implements LocationSource {
  const NoLocationSource();

  @override
  Future<Coordinates?> currentPosition() async => null;
}

/// The real thing, on top of the `geolocator` plugin.
///
/// **Location is a record, not a gate.** The API reference is explicit that
/// office, remote and hybrid staff all clock in from wherever they are and that
/// a punch without coordinates is valid. So every failure here — services off,
/// permission refused, no fix before the deadline, a plugin that throws —
/// resolves to null and the punch goes anyway. Somebody standing in a lift with
/// no signal still gets to clock in.
class GeolocatorLocationSource implements LocationSource {
  const GeolocatorLocationSource({
    this.fixTimeout = const Duration(seconds: 8),
    this.accuracy = LocationAccuracy.high,
  });

  /// How long to wait for a fix before giving up and punching without one.
  ///
  /// A cold GPS start outdoors is 5–10s and indoors it may never resolve, which
  /// is the case this exists for: the button must not sit under a spinner
  /// waiting on a satellite that is not coming.
  final Duration fixTimeout;

  /// [LocationAccuracy.high] (~10m) rather than `best`: this records which
  /// office someone punched from, and `best` keeps the receiver awake chasing
  /// precision that changes no answer.
  final LocationAccuracy accuracy;

  @override
  Future<Coordinates?> currentPosition() async {
    try {
      // Asking for a fix with the location services switched off throws on
      // Android and hangs on iOS. Check first, and do not prompt for a
      // permission that would be useless anyway.
      if (!await Geolocator.isLocationServiceEnabled()) return null;

      if (!await _ensurePermission()) return null;

      final position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: accuracy,
          timeLimit: fixTimeout,
        ),
      ).timeout(fixTimeout);

      final coordinates = Coordinates(
        latitude: position.latitude,
        longitude: position.longitude,
        // Straight off the platform's own report of this fix (B2.7). Never
        // computed here, and never a reason to drop the punch.
        isMocked: position.isMocked,
      );

      return coordinates.isPlausible ? coordinates : null;
    } catch (_) {
      // Deliberately broad. The plugin throws a family of unrelated types —
      // permission, service, timeout, and a plain PlatformException when the
      // channel is missing — and the response to every one of them is the same:
      // punch without coordinates. Letting any of them escape would turn a
      // recorded detail into a failed clock-in.
      return null;
    }
  }

  /// True if the app may read the location now.
  ///
  /// Prompts at most once per call, and never after a permanent refusal:
  /// re-asking there shows no dialog on Android and nothing at all on iOS, so
  /// it would only add a silent round trip to every punch.
  Future<bool> _ensurePermission() async {
    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      // Not timed out. This is the system dialog, and the person is deciding —
      // the punch button is already showing a spinner while they do.
      permission = await Geolocator.requestPermission();
    }

    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }
}

/// Resolves a punch's coordinates, and guarantees an answer.
///
/// Wraps a [LocationSource] with the promise the punch screen depends on: this
/// returns, it returns quickly, and it never throws. A source that hangs past
/// [deadline] is abandoned rather than waited on.
///
/// That promise holds for anything that hangs *in Dart*. It does not hold if
/// the platform's own main thread is blocked, because then no Dart runs at all
/// — the timer below never fires, the button stays under its spinner and the
/// whole app is wedged. Seen for real: `geolocator`'s Android clients register
/// an NMEA listener for every single-shot fix and tear it down with a
/// synchronous `removeNmeaListener` on the calling thread, and that binder call
/// blocks for as long as the system's location service holds its GNSS lock. An
/// emulator's fake GNSS HAL deadlocks there reliably. Both geolocator Android
/// clients do this and no plugin setting opts out, so there is nothing to fix
/// here — this note exists so the next person reads the timeouts below as what
/// they are, and does not lose an afternoon proving they fire.
class PunchLocator {
  const PunchLocator({
    this.source = const NoLocationSource(),
    this.integrity = const UnknownDeviceIntegrity(),
    this.deadline = const Duration(seconds: 12),
  });

  final LocationSource source;

  /// What the handset says about itself (B2.7). Defaults to saying nothing,
  /// which is what a test and a desktop build should say.
  final DeviceIntegrity integrity;

  /// The outer stop. Longer than the source's own fix timeout on purpose — it
  /// covers the permission dialog and a plugin that answers late, neither of
  /// which the source can time out for itself. It does not cover a blocked
  /// platform main thread; see the class doc for why nothing here could.
  final Duration deadline;

  Future<Coordinates?> resolve() async {
    try {
      return await source.currentPosition().timeout(deadline);
    } catch (_) {
      return null;
    }
  }

  /// The coordinates as `POST /attendance/check` wants them, ready to spread
  /// into the request body. Empty when there is no location — the endpoint
  /// treats both fields as optional, and sending nulls would fail its numeric
  /// validation rather than being read as "unknown".
  ///
  /// The device flags (B2.7) are separate from the fix and are sent even when
  /// there is no fix at all: "this phone is rooted" is true whether or not the
  /// satellites answered. A key is **omitted rather than sent null** when the
  /// answer is unknown, because the server stores null to mean *the client said
  /// nothing* and an explicit null would be indistinguishable from an absent
  /// key anyway — omitting it is the honest encoding of the same thing.
  Future<Map<String, dynamic>> punchBody() async {
    final fix = await resolve();

    // Asked in parallel with nothing else pending, and memoised after the first
    // punch — see [SafeDeviceIntegrity].
    final rooted = await _flag(integrity.isRooted);
    final emulator = await _flag(integrity.isEmulator);

    return {
      if (fix != null) ...{
        'latitude': fix.latitude,
        'longitude': fix.longitude,
        'location_mocked': fix.isMocked,
      },
      if (rooted != null) 'device_rooted': rooted,
      if (emulator != null) 'device_emulator': emulator,
    };
  }

  /// One integrity answer, or null if it cannot be had quickly or at all.
  ///
  /// Short deadline and a swallowed error, for the same reason the location has
  /// one: this is a note attached to a punch, and a note must never be the
  /// reason the punch does not happen.
  Future<bool?> _flag(Future<bool?> Function() ask) async {
    try {
      return await ask().timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    }
  }
}
