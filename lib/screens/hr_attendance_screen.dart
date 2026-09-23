import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../main.dart';
import '../widgets/async_view.dart';
import '../widgets/day_row.dart';

/// One employee's attendance, day by day, for HR.
///
/// The record screen answers "roughly how is this person doing" with four
/// counts over a fixed month. This answers the question HR actually rings up
/// about — *what happened on the 14th* — and it is the same day row the
/// employee sees on their own History, because a day that reads one way to the
/// person who worked it must read the same to the person asking them about it.
///
/// **No date on this screen is worked out here.** The app sends a period word
/// and reads `from`, `to` and `today` back out of the reply; the range picker
/// is anchored on the server's `today`, not the handset's. A phone is wherever
/// its owner is and attendance is judged in the company's zone, so for part of
/// every day the two disagree about the date — see trap 30, which this codebase
/// has paid for four times.
///
/// Nothing here is cached. The HR area reads live by decision: a register
/// served from disk answers a question about somebody else with facts that were
/// true yesterday, and the person reading it has no way to know.
class HrAttendanceScreen extends StatefulWidget {
  const HrAttendanceScreen({super.key, required this.person});

  /// The row that was tapped, so the screen opens on a name rather than a
  /// spinner — the same reason [HrPersonScreen] takes one.
  final HrEmployeeSummary person;

  @override
  State<HrAttendanceScreen> createState() => _HrAttendanceScreenState();
}

class _HrAttendanceScreenState extends State<HrAttendanceScreen> {
  static const _periods = ['daily', 'weekly', 'monthly', 'custom'];

  HrAttendanceHistory? _data;
  String _period = 'daily';

  /// Only ever sent for `custom`, and only after the picker has run. Every
  /// other period is the server's to resolve.
  String? _from;
  String? _to;

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final api = SessionScope.read(context).api;

      final query = <String, dynamic>{'period': _period};

      if (_period == 'custom' && _from != null && _to != null) {
        query['from'] = _from;
        query['to'] = _to;
      }

      final res = await api.get(
        '/hr/employees/${widget.person.id}/attendance',
        query: query,
      );

      if (!mounted) return;

      setState(() {
        _data = HrAttendanceHistory.fromJson(res);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      // Read here rather than before the request: this runs from initState,
      // where the inherited widget is not ready yet.
      setState(() {
        _error = e.text(context.t);
        _loading = false;
      });
    }
  }

  void _choose(String period) {
    if (period == _period && period != 'custom') return;

    if (period == 'custom') {
      unawaited(_pickRange());
      return;
    }

    setState(() {
      _period = period;
      _from = null;
      _to = null;
    });

    _load();
  }

  /// The range picker, anchored on the company's date.
  ///
  /// `currentDate` is the day Material draws a ring around and it defaults to
  /// `DateTime.now()` — the handset's. `lastDate` is not decoration either: the
  /// server clamps a window to its own today, so a picker offering tomorrow
  /// offers a day the app would then be corrected on.
  ///
  /// `firstDate` is deliberately looser than the server's 92-day ceiling,
  /// because a span is not something a range picker can constrain. Ask for too
  /// much and the server says so in words — which is a better failure than a
  /// picker that silently will not let you reach March.
  Future<void> _pickRange() async {
    final anchor = DateTime.tryParse(_data?.today ?? '');

    // Without a reply there is no company date to anchor on, and the handset's
    // is the one date that must not be used. Nothing to pick from yet.
    if (anchor == null) return;

    final picked = await showDateRangePicker(
      context: context,
      currentDate: anchor,
      firstDate: anchor.subtract(const Duration(days: 365)),
      lastDate: anchor,
      initialDateRange: _from != null && _to != null
          ? DateTimeRange(
              start: DateTime.parse(_from!),
              end: DateTime.parse(_to!),
            )
          : null,
    );

    if (picked == null || !mounted) return;

    setState(() {
      _period = 'custom';
      _from = _ymd(picked.start);
      _to = _ymd(picked.end);
    });

    _load();
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  String _periodLabel(AppLocalizations t, String period) => switch (period) {
        'weekly' => t.hrPeriodWeekly,
        'monthly' => t.hrPeriodMonthly,
        'custom' => t.hrPeriodCustom,
        _ => t.hrPeriodDaily,
      };

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final data = _data;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.person.name),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(46),
          child: SizedBox(
            height: 46,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final period in _periods) ...[
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(_periodLabel(t, period)),
                      selected: _period == period,
                      onSelected: (_) => _choose(period),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      body: AsyncView(
        loading: _loading,
        error: _error,
        onRetry: _load,
        child: data == null
            ? const SizedBox.shrink()
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  children: [
                    _TotalsCard(
                      heading: Fmt.range(t, data.from, data.to).toUpperCase(),
                      totals: data.totals,
                    ),
                    const SizedBox(height: 8),
                    if (data.days.isEmpty)
                      EmptyState(
                        icon: Icons.event_busy_outlined,
                        title: t.hrAttendanceEmpty,
                      )
                    else
                      for (final day in data.days) DayRow(day: day),
                  ],
                ),
              ),
      ),
    );
  }
}

/// The window's totals, in the same five-plus-two shape the employee's own
/// History uses — with the two HR-only numbers beside them.
class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.heading, required this.totals});

  final String heading;
  final HistoryTotals totals;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              heading,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 26,
              runSpacing: 14,
              children: [
                _Stat(label: t.historyStatPresent, value: '${totals.presentDays}'),
                _Stat(label: t.historyStatAbsent, value: '${totals.absentDays}'),
                _Stat(label: t.historyStatLate, value: '${totals.lateDays}'),
                _Stat(label: t.historyStatEarly, value: '${totals.earlyLeaveDays}'),
                _Stat(label: t.historyStatLeave, value: '${totals.leaveDays}'),
                _Stat(
                  label: t.historyStatWorked,
                  value: Fmt.duration(t, totals.workedMinutes),
                ),
                if (totals.breakMinutes != null)
                  _Stat(
                    label: t.historyStatBreak,
                    value: Fmt.duration(t, totals.breakMinutes!),
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
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        ),
      ],
    );
  }
}
