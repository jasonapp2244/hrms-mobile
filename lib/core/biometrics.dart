import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import '../l10n/generated/app_localizations.dart';

/// How a biometric check ended.
///
/// Four outcomes rather than a bool because the lock screen has to answer them
/// differently: a refusal is retried, an unavailable sensor is the one case
/// that must offer a way *past* the lock, and a lockout has to say that waiting
/// is the only thing that helps.
enum BiometricOutcome {
  /// The check passed.
  granted,

  /// The person cancelled, or the sensor did not recognise them. Retryable.
  refused,

  /// There is nothing on this handset to check against — no hardware, nothing
  /// enrolled, or the plugin is not there at all (a desktop build, a test).
  unavailable,

  /// Too many failed attempts. Retrying now will fail too.
  lockedOut,
}

/// The device's own fingerprint / face check, behind an interface.
///
/// Injectable for the same reason [PunchLocator] is: a headless test has no
/// platform channel to answer the plugin, and a screen that asks whether
/// biometrics exist must get an answer rather than an exception.
abstract class BiometricAuthenticator {
  const BiometricAuthenticator();

  /// True only when this handset has a biometric **enrolled**.
  ///
  /// Deliberately stricter than "the device supports authentication": with a
  /// PIN and no fingerprint, [authenticate] would still succeed by prompting
  /// for that PIN — so a switch labelled "Unlock with fingerprint or face"
  /// would be offered on a phone that has neither, and would ask for something
  /// else entirely.
  Future<bool> isAvailable();

  Future<BiometricOutcome> authenticate(String reason);
}

/// The real thing.
///
/// **Nothing here throws.** Every entry point resolves to [false] or
/// [BiometricOutcome.unavailable] instead, because both callers sit in front of
/// the whole app: a screen that cannot ask the sensor a question must fall back
/// to no lock at all rather than to a crash on launch.
class LocalAuthBiometrics implements BiometricAuthenticator {
  const LocalAuthBiometrics([this._auth = _defaultLocalAuth]);

  final LocalAuthFactory _auth;

  @override
  Future<bool> isAvailable() async {
    try {
      final auth = _auth();
      if (!await auth.isDeviceSupported()) return false;
      if (!await auth.canCheckBiometrics) return false;
      return (await auth.getAvailableBiometrics()).isNotEmpty;
    } catch (e) {
      debugPrint('Biometric availability check failed: $e');
      return false;
    }
  }

  @override
  Future<BiometricOutcome> authenticate(String reason) async {
    try {
      final ok = await _auth().authenticate(
        localizedReason: reason,
        // The device passcode is allowed as a fallback, on purpose. A thumb
        // that will not read through a wet glove must not leave somebody
        // standing at the door unable to clock in — and the passcode is
        // already what protects the keystore this token lives in, so allowing
        // it takes nothing away.
        biometricOnly: false,
        // Skips the extra "confirm" tap Android adds after a face match. This
        // gate stands in front of a roster and a clock-in button, not a
        // payment.
        sensitiveTransaction: false,
        // The OS backgrounds the app to show its own sheet. Without this the
        // check fails the moment it appears.
        persistAcrossBackgrounding: true,
      );
      return ok ? BiometricOutcome.granted : BiometricOutcome.refused;
    } on LocalAuthException catch (e) {
      return switch (e.code) {
        LocalAuthExceptionCode.userCanceled ||
        LocalAuthExceptionCode.timeout ||
        LocalAuthExceptionCode.systemCanceled ||
        LocalAuthExceptionCode.authInProgress ||
        LocalAuthExceptionCode.userRequestedFallback =>
          BiometricOutcome.refused,
        LocalAuthExceptionCode.temporaryLockout ||
        LocalAuthExceptionCode.biometricLockout =>
          BiometricOutcome.lockedOut,
        // Everything else — no hardware, nothing enrolled, no credentials set,
        // a device error — is the same answer to the only question the lock
        // screen is asking: this handset cannot be made to say yes, so it must
        // not be the only way in.
        _ => BiometricOutcome.unavailable,
      };
    } catch (e) {
      debugPrint('Biometric check failed: $e');
      return BiometricOutcome.unavailable;
    }
  }
}

/// Builds the plugin object. Exists so a test can hand [LocalAuthBiometrics] a
/// stand-in without a platform channel.
typedef LocalAuthFactory = LocalAuthentication Function();

LocalAuthentication _defaultLocalAuth() => LocalAuthentication();

/// An authenticator that is never available. The default in tests, and on any
/// platform the plugin does not cover.
class UnavailableBiometrics implements BiometricAuthenticator {
  const UnavailableBiometrics();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<BiometricOutcome> authenticate(String reason) async =>
      BiometricOutcome.unavailable;
}

/// Whether the app is locked behind the device's biometric check (B1.3).
///
/// A separate notifier from [Session] because it is a different question —
/// *who is signed in* versus *may this handset be looked at right now* — but
/// [Session] re-broadcasts its changes, so every screen that already listens
/// for a sign-out also learns about a lock.
///
/// **The preference is on the handset, not the account.** It answers "is this
/// phone shared", which the server has no way of knowing and no business
/// storing. It is cleared with the token for the same reason the punch queue
/// is: the next person to sign in on a borrowed phone inherits neither.
class AppLock extends ChangeNotifier {
  AppLock({
    BiometricAuthenticator authenticator = const LocalAuthBiometrics(),
    FlutterSecureStorage? storage,
    DateTime Function() clock = DateTime.now,
  })  : _authenticator = authenticator,
        _storage = storage ?? const FlutterSecureStorage(),
        _now = clock;

  final BiometricAuthenticator _authenticator;
  final FlutterSecureStorage _storage;

  /// Only so a test can send the app away for two minutes without waiting two
  /// minutes. Nothing else reads it.
  final DateTime Function() _now;

  static const preferenceKey = 'hrms_biometric_lock';

  /// How long the app may be away before it locks again.
  ///
  /// Not zero, and not short. The OS backgrounds the app for its own dialogs —
  /// the location permission prompt at the first punch, the file viewer opening
  /// a document, the biometric sheet itself — and locking behind each of those
  /// would put a second prompt over the first. A minute is long enough to cover
  /// them and short enough that a phone left on a table locks before it is
  /// picked up by somebody else.
  static const backgroundGrace = Duration(seconds: 60);

  bool _enabled = false;
  bool _armed = false;
  bool _locked = false;
  bool _prompting = false;
  DateTime? _leftAt;
  BiometricOutcome? _failure;

  /// True when this handset has been asked to lock. Meaningless on its own —
  /// nothing locks until somebody is signed in.
  bool get isEnabled => _enabled;

  /// True while the app must not be looked at until the check passes.
  bool get isLocked => _locked;

  /// How the last check failed, or null when there is nothing to say.
  ///
  /// The **outcome**, not a sentence. The words for it live in the ARB files
  /// and are looked up by whichever screen is drawing them (B6.2) — this class
  /// runs with no `BuildContext`, and a sentence chosen here would be English
  /// on a Spanish handset for ever after.
  BiometricOutcome? get failure => _failure;

  Future<bool> isAvailable() => _authenticator.isAvailable();

  /// Reads the stored preference at launch, and engages the lock when there is
  /// a session behind it.
  ///
  /// Called from [Session.restore] rather than from the widget tree, so the
  /// lock is already up by the time the splash comes down — otherwise the home
  /// screen is drawn for a frame first, which on a shared phone is the whole
  /// of what the lock was meant to prevent.
  Future<void> load({required bool signedIn}) async {
    _enabled = await _read();
    _armed = signedIn;
    _locked = _enabled && signedIn;
    _failure = null;
    _leftAt = null;
    notifyListeners();
  }

  /// Turns the lock on, but only after a check that actually passes.
  ///
  /// The check comes first on purpose: a switch that saves the preference and
  /// then discovers the sensor refuses everybody would lock the person who
  /// flipped it out of their own app, and the way out is a reinstall.
  ///
  /// [reason] is what the operating system prints inside its own sheet, so it
  /// is passed in from the screen that has the strings rather than held here.
  Future<BiometricOutcome> enable({required String reason}) async {
    final outcome = await _authenticator.authenticate(reason);
    if (outcome != BiometricOutcome.granted) return outcome;

    await _storage.write(key: preferenceKey, value: '1');
    _enabled = true;
    // Armed here as well as in [load]: this switch is only reachable from
    // inside a signed-in session, and somebody who signs in and turns the lock
    // on in the same run would otherwise not see it engage until the next cold
    // start — [load] runs at launch, and a fresh sign-in does not go through
    // it.
    _armed = true;
    _failure = null;
    notifyListeners();
    return outcome;
  }

  /// Turns it off. No check asked for — this is only reachable from inside the
  /// app, which is already on the far side of the lock.
  Future<void> disable() async {
    await _storage.delete(key: preferenceKey);
    _enabled = false;
    _locked = false;
    _failure = null;
    notifyListeners();
  }

  /// The lock screen's button.
  Future<BiometricOutcome> unlock({required String reason}) async {
    if (_prompting) return BiometricOutcome.refused;

    _prompting = true;
    try {
      final outcome = await _authenticator.authenticate(reason);

      if (outcome == BiometricOutcome.granted) {
        _locked = false;
        _failure = null;
        _leftAt = null;
      } else {
        _failure = outcome;
      }
      notifyListeners();
      return outcome;
    } finally {
      _prompting = false;
      // The sheet backgrounded the app to draw itself; the resume that follows
      // must not be read as somebody coming back to a phone left on a table.
      _leftAt = null;
    }
  }

  /// Forgets the preference. Called with the token on sign-out: it describes
  /// this handset for the person who set it, and the next person to sign in
  /// here has not been asked.
  Future<void> clear() async {
    await _storage.delete(key: preferenceKey);
    _enabled = false;
    _armed = false;
    _locked = false;
    _failure = null;
    _leftAt = null;
    notifyListeners();
  }

  /// Locks again when the app comes back after being away for longer than
  /// [backgroundGrace]. Wired up in `HrmsApp`.
  void handleLifecycle(AppLifecycleState state) {
    if (!_enabled || !_armed || _prompting) return;

    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _leftAt ??= _now();
      case AppLifecycleState.resumed:
        final left = _leftAt;
        _leftAt = null;
        if (left == null || _locked) return;
        if (_now().difference(left) < backgroundGrace) return;
        _locked = true;
        _failure = null;
        notifyListeners();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        // `inactive` fires for a notification shade pulled halfway down and
        // for the app switcher being opened and closed again. Neither is
        // leaving.
        break;
    }
  }

  /// What to tell somebody an outcome means. One definition, because the
  /// settings switch reports the same two failures the lock screen does and
  /// they should not drift into two wordings for one thing.
  static String messageFor(AppLocalizations t, BiometricOutcome outcome) =>
      switch (outcome) {
        BiometricOutcome.granted => '',
        BiometricOutcome.refused => t.lockNotRecognised,
        BiometricOutcome.lockedOut => t.lockLockedOut,
        BiometricOutcome.unavailable => t.lockUnavailable,
      };

  Future<bool> _read() async {
    try {
      return await _storage.read(key: preferenceKey) == '1';
    } catch (e) {
      // An unreadable keystore is not a reason to refuse entry to the app.
      debugPrint('Reading the lock preference failed: $e');
      return false;
    }
  }
}
