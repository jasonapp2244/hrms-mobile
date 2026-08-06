import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';
import 'location.dart';
import 'models.dart';
import 'push.dart';

/// Signed-in state for the whole app.
///
/// A plain [ChangeNotifier] rather than a state-management package: there is
/// exactly one piece of global state here — who is signed in — and a package
/// would be more machinery than the problem needs.
class Session extends ChangeNotifier {
  Session({
    ApiClient? api,
    FlutterSecureStorage? storage,
    PunchLocator? locator,
    PushProvider pushProvider = const DisabledPushProvider(),
  })  : api = api ?? ApiClient(),
        // Defaults are correct on both platforms now: the plugin uses the
        // Keychain on iOS and its own ciphers on Android. The old
        // encryptedSharedPreferences flag is deprecated and ignored.
        _storage = storage ?? const FlutterSecureStorage(),
        locator = locator ??
            const PunchLocator(source: GeolocatorLocationSource()) {
    push = PushService(api: this.api, provider: pushProvider);
  }

  final ApiClient api;
  final FlutterSecureStorage _storage;

  /// Registration of this handset for notifications.
  ///
  /// Lives here because it is a consequence of the session: a token is worth
  /// registering only while somebody is signed in, and has to be withdrawn the
  /// moment they are not. Defaults to a provider that receives nothing, so a
  /// test — and a build with no Firebase credentials — behaves exactly as the
  /// app did before push existed.
  late final PushService push;

  /// Supplies the coordinates attached to a punch. Injectable for the same
  /// reason [api] is: a headless test has no platform channel to answer the
  /// location plugin. It resolves to null there rather than failing, so a test
  /// that does not care about location does not have to stub one.
  final PunchLocator locator;

  static const _tokenKey = 'hrms_api_token';
  static const _deviceNameKey = 'hrms_device_name';

  AppUser? _user;
  bool _restoring = true;
  String? _restoreError;

  AppUser? get user => _user;
  bool get isSignedIn => _user != null;

  /// True while the launch-time session restore is in flight, so the UI can
  /// hold a splash instead of flashing the login screen at somebody who is
  /// already signed in.
  bool get isRestoring => _restoring;

  String? get restoreError => _restoreError;

  /// Names the token server-side so it can be recognised and revoked from the
  /// "where am I signed in" screen. Stable across launches — logging in again
  /// from the same device name *replaces* that token rather than issuing a
  /// second one, so a reinstall leaves no valid credential behind.
  Future<String> deviceName() async {
    final existing = await _storage.read(key: _deviceNameKey);
    if (existing != null && existing.isNotEmpty) return existing;

    final generated = defaultTargetPlatform == TargetPlatform.iOS
        ? 'iPhone'
        : defaultTargetPlatform == TargetPlatform.android
            ? 'Android device'
            : 'Desktop';
    await _storage.write(key: _deviceNameKey, value: generated);
    return generated;
  }

  /// Called once at launch. Restores the token, then verifies it against
  /// `/auth/me` — roles and permissions change without the app knowing, so a
  /// cached user object is not trustworthy on its own.
  Future<void> restore() async {
    _restoring = true;
    _restoreError = null;
    notifyListeners();

    try {
      final token = await _storage.read(key: _tokenKey);
      if (token == null || token.isEmpty) {
        _user = null;
        return;
      }

      api.token = token;
      final res = await api.get('/auth/me');
      _user = AppUser.fromJson(res['user'] as Map<String, dynamic>);

      // Every launch, not only the first: the OS reissues push tokens on its
      // own schedule, and a handset the server can no longer reach is
      // indistinguishable from one that never registered.
      await _startPush();
    } on ApiException catch (e) {
      if (e.isUnauthenticated) {
        // The token was revoked server-side — signed out on another device, or
        // logout-all after a lost phone. Clear it rather than retrying.
        await _clearToken();
        _user = null;
      } else {
        // Network trouble is not a reason to throw away a good token. Keep it
        // and let the user retry.
        _restoreError = e.displayMessage;
        _user = null;
      }
    } finally {
      _restoring = false;
      notifyListeners();
    }
  }

  Future<void> login({required String email, required String password}) async {
    final res = await api.post('/auth/login', body: {
      'email': email.trim(),
      'password': password,
      'device_name': await deviceName(),
    });

    final token = '${res['token']}';
    await _storage.write(key: _tokenKey, value: token);
    api.token = token;

    _user = AppUser.fromJson(res['user'] as Map<String, dynamic>);
    notifyListeners();

    // After the user is published, not before: the permission prompt should
    // appear over the app rather than over the login screen.
    await _startPush();
  }

  /// Registers this handset for notifications, and never gets in the way.
  ///
  /// Signing in is the primary job. A push registration that fails — no
  /// Firebase project, permission refused, the network down — must leave
  /// somebody signed in and able to clock in, so nothing here is allowed to
  /// escape.
  Future<void> _startPush() async {
    try {
      await push.start(deviceName: await deviceName());
    } catch (e) {
      debugPrint('Push start failed: $e');
    }
  }

  /// Signs out this device only.
  ///
  /// The push token goes with it: without that the handset keeps receiving the
  /// previous person's notifications, which on a shared work phone means one
  /// employee reading another's leave decisions.
  ///
  /// [pushToken] is only for a caller that already knows one. Left off — which
  /// is what every screen does — the token is taken from [push], so no call
  /// site has to remember that push exists.
  Future<void> logout({String? pushToken}) async {
    final token = pushToken ?? await push.stop();

    try {
      await api.post('/auth/logout', body: {
        if (token != null) 'push_token': token,
      });
    } on ApiException {
      // A failed logout call must not strand somebody in a signed-in UI they
      // cannot leave. Clear locally regardless.
    }
    await _clearToken();
    _user = null;
    notifyListeners();
  }

  /// Signs out everywhere and drops every registered handset — for a lost phone.
  Future<int> logoutEverywhere() async {
    // The server drops every registered handset on this endpoint, so there is
    // nothing to unregister — but this one still has to stop listening and
    // throw its own token away.
    await push.stop();

    int revoked = 0;
    try {
      final res = await api.post('/auth/logout-all');
      revoked = (res['tokens_revoked'] as num?)?.toInt() ?? 0;
    } on ApiException {
      // Same reasoning as above.
    }
    await _clearToken();
    _user = null;
    notifyListeners();
    return revoked;
  }

  /// Re-reads the signed-in user. Worth calling when returning to the app:
  /// a permission granted this morning should not need a reinstall to appear.
  Future<void> refreshUser() async {
    if (!isSignedIn) return;
    try {
      final res = await api.get('/auth/me');
      _user = AppUser.fromJson(res['user'] as Map<String, dynamic>);
      notifyListeners();
    } on ApiException catch (e) {
      if (e.isUnauthenticated) {
        await _clearToken();
        _user = null;
        notifyListeners();
      }
    }
  }

  Future<void> _clearToken() async {
    await _storage.delete(key: _tokenKey);
    api.token = null;
  }

  @override
  void dispose() {
    push.dispose();
    super.dispose();
  }
}
