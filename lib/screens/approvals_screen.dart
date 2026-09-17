import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/downloads.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../core/tab_visibility.dart';
import '../core/theme.dart';
import '../main.dart';
import '../widgets/async_view.dart';
import '../widgets/month_bar.dart';

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
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.teamTitle),
          bottom: TabBar(
            // Four tabs do not fit as equal thirds on a narrow handset, and a
            // label that ellipsises is a label nobody reads.
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: t.teamTabApprovals),
              Tab(text: t.teamTabInToday),
              Tab(text: t.teamTabRoster),
              Tab(text: t.teamTabLeave),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _ApprovalsTab(visible: visible),
            _TeamTab(visible: visible),
            _TeamRosterTab(visible: visible),
            _TeamLeaveTab(visible: visible),
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

  /// The request whose attachment is downloading, so one card spins rather than
  /// the whole inbox going dead (B4.1).
  int? _openingId;

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

  /// Fetch the supporting file and hand it to whatever opens that type (B4.1).
  ///
  /// The endpoint lets this manager through for their own direct reports and
  /// refuses everyone else, so there is nothing to check here that the server
  /// is not already checking.
  Future<void> _openAttachment(PendingApproval item) async {
    // Read before the first await: the palette cannot change mid-call, and
    // reaching for a BuildContext after one is the lint this avoids.
    final colors = AppColors.of(context);
    final t = context.t;

    if (_openingId != null) return;
    setState(() => _openingId = item.id);

    try {
      final opened = await downloadAndOpen(
        SessionScope.read(context).api,
        '/leave/requests/${item.id}/attachment',
        fallbackName: item.attachmentName ?? '',
        id: item.id,
      );

      if (!mounted) return;

      if (opened == OpenedFile.noOpener) {
        _say(t.documentsNoOpener(item.attachmentName ?? ''), colors.late);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      _say(e.text(t), Theme.of(context).colorScheme.error);
    } on FileSystemException {
      if (!mounted) return;
      _say(t.documentsNoRoom, Theme.of(context).colorScheme.error);
    } finally {
      if (mounted) setState(() => _openingId = null);
    }
  }

  void _say(String message, Color colour) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), backgroundColor: colour));
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
                      onOpenAttachment: () => _openAttachment(item),
                      openingAttachment: _openingId == item.id,
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
    required this.onOpenAttachment,
    required this.openingAttachment,
  });

  final PendingApproval item;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  /// B4.1. Downloads the supporting file and hands it to whatever opens that
  /// type — the manager is the one person on the phone who has to read it.
  final VoidCallback onOpenAttachment;
  final bool openingAttachment;

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

            // B4.1. Under the reason because it is what supports it, and above
            // the decision buttons for the same reason the clashes are: a sick
            // note read after approving is a sick note nobody read.
            if (item.attachmentName != null) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: openingAttachment ? null : onOpenAttachment,
                icon: openingAttachment
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    : const Icon(Icons.attach_file, size: 18),
                // Named rather than labelled "attachment": a sick note and a
                // photo of a car park are both files, and only one of them
                // needs opening before deciding.
                label: Text(
                  item.attachmentName!,
                  overflow: TextOverflow.ellipsis,
                ),
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  minimumSize: const Size.fromHeight(44),
                ),
              ),
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

  /// What the **server** calls today, learned from its own reply.
  ///
  /// Not `DateTime.now()`. Attendance is judged in the company's timezone, and
  /// the handset is wherever its owner is: a phone on Asia/Karachi reads 12 Sep
  /// while a New York company is still on the 11th, so asking for the handset's
  /// today asks for a day that has not happened and the board fails with
  /// "That day has not happened yet" — every night, for anybody east of the
  /// office. Null until the first reply lands, which is why the first request
  /// sends no date at all.
  DateTime? _anchor;

  /// The day on screen, or null before the server has said what today is.
  DateTime? get _date => _anchor?.add(Duration(days: _dayOffset));

  /// `yyyy-MM-dd`, the only date shape this endpoint takes.
  static String _isoOf(DateTime date) =>
      date.toIso8601String().substring(0, 10);

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
      // On today, send no date and let the server name the day — it is the one
      // that knows the company's timezone. On any other day, send the date
      // explicitly so a board left open across midnight goes on showing the day
      // its header claims rather than sliding silently onto another one.
      final iso = _isToday ? null : _isoOf(_date!);
      final res = await SessionScope.read(context)
          .api
          .get('/team/attendance${iso == null ? '' : '?date=$iso'}');
      if (!mounted) return;
      setState(() {
        // Re-read on every load of today, so a session left running for days
        // corrects itself rather than anchoring on a date that has gone stale.
        if (_isToday && res['date'] is String) {
          _anchor = DateTime.tryParse(res['date'] as String) ?? _anchor;
        }
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
    // Nothing to count back from until the server has named today. The arrows
    // are only reachable once a board has loaded, so this is belt and braces.
    if (_anchor == null) return;

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
                  switch ((_dayOffset, _date)) {
                    (0, _) => t.clockToday,
                    (-1, _) => t.teamYesterday,
                    // Unreachable: an offset past yesterday can only be reached
                    // through _shift, which refuses to move without an anchor.
                    (_, null) => t.clockToday,
                    (_, final d) => Fmt.longDate(t, _isoOf(d!)),
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

  /// What the **server** last called today, read back out of its own reply.
  ///
  /// Not `DateTime.now()` — see the note in [_load]. Null until the first reply
  /// lands, which is why that one asks for no window at all.
  String? _anchor;

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

    // Neither end of this window comes off the handset's clock. The roster is
    // planned in the company's timezone and the phone is wherever its owner is,
    // so for part of every day the two disagree about the date — and this
    // endpoint takes whatever `from` it is given rather than refusing one, so a
    // phone already on tomorrow was quietly shown Tuesday-to-Monday under a
    // heading that said "This week". Nothing errored; the heading simply lied.
    //
    // So on this week no `from` is sent at all: the server's default is the
    // company's today, which is the only correct answer, and its echo is what
    // [_anchor] is learned from. Every other week counts from that anchor —
    // and because this week always re-asks, a session left open across midnight
    // corrects itself the moment the manager comes back to it rather than
    // drifting a day further out each time.
    final anchor = _anchor;
    final from = _weekOffset == 0 || anchor == null
        ? null
        : _shiftDays(anchor, 7 * _weekOffset);

    try {
      final res = await SessionScope.read(context)
          .api
          .get('/team/roster?days=7${from == null ? '' : '&from=$from'}');
      if (!mounted) return;
      setState(() {
        // The server names the window it used. On this week that start *is*
        // the company's today; on any other it is a day this screen already
        // chose, so re-reading it then would teach the anchor nothing and
        // walk it forwards every time an arrow was pressed.
        if (_weekOffset == 0 && res['from'] is String) {
          _anchor = res['from'] as String;
        }
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
    // Nothing has been learned from the server yet, so there is no day to
    // count from. The arrows are disabled in that state; this is the belt to
    // that's braces.
    if (_anchor == null) return;

    setState(() => _weekOffset += weeks);
    _load();
  }

  /// `2026-08-30` + 7 → `2026-09-06`. `DateTime` does the carrying across
  /// month and year ends, and the date is read as a plain calendar day — these
  /// strings hold no timezone and giving them one would shift the day.
  static String _shiftDays(String ymd, int days) {
    final parsed = DateTime.tryParse(ymd);

    if (parsed == null) return ymd;

    final moved = DateTime(parsed.year, parsed.month, parsed.day + days);

    return '${moved.year.toString().padLeft(4, '0')}-'
        '${moved.month.toString().padLeft(2, '0')}-'
        '${moved.day.toString().padLeft(2, '0')}';
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
                  // Dead until the server has said what day it is. A control
                  // that would send a week counted from nothing is worse than
                  // one that is plainly not ready yet.
                  onPressed: _anchor == null ? null : () => _shift(-1),
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
                  onPressed: _anchor == null ? null : () => _shift(1),
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

// ---------------------------------------------------------------------------
// Team leave calendar (B4.6)
// ---------------------------------------------------------------------------

/// Who on the team is off, a month at a time.
///
/// **Date-major, unlike the roster tab beside it.** That one is read down a
/// person to see their week; this one answers "can I let a second person go
/// that week", which is a question about a day.
///
/// **The month is never built from `DateTime.now()`.** Leave is judged in the
/// company's timezone and the phone is wherever its owner is, so for part of
/// every day the two disagree about the date — and on the 1st or the 31st they
/// disagree about the *month*, which would open this screen on the wrong grid
/// with nothing to say it had. The first load asks for no month at all, reads
/// the answer out of the reply, and the arrows count from there.
class _TeamLeaveTab extends StatefulWidget {
  const _TeamLeaveTab({required this.visible});

  final ValueListenable<bool> visible;

  @override
  State<_TeamLeaveTab> createState() => _TeamLeaveTabState();
}

class _TeamLeaveTabState extends State<_TeamLeaveTab> with RefreshOnShow {
  TeamLeaveMonth? _month;
  bool _loading = true;
  String? _error;

  /// `YYYY-MM`, learned from the server's own reply and then moved by the
  /// arrows. Null until the first one lands.
  String? _anchor;

  /// The date whose people are listed under the grid.
  String? _selected;

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

    final anchor = _anchor;

    try {
      final res = await SessionScope.read(context)
          .api
          .get('/team/leave-calendar${anchor == null ? '' : '?month=$anchor'}');

      if (!mounted) return;

      final month = TeamLeaveMonth.fromJson(res);

      setState(() {
        _month = month;
        // The server names the month it actually answered for, which is the
        // only trustworthy statement of what "this month" means here.
        _anchor = month.month;
        _selected = _openOn(month);
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

  /// Which cell to open on.
  ///
  /// A day the manager had already picked wins, so a background refresh does
  /// not move the list out from under them. Otherwise today, and failing that
  /// the first day somebody is off — landing on an empty 1st when the leave is
  /// all in the third week makes the screen look broken.
  String? _openOn(TeamLeaveMonth month) {
    final held = _selected;

    if (held != null && month.days.any((d) => d.date == held)) {
      return held;
    }

    if (month.days.any((d) => d.date == month.today)) {
      return month.today;
    }

    for (final day in month.days) {
      if (day.people.isNotEmpty) return day.date;
    }

    return month.days.isEmpty ? null : month.days.first.date;
  }

  void _step(int months) {
    final anchor = _anchor;

    // Nothing has been learned yet, so there is nothing to count from. The
    // arrows are disabled in that state; this is the belt to that's braces.
    if (anchor == null) return;

    setState(() {
      _anchor = MonthBar.shiftMonth(anchor, months);
      // A different month holds no selection — _openOn picks a new one.
      _selected = null;
    });

    _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final month = _month;

    return AsyncView(
      loading: _loading,
      error: _error,
      onRetry: _load,
      child: month == null
          ? const SizedBox.shrink()
          : Column(
              children: [
                MonthBar(
                  label: MonthBar.monthLabel(t, month.month),
                  // Both arrows live, unlike the attendance board's forward
                  // one: leave is booked ahead, so next month is the most
                  // useful month this can answer for.
                  onBack: _anchor == null ? null : () => _step(-1),
                  onForward: _anchor == null ? null : () => _step(1),
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _load,
                    child: month.teamSize == 0
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
                            padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
                            children: [
                              _LeaveMonthGrid(
                                days: month.days,
                                today: month.today,
                                selected: _selected,
                                onTap: (date) => setState(() => _selected = date),
                              ),
                              const SizedBox(height: 16),
                              ..._dayDetail(context, month),
                            ],
                          ),
                  ),
                ),
              ],
            ),
    );
  }

  /// The selected day, spelled out under the grid.
  List<Widget> _dayDetail(BuildContext context, TeamLeaveMonth month) {
    final t = context.t;
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final selected = _selected;

    if (selected == null) return const [];

    final day = month.days.where((d) => d.date == selected).firstOrNull;

    if (day == null) return const [];

    return [
      Row(
        children: [
          Expanded(
            child: Text(
              Fmt.longDate(t, day.date),
              style: theme.textTheme.titleSmall,
            ),
          ),
          Text(
            day.people.isEmpty
                ? t.leaveCalendarNobodyOff
                : t.leaveCalendarPeopleOff(day.people.length),
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      if (day.holiday case final String holiday) ...[
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(Icons.celebration_outlined, size: 16, color: colors.neutral),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                holiday,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.neutral),
              ),
            ),
          ],
        ),
      ],
      const SizedBox(height: 8),
      if (day.people.isEmpty && month.isQuiet)
        EmptyState(
          icon: Icons.beach_access_outlined,
          title: t.leaveCalendarQuietTitle,
          subtitle: t.leaveCalendarQuietSubtitle,
        )
      else
        Card(
          child: Column(
            children: [
              for (var i = 0; i < day.people.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _LeavePersonRow(person: day.people[i]),
              ],
            ],
          ),
        ),
    ];
  }
}

/// The month grid itself.
///
/// **Weeks start on Monday, and that is a layout choice rather than a claim
/// about the working week.** Which days are a weekend is the company's setting
/// and arrives per-day on each cell, so a company that works Sunday to Thursday
/// gets its own days shaded correctly however the rows happen to break.
class _LeaveMonthGrid extends StatelessWidget {
  const _LeaveMonthGrid({
    required this.days,
    required this.today,
    required this.selected,
    required this.onTap,
  });

  final List<TeamLeaveDay> days;
  final String today;
  final String? selected;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);

    if (days.isEmpty) return const SizedBox.shrink();

    final first = DateTime.tryParse(days.first.date);
    final blanks = first == null ? 0 : first.weekday - DateTime.monday;

    final cells = <Widget>[
      for (var i = 0; i < blanks; i++) const SizedBox.shrink(),
      for (final day in days)
        _LeaveCell(
          day: day,
          isToday: day.date == today,
          isSelected: day.date == selected,
          onTap: () => onTap(day.date),
        ),
    ];

    final rows = <Widget>[];

    for (var i = 0; i < cells.length; i += 7) {
      rows.add(Row(
        children: [
          for (var c = 0; c < 7; c++)
            Expanded(
              child: i + c < cells.length ? cells[i + c] : const SizedBox.shrink(),
            ),
        ],
      ));
    }

    return Column(
      children: [
        Row(
          children: [
            for (var weekday = DateTime.monday; weekday <= DateTime.sunday; weekday++)
              Expanded(
                child: Center(
                  child: Text(
                    Fmt.weekdayShort(t, weekday),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        ...rows,
      ],
    );
  }
}

/// One day of the month.
///
/// The count sits **inside** the cell rather than under it: a dot alone says
/// somebody is off and a manager then has to tap every cell to find out how
/// many, which is the whole question.
class _LeaveCell extends StatelessWidget {
  const _LeaveCell({
    required this.day,
    required this.isToday,
    required this.isSelected,
    required this.onTap,
  });

  final TeamLeaveDay day;
  final bool isToday;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final t = context.t;

    final off = day.people.length;

    // Amber the moment anything on the day is unsettled: the manager's question
    // is whether the day is already spoken for, and a pending request is
    // exactly the one they are about to decide.
    final tone = day.people.any((p) => p.isPending) ? colors.late : colors.leave;

    final muted = day.isWeekend || day.holiday != null;

    return Semantics(
      selected: isSelected,
      label: '${Fmt.shortDate(t, day.date)}, '
          '${off == 0 ? t.leaveCalendarNobodyOff : t.leaveCalendarPeopleOff(off)}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AspectRatio(
          aspectRatio: 1,
          child: Container(
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              // The same neutral darkening the attendance grid uses, for the
              // same reason and so that the two calendars in this app agree
              // about what "picked" looks like. Accent is in the leave family
              // here, and a selected day tinted with it reads as a day off.
              color: isSelected
                  ? theme.colorScheme.onSurface.withValues(alpha: 0.12)
                  : (muted ? theme.colorScheme.surfaceContainerHighest : null),
              borderRadius: BorderRadius.circular(8),
              border: isToday
                  ? Border.all(color: colors.accent, width: 1.5)
                  : null,
            ),
            // Scaled down rather than clipped: at 2× text this cell is still a
            // square seventh of the width, and an overflowing calendar is a
            // calendar with days missing off the bottom.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${day.dayOfMonth}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
                        color: muted
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    SizedBox(
                      height: 16,
                      child: off == 0
                          ? null
                          : Container(
                              alignment: Alignment.center,
                              constraints: const BoxConstraints(minWidth: 16),
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              decoration: BoxDecoration(
                                color: tone.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '$off',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: tone,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One person on the selected day.
class _LeavePersonRow extends StatelessWidget {
  const _LeavePersonRow({required this.person});

  final TeamLeavePerson person;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final t = context.t;

    final tone = person.isPending ? colors.late : colors.leave;

    // The whole stretch, which is why the day it falls on is not printed here:
    // "29 Jul – 3 Aug" is what tells a manager this began before the month did.
    final dates = person.isSingleDay
        ? Fmt.longDate(t, person.startDate)
        : t.dateRange(
            Fmt.shortDate(t, person.startDate),
            Fmt.shortDate(t, person.endDate),
          );

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: tone.withValues(alpha: 0.15),
        child: Icon(Icons.beach_access_outlined, size: 18, color: tone),
      ),
      title: Text(person.name),
      subtitle: Text(
        [
          if (person.leaveType case final String type) type,
          dates,
          if (person.isHalfDay) t.leaveCalendarHalfDay,
        ].join(' · '),
      ),
      trailing: person.isPending
          ? Chip(
              label: Text(t.leaveCalendarPending),
              labelStyle: theme.textTheme.labelSmall?.copyWith(color: colors.late),
              backgroundColor: colors.late.withValues(alpha: 0.15),
              side: BorderSide.none,
              visualDensity: VisualDensity.compact,
            )
          : null,
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
