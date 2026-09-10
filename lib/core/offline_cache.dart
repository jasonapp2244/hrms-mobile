import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'api_client.dart';

/// A body that may have come off the disk rather than off the wire.
@immutable
class CachedResult {
  const CachedResult({required this.body, this.cachedAt});

  final Map<String, dynamic> body;

  /// When this copy was saved, or **null when it came from the server** —
  /// which is the whole test a screen makes. A non-null value is what puts the
  /// "saved copy" banner up, so nothing can show stale data unlabelled.
  final DateTime? cachedAt;

  bool get isStale => cachedAt != null;
}

/// The last good answer from each read-only endpoint, so the app is readable
/// with no signal (B6.3).
///
/// **Only whole response bodies, never parsed models.** Decoding stays in
/// `models.dart` where it already is, so a field added to an endpoint needs no
/// migration here — the cache neither knows nor cares what is in the map.
///
/// **Only endpoints that answer "what is already true about me".** Nothing that
/// takes a decision is cached: an approval inbox served from disk would offer a
/// manager a request somebody else settled an hour ago, and leave balances
/// would talk them into booking days they no longer have.
///
/// Held in a plain JSON file next to the punch queue, and for the same reasons:
/// it must survive a force-quit, and there is nothing in it the person cannot
/// already read on the screen it feeds. It is **not** nothing, though — the
/// profile copy carries the same PII the profile screen shows — so
/// [clear] runs with the token on sign-out, and the next person to use the
/// handset inherits an empty cache.
class OfflineCache {
  OfflineCache({@visibleForTesting Directory? directory})
    : _override = directory;

  static const _fileName = 'offline_cache.json';

  /// `/auth/me`. Also what lets the app open signed-in with no signal at all —
  /// see `Session.restore`.
  static const keyProfile = 'auth.me';

  /// `/attendance/today`. Read back only on the same calendar day; see [fetch].
  static const keyToday = 'attendance.today';

  /// `/schedule`.
  static const keySchedule = 'schedule';

  /// `/attendance/history`, one entry per range the screen offers — the three
  /// are different questions and the answer to a 92-day window is not the
  /// answer to a 7-day one.
  static String historyKey(int days) => 'attendance.history.$days';

  final Directory? _override;

  Map<String, _Entry> _entries = {};
  bool _loaded = false;

  Future<File> _file() async {
    final dir = _override ?? await getApplicationDocumentsDirectory();

    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  Future<void> _load() async {
    if (_loaded) return;

    try {
      final file = await _file();

      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString());
        if (raw is Map<String, dynamic>) {
          _entries = {
            for (final e in raw.entries)
              if (_Entry.tryParse(e.value) case final entry?) e.key: entry,
          };
        }
      }
    } catch (_) {
      // A corrupt cache is an empty cache. Every caller has a live request to
      // fall back on, so there is nothing here worth failing a launch over.
      _entries = {};
    }

    _loaded = true;
  }

  Future<void> _save() async {
    try {
      final file = await _file();
      await file.writeAsString(
        jsonEncode(_entries.map((k, v) => MapEntry(k, v.toJson()))),
        flush: true,
      );
    } catch (_) {
      // Kept in memory for this launch even if the write failed. A cache that
      // cannot persist is still worth having until the process ends.
    }
  }

  /// The saved copy for [key], or null when there is none.
  Future<CachedResult?> read(String key) async {
    await _load();

    final entry = _entries[key];

    return entry == null
        ? null
        : CachedResult(body: entry.body, cachedAt: entry.savedAt);
  }

  Future<void> write(String key, Map<String, dynamic> body) async {
    await _load();
    _entries[key] = _Entry(body: body, savedAt: DateTime.now());
    await _save();
  }

  /// Fetch [path], and fall back to the last good copy when — and only when —
  /// the request never arrived.
  ///
  /// A **refusal is an answer**: a 403 for an account with no employee record,
  /// or a validation failure, is the server telling the truth about now, and
  /// serving yesterday's success over it would hide a real change. So only
  /// [ApiException.isNetworkFailure] reaches the cache; everything else is
  /// rethrown for the screen to show.
  ///
  /// [stillValid] is for a body that expires on its own — today's status is
  /// worthless tomorrow. A copy it rejects is treated as though it were not
  /// there, and the network failure is rethrown.
  Future<CachedResult> fetch(
    ApiClient api,
    String path, {
    required String key,
    Map<String, dynamic>? query,
    bool Function(Map<String, dynamic> body)? stillValid,
  }) async {
    try {
      final res = await api.get(path, query: query);
      await write(key, res);

      return CachedResult(body: res);
    } on ApiException catch (e) {
      if (!e.isNetworkFailure) rethrow;

      final cached = await read(key);
      if (cached == null) rethrow;
      if (stillValid != null && !stillValid(cached.body)) rethrow;

      return cached;
    }
  }

  /// Everything, on sign-out. See the note on the class.
  Future<void> clear() async {
    _entries = {};
    _loaded = true;
    await _save();
  }
}

@immutable
class _Entry {
  const _Entry({required this.body, required this.savedAt});

  final Map<String, dynamic> body;
  final DateTime savedAt;

  Map<String, dynamic> toJson() => {
    'saved_at': savedAt.toUtc().toIso8601String(),
    'body': body,
  };

  /// Null for anything that does not read back as an entry — a half-written
  /// file, or a key left behind by an older build.
  static _Entry? tryParse(Object? raw) {
    if (raw is! Map) return null;

    final body = raw['body'];
    final savedAt = DateTime.tryParse('${raw['saved_at']}');

    if (body is! Map<String, dynamic> || savedAt == null) return null;

    return _Entry(body: body, savedAt: savedAt.toLocal());
  }
}
