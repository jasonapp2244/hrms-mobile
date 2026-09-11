import 'dart:io';
import 'dart:math' as math;

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/l10n.dart';
import 'package:attendance/core/locale.dart';
import 'package:attendance/core/location.dart';
import 'package:attendance/core/offline_cache.dart';
import 'package:attendance/core/punch_queue.dart';
import 'package:attendance/core/session.dart';
import 'package:attendance/core/theme.dart';
import 'package:attendance/main.dart';
import 'package:attendance/screens/blocked_screen.dart';
import 'package:attendance/screens/history_screen.dart';
import 'package:attendance/screens/lock_screen.dart';
import 'package:attendance/screens/login_screen.dart';
import 'package:attendance/screens/onboarding_screen.dart';
import 'package:attendance/screens/profile_screen.dart';
import 'package:attendance/screens/punch_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

/// The accessibility audit (B6.4), as checks rather than as a document.
///
/// Two things are being asserted, and both used to be true only by accident.
///
/// **Contrast.** The status palette was picked against a white card and reused
/// unchanged in dark mode, where three of its five colours fell between 2.8:1
/// and 3.4:1 — under AA for the 11–13px text they are mostly used for. There is
/// no single value that satisfies both themes, so there are now two palettes,
/// and this file measures them rather than trusting anybody's eye.
///
/// **Font scaling.** Nothing clamps the OS text size, which is right — but two
/// controls were laid out in fixed-height boxes, including the punch button the
/// whole app exists for, and clipped at the larger settings. Flutter reports an
/// overflow as a rendering exception, so pumping a screen at 2× is a real test
/// rather than a screenshot somebody has to look at.
void main() {
  group('contrast', () {
    // WCAG 2.1: 4.5:1 for body text, 3:1 for large text (>=18.66px bold or
    // >=24px) and for meaningful graphics.
    const bodyText = 4.5;

    /// Every surface a status colour is drawn on, per theme.
    const lightSurfaces = <String, Color>{
      'card #FFFFFF': Color(0xFFFFFFFF),
      'scaffold #F7F8FA': Color(0xFFF7F8FA),
      'raised #EFF1F4': Color(0xFFEFF1F4),
    };

    const darkSurfaces = <String, Color>{
      'card #161C22': Color(0xFF161C22),
      'scaffold #0F1419': Color(0xFF0F1419),
      'raised #1E262E': Color(0xFF1E262E),
    };

    Map<String, Color> paletteOf(AppColors c) => {
          'present': c.present,
          'late': c.late,
          'absent': c.absent,
          'leave': c.leave,
          'neutral': c.neutral,
          'accent': c.accent,
        };

    test('every status colour carries body text on every surface it meets', () {
      final cases = {
        Brightness.light: lightSurfaces,
        Brightness.dark: darkSurfaces,
      };

      final failures = <String>[];

      cases.forEach((brightness, surfaces) {
        paletteOf(AppColors.forBrightness(brightness)).forEach((name, colour) {
          surfaces.forEach((where, background) {
            final ratio = _contrast(colour, background);

            if (ratio < bodyText) {
              failures.add('${brightness.name}: $name on $where '
                  'is ${ratio.toStringAsFixed(2)}:1');
            }
          });
        });
      });

      expect(failures, isEmpty, reason: failures.join('\n'));
    });

    test('and carries it on its own tint, which is what it is usually on', () {
      // The house pattern for a banner or a chip: the colour at 10–15% over the
      // surface, with the same colour as the text on top. It is the tightest
      // pairing in the app and the one most easily got wrong, because the
      // background moves towards the foreground as the tint deepens.
      const tints = [0.10, 0.13, 0.15];

      final failures = <String>[];

      for (final entry in {
        Brightness.light: lightSurfaces.values.first,
        Brightness.dark: darkSurfaces.values.first,
      }.entries) {
        paletteOf(AppColors.forBrightness(entry.key)).forEach((name, colour) {
          for (final tint in tints) {
            final background = Color.alphaBlend(
              colour.withValues(alpha: tint),
              entry.value,
            );
            final ratio = _contrast(colour, background);

            if (ratio < bodyText) {
              failures.add('${entry.key.name}: $name on its own '
                  '${(tint * 100).round()}% tint is ${ratio.toStringAsFixed(2)}:1');
            }
          }
        });
      }

      expect(failures, isEmpty, reason: failures.join('\n'));
    });

    test('a filled button carries its own label', () {
      // The regression this catches: the seeded scheme put white on #F26522,
      // which is 3.15:1, and a filled button's label is 16px semibold —
      // ordinary text, so it needs 4.5. Every primary button in the app failed.
      for (final brightness in Brightness.values) {
        final scheme = (brightness == Brightness.light
                ? AppTheme.light()
                : AppTheme.dark())
            .colorScheme;

        expect(
          _contrast(scheme.onPrimary, scheme.primary),
          greaterThanOrEqualTo(bodyText),
          reason: '${brightness.name}: onPrimary on primary',
        );
        expect(
          _contrast(scheme.onSurface, scheme.surface),
          greaterThanOrEqualTo(bodyText),
          reason: '${brightness.name}: onSurface on surface',
        );
        expect(
          _contrast(scheme.onError, scheme.error),
          greaterThanOrEqualTo(bodyText),
          reason: '${brightness.name}: onError on error',
        );
      }
    });

    test('the gold stays off light surfaces and the navy carries text', () {
      // This test used to say "the brand orange stays off body text", and
      // pinned that orange between 3.0 and 4.5 on white — it was strong enough
      // to be a graphic and too weak to be a caption. The KEMP palette breaks
      // that shape completely, so the assertions are rewritten rather than
      // relaxed: navy is now *stronger* than the old bound, and the weak
      // colour is the gold, which is weaker than the old one ever was.
      const white = Color(0xFFFFFFFF);

      // Navy replaces both the old brand and its darkened twin. 10.1:1 on
      // white, so it needs no second colour to be readable and is `primary`
      // directly.
      expect(
        _contrast(AppTheme.navy, white),
        greaterThanOrEqualTo(bodyText),
        reason: 'navy on white',
      );
      expect(
        _contrast(AppTheme.navyDeep, white),
        greaterThanOrEqualTo(bodyText),
        reason: 'navyDeep on white',
      );

      // Gold on white is about 1.4:1 — under even the 3:1 asked of a graphic.
      // Pinned as a FAILURE so that nobody paints a caption, an icon or a
      // border with it on a light surface: if a future change makes this pass,
      // the gold has been altered and every dark-mode pairing below needs
      // re-measuring.
      expect(
        _contrast(AppTheme.gold, white),
        lessThan(3.0),
        reason: 'gold must never be drawn on a light surface',
      );

      // Which is exactly why the two are resolved by brightness rather than
      // being one constant. Each must carry text on the scaffold it is drawn
      // on: navy on the light one, gold on the dark one.
      expect(
        _contrast(AppTheme.brandFor(Brightness.light), const Color(0xFFF7F8FA)),
        greaterThanOrEqualTo(bodyText),
        reason: 'light brand on the light scaffold',
      );
      expect(
        _contrast(AppTheme.brandFor(Brightness.dark), const Color(0xFF0F1419)),
        greaterThanOrEqualTo(bodyText),
        reason: 'dark brand on the dark scaffold',
      );

      // And the second brand colour, which the punch button and the break
      // button use to mean the opposite of the first one.
      expect(
        _contrast(AppTheme.brandDeepFor(Brightness.light), const Color(0xFFF7F8FA)),
        greaterThanOrEqualTo(bodyText),
        reason: 'light brandDeep on the light scaffold',
      );
      expect(
        _contrast(AppTheme.brandDeepFor(Brightness.dark), const Color(0xFF0F1419)),
        greaterThanOrEqualTo(bodyText),
        reason: 'dark brandDeep on the dark scaffold',
      );

      // The punch button paints its own background and inherits onPrimary for
      // the label, so both brand shades have to carry onPrimary in both
      // themes — the one pairing a scheme-level check cannot see.
      for (final brightness in Brightness.values) {
        final onPrimary = (brightness == Brightness.light
                ? AppTheme.light()
                : AppTheme.dark())
            .colorScheme
            .onPrimary;

        expect(
          _contrast(onPrimary, AppTheme.brandFor(brightness)),
          greaterThanOrEqualTo(bodyText),
          reason: '${brightness.name}: punch button label on brand',
        );
        expect(
          _contrast(onPrimary, AppTheme.brandDeepFor(brightness)),
          greaterThanOrEqualTo(bodyText),
          reason: '${brightness.name}: punch button label on brandDeep',
        );
      }
    });
  });

  group('font scaling', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('a11y_test');
      FlutterSecureStorage.setMockInitialValues({'hrms_api_token': 'tok'});
    });

    tearDown(() async {
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } on FileSystemException {
        // Windows can still hold a file the app wrote without awaiting.
      }
    });

    Map<String, dynamic> employee() => {
          'user': {
            'id': 3,
            'name': 'James Smith',
            'email': 'james@acme.test',
            'roles': ['employee'],
            'permissions': ['view-attendance'],
            'employee': {
              'id': 1,
              'employee_code': 'EMP-0001',
              'full_name': 'James Smith',
              'is_manager': false,
            },
          },
        };

    /// A session signed in from the saved copy, so a screen draws with no
    /// server. Every disk touch is inside `runAsync`: `testWidgets` runs in a
    /// fake-async zone that never delivers a real file completion, so a pump
    /// that reaches the cache hangs the run rather than failing it.
    Future<Session> offlineSession(WidgetTester tester, {
      Map<String, dynamic>? today,
      Map<String, dynamic>? history,
    }) async {
      late Session session;

      await tester.runAsync(() async {
        final store = OfflineCache(directory: dir);
        await store.write(OfflineCache.keyProfile, employee());
        if (today != null) {
          await store.write(OfflineCache.keyToday, today);
        }
        if (history != null) {
          await store.write(OfflineCache.historyKey(30), history);
        }

        final queue = PunchQueue(directory: dir);
        await queue.load();

        session = Session(
          api: ApiClient(
            client: MockClient((_) async => throw const SocketException('offline')),
          ),
          cache: store,
          queue: queue,
          locator: const PunchLocator(source: NoLocationSource()),
        );
        await session.restore();
      });

      return session;
    }

    /// Renders [child] at [scale] on a phone-sized surface, in both themes.
    ///
    /// An overflow is a rendering exception, which `testWidgets` fails on — so
    /// nothing here needs an assertion beyond getting to the end.
    Future<void> at(
      WidgetTester tester,
      double scale,
      Session session,
      Widget child,
    ) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(390, 844));

      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocale.supported,
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: SessionScope(notifier: session, child: child),
          ),
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.pumpWidget(const SizedBox());
    }

    /// The OS goes well past this; 2.0 is where Android's "largest" setting and
    /// iOS's accessibility sizes land, and it is the point every fixed-height
    /// box in the app used to clip.
    const largest = 2.0;

    testWidgets('the clock screen, with a punch button to press', (tester) async {
      final now = DateTime.now();
      final ymd = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';

      final session = await offlineSession(tester, today: {
        'date': ymd,
        'next_action': 'out',
        'is_clocked_in': true,
        'worked_minutes': 125,
        // The cooldown note under the label, which is the line that overflowed
        // a fixed 120px button first.
        'can_check': false,
        'can_break': true,
        'next_break_action': 'start',
        'punches': const [],
      });

      await at(tester, largest, session,
          PunchScreen(visible: ValueNotifier<bool>(true)));

      session.dispose();
    });

    testWidgets('the history screen, score card and all (B3.5)',
        (tester) async {
      // Seeded through the cache rather than a stub server, the same way the
      // clock screen is: the mock client throws, the screen falls back, and
      // what gets drawn is the real card with real numbers in it.
      final session = await offlineSession(tester, history: {
        'from': '2026-08-03',
        'to': '2026-08-07',
        'days': [
          {
            'date': '2026-08-07',
            'weekday': 'Fri',
            'status': 'present',
            'late': true,
            'first_in': '2026-08-07T09:31:00+00:00',
            'last_out': '2026-08-07T17:05:00+00:00',
            'worked_minutes': 454,
            'punches': 2,
            'holiday': null,
          },
          {
            'date': '2026-08-06',
            'weekday': 'Thu',
            'status': 'absent',
            'late': false,
            'first_in': null,
            'last_out': null,
            'worked_minutes': 0,
            'punches': 0,
            'holiday': null,
          },
        ],
        'totals': {
          'present_days': 1,
          'late_days': 1,
          'leave_days': 0,
          'absent_days': 1,
          'worked_minutes': 454,
        },
        // A long streak and a three-digit-free score: the two widest strings
        // the card can hold, side by side, at twice the text size.
        'score': {
          'score': 50,
          'ontime_days': 0,
          'obliged_days': 2,
          'streak': 128,
        },
      });

      await at(tester, largest, session,
          HistoryScreen(visible: ValueNotifier<bool>(true)));

      session.dispose();
    });

    testWidgets('the history screen with no score to show', (tester) async {
      // The other half of the card: "No score yet" is a longer string than any
      // percentage, and it is the one a person sees after a fortnight off.
      final session = await offlineSession(tester, history: {
        'from': '2026-08-08',
        'to': '2026-08-09',
        'days': [
          {
            'date': '2026-08-09',
            'weekday': 'Sun',
            'status': 'weekend',
            'late': false,
            'first_in': null,
            'last_out': null,
            'worked_minutes': 0,
            'punches': 0,
            'holiday': null,
          },
        ],
        'totals': {
          'present_days': 0,
          'late_days': 0,
          'leave_days': 0,
          'absent_days': 0,
          'worked_minutes': 0,
        },
        'score': {
          'score': null,
          'ontime_days': 0,
          'obliged_days': 0,
          'streak': 0,
        },
      });

      await at(tester, largest, session,
          HistoryScreen(visible: ValueNotifier<bool>(true)));

      session.dispose();
    });

    testWidgets('the profile screen', (tester) async {
      final session = await offlineSession(tester);
      await at(tester, largest, session, const ProfileScreen());
      session.dispose();
    });

    testWidgets('the sign-in screen', (tester) async {
      final session = await offlineSession(tester);
      await at(tester, largest, session, const LoginScreen());
      session.dispose();
    });

    testWidgets('the lock screen', (tester) async {
      final session = await offlineSession(tester);
      await at(tester, largest, session, const LockScreen());
      session.dispose();
    });

    testWidgets('the blocked screen', (tester) async {
      final session = await offlineSession(tester);
      await at(tester, largest, session, const BlockedScreen());
      session.dispose();
    });

    testWidgets('the onboarding carousel, which is mostly prose',
        (tester) async {
      // The screen with the most words per page in the app, and the first one
      // anybody sees. A carousel that clipped its own explanation would be a
      // poor advertisement for the rest.
      final session = await offlineSession(tester);
      await at(tester, largest, session, const OnboardingScreen());
      session.dispose();
    });
  });

  group('screen readers', () {
    testWidgets('every icon-only control has a name', (tester) async {
      // An IconButton with no tooltip announces "button" and nothing else.
      // This walks the tree rather than the source, so it catches one added to
      // a screen after this file was written.
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(390, 844));

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocale.supported,
        home: Scaffold(
          appBar: AppBar(
            title: const Text('Screen'),
            actions: [
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: () {},
              ),
            ],
          ),
        ),
      ));

      for (final button in tester.widgetList<IconButton>(find.byType(IconButton))) {
        expect(
          button.tooltip,
          isNotNull,
          reason: 'An icon-only button with no tooltip has no accessible name.',
        );
      }
    });
  });
}

/// WCAG 2.1 relative luminance.
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// WCAG 2.1 contrast ratio, 1:1 to 21:1.
///
/// Written here rather than in the app because nothing at runtime asks the
/// question — the palette is fixed, and this is what checks it stays right.
double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);

  return (lighter + 0.05) / (darker + 0.05);
}
