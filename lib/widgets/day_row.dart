import 'package:flutter/material.dart';

import '../core/l10n.dart';
import '../core/models.dart';
import '../core/theme.dart';

/// One day of attendance, as a list row.
///
/// Shared by the employee's own History screen and by HR reading somebody
/// else's, because the two are the same row and not merely a similar one — a
/// day that reads "Present · late · 7h 14m" to the person who worked it must
/// read the same to the person asking them about it.
///
/// **The extra fields are drawn only when the server sent them.**
/// `/attendance/history` reports nine fields per day and
/// `/hr/employees/{id}/attendance` reports sixteen, so the break line and the
/// early-leave flag simply do not appear on the employee's own screen. That is
/// not a degraded rendering, it is the same rendering with nothing extra to
/// say — see [HistoryDay].
class DayRow extends StatelessWidget {
  const DayRow({super.key, required this.day, this.onTap});

  final HistoryDay day;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final t = context.t;
    final (color, label) = colors.statusStyle(t, day.status);

    return ListTile(
      onTap: onTap,
      leading: SizedBox(
        width: 46,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              // English on the wire, whoever is reading it.
              Fmt.weekdayNamed(t, day.weekday),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              Fmt.shortDate(t, day.date),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ],
        ),
      ),
      // A Wrap, not a Row: a day can be late *and* have left early, and the
      // pill plus both flags does not fit the tile's title on a narrow phone.
      // As a Row it overflowed by 109px, which draws the striped bar and hides
      // the second flag entirely — the one case where both matter most.
      title: Wrap(
        spacing: 6,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (day.late)
            Text(
              t.historyLateFlag,
              style: TextStyle(color: colors.late, fontSize: 11.5),
            ),
          if (day.earlyLeave)
            Text(
              t.historyEarlyFlag,
              style: TextStyle(color: colors.late, fontSize: 11.5),
            ),
        ],
      ),
      subtitle: _subtitle(context, t, theme),
      trailing: day.workedMinutes > 0
          ? Text(
              Fmt.duration(t, day.workedMinutes),
              style: const TextStyle(fontWeight: FontWeight.w600),
            )
          : null,
    );
  }

  /// The punch line, and a break line under it when there is one.
  ///
  /// A single `Text` when there is nothing extra to say, so the row a history
  /// screen has always drawn keeps the height it has always had.
  Widget? _subtitle(BuildContext context, AppLocalizations t, ThemeData theme) {
    final punches = _punchLine(t);
    final breaks = _breakLine(t);
    final note = day.remarks;

    if (breaks == null && note == null) {
      return punches == null ? null : Text(punches);
    }

    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (punches != null) Text(punches),
        if (breaks != null) Text(breaks, style: quiet),
        if (note != null) Text(note, style: quiet),
      ],
    );
  }

  String? _punchLine(AppLocalizations t) {
    if (day.holiday != null) return day.holiday;
    if (day.firstIn == null) return null;

    return t.historyInAt(clockOf(day.firstIn!)) +
        (day.lastOut != null
            ? t.historyOutAt(clockOf(day.lastOut!))
            : t.historyStillOpen) +
        // More than a single in-and-out. The two times above are the FIRST
        // entry and the LAST exit, so the total beside them does not span the
        // gap between — a day running 15:09 to 16:42 can read 22m and be
        // right. Without this the row looks like broken arithmetic, and the
        // count is the cheapest thing that explains it.
        (day.punches > 2 ? t.historyPunchCount(day.punches) : '');
  }

  /// Null when this endpoint does not report breaks, and null again when it
  /// does and there was not one — a day with no break has nothing to say about
  /// breaks, and a line reading "0m" is noise on every ordinary day.
  String? _breakLine(AppLocalizations t) {
    // Several breaks. The two times are the first start and the last end — an
    // envelope, not a break — so 11:00 – 13:45 beside "1h" would read as
    // broken arithmetic. The count and the total are the two true numbers.
    final count = day.breakCount;
    if (count != null && count > 1) {
      return t.historyBreakCount(count, Fmt.duration(t, day.breakMinutes ?? 0));
    }

    final start = day.breakStart;
    if (start == null) return null;

    final end = day.breakEnd;

    // A break punched in and never punched out. It costs nothing — its length
    // is unknown, so the total below excludes it — and saying so is the only
    // way the number beside it reads correctly.
    if (end == null) return t.historyBreakOpen(clockOf(start));

    return t.historyBreakLine(
      clockOf(start),
      clockOf(end),
      Fmt.duration(t, day.breakMinutes ?? 0),
    );
  }

  /// The server sends a full ISO timestamp carrying the company's offset. Take
  /// the clock face off it directly rather than converting — converting would
  /// re-render an employee's office time in whatever zone the handset is in.
  static String clockOf(String iso) {
    final time = iso.contains('T') ? iso.split('T')[1] : iso;
    final parts = time.split(':');
    return parts.length >= 2 ? '${parts[0]}:${parts[1]}' : time;
  }
}
