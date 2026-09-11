import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';

/// The app's visual language, taken from the KEMP mark rather than invented —
/// the same navy and gold as the icon, the web dashboard and the favicon, so
/// the phone and the browser read as one product.
///
/// **The navy and the gold are not interchangeable, and that is the whole
/// reason this class has four colours rather than one.** Navy is dark
/// (relative luminance 0.054) and gold is bright (0.70), so each is legible on
/// exactly the surfaces the other is not: navy carries white text and vanishes
/// on a dark background, gold carries black text and vanishes on white. The
/// orange these replaced sat between the two and was legible on neither —
/// white on it measured 3.15:1 and failed on every button in the app.
class AppTheme {
  /// KEMP navy — the plate the K sits on, and the interactive colour in light
  /// mode. White on it is 10.1:1, so unlike the orange it replaced this one
  /// **can** carry body text, and it is `primary` directly rather than needing
  /// a darkened twin.
  static const Color navy = Color(0xFF033C93);

  /// The bottom of the mark's gradient. Used where two navy controls sit
  /// together and have to be told apart — the punch button's checked-in state
  /// against its checked-out one, and the break button's outline. White on it
  /// is 15.8:1.
  static const Color navyDeep = Color(0xFF01174B);

  /// KEMP gold — the swoosh. **Identity and dark-mode primary, never text on a
  /// light surface**: on white it measures 1.4:1, which fails even the 3:1 WCAG
  /// asks of a graphic. On navy it is 9.4:1 and on near-black 15:1, so it is
  /// `primary` in dark mode with [onGold] on it, and it draws the mark on any
  /// dark ground. `accessibility_test.dart` pins both halves of that.
  static const Color gold = Color(0xFFFDD810);

  /// What sits on [gold]. Near-black rather than pure black, to echo the mark's
  /// own deep navy rather than introduce a fifth colour.
  static const Color onGold = Color(0xFF1A1500);

  /// The identity colour for the surface it is about to be drawn on: navy on a
  /// light background, gold on a dark one.
  ///
  /// A single constant cannot do this job, which is why `brand` is gone. Navy
  /// on the dark scaffold (#0F1419) is 1.4:1 — a splash mark nobody can see —
  /// and gold on white is the same number the other way up. Every caller that
  /// draws the mark, an accent icon or a focus ring comes through here.
  static Color brandOf(BuildContext context) =>
      brandFor(Theme.of(context).brightness);

  /// As [brandOf], for a theme being built or a test with no context.
  static Color brandFor(Brightness brightness) =>
      brightness == Brightness.dark ? gold : navy;

  /// Gold taken down far enough to be visibly a second colour beside [gold]
  /// while still carrying [onGold] at 8.8:1. The dark-mode counterpart of
  /// [navyDeep].
  static const Color goldDeep = Color(0xFFD4B200);

  /// The *second* brand colour for this surface — [navyDeep] on light,
  /// [goldDeep] on dark.
  ///
  /// Exists because two controls on the clock screen are both brand-coloured
  /// and mean opposite things: Check In against Check Out, and the button that
  /// ends a break. Telling them apart by shade only works if the shade moves
  /// with the theme; a fixed navy would be an invisible button on a dark
  /// handset, and near-black-on-navy for its label.
  static Color brandDeepOf(BuildContext context) =>
      brandDeepFor(Theme.of(context).brightness);

  /// As [brandDeepOf], without a context.
  static Color brandDeepFor(Brightness brightness) =>
      brightness == Brightness.dark ? goldDeep : navyDeep;

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    // fromSeed harmonises the seed into a tonal palette, which turns the navy
    // into a muted slate for `primary` — recognisably not the brand. The seed
    // still earns its keep for every secondary and container tone, so keep it
    // and put the exact brand colours back on the roles people actually see.
    final seeded = ColorScheme.fromSeed(seedColor: navy, brightness: brightness);

    final scheme = seeded.copyWith(
      // A filled button's label is 16px semibold — ordinary text by WCAG's
      // reckoning, so it needs 4.5:1, and this pair is the one that decides
      // whether every button in the app passes.
      //
      // The two themes take opposite halves of the mark. Light mode is white
      // on navy at 10.1:1. Dark mode is near-black on gold at 15:1 — navy on
      // the dark scaffold would be 1.4:1, a button you cannot see, and a light
      // primary carrying a dark label is what a Material dark scheme does
      // anyway. Both are a long way clear of the 4.5 the old orange missed.
      primary: brightness == Brightness.light ? navy : gold,
      onPrimary: brightness == Brightness.light ? Colors.white : onGold,
      // Neutral surfaces rather than the seed's navy-tinted ones: a coloured
      // wash behind every text field reads as a validation state.
      surface: brightness == Brightness.light
          ? const Color(0xFFFFFFFF)
          : const Color(0xFF161C22),
      surfaceContainerHighest: brightness == Brightness.light
          ? const Color(0xFFEFF1F4)
          : const Color(0xFF1E262E),
      outlineVariant: brightness == Brightness.light
          ? const Color(0xFFDCE2E8)
          : const Color(0xFF28313A),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          brightness == Brightness.light ? const Color(0xFFF7F8FA) : const Color(0xFF0F1419),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 1,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        titleTextStyle: TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          // Not const any more: the focus ring has to be gold on a dark form
          // and navy on a light one, or it is a 1.4:1 outline on one of them.
          borderSide: BorderSide(color: brandFor(brightness), width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

}

/// The status colours, resolved for the brightness they will be drawn on
/// (B6.4).
///
/// **There is no single value that works in both themes**, which is why these
/// are not constants any more. Readable body text on white needs a relative
/// luminance at or below about 0.17; readable body text on #1E262E needs one at
/// or above about 0.26. Nothing satisfies both. The old palette was picked
/// against white and reused unchanged in dark mode, where `present`, `absent`
/// and `leave` came out between 2.8:1 and 3.4:1 — under AA for the 11–13px text
/// they were mostly used for, and under *everything* on the raised surfaces.
///
/// Every value here clears **4.5:1 on the worst surface it is drawn on**,
/// including its own 10–15% tint, which is the background these colours are
/// most often paired with. `test/accessibility_test.dart` measures them rather
/// than trusting this comment.
@immutable
class AppColors {
  const AppColors._({
    required this.present,
    required this.late,
    required this.absent,
    required this.leave,
    required this.neutral,
    required this.accent,
  });

  /// Was there, on time.
  final Color present;

  /// Turned up late, or something expires soon — the warning hue.
  final Color late;

  /// Did not turn up, or something has expired.
  final Color absent;

  /// Booked off.
  final Color leave;

  /// A weekend, a holiday, a day off — nothing to answer for.
  final Color neutral;

  /// The brand colour where it has to be *read* rather than seen: small labels
  /// on a tinted chip — the 10px "rostered" pill, the avatar initials.
  ///
  /// Light mode is the navy itself, which needs no darkened twin the way the
  /// old orange did: it is 8.6:1 on its own 15% tint. Dark mode is the gold,
  /// for the same reason the dark primary is.
  final Color accent;

  static const _light = AppColors._(
    present: Color(0xFF186B48),
    // Was #A8720C: 4.14:1 on white, which is under AA for the 13px banner text
    // it is used for.
    late: Color(0xFF7E5709),
    absent: Color(0xFFA13E36),
    leave: Color(0xFF33609D),
    neutral: Color(0xFF566069),
    accent: AppTheme.navy,
  );

  static const _dark = AppColors._(
    present: Color(0xFF2AB57B),
    late: Color(0xFFCE9730),
    absent: Color(0xFFD78D87),
    leave: Color(0xFF7FA4D6),
    neutral: Color(0xFF9AA3AC),
    accent: AppTheme.gold,
  );

  static AppColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? _dark : _light;

  /// For a test, or anywhere without a [BuildContext].
  static AppColors forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;

  /// One vocabulary for a day's status, shared by the history list and the
  /// manager's team view — the server computes both with the same code, so they
  /// must never render as two different words.
  ///
  /// The status itself is a server key and stays English; only the word drawn
  /// from it is translated. A key this build has never heard of falls through
  /// to the raw value, which is at least honest about what the server said.
  (Color, String) statusStyle(AppLocalizations t, String status) => switch (status) {
        'present' => (present, t.statusPresent),
        'leave' => (leave, t.statusOnLeave),
        'holiday' => (neutral, t.statusHoliday),
        'day_off' => (neutral, t.statusDayOff),
        'weekend' => (neutral, t.statusWeekend),
        'absent' => (absent, t.statusAbsent),
        _ => (neutral, status.isEmpty ? '—' : status),
      };
}

/// Formatting helpers used across screens.
///
/// **Every one of them takes the strings rather than reading a global.** They
/// are all called from a `build`, where `context.t` is one getter away, and a
/// static "current language" would be one more thing that has to be set before
/// the first frame and reset between tests — for a saving of one argument at
/// two dozen call sites.
///
/// Month and weekday names come from the ARB files and not from intl's
/// `DateFormat`, which needs `initializeDateFormatting` to have been called
/// first and throws at the moment a date is drawn when it has not. That is
/// every screen in the app, and it would be a launch-time failure introduced by
/// a translation change.
class Fmt {
  /// "2026-08-04" → "4 Aug". Parsed as a plain calendar date: these strings
  /// carry no timezone and adding one would shift the day.
  static String shortDate(AppLocalizations t, String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    return t.dateShort('${d.day}', monthShort(t, d.month));
  }

  static String longDate(AppLocalizations t, String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    return t.dateLong('${d.day}', monthLong(t, d.month), '${d.year}');
  }

  /// 1–12 → "Jan". A switch rather than a list because the generated getters
  /// are twelve separate members, so there is nothing to index into.
  static String monthShort(AppLocalizations t, int month) => switch (month) {
        1 => t.monthShort1,
        2 => t.monthShort2,
        3 => t.monthShort3,
        4 => t.monthShort4,
        5 => t.monthShort5,
        6 => t.monthShort6,
        7 => t.monthShort7,
        8 => t.monthShort8,
        9 => t.monthShort9,
        10 => t.monthShort10,
        11 => t.monthShort11,
        _ => t.monthShort12,
      };

  static String monthLong(AppLocalizations t, int month) => switch (month) {
        1 => t.monthLong1,
        2 => t.monthLong2,
        3 => t.monthLong3,
        4 => t.monthLong4,
        5 => t.monthLong5,
        6 => t.monthLong6,
        7 => t.monthLong7,
        8 => t.monthLong8,
        9 => t.monthLong9,
        10 => t.monthLong10,
        11 => t.monthLong11,
        _ => t.monthLong12,
      };

  /// `DateTime.weekday`, 1 = Monday, → "Mon".
  ///
  /// Also the way a weekday the **server** named is translated: the roster and
  /// the history list both carry a `weekday` string in the response, written in
  /// English by a server that has no idea who is reading it. [weekdayNamed]
  /// turns one back into a number so it can be drawn in the right language.
  static String weekdayShort(AppLocalizations t, int weekday) => switch (weekday) {
        DateTime.monday => t.weekdayShort1,
        DateTime.tuesday => t.weekdayShort2,
        DateTime.wednesday => t.weekdayShort3,
        DateTime.thursday => t.weekdayShort4,
        DateTime.friday => t.weekdayShort5,
        DateTime.saturday => t.weekdayShort6,
        _ => t.weekdayShort7,
      };

  /// "Mon", "Monday", "mon" → the translated short name.
  ///
  /// Falls back to whatever the server sent when it is not a weekday this
  /// understands. Showing an English word is a smaller failure than showing
  /// nothing where a day name belongs.
  static String weekdayNamed(AppLocalizations t, String english) {
    const index = {
      'mon': DateTime.monday,
      'tue': DateTime.tuesday,
      'wed': DateTime.wednesday,
      'thu': DateTime.thursday,
      'fri': DateTime.friday,
      'sat': DateTime.saturday,
      'sun': DateTime.sunday,
    };

    if (english.length < 3) return english;
    final weekday = index[english.substring(0, 3).toLowerCase()];

    return weekday == null ? english : weekdayShort(t, weekday);
  }

  /// Minutes → "7h 14m". Used for worked time, which is never a bare number
  /// anyone wants to read.
  static String duration(AppLocalizations t, int minutes) {
    if (minutes <= 0) return t.durationMinutes(0);
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return t.durationMinutes(m);
    if (m == 0) return t.durationHours(h);
    return t.durationHoursMinutes(h, m);
  }

  /// Day counts arrive as JSON numbers and a half day is 0.5, so "1 day" and
  /// "0.5 days" both have to render correctly.
  ///
  /// The number is formatted here and the plural is chosen from a separate
  /// integer, because ICU would count 0.5 as "other" in English and as "one" in
  /// languages that treat a fraction that way — and this is a count of days
  /// booked, where only exactly one is singular.
  static String days(AppLocalizations t, double d) {
    final amount = d == d.roundToDouble() ? d.toInt().toString() : d.toString();
    return t.dayCount(amount, d == 1 ? 1 : 2);
  }

  /// When a cached copy was saved, for the offline banner — "today at 14:02",
  /// "yesterday at 08:15", "4 Sep at 09:00".
  ///
  /// The one place a **handset-local** time is the right one to show. Every
  /// other timestamp in the app is a work time and reads in the company zone;
  /// this one is not about work at all, it is about when this phone last
  /// managed to ask, so it belongs on the phone's own clock.
  static String savedAt(AppLocalizations t, DateTime when) {
    final at = when.toLocal();
    final clock = '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';

    final today = DateUtils.dateOnly(DateTime.now());
    final day = DateUtils.dateOnly(at);
    final daysBack = today.difference(day).inDays;

    return switch (daysBack) {
      0 => t.savedToday(clock),
      1 => t.savedYesterday(clock),
      _ => t.savedOn(shortDate(t, day.toIso8601String()), clock),
    };
  }

  /// A date range where a single day does not read as "4 Aug – 4 Aug".
  static String range(AppLocalizations t, String start, String end) => start == end
      ? longDate(t, start)
      : t.dateRange(shortDate(t, start), shortDate(t, end));

  /// "2026-08-03T18:00:00-04:00" → "06:00 PM".
  ///
  /// Parsed **without** converting to the handset's zone. These timestamps
  /// already carry the company's offset, and `DateTime.parse` on an offset
  /// string yields a moment that `.hour` then reports in local time — so a
  /// punch made at 18:00 in New York would read as 23:00 to somebody whose
  /// phone is on London time. The wall-clock reading is the one that matters
  /// here: it is the time the person was, or should have been, at work.
  static String timeOf(AppLocalizations t, String iso) {
    final match = RegExp(r'T(\d{2}):(\d{2})').firstMatch(iso);
    if (match == null) return iso;

    final hour = int.tryParse(match.group(1)!) ?? 0;
    final minute = match.group(2)!;
    final suffix = hour < 12 ? t.timeAm : t.timePm;
    final twelve = hour % 12 == 0 ? 12 : hour % 12;

    return '${twelve.toString().padLeft(2, '0')}:$minute $suffix';
  }
}
