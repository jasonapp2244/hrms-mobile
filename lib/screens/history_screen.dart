import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../core/tab_visibility.dart';
import '../core/theme.dart';
import '../main.dart';
import '../widgets/async_view.dart';

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
  bool _loading = true;
  String? _error;

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
      final api = SessionScope.read(context).api;
      final to = DateTime.now();
      final from = to.subtract(Duration(days: _rangeDays - 1));

      final res = await api.get(
        '/attendance/history',
        query: {'from': _ymd(from), 'to': _ymd(to)},
      );

      if (!mounted) return;
      setState(() {
        _days = ((res['days'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(HistoryDay.fromJson)
            .toList();
        _totals = res['totals'] is Map<String, dynamic>
            ? HistoryTotals.fromJson(res['totals'] as Map<String, dynamic>)
            : null;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.error == 'forbidden'
            ? 'This account has no employee record, so it has no attendance.'
            : e.displayMessage;
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          PopupMenuButton<int>(
            initialValue: _rangeDays,
            tooltip: 'Date range',
            icon: const Icon(Icons.tune),
            onSelected: (v) {
              setState(() => _rangeDays = v);
              _load();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 7, child: Text('Last 7 days')),
              PopupMenuItem(value: 30, child: Text('Last 30 days')),
              PopupMenuItem(value: 92, child: Text('Last 92 days')),
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
                  children: const [
                    SizedBox(height: 120),
                    EmptyState(
                      icon: Icons.history,
                      title: 'Nothing recorded yet',
                      subtitle:
                          'Your attendance will appear here once you clock in.',
                    ),
                  ],
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  children: [
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

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.totals, required this.rangeDays});

  final HistoryTotals totals;
  final int rangeDays;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'LAST $rangeDays DAYS',
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
                  label: 'Present',
                  value: '${totals.presentDays}',
                  color: AppTheme.present,
                ),
                _Stat(
                  label: 'Late',
                  value: '${totals.lateDays}',
                  color: AppTheme.late,
                ),
                _Stat(
                  label: 'Leave',
                  value: '${totals.leaveDays}',
                  color: AppTheme.leave,
                ),
                _Stat(
                  label: 'Absent',
                  value: '${totals.absentDays}',
                  color: AppTheme.absent,
                ),
                _Stat(
                  label: 'Worked',
                  value: Fmt.duration(totals.workedMinutes),
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
    final theme = Theme.of(context);
    final (color, label) = AppTheme.statusStyle(day.status);

    return ListTile(
      leading: SizedBox(
        width: 46,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              day.weekday,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              Fmt.shortDate(day.date),
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
            const Text(
              'late',
              style: TextStyle(color: AppTheme.late, fontSize: 11.5),
            ),
          ],
        ],
      ),
      subtitle: day.holiday != null
          ? Text(day.holiday!)
          : (day.firstIn != null
                ? Text(
                    'In ${_clock(day.firstIn!)}'
                    '${day.lastOut != null ? ' · Out ${_clock(day.lastOut!)}' : ' · still open'}',
                  )
                : null),
      trailing: day.workedMinutes > 0
          ? Text(
              Fmt.duration(day.workedMinutes),
              style: const TextStyle(fontWeight: FontWeight.w600),
            )
          : null,
    );
  }

  /// The server sends a full ISO timestamp carrying the company's offset. Take
  /// the clock face off it directly rather than converting — converting would
  /// re-render an employee's office time in whatever zone the handset is in.
  static String _clock(String iso) {
    final t = iso.contains('T') ? iso.split('T')[1] : iso;
    final parts = t.split(':');
    return parts.length >= 2 ? '${parts[0]}:${parts[1]}' : t;
  }
}
