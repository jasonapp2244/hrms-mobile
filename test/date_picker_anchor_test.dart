import 'dart:convert';
import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/locale.dart';
import 'package:attendance/core/offline_cache.dart';
import 'package:attendance/core/session.dart';
import 'package:attendance/core/theme.dart';
import 'package:attendance/l10n/generated/app_localizations.dart';
import 'package:attendance/main.dart';
import 'package:attendance/screens/leave_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/settle.dart';

/// The date pickers, and the day they think it is.
///
/// Every screen that *reads* a date already anchors on the server. The two that
/// *offer* one did not: `showDateRangePicker` and `showDatePicker` were handed
/// `DateTime.now()`, so they ringed the handset's today and bounded themselves
/// by it. Found on a real device — the phone was on 15 September while the
/// company, in America/New_York, was still on the 14th. The Clock, History and
/// Schedule tabs all said the 14th; the leave picker ringed the 15th.
///
/// Two costs, not one. Somebody booking "from today" books the wrong day; and
/// on the corrections form the upper bound is a rule — the server refuses a
/// correction to a time that has not happened — so the app was offering a date
/// it would then be refused for, which reads as the app being broken.
///
/// The mock below keeps a deliberate skew between the company's today and the
/// test machine's, because with a shared clock every one of these passes
/// against the broken code.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('date_picker_anchor_test');
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // The cache writes without the test awaiting it, so on Windows the file
      // can still be held open when the test ends. Harness tidying.
    }
  });

  /// The company's today, three days behind the machine running the tests so
  /// the two never coincide.
  final serverToday = DateUtils.dateOnly(
    DateTime.now().subtract(const Duration(days: 3)),
  );

  String iso(DateTime d) => d.toIso8601String().substring(0, 10);

  Session leaveSession() {
    final api = ApiClient(
      client: MockClient((request) async {
        final path = request.url.path;

        if (path.endsWith('/leave/balances')) {
          return http.Response(
            jsonEncode({
              'ok': true,
              'year': serverToday.year,
              'today': iso(serverToday),
              'balances': [
                {
                  'leave_type_id': 1,
                  'name': 'Annual Leave',
                  'code': 'AL',
                  'color': '#F26522',
                  'is_paid': true,
                  'allow_half_day': true,
                  'requires_approval': true,
                  'entitled_days': 20.0,
                  'carried_forward': 0.0,
                  'used_days': 0.0,
                  'available_days': 20.0,
                  'is_capped': true,
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        if (path.endsWith('/leave/requests')) {
          return http.Response(
            jsonEncode({'ok': true, 'requests': <Object>[], 'meta': <String, Object>{}}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        return http.Response(
          jsonEncode({'ok': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    return Session(api: api, cache: OfflineCache(directory: dir));
  }

  Future<void> pumpLeave(WidgetTester tester, Session session) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 900));

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocale.supported,
      home: SessionScope(
        notifier: session,
        child: LeaveScreen(visible: ValueNotifier(true)),
      ),
    ));
    await settle(tester);
  }

  testWidgets('the leave picker rings the company\'s today, not the phone\'s',
      (tester) async {
    await pumpLeave(tester, leaveSession());

    // Open the apply sheet, then the range picker inside it.
    expect(find.text('Apply'), findsOneWidget, reason: 'no way to apply for leave');
    await tester.tap(find.text('Apply'));
    await settle(tester);

    expect(find.text('Choose dates'), findsOneWidget, reason: 'apply sheet did not open');
    await tester.tap(find.text('Choose dates'));
    await settle(tester);

    final picker = tester.widget<DateRangePickerDialog>(
      find.byType(DateRangePickerDialog),
    );

    // `currentDate` is the day the picker draws a ring around. Material
    // defaults it to DateTime.now(), which is exactly the bug.
    expect(
      iso(picker.currentDate!),
      iso(serverToday),
      reason: 'the picker rings a day the company has not reached',
    );

    // The bounds come off the same day, so a phone drifting across a year
    // boundary cannot narrow or widen what the server will accept.
    expect(picker.firstDate.year, serverToday.year - 1);
    expect(picker.lastDate.year, serverToday.year + 2);
  });
}
