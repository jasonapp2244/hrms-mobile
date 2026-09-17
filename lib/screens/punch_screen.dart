import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../core/offline_cache.dart';
import '../core/punch_queue.dart';
import '../core/session.dart';
import '../core/tab_visibility.dart';
import '../core/theme.dart';
import '../main.dart';
import '../widgets/async_view.dart';
import 'notifications_screen.dart';

/// The home screen: one big button, and enough context around it that somebody
/// can tell at a glance whether they are clocked in and for how long.
class PunchScreen extends StatefulWidget {
  const PunchScreen({super.key, required this.visible});

  /// Set by `HomeShell` while this tab is the one on screen.
  final ValueListenable<bool> visible;

  @override
  State<PunchScreen> createState() => _PunchScreenState();
}

class _PunchScreenState extends State<PunchScreen> with RefreshOnShow {
  TodayStatus? _today;
  bool _loading = true;
  bool _punching = false;
  bool _breaking = false;
  String? _error;

  /// True when [_error] is one no retry can clear — the account has no employee
  /// record. See [ApiErrorText.isMissingEmployeeRecord].
  bool _fatal = false;

  /// Drives the live "worked so far" figure. The server sends worked_minutes at
  /// the moment of the call; ticking locally keeps the card honest between
  /// refreshes without hammering the endpoint.
  Timer? _ticker;
  DateTime? _loadedAt;

  /// When the card on screen was saved, or null when the server answered just
  /// now. Also what stops the worked-hours figure ticking: see [_load].
  DateTime? _cachedAt;

  /// No signal, and no copy of *today* to fall back on — the ordinary case of
  /// opening the app at a site with no reception, having last used it
  /// yesterday. See [_load].
  bool _offlineWithoutToday = false;

  @override
  ValueListenable<bool> get visibility => widget.visible;

  @override
  Future<void> refresh() => _load(silent: true);

  @override
  void initState() {
    super.initState();
    _load();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && _today?.isClockedIn == true) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = SessionScope.read(context);

    // The queue is read from disk once, on the first build that has a session
    // to read it with. Anything waiting from a previous launch shows up in the
    // banner immediately rather than at the next tap.
    session.queue.load();

    // B2.8. Attached once, and re-attached only if the session itself is
    // replaced — which is what a test that pumps the app twice does.
    if (!identical(session, _session)) {
      _session?.actions.pending.removeListener(_consumePendingAction);
      _session = session;
      session.actions.pending.addListener(_consumePendingAction);

      // Launching *from* a shortcut is the normal case, so the tap is already
      // waiting rather than arriving as an event. It will not fire yet — the
      // first `_load` is still in flight — but `_load` asks again when it
      // settles, which is the moment there is a day to punch against.
      _consumePendingAction();
    }
  }

  @override
  void dispose() {
    _session?.actions.pending.removeListener(_consumePendingAction);
    _ticker?.cancel();
    super.dispose();
  }

  /// Whether a punch can be made right now.
  ///
  /// **One rule, read by the button and by the launcher shortcut.** The two
  /// states that offer a punch are a loaded day outside the cooldown, and the
  /// offline case where the day is unknown but a punch can still be queued
  /// (B2.4) — and a second copy of that in the shortcut handler would be the
  /// next thing to drift.
  bool get _canPunchNow =>
      !_punching && (_offlineWithoutToday || (_today?.canCheck ?? false));

  /// Puts the shortcut that matches this day on the launcher (B2.8).
  ///
  /// Called whenever the day settles, so the menu follows a punch made here, a
  /// punch made on the web, and a language changed on the Profile screen — the
  /// title is read from `context.t` every time rather than cached.
  ///
  /// Nothing is published while the day is unknown. The offline case has no
  /// answer to "which way does the next punch go", and a shortcut that guessed
  /// would be a label that lies on the one screen that must not.
  void _publishShortcut() {
    final today = _today;
    if (today == null) return;

    final t = context.t;
    unawaited(
      SessionScope.read(context).actions.publish(
            willClockIn: today.willClockIn,
            title: today.willClockIn ? t.punchCheckIn : t.punchCheckOut,
          ),
    );
  }

  /// Makes the punch a launcher shortcut asked for (B2.8).
  ///
  /// **Held, not dropped, while the first load is in flight.** Tapping the
  /// shortcut is how the app started, so this runs for the first time before
  /// there is any day to punch against; `_load` calls it again once there is.
  /// Dropping it there would make the feature fail exactly on the cold launch
  /// it exists for.
  ///
  /// Once the day has settled the tap is spent either way — a shortcut that
  /// survived into the next refresh would punch somebody in twice, minutes
  /// apart, for one tap they had long forgotten.
  void _consumePendingAction() {
    final session = _session;
    if (session == null || !mounted) return;
    if (session.actions.pending.value == null) return;

    // Still loading. Leave it waiting; the `finally` in `_load` asks again.
    if (_loading) return;

    // Cleared **before** the punch, not after: `_punch` reloads on success and
    // the reload asks again, which with the value still set would punch in a
    // loop.
    session.actions.pending.value = null;

    // Nothing to do if the screen would not offer the button either — the
    // cooldown, or an account with no employee record. The person is looking
    // at the screen that says why.
    if (!_canPunchNow) return;

    unawaited(_punch());
  }

  Session? _session;

  /// [silent] keeps the current card on screen while the new status is
  /// fetched, for refreshes the user did not explicitly ask for.
  Future<void> _load({bool silent = false}) async {
    setState(() {
      _loading = !silent;
      _error = null;
      _fatal = false;
    });

    try {
      final session = SessionScope.read(context);

      // The saved copy is what keeps this screen — and with it the button that
      // queues a punch — reachable with no signal. Without it the first
      // refresh after the signal goes replaces the whole screen with a "try
      // again", and B2.4's queue can no longer be added to.
      //
      // Only today's copy will do. Yesterday's says "clocked out at 17:30" and
      // would have somebody believing they had already clocked in this morning.
      final res = await session.cache.fetch(
        session.api,
        '/attendance/today',
        key: OfflineCache.keyToday,
        stillValid: (body) => '${body['date']}' == _ymd(DateTime.now()),
      );

      if (!mounted) return;
      setState(() {
        _offlineWithoutToday = false;
        _today = TodayStatus.fromJson(res.body);
        // Null for a saved copy, which freezes the worked-hours figure. Ticking
        // it on would add every minute since the copy was taken, including the
        // ones after a clock-out the handset never heard about.
        _loadedAt = res.cachedAt == null ? DateTime.now() : null;
        _cachedAt = res.cachedAt;
        _loading = false;
      });

      // Reaching the server is the only proof there is a connection, and a
      // fresh answer is that proof — a cached one is the opposite. Drain
      // anything waiting, but not from inside a drain, which _drainQueue
      // guards against.
      if (res.cachedAt == null) unawaited(_drainQueue(announce: true));
    } on ApiException catch (e) {
      if (!mounted) return;
      // Read here rather than before the request: the first load runs from
      // initState, and reaching for the strings there registers an
      // inherited-widget dependency before the element has finished
      // building, which asserts.
      final t = context.t;

      // No signal, and yesterday's copy was rightly refused. This is the
      // ordinary way somebody arrives here — a site with no reception, the app
      // last opened the evening before — and it is precisely when B2.4's queue
      // is needed. An error page with a "try again" button would leave them no
      // way to record that they turned up.
      //
      // The day's state is genuinely unknown, so nothing is drawn that claims
      // to know it: no worked-hours card, no in-or-out wording. Just a punch
      // that will be kept at the time it was made. The server decides the
      // direction when it arrives, exactly as it does for a live one.
      final signedInEmployee =
          SessionScope.read(context).user?.hasEmployeeRecord == true;

      if (e.isNetworkFailure && signedInEmployee) {
        setState(() {
          _offlineWithoutToday = true;
          _today = null;
          _cachedAt = null;
          _loadedAt = null;
          _error = null;
          _loading = false;
        });
        return;
      }

      setState(() {
        _offlineWithoutToday = false;
        // No retry offered for this one: it is the account, not the network.
        _fatal = e.isMissingEmployeeRecord;
        _error = _fatal ? t.clockNoEmployeeRecord : e.text(t);
        _cachedAt = null;
        _loading = false;
      });
    } finally {
      // B2.8, and on every exit from this method including the early returns.
      // The day has settled now, whichever way it went — so the launcher menu
      // is brought into line with it, and a shortcut tap that arrived while
      // this load was in flight finally has something to act on.
      if (mounted) {
        _publishShortcut();
        _consumePendingAction();
      }
    }
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Minutes worked, extrapolated from the last load. Only the open stretch
  /// grows — closed pairs are fixed.
  int get _liveWorkedMinutes {
    final today = _today;
    if (today == null) return 0;
    if (!today.isClockedIn || _loadedAt == null) return today.workedMinutes;
    final elapsed = DateTime.now().difference(_loadedAt!).inMinutes;
    return today.workedMinutes + (elapsed > 0 ? elapsed : 0);
  }

  /// Deliver anything the handset could not send at the time.
  ///
  /// Attempted on every load rather than on a connectivity event: a network
  /// interface coming back is not the same as the server being reachable, and
  /// this screen is refreshed on resume and on every tab switch anyway.
  Future<void> _drainQueue({bool announce = false}) async {
    // Read before the first await: the palette cannot change mid-call, and
    // reaching for a BuildContext after one is the lint this avoids.
    final colors = AppColors.of(context);
    final t = context.t;
    final session = SessionScope.read(context);

    if (session.queue.count.value == 0) return;

    final outcome = await session.queue.flush(session.api);

    if (!mounted) return;

    // A refusal is the one outcome the person has to read: it will not come
    // back on a retry, and it means a punch they made is not on their record.
    if (outcome.refusals.isNotEmpty) {
      final refusal = outcome.refusals.first;
      _showResult(
        refusal.isEmpty ? t.errorGeneric : refusal,
        Theme.of(context).colorScheme.error,
      );
    } else if (announce && outcome.changedAnything) {
      _showResult(
        t.clockQueueDelivered(
          outcome.accepted == 1 ? 1 : outcome.accepted + outcome.duplicate,
        ),
        colors.present,
      );
    }

    if (outcome.changedAnything) await _load(silent: true);
  }

  /// The message to show instead of posting, or null to go ahead (B2.5).
  ///
  /// Returns null in every case the server would have accepted: no fence
  /// applies, the day has not loaded, or the punch carries no coordinates —
  /// that last one is an exemption the server makes deliberately, and matching
  /// it here is what keeps this a shortcut rather than a second, stricter rule.
  String? _outsideFence(Map<String, dynamic> body) {
    final fence = _today?.geofence;
    final lat = (body['latitude'] as num?)?.toDouble();
    final lng = (body['longitude'] as num?)?.toDouble();

    if (fence == null || lat == null || lng == null) return null;
    if (!fence.excludes(lat, lng)) return null;

    return context.t.clockOutsideFence(
      Fmt.distance(context.t, fence.metresFrom(lat, lng)),
      fence.office,
      '${fence.radiusMetres}',
    );
  }

  Future<void> _punch() async {
    // Read before the first await: neither the palette nor the strings can
    // change mid-call, and reaching for a BuildContext after one is the lint
    // this avoids.
    final colors = AppColors.of(context);
    final t = context.t;

    if (_punching) return;
    setState(() => _punching = true);

    try {
      final session = SessionScope.read(context);

      // Location is a record, not a gate — office, remote and hybrid staff all
      // clock in from wherever they are. The locator returns an empty body
      // rather than throwing when there is no fix, no permission or no signal,
      // so a punch is never lost to a missing coordinate; it is just recorded
      // without one, which the API explicitly allows.
      final body = await session.locator.punchBody();

      // B2.5. When a fence applies and there *is* a fix, the app can already
      // tell what the server is about to say — the rule and the radius came
      // down with the day, and the distance is the same haversine. Saying it
      // here costs no round trip and names the office and the gap, which is the
      // one thing the person can act on.
      //
      // **Only with a fix.** The server exempts a punch that arrives without
      // coordinates, so refusing one here would invent a rule the server does
      // not have and lock out anybody whose phone cannot see the sky.
      final outside = _outsideFence(body);

      if (outside != null) {
        _showResult(outside, colors.late);
        return;
      }

      final res = await session.api.post('/attendance/check', body: body);
      final punch = Punch.fromJson(res['punch'] as Map<String, dynamic>);

      if (!mounted) return;
      _showResult(
        '${res['message']}',
        punch.status == 'late' ? colors.late : colors.present,
      );
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;

      if (e.isDuplicateScan) {
        // Reads as success to the person holding the phone: the punch they
        // wanted is already on record, they just tapped twice.
        _showResult(t.clockAlreadyRecorded, colors.neutral);
        await _load();
      } else if (e.isNetworkFailure) {
        // The whole point of B2.4. The tap is kept at the moment it was made,
        // and delivered when there is something to deliver it over — rather
        // than lost, or silently recorded hours later at the wrong time.
        await _queuePunch();
      } else {
        _showResult(
          e.error == 'no_office' ? t.clockNoOffice : e.text(t),
          Theme.of(context).colorScheme.error,
        );
      }
    } finally {
      if (mounted) setState(() => _punching = false);
    }
  }

  /// Keep a punch that could not be sent.
  ///
  /// The time is taken **here**, at the tap, not when it eventually goes — a
  /// punch delivered four hours late is still a punch made four hours ago, and
  /// the server records it at the time claimed here.
  ///
  /// `intendedType` is what the button read, kept so this screen goes on making
  /// sense while the queue drains. It is not sent: the server decides the
  /// direction from the punches before that moment, exactly as for a live one.
  Future<void> _queuePunch() async {
    // Read before the first await: neither the palette nor the strings can
    // change mid-call, and reaching for a BuildContext after one is the lint
    // this avoids.
    final colors = AppColors.of(context);
    final t = context.t;
    final session = SessionScope.read(context);
    final body = await session.locator.punchBody();

    await session.queue.add(QueuedPunch(
      occurredAt: DateTime.now().toUtc().toIso8601String(),
      // Falls to 'out' when the day could not be read at all — the offline
      // card above. Nothing renders this, and the server ignores it, so a
      // guess here costs nothing; a guess on the wire would cost a punch.
      intendedType: _today?.willClockIn == true ? 'in' : 'out',
      latitude: (body['latitude'] as num?)?.toDouble(),
      longitude: (body['longitude'] as num?)?.toDouble(),
      // Taken now and kept with the punch (B2.7) — what the phone was when the
      // button was pressed, not what it is when the queue finally drains.
      locationMocked: body['location_mocked'] as bool?,
      deviceRooted: body['device_rooted'] as bool?,
      deviceEmulator: body['device_emulator'] as bool?,
    ));

    if (!mounted) return;

    _showResult(t.clockQueuedNotice, colors.late);
  }

  /// Start or end a break (B2.6).
  ///
  /// A separate endpoint from the punch, and separate state here, because the
  /// two refuse for different reasons: a break is refused when the day is not
  /// in a state for one, a punch never is. `break_not_available` means the
  /// screen is out of date, so it reloads rather than blaming the person.
  Future<void> _break() async {
    // Read before the first await: neither the palette nor the strings can
    // change mid-call, and reaching for a BuildContext after one is the lint
    // this avoids.
    final colors = AppColors.of(context);
    final t = context.t;
    if (_breaking) return;
    setState(() => _breaking = true);

    try {
      final session = SessionScope.read(context);

      final res = await session.api.post(
        '/attendance/break',
        body: await session.locator.punchBody(),
      );

      if (!mounted) return;
      _showResult('${res['message']}', colors.neutral);
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;

      if (e.isDuplicateScan) {
        _showResult(t.clockAlreadyDone, colors.neutral);
        await _load();
      } else if (e.error == 'break_not_available') {
        // The day moved on under the screen — clocked out on another device,
        // most likely. Refreshing answers it better than any message would.
        _showResult(e.text(t), colors.late);
        await _load();
      } else {
        _showResult(e.text(t), Theme.of(context).colorScheme.error);
      }
    } finally {
      if (mounted) setState(() => _breaking = false);
    }
  }

  void _showResult(String message, Color color) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: color,
          duration: const Duration(seconds: 3),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final user = session.user;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          user?.employee?.fullName ?? user?.name ?? context.t.clockToday,
        ),
        actions: [
          // The way into the notification history (B5.6). On this tab because
          // it is the one everybody opens; a sixth tab for something read once
          // a week would cost the clock screen room it needs more.
          _NotificationBell(unread: session.unreadNotifications),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: context.t.actionRefresh,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: AsyncView(
        loading: _loading,
        error: _error,
        onRetry: _fatal ? null : _load,
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              // Above the card, because it changes what the numbers below mean:
              // hours held on the handset are not hours HR can see yet.
              _QueueBanner(
                queue: SessionScope.read(context).queue,
                onRetry: () => _drainQueue(announce: true),
              ),
              // Below the queue banner: a punch waiting to send is the more
              // urgent of the two, and the one the person may need to act on.
              OfflineBanner(savedAt: _cachedAt, onRetry: _load),
              if (_offlineWithoutToday)
                _OfflineClockCard(
                  busy: _punching,
                  // The same handler as the live button. It posts first and
                  // queues only when that actually fails — trying is the only
                  // honest test of a connection, and one may well have come
                  // back since this screen gave up.
                  onPressed: _punch,
                  onRetry: _load,
                ),
              if (_today != null) ...[
                _StatusCard(today: _today!, workedMinutes: _liveWorkedMinutes),
                const SizedBox(height: 20),
                _PunchButton(
                  today: _today!,
                  busy: _punching,
                  onPressed: _canPunchNow ? _punch : null,
                ),
                // Only on the clock. Off the clock there is no break to take,
                // and the server would refuse it — so there is nothing to show.
                if (_today!.isClockedIn) ...[
                  const SizedBox(height: 12),
                  _BreakButton(
                    today: _today!,
                    busy: _breaking,
                    onPressed: _today!.canBreak ? _break : null,
                  ),
                  // What pressing it costs them (A5.7). The server has known
                  // whether a break is paid since the policy shipped and never
                  // said, which left the one screen with a break button unable
                  // to answer the only question somebody has before taking one.
                  _BreakPolicyNote(shift: _today!.shift),
                ],
                const SizedBox(height: 24),
                _DayNotes(today: _today!),
                if (_today!.punches.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  _PunchList(punches: _today!.punches),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The clock screen with no signal and no copy of today (B6.3 / B2.4).
///
/// Deliberately says nothing about whether the person is on the clock. The
/// handset does not know, and guessing from the last punch it happens to
/// remember is how somebody ends up told they are already at work.
/// The bell, with a count when there is one (B5.6).
///
/// Listens to the session's counter rather than being handed a number, so it
/// is right after the inbox is read and after a push lands with the app open,
/// without the clock screen having to know about either.
class _NotificationBell extends StatelessWidget {
  const _NotificationBell({required this.unread});

  final ValueListenable<int> unread;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: unread,
      builder: (context, count, _) {
        final bell = IconButton(
          // Says the number, not just "notifications" — a screen reader user
          // gets what the badge shows rather than what it looks like.
          tooltip: count == 0
              ? context.t.bellNoUnread
              : context.t.bellUnread(count),
          icon: const Icon(Icons.notifications_none),
          onPressed: () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const NotificationsScreen(),
              ),
            );
          },
        );

        if (count == 0) return bell;

        return Badge.count(
          count: count,
          // Sits over the icon rather than replacing it, so the control keeps
          // its 48dp target whatever the badge does.
          alignment: const Alignment(0.42, -0.42),
          child: bell,
        );
      },
    );
  }
}

class _OfflineClockCard extends StatelessWidget {
  const _OfflineClockCard({
    required this.busy,
    required this.onPressed,
    required this.onRetry,
  });

  final bool busy;
  final VoidCallback onPressed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final t = context.t;

    return Column(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.cloud_off, color: colors.late, size: 20),
                    const SizedBox(width: 10),
                    Text(
                      t.clockOfflineTitle,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Spacer(),
                    TextButton(
                      onPressed: onRetry,
                      style: TextButton.styleFrom(
                        foregroundColor: colors.late,
                      ),
                      child: Text(t.actionRetry),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  t.clockOfflineBody,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          height: 72,
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: busy ? null : onPressed,
            icon: busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  )
                : const Icon(Icons.more_time, size: 26),
            label: Text(
              t.clockSaveAPunch,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: colors.late,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.today, required this.workedMinutes});

  final TodayStatus today;
  final int workedMinutes;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final t = context.t;
    final clockedIn = today.isClockedIn;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: today.onBreak
                        ? colors.late
                        : (clockedIn ? colors.present : colors.neutral),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                // Flexible rather than fixed (B6.4): at the OS's larger font
                // sizes "Not clocked in" and the date together are wider than
                // the card, and a plain Row clips whatever is on the right.
                Expanded(
                  child: Text(
                    // On a break is a third state, not a fourth word for
                    // clocked out. The clock is still running on the day; it is
                    // the paid total below that has paused.
                    today.onBreak
                        ? t.clockOnBreak
                        : (clockedIn ? t.clockClockedIn : t.clockNotClockedIn),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  Fmt.shortDate(t, today.date),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            // A Wrap, not a Row (B6.4). `displaySmall` at 2× is most of the
            // card's width on its own, and "worked today" beside it does not
            // fit at all — so at large sizes it drops to its own line instead
            // of being clipped off the right edge.
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.end,
              spacing: 10,
              children: [
                Text(
                  Fmt.duration(t, workedMinutes),
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1.5,
                    fontFeatures: const [],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    t.clockWorkedToday,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            if (today.shift != null) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Icon(
                    Icons.schedule,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      t.clockShiftLine(today.shift!.name, today.shift!.window),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            // B2.5. **Policy, not position** — it needs no fix, no permission
            // and no battery, so it can be stated before anybody taps rather
            // than after they have been refused. Present only when a fence
            // actually applies to this employee: the server resolves that, and
            // a home worker sees nothing.
            if (today.geofence != null) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Icon(
                    Icons.my_location,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      t.clockFenceRule(
                        '${today.geofence!.radiusMetres}',
                        today.geofence!.office,
                      ),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PunchButton extends StatelessWidget {
  const _PunchButton({required this.today, required this.busy, this.onPressed});

  final TodayStatus today;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final clockingIn = today.willClockIn;
    final t = context.t;

    // A minimum, not a height (B6.4). At the OS's larger font sizes the 21px
    // label and the cooldown note under it need more than 120px, and a fixed
    // box clips them — on the one control the whole app exists for.
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 120),
      child: FilledButton(
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(
          // The theme's `Size.fromHeight(50)` would otherwise fight the
          // constraint above and pin this back to 50.
          minimumSize: const Size.fromHeight(120),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          // #F26522 at 21px semibold is large text by WCAG, which asks 3:1 of
          // it — 3.15 clears that. The ordinary 16px buttons do not, which is
          // why `primary` is the deeper orange and this one names its own.
          backgroundColor: clockingIn ? AppTheme.brandOf(context) : AppTheme.brandDeepOf(context),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        child: busy
            ? const CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2.6,
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(clockingIn ? Icons.login : Icons.logout, size: 34),
                  const SizedBox(height: 8),
                  Text(
                    clockingIn ? t.punchCheckIn : t.punchCheckOut,
                    style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  // can_check is false only while the duplicate cooldown runs.
                  // Say why the button is dead rather than letting a tap fail.
                  if (!today.canCheck)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        t.clockCooldown,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w400,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

/// "2 punches waiting to send" (B2.4).
///
/// Listens to the queue rather than being handed a count, so it is right after
/// a punch is queued from this screen and after one drains in the background,
/// without either of those having to remember to rebuild it.
///
/// Shown whenever anything is waiting — not only while offline. Somebody whose
/// punch has not reached HR should be able to see that, and try again, at any
/// point rather than only during the outage.
class _QueueBanner extends StatelessWidget {
  const _QueueBanner({required this.queue, required this.onRetry});

  final PunchQueue queue;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final t = context.t;
    return ValueListenableBuilder<int>(
      valueListenable: queue.count,
      builder: (context, waiting, _) {
        if (waiting == 0) return const SizedBox.shrink();

        return Padding(
          padding: EdgeInsets.only(bottom: 16),
          child: Container(
            padding: EdgeInsets.fromLTRB(14, 10, 8, 10),
            decoration: BoxDecoration(
              color: colors.late.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.late.withValues(alpha: 0.32)),
            ),
            child: Row(
              children: [
                Icon(Icons.cloud_off, color: colors.late, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    t.clockQueueWaiting(waiting),
                    style: TextStyle(color: colors.late, fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(foregroundColor: colors.late),
                  child: Text(t.actionRetry),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The break button (B2.6).
///
/// Outlined rather than filled, and half the height of the punch button. The
/// clock in/out button is the one thing this screen is for; a break is a
/// secondary action and giving it equal weight would invite mis-taps on the
/// one control that matters.
class _BreakButton extends StatelessWidget {
  const _BreakButton({required this.today, required this.busy, this.onPressed});

  final TodayStatus today;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final starting = today.willStartBreak;
    final t = context.t;

    // Same reasoning as the punch button: a floor rather than a ceiling, so a
    // 16px label at 2× scale grows the button instead of being clipped by it.
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: OutlinedButton.icon(
        onPressed: busy ? null : onPressed,
        icon: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              )
            : Icon(starting ? Icons.free_breakfast_outlined : Icons.play_arrow),
        label: Text(
          starting ? t.clockStartBreak : t.clockEndBreak,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        style: OutlinedButton.styleFrom(
          // On a break the control that ends it is the live one, so it gets the
          // colour. Starting one is unremarkable and stays quiet.
          foregroundColor: starting ? null : AppTheme.brandDeepOf(context),
          side: starting ? null : BorderSide(color: AppTheme.brandDeepOf(context), width: 1.6),
          // The theme's 48 would pin this back under the 56 above.
          minimumSize: const Size.fromHeight(56),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );
  }
}

/// What a break costs, under this shift's policy (A5.7).
///
/// One line, and only when there is something to say: a shift with no break
/// configured gets nothing rather than "0 minutes, unpaid".
///
/// **It states the consequence, not the setting.** "Unpaid" is a payroll word;
/// "comes off your hours" is what somebody standing in a corridor deciding
/// whether to take lunch actually needs to know. The minimum rule gets its own
/// wording for the same reason — under it, cutting a break short buys nothing,
/// and that changes what people do.
class _BreakPolicyNote extends StatelessWidget {
  const _BreakPolicyNote({required this.shift});

  final ShiftInfo? shift;

  @override
  Widget build(BuildContext context) {
    final policy = shift;

    if (policy == null || !policy.hasBreakPolicy) {
      return const SizedBox.shrink();
    }

    final t = context.t;
    final theme = Theme.of(context);
    final colors = AppColors.of(context);

    final (icon, text, tone) = switch (policy) {
      final s when s.breakIsPaid => (
        Icons.check_circle_outline,
        t.clockBreakPaid(s.breakMinutes),
        colors.present,
      ),
      final s when s.breakIsMinimum => (
        Icons.info_outline,
        t.clockBreakUnpaidMinimum(s.breakMinutes),
        colors.neutral,
      ),
      final s => (
        Icons.info_outline,
        t.clockBreakUnpaid(s.breakMinutes),
        colors.neutral,
      ),
    };

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: tone),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: tone),
            ),
          ),
        ],
      ),
    );
  }
}

/// Holiday, leave and day-off notes. None of them disable the button:
/// somebody who books a day off and comes in anyway worked, and the record has
/// to say so.
class _DayNotes extends StatelessWidget {
  const _DayNotes({required this.today});

  final TodayStatus today;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final t = context.t;
    final notes = <(IconData, String, Color)>[
      if (today.holiday != null)
        (
          Icons.celebration_outlined,
          t.clockHolidayNote(today.holiday!),
          colors.neutral,
        ),
      if (today.leave != null)
        (
          Icons.beach_access_outlined,
          t.clockLeaveNote(today.leave!),
          colors.leave,
        ),
      if (today.isDayOff)
        (Icons.weekend_outlined, t.clockDayOffNote, colors.neutral),
    ];

    if (notes.isEmpty) return const SizedBox.shrink();

    return Column(
      children: [
        for (final (icon, text, color) in notes)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: color.withValues(alpha: 0.30)),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 19, color: color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(color: color, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _PunchList extends StatelessWidget {
  const _PunchList({required this.punches});

  final List<Punch> punches;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final t = context.t;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.clockTodaysPunches,
          style: theme.textTheme.labelSmall?.copyWith(
            letterSpacing: 1.1,
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        Card(
          child: Column(
            children: [
              for (var i = 0; i < punches.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                ListTile(
                  // Four types, not two. A ternary on isIn would label a
                  // break_start "Checked out" — the same mistake the server
                  // made in /attendance/today before B2.6.
                  leading: Icon(
                    switch (punches[i].type) {
                      'in' => Icons.login,
                      'out' => Icons.logout,
                      'break_start' => Icons.free_breakfast_outlined,
                      _ => Icons.play_arrow,
                    },
                    color: punches[i].isBreak
                        ? colors.late
                        : (punches[i].isIn ? colors.present : colors.neutral),
                  ),
                  title: Text(
                    punches[i].label(t),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: punches[i].office != null
                      ? Text(punches[i].office!)
                      : null,
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        punches[i].time,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (punches[i].status == 'late')
                        Text(
                          t.clockLateFlag,
                          style: TextStyle(fontSize: 11, color: colors.late),
                        )
                      else if (punches[i].status == 'early_leave')
                        Text(
                          t.clockEarlyFlag,
                          style: TextStyle(fontSize: 11, color: colors.late),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
