import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../main.dart';
import '../widgets/async_view.dart';

class LeaveScreen extends StatefulWidget {
  const LeaveScreen({super.key});

  @override
  State<LeaveScreen> createState() => _LeaveScreenState();
}

class _LeaveScreenState extends State<LeaveScreen> {
  List<LeaveBalance> _balances = const [];
  List<LeaveRequest> _requests = const [];
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
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.error == 'forbidden'
            ? 'This account has no employee record, so it cannot book leave.'
            : e.displayMessage;
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
      builder: (_) => ApplyLeaveSheet(balances: _balances),
    );
    if (created == true) _load();
  }

  Future<void> _cancel(LeaveRequest request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Withdraw this request?'),
        content: Text(
          '${request.leaveType}, ${Fmt.range(request.startDate, request.endDate)}.'
          '${request.status == 'approved' ? '\n\nThe days go back onto your balance.' : ''}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep it')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Withdraw')),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await SessionScope.read(context).api.post('/leave/requests/${request.id}/cancel');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Request withdrawn.')),
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
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Leave')),
      floatingActionButton: (_loading || _error != null || _balances.isEmpty)
          ? null
          : FloatingActionButton.extended(
              onPressed: _apply,
              icon: const Icon(Icons.add),
              label: const Text('Apply'),
              backgroundColor: AppTheme.brand,
              foregroundColor: Colors.white,
            ),
      body: AsyncView(
        loading: _loading,
        error: _error,
        onRetry: _load,
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
            children: [
              _SectionLabel('BALANCES'),
              const SizedBox(height: 10),
              if (_balances.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(18),
                    child: Text('No leave types are open for booking.'),
                  ),
                )
              else
                for (final b in _balances) ...[
                  _BalanceCard(balance: b),
                  const SizedBox(height: 10),
                ],
              const SizedBox(height: 18),
              _SectionLabel('YOUR REQUESTS'),
              const SizedBox(height: 10),
              if (_requests.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(18),
                    child: Text('You have not applied for any leave yet.'),
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

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 4,
              height: 40,
              decoration: BoxDecoration(
                color: _color(balance.colorHex) ?? AppTheme.brand,
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
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    // An uncapped type grants no fixed entitlement — that is how
                    // unpaid leave is set up. Showing "0 left" would read as
                    // exhausted, which is the opposite of what it means.
                    balance.isCapped
                        ? '${_num(balance.usedDays)} used of ${_num(balance.entitledDays)}'
                        : 'No fixed limit',
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
                    'left',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              )
            else
              Icon(Icons.all_inclusive, color: theme.colorScheme.onSurfaceVariant),
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
    final (color, _) = _statusStyle(request.status);

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
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    // "Pending" alone does not say who to chase, so the server
                    // sends a stage: Awaiting Manager, Awaiting HR, or final.
                    request.stage,
                    style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${Fmt.range(request.startDate, request.endDate)} · '
              '${request.isHalfDay ? 'half day' : Fmt.days(request.days)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (request.decisionNote != null && request.decisionNote!.isNotEmpty) ...[
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
                child: TextButton(onPressed: onCancel, child: const Text('Withdraw')),
              )
            else
              const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  static (Color, String) _statusStyle(String status) => switch (status) {
        'approved' => (AppTheme.present, 'Approved'),
        'rejected' => (AppTheme.absent, 'Rejected'),
        'cancelled' => (AppTheme.neutral, 'Withdrawn'),
        _ => (AppTheme.late, 'Pending'),
      };
}

/// The apply form.
///
/// Deliberately does *not* compute a day count. Weekends and company holidays
/// inside the range are free, so Friday-to-Monday over a two-day weekend costs
/// 2 and not 4 — only the server knows the company's calendar. The response
/// says what it actually cost.
class ApplyLeaveSheet extends StatefulWidget {
  const ApplyLeaveSheet({super.key, required this.balances});

  final List<LeaveBalance> balances;

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
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      // The API refuses anything more than two years ahead.
      lastDate: DateTime(now.year + 2),
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

  Future<void> _submit() async {
    if (_start == null || _end == null) {
      setState(() => _error = 'Choose the dates first.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _fieldErrors = const {};
    });

    try {
      final res = await SessionScope.read(context).api.post('/leave/requests', body: {
        'leave_type_id': _type.leaveTypeId,
        'start_date': _ymd(_start!),
        'end_date': _ymd(_end!),
        if (_halfDay) 'is_half_day': true,
        if (_halfDay) 'half_day_period': _halfPeriod,
        if (_reason.text.trim().isNotEmpty) 'reason': _reason.text.trim(),
      });

      if (!mounted) return;
      final request = LeaveRequest.fromJson(res['request'] as Map<String, dynamic>);
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Applied for ${Fmt.days(request.days)} — ${request.stage.toLowerCase()}.'),
          backgroundColor: AppTheme.present,
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
        _error = _fieldErrors.isEmpty ? e.displayMessage : null;
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

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Apply for leave',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
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
              decoration: InputDecoration(
                labelText: 'Leave type',
                errorText: _fieldErrors['leave_type_id'],
              ),
              items: [
                for (final b in widget.balances)
                  DropdownMenuItem(
                    value: b.leaveTypeId,
                    child: Text(
                      b.isCapped ? '${b.name} (${_LeaveNum.of(b.availableDays)} left)' : b.name,
                    ),
                  ),
              ],
              onChanged: (v) {
                final match = widget.balances.firstWhere((b) => b.leaveTypeId == v);
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
                  labelText: 'Dates',
                  errorText: _fieldErrors['start_date'] ?? _fieldErrors['end_date'],
                  suffixIcon: const Icon(Icons.calendar_today, size: 20),
                ),
                child: Text(
                  _start == null
                      ? 'Choose dates'
                      : Fmt.range(_ymd(_start!), _ymd(_end!)),
                ),
              ),
            ),

            if (_type.allowHalfDay && _sameDay) ...[
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Half day'),
                value: _halfDay,
                activeThumbColor: AppTheme.brand,
                onChanged: (v) => setState(() => _halfDay = v),
              ),
              if (_halfDay)
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'first_half', label: Text('Morning')),
                    ButtonSegment(value: 'second_half', label: Text('Afternoon')),
                  ],
                  selected: {_halfPeriod},
                  onSelectionChanged: (s) => setState(() => _halfPeriod = s.first),
                ),
            ],

            const SizedBox(height: 14),
            TextField(
              controller: _reason,
              maxLines: 3,
              maxLength: 1000,
              decoration: InputDecoration(
                labelText: 'Reason (optional)',
                alignLabelWithHint: true,
                errorText: _fieldErrors['reason'],
              ),
            ),
            const SizedBox(height: 6),

            FilledButton(
              onPressed: _busy ? null : _submit,
              style: FilledButton.styleFrom(backgroundColor: AppTheme.brand),
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                    )
                  : const Text('Submit request'),
            ),
            const SizedBox(height: 8),
            Text(
              'Weekends and company holidays inside your dates are not charged.',
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
