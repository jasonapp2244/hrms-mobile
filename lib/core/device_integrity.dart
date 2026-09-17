import 'package:safe_device/safe_device.dart';

/// What the handset can say about itself, beside a punch (B2.7).
///
/// **Recorded, never enforced.** Nothing here stops anybody clocking in — the
/// server writes the flags against the punch and the attendance register offers
/// a filter for them. That is deliberate and it is the same rule the rest of
/// this system applies to location: office, remote and hybrid staff clock in
/// from wherever they are, and a false positive that stops somebody being paid
/// is a worse failure than a true positive nobody acted on for a day.
///
/// **And none of it is proof.** A root check runs on the device it is judging,
/// so the root it detects can also patch it out; a custom ROM trips it
/// honestly, with no fraud anywhere near. What these are worth is the pattern:
/// one flagged punch is usually nothing, and the same employee flagged every
/// morning for a fortnight is a conversation.
abstract class DeviceIntegrity {
  /// True when the phone appears rooted or jailbroken, false when it does not,
  /// and **null when this build cannot tell** — which is the answer the server
  /// stores, because "unknown" and "clean" are different claims.
  Future<bool?> isRooted();

  /// True when the app is running on an emulator rather than real hardware.
  Future<bool?> isEmulator();
}

/// Says nothing about anything.
///
/// The default in tests and on desktop, where this app is only ever opened by
/// a developer and every answer would be both true and meaningless.
class UnknownDeviceIntegrity implements DeviceIntegrity {
  const UnknownDeviceIntegrity();

  @override
  Future<bool?> isRooted() async => null;

  @override
  Future<bool?> isEmulator() async => null;
}

/// The real thing, on top of the `safe_device` plugin.
///
/// Both answers are **memoised for the life of the process**, because neither
/// can change while the app is running and both are platform-channel round
/// trips on the path of a button somebody is waiting on.
///
/// Every failure resolves to null rather than throwing. A punch must never be
/// lost to a diagnostic about the punch.
class SafeDeviceIntegrity implements DeviceIntegrity {
  const SafeDeviceIntegrity();

  static bool? _rooted;
  static bool? _emulator;
  static bool _asked = false;

  @override
  Future<bool?> isRooted() async {
    await _ask();

    return _rooted;
  }

  @override
  Future<bool?> isEmulator() async {
    await _ask();

    return _emulator;
  }

  Future<void> _ask() async {
    if (_asked) return;
    // Set before the awaits, not after: two punches in quick succession must
    // not both start the platform round trip.
    _asked = true;

    try {
      _rooted = await SafeDevice.isJailBroken;
    } catch (_) {
      // The plugin throws a plain PlatformException where the channel is
      // missing — desktop, and any test that reaches here by accident.
      _rooted = null;
    }

    try {
      _emulator = !(await SafeDevice.isRealDevice);
    } catch (_) {
      _emulator = null;
    }
  }

  /// Forgets the memo. For tests only — nothing in the app has a reason to ask
  /// twice.
  static void reset() {
    _asked = false;
    _rooted = null;
    _emulator = null;
  }
}
