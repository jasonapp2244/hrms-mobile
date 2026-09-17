import 'package:flutter/material.dart';

import '../core/l10n.dart';
import '../core/theme.dart';

/// The header over a month grid: back, the month's name, forward.
///
/// Shared by the team leave calendar and the attendance calendar because the
/// two are the same control, not because they happen to look alike — a
/// difference in where the arrows sit or how the month is worded between two
/// calendars in one app is a bug the user reports as "it moved".
///
/// Either arrow is disabled by passing a null callback, and the two screens do
/// disagree about that: leave is booked ahead, so the team calendar's forward
/// arrow is always live, while attendance has no future to show and stops at
/// the month the server is in.
class MonthBar extends StatelessWidget {
  const MonthBar({super.key, required this.label, this.onBack, this.onForward});

  final String label;
  final VoidCallback? onBack;
  final VoidCallback? onForward;

  /// "August 2026", in the reader's language, from a `YYYY-MM` string.
  ///
  /// Month names come from the ARB files rather than from intl's `DateFormat`,
  /// which needs `initializeDateFormatting` to have been called first and
  /// throws at the moment a date is drawn when it has not. See [Fmt].
  static String monthLabel(AppLocalizations t, String ym) {
    final parts = ym.split('-');
    final month = parts.length > 1 ? int.tryParse(parts[1]) : null;

    return month == null
        ? ym
        : t.calendarMonthYear(Fmt.monthLong(t, month), parts.first);
  }

  /// `2026-12` + 1 → `2027-01`. `DateTime` does the carrying, built on the 1st
  /// where no month is short of a day to land on.
  static String shiftMonth(String ym, int by) {
    final parts = ym.split('-');
    final year = int.tryParse(parts.first);
    final month = parts.length > 1 ? int.tryParse(parts[1]) : null;

    // Nothing sensible to step from. Returning the input leaves the arrows
    // inert rather than jumping the calendar to some year the server never
    // named, which is the failure that would be hard to explain.
    if (year == null || month == null) return ym;

    final moved = DateTime(year, month + by);

    return '${moved.year.toString().padLeft(4, '0')}-'
        '${moved.month.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.t;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.chevron_left),
            tooltip: t.calendarPreviousMonth,
          ),
          Flexible(
            child: Text(
              label,
              style: theme.textTheme.titleSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            onPressed: onForward,
            icon: const Icon(Icons.chevron_right),
            tooltip: t.calendarNextMonth,
          ),
        ],
      ),
    );
  }
}
