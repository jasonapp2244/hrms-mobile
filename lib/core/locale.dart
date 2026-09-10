import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Which language the app is drawn in (B6.2).
///
/// **Null means follow the handset**, and that is the default and the common
/// case: a phone set to Spanish gets a Spanish app without anybody being asked.
/// The preference exists for the person whose phone is in one language and who
/// reads another — which on a shared work handset is most of the point, since
/// nobody is going to change the whole device for a shift.
///
/// **Not cleared with the token, and that is deliberate.** Everything else in
/// the keystore belongs to whoever was signed in — the punch queue, the offline
/// cache, the biometric preference, the unread badge — and is cleared with it
/// so the next person on a shared phone inherits nothing. Two things are not
/// like that. `hrms_onboarding_seen` describes the handset, and so does this:
/// clearing it at sign-out would put the login form itself back into a language
/// the person standing there cannot read, which is the one screen where that
/// costs the most and the one screen they cannot get past to fix it.
class AppLocale extends ChangeNotifier {
  AppLocale({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const preferenceKey = 'hrms_locale';

  /// Everything the app is translated into, and the list `MaterialApp` is
  /// given. English is first, so it is what Flutter falls back to for a
  /// handset set to anything else.
  static const supported = <Locale>[Locale('en'), Locale('es')];

  /// What each supported locale calls itself. In its own language, always —
  /// "Spanish" is no use to somebody who is looking for the word Español.
  static const names = <String, String>{
    'en': 'English',
    'es': 'Español',
  };

  Locale? _locale;

  /// The chosen language, or null to follow the handset. Passed straight to
  /// `MaterialApp.locale`, which treats null as exactly that.
  Locale? get locale => _locale;

  /// True while the app is following the phone's own setting.
  bool get followsSystem => _locale == null;

  /// Reads the preference. Called at the start of the session restore rather
  /// than lazily: `_Root` builds synchronously, and a language arriving a frame
  /// later has already drawn a screen in the wrong one.
  Future<void> load() async {
    try {
      final saved = await _storage.read(key: preferenceKey);
      _locale = _parse(saved);
    } catch (e) {
      // A keystore that will not answer is not worth a screen. Following the
      // handset is the right fallback anyway — it is the default.
      debugPrint('Reading the language preference failed: $e');
      _locale = null;
    }
    notifyListeners();
  }

  /// Switches language, or goes back to following the handset when [locale] is
  /// null. Applied first and saved second, unlike the biometric lock: this one
  /// is reversible by the person who just changed it, so a write that fails
  /// must not stop the screen from changing under them.
  Future<void> set(Locale? locale) async {
    if (locale != null && !supported.any((l) => l.languageCode == locale.languageCode)) {
      return;
    }

    _locale = locale;
    notifyListeners();

    try {
      if (locale == null) {
        await _storage.delete(key: preferenceKey);
      } else {
        await _storage.write(key: preferenceKey, value: locale.languageCode);
      }
    } catch (e) {
      // Worst case it reverts to the handset's language at the next launch.
      debugPrint('Saving the language preference failed: $e');
    }
  }

  /// What travels in `Accept-Language`. The chosen language, or the handset's
  /// when nothing has been chosen — never null, because a request with no
  /// preference at all tells the server nothing it can act on.
  String get headerValue =>
      _locale?.languageCode ?? _systemLanguage();

  static String _systemLanguage() {
    final device = PlatformDispatcher.instance.locale.languageCode;
    return supported.any((l) => l.languageCode == device) ? device : 'en';
  }

  static Locale? _parse(String? code) {
    if (code == null || code.isEmpty) return null;
    for (final locale in supported) {
      if (locale.languageCode == code) return locale;
    }
    // A code saved by a build that supported a language this one does not —
    // a downgrade, or a translation withdrawn. Follow the handset rather than
    // showing a language with no strings behind it.
    return null;
  }
}
