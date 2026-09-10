import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';
import 'app_gate.dart';
import 'biometrics.dart';
import 'crash_reporter.dart';
import 'locale.dart';
import 'location.dart';
import 'models.dart';
import 'offline_cache.dart';
import 'onboarding.dart';
import 'punch_queue.dart';
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
    PunchQueue? queue,
    OfflineCache? cache,
    PushProvider pushProvider = const DisabledPushProvider(),
    BiometricAuthenticator biometrics = const LocalAuthBiometrics(),
    AppVersionSource versionSource = const PackageInfoVersion(),
    CrashReporter? crashes,
    Onboarding? onboarding,
    AppLocale? appLocale,
  })  : _injectedCrashes = crashes,
        _localeOverride = appLocale,
        _onboardingOverride = onboarding,
        api = api ?? ApiClient(),
        queue = queue ?? PunchQueue(),
        cache = cache ?? OfflineCache(),
        // Defaults are correct on both platforms now: the plugin uses the
        // Keychain on iOS and its own ciphers on Android. The old
        // encryptedSharedPreferences flag is deprecated and ignored.
        _storage = storage ?? const FlutterSecureStorage(),
        locator = locator ??
            const PunchLocator(source: GeolocatorLocationSource()) {
    push = PushService(api: this.api, provider: pushProvider);
    lock = AppLock(authenticator: biometrics, storage: _storage);
    gate = AppGate(api: this.api, versionSource: versionSource);

    // Built here rather than taken as a plain default so that it shares this
    // session's client — and therefore its token. A report delivered after
    // sign-in is attributed to the person who was using the handset; one from
    // before it is kept with nobody against it, which is the case the endpoint
    // is public for.
    //
    // **`this.` is load-bearing.** The named parameter above is also called
    // `crashes`, and inside a constructor body a parameter shadows the field —
    // so a bare `crashes = …` assigns the argument and leaves the field unset.
    // Nothing complains: it is a `late final`, so the failure is a
    // LateInitializationError at the first *read*, which is
    // `_installCrashReporting` in `HrmsApp.initState` — the first frame of
    // every launch. No unit test touched it, because nothing but the real app
    // reads this field.
    this.crashes = _injectedCrashes ?? CrashReporter(api: this.api);
    _onboarding = _onboardingOverride ?? Onboarding(storage: _storage);
    locale = _localeOverride ?? AppLocale(storage: _storage);

    // Two jobs on one listener. The app has to redraw in the new language, and
    // the header the server is told to answer in has to change with it —
    // a header naming a language somebody switched away from an hour ago is
    // worse than no header at all.
    locale.addListener(_applyLocale);
    _applyLocale();

    // Re-broadcast, so that a screen already listening for a sign-out learns
    // about a lock or a blocked build without subscribing to three notifiers.
    // Locking, being told to update and signing out are the same event to
    // every widget above the shell: the thing on screen has to be replaced.
    lock.addListener(notifyListeners);
    gate.addListener(notifyListeners);
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

  /// Punches made with no signal, waiting for one (B2.4).
  ///
  /// On the session rather than on the punch screen because it outlives that
  /// screen: the queue has to survive the tab being switched away from, the app
  /// being force-quit, and the person signing out — the last of which clears
  /// it, since undelivered punches belong to whoever made them.
  final PunchQueue queue;

  /// The last good answer from each read-only endpoint (B6.3).
  ///
  /// On the session for the same reason the queue is: it outlives every screen
  /// that reads it, and it is cleared with the token, because a saved copy of
  /// somebody's roster and profile belongs to them and not to the handset.
  final OfflineCache cache;

  /// Whether this handset is held behind its own biometric check (B1.3).
  ///
  /// On the session because it is armed and cleared by the same two events the
  /// token is: there is nothing to lock before somebody signs in, and the
  /// preference belongs to whoever set it, not to the phone.
  late final AppLock lock;

  /// Whether the server will talk to this build at all (B6.6).
  ///
  /// Not session state — it applies before anybody signs in, and during a
  /// maintenance window there is nobody to sign in as. It hangs here because it
  /// needs the same [api] and the same launch and resume hooks, and because
  /// `_Root` already reads the session: a fourth notifier above it would buy
  /// nothing but a second `InheritedWidget`.
  late final AppGate gate;

  /// Crashes the app did not survive, waiting to be told about (B6.5).
  ///
  /// Here for the token: a report delivered after sign-in should say whose
  /// handset it came from, and sharing [api] is what makes that happen without
  /// the reporter knowing anything about sessions.
  late final CrashReporter crashes;

  final CrashReporter? _injectedCrashes;

  final Onboarding? _onboardingOverride;
  late final Onboarding _onboarding;

  final AppLocale? _localeOverride;

  /// Which language the app is drawn in (B6.2).
  ///
  /// On the session because `MaterialApp` is above `_Root`, which already
  /// reads the session — a second `InheritedWidget` for one nullable `Locale`
  /// would be more parts than the problem has. **It is not session state.** It
  /// survives a sign-out on purpose: see [AppLocale].
  late final AppLocale locale;

  void _applyLocale() {
    api.acceptLanguage = locale.headerValue;
    notifyListeners();
  }

  bool _needsOnboarding = false;

  /// True on a handset that has never been shown what the app is for (B1.1).
  ///
  /// Read once during [restore], because `_Root` is a synchronous build and a
  /// screen that appears a frame late has already flashed the login form at
  /// somebody. Nothing else re-reads it: within one launch the answer only
  /// changes when [completeOnboarding] changes it.
  bool get needsOnboarding => _needsOnboarding;

  /// The carousel is finished, or was skipped. Both mean the same thing.
  Future<void> completeOnboarding() async {
    await _onboarding.markSeen();
    _needsOnboarding = false;
    notifyListeners();
  }

  /// How many notifications are waiting unread (B5.6).
  ///
  /// A [ValueNotifier] rather than session state so the bell can rebuild on its
  /// own: this changes on a push arriving, on the inbox being opened, and on
  /// every launch, and none of those should rebuild the whole tree the way a
  /// `notifyListeners()` here would.
  ///
  /// Zero when nobody is signed in, which is also its value before the first
  /// answer comes back — a badge that guesses high is worse than one that
  /// appears a moment late.
  final ValueNotifier<int> unreadNotifications = ValueNotifier<int>(0);

  /// Asks the server how many are unread. Silent on failure: a badge is not
  /// worth an error, and a handset with no signal simply keeps the last count
  /// it had.
  Future<void> refreshUnread() async {
    if (!isSignedIn) return;

    try {
      final res = await api.get('/notifications');
      unreadNotifications.value = (res['unread'] as num?)?.toInt() ?? 0;
    } on ApiException catch (e) {
      debugPrint('Unread count unavailable: ${e.error}');
    }
  }

  /// How long the app will go on trusting a cached identity with no way to
  /// re-read it. See [_restoreOffline].
  static const offlineIdentityGrace = Duration(days: 7);

  static const _tokenKey = 'hrms_api_token';
  static const _deviceNameKey = 'hrms_device_name';

  AppUser? _user;
  bool _restoring = true;
  ApiException? _restoreError;
  DateTime? _offlineSince;

  AppUser? get user => _user;
  bool get isSignedIn => _user != null;

  /// True while the app is running on a cached identity rather than one the
  /// server confirmed this launch. Screens use it to say so; nothing branches
  /// on it, because every write already fails honestly with no connection.
  bool get isOffline => _offlineSince != null;

  /// When the identity the app is running on was last confirmed. Null whenever
  /// that was this launch.
  DateTime? get offlineSince => _offlineSince;

  /// True while the launch-time session restore is in flight, so the UI can
  /// hold a splash instead of flashing the login screen at somebody who is
  /// already signed in.
  bool get isRestoring => _restoring;

  /// Why the launch-time restore failed, or null. Kept as the exception rather
  /// than as a sentence: the words come from `ApiErrorText.text`, which needs
  /// the strings, and there is no `BuildContext` here to get them from.
  ApiException? get restoreError => _restoreError;

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

    // First, and awaited. `_Root` builds synchronously and the gate can put a
    // screen up ahead of everything else, so a language that arrives a frame
    // later has already drawn something in the wrong one. This is a keystore
    // read; the gate check it races is a network round trip.
    await locale.load();

    try {
      final token = await _storage.read(key: _tokenKey);
      if (token == null || token.isEmpty) {
        _user = null;

        // Nothing on disk belongs to anybody without a token to go with it.
        // A session ended by logout-all on another device never ran
        // [_clearToken] here, so this is the only sweep that catches it.
        await cache.clear();
        return;
      }

      api.token = token;
      final res = await api.get('/auth/me');
      _user = AppUser.fromJson(res['user'] as Map<String, dynamic>);
      _offlineSince = null;
      await _cacheProfile(res['user']);

      // The badge, once per launch. Not awaited and not guarded: a count is
      // not worth holding the splash for, and refreshUnread swallows its own
      // failures (B5.6).
      unawaited(refreshUnread());

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
      } else if (e.isNetworkFailure && await _restoreOffline()) {
        // Opened with no signal, on the last answer the server gave. Nothing
        // to report here: the app is usable, and every screen says so.
        //
        // No _startPush: registering needs the network this launch did not
        // have. A signal arriving later in the same run leaves this handset
        // unregistered until the next cold start, which is the same state as
        // an app that has simply not been opened since the OS reissued its
        // token — already the case push has to tolerate.
      } else {
        // Network trouble is not a reason to throw away a good token. Keep it
        // and let the user retry.
        _restoreError = e;
        _user = null;
      }
    } finally {
      // Before the splash comes down, not after: a lock that engages once the
      // home screen is already drawn has shown a shared handset the thing it
      // was put there to hide.
      await lock.load(signedIn: isSignedIn);

      // Same reasoning, and the same moment: `_Root` builds synchronously, so
      // an answer that arrives a frame later has already flashed the login
      // form at somebody who was about to be introduced to the app.
      //
      // Never for a session that restored. Somebody signed in on this handset
      // has used it before, whatever the keystore says — a wiped preference
      // must not walk them through it again on the way back in.
      _needsOnboarding = !isSignedIn && await _onboarding.isPending();

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
    _offlineSince = null;
    await _cacheProfile(res['user']);
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
      _offlineSince = null;
      await _cacheProfile(res['user']);
      notifyListeners();
    } on ApiException catch (e) {
      if (e.isUnauthenticated) {
        await _clearToken();
        _user = null;
        notifyListeners();
      }
    }
  }

  /// Keep the signed-in user for a launch that cannot reach the server.
  ///
  /// **The user object only.** The login response also carries the bearer
  /// token, and the cache is a plain file — the token lives in the keystore
  /// precisely so that it never lands in one.
  Future<void> _cacheProfile(Object? user) async {
    if (user is Map<String, dynamic>) {
      await cache.write(OfflineCache.keyProfile, {'user': user});
    }
  }

  /// Open on the last verified answer from `/auth/me` when there is no way to
  /// ask again (B6.3). False when there is nothing usable to open on.
  ///
  /// Without this the offline punch queue is close to unreachable: a handset
  /// with no signal fails the restore, lands on the login screen, and login
  /// needs the network too — so the one screen carrying the button that queues
  /// a punch could not be opened at all unless the app happened to still be
  /// running from before the signal went.
  ///
  /// **Bounded by [offlineIdentityGrace].** Roles, permissions and whether
  /// somebody still works here are re-read on every launch that reaches the
  /// server, and offline they cannot be. Past the grace the app asks for a
  /// sign-in rather than going on trusting what it last knew about them.
  Future<bool> _restoreOffline() async {
    final cached = await cache.read(OfflineCache.keyProfile);
    if (cached == null) return false;

    final savedAt = cached.cachedAt;
    final user = cached.body['user'];

    if (savedAt == null || user is! Map<String, dynamic>) return false;
    if (DateTime.now().difference(savedAt) > offlineIdentityGrace) return false;

    _user = AppUser.fromJson(user);
    _offlineSince = savedAt;
    return true;
  }

  Future<void> _clearToken() async {
    await _storage.delete(key: _tokenKey);
    api.token = null;

    // Undelivered punches go with the token. They belong to the person who
    // made them, and the next person to sign in on this handset must not
    // inherit them — nor have them posted against their own record.
    await queue.clear();

    // So does the saved copy of their profile, roster and attendance. Same
    // reasoning, and the profile copy is also the thing that would otherwise
    // let the app reopen signed-in as somebody who signed out.
    await cache.clear();

    // The unread badge belongs to the person who was signed in. Leaving it
    // would greet the next one on a shared handset with somebody else's count.
    unreadNotifications.value = 0;

    // And the lock preference. It says "this phone is shared", which is a
    // statement about the person who set it rather than about the handset —
    // the next one to sign in here has not been asked.
    await lock.clear();

    _offlineSince = null;
  }

  @override
  void dispose() {
    // Before the lock is disposed: its listener is this notifier's own
    // notifyListeners, and firing that after dispose throws.
    locale.removeListener(_applyLocale);
    locale.dispose();
    lock.removeListener(notifyListeners);
    lock.dispose();
    unreadNotifications.dispose();
    gate.removeListener(notifyListeners);
    gate.dispose();
    push.dispose();
    queue.dispose();
    super.dispose();
  }
}
