import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/api_client.dart';
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
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('My team'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Approvals'),
              Tab(text: 'In today'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _ApprovalsTab(visible: visible),
            _TeamTab(visible: visible),
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
      setState(() {
        _error = e.displayMessage;
        _loading = false;
      });
    }
  }

  Future<void> _approve(PendingApproval item) async {
    final note = await _askForNote(
      title: 'Approve ${item.employee}?',
      body:
          'This passes the request to HR for the final decision. '
          'Nothing comes off their balance at this step.',
      hint: 'Note for HR (optional)',
      confirmLabel: 'Approve',
      required: false,
    );
    if (note == null || !mounted) return;

    await _act(
      '/leave/approvals/${item.id}/approve',
      body: {if (note.isNotEmpty) 'manager_note': note},
      success: 'Passed to HR.',
    );
  }

  Future<void> _reject(PendingApproval item) async {
    final note = await _askForNote(
      title: 'Reject ${item.employee}?',
      body: '${item.employee} sees the reason you give.',
      hint: 'Reason',
      confirmLabel: 'Reject',
      // The API makes decision_note required on a rejection, so the form does
      // too rather than letting the server bounce it back.
      required: true,
    );
    if (note == null || !mounted) return;

    await _act(
      '/leave/approvals/${item.id}/reject',
      body: {'decision_note': note},
      success: 'Request rejected.',
    );
  }

  Future<void> _act(
    String path, {
    required Map<String, dynamic> body,
    required String success,
  }) async {
    try {
      await SessionScope.read(context).api.post(path, body: body);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(success), backgroundColor: AppTheme.present),
      );
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.displayMessage),
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
                child: const Text('Cancel'),
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
                children: const [
                  SizedBox(height: 100),
                  EmptyState(
                    icon: Icons.inbox_outlined,
                    title: 'Nothing waiting on you',
                    subtitle: 'Requests already passed to HR leave this inbox.',
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
    final theme = Theme.of(context);

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
              '${item.leaveType} · ${Fmt.range(item.startDate, item.endDate)} · ${Fmt.days(item.days)}',
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
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: AppTheme.late.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppTheme.late.withValues(alpha: 0.32),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          size: 17,
                          color: AppTheme.late,
                        ),
                        const SizedBox(width: 7),
                        Text(
                          'Also off then',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: AppTheme.late,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    for (final clash in item.clashes)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '${clash.employee} · ${Fmt.range(clash.startDate, clash.endDate)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: AppTheme.late,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: onReject,
                  style: TextButton.styleFrom(foregroundColor: AppTheme.absent),
                  child: const Text('Reject'),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  onPressed: onApprove,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.present,
                    minimumSize: const Size(110, 42),
                  ),
                  child: const Text('Approve'),
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
      final res = await SessionScope.read(context).api.get('/team/attendance');
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
      setState(() {
        _error = e.displayMessage;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AsyncView(
      loading: _loading,
      error: _error,
      onRetry: _load,
      child: RefreshIndicator(
        onRefresh: _load,
        child: _team.isEmpty
            ? ListView(
                children: const [
                  SizedBox(height: 100),
                  EmptyState(
                    icon: Icons.groups_outlined,
                    title: 'Nobody reports to you',
                    subtitle:
                        'Company-wide attendance lives in the web dashboard.',
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
    );
  }
}

class _TeamSummaryCard extends StatelessWidget {
  const _TeamSummaryCard({required this.summary});

  final TeamSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
                    color: AppTheme.present,
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'on the floor now, of ${summary.total}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
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
                  label: 'Turned up',
                  value: summary.present,
                  color: AppTheme.present,
                ),
                _Pill(label: 'Late', value: summary.late, color: AppTheme.late),
                _Pill(
                  label: 'On leave',
                  value: summary.onLeave,
                  color: AppTheme.leave,
                ),
                _Pill(
                  label: 'Absent',
                  value: summary.absent,
                  color: AppTheme.absent,
                ),
                _Pill(
                  label: 'Off',
                  value: summary.off,
                  color: AppTheme.neutral,
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
    final theme = Theme.of(context);
    final (color, label) = AppTheme.statusStyle(member.status);

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
          if (member.late) 'late',
          if (member.firstIn != null) 'in ${member.firstIn}',
          if (member.lastOut != null) 'out ${member.lastOut}',
        ].join(' · '),
        style: theme.textTheme.bodySmall,
      ),
      trailing: member.isClockedIn
          ? Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: AppTheme.present,
                shape: BoxShape.circle,
              ),
            )
          : (member.workedMinutes > 0
                ? Text(
                    Fmt.duration(member.workedMinutes),
                    style: theme.textTheme.bodySmall,
                  )
                : null),
    );
  }
}
