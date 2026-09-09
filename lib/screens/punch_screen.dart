import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../core/punch_queue.dart';
import '../core/tab_visibility.dart';
import '../core/theme.dart';
import '../main.dart';
import '../widgets/async_view.dart';

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
      final api = SessionScope.read(context).api;
      final res = await api.get('/attendance/today');
      if (!mounted) return;
      setState(() {
        _today = TodayStatus.fromJson(res);
        _loadedAt = DateTime.now();
        _loading = false;
      });

      // Reaching the server is the only proof there is a connection, and this
      // call just did. Drain anything waiting — but not from inside a drain,
      // which _drainQueue guards against.
      unawaited(_drainQueue(announce: true));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.error == 'forbidden'
            ? 'This account has no employee record, so there is nothing to clock.'
            : e.displayMessage;
        _loading = false;
      });
    }
  }

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
    final session = SessionScope.read(context);

    if (session.queue.count.value == 0) return;

    final outcome = await session.queue.flush(session.api);

    if (!mounted) return;

    // A refusal is the one outcome the person has to read: it will not come
    // back on a retry, and it means a punch they made is not on their record.
    if (outcome.refusals.isNotEmpty) {
      _showResult(outcome.refusals.first, Theme.of(context).colorScheme.error);
    } else if (announce && outcome.changedAnything) {
      _showResult(
        outcome.accepted == 1
            ? 'Your offline punch has been recorded.'
            : '${outcome.accepted + outcome.duplicate} offline punches recorded.',
        AppTheme.present,
      );
    }

    if (outcome.changedAnything) await _load(silent: true);
  }

  Future<void> _punch() async {
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
        punch.status == 'late' ? AppTheme.late : AppTheme.present,
      );
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;

      if (e.isDuplicateScan) {
        // Reads as success to the person holding the phone: the punch they
        // wanted is already on record, they just tapped twice.
        _showResult('That punch is already recorded.', AppTheme.neutral);
        await _load();
      } else if (e.isNetworkFailure) {
        // The whole point of B2.4. The tap is kept at the moment it was made,
        // and delivered when there is something to deliver it over — rather
        // than lost, or silently recorded hours later at the wrong time.
        await _queuePunch();
      } else {
        _showResult(
          e.error == 'no_office'
              ? 'No office is set up yet. HR needs to add one before you can clock in.'
              : e.displayMessage,
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
    final session = SessionScope.read(context);
    final body = await session.locator.punchBody();

    await session.queue.add(QueuedPunch(
      occurredAt: DateTime.now().toUtc().toIso8601String(),
      intendedType: _today?.willClockIn == true ? 'in' : 'out',
      latitude: (body['latitude'] as num?)?.toDouble(),
      longitude: (body['longitude'] as num?)?.toDouble(),
    ));

    if (!mounted) return;

    _showResult(
      'No connection — saved. It will be recorded at the time you tapped, '
      'once you are back online.',
      AppTheme.late,
    );
  }

  /// Start or end a break (B2.6).
  ///
  /// A separate endpoint from the punch, and separate state here, because the
  /// two refuse for different reasons: a break is refused when the day is not
  /// in a state for one, a punch never is. `break_not_available` means the
  /// screen is out of date, so it reloads rather than blaming the person.
  Future<void> _break() async {
    if (_breaking) return;
    setState(() => _breaking = true);

    try {
      final session = SessionScope.read(context);

      final res = await session.api.post(
        '/attendance/break',
        body: await session.locator.punchBody(),
      );

      if (!mounted) return;
      _showResult('${res['message']}', AppTheme.neutral);
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;

      if (e.isDuplicateScan) {
        _showResult('That is already recorded.', AppTheme.neutral);
        await _load();
      } else if (e.error == 'break_not_available') {
        // The day moved on under the screen — clocked out on another device,
        // most likely. Refreshing answers it better than any message would.
        _showResult(e.displayMessage, AppTheme.late);
        await _load();
      } else {
        _showResult(e.displayMessage, Theme.of(context).colorScheme.error);
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
    final user = SessionScope.of(context).user;

    return Scaffold(
      appBar: AppBar(
        title: Text(user?.employee?.fullName ?? user?.name ?? 'Today'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
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

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.today, required this.workedMinutes});

  final TodayStatus today;
  final int workedMinutes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                        ? AppTheme.late
                        : (clockedIn ? AppTheme.present : AppTheme.neutral),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  // On a break is a third state, not a fourth word for clocked
                  // out. The clock is still running on the day; it is the paid
                  // total below that has paused.
                  today.onBreak
                      ? 'On a break'
                      : (clockedIn ? 'Clocked in' : 'Not clocked in'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  Fmt.shortDate(today.date),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  Fmt.duration(workedMinutes),
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1.5,
                    fontFeatures: const [],
                  ),
                ),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'worked today',
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
                      '${today.shift!.name} · ${today.shift!.window}',
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

    return SizedBox(
      height: 120,
      child: FilledButton(
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(
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
                    clockingIn ? 'Check in' : 'Check out',
                    style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  // can_check is false only while the duplicate cooldown runs.
                  // Say why the button is dead rather than letting a tap fail.
                  if (!today.canCheck)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                        'Just a moment — your last punch is still registering',
                        style: TextStyle(
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
    return ValueListenableBuilder<int>(
      valueListenable: queue.count,
      builder: (context, waiting, _) {
        if (waiting == 0) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            decoration: BoxDecoration(
              color: AppTheme.late.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.late.withValues(alpha: 0.32)),
            ),
            child: Row(
              children: [
                const Icon(Icons.cloud_off, color: AppTheme.late, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    waiting == 1
                        ? '1 punch waiting to send. It will be recorded at the '
                            'time you tapped.'
                        : '$waiting punches waiting to send. They will be '
                            'recorded at the times you tapped.',
                    style: const TextStyle(color: AppTheme.late, fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(foregroundColor: AppTheme.late),
                  child: const Text('Retry'),
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

    return SizedBox(
      height: 56,
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
          starting ? 'Start break' : 'End break',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        style: OutlinedButton.styleFrom(
          // On a break the control that ends it is the live one, so it gets the
          // colour. Starting one is unremarkable and stays quiet.
          foregroundColor: starting ? null : AppTheme.brandDeep,
          side: starting ? null : const BorderSide(color: AppTheme.brandDeep, width: 1.6),
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
    final notes = <(IconData, String, Color)>[
      if (today.holiday != null)
        (
          Icons.celebration_outlined,
          'Company holiday — ${today.holiday}',
          AppTheme.neutral,
        ),
      if (today.leave != null)
        (
          Icons.beach_access_outlined,
          'You are on ${today.leave} today',
          AppTheme.leave,
        ),
      if (today.isDayOff)
        (Icons.weekend_outlined, 'Rostered off today', AppTheme.neutral),
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
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "TODAY'S PUNCHES",
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
                        ? AppTheme.late
                        : (punches[i].isIn ? AppTheme.present : AppTheme.neutral),
                  ),
                  title: Text(
                    punches[i].label,
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
                        const Text(
                          'late',
                          style: TextStyle(fontSize: 11, color: AppTheme.late),
                        )
                      else if (punches[i].status == 'early_leave')
                        const Text(
                          'early',
                          style: TextStyle(fontSize: 11, color: AppTheme.late),
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
