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
import 'hr_person_screen.dart';

/// HR mode (client requirement, 2026-09-22).
///
/// **Not a copy of the Team tab.** The manager's inbox is the *first* step of
/// the approval chain — it passes a request up and spends nothing. This is the
/// step that commits the days, which is why every card here carries a balance
/// and the manager's own note: HR decides on somebody a manager has already
/// seconded, and needs both to do it responsibly.
///
/// Which tabs appear is the server's answer, not this file's. `decidesLeave`
/// and `viewsEmployees` come from the `can` block on `/auth/me`, because the
/// same rule used to live in Dart and in the route table and the two were free
/// to drift. A build that cannot ask shows nothing rather than guessing.
class HrScreen extends StatelessWidget {
  const HrScreen({super.key, required this.visible});

  /// Set by `HomeShell` while this tab is on screen. Both sub-tabs watch it: a
  /// request decided on the web should not still be sitting in the queue when
  /// HR comes back to this screen.
  final ValueListenable<bool> visible;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final user = SessionScope.of(context).user;

    final tabs = <({String label, Widget view})>[
      if (user?.decidesLeave == true)
        (label: t.hrTabApprovals, view: _ApprovalsTab(visible: visible)),
      if (user?.viewsEmployees == true)
        (label: t.hrTabPeople, view: _PeopleTab(visible: visible)),
    ];

    // Neither capability granted. The shell does not draw the tab in that
    // case, so this is the belt to its braces — a session refreshed into
    // fewer permissions while the tab was open lands here rather than on a
    // TabController built for zero children, which throws.
    if (tabs.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(t.hrTitle)),
        body: EmptyState(
          icon: Icons.lock_outline,
          title: t.hrApprovalsEmptyTitle,
          subtitle: t.hrPersonReadOnly,
        ),
      );
    }

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.hrTitle),
          bottom: tabs.length > 1
              ? TabBar(tabs: [for (final tab in tabs) Tab(text: tab.label)])
              : null,
        ),
        body: TabBarView(children: [for (final tab in tabs) tab.view]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The leave desk
// ---------------------------------------------------------------------------

class _ApprovalsTab extends StatefulWidget {
  const _ApprovalsTab({required this.visible});

  final ValueListenable<bool> visible;

  @override
  State<_ApprovalsTab> createState() => _ApprovalsTabState();
}

class _ApprovalsTabState extends State<_ApprovalsTab> with RefreshOnShow {
  List<HrPendingLeave> _pending = const [];
  List<HrDecidedLeave> _decided = const [];
  bool _loading = true;
  String? _error;

  /// The request whose attachment is downloading, so one card spins rather
  /// than the whole queue going dead.
  int? _openingId;

  /// The request currently being decided. A second tap on a card whose POST is
  /// still in flight would spend the balance twice — the server refuses the
  /// duplicate, but the button should not offer it in the first place.
  int? _decidingId;

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

    try {
      final api = SessionScope.read(context).api;
      final queue = await api.get('/hr/leave/approvals');
      final decided = await api.get('/hr/leave/decided');

      if (!mounted) return;

      setState(() {
        _pending = ((queue['pending'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(HrPendingLeave.fromJson)
            .toList();
        _decided = ((decided['requests'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(HrDecidedLeave.fromJson)
            .take(10)
            .toList();
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      // Read here rather than before the request: the first load runs from
      // initState, and reaching for the strings there registers an
      // inherited-widget dependency before the element has finished building.
      final t = context.t;
      setState(() {
        _error = e.text(t);
        _loading = false;
      });
    }
  }

  Future<void> _openAttachment(HrPendingLeave item) async {
    final colors = AppColors.of(context);
    final t = context.t;

    if (_openingId != null) return;
    setState(() => _openingId = item.id);

    try {
      final opened = await downloadAndOpen(
        SessionScope.read(context).api,
        '/hr/leave/${item.id}/attachment',
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

  Future<void> _approve(HrPendingLeave item) async {
    final t = context.t;

    final note = await _askForNote(
      title: t.hrApprovalsApproveTitle(item.employee),
      body: t.hrApprovalsApproveBody,
      hint: t.hrApprovalsNote,
      confirmLabel: t.hrApprovalsApprove,
      required: false,
    );
    if (note == null || !mounted) return;

    await _decide(
      item,
      '/hr/leave/${item.id}/approve',
      body: {if (note.isNotEmpty) 'decision_note': note},
      success: t.hrApprovalsApproved,
    );
  }

  Future<void> _reject(HrPendingLeave item) async {
    final t = context.t;

    final note = await _askForNote(
      title: t.hrApprovalsRejectTitle(item.employee),
      body: t.hrApprovalsRejectBody(item.employee),
      hint: t.hrApprovalsReason,
      confirmLabel: t.hrApprovalsReject,
      // The API makes decision_note required on a rejection, so the form does
      // too rather than letting the server bounce it back. The employee reads
      // this, and a refusal with no words is the one outcome somebody always
      // comes back to ask about.
      required: true,
    );
    if (note == null || !mounted) return;

    await _decide(
      item,
      '/hr/leave/${item.id}/reject',
      body: {'decision_note': note},
      success: t.hrApprovalsRejected,
    );
  }

  /// Send the decision.
  ///
  /// **Never queued.** A punch taken with no signal is held and synced later,
  /// because the punch already happened and the clock is the record. A decision
  /// has not happened until the server says so, and one replayed from a queue
  /// would spend the balance twice. So this fails with a message and the
  /// request stays in the queue for another try.
  Future<void> _decide(
    HrPendingLeave item,
    String path, {
    required Map<String, dynamic> body,
    required String success,
  }) async {
    final colors = AppColors.of(context);
    final t = context.t;

    if (_decidingId != null) return;
    setState(() => _decidingId = item.id);

    try {
      await SessionScope.read(context).api.post(path, body: body);
      if (!mounted) return;
      _say(success, colors.present);
      await _load(silent: true);
    } on ApiException catch (e) {
      if (!mounted) return;
      // The server's own words. An over-spent balance and an already-decided
      // request are different problems and the app cannot tell them apart from
      // the outside, so it shows what it was told rather than guessing.
      _say(e.text(t), Theme.of(context).colorScheme.error);
    } finally {
      if (mounted) setState(() => _decidingId = null);
    }
  }

  Future<String?> _askForNote({
    required String title,
    required String body,
    required String hint,
    required String confirmLabel,
    required bool required,
  }) async {
    final controller = TextEditingController();
    final t = context.t;

    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        String? error;

        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(body),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  maxLines: 3,
                  maxLength: 1000,
                  decoration: InputDecoration(
                    labelText: hint,
                    errorText: error,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(t.actionCancel),
              ),
              FilledButton(
                onPressed: () {
                  final text = controller.text.trim();
                  if (required && text.isEmpty) {
                    setDialogState(() => error = t.hrApprovalsReason);
                    return;
                  }
                  Navigator.of(context).pop(text);
                },
                child: Text(confirmLabel),
              ),
            ],
          ),
        );
      },
    );

    controller.dispose();

    return result;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    return AsyncView(
      loading: _loading,
      error: _error,
      onRetry: _load,
      child: RefreshIndicator(
        onRefresh: () => _load(silent: true),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_pending.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: EmptyState(
                  icon: Icons.inbox_outlined,
                  title: t.hrApprovalsEmptyTitle,
                  subtitle: t.hrApprovalsEmptyBody,
                ),
              )
            else
              for (final item in _pending)
                _PendingCard(
                  item: item,
                  busy: _decidingId == item.id,
                  opening: _openingId == item.id,
                  onApprove: () => _approve(item),
                  onReject: () => _reject(item),
                  onOpenAttachment: () => _openAttachment(item),
                ),
            if (_decided.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text(
                t.hrDecidedTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              for (final item in _decided) _DecidedRow(item: item),
            ],
          ],
        ),
      ),
    );
  }
}

/// One request waiting on HR.
class _PendingCard extends StatelessWidget {
  const _PendingCard({
    required this.item,
    required this.busy,
    required this.opening,
    required this.onApprove,
    required this.onReject,
    required this.onOpenAttachment,
  });

  final HrPendingLeave item;
  final bool busy;
  final bool opening;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onOpenAttachment;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final balance = item.balance;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.employee, style: theme.textTheme.titleMedium),
            if (item.department != null)
              Text(
                item.department!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.hintColor),
              ),
            const SizedBox(height: 8),
            Text(
              '${item.leaveType} · ${Fmt.range(t, item.startDate, item.endDate)} · '
              '${Fmt.days(t, item.days)}',
              style: theme.textTheme.bodyMedium,
            ),
            if (item.reason != null) ...[
              const SizedBox(height: 6),
              Text(item.reason!, style: theme.textTheme.bodySmall),
            ],

            // The manager step. Absent is an answer too — an employee who
            // reports to nobody skips it by design rather than by oversight.
            const SizedBox(height: 8),
            Text(
              item.managerApprovedBy != null
                  ? t.hrApprovalsSeconded(item.managerApprovedBy!)
                  : t.hrApprovalsNoManagerStep,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            if (item.managerNote != null)
              Text(
                item.managerNote!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontStyle: FontStyle.italic),
              ),

            // The number that decides the answer.
            if (balance != null) ...[
              const SizedBox(height: 10),
              Text(
                balance.capped
                    ? t.hrApprovalsBalance(
                        _number(balance.available),
                        _number(balance.entitled),
                      )
                    : t.hrApprovalsBalanceUncapped(_number(balance.used)),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: balance.wouldExceed ? colors.late : null,
                ),
              ),
              if (balance.wouldExceed)
                Text(
                  t.hrApprovalsWouldExceed,
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.late),
                ),
            ],

            if (item.clashes.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                t.hrApprovalsClash(item.clashes.length),
                style: theme.textTheme.bodySmall?.copyWith(color: colors.late),
              ),
            ],

            if (item.attachmentName != null) ...[
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: opening ? null : onOpenAttachment,
                icon: opening
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.attach_file, size: 18),
                label: Text(item.attachmentName!),
              ),
            ],

            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: busy ? null : onReject,
                  style: TextButton.styleFrom(foregroundColor: colors.absent),
                  child: Text(t.hrApprovalsReject),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: busy ? null : onApprove,
                  // `minimumSize` is overridden because the app theme sets
                  // `Size.fromHeight(50)` on every filled button — a width of
                  // **infinity**, which is what makes them full-width in a
                  // column. Inside a Row the main axis is unbounded, so that
                  // minimum becomes a tight infinite width and the layout
                  // throws rather than overflowing. The manager's card does
                  // the same thing a few files over, for the same reason.
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.present,
                    minimumSize: const Size(110, 42),
                  ),
                  child: Text(t.hrApprovalsApprove),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DecidedRow extends StatelessWidget {
  const _DecidedRow({required this.item});

  final HrDecidedLeave item;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final colors = AppColors.of(context);
    final approved = item.status == 'approved';

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        approved ? Icons.check_circle_outline : Icons.cancel_outlined,
        color: approved ? colors.present : colors.late,
      ),
      title: Text('${item.employee} · ${item.leaveType}'),
      subtitle: Text(
        '${Fmt.range(t, item.startDate, item.endDate)}'
        '${item.decidedBy != null ? ' · ${t.hrDecidedBy(item.decidedBy!)}' : ''}',
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The employee register
// ---------------------------------------------------------------------------

class _PeopleTab extends StatefulWidget {
  const _PeopleTab({required this.visible});

  final ValueListenable<bool> visible;

  @override
  State<_PeopleTab> createState() => _PeopleTabState();
}

class _PeopleTabState extends State<_PeopleTab> with RefreshOnShow {
  final _search = TextEditingController();

  List<HrEmployeeSummary> _people = const [];
  bool _loading = true;
  bool _includeLeavers = false;
  String? _error;

  /// Which window the attendance line under each name covers.
  ///
  /// A word, not a pair of dates — the server resolves it in the company's
  /// zone and reports what it used. [_from], [_to] and [_today] are read back
  /// out of the reply and never worked out here; the handset's own date is a
  /// different date from the employer's for part of every day.
  String _period = 'daily';
  String? _from;
  String? _to;
  String? _today;

  @override
  ValueListenable<bool> get visibility => widget.visible;

  @override
  Future<void> refresh() => _load(silent: true);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    setState(() {
      _loading = !silent;
      _error = null;
    });

    final query = <String>[
      if (_search.text.trim().isNotEmpty)
        'q=${Uri.encodeQueryComponent(_search.text.trim())}',
      // Leavers are off by default: a register is asked about them, but not
      // most of the time, and a list that opens on everybody who ever worked
      // here answers the wrong question first.
      if (_includeLeavers) 'status=all',
      'period=$_period',
      // Only `custom` carries dates, and only once the picker has run.
      if (_period == 'custom' && _from != null) 'from=$_from',
      if (_period == 'custom' && _to != null) 'to=$_to',
    ];

    try {
      final res = await SessionScope.read(context).api.get(
            '/hr/employees${query.isEmpty ? '' : '?${query.join('&')}'}',
          );

      if (!mounted) return;

      setState(() {
        _people = ((res['people'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(HrEmployeeSummary.fromJson)
            .toList();
        // The dates the server actually used. An older server sends none and
        // the window line simply does not draw, which is the safe direction.
        _from = res['from'] as String?;
        _to = res['to'] as String?;
        _today = res['today'] as String?;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      final t = context.t;
      setState(() {
        _error = e.text(t);
        _loading = false;
      });
    }
  }

  /// Switch the window the attendance line covers.
  ///
  /// `custom` opens a range picker anchored on the **server's** today.
  /// `currentDate` is the day Material rings, and it defaults to
  /// `DateTime.now()`; `lastDate` is a rule rather than decoration, because the
  /// server clamps a window to its own today and a picker offering tomorrow
  /// offers a day the app would then be corrected on.
  Future<void> _chooseWindow(String period) async {
    if (period != 'custom') {
      setState(() {
        _period = period;
        _from = null;
        _to = null;
      });

      return _load();
    }

    final anchor = DateTime.tryParse(_today ?? '');

    // No reply yet means no company date to anchor on, and the handset's is
    // the one date that must not be used here.
    if (anchor == null) return;

    final picked = await showDateRangePicker(
      context: context,
      currentDate: anchor,
      firstDate: anchor.subtract(const Duration(days: 365)),
      lastDate: anchor,
    );

    if (picked == null || !mounted) return;

    setState(() {
      _period = 'custom';
      _from = _ymd(picked.start);
      _to = _ymd(picked.end);
    });

    await _load();
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _load(),
            decoration: InputDecoration(
              hintText: t.hrPeopleSearch,
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        ListTile(
          dense: true,
          title: Text(t.hrPeopleWindow),
          subtitle: _from == null || _to == null
              ? null
              : Text(Fmt.range(t, _from!, _to!)),
          trailing: PopupMenuButton<String>(
            icon: const Icon(Icons.tune),
            initialValue: _period,
            onSelected: _chooseWindow,
            itemBuilder: (context) => [
              PopupMenuItem(value: 'daily', child: Text(t.hrPeriodDaily)),
              PopupMenuItem(value: 'weekly', child: Text(t.hrPeriodWeekly)),
              PopupMenuItem(value: 'monthly', child: Text(t.hrPeriodMonthly)),
              PopupMenuItem(value: 'custom', child: Text(t.hrPeriodCustom)),
            ],
          ),
        ),
        SwitchListTile(
          dense: true,
          value: _includeLeavers,
          title: Text(t.hrPeopleIncludeLeavers),
          onChanged: (value) {
            setState(() => _includeLeavers = value);
            _load();
          },
        ),
        Expanded(
          child: AsyncView(
            loading: _loading,
            error: _error,
            onRetry: _load,
            child: _people.isEmpty
                ? EmptyState(
                    icon: Icons.person_search_outlined,
                    title: t.hrPeopleEmptyTitle,
                    subtitle: t.hrPeopleEmptyBody,
                  )
                : RefreshIndicator(
                    onRefresh: () => _load(silent: true),
                    child: ListView.separated(
                      itemCount: _people.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final person = _people[index];

                        final attendance = person.attendance;

                        return ListTile(
                          isThreeLine: attendance != null,
                          title: Text(person.name),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                [
                                  person.employeeCode,
                                  person.designation,
                                  person.department,
                                ].whereType<String>().join(' · '),
                              ),
                              // Present and late are DAYS. Drawn only when the
                              // server reported them, so an older one loses the
                              // line rather than showing zeros it never sent.
                              if (attendance != null)
                                Text(
                                  t.hrPeopleAttendanceLine(
                                    attendance.presentDays,
                                    attendance.lateDays,
                                    Fmt.duration(t, attendance.workedMinutes),
                                  ),
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                ),
                            ],
                          ),
                          trailing: person.isActive
                              ? null
                              // Named rather than hidden: somebody searching
                              // for a leaver has to see that this is one.
                              : Chip(
                                  label: Text(_statusLabel(t, person.status)),
                                  visualDensity: VisualDensity.compact,
                                ),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => HrPersonScreen(person: person),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

String _statusLabel(dynamic t, String status) => switch (status) {
      'active' => t.hrPeopleStatusActive as String,
      'terminated' => t.hrPeopleStatusTerminated as String,
      _ => t.hrPeopleStatusInactive as String,
    };


String _number(double value) =>
    value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
