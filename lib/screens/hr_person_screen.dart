import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../main.dart';
import '../widgets/async_view.dart';

/// One employee record, as only `manage-employees` may read it.
///
/// **Everything the directory deliberately refuses to say.** `/directory`
/// answers "who else works here" for every member of staff and withholds date
/// of birth, address, national id, the emergency contact and the reporting
/// line; this screen shows them, because the person reading holds the
/// permission the web puts on the same fields.
///
/// **Read-only, and it says so.** Editing a record one-handed writes an audit
/// trail nobody would check, and the fields most likely to be mistyped are the
/// ones least likely to be noticed wrong. The note at the bottom is there so
/// that the absence of an edit button reads as a decision rather than as an
/// unfinished screen.
class HrPersonScreen extends StatefulWidget {
  const HrPersonScreen({super.key, required this.person});

  /// The row that was tapped. Used for the header while the full record loads,
  /// so the screen opens on a name rather than on a spinner.
  final HrEmployeeSummary person;

  @override
  State<HrPersonScreen> createState() => _HrPersonScreenState();
}

class _HrPersonScreenState extends State<HrPersonScreen> {
  HrEmployeeRecord? _record;
  List<HrEmployeeLeave> _leave = const [];
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
      final record = await api.get('/hr/employees/${widget.person.id}');
      // The history is its own request on the server for a reason — a
      // long-serving employee has a long one — but the screen shows both, so
      // they are fetched together and the second failing does not cost the
      // first.
      final leave = await api.get('/hr/employees/${widget.person.id}/leave');

      if (!mounted) return;

      setState(() {
        _record = HrEmployeeRecord.fromJson(record);
        _leave = ((leave['requests'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(HrEmployeeLeave.fromJson)
            .toList();
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

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final record = _record;

    return Scaffold(
      appBar: AppBar(title: Text(widget.person.name)),
      body: AsyncView(
        loading: _loading,
        error: _error,
        onRetry: _load,
        child: record == null
            ? const SizedBox.shrink()
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _Header(person: record.summary),
                  const SizedBox(height: 16),

                  _Section(
                    title: t.hrPersonEmployment,
                    rows: [
                      (t.hrPersonHireDate, record.hireDate),
                      (t.hrPersonWorkMode, record.workMode),
                      (t.hrPersonManager, record.manager),
                      (t.hrPersonShift, record.shift),
                    ],
                  ),

                  _Section(
                    title: t.hrPersonPersonal,
                    rows: [
                      (t.hrPersonDateOfBirth, record.dateOfBirth),
                      (t.hrPersonGender, record.gender),
                      (t.hrPersonNationalId, record.nationalId),
                      (t.hrPersonBloodGroup, record.bloodGroup),
                      (t.hrPersonPersonalEmail, record.personalEmail),
                      (
                        t.hrPersonAddress,
                        [record.address, record.city, record.country]
                                .whereType<String>()
                                .isEmpty
                            ? null
                            : [record.address, record.city, record.country]
                                .whereType<String>()
                                .join(', ')
                      ),
                    ],
                  ),

                  _Section(
                    title: t.hrPersonEmergency,
                    rows: [
                      (t.hrPersonEmergency, record.emergencyName),
                      (t.hrPersonPhone, record.emergencyPhone),
                      (t.hrPersonRelation, record.emergencyRelation),
                    ],
                  ),

                  _SignInCard(record: record),

                  if (record.attendance != null)
                    _AttendanceCard(summary: record.attendance!),

                  if (record.balances.isNotEmpty)
                    _BalancesCard(balances: record.balances),

                  _LeaveHistory(requests: _leave),

                  const SizedBox(height: 16),
                  Text(
                    t.hrPersonReadOnly,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).hintColor,
                        ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.person});

  final HrEmployeeSummary person;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        CircleAvatar(
          radius: 28,
          backgroundImage:
              person.photoUrl != null ? NetworkImage(person.photoUrl!) : null,
          child: person.photoUrl == null
              ? Text(person.name.isEmpty ? '?' : person.name[0].toUpperCase())
              : null,
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(person.name, style: theme.textTheme.titleLarge),
              Text(
                [person.employeeCode, person.designation, person.office]
                    .whereType<String>()
                    .join(' · '),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.hintColor),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A card of label/value rows.
///
/// **A null value drops its row entirely** rather than printing a dash. A
/// record is filled in over time, and a screen of em dashes reads as a broken
/// fetch rather than as a half-complete record — which is the ordinary state of
/// most of them.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.rows});

  final String title;
  final List<(String, String?)> rows;

  @override
  Widget build(BuildContext context) {
    final present = rows.where((row) => row.$2 != null && row.$2!.isNotEmpty);

    if (present.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final (label, value) in present)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 130,
                      child: Text(
                        label,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.hintColor),
                      ),
                    ),
                    Expanded(
                      child: Text(value!, style: theme.textTheme.bodyMedium),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Whether this person can sign in at all.
///
/// The question HR is asked most often about somebody who says the app will
/// not let them in, and one the register could not answer before. The account
/// itself is created and changed on the web.
class _SignInCard extends StatelessWidget {
  const _SignInCard({required this.record});

  final HrEmployeeRecord record;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final colors = AppColors.of(context);
    final theme = Theme.of(context);

    final disabled = record.hasLogin && record.loginActive == false;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(
          record.hasLogin ? Icons.lock_open_outlined : Icons.lock_outline,
          color: !record.hasLogin || disabled ? colors.late : colors.present,
        ),
        title: Text(t.hrPersonSignIn, style: theme.textTheme.titleSmall),
        subtitle: Text(
          !record.hasLogin
              ? t.hrPersonSignInNone
              : disabled
                  ? '${record.loginEmail ?? ''} — ${t.hrPersonSignInDisabled}'
                  : record.loginEmail ?? '',
        ),
      ),
    );
  }
}

class _AttendanceCard extends StatelessWidget {
  const _AttendanceCard({required this.summary});

  final HrAttendanceSummary summary;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.hrPersonAttendance, style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            Row(
              children: [
                _Stat(label: t.hrPersonDaysWorked, value: summary.daysWorked),
                _Stat(label: t.hrPersonOnTime, value: summary.onTime),
                _Stat(label: t.hrPersonLate, value: summary.late),
                _Stat(label: t.hrPersonEarlyLeave, value: summary.earlyLeave),
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
  final int value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Expanded(
      child: Column(
        children: [
          Text('$value', style: theme.textTheme.headlineSmall),
          Text(
            label,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );
  }
}

class _BalancesCard extends StatelessWidget {
  const _BalancesCard({required this.balances});

  final List<HrBalance> balances;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.hrPersonBalances, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final balance in balances)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Expanded(child: Text(balance.leaveType ?? '')),
                    Text(
                      // An uncapped type has no meaningful "left", so it says
                      // what was taken instead of a figure that would read as
                      // a limit somebody is close to.
                      balance.capped
                          ? t.hrApprovalsBalance(
                              _n(balance.available),
                              _n(balance.entitled),
                            )
                          : t.hrApprovalsBalanceUncapped(_n(balance.used)),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LeaveHistory extends StatelessWidget {
  const _LeaveHistory({required this.requests});

  final List<HrEmployeeLeave> requests;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final colors = AppColors.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.hrPersonLeaveHistory, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            if (requests.isEmpty)
              Text(t.hrPersonNoLeave, style: theme.textTheme.bodySmall)
            else
              for (final request in requests)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    switch (request.status) {
                      'approved' => Icons.check_circle_outline,
                      'rejected' => Icons.cancel_outlined,
                      'pending' => Icons.schedule,
                      _ => Icons.remove_circle_outline,
                    },
                    color: switch (request.status) {
                      'approved' => colors.present,
                      'rejected' => colors.late,
                      _ => theme.hintColor,
                    },
                  ),
                  title: Text(request.leaveType),
                  subtitle: Text(
                    '${request.startDate} → ${request.endDate} · '
                    '${_n(request.days)}',
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

String _n(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(1);
