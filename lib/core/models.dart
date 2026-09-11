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

import '../l10n/generated/app_localizations.dart';

// For PushRoute. A notification in the history points at the same tabs a push
// does, and parsing it through the same enum is what keeps the two in step.
import 'push.dart';

/// What a punch type is called on screen, in one place (B6.2).
///
/// Two models carry a punch type and both used to spell these out, which is two
/// places for a break to end up worded differently. A type this build has not
/// heard of falls through to the server's own key rather than to nothing.
String punchTypeLabel(AppLocalizations t, String type) => switch (type) {
      'in' => t.punchCheckedIn,
      'out' => t.punchCheckedOut,
      'break_start' => t.punchBreakStarted,
      'break_end' => t.punchBackFromBreak,
      _ => type,
    };

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

  /// Holds the permission the manager endpoints are gated on.
  ///
  /// Not sufficient on its own to show the Team tab — see [leadsATeam]. **HR
  /// holds this too**, because HR is the second step of the approval chain on
  /// the web.
  bool get canApproveLeave => permissions.contains('approve-leave');

  /// The gate for the Team tab: the permission **and** somebody to use it on.
  ///
  /// "manager is a role *and* a relationship, and both must line up" — the
  /// permission opens the endpoints, `employees.manager_id` decides whose
  /// records they return. The tab used to hang off the permission alone, which
  /// gave a Team tab to every HR user and to any manager with nobody reporting
  /// to them; every screen behind it then came back empty, for ever, with
  /// nothing on it explaining why.
  ///
  /// On the web the two never met, because `/manager/*` is gated `role:manager`
  /// as well and refuses HR at the door. The app had no equivalent, so it
  /// advertised an area that could not do anything.
  bool get leadsATeam => canApproveLeave && employee?.isManager == true;

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

  /// `in`, `out`, `break_start` or `break_end` — decided by the server from what
  /// is already on record, not by the app. A stale screen therefore cannot post
  /// the wrong direction.
  ///
  /// **There are four of these, not two.** Anything that branches on `isIn`
  /// alone reads a break as a departure; the server made exactly that mistake
  /// in `/attendance/today` and offered "Check In" to somebody who had never
  /// left. Use [label] rather than a ternary.
  final String type;

  /// `ontime`, `late` or `early_leave`, measured against the rostered shift.
  /// Always `ontime` on a break — there is nothing to judge one against.
  final String status;

  /// Pre-formatted by the server in the company timezone, e.g. "04:57 PM".
  final String time;
  final String? office;
  final String? source;

  bool get isIn => type == 'in';
  bool get isBreak => type == 'break_start' || type == 'break_end';

  /// What this punch is called on screen. One definition, so a break cannot be
  /// worded two ways on two lists.
  String label(AppLocalizations t) => punchTypeLabel(t, type);

  factory Punch.fromJson(Map<String, dynamic> j) => Punch(
        id: _toInt(j['id']),
        type: '${j['type'] ?? ''}',
        status: '${j['status'] ?? ''}',
        time: '${j['time'] ?? ''}',
        office: _str(j['office']),
        source: _str(j['source']),
      );
}

/// A colleague in the staff directory (B3.8).
///
/// The only model in the app describing **somebody else**, and so the thinnest.
/// Date of birth, address, national id, personal email, emergency contact and
/// the reporting line are not in the payload at any policy setting — a manager
/// does not see those for their own team, and a colleague cannot see more than
/// a manager.
class DirectoryPerson {
  DirectoryPerson({
    required this.id,
    required this.employeeCode,
    required this.fullName,
    this.designation,
    this.department,
    this.office,
    this.workMode,
    this.photoUrl,
    this.email,
    this.phone,
  });

  final int id;
  final String employeeCode;
  final String fullName;
  final String? designation;
  final String? department;
  final String? office;
  final String? workMode;
  final String? photoUrl;

  /// Both null unless the company has switched `directory_show_contact_details`
  /// on. Read the list's `shows_contact_details` to tell "the company withholds
  /// this" from "this person has none on file" — see [Directory].
  final String? email;
  final String? phone;

  String get initials {
    final parts = fullName.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters1();
    return '${parts.first.characters1()}${parts.last.characters1()}';
  }

  factory DirectoryPerson.fromJson(Map<String, dynamic> j) => DirectoryPerson(
        id: _toInt(j['id']),
        employeeCode: '${j['employee_code'] ?? ''}',
        fullName: '${j['full_name'] ?? ''}',
        designation: _str(j['designation']),
        department: _str(j['department']),
        office: _str(j['office']),
        workMode: _str(j['work_mode']),
        photoUrl: _str(j['photo_url']),
        email: _str(j['email']),
        phone: _str(j['phone']),
      );
}

/// One page of the directory, and whether this company shares contact details.
class Directory {
  Directory({
    required this.people,
    required this.showsContactDetails,
    required this.lastPage,
    required this.currentPage,
  });

  final List<DirectoryPerson> people;

  /// Stated by the server rather than inferred from absent keys. The app has to
  /// tell a company that withholds contact details from a colleague who simply
  /// has none on file, so it can hide a call button instead of drawing a dead
  /// one.
  final bool showsContactDetails;

  final int lastPage;
  final int currentPage;

  bool get hasMore => currentPage < lastPage;

  factory Directory.fromJson(Map<String, dynamic> j) {
    final meta = (j['meta'] as Map<String, dynamic>?) ?? const {};

    return Directory(
      people: ((j['people'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(DirectoryPerson.fromJson)
          .toList(),
      showsContactDetails: j['shows_contact_details'] == true,
      currentPage: _toInt(meta['current_page']),
      lastPage: _toInt(meta['last_page']),
    );
  }
}

/// A request to have the attendance record corrected (B3.9 / A4.13).
///
/// **Raising only from the app.** Deciding one voids a punch and writes a
/// replacement, which is HR's and stays on the web — a manager has no step in
/// this chain, unlike leave.
class Regularisation {
  Regularisation({
    required this.id,
    required this.type,
    required this.workDate,
    required this.requestedAt,
    required this.reason,
    required this.status,
    required this.challengesAPunch,
    required this.canCancel,
    this.attendanceLogId,
    this.decisionNote,
    this.decidedBy,
  });

  final int id;

  /// `in` or `out` — what the corrected punch should be. Breaks are not
  /// correctable: there is no shift to judge one against.
  final String type;

  final String workDate;
  final String requestedAt;
  final String reason;

  /// `pending`, `approved`, `rejected` or `cancelled`.
  final String status;

  /// True when this disputes an existing reading rather than reporting a
  /// missing one. Sent by the server so the two are not worded differently in
  /// two places.
  final bool challengesAPunch;

  final bool canCancel;
  final int? attendanceLogId;
  final String? decisionNote;

  /// Recorded on the row at the moment of the decision, so it still reads
  /// correctly after that HR account is deleted.
  final String? decidedBy;

  bool get isPending => status == 'pending';

  String typeLabel(AppLocalizations t) =>
      type == 'in' ? t.punchCheckIn : t.punchCheckOut;

  /// One phrase for what this request is about, lower case.
  ///
  /// Four separate messages rather than "disputing a " plus a punch name:
  /// Spanish does not put the two together in that order, and lower-casing an
  /// assembled English sentence is not a translation strategy.
  String summary(AppLocalizations t) => switch ((challengesAPunch, type)) {
        (true, 'in') => t.correctionsDisputing,
        (true, _) => t.correctionsDisputingOut,
        (false, 'in') => t.correctionsMissingIn,
        (false, _) => t.correctionsMissingOut,
      };

  factory Regularisation.fromJson(Map<String, dynamic> j) => Regularisation(
        id: _toInt(j['id']),
        type: '${j['type'] ?? ''}',
        workDate: '${j['work_date'] ?? ''}',
        requestedAt: '${j['requested_at'] ?? ''}',
        reason: '${j['reason'] ?? ''}',
        status: '${j['status'] ?? 'pending'}',
        challengesAPunch: j['challenges_a_punch'] == true,
        canCancel: j['can_cancel'] == true,
        attendanceLogId: j['attendance_log_id'] is num
            ? (j['attendance_log_id'] as num).toInt()
            : null,
        decisionNote: _str(j['decision_note']),
        decidedBy: _str(j['decided_by']),
      );
}

/// One of the caller's recent punches, offered for dispute.
///
/// Shipped with the regularisation list rather than fetched separately:
/// `/attendance/history` answers in day-shaped rows and carries no punch ids,
/// so without these the app cannot name the reading it is disputing.
class DisputablePunch {
  DisputablePunch({
    required this.id,
    required this.type,
    required this.workDate,
    required this.time,
    this.office,
  });

  final int id;
  final String type;
  final String workDate;
  final String time;
  final String? office;

  String label(AppLocalizations t) => punchTypeLabel(t, type);

  /// Only in and out can be corrected — `recordManual` has nothing to write for
  /// a break, and a break has no shift to be judged against.
  bool get isCorrectable => type == 'in' || type == 'out';

  factory DisputablePunch.fromJson(Map<String, dynamic> j) => DisputablePunch(
        id: _toInt(j['id']),
        type: '${j['type'] ?? ''}',
        workDate: '${j['work_date'] ?? ''}',
        time: '${j['time'] ?? ''}',
        office: _str(j['office']),
      );
}

/// A document HR has filed against this employee (B3.7).
///
/// Read-only from the app's side. `notes` and the uploader are not in the
/// payload at all — notes is where HR records why something is being chased,
/// and the employee is the subject of that commentary rather than its reader.
class EmployeeDocument {
  EmployeeDocument({
    required this.id,
    required this.type,
    required this.typeLabel,
    required this.title,
    required this.originalName,
    required this.sizeLabel,
    required this.expiryState,
    this.mimeType,
    this.issuedOn,
    this.expiresOn,
  });

  final int id;
  final String type;
  final String typeLabel;
  final String title;
  final String originalName;
  final String sizeLabel;

  /// `none`, `valid`, `soon` or `expired` — the same four the web badge uses,
  /// so one document cannot read as expiring on a phone and fine on a desk.
  final String expiryState;

  final String? mimeType;
  final String? issuedOn;
  final String? expiresOn;

  bool get hasExpired => expiryState == 'expired';
  bool get expiresSoon => expiryState == 'soon';

  factory EmployeeDocument.fromJson(Map<String, dynamic> j) => EmployeeDocument(
        id: _toInt(j['id']),
        type: '${j['type'] ?? ''}',
        typeLabel: '${j['type_label'] ?? j['type'] ?? 'Document'}',
        title: '${j['title'] ?? ''}',
        originalName: '${j['original_name'] ?? ''}',
        sizeLabel: '${j['size_label'] ?? ''}',
        expiryState: '${j['expiry_state'] ?? 'none'}',
        mimeType: _str(j['mime_type']),
        issuedOn: _str(j['issued_on']),
        expiresOn: _str(j['expires_on']),
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
    this.onBreak = false,
    this.canBreak = false,
    this.nextBreakAction = 'start',
    this.breakStartedAt,
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

  /// Currently on a break. `isClockedIn` stays true throughout — the person has
  /// not gone home, and `workedMinutes` has already had the break taken off.
  final bool onBreak;

  /// True only on the clock and outside the cooldown. `recordBreak` refuses a
  /// break in any other state, so grey the button rather than let the tap fail.
  final bool canBreak;

  /// `start` or `end` — what the break button should say. Kept apart from
  /// [nextAction], which belongs to the in/out button: one screen carries both
  /// and they move independently.
  final String nextBreakAction;

  /// Set only while [onBreak]. ISO 8601 with the company's offset.
  final String? breakStartedAt;

  bool get willClockIn => nextAction == 'in';
  bool get willStartBreak => nextBreakAction == 'start';

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
        onBreak: j['on_break'] == true,
        // Defaults to false, not true: a build talking to a server from before
        // the break endpoint existed gets no button rather than one that 404s.
        canBreak: j['can_break'] == true,
        nextBreakAction: '${j['next_break_action'] ?? 'start'}',
        breakStartedAt: _str(j['break_started_at']),
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

/// The personal attendance score and on-time streak (B3.5).
///
/// Two numbers with deliberately different shapes, and the difference is worth
/// keeping straight when reading this: [score] answers for the window on
/// screen and is computed by the server from the very rows below it, while
/// [streak] ignores the window entirely — "eleven days" has to mean eleven
/// days, not eleven of the last thirty.
class AttendanceScore {
  AttendanceScore({
    required this.ontimeDays,
    required this.obligedDays,
    required this.streak,
    this.score,
  });

  /// Percent, 0–100, or **null when nobody was expected in** — a window of
  /// weekends, or a fortnight of booked leave. Null is not zero: zero would
  /// read as a failure, and the screen shows no score at all instead.
  final int? score;

  /// Days in the window they made on time.
  final int ontimeDays;

  /// Days in the window they were meant to be here at all. The denominator,
  /// and the number that makes the score explicable rather than magic.
  final int obligedDays;

  /// Consecutive days arrived on time, counting back from today. Weekends,
  /// holidays and booked leave neither break it nor extend it.
  final int streak;

  bool get hasScore => score != null;

  factory AttendanceScore.fromJson(Map<String, dynamic> j) => AttendanceScore(
        // Absent or null both mean "no score", which is a real answer here.
        score: j['score'] == null ? null : _toInt(j['score']),
        ontimeDays: _toInt(j['ontime_days']),
        obligedDays: _toInt(j['obliged_days']),
        streak: _toInt(j['streak']),
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

/// One row in the notification history (B5.6).
///
/// The server publishes only the four keys every notification class agrees on,
/// plus a route derived from the type — the stored payload also holds a **web**
/// URL and per-class extras, and neither is any use here. That is what keeps a
/// new notification type on the server from being a client change.
class AppNotification {
  AppNotification({
    required this.id,
    required this.title,
    required this.createdAt,
    this.type,
    this.body,
    this.route,
    this.readAt,
  });

  /// A UUID. The server's, and what `POST /notifications/{id}/read` takes.
  final String id;

  final String title;

  /// ISO 8601 with the company's offset, like every other timestamp here.
  final String createdAt;

  /// `leave.approved`, `attendance.missing_checkout`, and so on. Shown to
  /// nobody — it picks the icon.
  final String? type;

  final String? body;

  /// Where in the app this points, if anywhere. Null for a notification
  /// addressed to somebody at a desk — a document-expiry warning has no screen
  /// here, and inventing one to open would be worse than opening nothing.
  final PushRoute? route;

  final String? readAt;

  bool get isUnread => readAt == null;

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: '${j['id'] ?? ''}',
        // Empty rather than an English fallback: the screen supplies the word
        // for a notification the server did not title, in the right language.
        title: '${j['title'] ?? ''}',
        createdAt: '${j['created_at'] ?? ''}',
        type: _str(j['type']),
        body: _str(j['body']),
        // Parsed through the same enum a push tap goes through, so a route
        // this build has never heard of is null rather than a crash.
        route: PushRoute.parse(j['route']),
        readAt: _str(j['read_at']),
      );
}
