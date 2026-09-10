import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'api_client.dart';

/// One crash, as it will be sent (B6.5).
///
/// **Nothing personal goes in here.** A stack trace names code, not people; the
/// exception's own message is the one field that could carry anything, so it is
/// truncated hard and nothing in the app is allowed to build one out of
/// somebody's details. The report is read by an administrator on the employer's
/// own server — which is the whole reason there is no third-party crash service
/// behind this.
@immutable
class CrashRecord {
  const CrashRecord({
    required this.exception,
    required this.occurredAt,
    this.message,
    this.stack,
    this.appVersion,
    this.platform,
    this.osVersion,
  });

  /// The exception's runtime type — `_TypeError`, `StateError`. Never its
  /// `toString()`, which on many exceptions includes the message again.
  final String exception;

  /// UTC, ISO 8601 with the `Z`. The moment of the crash, not of delivery: a
  /// report written on a phone in a locker arrives the next morning, and
  /// stamping it on arrival would put every crash at the same minute.
  final String occurredAt;

  final String? message;
  final String? stack;
  final String? appVersion;
  final String? platform;

  /// `Platform.operatingSystemVersion`. On Android that string already names
  /// the build and the handset, which is why there is no separate device field
  /// and no second plugin to read one.
  final String? osVersion;

  /// The server caps these too. Trimming here as well keeps the file on the
  /// handset small and keeps a 5 MB stack from being written at the moment the
  /// app is already dying.
  static const messageLimit = 500;
  static const stackLimit = 8000;

  Map<String, dynamic> toJson() => {
        'exception': exception,
        'occurred_at': occurredAt,
        if (message != null) 'message': message,
        if (stack != null) 'stack': stack,
        if (appVersion != null) 'app_version': appVersion,
        if (platform != null) 'platform': platform,
        if (osVersion != null) 'os_version': osVersion,
      };

  factory CrashRecord.fromJson(Map<String, dynamic> j) => CrashRecord(
        exception: '${j['exception'] ?? 'Error'}',
        occurredAt: '${j['occurred_at'] ?? ''}',
        message: j['message'] as String?,
        stack: j['stack'] as String?,
        appVersion: j['app_version'] as String?,
        platform: j['platform'] as String?,
        osVersion: j['os_version'] as String?,
      );

  static String? _trim(String? value, int limit) {
    if (value == null) return null;
    final text = value.trim();
    if (text.isEmpty) return null;
    return text.length <= limit ? text : text.substring(0, limit);
  }

  /// Builds a record from what Flutter hands an error handler.
  factory CrashRecord.from(
    Object error,
    StackTrace? stack, {
    String? appVersion,
    String? platform,
    String? osVersion,
  }) =>
      CrashRecord(
        exception: error.runtimeType.toString(),
        occurredAt: DateTime.now().toUtc().toIso8601String(),
        message: _trim(error.toString(), messageLimit),
        stack: _trim(stack?.toString(), stackLimit),
        appVersion: appVersion,
        platform: platform,
        osVersion: osVersion,
      );
}

/// Catches what the app does not survive, and tells the server next time it
/// opens (B6.5).
///
/// **Written to disk first, sent later.** A reporter that posts at the moment
/// of the crash loses precisely the crash that killed the process, and the ones
/// worth having are the ones that did. So the record goes into a file — the
/// same approach the punch queue takes, for the same reason — and is delivered
/// on the next launch.
///
/// **It is never allowed to make things worse.** Every path swallows its own
/// failures: a reporter that throws inside an error handler turns one crash
/// into a loop, and a delivery that fails must leave the app running normally.
///
/// There is no analytics here and there never should be. The app contacts one
/// host — the employer's own server — and the privacy policy, the Apple
/// privacy manifest and both store data forms all say so.
class CrashReporter {
  CrashReporter({
    required ApiClient api,
    @visibleForTesting Directory? directory,
  })  : _api = api,
        _override = directory;

  final ApiClient _api;
  final Directory? _override;

  static const _fileName = 'pending_crashes.json';

  /// The server accepts five in a call, and there is nothing to learn from a
  /// sixth copy of the same stack. The newest are kept: a crash loop's last
  /// report is the one that describes where it ended up.
  static const maxPending = 5;

  List<CrashRecord> _pending = const [];
  bool _loaded = false;
  bool _flushing = false;

  /// Filled in by [install] so a record can name the build it came from.
  String? appVersion;
  String? platform;
  String? osVersion;

  List<CrashRecord> get pending => List.unmodifiable(_pending);

  Future<File> _file() async {
    final dir = _override ?? await getApplicationDocumentsDirectory();

    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  Future<void> load() async {
    if (_loaded) return;

    try {
      final file = await _file();

      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString());
        _pending = (raw is List ? raw : const [])
            .whereType<Map<String, dynamic>>()
            .map(CrashRecord.fromJson)
            .toList();
      }
    } catch (_) {
      // A corrupt file must not stop the app starting. Losing a crash report
      // costs a diagnosis; refusing to launch costs the working day.
      _pending = const [];
    }

    _loaded = true;
  }

  /// Takes over Flutter's two error handlers.
  ///
  /// Both are needed and they catch different things: `FlutterError.onError`
  /// sees exceptions thrown inside the framework — a build, a layout, a
  /// gesture callback — and `PlatformDispatcher.onError` sees the ones that
  /// escape an async gap, which is most of what a networked app produces.
  ///
  /// The previous handler is called afterwards in both cases. Flutter's default
  /// is what prints a readable error to the console, and swallowing it would
  /// make debugging worse in exchange for a report nobody reads until later.
  void install({
    String? appVersion,
    String? platform,
    String? osVersion,
  }) {
    this.appVersion = appVersion;
    this.platform = platform;
    this.osVersion = osVersion;

    final previousFlutterError = FlutterError.onError;

    FlutterError.onError = (details) {
      record(details.exception, details.stack);
      previousFlutterError?.call(details);
    };

    final previousPlatformError = PlatformDispatcher.instance.onError;

    PlatformDispatcher.instance.onError = (error, stack) {
      record(error, stack);

      // False means "not handled", which lets the previous handler — and
      // ultimately the framework's own reporting — see it too.
      return previousPlatformError?.call(error, stack) ?? false;
    };
  }

  /// Queues one crash. Synchronous on the caller's side, because the caller is
  /// an error handler and the process may not be alive for an await.
  void record(Object error, StackTrace? stack) {
    try {
      final report = CrashRecord.from(
        error,
        stack,
        appVersion: appVersion,
        platform: platform,
        osVersion: osVersion,
      );

      _pending = [..._pending, report];

      if (_pending.length > maxPending) {
        _pending = _pending.sublist(_pending.length - maxPending);
      }

      unawaited(_save());
    } catch (_) {
      // A reporter that throws inside an error handler turns one crash into a
      // loop. There is nowhere to report this to and nothing useful to do.
    }
  }

  /// Delivers whatever is waiting. Called once at launch, after the session
  /// restore, so a report from a signed-in handset carries a token and is
  /// attributed to the person who was using it.
  ///
  /// Never throws, and never drops a report it did not manage to send.
  Future<void> flush() async {
    // Claimed before the first await, not after. Two callers reaching an
    // `await load()` ahead of the flag would both pass the guard and both
    // deliver the same batch — the launch flush and a retry landing together
    // is exactly the shape that produces it.
    if (_flushing) return;
    _flushing = true;

    // Declared out here because both failure branches below need to know what
    // was on its way when the call failed.
    var sending = const <CrashRecord>[];

    try {
      await load();
      if (_pending.isEmpty) return;

      sending = _pending;

      await _api.post('/app/crashes', body: {
        'reports': sending.map((r) => r.toJson()).toList(),
      });

      // By identity, not by count. A crash recorded while the call was in
      // flight has to survive it — and it may also have pushed an older one
      // out of the cap, which a sublist would then take the wrong end of.
      _pending = _pending.where((r) => !sending.contains(r)).toList();
      await _save();
    } on ApiException catch (e) {
      if (e.isNetworkFailure) {
        // Keep them. A handset on a site with no coverage will deliver next
        // time, and a crash is worth more late than not at all.
        debugPrint('Crash reports held: no connection');
      } else {
        // The server refused them — a shape it will refuse every time. Holding
        // them would mean retrying the same rejection at every launch for ever,
        // so they go.
        debugPrint('Crash reports dropped: ${e.error}');
        _pending = _pending.where((r) => !sending.contains(r)).toList();
        await _save();
      }
    } catch (e) {
      debugPrint('Crash report delivery failed: $e');
    } finally {
      _flushing = false;
    }
  }

  Future<void> clear() async {
    _pending = const [];
    await _save();
  }

  Future<void> _save() async {
    try {
      final file = await _file();
      await file.writeAsString(
        jsonEncode(_pending.map((r) => r.toJson()).toList()),
        flush: true,
      );
    } catch (_) {
      // Same reasoning as everywhere else here: a diagnostic that cannot be
      // written is not worth an exception.
    }
  }
}
