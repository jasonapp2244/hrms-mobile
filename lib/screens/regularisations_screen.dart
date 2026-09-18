import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../main.dart';
import '../widgets/async_view.dart';
import '../widgets/sheet_padding.dart';

/// Asking for the attendance record to be corrected (B3.9 / A4.13).
///
/// Reached from History rather than given a tab: it is opened when a punch is
/// wrong, which is rare, and it only makes sense next to the record it is
/// disputing.
///
/// **Raising and withdrawing only.** Approving one voids a punch and writes a
/// replacement — `manage-attendance`, HR's, and on the web. There is no
/// decide button here for anybody, manager included: leave approval is
/// manager-then-HR, a correction is HR's alone.
class RegularisationsScreen extends StatefulWidget {
  const RegularisationsScreen({super.key});

  @override
  State<RegularisationsScreen> createState() => _RegularisationsScreenState();
}

class _RegularisationsScreenState extends State<RegularisationsScreen> {
  List<Regularisation> _requests = const [];
  List<DisputablePunch> _punches = const [];

  /// The day the **server** last said the company was on.
  ///
  /// Null until the first reply lands. Not `DateTime.now()`: it is the line the
  /// date picker must not offer past — see [_RaiseSheetState._pickWhen].
  DateTime? _today;

  bool _loading = true;
  String? _error;

  /// True when [_error] is one no retry can clear — the account has no employee
  /// record. See [ApiErrorText.isMissingEmployeeRecord].
  bool _fatal = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _fatal = false;
    });

    try {
      final res = await SessionScope.read(context).api.get('/attendance/regularisations');
      if (!mounted) return;

      setState(() {
        _requests = ((res['requests'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(Regularisation.fromJson)
            .toList();
        // Breaks are filtered out here rather than on the server: the server's
        // list is "your recent punches", and only in/out are correctable.
        _punches = ((res['recent_punches'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(DisputablePunch.fromJson)
            .where((p) => p.isCorrectable)
            .toList();
        _today = DateTime.tryParse('${res['today']}') ?? _today;
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
        _error = _fatal ? t.correctionsNoEmployeeRecord : e.text(t);
        _loading = false;
      });
    }
  }

  Future<void> _raise() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _RaiseSheet(punches: _punches, today: _today),
    );

    if (created == true) _load();
  }

  Future<void> _withdraw(Regularisation request) async {
    // Read before the first await: the palette cannot change mid-call, and
    // reaching for a BuildContext after one is the lint this avoids.
    final colors = AppColors.of(context);
    final t = context.t;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.correctionsWithdrawTitle),
        content: Text(
          t.correctionsWithdrawBody(
            request.summary(t),
            Fmt.shortDate(t, request.workDate),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.correctionsKeepIt),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.correctionsWithdraw),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await SessionScope.read(context)
          .api
          .post('/attendance/regularisations/${request.id}/cancel');

      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.correctionsWithdrawn)));
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      // Most likely HR decided it while this screen was open. Reloading shows
      // the decision, which answers it better than the message does.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.text(t)), backgroundColor: colors.late),
      );
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    return Scaffold(
      appBar: AppBar(title: Text(t.correctionsTitle)),
      floatingActionButton: _loading || _error != null
          ? null
          : FloatingActionButton.extended(
              onPressed: _raise,
              // The scheme primary already carries a white label at 4.72:1;
              // #F26522 does not (B6.4).
              icon: const Icon(Icons.add),
              label: Text(t.correctionsRaise),
            ),
      body: AsyncView(
        loading: _loading,
        error: _error,
        onRetry: _load,
        permanent: _fatal,
        child: RefreshIndicator(
          onRefresh: _load,
          child: _requests.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    const SizedBox(height: 90),
                    EmptyState(
                      icon: Icons.rule,
                      title: t.correctionsEmptyTitle,
                      subtitle: t.correctionsEmptySubtitle,
                    ),
                  ],
                )
              : ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                  children: [
                    for (final request in _requests)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _RequestCard(
                          request: request,
                          onWithdraw: request.canCancel ? () => _withdraw(request) : null,
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.request, this.onWithdraw});

  final Regularisation request;
  final VoidCallback? onWithdraw;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final t = context.t;

    final (label, colour) = switch (request.status) {
      'approved' => (t.correctionsStatusApproved, colors.present),
      'rejected' => (t.correctionsStatusRejected, colors.absent),
      'cancelled' => (t.correctionsStatusWithdrawn, colors.neutral),
      _ => (t.correctionsStatusWaiting, colors.late),
    };

    final summary = request.summary(t);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${summary[0].toUpperCase()}${summary.substring(1)}',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: colour.withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      color: colour,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              t.correctionsShouldRead(
                Fmt.shortDate(t, request.workDate),
                Fmt.timeOf(t, request.requestedAt),
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Text(request.reason, style: theme.textTheme.bodyMedium),
            if (request.decisionNote != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: colour.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.decidedBy == null
                          ? t.correctionsHrSaid
                          : t.correctionsHrNamed(request.decidedBy!),
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colour,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(request.decisionNote!, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ],
            if (onWithdraw != null) ...[
              SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: onWithdraw,
                  style: TextButton.styleFrom(foregroundColor: colors.absent),
                  child: Text(t.correctionsWithdraw),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Raising one.
///
/// Two shapes in one form: pick a punch to dispute, or leave it on "none of
/// these" to report one that is missing. The server tells the two apart from
/// whether `attendance_log_id` is present, so the form does not have to send a
/// mode as well — one less thing that can disagree with itself.
class _RaiseSheet extends StatefulWidget {
  const _RaiseSheet({required this.punches, this.today});

  final List<DisputablePunch> punches;

  /// The day the server says the company is on, or null if no reply has
  /// carried one. See [_RaiseSheetState._pickWhen].
  final DateTime? today;

  @override
  State<_RaiseSheet> createState() => _RaiseSheetState();
}

class _RaiseSheetState extends State<_RaiseSheet> {
  final _reason = TextEditingController();

  DisputablePunch? _disputed;
  String _type = 'in';

  /// Opens on the company's own today at the current wall clock, not on the
  /// handset's date. A phone a few hours ahead of the company would otherwise
  /// open this form on a day the server has not reached and will refuse.
  late DateTime _when = _defaultWhen();

  bool _busy = false;
  String? _error;
  Map<String, String> _fieldErrors = const {};

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  /// The company's today at the handset's wall clock.
  ///
  /// The date has to be the company's, because that is what the server judges.
  /// The *time* is only a starting point the user is about to change, and the
  /// phone's clock is as good a guess as any for it.
  DateTime _defaultWhen() {
    final now = DateTime.now();
    final today = widget.today;

    return today == null
        ? now
        : DateTime(today.year, today.month, today.day, now.hour, now.minute);
  }

  Future<void> _pickWhen() async {
    // The company's today, not the handset's. This is the line the picker must
    // not offer past: the server refuses a correction to a time that has not
    // happened, and on a phone even a few hours ahead the picker was offering
    // exactly that — a date the app itself suggested and the server then
    // rejected, which reads to the user as the app being broken.
    final today = widget.today ?? DateTime.now();
    final last = DateTime(today.year, today.month, today.day, 23, 59);

    final date = await showDatePicker(
      context: context,
      currentDate: today,
      // Clamped, because a sheet left open across midnight in the company's
      // zone would otherwise hand the picker an initial date past its own
      // lastDate, which asserts rather than degrades.
      initialDate: _when.isAfter(last) ? last : _when,
      firstDate: DateTime(today.year, today.month, today.day)
          .subtract(const Duration(days: 92)),
      lastDate: last,
    );

    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_when),
    );

    if (time == null || !mounted) return;

    setState(() {
      _when = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
      _fieldErrors = const {};
    });

    try {
      await SessionScope.read(context).api.post('/attendance/regularisations', body: {
        if (_disputed != null) 'attendance_log_id': _disputed!.id,
        'type': _type,
        'requested_at': _iso(_when),
        'reason': _reason.text.trim(),
      });

      if (!mounted) return;
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _fieldErrors = {
          for (final entry in e.fieldErrors.entries)
            if (entry.value.isNotEmpty) entry.key: entry.value.first,
        };
        _error = _fieldErrors.isEmpty ? e.text(context.t) : null;
      });
    }
  }

  /// Local wall-clock, no offset. The server reads it in the company's zone,
  /// which is the zone the punch would have been made in.
  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}:00';

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
              t.correctionsRaise,
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              t.correctionsSheetBlurb,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
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

            DropdownButtonFormField<DisputablePunch?>(
              initialValue: _disputed,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: t.correctionsWhichPunch,
                errorText: _fieldErrors['attendance_log_id'],
              ),
              items: [
                DropdownMenuItem<DisputablePunch?>(
                  value: null,
                  child: Text(t.correctionsNoneOfThese),
                ),
                for (final punch in widget.punches)
                  DropdownMenuItem<DisputablePunch?>(
                    value: punch,
                    child: Text(
                      t.correctionsPunchOption(
                        Fmt.shortDate(t, punch.workDate),
                        punch.label(t),
                        punch.time,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (punch) => setState(() {
                _disputed = punch;
                // Disputing a punch corrects that punch, so the direction is
                // already decided — asking again would let the two disagree.
                if (punch != null) _type = punch.type;
              }),
            ),
            const SizedBox(height: 12),

            if (_disputed == null) ...[
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: 'in',
                    label: Text(t.punchCheckIn),
                    icon: const Icon(Icons.login),
                  ),
                  ButtonSegment(
                    value: 'out',
                    label: Text(t.punchCheckOut),
                    icon: const Icon(Icons.logout),
                  ),
                ],
                selected: {_type},
                onSelectionChanged: (s) => setState(() => _type = s.first),
              ),
              const SizedBox(height: 12),
            ],

            OutlinedButton.icon(
              onPressed: _pickWhen,
              icon: const Icon(Icons.schedule),
              label: Text(
                t.correctionsShouldReadAt(
                  Fmt.shortDate(t, _iso(_when).substring(0, 10)),
                  TimeOfDay.fromDateTime(_when).format(context),
                ),
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: _fieldErrors['requested_at'] != null
                    ? theme.colorScheme.error
                    : null,
              ),
            ),
            if (_fieldErrors['requested_at'] != null) ...[
              const SizedBox(height: 6),
              Text(
                _fieldErrors['requested_at']!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),

            TextField(
              controller: _reason,
              maxLines: 3,
              maxLength: 500,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: t.correctionsWhatHappened,
                hintText: t.correctionsReasonHint,
                errorText: _fieldErrors['reason'],
              ),
            ),
            const SizedBox(height: 8),

            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                    )
                  : Text(t.correctionsSend),
            ),
          ],
        ),
      ),
    );
  }
}
