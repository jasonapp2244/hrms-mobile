import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/l10n.dart';
import 'package:attendance/core/locale.dart';
import 'package:attendance/core/location.dart';
import 'package:attendance/core/offline_cache.dart';
import 'package:attendance/core/punch_queue.dart';
import 'package:attendance/core/session.dart';
import 'package:attendance/main.dart';
import 'package:attendance/screens/login_screen.dart';
import 'package:attendance/widgets/site_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The privacy policy is reachable from the login screen.
///
/// Both stores review the app before anyone has an account, and Google Play
/// asks for the policy to be one tap away from the first screen. It used to be
/// only under Profile — behind a sign-in a reviewer does not have.
void main() {
  late Directory dir;
  late List<Uri> opened;
  final realLauncher = SiteLink.launcher;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('login_privacy_test');
    FlutterSecureStorage.setMockInitialValues({});
    opened = [];
    SiteLink.launcher = (url) async {
      opened.add(url);
      return true;
    };
  });

  tearDown(() async {
    SiteLink.launcher = realLauncher;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows can hold a file the app wrote without awaiting.
    }
  });

  Session session() => Session(
        api: ApiClient(client: MockClient((_) async => http.Response('{}', 401))),
        cache: OfflineCache(directory: dir),
        queue: PunchQueue(directory: dir),
        locator: const PunchLocator(source: NoLocationSource()),
      );

  Future<Session> pumpLogin(WidgetTester tester, String locale) async {
    FlutterSecureStorage.setMockInitialValues({AppLocale.preferenceKey: locale});
    late Session s;
    await tester.runAsync(() async {
      s = session();
      await s.restore();
    });

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocale.supported,
      locale: s.locale.locale,
      home: SessionScope(notifier: s, child: const LoginScreen()),
    ));
    await tester.pump();
    return s;
  }

  testWidgets('tapping it opens the server policy page', (tester) async {
    final s = await pumpLogin(tester, 'en');

    final link = find.text('Privacy policy');
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pump();

    expect(opened, [Uri.parse('${ApiClient.siteUrl}/privacy')]);
    s.dispose();
  });

  testWidgets('it is translated', (tester) async {
    final s = await pumpLogin(tester, 'es');

    expect(find.text('Política de privacidad'), findsOneWidget);
    expect(find.text('Privacy policy'), findsNothing);
    s.dispose();
  });

  testWidgets('a link that cannot open says where the page lives',
      (tester) async {
    SiteLink.launcher = (_) async => false;
    final s = await pumpLogin(tester, 'en');

    final link = find.text('Privacy policy');
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pump();

    expect(find.text('Could not open ${ApiClient.siteUrl}/privacy'), findsOneWidget);
    s.dispose();
  });
}
