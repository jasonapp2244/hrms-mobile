import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// A coordinate pair to attach to a punch.
///
/// `latitude` and `longitude` are the two optional fields `POST
/// /attendance/check` accepts (API-Reference_v1.md §3). Both or neither — a
/// half-populated pair is not a location, so they travel together.
@immutable
class Coordinates {
  const Coordinates({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;

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
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);

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
class PunchLocator {
  const PunchLocator({
    this.source = const NoLocationSource(),
    this.deadline = const Duration(seconds: 12),
  });

  final LocationSource source;

  /// The outer stop. Longer than the source's own fix timeout on purpose — it
  /// covers the permission dialog and a wedged platform channel, neither of
  /// which the source can time out for itself.
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
  Future<Map<String, dynamic>> punchBody() async {
    final fix = await resolve();

    return fix == null
        ? const {}
        : {'latitude': fix.latitude, 'longitude': fix.longitude};
  }
}
