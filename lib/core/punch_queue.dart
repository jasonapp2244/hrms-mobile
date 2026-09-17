import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'api_client.dart';

/// A punch the handset could not deliver when it was made (B2.4).
///
/// [intendedType] is carried for the **label only** — what the button said when
/// it was tapped, so the screen can go on making sense while the queue drains.
/// It is never sent: the server decides the direction from the punches before
/// that moment, exactly as it does for a live one, so a queue that has drifted
/// out of step cannot post the wrong direction.
@immutable
class QueuedPunch {
  const QueuedPunch({
    required this.occurredAt,
    required this.intendedType,
    this.latitude,
    this.longitude,
    this.locationMocked,
    this.deviceRooted,
    this.deviceEmulator,
  });

  /// UTC, ISO 8601 with the `Z`. Sent verbatim, and it is also the identity of
  /// this punch on the server — a redelivery of the same instant is recognised
  /// as the same punch rather than written twice.
  ///
  /// UTC rather than local wall-clock so that a handset carried across a
  /// timezone still names the right instant.
  final String occurredAt;

  /// `in` or `out`, as the button read at the moment of the tap.
  final String intendedType;

  final double? latitude;
  final double? longitude;

  /// What the handset said about itself **at the moment of the tap** (B2.7).
  ///
  /// Held with the punch rather than read again at sync time, for the same
  /// reason `occurredAt` is: the queue exists to deliver what was true then.
  /// Reading these on delivery would describe the phone at the moment it found
  /// signal, which is a different phone-state and possibly a different day.
  ///
  /// Null throughout means *unknown*, and is omitted from the wire rather than
  /// sent as null — the server stores null for "the client said nothing".
  final bool? locationMocked;
  final bool? deviceRooted;
  final bool? deviceEmulator;

  Map<String, dynamic> toJson() => {
        'occurred_at': occurredAt,
        'intended_type': intendedType,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (locationMocked != null) 'location_mocked': locationMocked,
        if (deviceRooted != null) 'device_rooted': deviceRooted,
        if (deviceEmulator != null) 'device_emulator': deviceEmulator,
      };

  /// What goes to `/attendance/sync` — deliberately without `intended_type`.
  Map<String, dynamic> toWire() => {
        'occurred_at': occurredAt,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (locationMocked != null) 'location_mocked': locationMocked,
        if (deviceRooted != null) 'device_rooted': deviceRooted,
        if (deviceEmulator != null) 'device_emulator': deviceEmulator,
      };

  factory QueuedPunch.fromJson(Map<String, dynamic> j) => QueuedPunch(
        occurredAt: '${j['occurred_at'] ?? ''}',
        intendedType: '${j['intended_type'] ?? 'in'}',
        latitude: (j['latitude'] as num?)?.toDouble(),
        longitude: (j['longitude'] as num?)?.toDouble(),
        // `as bool?` rather than `== true`: a key absent from a punch queued by
        // an older build must stay unknown, not become a denial.
        locationMocked: j['location_mocked'] as bool?,
        deviceRooted: j['device_rooted'] as bool?,
        deviceEmulator: j['device_emulator'] as bool?,
      );
}

/// What came back from trying to drain the queue.
@immutable
class SyncOutcome {
  const SyncOutcome({
    this.accepted = 0,
    this.duplicate = 0,
    this.refused = 0,
    this.refusals = const [],
    this.stillQueued = 0,
    this.failed = false,
  });

  final int accepted;
  final int duplicate;
  final int refused;

  /// The server's reason for each refusal, to show the person. These do not
  /// come back on a retry, so they are the one thing they need to read.
  final List<String> refusals;

  final int stillQueued;

  /// The whole call failed — no connection yet. Nothing was dropped.
  final bool failed;

  bool get changedAnything => accepted > 0 || duplicate > 0 || refused > 0;
}

/// Punches waiting for a connection.
///
/// **Deliberately has no connectivity library.** Those APIs answer "is there a
/// network interface", which is not the question — a handset joined to hotel
/// wifi with a captive portal is online by every measure except the one that
/// matters. So a punch is always attempted first, and queued only when the
/// attempt actually fails. Trying is the only honest test.
///
/// Held in a plain JSON file rather than secure storage: it is not a secret,
/// there may be dozens of entries, and it has to survive a force-quit — which
/// rules out memory and makes a file the simplest thing that works.
class PunchQueue {
  PunchQueue({@visibleForTesting Directory? directory}) : _override = directory;

  static const _fileName = 'pending_punches.json';

  final Directory? _override;

  List<QueuedPunch> _pending = const [];
  bool _loaded = false;

  /// So the punch screen can show a "waiting to sync" banner without polling.
  final ValueNotifier<int> count = ValueNotifier<int>(0);

  /// Guards against two flushes overlapping — a resume and a manual retry
  /// landing together would otherwise deliver the same punches twice. The
  /// server would call the second lot duplicates, but the app would then drop
  /// entries it had not confirmed.
  bool _flushing = false;

  List<QueuedPunch> get pending => List.unmodifiable(_pending);

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
            .map(QueuedPunch.fromJson)
            .toList();
      }
    } catch (_) {
      // A corrupt or unreadable queue file must not stop the app starting.
      // Losing an unsent punch is bad; refusing to launch is worse, and the
      // person can always ask HR for a correction.
      _pending = const [];
    }

    _loaded = true;
    count.value = _pending.length;
  }

  Future<void> _save() async {
    count.value = _pending.length;

    try {
      final file = await _file();
      await file.writeAsString(
        jsonEncode(_pending.map((p) => p.toJson()).toList()),
        flush: true,
      );
    } catch (_) {
      // Kept in memory even if the write failed — this attempt may still
      // deliver, and a punch held badly beats a punch dropped.
    }
  }

  Future<void> add(QueuedPunch punch) async {
    await load();
    _pending = [..._pending, punch];
    await _save();
  }

  /// Try to deliver everything waiting.
  ///
  /// Entries are dropped only on a verdict from the server. A call that never
  /// arrived leaves the queue exactly as it was — the whole point is that a
  /// punch is not lost because the network was not there.
  Future<SyncOutcome> flush(ApiClient api) async {
    // Claimed before the first await, not after it. `await load()` yields to
    // the microtask queue even when there is nothing to read, so two callers
    // arriving together — a resume and a manual retry, which is the pair this
    // guard exists for — both used to get past a check that ran after it, and
    // both sent the same punches. The server recognises the second delivery as
    // duplicates, so nothing was written twice; the cost was on this side, in
    // an outcome that reported entries as duplicate that had in fact just been
    // accepted.
    if (_flushing) {
      return SyncOutcome(stillQueued: _pending.length);
    }

    _flushing = true;

    await load();

    if (_pending.isEmpty) {
      _flushing = false;

      return SyncOutcome(stillQueued: 0);
    }

    // A copy: the queue can be appended to while this is in flight, and only
    // the entries actually sent may be dropped.
    final sending = List<QueuedPunch>.from(_pending);

    try {
      final res = await api.post('/attendance/sync', body: {
        'punches': sending.map((p) => p.toWire()).toList(),
      });

      final results = ((res['results'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

      // Every verdict is final — accepted, duplicate and refused all mean
      // "stop retrying this one". Refused is included on purpose: it is
      // refused for a reason that will not change, so keeping it would retry
      // for ever and the banner would never clear.
      final settled = results.map((r) => '${r['occurred_at']}').toSet();

      final refusals = results
          .where((r) => r['result'] == 'refused')
          // Empty when the server named no reason. The words for that case are
          // the app's, and they live in the ARB files — inventing an English
          // sentence here would put one language past the translation layer.
          .map((r) => '${r['message'] ?? ''}')
          .toList();

      _pending = _pending.where((p) => !settled.contains(p.occurredAt)).toList();
      await _save();

      return SyncOutcome(
        accepted: _countOf(res['accepted']),
        duplicate: _countOf(res['duplicate']),
        refused: _countOf(res['refused']),
        refusals: refusals,
        stillQueued: _pending.length,
      );
    } on ApiException {
      // Still no connection, or the server refused the batch outright. Nothing
      // is dropped and nothing is claimed.
      return SyncOutcome(failed: true, stillQueued: _pending.length);
    } finally {
      _flushing = false;
    }
  }

  static int _countOf(Object? v) => v is num ? v.toInt() : 0;

  /// Signing out clears the queue with the token.
  ///
  /// Undelivered punches belong to the person who made them, and the next
  /// person to sign in on this handset must not inherit them.
  Future<void> clear() async {
    _pending = const [];
    await _save();
  }

  void dispose() => count.dispose();
}
