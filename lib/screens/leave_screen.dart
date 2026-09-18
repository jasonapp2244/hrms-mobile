import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../core/tab_visibility.dart';
import '../core/theme.dart';
import '../main.dart';
import '../widgets/async_view.dart';
import '../widgets/sheet_padding.dart';

class LeaveScreen extends StatefulWidget {
  const LeaveScreen({super.key, required this.visible});

  /// Set by `HomeShell` while this tab is the one on screen.
  final ValueListenable<bool> visible;

  @override
  State<LeaveScreen> createState() => _LeaveScreenState();
}

class _LeaveScreenState extends State<LeaveScreen> with RefreshOnShow {
  List<LeaveBalance> _balances = const [];
  List<LeaveRequest> _requests = const [];
  bool _loading = true;
  String? _error;

  /// True when [_error] is one no retry can clear — the account has no employee
  /// record. See [ApiErrorText.isMissingEmployeeRecord].
  bool _fatal = false;

  /// The day the **server** last said the company was on.
  ///
  /// Null until the first reply lands. Not `DateTime.now()`: the date picker
  /// this feeds rings a day as today, and a handset is wherever its owner is.
  DateTime? _today;

  @override
  ValueListenable<bool> get visibility => widget.visible;

  @override
  Future<void> refresh() => _load(silent: true);

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// [silent] leaves the current balances and requests on screen while the new
  /// ones are fetched, for refreshes the user did not explicitly ask for.
  Future<void> _load({bool silent = false}) async {
    setState(() {
      _loading = !silent;
      _error = null;
      _fatal = false;
    });

    try {
      final api = SessionScope.read(context).api;
      final results = await Future.wait([
        api.get('/leave/balances'),
        api.get('/leave/requests'),
      ]);

      if (!mounted) return;
      setState(() {
        _balances = ((results[0]['balances'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(LeaveBalance.fromJson)
            .toList();
        _requests = ((results[1]['requests'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(LeaveRequest.fromJson)
            .toList();
        // The day the company is on, which is the day the date picker has to
        // open on. Not `DateTime.now()` — see [_ApplySheet._pickRange].
        _today = DateTime.tryParse('${results[0]['today']}') ?? _today;
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
        // No retry offered for this one: it is the account, not the network.
        _fatal = e.isMissingEmployeeRecord;
        _error = _fatal ? t.leaveNoEmployeeRecord : e.text(t);
        _loading = false;
      });
    }
  }

  Future<void> _apply() async {
    if (_balances.isEmpty) return;
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ApplyLeaveSheet(balances: _balances, today: _today),
    );
    if (created == true) _load();
  }

  Future<void> _cancel(LeaveRequest request) async {
    final t = context.t;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.leaveWithdrawTitle),
        content: Text(
          t.leaveWithdrawBody(
                request.leaveType,
                Fmt.range(t, request.startDate, request.endDate),
              ) +
              (request.status == 'approved'
                  ? '\n\n${t.leaveWithdrawRefund}'
                  : ''),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.leaveKeepIt),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.leaveWithdrawAction),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await SessionScope.read(
        context,
      ).api.post('/leave/requests/${request.id}/cancel');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.leaveWithdrawn)));
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.text(t)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    return Scaffold(
      appBar: AppBar(title: Text(t.leaveTitle)),
      floatingActionButton: (_loading || _error != null || _balances.isEmpty)
          ? null
          : FloatingActionButton.extended(
              onPressed: _apply,
              icon: const Icon(Icons.add),
              label: Text(t.leaveApply),
              // #F26522 with white on it is 3.15:1 — under AA for this label.
              // The scheme already holds an accessible pair (B6.4).
            ),
      body: AsyncView(
        loading: _loading,
        error: _error,
        onRetry: _load,
        permanent: _fatal,
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
            children: [
              _SectionLabel(t.leaveSectionBalances),
              const SizedBox(height: 10),
              if (_balances.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text(t.leaveNoTypes),
                  ),
                )
              else
                for (final b in _balances) ...[
                  _BalanceCard(balance: b),
                  const SizedBox(height: 10),
                ],
              const SizedBox(height: 18),
              _SectionLabel(t.leaveSectionRequests),
              const SizedBox(height: 10),
              if (_requests.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text(t.leaveNoRequests),
                  ),
                )
              else
                for (final r in _requests) ...[
                  _RequestCard(request: r, onCancel: () => _cancel(r)),
                  const SizedBox(height: 10),
                ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelSmall?.copyWith(
        letterSpacing: 1.1,
        fontWeight: FontWeight.w700,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.balance});

  final LeaveBalance balance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.t;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 4,
              height: 40,
              decoration: BoxDecoration(
                color: _color(balance.colorHex) ?? AppTheme.brandOf(context),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    balance.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    // An uncapped type grants no fixed entitlement — that is how
                    // unpaid leave is set up. Showing "0 left" would read as
                    // exhausted, which is the opposite of what it means.
                    balance.isCapped
                        ? t.leaveUsedOf(
                            _num(balance.usedDays),
                            _num(balance.entitledDays),
                          )
                        : t.leaveNoFixedLimit,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (balance.isCapped)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _num(balance.availableDays),
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                  Text(
                    t.leaveDaysLeft,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              )
            else
              Icon(
                Icons.all_inclusive,
                color: theme.colorScheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }

  static String _num(double d) =>
      d == d.roundToDouble() ? d.toInt().toString() : d.toString();

  static Color? _color(String? hex) {
    if (hex == null) return null;
    final cleaned = hex.replaceAll('#', '');
    final value = int.tryParse(cleaned, radix: 16);
    if (value == null) return null;
    return Color(cleaned.length == 6 ? 0xFF000000 | value : value);
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.request, required this.onCancel});

  final LeaveRequest request;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.t;
    final color = _statusColour(AppColors.of(context), request.status);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    request.leaveType,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    // "Pending" alone does not say who to chase, so the server
                    // sends a stage: Awaiting Manager, Awaiting HR, or final.
                    request.stage,
                    style: TextStyle(
                      color: color,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              t.leaveRangeAndLength(
                Fmt.range(t, request.startDate, request.endDate),
                request.isHalfDay
                    ? t.leaveHalfDayShort
                    : Fmt.days(t, request.days),
              ),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            // B4.1. Named rather than labelled "attachment", and shown without
            // a link: this is the person's own file, and the two routes that
            // serve it are for whoever has to decide. Seeing the name is how
            // they know it arrived.
            if (request.attachmentName != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.attach_file,
                    size: 15,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      request.attachmentName!,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (request.decisionNote != null &&
                request.decisionNote!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  request.decisionNote!,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
            if (request.canCancel)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: onCancel,
                  child: Text(t.leaveWithdrawAction),
                ),
              )
            else
              const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  /// Colour only. The **word** on the pill is `request.stage`, which the server
  /// sends because "Pending" alone does not say who to chase; this used to
  /// return a second label beside the colour that no caller ever read.
  static Color _statusColour(AppColors colors, String status) => switch (status) {
    'approved' => colors.present,
    'rejected' => colors.absent,
    'cancelled' => colors.neutral,
    _ => colors.late,
  };
}

/// The apply form.
///
/// Deliberately does *not* compute a day count. Weekends and company holidays
/// inside the range are free, so Friday-to-Monday over a two-day weekend costs
/// 2 and not 4 — only the server knows the company's calendar. The response
/// says what it actually cost.
class ApplyLeaveSheet extends StatefulWidget {
  const ApplyLeaveSheet({super.key, required this.balances, this.today});

  final List<LeaveBalance> balances;

  /// The day the server says the company is on, or null if no reply has
  /// carried one. See [_ApplyLeaveSheetState._pickRange].
  final DateTime? today;

  @override
  State<ApplyLeaveSheet> createState() => _ApplyLeaveSheetState();
}

class _ApplyLeaveSheetState extends State<ApplyLeaveSheet> {
  late LeaveBalance _type = widget.balances.first;
  DateTime? _start;
  DateTime? _end;
  bool _halfDay = false;
  String _halfPeriod = 'first_half';
  final _reason = TextEditingController();

  /// The supporting file, once one has been picked (B4.1). Null is the normal
  /// case — most leave needs no evidence.
  ({String path, String name})? _attachment;

  bool _busy = false;
  String? _error;
  Map<String, String> _fieldErrors = const {};

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  bool get _sameDay =>
      _start != null && _end != null && _ymd(_start!) == _ymd(_end!);

  Future<void> _pickRange() async {
    // The company's today, and only the handset's when nothing has told us
    // otherwise. The picker draws a ring around whatever it is given as
    // `currentDate`, and on a phone a few hours ahead of the company that ring
    // sat on tomorrow — while the Clock, History and Schedule tabs all
    // correctly showed the day before it. Somebody booking "from today" would
    // have booked the wrong day, and every date the picker offers is a date
    // this same screen will hand to a server that judges it in the company's
    // zone.
    final today = widget.today ?? DateTime.now();

    final picked = await showDateRangePicker(
      context: context,
      currentDate: today,
      firstDate: DateTime(today.year - 1),
      // The API refuses anything more than two years ahead.
      lastDate: DateTime(today.year + 2),
      initialDateRange: _start != null && _end != null
          ? DateTimeRange(start: _start!, end: _end!)
          : null,
    );

    if (picked != null) {
      setState(() {
        _start = picked.start;
        _end = picked.end;
        if (!_sameDay) _halfDay = false;
      });
    }
  }

  /// What the server will accept, checked here as well (B4.1).
  ///
  /// Not a second rule — the same one, asked earlier. Ten megabytes over a
  /// phone connection is a long wait to be told no, and the refusal is the same
  /// either way.
  static const _maxAttachmentBytes = 10 * 1024 * 1024;

  static const _allowedAttachmentTypes = [
    'pdf', 'jpg', 'jpeg', 'png', 'webp', 'doc', 'docx',
  ];

  Future<void> _pickAttachment() async {
    final t = context.t;

    // Static, not `FilePicker.platform`: version 11 made the class abstract
    // final and moved the platform indirection behind it.
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: _allowedAttachmentTypes,
    );

    if (!mounted || result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final path = file.path;

    // Android can hand back an entry with no readable path — a file living in
    // a cloud provider that was never downloaded. There is nothing to upload
    // in that case, and saying so beats posting an empty part.
    if (path == null) {
      setState(() => _error = t.leaveAttachUnreadable);
      return;
    }

    if (file.size > _maxAttachmentBytes) {
      setState(() => _error = t.leaveAttachTooLarge);
      return;
    }

    setState(() {
      _attachment = (path: path, name: file.name);
      _error = null;
    });
  }

  Future<void> _submit() async {
    // Read before the first await: the palette cannot change mid-call, and
    // reaching for a BuildContext after one is the lint this avoids.
    final colors = AppColors.of(context);
    final t = context.t;
    if (_start == null || _end == null) {
      setState(() => _error = t.leaveChooseDatesFirst);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _fieldErrors = const {};
    });

    try {
      // Multipart whether or not a file is attached, rather than two code
      // paths that have to stay in step. Every field crosses as a string, so
      // `is_half_day` is '1' rather than true — which is what the server's
      // `boolean()` reads anyway.
      final res = await SessionScope.read(context).api.postMultipart(
        '/leave/requests',
        fields: {
          'leave_type_id': '${_type.leaveTypeId}',
          'start_date': _ymd(_start!),
          'end_date': _ymd(_end!),
          if (_halfDay) 'is_half_day': '1',
          if (_halfDay) 'half_day_period': _halfPeriod,
          if (_reason.text.trim().isNotEmpty) 'reason': _reason.text.trim(),
        },
        filePath: _attachment?.path,
      );

      if (!mounted) return;
      final request = LeaveRequest.fromJson(
        res['request'] as Map<String, dynamic>,
      );
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t.leaveApplied(
              Fmt.days(t, request.days),
              request.stage.toLowerCase(),
            ),
          ),
          backgroundColor: colors.present,
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        // Business-rule refusals arrive as validation errors against the field
        // that caused them, so they belong on the form rather than in a toast.
        _fieldErrors = {
          for (final entry in e.fieldErrors.entries)
            if (entry.value.isNotEmpty) entry.key: entry.value.first,
        };
        _error = _fieldErrors.isEmpty ? e.text(t) : null;
        _busy = false;
      });
      return;
    }

    if (mounted) setState(() => _busy = false);
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.t;

    return Padding(
      padding: sheetPadding(context),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t.leaveApplyTitle,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 20),

            if (_error != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
              const SizedBox(height: 14),
            ],

            DropdownButtonFormField<int>(
              initialValue: _type.leaveTypeId,
              // A dropdown sizes itself to its widest item and does **not**
              // wrap or clip one: leave types are named by whoever set them up,
              // and "Compassionate / Bereavement Leave (12.5 left)" runs off
              // the side of a phone. Expanded gives the label the full width to
              // work with and the ellipsis takes what is still too long — the
              // balance is on the card above and the list is one tap away, so
              // a trimmed tail costs nothing a reader cannot recover.
              isExpanded: true,
              decoration: InputDecoration(
                labelText: t.leaveType,
                errorText: _fieldErrors['leave_type_id'],
              ),
              items: [
                for (final b in widget.balances)
                  DropdownMenuItem(
                    value: b.leaveTypeId,
                    child: Text(
                      b.isCapped
                          ? t.leaveTypeWithBalance(
                              b.name,
                              _LeaveNum.of(b.availableDays),
                            )
                          : b.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) {
                final match = widget.balances.firstWhere(
                  (b) => b.leaveTypeId == v,
                );
                setState(() {
                  _type = match;
                  if (!match.allowHalfDay) _halfDay = false;
                });
              },
            ),
            const SizedBox(height: 14),

            InkWell(
              onTap: _pickRange,
              borderRadius: BorderRadius.circular(12),
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: t.leaveDates,
                  errorText:
                      _fieldErrors['start_date'] ?? _fieldErrors['end_date'],
                  suffixIcon: const Icon(Icons.calendar_today, size: 20),
                ),
                child: Text(
                  _start == null
                      ? t.leaveChooseDates
                      : Fmt.range(t, _ymd(_start!), _ymd(_end!)),
                ),
              ),
            ),

            if (_type.allowHalfDay && _sameDay) ...[
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t.leaveHalfDay),
                value: _halfDay,
                activeThumbColor: AppTheme.brandOf(context),
                onChanged: (v) => setState(() => _halfDay = v),
              ),
              if (_halfDay)
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'first_half',
                      label: Text(t.leaveMorning),
                    ),
                    ButtonSegment(
                      value: 'second_half',
                      label: Text(t.leaveAfternoon),
                    ),
                  ],
                  selected: {_halfPeriod},
                  onSelectionChanged: (s) =>
                      setState(() => _halfPeriod = s.first),
                ),
            ],

            const SizedBox(height: 14),
            TextField(
              controller: _reason,
              maxLines: 3,
              maxLength: 1000,
              decoration: InputDecoration(
                labelText: t.leaveReasonOptional,
                alignLabelWithHint: true,
                errorText: _fieldErrors['reason'],
              ),
            ),
            const SizedBox(height: 6),

            // B4.1. Below the reason because it is what supports the reason,
            // and stated as optional in the control itself — most leave needs
            // no evidence, and a field that looks required makes people go
            // hunting for one.
            if (_attachment == null)
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickAttachment,
                icon: const Icon(Icons.attach_file, size: 18),
                label: Text(t.leaveAttachOptional),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                ),
              )
            else
              Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.attach_file,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    // Flexible, because a file picked out of a downloads folder
                    // can easily be longer than a phone is wide.
                    Flexible(
                      child: Text(
                        _attachment!.name,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    IconButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() => _attachment = null),
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: t.leaveAttachRemove,
                    ),
                  ],
                ),
              ),
            if (_fieldErrors['attachment'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 12),
                child: Text(
                  _fieldErrors['attachment']!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 14),

            FilledButton(
              onPressed: _busy ? null : _submit,
              // No backgroundColor override: the theme primary is the deeper
              // orange precisely so that its white label reads (B6.4).
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Colors.white,
                      ),
                    )
                  : Text(t.leaveSubmit),
            ),
            const SizedBox(height: 8),
            Text(
              t.leaveFreeDaysNote,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LeaveNum {
  static String of(double d) =>
      d == d.roundToDouble() ? d.toInt().toString() : d.toString();
}
