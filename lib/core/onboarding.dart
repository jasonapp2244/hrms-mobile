import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Whether this handset has been shown what the app is for (B1.1).
///
/// **Not part of the session, and deliberately not cleared with the token.**
/// Signing out is something a person does at the end of a shift on a shared
/// phone; being walked through the app again each time would be an insult
/// rather than an introduction. The flag describes the handset, not the
/// account.
///
/// It lives beside the token in the keystore rather than in a file for one
/// reason only — the app already has exactly one place for a small per-handset
/// preference, and a second mechanism for a single boolean would be more parts
/// than the problem has. A consequence worth knowing: `FlutterSecureStorage.xml`
/// is excluded from Android backup (so the token is never restored onto another
/// phone), so a restored device is shown the introduction again. That is the
/// right answer anyway — it is a new handset to whoever is holding it.
class Onboarding {
  Onboarding({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const preferenceKey = 'hrms_onboarding_seen';

  /// True until somebody has been through it, or read it and skipped.
  ///
  /// An unreadable keystore answers **false**: showing an introduction twice is
  /// a small annoyance, and blocking somebody at a carousel they cannot get
  /// past because a read failed is not.
  Future<bool> isPending() async {
    try {
      return await _storage.read(key: preferenceKey) != '1';
    } catch (e) {
      debugPrint('Reading the onboarding flag failed: $e');
      return false;
    }
  }

  /// Marks it done. Called when the last card is passed **and** when it is
  /// skipped: skipping is a decision about this app, not a request to be asked
  /// again next launch.
  Future<void> markSeen() async {
    try {
      await _storage.write(key: preferenceKey, value: '1');
    } catch (e) {
      // Worst case it appears once more. Nothing here is worth an exception in
      // front of somebody who has not signed in yet.
      debugPrint('Saving the onboarding flag failed: $e');
    }
  }
}
