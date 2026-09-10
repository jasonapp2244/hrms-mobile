import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'api_client.dart';

/// What the server says this build may do (B6.6).
enum GateAction {
  /// Carry on. The only outcome that is ever inferred rather than told.
  ok,

  /// Too old to be talked to. Stop, and offer the store.
  updateRequired,

  /// The server is deliberately not serving the app right now.
  maintenance,
}

/// Reads the running build's own version number.
///
/// An interface because the real one is a platform channel, and because the
/// version that matters is the *installed binary's* — not a constant in the
/// source, which drifts from `pubspec.yaml` the first time somebody ships
/// without updating it. A gate reading a version the build does not actually
/// have is a gate that lies in both directions.
abstract class AppVersionSource {
  const AppVersionSource();

  /// `major.minor.patch`, or null when it cannot be read.
  Future<String?> version();
}

class PackageInfoVersion implements AppVersionSource {
  const PackageInfoVersion();

  @override
  Future<String?> version() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (e) {
      // No platform channel — a test, or a build the plugin does not cover.
      // Null means "do not judge me", which the server honours.
      debugPrint('Reading the app version failed: $e');
      return null;
    }
  }
}

/// Whether this build may carry on (B6.6).
///
/// **It fails open, at every level.** An unreachable server, an unparseable
/// answer, an action nobody has heard of — all of them resolve to
/// [GateAction.ok]. Only an explicit `update_required` or `maintenance` stops
/// anything.
///
/// That is not caution, it is the point. The app is deliberately usable with no
/// signal: it opens on a cached identity, shows the last roster it saw, and
/// queues a punch for later. A gate that blocked whenever it could not reach
/// the server would take all of that away in exactly the conditions it was
/// built for — a cleaner on a site with no coverage would be told the app is
/// under maintenance and have no way to record that they turned up.
class AppGate extends ChangeNotifier {
  AppGate({
    required ApiClient api,
    AppVersionSource versionSource = const PackageInfoVersion(),
  })  : _api = api,
        _versionSource = versionSource;

  final ApiClient _api;
  final AppVersionSource _versionSource;

  /// How long the app may be away before the verdict is asked for again.
  ///
  /// A maintenance window that starts while somebody has the app open would
  /// otherwise not be noticed until the next cold start, which on a phone that
  /// is never closed is never.
  static const recheckAfter = Duration(minutes: 5);

  GateAction _action = GateAction.ok;
  String? _message;
  String? _storeUrl;
  bool _checking = false;
  DateTime? _leftAt;

  GateAction get action => _action;

  /// The server's own words. Shown verbatim — it is the only channel that can
  /// say *when* a window ends.
  String? get message => _message;

  /// Where to send somebody who has to update. Null unless [action] is
  /// [GateAction.updateRequired] and the server had a link for this platform.
  String? get storeUrl => _storeUrl;

  bool get isBlocked => _action != GateAction.ok;

  bool get isChecking => _checking;

  /// Asks the server. Never throws, and never leaves the app blocked on an
  /// answer it did not get.
  Future<void> check() async {
    if (_checking) return;

    _checking = true;
    notifyListeners();

    try {
      final version = await _versionSource.version();
      // Null on a platform with no store, which the server answers `ok`.
      final platform = apiPlatformName();

      final res = await _api.get('/app/status', query: {
        // Omitted rather than sent empty when unknown. The server reads an
        // absent version as "cannot judge" and answers `ok`, which is the
        // right outcome — but sending nothing is the honest shape for it.
        if (version != null && version.isNotEmpty) 'version': version,
        if (platform != null) 'platform': platform,
      });

      _apply(res);
    } on ApiException catch (e) {
      // Includes the network failure this is most likely to hit. Unblock: the
      // app works offline on purpose, and a gate is not a reason to take that
      // away.
      debugPrint('App status check failed: ${e.error}');
      _clear();
    } catch (e) {
      debugPrint('App status check failed: $e');
      _clear();
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  void _apply(Map<String, dynamic> res) {
    final action = switch (res['action']) {
      'update_required' => GateAction.updateRequired,
      'maintenance' => GateAction.maintenance,
      // Anything else, including a verdict invented after this build shipped.
      // A build that cannot understand the answer is not a build to strand.
      _ => GateAction.ok,
    };

    _action = action;

    if (action == GateAction.ok) {
      _message = null;
      _storeUrl = null;
      return;
    }

    final message = res['message'];
    final storeUrl = res['store_url'];

    _message = message is String && message.isNotEmpty ? message : null;
    _storeUrl = storeUrl is String && storeUrl.isNotEmpty ? storeUrl : null;
  }

  void _clear() {
    _action = GateAction.ok;
    _message = null;
    _storeUrl = null;
  }

  /// Asks again when the app comes back after being away for longer than
  /// [recheckAfter]. Wired up in `HrmsApp`.
  void handleLifecycle(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _leftAt ??= DateTime.now();
      case AppLifecycleState.resumed:
        final left = _leftAt;
        _leftAt = null;

        // While blocked, every return is worth a re-ask however brief: the
        // person is most likely coming back from the store, or from waiting
        // out a window, and the whole screen exists to be left behind.
        if (isBlocked || (left != null && DateTime.now().difference(left) >= recheckAfter)) {
          check();
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }
}
