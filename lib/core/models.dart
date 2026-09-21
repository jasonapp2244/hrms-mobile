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

import 'dart:math' as math;

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

/// What the signed-in account may do, as the **server** decides it.
///
/// Every one of these could be worked out from `permissions`, and for a while
/// one of them was: `leadsATeam` is `approve-leave` plus a direct report,
/// because the permission alone gave a permanently empty Team tab to every HR
/// user. That rule then existed in two languages, and the HR section would have
/// made it three — each free to drift from the route group it is supposed to
/// describe.
///
/// So the server states the conclusion and the app reads it. A capability is a
/// promise that the matching endpoints will answer, which is what a tab
/// actually needs to know; a permission is only an input to that question.
///
/// **Absent for an older server**, which is why every field has a fallback at
/// the call site rather than defaulting to true here. A build that cannot tell
/// should show less, not more.
class Capabilities {
  const Capabilities({
    required this.leadTeam,
    required this.decideLeave,
    required this.viewEmployees,
  });

  /// The Team tab — a line manager with somebody reporting to them.
  final bool leadTeam;

  /// The HR leave desk: the final, company-wide decision that spends the days.
  /// `manage-leave` **and** `approve-leave`, matching the route group.
  final bool decideLeave;

  /// The employee register. Read-only on the phone.
  final bool viewEmployees;

  bool get anyHrArea => decideLeave || viewEmployees;

  factory Capabilities.fromJson(Map<String, dynamic> j) => Capabilities(
        leadTeam: j['lead_team'] == true,
        decideLeave: j['decide_leave'] == true,
        viewEmployees: j['view_employees'] == true,
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
    this.can,
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

  /// What the server says this account may do. Null against an older build of
  /// the API, which is why each getter below falls back rather than assuming.
  final Capabilities? can;

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
  /// Read from the server, with the old derivation as the fallback.
  ///
  /// The rule has not changed — the permission **and** somebody to use it on —
  /// only where it is decided. An app talking to a server that predates the
  /// `can` block still works it out locally; one talking to a current server
  /// takes the answer, so the tab and the route group cannot disagree.
  bool get leadsATeam =>
      can?.leadTeam ?? (canApproveLeave && employee?.isManager == true);

  /// The HR leave desk — the final, company-wide decision.
  ///
  /// **No local fallback, deliberately.** This one spends leave balance, and
  /// an app that cannot ask the server whether it may must not decide for
  /// itself that it may. An older server simply has no HR section.
  bool get decidesLeave => can?.decideLeave ?? false;

  /// The employee register. Read-only, and the same rule as above.
  bool get viewsEmployees => can?.viewEmployees ?? false;

  /// Whether to draw the HR tab at all.
  bool get hasHrArea => decidesLeave || viewsEmployees;

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
        can: j['can'] is Map<String, dynamic>
            ? Capabilities.fromJson(j['can'] as Map<String, dynamic>)
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
    this.breakMinutes = 0,
    this.breakIsPaid = false,
    this.breakIsMinimum = false,
  });

  final String name;
  final String startTime;
  final String endTime;
  final int? lateGraceMinutes;
  final bool crossesMidnight;

  /// The shift's break policy (A5.7), for the one screen with a break button.
  ///
  /// Absent from a saved copy taken before the policy shipped, and from the
  /// `/schedule` and `/team/*` payloads, which do not carry it — so these
  /// default to the old behaviour rather than to null, and a screen reading
  /// them shows nothing rather than something wrong.
  final int breakMinutes;
  final bool breakIsPaid;
  final bool breakIsMinimum;

  /// Whether there is anything to say about the break at all.
  bool get hasBreakPolicy => breakMinutes > 0;

  factory ShiftInfo.fromJson(Map<String, dynamic> j) => ShiftInfo(
        name: '${j['name'] ?? ''}',
        startTime: '${j['start_time'] ?? ''}',
        endTime: '${j['end_time'] ?? ''}',
        lateGraceMinutes: j['late_grace_minutes'] is num
            ? (j['late_grace_minutes'] as num).toInt()
            : null,
        crossesMidnight: j['crosses_midnight'] == true,
        breakMinutes: j['break_minutes'] is num
            ? (j['break_minutes'] as num).toInt()
            : 0,
        breakIsPaid: j['break_is_paid'] == true,
        breakIsMinimum: j['break_is_minimum'] == true,
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
    this.geofence,
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

  /// The fence this employee is judged against, or null when none applies
  /// (B2.5).
  ///
  /// **Resolved by the server, never worked out here.** Whether a fence applies
  /// depends on the company policy, the employee's work mode and whether the
  /// office has coordinates at all — three rules the enforcement already owns,
  /// and a second copy in the app would drift the first time one of them
  /// changed. Null means say nothing: a home worker told they are two
  /// kilometres from an office they were instructed not to attend is worse
  /// than no warning at all.
  final Geofence? geofence;

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
        geofence: j['geofence'] is Map<String, dynamic>
            ? Geofence.fromJson(j['geofence'] as Map<String, dynamic>)
            : null,
      );
}

/// Where somebody has to be standing to clock in (B2.5).
///
/// Only ever present when the fence actually applies to the person reading it —
/// see [TodayStatus.geofence].
class Geofence {
  const Geofence({
    required this.office,
    required this.latitude,
    required this.longitude,
    required this.radiusMetres,
  });

  final String office;
  final double latitude;
  final double longitude;
  final int radiusMetres;

  /// Metres between the fence's centre and a point, by the **same haversine on
  /// a spherical earth** the server uses.
  ///
  /// Deliberately the same formula rather than a cleverer one: the app's job
  /// here is to predict the server's answer, and a more accurate distance that
  /// disagreed with the enforcement would be worse than a less accurate one
  /// that matched it. Accurate to a few metres over the distances a fence cares
  /// about, which is well inside the error of the fix itself.
  double metresFrom(double lat, double lng) {
    const earthRadius = 6371000.0;

    final dLat = _radians(lat - latitude);
    final dLng = _radians(lng - longitude);

    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_radians(latitude)) *
            math.cos(_radians(lat)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);

    return earthRadius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  /// True when a fix that far out would be refused by the server.
  bool excludes(double lat, double lng) => metresFrom(lat, lng) > radiusMetres;

  static double _radians(double degrees) => degrees * math.pi / 180;

  factory Geofence.fromJson(Map<String, dynamic> j) => Geofence(
        office: '${j['office'] ?? ''}',
        latitude: _toDouble(j['latitude']),
        longitude: _toDouble(j['longitude']),
        radiusMetres: _toInt(j['radius']),
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
    this.attachmentName,
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

  /// The supporting file's name, or null when there is none (B4.1).
  ///
  /// Taken from `has_attachment` and not from the name alone: a request whose
  /// file has gone missing off the disk still carries the name it was uploaded
  /// under, and a paperclip pointing at nothing is worse than no paperclip.
  final String? attachmentName;

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
        attachmentName:
            j['has_attachment'] == true ? _str(j['attachment_name']) : null,
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
    this.attachmentName,
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

  /// The supporting file's name, or null when there is none (B4.1). Taken from
  /// `has_attachment`, for the reason on [LeaveRequest.attachmentName].
  final String? attachmentName;

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
        attachmentName:
            j['has_attachment'] == true ? _str(j['attachment_name']) : null,
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

/// Who on the team is off, a month at a time (B4.6).
///
/// Date-major, the opposite of [TeamRosterMember] — this answers "can I let a
/// second person go that week", which is a question about a day rather than
/// about a person.
class TeamLeaveMonth {
  TeamLeaveMonth({
    required this.month,
    required this.today,
    required this.teamSize,
    required this.days,
  });

  /// `YYYY-MM`, as the server named it.
  final String month;

  /// The **company's** today, for marking the current cell. Never the
  /// handset's: the phone is wherever its owner is standing.
  final String today;

  final int teamSize;
  final List<TeamLeaveDay> days;

  factory TeamLeaveMonth.fromJson(Map<String, dynamic> j) => TeamLeaveMonth(
        month: '${j['month'] ?? ''}',
        today: '${j['today'] ?? ''}',
        teamSize: _toInt(j['team_size']),
        days: ((j['days'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(TeamLeaveDay.fromJson)
            .toList(),
      );

  /// Nobody off all month — which is an ordinary answer, not an empty state.
  bool get isQuiet => days.every((d) => d.people.isEmpty);
}

/// One cell of the month grid. Present even when nobody is off, because the
/// weekend and holiday facts belong to the day rather than to the leave.
class TeamLeaveDay {
  TeamLeaveDay({
    required this.date,
    required this.isWeekend,
    required this.people,
    this.holiday,
  });

  final String date;
  final bool isWeekend;
  final String? holiday;
  final List<TeamLeavePerson> people;

  /// The day of the month, for the grid's numeral.
  int get dayOfMonth => int.tryParse(date.split('-').last) ?? 0;

  factory TeamLeaveDay.fromJson(Map<String, dynamic> j) => TeamLeaveDay(
        date: '${j['date'] ?? ''}',
        isWeekend: j['weekend'] == true,
        holiday: _str(j['holiday']),
        people: ((j['people'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(TeamLeavePerson.fromJson)
            .toList(),
      );
}

/// One person's leave, as it falls on one day of the grid.
///
/// [startDate] and [endDate] name the whole request rather than this day, so a
/// tap can say "29 Jul – 3 Aug" without a second call — a stretch that began
/// last month still reads correctly on the 1st.
class TeamLeavePerson {
  TeamLeavePerson({
    required this.employeeId,
    required this.name,
    required this.status,
    required this.isHalfDay,
    required this.startDate,
    required this.endDate,
    this.leaveType,
  });

  final int employeeId;
  final String name;

  /// `approved` or `pending`, and nothing else is sent. Pending is drawn
  /// alongside approved on purpose: a month showing only what is already
  /// granted is a month a manager can approve a second person onto.
  final String status;

  final bool isHalfDay;
  final String startDate;
  final String endDate;
  final String? leaveType;

  bool get isPending => status == 'pending';

  /// True when the whole request is this one day, which is what decides
  /// whether the dates are worth printing at all.
  bool get isSingleDay => startDate == endDate;

  factory TeamLeavePerson.fromJson(Map<String, dynamic> j) => TeamLeavePerson(
        employeeId: _toInt(j['employee_id']),
        name: '${j['name'] ?? ''}',
        status: '${j['status'] ?? ''}',
        isHalfDay: j['is_half_day'] == true,
        startDate: '${j['start_date'] ?? ''}',
        endDate: '${j['end_date'] ?? ''}',
        leaveType: _str(j['leave_type']),
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

// ---------------------------------------------------------------------------
// HR (client requirement, 2026-09-22)
//
// The second decision surface, not a copy of the manager's. `PendingApproval`
// above is the *manager* step — approving it passes a request up and spends
// nothing. Everything below belongs to the step that commits the days, which
// is why it carries a balance and the manager's own note: HR is deciding on
// somebody a manager has already seconded, and needs to know both.
// ---------------------------------------------------------------------------

/// What is left of one leave type, for one person, this year.
///
/// [capped] is sent separately rather than inferred from [available] being
/// zero: an uncapped type has no meaningful "available", and reading a zero
/// there as "none left" would refuse leave nobody is short of.
class HrBalance {
  const HrBalance({
    required this.entitled,
    required this.used,
    required this.available,
    required this.capped,
    this.leaveType,
    this.carried = 0,
    this.wouldExceed = false,
  });

  final double entitled;
  final double carried;
  final double used;
  final double available;
  final bool capped;

  /// Null on the balance attached to a pending request, which is already
  /// labelled by the request's own leave type.
  final String? leaveType;

  /// The server making the same comparison `approve()` will make, up front.
  /// Finding out after the tap is the web's behaviour; a phone should say so
  /// before somebody commits to it.
  final bool wouldExceed;

  factory HrBalance.fromJson(Map<String, dynamic> j) => HrBalance(
        leaveType: _str(j['leave_type']),
        entitled: _toDouble(j['entitled']),
        carried: _toDouble(j['carried']),
        used: _toDouble(j['used']),
        available: _toDouble(j['available']),
        capped: j['capped'] == true,
        wouldExceed: j['would_exceed'] == true,
      );
}

/// One request sitting with HR for the final decision.
class HrPendingLeave {
  const HrPendingLeave({
    required this.id,
    required this.employee,
    required this.leaveType,
    required this.startDate,
    required this.endDate,
    required this.days,
    required this.isHalfDay,
    required this.clashes,
    this.employeeCode,
    this.department,
    this.office,
    this.reason,
    this.attachmentName,
    this.managerApprovedBy,
    this.managerNote,
    this.balance,
  });

  final int id;
  final String employee;
  final String leaveType;
  final String startDate;
  final String endDate;
  final double days;
  final bool isHalfDay;
  final String? employeeCode;
  final String? department;
  final String? office;
  final String? reason;

  /// Null when the file is gone from disk even though the name survives — the
  /// same rule `LeaveRequest` applies, because a paperclip that opens nothing
  /// is worse than no paperclip.
  final String? attachmentName;

  /// Who seconded it at the manager step, and what they said. Both null for an
  /// employee with no line manager, whose request skips that step entirely —
  /// which is an answer rather than a gap.
  final String? managerApprovedBy;
  final String? managerNote;

  final HrBalance? balance;

  /// Who else in the same department is already off over these dates.
  ///
  /// The department rather than the whole company: company-wide would be every
  /// approved day off in the business that week, which is true and unreadable.
  final List<LeaveClash> clashes;

  factory HrPendingLeave.fromJson(Map<String, dynamic> j) => HrPendingLeave(
        id: _toInt(j['id']),
        employee: '${j['employee'] ?? ''}',
        employeeCode: _str(j['employee_code']),
        department: _str(j['department']),
        office: _str(j['office']),
        leaveType: '${j['leave_type'] ?? ''}',
        startDate: '${j['start_date'] ?? ''}',
        endDate: '${j['end_date'] ?? ''}',
        days: _toDouble(j['days']),
        isHalfDay: j['is_half_day'] == true,
        reason: _str(j['reason']),
        attachmentName:
            j['has_attachment'] == true ? _str(j['attachment_name']) : null,
        managerApprovedBy: _str(j['manager_approved_by']),
        managerNote: _str(j['manager_note']),
        balance: j['balance'] is Map<String, dynamic>
            ? HrBalance.fromJson(j['balance'] as Map<String, dynamic>)
            : null,
        clashes: ((j['clashes'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(LeaveClash.fromJson)
            .toList(),
      );
}

/// A request HR has already settled, for the "what did I do yesterday" list.
class HrDecidedLeave {
  const HrDecidedLeave({
    required this.id,
    required this.employee,
    required this.leaveType,
    required this.startDate,
    required this.endDate,
    required this.days,
    required this.status,
    this.decidedBy,
    this.decisionNote,
  });

  final int id;
  final String employee;
  final String leaveType;
  final String startDate;
  final String endDate;
  final double days;

  /// approved · rejected · cancelled
  final String status;
  final String? decidedBy;
  final String? decisionNote;

  factory HrDecidedLeave.fromJson(Map<String, dynamic> j) => HrDecidedLeave(
        id: _toInt(j['id']),
        employee: '${j['employee'] ?? ''}',
        leaveType: '${j['leave_type'] ?? ''}',
        startDate: '${j['start_date'] ?? ''}',
        endDate: '${j['end_date'] ?? ''}',
        days: _toDouble(j['days']),
        status: '${j['status'] ?? ''}',
        decidedBy: _str(j['decided_by']),
        decisionNote: _str(j['decision_note']),
      );
}

/// One row of the employee register.
class HrEmployeeSummary {
  const HrEmployeeSummary({
    required this.id,
    required this.name,
    required this.status,
    this.employeeCode,
    this.department,
    this.designation,
    this.office,
    this.photoUrl,
    this.email,
    this.phone,
  });

  final int id;
  final String name;

  /// active · inactive · terminated. Shown rather than filtered out, because a
  /// register is asked about leavers and a directory is not.
  final String status;

  final String? employeeCode;
  final String? department;
  final String? designation;
  final String? office;
  final String? photoUrl;
  final String? email;
  final String? phone;

  bool get isActive => status == 'active';

  factory HrEmployeeSummary.fromJson(Map<String, dynamic> j) =>
      HrEmployeeSummary(
        id: _toInt(j['id']),
        name: '${j['name'] ?? ''}',
        status: '${j['status'] ?? ''}',
        employeeCode: _str(j['employee_code']),
        department: _str(j['department']),
        designation: _str(j['designation']),
        office: _str(j['office']),
        photoUrl: _str(j['photo_url']),
        email: _str(j['email']),
        phone: _str(j['phone']),
      );
}

/// The last month of attendance, counted rather than listed.
class HrAttendanceSummary {
  const HrAttendanceSummary({
    required this.from,
    required this.to,
    required this.daysWorked,
    required this.late,
    required this.earlyLeave,
    required this.onTime,
  });

  final String from;
  final String to;
  final int daysWorked;
  final int late;
  final int earlyLeave;
  final int onTime;

  factory HrAttendanceSummary.fromJson(Map<String, dynamic> j) =>
      HrAttendanceSummary(
        from: '${j['from'] ?? ''}',
        to: '${j['to'] ?? ''}',
        daysWorked: _toInt(j['days_worked']),
        late: _toInt(j['late']),
        earlyLeave: _toInt(j['early_leave']),
        onTime: _toInt(j['on_time']),
      );
}

/// The full record, as only `manage-employees` may read it.
///
/// Everything the directory deliberately refuses to say. The fields are
/// nullable throughout because a record is filled in over time and a half-empty
/// one is ordinary rather than broken — the screen omits a row instead of
/// printing an em dash under every heading.
class HrEmployeeRecord {
  const HrEmployeeRecord({
    required this.summary,
    required this.balances,
    this.attendance,
    this.dateOfBirth,
    this.gender,
    this.hireDate,
    this.workMode,
    this.personalEmail,
    this.address,
    this.city,
    this.country,
    this.nationalId,
    this.bloodGroup,
    this.emergencyName,
    this.emergencyPhone,
    this.emergencyRelation,
    this.manager,
    this.shift,
    this.hasLogin = false,
    this.loginEmail,
    this.loginActive,
  });

  final HrEmployeeSummary summary;
  final List<HrBalance> balances;
  final HrAttendanceSummary? attendance;

  final String? dateOfBirth;
  final String? gender;
  final String? hireDate;
  final String? workMode;
  final String? personalEmail;
  final String? address;
  final String? city;
  final String? country;
  final String? nationalId;
  final String? bloodGroup;
  final String? emergencyName;
  final String? emergencyPhone;
  final String? emergencyRelation;
  final String? manager;
  final String? shift;

  /// Whether this person can sign in at all — the question HR is asked most
  /// often about somebody who says the app will not let them in. The account
  /// itself is administered on the web.
  final bool hasLogin;
  final String? loginEmail;
  final bool? loginActive;

  factory HrEmployeeRecord.fromJson(Map<String, dynamic> j) {
    final employee = (j['employee'] as Map<String, dynamic>?) ?? const {};
    final emergency =
        (employee['emergency_contact'] as Map<String, dynamic>?) ?? const {};

    return HrEmployeeRecord(
      summary: HrEmployeeSummary.fromJson(employee),
      dateOfBirth: _str(employee['date_of_birth']),
      gender: _str(employee['gender']),
      hireDate: _str(employee['hire_date']),
      workMode: _str(employee['work_mode']),
      personalEmail: _str(employee['personal_email']),
      address: _str(employee['address']),
      city: _str(employee['city']),
      country: _str(employee['country']),
      nationalId: _str(employee['national_id']),
      bloodGroup: _str(employee['blood_group']),
      emergencyName: _str(emergency['name']),
      emergencyPhone: _str(emergency['phone']),
      emergencyRelation: _str(emergency['relation']),
      manager: _str(employee['manager']),
      shift: _str(employee['shift']),
      hasLogin: employee['has_login'] == true,
      loginEmail: _str(employee['login_email']),
      loginActive: employee['login_active'] is bool
          ? employee['login_active'] as bool
          : null,
      balances: ((j['balances'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(HrBalance.fromJson)
          .toList(),
      attendance: j['attendance'] is Map<String, dynamic>
          ? HrAttendanceSummary.fromJson(j['attendance'] as Map<String, dynamic>)
          : null,
    );
  }
}

/// One line of an employee's leave history, as HR reads it.
class HrEmployeeLeave {
  const HrEmployeeLeave({
    required this.id,
    required this.leaveType,
    required this.startDate,
    required this.endDate,
    required this.days,
    required this.status,
    this.decidedBy,
    this.decisionNote,
  });

  final int id;
  final String leaveType;
  final String startDate;
  final String endDate;
  final double days;
  final String status;
  final String? decidedBy;
  final String? decisionNote;

  factory HrEmployeeLeave.fromJson(Map<String, dynamic> j) => HrEmployeeLeave(
        id: _toInt(j['id']),
        leaveType: '${j['leave_type'] ?? ''}',
        startDate: '${j['start_date'] ?? ''}',
        endDate: '${j['end_date'] ?? ''}',
        days: _toDouble(j['days']),
        status: '${j['status'] ?? ''}',
        decidedBy: _str(j['decided_by']),
        decisionNote: _str(j['decision_note']),
      );
}
