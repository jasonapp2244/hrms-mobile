import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// Where a tap on a notification should land.
///
/// The server puts one of these three strings in the payload's `route` key —
/// see `Push-Notifications_Setup.md` — precisely so the app never has to guess
/// the destination by reading the message text. Text gets reworded; a key does
/// not.
enum PushRoute {
  /// Still clocked in after the shift ended (`MissingCheckoutReminder`).
  clock('clock', 'Clock'),

  /// A decision reached the employee (`LeaveRequestDecided`).
  leave('leave', 'Leave'),

  /// A request arrived for a manager (`LeaveRequestSubmitted`).
  approvals('approvals', 'Team');

  const PushRoute(this.wireValue, this.tabLabel);

  /// The string the server sends.
  final String wireValue;

  /// The `HomeShell` tab that answers it. Matched by label rather than index
  /// because the manager tab is only present for somebody with `approve-leave`,
  /// so index 4 is not the same screen for everybody.
  final String tabLabel;

  /// Null for anything unrecognised — a newer server sending a route this build
  /// has never heard of must open the app normally, not crash it.
  static PushRoute? parse(Object? value) {
    for (final route in PushRoute.values) {
      if (route.wireValue == value) return route;
    }
    return null;
  }
}

/// One notification, reduced to the three things the app actually uses.
@immutable
class PushMessage {
  const PushMessage({this.title, this.body, this.route});

  final String? title;
  final String? body;
  final PushRoute? route;

  /// The server sends `notification` (what the OS displays) and `data` (what
  /// the app reads) in the same message, so both halves arrive together.
  factory PushMessage.fromRemote(RemoteMessage message) => PushMessage(
        title: message.notification?.title,
        body: message.notification?.body,
        route: PushRoute.parse(message.data['route']),
      );

  bool get hasText => (title ?? body ?? '').isNotEmpty;
}

/// The handset's notification plumbing, behind an interface.
///
/// The same reasoning as `LocationSource` in `location.dart`: the real
/// implementation needs a platform channel and a Firebase project, and a
/// headless `flutter test` has neither. Every screen and every test therefore
/// talks to this rather than to `FirebaseMessaging` directly.
abstract class PushProvider {
  /// Ask the OS for permission to show notifications. False if refused.
  ///
  /// Android 13+ shows a dialog; earlier Android grants silently; iOS always
  /// asks. Implementations must not throw.
  Future<bool> requestPermission();

  /// This installation's FCM token, or null if it cannot be had.
  Future<String?> currentToken();

  /// Fires when the OS reissues the token, which it does on its own schedule —
  /// after a restore, a reinstall, or for no visible reason at all. A token the
  /// server holds after a refresh is dead, so this is not optional.
  Stream<String> get tokenRefreshes;

  /// Messages that arrive while the app is on screen. Android shows nothing of
  /// its own in this state and iOS only a banner, so the app decides.
  Stream<PushMessage> get foregroundMessages;

  /// Notifications tapped while the app was in the background.
  Stream<PushMessage> get notificationTaps;

  /// The notification that launched the app from cold, if that is what
  /// happened. Delivered once — it does not appear in [notificationTaps].
  Future<PushMessage?> launchMessage();

  /// Throw this installation's token away.
  ///
  /// Sign-out on a shared handset: the row is deleted server-side too, but the
  /// local token is a live address for the *device*, and the next person to
  /// sign in should get a new one rather than inherit it.
  Future<void> discardToken();
}

/// A handset that receives nothing.
///
/// The default everywhere. Tests use it, desktop uses it, and — the case that
/// matters in production — so does any build whose Firebase credentials file is
/// missing, because [FirebasePushProvider.connect] returns this rather than
/// failing. Push is the one feature that has to be absent quietly: the app's
/// job is clocking people in, and it can do all of that with no Firebase
/// project in existence.
class DisabledPushProvider implements PushProvider {
  const DisabledPushProvider();

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<String?> currentToken() async => null;

  @override
  Stream<String> get tokenRefreshes => const Stream.empty();

  @override
  Stream<PushMessage> get foregroundMessages => const Stream.empty();

  @override
  Stream<PushMessage> get notificationTaps => const Stream.empty();

  @override
  Future<PushMessage?> launchMessage() async => null;

  @override
  Future<void> discardToken() async {}
}

/// The real thing, on top of `firebase_messaging`.
///
/// Assumes `Firebase.initializeApp()` has already succeeded — see
/// [FirebasePushProvider.connect], which is the only thing that should build
/// one of these.
class FirebasePushProvider implements PushProvider {
  FirebasePushProvider(this._messaging);

  final FirebaseMessaging _messaging;

  /// Builds a provider if this build can actually receive push, and a
  /// [DisabledPushProvider] if it cannot.
  ///
  /// "Cannot" is the normal case until somebody has done the console work:
  /// without `google-services.json` (Android) or `GoogleService-Info.plist`
  /// (iOS) the native SDK has no project to attach to and initialisation
  /// throws. That must not stop the app launching, so it is caught here and
  /// reported as "no push" rather than as an error.
  static Future<PushProvider> connect(
    Future<void> Function() initialiseFirebase,
  ) async {
    try {
      await initialiseFirebase();
      return FirebasePushProvider(FirebaseMessaging.instance);
    } catch (error) {
      debugPrint('Push disabled — Firebase did not initialise: $error');
      return const DisabledPushProvider();
    }
  }

  @override
  Future<bool> requestPermission() async {
    try {
      final settings = await _messaging.requestPermission();
      final status = settings.authorizationStatus;

      // `provisional` is iOS quiet delivery: notifications arrive in the
      // notification centre without a prompt having been shown. They are real
      // deliveries, so registering the token is correct.
      return status == AuthorizationStatus.authorized ||
          status == AuthorizationStatus.provisional;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> currentToken() async {
    try {
      return await _messaging.getToken();
    } catch (_) {
      // Routinely null-or-throws on iOS at first launch: FCM cannot mint a
      // token until APNs has handed one over, which happens a moment later.
      // [tokenRefreshes] fires when it does, and registration happens there
      // instead — so this is a delay, not a failure.
      return null;
    }
  }

  @override
  Stream<String> get tokenRefreshes => _messaging.onTokenRefresh;

  @override
  Stream<PushMessage> get foregroundMessages =>
      FirebaseMessaging.onMessage.map(PushMessage.fromRemote);

  @override
  Stream<PushMessage> get notificationTaps =>
      FirebaseMessaging.onMessageOpenedApp.map(PushMessage.fromRemote);

  @override
  Future<PushMessage?> launchMessage() async {
    try {
      final message = await _messaging.getInitialMessage();
      return message == null ? null : PushMessage.fromRemote(message);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> discardToken() async {
    try {
      await _messaging.deleteToken();
    } catch (_) {
      // Best effort. The server row is deleted by the logout call regardless,
      // which is the half that stops delivery.
    }
  }
}

/// Keeps the server's idea of where to reach this handset in step with the OS's.
///
/// Owned by [Session], because registration is a consequence of signing in and
/// unregistration a consequence of signing out — there is no state here that
/// outlives a session.
///
/// **Nothing in here is allowed to fail loudly.** A person whose push
/// registration failed should still be able to clock in; every API call below
/// swallows its errors for that reason.
class PushService {
  PushService({
    required ApiClient api,
    PushProvider provider = const DisabledPushProvider(),
  })  : _api = api,
        _provider = provider;

  final ApiClient _api;
  final PushProvider _provider;

  StreamSubscription<String>? _refreshes;
  StreamSubscription<PushMessage>? _taps;
  StreamSubscription<PushMessage>? _foreground;

  String? _token;

  /// The token currently registered, for `POST /auth/logout` to unregister.
  String? get token => _token;

  /// Where a tapped notification wants to go, until somebody handles it.
  ///
  /// A [ValueNotifier] rather than a stream because the tap can land before
  /// `HomeShell` is on screen — the app may still be verifying the saved token
  /// against `/auth/me` when the OS delivers it. A stream event at that moment
  /// has no listener and is lost; a value waits.
  final ValueNotifier<PushRoute?> pendingRoute = ValueNotifier(null);

  /// Notifications that arrived with the app open, for the in-app banner.
  Stream<PushMessage> get foregroundMessages => _foregroundController.stream;
  final StreamController<PushMessage> _foregroundController =
      StreamController<PushMessage>.broadcast();

  /// Called once the user is signed in and the API client holds their token.
  ///
  /// Safe to call repeatedly — the endpoint is documented as safe to repeat,
  /// and a launch that restores a session calls this on exactly the same path
  /// a fresh login does.
  Future<void> start({required String deviceName}) async {
    // Set before the listeners go up: a token refresh can arrive during this
    // method, and the handler needs a name to send with it.
    _lastDeviceName = deviceName;

    await _listen();

    if (!await _provider.requestPermission()) {
      // Refused, or no push in this build. Nothing further to do: registering a
      // token the OS will never deliver to just fills the table with rows that
      // fail forever.
      return;
    }

    final token = await _provider.currentToken();
    if (token != null) await _register(token, deviceName: deviceName);

    // Whether or not there was a token just now, a cold launch may deliver one
    // through the tap handlers before the UI exists.
    final launch = await _provider.launchMessage();
    if (launch?.route != null) pendingRoute.value = launch!.route;
  }

  /// Stops this handset receiving, and reports the token so the caller can tell
  /// the server in the same round trip it is already making.
  Future<String?> stop() async {
    final token = _token;

    await _refreshes?.cancel();
    await _taps?.cancel();
    await _foreground?.cancel();
    _refreshes = _taps = null;
    _foreground = null;

    await _provider.discardToken();
    _token = null;
    pendingRoute.value = null;

    return token;
  }

  Future<void> _listen() async {
    // Re-entrant by design: `start` runs again on every launch, and doubling
    // the subscriptions would double every banner.
    if (_refreshes != null) return;

    _refreshes = _provider.tokenRefreshes.listen((token) {
      // The device name is not re-read here — the server treats the token as
      // the identity of the row and overwrites the rest, so a refresh that
      // carries the old name is corrected on the next `start`.
      _register(token, deviceName: _lastDeviceName ?? 'Mobile device');
    });

    _taps = _provider.notificationTaps.listen((message) {
      if (message.route != null) pendingRoute.value = message.route;
    });

    _foreground = _provider.foregroundMessages.listen((message) {
      if (message.hasText) _foregroundController.add(message);
    });
  }

  String? _lastDeviceName;

  Future<void> _register(String token, {required String deviceName}) async {
    _lastDeviceName = deviceName;

    try {
      await _api.post('/devices', body: {
        'token': token,
        'platform': _platform,
        'device_name': deviceName,
        'app_version': appVersion,
      });
      _token = token;
    } on ApiException catch (e) {
      // Worth keeping the token locally even so: logout still needs something
      // to send, and a registration that failed on a flaky connection may well
      // have reached the server.
      _token = token;
      debugPrint('Push registration failed: ${e.error}');
    }
  }

  /// One of the three the server accepts (`PushDevice::PLATFORMS`). Desktop
  /// never gets here — [DisabledPushProvider] returns no token — but it has to
  /// resolve to something valid rather than throw.
  String get _platform =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  /// Recorded against the handset so a bug report can be tied to a build.
  ///
  /// Passed in at build time rather than read from the pubspec: reading it
  /// would mean another plugin, and this is a diagnostic field the server
  /// treats as optional.
  ///
  ///   flutter build apk --dart-define=APP_VERSION=1.0.0+1
  static const String appVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '1.0.0',
  );

  void dispose() {
    _refreshes?.cancel();
    _taps?.cancel();
    _foreground?.cancel();
    _foregroundController.close();
    pendingRoute.dispose();
  }
}
