import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../main.dart';
import '../widgets/async_view.dart';

/// The home screen: one big button, and enough context around it that somebody
/// can tell at a glance whether they are clocked in and for how long.
class PunchScreen extends StatefulWidget {
  const PunchScreen({super.key});

  @override
  State<PunchScreen> createState() => _PunchScreenState();
}

class _PunchScreenState extends State<PunchScreen> {
  TodayStatus? _today;
  bool _loading = true;
  bool _punching = false;
  String? _error;

  /// Drives the live "worked so far" figure. The server sends worked_minutes at
  /// the moment of the call; ticking locally keeps the card honest between
  /// refreshes without hammering the endpoint.
  Timer? _ticker;
  DateTime? _loadedAt;

  @override
  void initState() {
    super.initState();
    _load();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && _today?.isClockedIn == true) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
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

  Future<void> _punch() async {
    if (_punching) return;
    setState(() => _punching = true);

    try {
      final api = SessionScope.read(context).api;

      // Location is a record, not a gate — office, remote and hybrid staff all
      // clock in from wherever they are. No location plugin is wired yet, so
      // the punch simply goes without it, which the API explicitly allows.
      final res = await api.post('/attendance/check');
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

  void _showResult(String message, Color color) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: color,
        duration: const Duration(seconds: 3),
      ));
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
              if (_today != null) ...[
                _StatusCard(today: _today!, workedMinutes: _liveWorkedMinutes),
                const SizedBox(height: 20),
                _PunchButton(
                  today: _today!,
                  busy: _punching,
                  onPressed: _today!.canCheck ? _punch : null,
                ),
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
                    color: clockedIn ? AppTheme.present : AppTheme.neutral,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  clockedIn ? 'Clocked in' : 'Not clocked in',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
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
                  Icon(Icons.schedule, size: 16, color: theme.colorScheme.onSurfaceVariant),
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        child: busy
            ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 2.6)
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(clockingIn ? Icons.login : Icons.logout, size: 34),
                  const SizedBox(height: 8),
                  Text(
                    clockingIn ? 'Check in' : 'Check out',
                    style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
                  ),
                  // can_check is false only while the duplicate cooldown runs.
                  // Say why the button is dead rather than letting a tap fail.
                  if (!today.canCheck)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                        'Just a moment — your last punch is still registering',
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w400),
                        textAlign: TextAlign.center,
                      ),
                    ),
                ],
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
        (Icons.celebration_outlined, 'Company holiday — ${today.holiday}', AppTheme.neutral),
      if (today.leave != null)
        (Icons.beach_access_outlined, 'You are on ${today.leave} today', AppTheme.leave),
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
                    child: Text(text, style: TextStyle(color: color, fontSize: 14)),
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
                  leading: Icon(
                    punches[i].isIn ? Icons.login : Icons.logout,
                    color: punches[i].isIn ? AppTheme.present : AppTheme.neutral,
                  ),
                  title: Text(
                    punches[i].isIn ? 'Checked in' : 'Checked out',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: punches[i].office != null ? Text(punches[i].office!) : null,
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        punches[i].time,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (punches[i].status == 'late')
                        const Text('late', style: TextStyle(fontSize: 11, color: AppTheme.late))
                      else if (punches[i].status == 'early_leave')
                        const Text('early', style: TextStyle(fontSize: 11, color: AppTheme.late)),
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
