import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../core/offline_cache.dart';
import '../core/punch_queue.dart';
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
    // The queue is read from disk once, on the first build that has a session
    // to read it with. Anything waiting from a previous launch shows up in the
    // banner immediately rather than at the next tap.
    SessionScope.read(context).queue.load();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// [silent] keeps the current card on screen while the new status is
  /// fetched, for refreshes the user did not explicitly ask for.
  Future<void> _load({bool silent = false}) async {
    setState(() {
      _loading = !silent;
      _error = null;
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
        _error = e.error == 'forbidden'
            ? t.clockNoEmployeeRecord
            : e.text(t);
        _cachedAt = null;
        _loading = false;
      });
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
      final res = await session.api.post(
        '/attendance/check',
        body: await session.locator.punchBody(),
      );
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
        onRetry: _load,
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
                  onPressed: _today!.canCheck ? _punch : null,
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
          backgroundColor: clockingIn ? AppTheme.brand : AppTheme.brandDeep,
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
          foregroundColor: starting ? null : AppTheme.brandDeep,
          side: starting ? null : const BorderSide(color: AppTheme.brandDeep, width: 1.6),
          // The theme's 48 would pin this back under the 56 above.
          minimumSize: const Size.fromHeight(56),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
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
