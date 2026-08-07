import 'dart:async';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/location.dart';
import 'package:attendance/core/models.dart';
import 'package:attendance/core/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
      expect(user.hasEmployeeRecord, isTrue);
      expect(user.initials, 'JS');
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
  });

  group('Fmt', () {
    test('renders whole and half days correctly', () {
      expect(Fmt.days(1), '1 day');
      expect(Fmt.days(2), '2 days');
      expect(Fmt.days(0.5), '0.5 days');
    });

    test('renders durations a person would read', () {
      expect(Fmt.duration(0), '0m');
      expect(Fmt.duration(45), '45m');
      expect(Fmt.duration(60), '1h');
      expect(Fmt.duration(434), '7h 14m');
    });

    test('a single-day range does not repeat itself', () {
      expect(Fmt.range('2026-08-04', '2026-08-04'), '4 August 2026');
      expect(Fmt.range('2026-08-04', '2026-08-06'), '4 Aug – 6 Aug');
    });
  });

  group('statusStyle', () {
    test('covers every status the API can send', () {
      for (final status in [
        'present',
        'leave',
        'holiday',
        'day_off',
        'weekend',
        'absent',
      ]) {
        final (_, label) = AppTheme.statusStyle(status);
        expect(label, isNotEmpty);
        expect(label, isNot(status));
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
