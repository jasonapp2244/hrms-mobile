import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../core/tab_visibility.dart';
import '../core/theme.dart';
import '../main.dart';
import '../widgets/async_view.dart';

/// Manager mode. Reachable only when `approve-leave` is present — the shell
/// hides the tab otherwise, and the endpoints behind it are gated *and* scoped
/// to the caller's own direct reports, so the permission alone reaches nobody
/// else's team.
class ApprovalsScreen extends StatelessWidget {
  const ApprovalsScreen({super.key, required this.visible});

  /// Set by `HomeShell` while this tab is the one on screen. Both sub-tabs
  /// watch it: an approval decided on the web should not still be sitting in
  /// the inbox when the manager comes back to this screen.
  final ValueListenable<bool> visible;

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.teamTitle),
          bottom: TabBar(
            tabs: [
              Tab(text: t.teamTabApprovals),
              Tab(text: t.teamTabInToday),
              Tab(text: t.teamTabRoster),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _ApprovalsTab(visible: visible),
            _TeamTab(visible: visible),
            _TeamRosterTab(visible: visible),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Approvals inbox
// ---------------------------------------------------------------------------

class _ApprovalsTab extends StatefulWidget {
  const _ApprovalsTab({required this.visible});

  final ValueListenable<bool> visible;

  @override
  State<_ApprovalsTab> createState() => _ApprovalsTabState();
}

class _ApprovalsTabState extends State<_ApprovalsTab> with RefreshOnShow {
  List<PendingApproval> _pending = const [];
  bool _loading = true;
  String? _error;

  @override
  ValueListenable<bool> get visibility => widget.visible;

  @override
  Future<void> refresh() => _load(silent: true);

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// [silent] leaves the current inbox on screen while it is refetched, for
  /// refreshes the user did not explicitly ask for.
  Future<void> _load({bool silent = false}) async {
    setState(() {
      _loading = !silent;
      _error = null;
    });

    try {
      final res = await SessionScope.read(context).api.get('/leave/approvals');
      if (!mounted) return;
      setState(() {
        _pending = ((res['pending'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(PendingApproval.fromJson)
            .toList();
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
        _error = e.text(t);
        _loading = false;
      });
    }
  }

  Future<void> _approve(PendingApproval item) async {
    final t = context.t;
    final note = await _askForNote(
      title: t.approvalsApproveTitle(item.employee),
      body: t.approvalsApproveBody,
      hint: t.approvalsNoteForHr,
      confirmLabel: t.approvalsApprove,
      required: false,
    );
    if (note == null || !mounted) return;

    await _act(
      '/leave/approvals/${item.id}/approve',
      body: {if (note.isNotEmpty) 'manager_note': note},
      success: t.approvalsPassedToHr,
    );
  }

  Future<void> _reject(PendingApproval item) async {
    final t = context.t;
    final note = await _askForNote(
      title: t.approvalsRejectTitle(item.employee),
      body: t.approvalsRejectBody(item.employee),
      hint: t.approvalsReason,
      confirmLabel: t.approvalsReject,
      // The API makes decision_note required on a rejection, so the form does
      // too rather than letting the server bounce it back.
      required: true,
    );
    if (note == null || !mounted) return;

    await _act(
      '/leave/approvals/${item.id}/reject',
      body: {'decision_note': note},
      success: t.approvalsRejected,
    );
  }

  Future<void> _act(
    String path, {
    required Map<String, dynamic> body,
    required String success,
  }) async {
    // Read before the first await: neither the palette nor the strings can
    // change mid-call, and reaching for a BuildContext after one is the lint
    // this avoids.
    final colors = AppColors.of(context);
    final t = context.t;

    try {
      await SessionScope.read(context).api.post(path, body: body);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(success), backgroundColor: colors.present),
      );
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.text(t)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      // Somebody else may have decided it while this screen was open.
      _load();
    }
  }

  Future<String?> _askForNote({
    required String title,
    required String body,
    required String hint,
    required String confirmLabel,
    required bool required,
  }) {
    final controller = TextEditingController();

    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final valid = !required || controller.text.trim().isNotEmpty;
          return AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(body, style: Theme.of(ctx).textTheme.bodyMedium),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  maxLines: 3,
                  maxLength: 1000,
                  autofocus: required,
                  onChanged: (_) => setLocal(() {}),
                  decoration: InputDecoration(labelText: hint),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(context.t.actionCancel),
              ),
              FilledButton(
                onPressed: valid
                    ? () => Navigator.pop(ctx, controller.text.trim())
                    : null,
                child: Text(confirmLabel),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AsyncView(
      loading: _loading,
      error: _error,
      onRetry: _load,
      child: RefreshIndicator(
        onRefresh: _load,
        child: _pending.isEmpty
            ? ListView(
                children: [
                  const SizedBox(height: 100),
                  EmptyState(
                    icon: Icons.inbox_outlined,
                    title: context.t.approvalsEmptyTitle,
                    subtitle: context.t.approvalsEmptySubtitle,
                  ),
                ],
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  for (final item in _pending) ...[
                    _ApprovalCard(
                      item: item,
                      onApprove: () => _approve(item),
                      onReject: () => _reject(item),
                    ),
                    const SizedBox(height: 12),
                  ],
                ],
              ),
      ),
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({
    required this.item,
    required this.onApprove,
    required this.onReject,
  });

  final PendingApproval item;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final t = context.t;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.employee,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 4),
            Text(
              t.approvalsSummaryLine(
                item.leaveType,
                Fmt.range(t, item.startDate, item.endDate),
                Fmt.days(t, item.days),
              ),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (item.reason != null && item.reason!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(item.reason!, style: theme.textTheme.bodyMedium),
            ],

            // Clashes go *before* the approve button, not after — the whole
            // point is that they inform the decision.
            if (item.clashes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: colors.late.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: colors.late.withValues(alpha: 0.32),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 17,
                          color: colors.late,
                        ),
                        SizedBox(width: 7),
                        Text(
                          t.approvalsClashTitle,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: colors.late,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    for (final clash in item.clashes)
                      Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Text(
                          t.approvalsClashLine(
                            clash.employee,
                            Fmt.range(t, clash.startDate, clash.endDate),
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.late,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],

            SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: onReject,
                  style: TextButton.styleFrom(foregroundColor: colors.absent),
                  child: Text(t.approvalsReject),
                ),
                SizedBox(width: 6),
                FilledButton(
                  onPressed: onApprove,
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.present,
                    minimumSize: const Size(110, 42),
                  ),
                  child: Text(t.approvalsApprove),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Team attendance today
// ---------------------------------------------------------------------------

class _TeamTab extends StatefulWidget {
  const _TeamTab({required this.visible});

  final ValueListenable<bool> visible;

  @override
  State<_TeamTab> createState() => _TeamTabState();
}

class _TeamTabState extends State<_TeamTab> with RefreshOnShow {
  TeamSummary? _summary;
  List<TeamMember> _team = const [];
  bool _loading = true;
  String? _error;

  /// How far back from today, in whole days. Never positive.
  ///
  /// `GET /team/attendance` has accepted a `date` since it shipped and the app
  /// only ever asked for today, so a manager on a handset could not answer
  /// "was she in yesterday?" — the one question that comes up when somebody is
  /// missing this morning. The web manager area has had the same board with a
  /// date on it all along (A10.4).
  int _dayOffset = 0;

  bool get _isToday => _dayOffset == 0;

  DateTime get _date => DateUtils.dateOnly(
        DateTime.now().add(Duration(days: _dayOffset)),
      );

  @override
  ValueListenable<bool> get visibility => widget.visible;

  @override
  Future<void> refresh() => _load(silent: true);

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// [silent] leaves the current board on screen while it is refetched — who
  /// is in today changes through the day, so this tab goes stale fastest.
  Future<void> _load({bool silent = false}) async {
    setState(() {
      _loading = !silent;
      _error = null;
    });

    try {
      // Today is sent explicitly rather than left to the server's default. The
      // two agree, but a handset left open across midnight would otherwise
      // refresh into a different day than the header claims.
      final iso = _date.toIso8601String().substring(0, 10);
      final res = await SessionScope.read(context)
          .api
          .get('/team/attendance?date=$iso');
      if (!mounted) return;
      setState(() {
        _summary = res['summary'] is Map<String, dynamic>
            ? TeamSummary.fromJson(res['summary'] as Map<String, dynamic>)
            : null;
        _team = ((res['team'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(TeamMember.fromJson)
            .toList();
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
        _error = e.text(t);
        _loading = false;
      });
    }
  }

  void _shift(int days) {
    // Never past today: the endpoint refuses a future date, and a control that
    // reliably produces an error is a trap rather than a feature — the same
    // reason the corrections date picker stops here.
    final next = _dayOffset + days;
    if (next > 0) return;

    setState(() => _dayOffset = next);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.t;

    return AsyncView(
      loading: _loading,
      error: _error,
      onRetry: _load,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  onPressed: () => _shift(-1),
                  icon: const Icon(Icons.chevron_left),
                  tooltip: t.teamPreviousDay,
                ),
                Text(
                  switch (_dayOffset) {
                    0 => t.clockToday,
                    -1 => t.teamYesterday,
                    _ => Fmt.longDate(
                        t,
                        _date.toIso8601String().substring(0, 10),
                      ),
                  },
                  style: theme.textTheme.titleSmall,
                ),
                IconButton(
                  // Disabled rather than hidden on today, so the row does not
                  // reflow under the finger as somebody steps back and forth.
                  onPressed: _isToday ? null : () => _shift(1),
                  icon: const Icon(Icons.chevron_right),
                  tooltip: t.teamNextDay,
                ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: _team.isEmpty
                  ? ListView(
                      children: [
                        const SizedBox(height: 100),
                        EmptyState(
                          icon: Icons.groups_outlined,
                          title: context.t.teamEmptyTitle,
                          subtitle: context.t.teamEmptySubtitle,
                        ),
                      ],
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                      children: [
                        if (_summary != null) ...[
                          _TeamSummaryCard(summary: _summary!),
                          const SizedBox(height: 16),
                        ],
                        Card(
                          child: Column(
                            children: [
                              for (var i = 0; i < _team.length; i++) ...[
                                if (i > 0) const Divider(height: 1),
                                _TeamRow(member: _team[i]),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Team roster (B7.3)
// ---------------------------------------------------------------------------

/// The week ahead for each direct report.
///
/// Published days only — the endpoint enforces that, and it matters: telling a
/// manager somebody is on Tuesday when the roster is still a draft is how
/// people get told to come in on a day that then changes.
class _TeamRosterTab extends StatefulWidget {
  const _TeamRosterTab({required this.visible});

  final ValueListenable<bool> visible;

  @override
  State<_TeamRosterTab> createState() => _TeamRosterTabState();
}

class _TeamRosterTabState extends State<_TeamRosterTab> with RefreshOnShow {
  List<TeamRosterMember> _team = const [];
  bool _loading = true;
  String? _error;

  /// How far ahead the window starts, in whole weeks from today.
  int _weekOffset = 0;

  @override
  ValueListenable<bool> get visibility => widget.visible;

  @override
  Future<void> refresh() => _load(silent: true);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool silent = false}) async {
    setState(() {
      _loading = !silent;
      _error = null;
    });

    // Dates are built here rather than sent as an offset: the server takes a
    // concrete day, and a device whose clock is a day out should show its own
    // idea of "this week" rather than silently disagree with the header.
    final start = DateTime.now().add(Duration(days: 7 * _weekOffset));
    final from = '${start.year.toString().padLeft(4, '0')}-'
        '${start.month.toString().padLeft(2, '0')}-'
        '${start.day.toString().padLeft(2, '0')}';

    try {
      final res = await SessionScope.read(context)
          .api
          .get('/team/roster?from=$from&days=7');
      if (!mounted) return;
      setState(() {
        _team = ((res['team'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(TeamRosterMember.fromJson)
            .toList();
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
        _error = e.text(t);
        _loading = false;
      });
    }
  }

  void _shift(int weeks) {
    setState(() => _weekOffset += weeks);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.t;

    return AsyncView(
      loading: _loading,
      error: _error,
      onRetry: _load,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  onPressed: () => _shift(-1),
                  icon: const Icon(Icons.chevron_left),
                  tooltip: t.rosterPreviousWeek,
                ),
                Text(
                  switch (_weekOffset) {
                    0 => t.rosterThisWeek,
                    1 => t.rosterWeekAfter,
                    -1 => t.rosterWeekBefore,
                    final int w when w > 0 => t.rosterWeeksAhead(w),
                    final int w => t.rosterWeeksBack(w.abs()),
                  },
                  style: theme.textTheme.titleSmall,
                ),
                IconButton(
                  onPressed: () => _shift(1),
                  icon: const Icon(Icons.chevron_right),
                  tooltip: t.rosterNextWeek,
                ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: _team.isEmpty
                  ? ListView(
                      children: [
                        const SizedBox(height: 80),
                        EmptyState(
                          icon: Icons.event_busy_outlined,
                          title: t.rosterEmptyTitle,
                          subtitle: t.rosterEmptySubtitle,
                        ),
                      ],
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                      children: [
                        for (final member in _team) ...[
                          _TeamRosterCard(member: member),
                          const SizedBox(height: 12),
                        ],
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TeamRosterCard extends StatelessWidget {
  const _TeamRosterCard({required this.member});

  final TeamRosterMember member;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.t;

    final working = member.schedule.where((d) => d.isWorking).length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    member.name,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  t.rosterDaysOn(working),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const Divider(height: 18),
            for (final day in member.schedule) _TeamRosterDayRow(day: day),
          ],
        ),
      ),
    );
  }
}

class _TeamRosterDayRow extends StatelessWidget {
  const _TeamRosterDayRow({required this.day});

  final TeamRosterDay day;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final t = context.t;
    // Same vocabulary and the same ordering as the employee's own schedule
    // screen: leave and holidays outrank the shift, because they are why
    // nobody is working it.
    final (label, color) = switch (day.status) {
      'leave' => (t.statusOnLeave, colors.leave),
      'holiday' => (day.holiday ?? t.statusHoliday, colors.neutral),
      'day_off' => (t.statusDayOff, colors.neutral),
      'weekend' => (t.statusWeekend, colors.neutral),
      _ => (day.shift?.window ?? t.scheduleNoShift, colors.present),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 58,
            child: Text(
              Fmt.shortDate(t, day.date),
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5),
            ),
          ),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          if (day.isRostered)
            // A day somebody deliberately placed, as opposed to the standing
            // shift filling in. One is a decision, the other a default.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.brandOf(context).withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                t.scheduleRostered,
                style: TextStyle(
                  fontSize: 10,
                  color: colors.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TeamSummaryCard extends StatelessWidget {
  const _TeamSummaryCard({required this.summary});

  final TeamSummary summary;

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
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${summary.inNow}',
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1.5,
                    color: colors.present,
                  ),
                ),
                const SizedBox(width: 8),
                // Expanded, not a bare Text: the label sits beside a 36px
                // number inside an 18px-padded card, which leaves it about
                // 250px on a 390px handset. "of 12 on the floor now" fits;
                // the Spanish reading of it does not, and nor does the English
                // one at any raised font size. Unflexed it overflowed by 34px
                // — a black-and-yellow bar across the manager's first screen.
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      t.teamOnFloorNow(summary.total),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            // in_now is not present: somebody who worked this morning and went
            // home is present for the day but not on the floor. Both numbers
            // are shown because managers ask both questions.
            Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                _Pill(
                  label: t.teamPillTurnedUp,
                  value: summary.present,
                  color: colors.present,
                ),
                _Pill(
                  label: t.teamPillLate,
                  value: summary.late,
                  color: colors.late,
                ),
                _Pill(
                  label: t.teamPillOnLeave,
                  value: summary.onLeave,
                  color: colors.leave,
                ),
                _Pill(
                  label: t.teamPillAbsent,
                  value: summary.absent,
                  color: colors.absent,
                ),
                _Pill(
                  label: t.teamPillOff,
                  value: summary.off,
                  color: colors.neutral,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.value, required this.color});

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$value',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: color,
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

class _TeamRow extends StatelessWidget {
  const _TeamRow({required this.member});

  final TeamMember member;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final t = context.t;
    final (color, label) = colors.statusStyle(t, member.status);

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.15),
        child: Text(
          member.name.isEmpty ? '?' : member.name[0].toUpperCase(),
          style: TextStyle(color: color, fontWeight: FontWeight.w700),
        ),
      ),
      title: Text(
        member.name,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          label,
          if (member.late) t.teamRowLate,
          if (member.firstIn != null) t.teamRowIn(member.firstIn!),
          if (member.lastOut != null) t.teamRowOut(member.lastOut!),
        ].join(' · '),
        style: theme.textTheme.bodySmall,
      ),
      trailing: member.isClockedIn
          ? Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: colors.present,
                shape: BoxShape.circle,
              ),
            )
          : (member.workedMinutes > 0
                ? Text(
                    Fmt.duration(t, member.workedMinutes),
                    style: theme.textTheme.bodySmall,
                  )
                : null),
    );
  }
}
