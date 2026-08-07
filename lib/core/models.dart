/// Models mirroring the v1 API payloads.
///
/// Two rules run through all of them, both taken from the reference rather than
/// invented here:
///
///   * Day counts arrive as JSON numbers and a half day is `0.5`, so every day
///     figure is a `double`, never an `int`.
///   * Timestamps carry the *company's* offset, not the handset's. They are
///     kept as the server's own strings where they are only ever displayed, so
///     a phone in another country cannot quietly re-render someone else's
///     office clock.
library;

double _toDouble(Object? v) => v is num ? v.toDouble() : 0.0;
int _toInt(Object? v) => v is num ? v.toInt() : 0;
String? _str(Object? v) => v == null ? null : '$v';

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

class Company {
  Company({required this.id, required this.name, required this.timezone, this.currency});

  final int id;
  final String name;
  final String timezone;
  final String? currency;

  factory Company.fromJson(Map<String, dynamic> j) => Company(
        id: _toInt(j['id']),
        name: '${j['name'] ?? ''}',
        timezone: '${j['timezone'] ?? 'UTC'}',
        currency: _str(j['currency']),
      );
}

class EmployeeRef {
  EmployeeRef({
    required this.id,
    required this.employeeCode,
    required this.fullName,
    this.department,
    this.designation,
    this.office,
    this.workMode,
    required this.isManager,
  });

  final int id;
  final String employeeCode;
  final String fullName;
  final String? department;
  final String? designation;
  final String? office;
  final String? workMode;
  final bool isManager;

  factory EmployeeRef.fromJson(Map<String, dynamic> j) => EmployeeRef(
        id: _toInt(j['id']),
        employeeCode: '${j['employee_code'] ?? ''}',
        fullName: '${j['full_name'] ?? ''}',
        department: _str(j['department']),
        designation: _str(j['designation']),
        office: _str(j['office']),
        workMode: _str(j['work_mode']),
        isManager: j['is_manager'] == true,
      );
}

class AppUser {
  AppUser({
    required this.id,
    required this.name,
    required this.email,
    required this.roles,
    required this.permissions,
    this.company,
    this.employee,
  });

  final int id;
  final String name;
  final String email;
  final List<String> roles;
  final List<String> permissions;
  final Company? company;

  /// Null for an account with no employee record — an admin login, typically.
  /// Such an account signs in fine and then gets 403 from every
  /// employee-scoped endpoint, so the UI has to check this rather than assume.
  final EmployeeRef? employee;

  /// The gate for the whole manager section. The reference is explicit: show it
  /// only when the permission is present, because the endpoints behind it are
  /// permission-gated *and* scoped to direct reports.
  bool get canApproveLeave => permissions.contains('approve-leave');

  bool get hasEmployeeRecord => employee != null;

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters1();
    return '${parts.first.characters1()}${parts.last.characters1()}';
  }

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: _toInt(j['id']),
        name: '${j['name'] ?? ''}',
        email: '${j['email'] ?? ''}',
        roles: ((j['roles'] as List?) ?? const []).map((e) => '$e').toList(),
        permissions: ((j['permissions'] as List?) ?? const []).map((e) => '$e').toList(),
        company: j['company'] is Map<String, dynamic>
            ? Company.fromJson(j['company'] as Map<String, dynamic>)
            : null,
        employee: j['employee'] is Map<String, dynamic>
            ? EmployeeRef.fromJson(j['employee'] as Map<String, dynamic>)
            : null,
      );
}

extension on String {
  String characters1() => isEmpty ? '' : this[0].toUpperCase();
}

// ---------------------------------------------------------------------------
// Attendance
// ---------------------------------------------------------------------------

class Punch {
  Punch({
    required this.id,
    required this.type,
    required this.status,
    required this.time,
    this.office,
    this.source,
  });

  final int id;

  /// `in` or `out` — decided by the server from what is already on record, not
  /// by the app. A stale screen therefore cannot post the wrong direction.
  final String type;

  /// `ontime`, `late` or `early_leave`, measured against the rostered shift.
  final String status;

  /// Pre-formatted by the server in the company timezone, e.g. "04:57 PM".
  final String time;
  final String? office;
  final String? source;

  bool get isIn => type == 'in';

  factory Punch.fromJson(Map<String, dynamic> j) => Punch(
        id: _toInt(j['id']),
        type: '${j['type'] ?? ''}',
        status: '${j['status'] ?? ''}',
        time: '${j['time'] ?? ''}',
        office: _str(j['office']),
        source: _str(j['source']),
      );
}

class ShiftInfo {
  ShiftInfo({
    required this.name,
    required this.startTime,
    required this.endTime,
    this.lateGraceMinutes,
    this.crossesMidnight = false,
  });

  final String name;
  final String startTime;
  final String endTime;
  final int? lateGraceMinutes;
  final bool crossesMidnight;

  factory ShiftInfo.fromJson(Map<String, dynamic> j) => ShiftInfo(
        name: '${j['name'] ?? ''}',
        startTime: '${j['start_time'] ?? ''}',
        endTime: '${j['end_time'] ?? ''}',
        lateGraceMinutes: j['late_grace_minutes'] is num
            ? (j['late_grace_minutes'] as num).toInt()
            : null,
        crossesMidnight: j['crosses_midnight'] == true,
      );

  /// "09:00:00" reads badly on a card; "09:00" does.
  String get window => '${_hhmm(startTime)} – ${_hhmm(endTime)}';

  static String _hhmm(String t) {
    final parts = t.split(':');
    return parts.length >= 2 ? '${parts[0]}:${parts[1]}' : t;
  }
}

class TodayStatus {
  TodayStatus({
    required this.date,
    required this.timezone,
    required this.nextAction,
    required this.canCheck,
    required this.isClockedIn,
    required this.workedMinutes,
    required this.punches,
    this.shift,
    required this.isDayOff,
    this.holiday,
    this.leave,
  });

  /// The day a punch made *now* counts against. On a shift crossing midnight
  /// this is still yesterday, matching how the punch is filed.
  final String date;
  final String timezone;

  /// `in` or `out` — what the button should say.
  final String nextAction;

  /// False only while the duplicate cooldown runs. Grey the button rather than
  /// letting a tap fail.
  final bool canCheck;

  final bool isClockedIn;
  final int workedMinutes;
  final List<Punch> punches;
  final ShiftInfo? shift;
  final bool isDayOff;
  final String? holiday;

  /// Set does *not* disable the button. Somebody who booked the day off and
  /// came in anyway worked, and the record has to say so.
  final String? leave;

  bool get willClockIn => nextAction == 'in';

  factory TodayStatus.fromJson(Map<String, dynamic> j) => TodayStatus(
        date: '${j['date'] ?? ''}',
        timezone: '${j['timezone'] ?? 'UTC'}',
        nextAction: '${j['next_action'] ?? 'in'}',
        canCheck: j['can_check'] != false,
        isClockedIn: j['is_clocked_in'] == true,
        workedMinutes: _toInt(j['worked_minutes']),
        punches: ((j['punches'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(Punch.fromJson)
            .toList(),
        shift: j['shift'] is Map<String, dynamic>
            ? ShiftInfo.fromJson(j['shift'] as Map<String, dynamic>)
            : null,
        isDayOff: j['is_day_off'] == true,
        holiday: _str(j['holiday']),
        leave: _str(j['leave']),
      );
}

class HistoryDay {
  HistoryDay({
    required this.date,
    required this.weekday,
    required this.status,
    required this.late,
    required this.workedMinutes,
    required this.punches,
    this.firstIn,
    this.lastOut,
    this.holiday,
  });

  final String date;
  final String weekday;

  /// present · leave · holiday · day_off · weekend · absent
  final String status;
  final bool late;
  final int workedMinutes;
  final int punches;
  final String? firstIn;
  final String? lastOut;
  final String? holiday;

  factory HistoryDay.fromJson(Map<String, dynamic> j) => HistoryDay(
        date: '${j['date'] ?? ''}',
        weekday: '${j['weekday'] ?? ''}',
        status: '${j['status'] ?? ''}',
        late: j['late'] == true,
        workedMinutes: _toInt(j['worked_minutes']),
        punches: _toInt(j['punches']),
        firstIn: _str(j['first_in']),
        lastOut: _str(j['last_out']),
        holiday: _str(j['holiday']),
      );
}

class HistoryTotals {
  HistoryTotals({
    required this.presentDays,
    required this.lateDays,
    required this.leaveDays,
    required this.absentDays,
    required this.workedMinutes,
  });

  final int presentDays;
  final int lateDays;
  final int leaveDays;
  final int absentDays;
  final int workedMinutes;

  factory HistoryTotals.fromJson(Map<String, dynamic> j) => HistoryTotals(
        presentDays: _toInt(j['present_days']),
        lateDays: _toInt(j['late_days']),
        leaveDays: _toInt(j['leave_days']),
        absentDays: _toInt(j['absent_days']),
        workedMinutes: _toInt(j['worked_minutes']),
      );
}

// ---------------------------------------------------------------------------
// Leave
// ---------------------------------------------------------------------------

class LeaveBalance {
  LeaveBalance({
    required this.leaveTypeId,
    required this.name,
    required this.code,
    required this.colorHex,
    required this.isPaid,
    required this.allowHalfDay,
    required this.entitledDays,
    required this.usedDays,
    required this.availableDays,
    required this.isCapped,
  });

  final int leaveTypeId;
  final String name;
  final String code;
  final String? colorHex;
  final bool isPaid;
  final bool allowHalfDay;
  final double entitledDays;
  final double usedDays;
  final double availableDays;

  /// A type granting zero days is *uncapped*, not exhausted — that is how
  /// unpaid leave is set up. Never grey it out or show "0 days left".
  final bool isCapped;

  factory LeaveBalance.fromJson(Map<String, dynamic> j) => LeaveBalance(
        leaveTypeId: _toInt(j['leave_type_id']),
        name: '${j['name'] ?? ''}',
        code: '${j['code'] ?? ''}',
        colorHex: _str(j['color']),
        isPaid: j['is_paid'] == true,
        allowHalfDay: j['allow_half_day'] == true,
        entitledDays: _toDouble(j['entitled_days']),
        usedDays: _toDouble(j['used_days']),
        availableDays: _toDouble(j['available_days']),
        isCapped: j['is_capped'] == true,
      );
}

class LeaveRequest {
  LeaveRequest({
    required this.id,
    required this.leaveType,
    required this.startDate,
    required this.endDate,
    required this.days,
    required this.isHalfDay,
    required this.status,
    required this.stage,
    required this.canCancel,
    this.reason,
    this.decisionNote,
    this.managerNote,
  });

  final int id;
  final String leaveType;
  final String startDate;
  final String endDate;
  final double days;
  final bool isHalfDay;

  /// pending · approved · rejected · cancelled
  final String status;

  /// What to show somebody chasing a decision: "Awaiting Manager",
  /// "Awaiting HR", or the final status. "Pending" alone does not say who to ask.
  final String stage;

  final bool canCancel;
  final String? reason;
  final String? decisionNote;
  final String? managerNote;

  factory LeaveRequest.fromJson(Map<String, dynamic> j) => LeaveRequest(
        id: _toInt(j['id']),
        leaveType: '${j['leave_type'] ?? ''}',
        startDate: '${j['start_date'] ?? ''}',
        endDate: '${j['end_date'] ?? ''}',
        days: _toDouble(j['days']),
        isHalfDay: j['is_half_day'] == true,
        status: '${j['status'] ?? ''}',
        stage: '${j['stage'] ?? ''}',
        canCancel: j['can_cancel'] == true,
        reason: _str(j['reason']),
        decisionNote: _str(j['decision_note']),
        managerNote: _str(j['manager_note']),
      );
}

class LeaveClash {
  LeaveClash({required this.employee, required this.startDate, required this.endDate});

  final String employee;
  final String startDate;
  final String endDate;

  factory LeaveClash.fromJson(Map<String, dynamic> j) => LeaveClash(
        employee: '${j['employee'] ?? ''}',
        startDate: '${j['start_date'] ?? ''}',
        endDate: '${j['end_date'] ?? ''}',
      );
}

class PendingApproval {
  PendingApproval({
    required this.id,
    required this.employee,
    required this.leaveType,
    required this.startDate,
    required this.endDate,
    required this.days,
    required this.clashes,
    this.reason,
  });

  final int id;
  final String employee;
  final String leaveType;
  final String startDate;
  final String endDate;
  final double days;

  /// Who else on the team is already off over the same dates. Shown *before*
  /// the approve button, not after.
  final List<LeaveClash> clashes;
  final String? reason;

  factory PendingApproval.fromJson(Map<String, dynamic> j) => PendingApproval(
        id: _toInt(j['id']),
        employee: '${j['employee'] ?? ''}',
        leaveType: '${j['leave_type'] ?? ''}',
        startDate: '${j['start_date'] ?? ''}',
        endDate: '${j['end_date'] ?? ''}',
        days: _toDouble(j['days']),
        clashes: ((j['clashes'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(LeaveClash.fromJson)
            .toList(),
        reason: _str(j['reason']),
      );
}

// ---------------------------------------------------------------------------
// Schedule
// ---------------------------------------------------------------------------

class ScheduleDay {
  ScheduleDay({
    required this.date,
    required this.weekday,
    this.shift,
    required this.isDayOff,
    required this.isRostered,
    required this.isWorkingDay,
    this.holiday,
    this.leave,
  });

  final String date;
  final String weekday;

  /// Null on weekends and holidays unless somebody was explicitly rostered —
  /// the standing shift does not leak onto days the company does not work.
  final ShiftInfo? shift;

  /// A *planned* day with no hours, which is not the same as a day nobody
  /// planned at all.
  final bool isDayOff;

  /// Distinguishes a published roster day from the standing shift filling in.
  final bool isRostered;

  final bool isWorkingDay;
  final String? holiday;

  /// Approved leave only. A pending request is not time off yet.
  final String? leave;

  factory ScheduleDay.fromJson(Map<String, dynamic> j) => ScheduleDay(
        date: '${j['date'] ?? ''}',
        weekday: '${j['weekday'] ?? ''}',
        shift: j['shift'] is Map<String, dynamic>
            ? ShiftInfo.fromJson(j['shift'] as Map<String, dynamic>)
            : null,
        isDayOff: j['is_day_off'] == true,
        isRostered: j['is_rostered'] == true,
        isWorkingDay: j['is_working_day'] == true,
        holiday: _str(j['holiday']),
        leave: _str(j['leave']),
      );
}

// ---------------------------------------------------------------------------
// Team (manager)
// ---------------------------------------------------------------------------

class TeamSummary {
  TeamSummary({
    required this.total,
    required this.present,
    required this.inNow,
    required this.late,
    required this.onLeave,
    required this.absent,
    required this.off,
  });

  final int total;

  /// Turned up at some point today.
  final int present;

  /// On the floor right now. Not the same number, and the distinction is the
  /// whole point of the endpoint.
  final int inNow;

  final int late;
  final int onLeave;
  final int absent;
  final int off;

  factory TeamSummary.fromJson(Map<String, dynamic> j) => TeamSummary(
        total: _toInt(j['total']),
        present: _toInt(j['present']),
        inNow: _toInt(j['in_now']),
        late: _toInt(j['late']),
        onLeave: _toInt(j['on_leave']),
        absent: _toInt(j['absent']),
        off: _toInt(j['off']),
      );
}

class TeamMember {
  TeamMember({
    required this.employeeId,
    required this.name,
    required this.employeeCode,
    required this.status,
    required this.late,
    required this.isClockedIn,
    required this.workedMinutes,
    this.firstIn,
    this.lastOut,
    this.shift,
  });

  final int employeeId;
  final String name;
  final String employeeCode;
  final String status;
  final bool late;
  final bool isClockedIn;
  final int workedMinutes;
  final String? firstIn;
  final String? lastOut;
  final ShiftInfo? shift;

  factory TeamMember.fromJson(Map<String, dynamic> j) => TeamMember(
        employeeId: _toInt(j['employee_id']),
        name: '${j['name'] ?? ''}',
        employeeCode: '${j['employee_code'] ?? ''}',
        status: '${j['status'] ?? ''}',
        late: j['late'] == true,
        isClockedIn: j['is_clocked_in'] == true,
        workedMinutes: _toInt(j['worked_minutes']),
        firstIn: _str(j['first_in']),
        lastOut: _str(j['last_out']),
        shift: j['shift'] is Map<String, dynamic>
            ? ShiftInfo.fromJson(j['shift'] as Map<String, dynamic>)
            : null,
      );
}

/// One person's rostered week, as `/team/roster` returns it (B7.3).
///
/// Employee-major to match the endpoint: a manager reads down a person to see
/// their week. The across-a-day view is what the "In today" tab already gives.
class TeamRosterMember {
  TeamRosterMember({
    required this.employeeId,
    required this.name,
    required this.employeeCode,
    required this.schedule,
  });

  final int employeeId;
  final String name;
  final String employeeCode;
  final List<TeamRosterDay> schedule;

  factory TeamRosterMember.fromJson(Map<String, dynamic> j) => TeamRosterMember(
        employeeId: _toInt(j['employee_id']),
        name: '${j['name'] ?? ''}',
        employeeCode: '${j['employee_code'] ?? ''}',
        schedule: ((j['schedule'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(TeamRosterDay.fromJson)
            .toList(),
      );
}

class TeamRosterDay {
  TeamRosterDay({
    required this.date,
    required this.status,
    required this.isRostered,
    this.shift,
    this.holiday,
  });

  final String date;

  /// One of working, leave, holiday, day_off, weekend.
  final String status;

  /// A day explicitly placed on the roster, as opposed to one falling back to
  /// the person's standing shift. Both are "working"; only the first was a
  /// decision somebody made.
  final bool isRostered;

  final ShiftInfo? shift;
  final String? holiday;

  bool get isWorking => status == 'working';

  factory TeamRosterDay.fromJson(Map<String, dynamic> j) => TeamRosterDay(
        date: '${j['date'] ?? ''}',
        status: '${j['status'] ?? ''}',
        isRostered: j['is_rostered'] == true,
        shift: j['shift'] is Map<String, dynamic>
            ? ShiftInfo.fromJson(j['shift'] as Map<String, dynamic>)
            : null,
        holiday: _str(j['holiday']),
      );
}
