import 'dart:async';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/l10n.dart';
import 'package:attendance/core/location.dart';
import 'package:attendance/core/models.dart';
import 'package:attendance/core/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// The English strings, for the helpers that format with them. A test has no
  /// widget tree to read a set out of, and English is the template — so this is
  /// also what makes an assertion on exact wording meaningful.
  final t = lookupAppLocalizations(const Locale('en'));

  group('ApiException', () {
    test('prefers the field message when a single field failed', () {
      // The server's top-line for a validation failure is generic ("The given
      // data was invalid"); the useful text is in the field detail.
      final e = ApiException(
        error: 'validation_failed',
        message: 'The given data was invalid.',
        fieldErrors: {
          'end_date': ['The end date must be after the start date.'],
        },
      );

      expect(e.displayMessage, 'The end date must be after the start date.');
    });

    test('falls back to the top-line when several fields failed', () {
      final e = ApiException(
        error: 'validation_failed',
        message: 'The given data was invalid.',
        fieldErrors: {
          'start_date': ['Required.'],
          'end_date': ['Required.'],
        },
      );

      expect(e.displayMessage, 'The given data was invalid.');
    });

    test('recognises the states the UI branches on', () {
      expect(
        ApiException(error: 'unauthenticated', message: '').isUnauthenticated,
        isTrue,
      );
      expect(
        ApiException(error: 'duplicate_scan', message: '').isDuplicateScan,
        isTrue,
      );
    });
  });

  group('AppUser', () {
    test('reads an employee with a manager permission', () {
      final user = AppUser.fromJson({
        'id': 3,
        'name': 'James Smith',
        'email': 'james@acme.test',
        'roles': ['employee', 'manager'],
        'permissions': ['view-attendance', 'approve-leave'],
        'company': {'id': 1, 'name': 'Acme', 'timezone': 'America/New_York'},
        'employee': {
          'id': 1,
          'employee_code': 'EMP-0001',
          'full_name': 'James Smith',
          'is_manager': true,
        },
      });

      expect(user.canApproveLeave, isTrue);
      expect(user.leadsATeam, isTrue);
      expect(user.hasEmployeeRecord, isTrue);
      expect(user.initials, 'JS');
    });

    test('HR holds approve-leave and still gets no Team tab', () {
      // HR is the second step of the approval chain, so it carries the
      // permission the manager endpoints are gated on. It almost never has
      // anybody reporting to it, and those endpoints are scoped to direct
      // reports — so the tab used to appear and every screen behind it came
      // back empty for ever. The web never had this: /manager/* is gated
      // role:manager as well and refuses HR at the door.
      final hr = AppUser.fromJson({
        'id': 4,
        'name': 'Dana HR',
        'email': 'dana@acme.test',
        'roles': ['hr'],
        'permissions': ['approve-leave', 'view-team', 'manage-employees'],
        'employee': {
          'id': 2,
          'employee_code': 'EMP-0002',
          'full_name': 'Dana HR',
          'is_manager': false,
        },
      });

      expect(hr.canApproveLeave, isTrue);
      expect(hr.leadsATeam, isFalse);
    });

    test('a manager role with nobody reporting gets no Team tab either', () {
      // The role grants the gate; manager_id decides the scope. Both have to
      // line up, and on a phone a permanently empty tab is worse than none.
      final lonely = AppUser.fromJson({
        'id': 5,
        'name': 'Mia Lead',
        'email': 'mia@acme.test',
        'roles': ['employee', 'manager'],
        'permissions': ['view-attendance', 'approve-leave'],
        'employee': {
          'id': 3,
          'employee_code': 'EMP-0003',
          'full_name': 'Mia Lead',
          'is_manager': false,
        },
      });

      expect(lonely.canApproveLeave, isTrue);
      expect(lonely.leadsATeam, isFalse);
    });

    test('an admin login with no employee record is still a valid user', () {
      // Such an account signs in fine and then gets 403 from every
      // employee-scoped endpoint, so the UI has to check rather than assume.
      final user = AppUser.fromJson({
        'id': 1,
        'name': 'Admin',
        'email': 'admin@acme.test',
        'roles': ['admin'],
        'permissions': [],
        'employee': null,
      });

      expect(user.hasEmployeeRecord, isFalse);
      expect(user.canApproveLeave, isFalse);
      // No employee record means no reporting line either, so nothing to lead.
      expect(user.leadsATeam, isFalse);
    });
  });

  group('LeaveBalance', () {
    test('an uncapped type is not an exhausted one', () {
      // A type granting zero days is how unpaid leave is set up. Rendering it
      // as "0 days left" would read as exhausted, the opposite of the truth.
      final balance = LeaveBalance.fromJson({
        'leave_type_id': 9,
        'name': 'Unpaid Leave',
        'code': 'UL',
        'entitled_days': 0,
        'used_days': 0,
        'available_days': 0,
        'is_capped': false,
      });

      expect(balance.isCapped, isFalse);
      expect(balance.entitledDays, 0.0);
    });

    test('parses a half day as 0.5, not 0', () {
      final balance = LeaveBalance.fromJson({
        'leave_type_id': 4,
        'name': 'Annual',
        'code': 'AL',
        'used_days': 0.5,
        'available_days': 19.5,
        'is_capped': true,
      });

      expect(balance.usedDays, 0.5);
      expect(balance.availableDays, 19.5);
    });
  });

  group('TodayStatus', () {
    test('defaults can_check to true when the server omits it', () {
      final today = TodayStatus.fromJson({'date': '2026-08-04', 'next_action': 'in'});
      expect(today.canCheck, isTrue);
      expect(today.willClockIn, isTrue);
    });

    test('leave on a day does not stop the punch', () {
      // Somebody who books a day off and comes in anyway worked, and the
      // record has to say so.
      final today = TodayStatus.fromJson({
        'date': '2026-08-04',
        'next_action': 'in',
        'can_check': true,
        'leave': 'Annual Leave',
      });

      expect(today.leave, 'Annual Leave');
      expect(today.canCheck, isTrue);
    });

    test('a break does not read as having gone home', () {
      // The bug this endpoint would otherwise have caused, in model form:
      // break_end is neither in nor out, and anything reading the last punch
      // treats a returning employee as one who left.
      final today = TodayStatus.fromJson({
        'date': '2026-08-04',
        'next_action': 'out',
        'is_clocked_in': true,
        'on_break': true,
        'can_break': true,
        'next_break_action': 'end',
        'break_started_at': '2026-08-04T13:00:00+00:00',
      });

      expect(today.isClockedIn, isTrue);
      expect(today.willClockIn, isFalse);
      expect(today.onBreak, isTrue);
      expect(today.willStartBreak, isFalse);
      expect(today.breakStartedAt, '2026-08-04T13:00:00+00:00');
    });

    test('an older server offering no break keys gets no break button', () {
      // can_break defaults to false, not true: a build talking to a server from
      // before B2.6 must show no button rather than one that 404s.
      final today = TodayStatus.fromJson({'date': '2026-08-04', 'next_action': 'out'});

      expect(today.canBreak, isFalse);
      expect(today.onBreak, isFalse);
      expect(today.willStartBreak, isTrue);
      expect(today.breakStartedAt, isNull);
    });
  });

  group('Punch', () {
    test('names all four types, not two', () {
      String labelFor(String type) =>
          Punch.fromJson({'id': 1, 'type': type, 'status': 'ontime', 'time': '09:00 AM'})
              .label(t);

      expect(labelFor('in'), 'Checked in');
      expect(labelFor('out'), 'Checked out');
      expect(labelFor('break_start'), 'Break started');
      expect(labelFor('break_end'), 'Back from break');
    });

    test('a break is not a departure', () {
      final breakEnd = Punch.fromJson(
        {'id': 1, 'type': 'break_end', 'status': 'ontime', 'time': '01:30 PM'},
      );

      // isIn is false for a break_end, which is exactly why nothing may branch
      // on it alone — that ternary would render this as "Checked out".
      expect(breakEnd.isIn, isFalse);
      expect(breakEnd.isBreak, isTrue);
      expect(breakEnd.label, isNot('Checked out'));
    });

    test('an unknown type falls back to itself rather than lying', () {
      final odd = Punch.fromJson(
        {'id': 1, 'type': 'lunch', 'status': 'ontime', 'time': '12:00 PM'},
      );

      expect(odd.label(t), 'lunch');
      // And in every other language too: a type this build has not heard of has
      // no translation to fall back to, only the server's own word.
      expect(odd.label(lookupAppLocalizations(const Locale('es'))), 'lunch');
      expect(odd.isBreak, isFalse);
    });
  });

  group('Directory', () {
    Map<String, dynamic> page({bool contact = false}) => {
          'people': [
            {
              'id': 4,
              'employee_code': 'E2',
              'full_name': 'Bo Ray',
              'designation': 'Cleaner',
              'department': 'Ops',
              'office': 'Head Office',
              'work_mode': 'office',
              'photo_url': null,
              if (contact) 'email': 'bo@acme.test',
              if (contact) 'phone': '+15550134',
            },
          ],
          'meta': {'current_page': 1, 'last_page': 1},
          'shows_contact_details': contact,
        };

    test('a colleague carries where to find them and nothing more', () {
      final directory = Directory.fromJson(page());
      final person = directory.people.single;

      expect(person.fullName, 'Bo Ray');
      expect(person.designation, 'Cleaner');
      expect(person.office, 'Head Office');
      expect(person.initials, 'BR');
    });

    test('contact details are absent until the company shares them', () {
      final withheld = Directory.fromJson(page());

      expect(withheld.showsContactDetails, isFalse);
      expect(withheld.people.single.phone, isNull);
      expect(withheld.people.single.email, isNull);

      final shared = Directory.fromJson(page(contact: true));

      expect(shared.showsContactDetails, isTrue);
      expect(shared.people.single.phone, '+15550134');
    });

    test('the flag is read, not inferred from a missing phone', () {
      // Sharing switched on, this colleague has nothing on file. The app has to
      // tell that apart from the company withholding it, or it draws a call
      // button that does nothing.
      final directory = Directory.fromJson({
        'people': [
          {'id': 5, 'employee_code': 'E3', 'full_name': 'Cy Pher', 'phone': null},
        ],
        'meta': {'current_page': 1, 'last_page': 1},
        'shows_contact_details': true,
      });

      expect(directory.showsContactDetails, isTrue);
      expect(directory.people.single.phone, isNull);
    });

    test('knows when there is another page', () {
      expect(Directory.fromJson(page()).hasMore, isFalse);

      final more = Directory.fromJson({
        'people': const [],
        'meta': {'current_page': 1, 'last_page': 3},
      });

      expect(more.hasMore, isTrue);
    });
  });

  group('Regularisation', () {
    test('tells a disputed punch from a missing one', () {
      final disputed = Regularisation.fromJson({
        'id': 7, 'type': 'in', 'work_date': '2026-08-03',
        'requested_at': '2026-08-03T09:00:00+00:00', 'reason': 'Reader missed me',
        'status': 'pending', 'challenges_a_punch': true,
        'attendance_log_id': 109, 'can_cancel': true,
      });

      final missing = Regularisation.fromJson({
        'id': 8, 'type': 'out', 'work_date': '2026-08-03',
        'requested_at': '2026-08-03T18:00:00+00:00', 'reason': 'Forgot to check out',
        'status': 'pending', 'challenges_a_punch': false,
        'attendance_log_id': null, 'can_cancel': true,
      });

      expect(disputed.challengesAPunch, isTrue);
      expect(disputed.attendanceLogId, 109);
      expect(missing.challengesAPunch, isFalse);
      expect(missing.attendanceLogId, isNull);
      expect(disputed.summary, isNot(missing.summary));
    });

    test('a decided request cannot be withdrawn and names who decided it', () {
      final decided = Regularisation.fromJson({
        'id': 9, 'type': 'in', 'work_date': '2026-08-03',
        'requested_at': '2026-08-03T09:00:00+00:00', 'reason': 'Reader missed me',
        'status': 'rejected', 'challenges_a_punch': false, 'can_cancel': false,
        'decision_note': 'The badge log disagrees.', 'decided_by': 'Dana HR',
      });

      expect(decided.isPending, isFalse);
      expect(decided.canCancel, isFalse);
      expect(decided.decidedBy, 'Dana HR');
    });
  });

  group('DisputablePunch', () {
    test('only in and out can be corrected', () {
      DisputablePunch punch(String type) => DisputablePunch.fromJson({
            'id': 1, 'type': type, 'work_date': '2026-08-03', 'time': '09:00 AM',
          });

      // recordManual has nothing to write for a break, and a break has no shift
      // to be judged against — so offering one would be a form that always fails.
      expect(punch('in').isCorrectable, isTrue);
      expect(punch('out').isCorrectable, isTrue);
      expect(punch('break_start').isCorrectable, isFalse);
      expect(punch('break_end').isCorrectable, isFalse);
    });
  });

  group('EmployeeDocument', () {
    Map<String, dynamic> json({String state = 'none', String? expires}) => {
          'id': 12,
          'type': 'right_to_work',
          'type_label': 'Right to Work / Visa',
          'title': 'Work visa',
          'original_name': 'visa-2026.pdf',
          'mime_type': 'application/pdf',
          'size_bytes': 184320,
          'size_label': '180 KB',
          'expiry_state': state,
          'expires_on': expires,
        };

    test('reads what the list shows', () {
      final doc = EmployeeDocument.fromJson(json(state: 'soon', expires: '2026-10-01'));

      expect(doc.id, 12);
      expect(doc.typeLabel, 'Right to Work / Visa');
      expect(doc.title, 'Work visa');
      expect(doc.sizeLabel, '180 KB');
      expect(doc.expiresOn, '2026-10-01');
    });

    test('the four expiry states line up with the web badge', () {
      expect(EmployeeDocument.fromJson(json(state: 'expired')).hasExpired, isTrue);
      expect(EmployeeDocument.fromJson(json(state: 'soon')).expiresSoon, isTrue);

      final valid = EmployeeDocument.fromJson(json(state: 'valid'));
      expect(valid.hasExpired, isFalse);
      expect(valid.expiresSoon, isFalse);

      final undated = EmployeeDocument.fromJson(json());
      expect(undated.hasExpired, isFalse);
      expect(undated.expiresSoon, isFalse);
      expect(undated.expiresOn, isNull);
    });

    test('falls back to the raw type when the server sends no label', () {
      final doc = EmployeeDocument.fromJson({'id': 1, 'type': 'contract'});

      expect(doc.typeLabel, 'contract');
      // Absent rather than wrong: an older server omitting expiry_state must
      // not have its documents drawn as expired.
      expect(doc.expiryState, 'none');
    });
  });

  group('Fmt', () {
    test('renders whole and half days correctly', () {
      expect(Fmt.days(t, 1), '1 day');
      expect(Fmt.days(t, 2), '2 days');
      expect(Fmt.days(t, 0.5), '0.5 days');
    });

    test('renders durations a person would read', () {
      expect(Fmt.duration(t, 0), '0m');
      expect(Fmt.duration(t, 45), '45m');
      expect(Fmt.duration(t, 60), '1h');
      expect(Fmt.duration(t, 434), '7h 14m');
    });

    test('reads a time in the company zone, not the handset one', () {
      // The string already carries the company's offset. DateTime.parse would
      // convert it to local time, so a punch made at 18:00 in New York would
      // read as 23:00 to somebody whose phone is on London time.
      expect(Fmt.timeOf(t, '2026-08-03T18:00:00-04:00'), '06:00 PM');
      expect(Fmt.timeOf(t, '2026-08-03T09:05:00+05:00'), '09:05 AM');
      expect(Fmt.timeOf(t, '2026-08-03T00:30:00+00:00'), '12:30 AM');
      expect(Fmt.timeOf(t, '2026-08-03T12:00:00+00:00'), '12:00 PM');
    });

    test('a time it cannot parse comes back untouched rather than wrong', () {
      expect(Fmt.timeOf(t, 'not a timestamp'), 'not a timestamp');
    });

    test('a single-day range does not repeat itself', () {
      expect(Fmt.range(t, '2026-08-04', '2026-08-04'), '4 August 2026');
      expect(Fmt.range(t, '2026-08-04', '2026-08-06'), '4 Aug – 6 Aug');
    });

    test('names when a cached copy was saved', () {
      // The offline banner's whole job is to say how stale it is, so "today"
      // and "yesterday" have to be told apart by the calendar day and not by
      // a 24-hour arithmetic that calls 23:00 last night "today".
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day, 14, 2);

      expect(Fmt.savedAt(t, today), 'today at 14:02');
      expect(
        Fmt.savedAt(t, today.subtract(const Duration(days: 1))),
        'yesterday at 14:02',
      );

      final older = today.subtract(const Duration(days: 5));
      expect(
        Fmt.savedAt(t, older),
        '${Fmt.shortDate(t, older.toIso8601String())} at 14:02',
      );
    });

    test('pads a single-digit clock', () {
      final now = DateTime.now();

      expect(
        Fmt.savedAt(t, DateTime(now.year, now.month, now.day, 8, 5)),
        'today at 08:05',
      );
    });

    test('a date reads the way the language it is drawn in writes one', () {
      // Spanish puts "de" between the day, the month and the year, which is why
      // dateLong is a message with three placeholders rather than three strings
      // glued together in Dart.
      final es = lookupAppLocalizations(const Locale('es'));

      expect(Fmt.longDate(es, '2026-08-04'), '4 de agosto de 2026');
      expect(Fmt.shortDate(es, '2026-08-04'), '4 ago');
      expect(Fmt.days(es, 1), '1 día');
      expect(Fmt.days(es, 2), '2 días');
      expect(Fmt.timeOf(es, '2026-08-03T18:00:00-04:00'), '06:00 p. m.');
    });

    test('a weekday the server wrote in English is drawn in the right one', () {
      // The roster and the history list both carry a weekday string from a
      // server that has no idea who is reading it.
      final es = lookupAppLocalizations(const Locale('es'));

      expect(Fmt.weekdayNamed(es, 'Mon'), 'lun');
      expect(Fmt.weekdayNamed(es, 'Sunday'), 'dom');
      expect(Fmt.weekdayNamed(t, 'Wed'), 'Wed');

      // Not a weekday at all: better an English word where a day name belongs
      // than a blank.
      expect(Fmt.weekdayNamed(es, 'Quarter'), 'Quarter');
      expect(Fmt.weekdayNamed(es, ''), '');
    });
  });

  group('statusStyle', () {
    test('covers every status the API can send', () {
      for (final brightness in Brightness.values) {
        final colors = AppColors.forBrightness(brightness);

        for (final status in [
          'present',
          'leave',
          'holiday',
          'day_off',
          'weekend',
          'absent',
        ]) {
          final (_, label) = colors.statusStyle(t, status);
          expect(label, isNotEmpty);
          expect(label, isNot(status));
        }
      }
    });
  });

  // The team roster (B7.3). Parsing only — the endpoint decides the status
  // vocabulary and the app must not reinterpret it.
  group('TeamRosterMember', () {
    Map<String, dynamic> payload() => {
          'employee_id': 7,
          'name': 'Emily Johnson',
          'employee_code': 'EMP-0002',
          'schedule': [
            {
              'date': '2026-08-03',
              'status': 'working',
              'holiday': null,
              'shift': {
                'name': 'Morning',
                'start_time': '09:00:00',
                'end_time': '17:00:00',
              },
              'is_rostered': true,
            },
            {
              'date': '2026-08-04',
              'status': 'leave',
              'holiday': null,
              'shift': null,
              'is_rostered': false,
            },
          ],
        };

    test('reads a week for one person', () {
      final member = TeamRosterMember.fromJson(payload());

      expect(member.employeeId, 7);
      expect(member.name, 'Emily Johnson');
      expect(member.schedule, hasLength(2));
    });

    test('a working day carries its shift', () {
      final day = TeamRosterMember.fromJson(payload()).schedule.first;

      expect(day.isWorking, isTrue);
      expect(day.isRostered, isTrue);
      expect(day.shift?.name, 'Morning');
    });

    test('a leave day carries no shift', () {
      // Showing the shift would have a manager expecting somebody who booked
      // the day off after the roster was drawn.
      final day = TeamRosterMember.fromJson(payload()).schedule[1];

      expect(day.isWorking, isFalse);
      expect(day.status, 'leave');
      expect(day.shift, isNull);
    });

    test('an empty schedule is not an error', () {
      final member = TeamRosterMember.fromJson({
        'employee_id': 1,
        'name': 'Nobody',
        'employee_code': 'E1',
      });

      expect(member.schedule, isEmpty);
    });
  });

  // Location is a record, not a gate. Every test here is really the same
  // assertion from a different angle: whatever goes wrong with the sensor, the
  // punch still gets sent.
  group('PunchLocator', () {
    test('sends both coordinates when there is a fix', () async {
      const locator = PunchLocator(
        source: _FakeLocationSource(
          Coordinates(latitude: 40.7128, longitude: -74.006),
        ),
      );

      expect(await locator.punchBody(), {
        'latitude': 40.7128,
        'longitude': -74.006,
      });
    });

    test('sends an empty body when there is no fix', () async {
      const locator = PunchLocator(source: NoLocationSource());

      // Not {'latitude': null} — the endpoint validates these as numeric when
      // present, so a null would fail the punch rather than read as "unknown".
      expect(await locator.punchBody(), isEmpty);
    });

    test('swallows a source that throws', () async {
      const locator = PunchLocator(source: _ThrowingLocationSource());

      expect(await locator.resolve(), isNull);
      expect(await locator.punchBody(), isEmpty);
    });

    test('gives up on a source that hangs', () async {
      const locator = PunchLocator(
        source: _HangingLocationSource(),
        deadline: Duration(milliseconds: 50),
      );

      // The real case: indoors, permission granted, no fix ever arrives. The
      // button must not sit under a spinner waiting for it.
      expect(await locator.resolve(), isNull);
    });

    test('drops a fix the server would reject', () async {
      // 91° does not exist. The server validates −90…90 and fails the whole
      // punch on a bad value, so a broken sensor must cost the coordinates
      // rather than the clock-in.
      const locator = PunchLocator(
        source: _FakeLocationSource(
          Coordinates(latitude: 91, longitude: -74.006),
        ),
      );

      expect(await locator.punchBody(), isEmpty);
    });

    test('treats NaN as no fix', () async {
      const locator = PunchLocator(
        source: _FakeLocationSource(
          Coordinates(latitude: double.nan, longitude: double.nan),
        ),
      );

      expect(await locator.punchBody(), isEmpty);
    });
  });
}

class _FakeLocationSource implements LocationSource {
  const _FakeLocationSource(this.fix);

  final Coordinates fix;

  @override
  Future<Coordinates?> currentPosition() async =>
      fix.isPlausible ? fix : null;
}

class _ThrowingLocationSource implements LocationSource {
  const _ThrowingLocationSource();

  @override
  Future<Coordinates?> currentPosition() async =>
      throw Exception('permission channel blew up');
}

class _HangingLocationSource implements LocationSource {
  const _HangingLocationSource();

  @override
  Future<Coordinates?> currentPosition() => Completer<Coordinates?>().future;
}
