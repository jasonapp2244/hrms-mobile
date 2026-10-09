import 'dart:convert';
import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/locale.dart';
import 'package:attendance/core/models.dart' show HrEmployeeSummary;
import 'package:attendance/core/offline_cache.dart';
import 'package:attendance/core/session.dart';
import 'package:attendance/core/theme.dart';
import 'package:attendance/l10n/generated/app_localizations.dart';
import 'package:attendance/main.dart';
import 'package:attendance/screens/hr_person_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// One employee's record, as HR opens it on a phone (B8.9).
///
/// The register row and the record both carry the employee's own phone; for a
/// long time the screen drew neither, so HR could read somebody's emergency
/// contact but not the number to ring the person themselves.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('hr_person_test');
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // The cache can still hold the file open on Windows. Harness tidying.
    }
  });

  Session session() => Session(
        cache: OfflineCache(directory: dir),
        api: ApiClient(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/hr/employees/2')) {
              return _json({
                'ok': true,
                'employee': {
                  'id': 2,
                  'name': 'Emily Johnson',
                  'employee_code': 'EMP-0002',
                  'status': 'active',
                  'phone': '+12135550142',
                  'emergency_contact': {
                    'name': 'Mark Johnson',
                    'phone': '+12135550199',
                    'relation': 'Brother',
                  },
                },
                'balances': [],
              });
            }

            return _json({'ok': true, 'requests': []});
          }),
        ),
      );

  testWidgets('the person\'s own phone is on the record', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 1400));

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocale.supported,
      home: SessionScope(
        notifier: session(),
        child: HrPersonScreen(
          person: HrEmployeeSummary.fromJson(
            const {'id': 2, 'name': 'Emily Johnson', 'status': 'active'},
          ),
        ),
      ),
    ));

    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('+12135550142'), findsOneWidget);
    // And the emergency contact's, which was always there, is still its own.
    expect(find.text('+12135550199'), findsOneWidget);
  });
}

http.Response _json(Map<String, dynamic> body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
