import 'package:attendance/core/models.dart' show Geofence, TodayStatus;
import 'package:attendance/core/theme.dart';
import 'package:attendance/l10n/generated/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The fence the Clock screen warns about (B2.5).
///
/// The server has refused punches outside an office since A4.16. What the app
/// never did was say so *before* the tap: somebody walked to the car park, held
/// the button through a GPS fix and a round trip, and was then told they were
/// two kilometres away.
///
/// Two properties matter, and they pull in opposite directions.
///
/// **The app must predict the server exactly.** It uses the same haversine, the
/// same radius and the same exemptions — because a prediction that is stricter
/// than the rule refuses a punch the server would have taken, which is worse
/// than no prediction at all.
///
/// **And it must stay quiet when no fence applies.** Whether one applies is the
/// server's answer, sent as null or an object; the app never works it out from
/// a policy flag and a work mode, because that is the copy that drifts.
void main() {
  // Two points about 111 m apart: a tenth of a degree of latitude is 11.1 km,
  // so a thousandth is 11.1 m.
  const office = Geofence(
    office: 'Head Office',
    latitude: 40.7128,
    longitude: -74.006,
    radiusMetres: 100,
  );

  group('the distance is the server\'s distance', () {
    test('standing on the spot is zero', () {
      expect(office.metresFrom(40.7128, -74.006), closeTo(0, 0.5));
      expect(office.excludes(40.7128, -74.006), isFalse);
    });

    test('a tenth of a degree north is about 11 km', () {
      // Haversine on a spherical earth, which is what the server runs. The
      // point of this number is that the two agree, not that it is the finest
      // geodesic available — a more accurate formula that disagreed with the
      // enforcement would be the worse choice.
      expect(office.metresFrom(40.8128, -74.006), closeTo(11119, 40));
    });

    test('just inside the radius is allowed and just outside is not', () {
      // ~89 m north, inside 100.
      expect(office.excludes(40.71360, -74.006), isFalse);
      // ~133 m north, outside.
      expect(office.excludes(40.71400, -74.006), isTrue);
    });
  });

  group('the app only ever knows what the server told it', () {
    test('no fence in the payload means no fence', () {
      final today = TodayStatus.fromJson(const {
        'date': '2026-09-14',
        'next_action': 'in',
        'is_clocked_in': false,
      });

      // The default, and the case for home and hybrid workers, for a company
      // that does not enforce, and for an office with no coordinates. The app
      // does not distinguish between those — it has no business doing so.
      expect(today.geofence, isNull);
    });

    test('a fence is read whole, radius and all', () {
      final today = TodayStatus.fromJson(const {
        'date': '2026-09-14',
        'next_action': 'in',
        'is_clocked_in': false,
        'geofence': {
          'office': 'Head Office',
          'latitude': 40.7128,
          'longitude': -74.006,
          'radius': 250,
        },
      });

      expect(today.geofence, isNotNull);
      expect(today.geofence!.office, 'Head Office');
      expect(today.geofence!.radiusMetres, 250);

      // The radius is the server's, not a constant in the app: a company that
      // set 250 m must not be judged against somebody else's 100.
      expect(today.geofence!.excludes(40.71400, -74.006), isFalse);
    });

    test('a build talking to an older server simply has no fence', () {
      // `geofence` is absent from every payload before this feature shipped.
      // Reading that as "no fence" is what keeps the app quiet rather than
      // crashing or inventing one.
      final today = TodayStatus.fromJson(const {
        'date': '2026-09-14',
        'next_action': 'in',
        'is_clocked_in': false,
        'geofence': null,
      });

      expect(today.geofence, isNull);
    });
  });

  group('the distance reads like a distance', () {
    // The three bands, and the reason for the third: the first version printed
    // "11688.3 km" to somebody testing from the other side of the world, which
    // is precision outrunning the question and reads as a broken number.
    late AppLocalizations t;

    setUpAll(() async {
      t = await AppLocalizations.delegate.load(const Locale('en'));
    });

    test('metres below a kilometre', () {
      expect(Fmt.distance(t, 80), '80 m');
      expect(Fmt.distance(t, 999), '999 m');
    });

    test('a tenth of a kilometre up to ten', () {
      expect(Fmt.distance(t, 2300), '2.3 km');
      expect(Fmt.distance(t, 9949), '9.9 km');
    });

    test('whole kilometres beyond that', () {
      expect(Fmt.distance(t, 11688300), '11688 km');
      expect(Fmt.distance(t, 12400), '12 km');
    });
  });
}
