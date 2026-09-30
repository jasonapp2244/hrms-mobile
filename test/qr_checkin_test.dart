import 'dart:convert';
import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/locale.dart';
import 'package:attendance/core/location.dart';
import 'package:attendance/core/models.dart' show TodayStatus;
import 'package:attendance/core/offline_cache.dart';
import 'package:attendance/core/punch_queue.dart';
import 'package:attendance/core/session.dart';
import 'package:attendance/core/theme.dart';
import 'package:attendance/l10n/generated/app_localizations.dart';
import 'package:attendance/main.dart';
import 'package:attendance/screens/login_screen.dart';
import 'package:attendance/screens/punch_screen.dart';
import 'package:attendance/screens/qr_scan_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/settle.dart';

/// QR check-in (A4.21), from the handset's side.
///
/// The camera cannot run in a widget test, so [QrScanScreen.open] is replaced
/// with one that answers as if a code had been read; everything after the scan
/// — the request, the refusals, the queue that must *not* be used — is real.
void main() {
  late Directory dir;
  final realOpen = QrScanScreen.open;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qr_checkin_test');
    FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});
  });

  tearDown(() async {
    QrScanScreen.open = realOpen;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows can still hold a file the cache wrote. Harness tidying.
    }
  });

  /// The scanner "reads" [text], and records what it was asked for.
  List<String> scannerReads(String? text) {
    final asked = <String>[];
    QrScanScreen.open = (context, {required title, required prefix}) async {
      asked.add(prefix);
      return text;
    };
    return asked;
  }

  Map<String, dynamic> user() => {
        'id': 3,
        'name': 'Ann Lee',
        'email': 'ann@acme.test',
        'roles': ['employee'],
        'permissions': ['view-attendance'],
        'employee': {'id': 1, 'employee_code': 'E1', 'full_name': 'Ann Lee', 'is_manager': false},
      };

  Map<String, dynamic> today(String method) {
    final now = DateTime.now();
    final date = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';

    return {
      'ok': true,
      'date': date,
      'method': method,
      'next_action': 'in',
      'is_clocked_in': false,
      'on_break': false,
      'can_check': true,
      'can_break': false,
      'next_break_action': 'start',
      'worked_minutes': 0,
      'punches': const <Map<String, dynamic>>[],
      'shift': null,
      'is_day_off': false,
      'holiday': null,
      'leave': null,
    };
  }

  http.Response json(Map<String, dynamic> body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  /// A signed-in session whose server answers `/attendance/qr` with [onScan].
  Future<(Session, List<http.Request>)> signedIn(
    WidgetTester tester, {
    required String method,
    http.Response Function()? onScan,
  }) async {
    late Session session;
    final sent = <http.Request>[];

    await tester.runAsync(() async {
      final store = OfflineCache(directory: dir);
      await store.write(OfflineCache.keyProfile, {'user': user()});

      final queue = PunchQueue(directory: dir);
      await queue.load();

      session = Session(
        api: ApiClient(
          client: MockClient((request) async {
            sent.add(request);
            final path = request.url.path;

            if (path.endsWith('/attendance/today')) return json(today(method));
            if (path.endsWith('/attendance/qr')) {
              return onScan?.call() ??
                  json({
                    'ok': true,
                    'punch': {'id': 9, 'type': 'in', 'status': 'ontime', 'scanned_at': '2026-09-30T08:57:00-04:00', 'time': '08:57 AM'},
                    'next_action': 'out',
                    'message': 'You clocked IN at 08:57 AM.',
                  });
            }
            if (path.endsWith('/attendance/check')) {
              return json({
                'ok': true,
                'punch': {'id': 8, 'type': 'in', 'status': 'ontime', 'scanned_at': '2026-09-30T08:57:00-04:00', 'time': '08:57 AM'},
                'next_action': 'out',
                'message': 'Tapped in.',
              });
            }
            return json({'ok': true, 'user': user()});
          }),
        ),
        cache: store,
        queue: queue,
        locator: const PunchLocator(source: NoLocationSource()),
      );

      await session.restore();
    });

    return (session, sent);
  }

  Future<void> pumpClock(WidgetTester tester, Session session) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 900));

    await tester.pumpWidget(SessionScope(
      notifier: session,
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocale.supported,
        home: PunchScreen(visible: ValueNotifier(true)),
      ),
    ));
    await settle(tester);
  }

  Iterable<String> paths(List<http.Request> sent) => sent.map((r) => r.url.path.split('/api/v1').last);

  test('the server decides the method, and an old server means the button', () {
    expect(TodayStatus.fromJson(today('qr')).scansQr, isTrue);
    expect(TodayStatus.fromJson(today('button')).scansQr, isFalse);
    expect(TodayStatus.fromJson(today('button')..remove('method')).scansQr, isFalse);
  });

  testWidgets('office staff scan: the code goes to /attendance/qr, never /check', (tester) async {
    final asked = scannerReads('KEMP1:4:abc123');
    final (session, sent) = await signedIn(tester, method: 'qr');
    await pumpClock(tester, session);

    expect(find.text('Scan to check in'), findsOneWidget);

    await tester.tap(find.text('Scan to check in'));
    await settle(tester);

    expect(asked, [officeQrPrefix]);
    expect(paths(sent), contains('/attendance/qr'));
    expect(paths(sent), isNot(contains('/attendance/check')));

    final scan = sent.firstWhere((r) => r.url.path.endsWith('/attendance/qr'));
    expect(jsonDecode(scan.body)['qr'], 'KEMP1:4:abc123');
    expect(find.text('You clocked IN at 08:57 AM.'), findsOneWidget);

    session.dispose();
  });

  testWidgets('the button stays a button for everybody else', (tester) async {
    final asked = scannerReads('KEMP1:4:abc123');
    final (session, sent) = await signedIn(tester, method: 'button');
    await pumpClock(tester, session);

    await tester.tap(find.text('Check in'));
    await settle(tester);

    expect(asked, isEmpty, reason: 'the camera must not open');
    expect(paths(sent), contains('/attendance/check'));
    expect(paths(sent), isNot(contains('/attendance/qr')));

    session.dispose();
  });

  testWidgets('backing out of the camera sends nothing', (tester) async {
    scannerReads(null);
    final (session, sent) = await signedIn(tester, method: 'qr');
    await pumpClock(tester, session);

    await tester.tap(find.text('Scan to check in'));
    await settle(tester);

    expect(paths(sent), isNot(contains('/attendance/qr')));

    session.dispose();
  });

  testWidgets('a code somebody else used first asks for another scan', (tester) async {
    scannerReads('KEMP1:4:abc123');
    final (session, _) = await signedIn(
      tester,
      method: 'qr',
      onScan: () => json({'ok': false, 'error': 'qr_already_used', 'message': 'server words'}, 422),
    );
    await pumpClock(tester, session);

    await tester.tap(find.text('Scan to check in'));
    await settle(tester);

    expect(find.text('That code has just changed. Scan the new one on the screen.'), findsOneWidget);

    session.dispose();
  });

  testWidgets('with no connection a scan is refused, not queued', (tester) async {
    scannerReads('KEMP1:4:abc123');
    final (session, _) = await signedIn(
      tester,
      method: 'qr',
      onScan: () => throw const SocketException('offline'),
    );
    await pumpClock(tester, session);

    await tester.tap(find.text('Scan to check in'));
    await settle(tester);

    expect(find.textContaining('Scanning needs the internet'), findsOneWidget);
    expect(session.queue.count.value, 0, reason: 'a one-time code held for later would be refused on arrival');

    session.dispose();
  });

  testWidgets('the welcome email code signs the phone in', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final asked = scannerReads('KEMP1-ACT:welcome-code');
    final sent = <http.Request>[];

    final session = Session(
      api: ApiClient(
        client: MockClient((request) async {
          sent.add(request);
          if (request.url.path.endsWith('/auth/activate')) {
            return json({'ok': true, 'token': 'new-token', 'user': user()});
          }
          return json({'ok': true});
        }),
      ),
      cache: OfflineCache(directory: dir),
      queue: PunchQueue(directory: dir),
    );

    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 900));
    await tester.pumpWidget(SessionScope(
      notifier: session,
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocale.supported,
        home: const LoginScreen(),
      ),
    ));
    await settle(tester);

    await tester.tap(find.text('Sign in with QR'));
    await settle(tester);

    expect(asked, [activationQrPrefix]);
    final activate = sent.singleWhere((r) => r.url.path.endsWith('/auth/activate'));
    final body = jsonDecode(activate.body) as Map<String, dynamic>;
    expect(body['code'], 'KEMP1-ACT:welcome-code');
    expect(body['device_id'], isA<String>(), reason: 'device binding applies to this door too');
    expect(session.isSignedIn, isTrue);

    session.dispose();
  });

  testWidgets('a spent welcome code says so on the form', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    scannerReads('KEMP1-ACT:old');

    final session = Session(
      api: ApiClient(
        client: MockClient((request) async => json(
              {'ok': false, 'error': 'activation_expired', 'message': 'That sign-in code has expired.'},
              422,
            )),
      ),
      cache: OfflineCache(directory: dir),
      queue: PunchQueue(directory: dir),
    );

    await tester.pumpWidget(SessionScope(
      notifier: session,
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocale.supported,
        home: const LoginScreen(),
      ),
    ));
    await settle(tester);

    await tester.tap(find.text('Sign in with QR'));
    await settle(tester);

    expect(find.text('That sign-in code has expired.'), findsOneWidget);
    expect(session.isSignedIn, isFalse);

    session.dispose();
  });
}
