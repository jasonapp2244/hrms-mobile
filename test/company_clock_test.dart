import 'package:attendance/screens/regularisations_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where the correction form opens: the company's clock, read off
/// `server_time` exactly as written — never converted into the handset's zone.
void main() {
  test('the wall clock is read as written, offset dropped', () {
    // 22:30 in New York. DateTime.parse would move this to 02:30 the next day
    // for a phone on UTC — the date and the hour both wrong.
    final when = wallClockOf('2026-09-14T22:30:00-04:00')!;

    expect(
      [when.year, when.month, when.day, when.hour, when.minute],
      [2026, 9, 14, 22, 30],
    );
    expect(when.isUtc, isFalse);
  });

  test('a UTC company written with Z reads the same way', () {
    final when = wallClockOf('2026-09-14T09:05:00Z')!;

    expect([when.day, when.hour, when.minute], [14, 9, 5]);
  });

  test('an older server that sends nothing gives nothing', () {
    expect(wallClockOf(null), isNull);
    expect(wallClockOf(''), isNull);
    expect(wallClockOf('2026-09-14'), isNull);
  });
}
