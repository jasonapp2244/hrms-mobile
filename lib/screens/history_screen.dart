import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../core/offline_cache.dart';
import '../core/tab_visibility.dart';
import '../core/theme.dart';
import '../main.dart';
import '../widgets/async_view.dart';
import 'regularisations_screen.dart';

/// One row per day, newest first — "did I make it in, and when" is a
/// day-shaped question, so the API answers it in days rather than punches.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.visible});

  /// Set by `HomeShell` while this tab is the one on screen.
  final ValueListenable<bool> visible;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> with RefreshOnShow {
  List<HistoryDay> _days = const [];
  HistoryTotals? _totals;
  AttendanceScore? _score;
  bool _loading = true;
  String? _error;

  /// When the rows on screen were saved, or null when they came from the
  /// server just now. Drives the offline banner (B6.3).
  DateTime? _cachedAt;

  /// The API caps the window at 92 days, so these are the only offers.
  int _rangeDays = 30;

  @override
  ValueListenable<bool> get visibility => widget.visible;

  @override
  Future<void> refresh() => _load(silent: true);

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// [silent] leaves the current rows on screen while the new ones are
  /// fetched, for refreshes the user did not explicitly ask for.
  Future<void> _load({bool silent = false}) async {
    setState(() {
      _loading = !silent;
      _error = null;
    });

    try {
      final session = SessionScope.read(context);
      final to = DateTime.now();
      final from = to.subtract(Duration(days: _rangeDays - 1));

      // One saved copy per range: the three offers are three different
      // questions, and the answer to a 92-day window is not the answer to a
      // 7-day one. A copy taken yesterday covers yesterday's window, which is
      // why the banner names the day it was taken.
      final res = await session.cache.fetch(
        session.api,
        '/attendance/history',
        key: OfflineCache.historyKey(_rangeDays),
        query: {'from': _ymd(from), 'to': _ymd(to)},
      );

      if (!mounted) return;
      setState(() {
        _days = ((res.body['days'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(HistoryDay.fromJson)
            .toList();
        _totals = res.body['totals'] is Map<String, dynamic>
            ? HistoryTotals.fromJson(res.body['totals'] as Map<String, dynamic>)
            : null;
        // Absent from a cached copy taken before B3.5 shipped, which is an
        // ordinary state rather than a broken one — the card simply does not
        // appear until the next time the phone has signal.
        _score = res.body['score'] is Map<String, dynamic>
            ? AttendanceScore.fromJson(res.body['score'] as Map<String, dynamic>)
            : null;
        _cachedAt = res.cachedAt;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      // Read here rather than before the request: the first load runs from
      // initState, and reaching for the strings there registers an
      // inherited-widget dependency before the element has finished
      // building, which asserts.
      final t = context.t;
      setState(() {
        _error = e.error == 'forbidden'
            ? t.historyNoEmployeeRecord
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

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    return Scaffold(
      appBar: AppBar(
        title: Text(t.historyTitle),
        actions: [
          // Next to the record it disputes, rather than on a tab of its own.
          // Asking for a correction is rare and only makes sense here.
          IconButton(
            icon: const Icon(Icons.rule),
            tooltip: t.historyCorrections,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const RegularisationsScreen()),
            ),
          ),
          PopupMenuButton<int>(
            initialValue: _rangeDays,
            tooltip: t.historyDateRange,
            icon: const Icon(Icons.tune),
            onSelected: (v) {
              setState(() => _rangeDays = v);
              _load();
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 7, child: Text(t.historyLastDays(7))),
              PopupMenuItem(value: 30, child: Text(t.historyLastDays(30))),
              PopupMenuItem(value: 92, child: Text(t.historyLastDays(92))),
            ],
          ),
        ],
      ),
      body: AsyncView(
        loading: _loading,
        error: _error,
        onRetry: _load,
        child: RefreshIndicator(
          onRefresh: _load,
          child: _days.isEmpty
              ? ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  children: [
                    OfflineBanner(savedAt: _cachedAt, onRetry: _load),
                    const SizedBox(height: 104),
                    EmptyState(
                      icon: Icons.history,
                      title: t.historyEmptyTitle,
                      subtitle: t.historyEmptySubtitle,
                    ),
                  ],
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  children: [
                    OfflineBanner(savedAt: _cachedAt, onRetry: _load),
                    if (_score != null) ...[
                      _ScoreCard(score: _score!),
                      const SizedBox(height: 20),
                    ],
                    if (_totals != null) ...[
                      _TotalsCard(totals: _totals!, rangeDays: _rangeDays),
                      const SizedBox(height: 20),
                    ],
                    Card(
                      child: Column(
                        children: [
                          for (var i = 0; i < _days.length; i++) ...[
                            if (i > 0) const Divider(height: 1),
                            _DayRow(day: _days[i]),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// The score and the streak (B3.5).
///
/// Above the totals rather than below, because it is the answer to the
/// question somebody opens this screen with — the five counts underneath are
/// the working.
///
/// Never a bare number. The line under it says what the number is made of, so
/// that a person who disagrees with it can point at the day they think is
/// wrong and ask for a correction, which is one tap away in the app bar.
class _ScoreCard extends StatelessWidget {
  const _ScoreCard({required this.score});

  final AttendanceScore score;

  /// Green, amber, red — the same three the day rows use, so a colour means
  /// the same thing everywhere on this screen.
  Color _tone(AppColors colors) {
    final value = score.score;
    if (value == null) return colors.neutral;
    if (value >= 90) return colors.present;
    if (value >= 75) return colors.late;
    return colors.absent;
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final t = context.t;
    final tone = _tone(colors);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.historyScoreHeading,
              style: theme.textTheme.labelSmall?.copyWith(
                letterSpacing: 1.1,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            // Wrap rather than Row: at 2x text the score and the streak will
            // not sit side by side. The Wrap alone was not enough — see the
            // Flexible below, which is what the accessibility test actually
            // caught.
            Wrap(
              spacing: 28,
              runSpacing: 16,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      score.hasScore ? '${score.score}%' : t.historyScoreNone,
                      style: (score.hasScore
                              ? theme.textTheme.displaySmall
                              : theme.textTheme.titleMedium)
                          ?.copyWith(
                        color: tone,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      score.hasScore
                          ? t.historyScoreOutOf(score.ontimeDays, score.obligedDays)
                          : t.historyScoreNoneWhy,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.local_fire_department_outlined,
                          size: 18,
                          // Neutral at zero: a flame beside "No streak" reads
                          // as a taunt.
                          color: score.streak > 0 ? colors.accent : colors.neutral,
                        ),
                        const SizedBox(width: 6),
                        // Flexible, not bare: "128 days in a row" at twice the
                        // text size is wider than the card, and a Row does not
                        // wrap for you. This overflowed before the 2x test in
                        // accessibility_test.dart was pointed at this screen.
                        Flexible(
                          child: Text(
                            t.historyStreak(score.streak),
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      t.historyStreakCaption,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.totals, required this.rangeDays});

  final HistoryTotals totals;
  final int rangeDays;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final t = context.t;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.historyRangeHeading(rangeDays),
              style: theme.textTheme.labelSmall?.copyWith(
                letterSpacing: 1.1,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 26,
              runSpacing: 14,
              children: [
                _Stat(
                  label: t.historyStatPresent,
                  value: '${totals.presentDays}',
                  color: colors.present,
                ),
                _Stat(
                  label: t.historyStatLate,
                  value: '${totals.lateDays}',
                  color: colors.late,
                ),
                _Stat(
                  label: t.historyStatLeave,
                  value: '${totals.leaveDays}',
                  color: colors.leave,
                ),
                _Stat(
                  label: t.historyStatAbsent,
                  value: '${totals.absentDays}',
                  color: colors.absent,
                ),
                _Stat(
                  label: t.historyStatWorked,
                  value: Fmt.duration(t, totals.workedMinutes),
                  color: theme.colorScheme.onSurface,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: color,
            letterSpacing: -0.5,
          ),
        ),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _DayRow extends StatelessWidget {
  const _DayRow({required this.day});

  final HistoryDay day;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final t = context.t;
    final (color, label) = colors.statusStyle(t, day.status);

    return ListTile(
      leading: SizedBox(
        width: 46,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              // English on the wire, whoever is reading it.
              Fmt.weekdayNamed(t, day.weekday),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              Fmt.shortDate(t, day.date),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ],
        ),
      ),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (day.late) ...[
            const SizedBox(width: 6),
            Text(
              t.historyLateFlag,
              style: TextStyle(color: colors.late, fontSize: 11.5),
            ),
          ],
        ],
      ),
      subtitle: day.holiday != null
          ? Text(day.holiday!)
          : (day.firstIn != null
                ? Text(
                    t.historyInAt(_clock(day.firstIn!)) +
                        (day.lastOut != null
                            ? t.historyOutAt(_clock(day.lastOut!))
                            : t.historyStillOpen),
                  )
                : null),
      trailing: day.workedMinutes > 0
          ? Text(
              Fmt.duration(t, day.workedMinutes),
              style: const TextStyle(fontWeight: FontWeight.w600),
            )
          : null,
    );
  }

  /// The server sends a full ISO timestamp carrying the company's offset. Take
  /// the clock face off it directly rather than converting — converting would
  /// re-render an employee's office time in whatever zone the handset is in.
  static String _clock(String iso) {
    final time = iso.contains('T') ? iso.split('T')[1] : iso;
    final parts = time.split(':');
    return parts.length >= 2 ? '${parts[0]}:${parts[1]}' : time;
  }
}
