import 'package:attendance/screens/punch_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// Whether the clock screen may show a saved copy of today with no signal.
///
/// Judged on the **company's** calendar (trap 30), from the offset the server
/// wrote into `server_time` — never from the handset's date.
void main() {
  // A New York company, the copy saved at 23:30 on 23 Sep company time.
  final lateEvening = {
    'date': '2026-09-23',
    'server_time': '2026-09-23T23:30:00-04:00',
  };

  test('still the same company day, whatever the phone thinks', () {
    // 23:45 New York is already 24 Sep in UTC and on most phones east of it.
    final now = DateTime.utc(2026, 9, 24, 3, 45);

    expect(savedTodayStillHolds(lateEvening, now), isTrue);
  });

  test('refused once the company has passed midnight', () {
    // 00:05 New York on the 24th. A phone in Los Angeles still reads the
    // 23rd, and the old comparison accepted yesterday's copy here.
    final now = DateTime.utc(2026, 9, 24, 4, 5);

    expect(savedTodayStillHolds(lateEvening, now), isFalse);
  });

  test('a night shift copy is judged by when it was taken, not its date', () {
    // The server dates a night shift by its first day; the copy was taken at
    // 01:00 on the 24th and is still good five minutes later.
    final nightShift = {
      'date': '2026-09-23',
      'server_time': '2026-09-24T01:00:00-04:00',
    };
    final now = DateTime.utc(2026, 9, 24, 5, 5);

    expect(savedTodayStillHolds(nightShift, now), isTrue);
  });

  test('a company on UTC written with Z', () {
    final utc = {'date': '2026-09-23', 'server_time': '2026-09-23T22:00:00Z'};

    expect(savedTodayStillHolds(utc, DateTime.utc(2026, 9, 23, 23, 59)), isTrue);
    expect(savedTodayStillHolds(utc, DateTime.utc(2026, 9, 24, 0, 1)), isFalse);
  });

  test('a copy without server_time keeps the old comparison', () {
    final old = {'date': '2026-09-23'};

    expect(savedTodayStillHolds(old, DateTime(2026, 9, 23, 12)), isTrue);
    expect(savedTodayStillHolds(old, DateTime(2026, 9, 24, 12)), isFalse);
  });
}
