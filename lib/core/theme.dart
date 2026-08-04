import 'package:flutter/material.dart';

/// The app's visual language, taken from the web dashboard rather than invented
/// — #F26522 is the orange the logo and favicon were recoloured to, so the
/// phone and the browser read as one product.
class AppTheme {
  static const Color brand = Color(0xFFF26522);
  static const Color brandDeep = Color(0xFFC44E14);

  // Status colours. Kept separate from the brand accent on purpose: "late" must
  // not be the same hue as a primary button, or a warning stops reading as one.
  static const Color present = Color(0xFF1B7A52);
  static const Color late = Color(0xFFA8720C);
  static const Color absent = Color(0xFFB4453C);
  static const Color leave = Color(0xFF3B6FB6);
  static const Color neutral = Color(0xFF6C7884);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    // fromSeed harmonises the seed into a tonal palette, which turns #F26522
    // into a muted brown for `primary` — recognisably not the brand. The seed
    // still earns its keep for every secondary and container tone, so keep it
    // and put the exact brand colour back on the roles people actually see.
    final seeded = ColorScheme.fromSeed(seedColor: brand, brightness: brightness);

    final scheme = seeded.copyWith(
      primary: brightness == Brightness.light ? brand : const Color(0xFFFF7B3C),
      onPrimary: Colors.white,
      // Neutral surfaces rather than the seed's orange-tinted ones: an
      // orange wash behind every text field reads as a validation state.
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
          borderSide: const BorderSide(color: brand, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  /// One vocabulary for a day's status, shared by the history list and the
  /// manager's team view — the server computes both with the same code, so they
  /// must never render as two different words.
  static (Color, String) statusStyle(String status) => switch (status) {
        'present' => (present, 'Present'),
        'leave' => (leave, 'On leave'),
        'holiday' => (neutral, 'Holiday'),
        'day_off' => (neutral, 'Day off'),
        'weekend' => (neutral, 'Weekend'),
        'absent' => (absent, 'Absent'),
        _ => (neutral, status.isEmpty ? '—' : status),
      };
}

/// Formatting helpers used across screens.
class Fmt {
  /// "2026-08-04" → "Tue 4 Aug". Parsed as a plain calendar date: these strings
  /// carry no timezone and adding one would shift the day.
  static String shortDate(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month - 1]}';
  }

  static String longDate(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  /// Minutes → "7h 14m". Used for worked time, which is never a bare number
  /// anyone wants to read.
  static String duration(int minutes) {
    if (minutes <= 0) return '0m';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }

  /// Day counts arrive as JSON numbers and a half day is 0.5, so "1 day" and
  /// "0.5 days" both have to render correctly.
  static String days(double d) {
    final text = d == d.roundToDouble() ? d.toInt().toString() : d.toString();
    return '$text ${d == 1 ? 'day' : 'days'}';
  }

  /// A date range where a single day does not read as "4 Aug – 4 Aug".
  static String range(String start, String end) =>
      start == end ? longDate(start) : '${shortDate(start)} – ${shortDate(end)}';
}
