import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../core/offline_cache.dart';
import '../core/tab_visibility.dart';
import '../core/theme.dart';
import '../main.dart';
import '../widgets/async_view.dart';
import '../widgets/month_bar.dart';
import 'regularisations_screen.dart';

/// The two shapes this screen takes.
///
/// The same rows, asked for over a different window and drawn differently.
/// They answer different questions: the list answers "what happened recently",
/// which needs no navigation, and the grid answers "which days did I miss",
/// which is month-shaped and is the one people bring a dispute to.
enum _HistoryView { list, calendar }

/// One row per day, newest first — "did I make it in, and when" is a
/// day-shaped question, so the API answers it in days rather than punches.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.visible});

  /// Set by `HomeShell` while this tab is the one on screen.
  final ValueListenable<bool> visible;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> with RefreshOnShow {
  List<HistoryDay> _days = const [];
  HistoryTotals? _totals;
  AttendanceScore? _score;
  bool _loading = true;
  String? _error;

  /// True when [_error] is one no retry can clear — the account has no employee
  /// record. See [ApiErrorText.isMissingEmployeeRecord].
  bool _fatal = false;

  /// When the rows on screen were saved, or null when they came from the
  /// server just now. Drives the offline banner (B6.3).
  DateTime? _cachedAt;

  /// The API caps the window at 92 days, so these are the only offers.
  int _rangeDays = 30;

  /// List or grid. See [_HistoryView].
  _HistoryView _view = _HistoryView.list;

  /// `YYYY-MM`, the month the grid is drawing. Taken from [_anchor] the first
  /// time one lands and then moved by the arrows — never from the handset's
  /// clock, for the reason spelled out in [_load].
  String? _monthAnchor;

  /// The date whose detail is spelled out under the grid, in the grid only.
  String? _selected;

  /// What the **server** last called today, read back out of its own reply.
  ///
  /// Not `DateTime.now()` — see the note in [_load]. Null until the first live
  /// reply lands, which is why that one asks for no window at all.
  DateTime? _anchor;

  @override
  ValueListenable<bool> get visibility => widget.visible;

  @override
  Future<void> refresh() => _load(silent: true);

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// [silent] leaves the current rows on screen while the new ones are
  /// fetched, for refreshes the user did not explicitly ask for.
  Future<void> _load({bool silent = false}) async {
    setState(() {
      _loading = !silent;
      _error = null;
      _fatal = false;
    });

    try {
      final session = SessionScope.read(context);

      // Neither end of this window comes off the handset's clock. Attendance is
      // judged in the company's timezone and the phone is wherever its owner
      // is, so a phone already on tomorrow asks for a window ending tomorrow —
      // and the endpoint clamps `to` back to its own today rather than
      // refusing, so "Last 7 days" quietly returns six, with the totals and the
      // attendance score computed over the short window. Nothing errors; the
      // heading simply lies.
      //
      // So in the list `to` is never sent: the server's default is the
      // company's today, which is the only correct answer. `from` counts back
      // from [_anchor], the day the server last said it was. Until the first
      // reply lands there is nothing to count from, and sending neither asks
      // for the server's own 30-day default — which is exactly [_rangeDays]'s
      // starting value.
      //
      // The grid is the one caller that does send `to`, and it is the same rule
      // rather than an exception to it: the month it sends both ends of is a
      // month counted from [_anchor] as well.
      final anchor = _anchor;
      final calendar = _view == _HistoryView.calendar;
      final month = _monthAnchor;

      final Map<String, dynamic> query;

      // One saved copy per range: the three offers are three different
      // questions, and the answer to a 92-day window is not the answer to a
      // 7-day one. A copy taken yesterday covers yesterday's window, which is
      // why the banner names the day it was taken.
      final String key;

      // Only the month slot needs one — see OfflineCache.keyHistoryMonth.
      bool Function(Map<String, dynamic> body)? stillValid;

      if (calendar && month != null) {
        // A month is the one window with **both** ends named, and both are
        // named from a month the server handed over. `to` runs past today in
        // the month that is running, which the endpoint clamps back to its own
        // today rather than refusing — and that clamp is right here, because
        // the heading is a month name. A short last week does not make "August
        // 2026" a lie the way it makes "Last 7 days" one.
        final from = '$month-01';
        query = {'from': from, 'to': _ymd(_lastDayOf(month))};
        key = OfflineCache.keyHistoryMonth;
        stillValid = (body) => '${body['from']}' == from;
      } else if (calendar || anchor == null) {
        // Nothing to count from yet, in either shape. Asking for no window at
        // all gets the server's own default, and with it the day it thinks it
        // is — which is the whole point of the request. The grid then asks
        // again for the real month; see below.
        query = const <String, dynamic>{};
        key = OfflineCache.historyKey(OfflineCache.serverDefaultHistoryDays);
      } else {
        query = {'from': _ymd(anchor.subtract(Duration(days: _rangeDays - 1)))};
        key = OfflineCache.historyKey(_rangeDays);
      }

      final res = await session.cache.fetch(
        session.api,
        '/attendance/history',
        key: key,
        query: query,
        stillValid: stillValid,
      );

      if (!mounted) return;
      setState(() {
        // The server names the window it actually used, and that echo is the
        // only trustworthy statement of what today means here. Taken from a
        // live reply only — a saved copy carries the day it was taken, which
        // may be several days stale, and anchoring on that would walk the
        // window backwards every time the phone opened it offline.
        //
        // And only from a reply to a request that did **not** name `to`. The
        // echo is the window's end, which is today only because nobody asked
        // for anything earlier. Page the grid back to March and the reply says
        // `to: 2025-03-31` — perfectly true, and not today. Anchoring on it
        // moved the app's idea of today to the end of whatever month was being
        // read, which killed the forward arrow and then handed the list a
        // window ending in March.
        if (!query.containsKey('to') &&
            res.cachedAt == null &&
            res.body['to'] is String) {
          final to = DateTime.tryParse(res.body['to'] as String);
          if (to != null) {
            _anchor = to;
            // The month the grid opens on, named once and then only moved by
            // the arrows — a later reply must not drag the reader back to the
            // current month while they are looking at April.
            _monthAnchor ??= _ym(to);
          }
        }
        _days = ((res.body['days'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(HistoryDay.fromJson)
            .toList();
        _totals = res.body['totals'] is Map<String, dynamic>
            ? HistoryTotals.fromJson(res.body['totals'] as Map<String, dynamic>)
            : null;
        // Absent from a cached copy taken before B3.5 shipped, which is an
        // ordinary state rather than a broken one — the card simply does not
        // appear until the next time the phone has signal.
        _score = res.body['score'] is Map<String, dynamic>
            ? AttendanceScore.fromJson(res.body['score'] as Map<String, dynamic>)
            : null;
        _cachedAt = res.cachedAt;
        if (calendar) _selected = _openOn();
        _loading = false;
      });

      // The first grid load could only ask for the server's default window,
      // because a month cannot be named before a day has been. One has now, so
      // ask again for the month itself — silently, which leaves the days that
      // did arrive on screen while the right ones land on top of them.
      if (calendar && month == null && _monthAnchor != null) {
        return _load(silent: true);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      // Read here rather than before the request: the first load runs from
      // initState, and reaching for the strings there registers an
      // inherited-widget dependency before the element has finished
      // building, which asserts.
      final t = context.t;
      setState(() {
        // No retry offered for this one: it is the account, not the network.
        _fatal = e.isMissingEmployeeRecord;
        _error = _fatal ? t.historyNoEmployeeRecord : e.text(t);
        _cachedAt = null;
        _loading = false;
      });
    }
  }

  /// Which cell the grid opens on.
  ///
  /// A day the reader already picked wins, so a background refresh does not
  /// pull the detail out from under them. Otherwise the newest day the month
  /// has — today in the month that is running, and the last day of any other.
  String? _openOn() {
    final held = _selected;

    if (held != null && _days.any((d) => d.date == held)) return held;

    // The API answers newest first.
    return _days.isEmpty ? null : _days.first.date;
  }

  void _toggleView() {
    setState(() {
      _view = _view == _HistoryView.list
          ? _HistoryView.calendar
          : _HistoryView.list;
      _selected = null;
    });

    // Not just a repaint: the two shapes ask for different windows, and the
    // rows on screen belong to the one being left.
    _load();
  }

  void _step(int months) {
    final month = _monthAnchor;

    // Nothing has been learned yet, so there is nothing to count from. The
    // arrows are disabled in that state; this is the belt to those braces.
    if (month == null) return;

    setState(() {
      _monthAnchor = MonthBar.shiftMonth(month, months);
      // A different month holds no selection — _openOn picks a new one.
      _selected = null;
    });

    _load();
  }

  /// True while the grid is on the month the **server** is in, which is as far
  /// forward as it goes.
  bool get _atCurrentMonth {
    final anchor = _anchor;

    return anchor == null || _monthAnchor == _ym(anchor);
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static String _ym(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}';

  /// `2026-02` → 29 February 2026. Day zero of the next month is the last day
  /// of this one, so `DateTime` does the leap year rather than a table.
  static DateTime _lastDayOf(String ym) {
    final parts = ym.split('-');
    final year = int.tryParse(parts.first) ?? 1970;
    final month = parts.length > 1 ? int.tryParse(parts[1]) ?? 1 : 1;

    return DateTime(year, month + 1, 0);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final calendar = _view == _HistoryView.calendar;

    return Scaffold(
      appBar: AppBar(
        title: Text(t.historyTitle),
        // **Order matters, and the toggle is last on purpose.** An AppBar lays
        // its actions out against the right edge, so dropping one shifts every
        // action after it. With the toggle first, pressing it removed the range
        // menu and slid the toggle a full button to the right — under the
        // thumb that had just pressed it was now Corrections, a different
        // screen. Last, it never moves; the button that shifts instead is the
        // one nobody presses twice in a row.
        actions: [
          // Next to the record it disputes, rather than on a tab of its own.
          // Asking for a correction is rare and only makes sense here.
          IconButton(
            icon: const Icon(Icons.rule),
            tooltip: t.historyCorrections,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const RegularisationsScreen()),
            ),
          ),
          // A month *is* the range while the grid is up, so offering another
          // one would be two controls arguing over the same window.
          if (!calendar)
            PopupMenuButton<int>(
              initialValue: _rangeDays,
              tooltip: t.historyDateRange,
              icon: const Icon(Icons.tune),
              onSelected: (v) {
                setState(() => _rangeDays = v);
                _load();
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 7, child: Text(t.historyLastDays(7))),
                PopupMenuItem(value: 30, child: Text(t.historyLastDays(30))),
                PopupMenuItem(value: 92, child: Text(t.historyLastDays(92))),
              ],
            ),
          IconButton(
            icon: Icon(
              calendar ? Icons.view_list_outlined : Icons.calendar_month_outlined,
            ),
            tooltip: calendar ? t.historyViewList : t.historyViewCalendar,
            onPressed: _toggleView,
          ),
        ],
      ),
      body: AsyncView(
        loading: _loading,
        error: _error,
        onRetry: _load,
        permanent: _fatal,
        child: calendar ? _calendarBody(context) : _listBody(context),
      ),
    );
  }

  Widget _listBody(BuildContext context) {
    final t = context.t;

    return RefreshIndicator(
      onRefresh: _load,
      child: _days.isEmpty
          ? ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              children: [
                OfflineBanner(savedAt: _cachedAt, onRetry: _load),
                const SizedBox(height: 104),
                EmptyState(
                  icon: Icons.history,
                  title: t.historyEmptyTitle,
                  subtitle: t.historyEmptySubtitle,
                ),
              ],
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                OfflineBanner(savedAt: _cachedAt, onRetry: _load),
                if (_score != null) ...[
                  _ScoreCard(score: _score!),
                  const SizedBox(height: 20),
                ],
                if (_totals != null) ...[
                  _TotalsCard(
                    totals: _totals!,
                    heading: t.historyRangeHeading(_rangeDays),
                  ),
                  const SizedBox(height: 20),
                ],
                Card(
                  child: Column(
                    children: [
                      for (var i = 0; i < _days.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _DayRow(day: _days[i]),
                      ],
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _calendarBody(BuildContext context) {
    final t = context.t;
    final month = _monthAnchor;

    // No month has been named, which can only happen when the very first load
    // never reached the server. Saying so is the honest screen: the alternative
    // is drawing whatever month this handset believes it is, which is the one
    // thing this screen has spent its whole life refusing to do.
    if (month == null) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          children: [
            OfflineBanner(savedAt: _cachedAt, onRetry: _load),
            const SizedBox(height: 80),
            EmptyState(
              icon: Icons.calendar_month_outlined,
              title: t.historyCalendarOfflineTitle,
              subtitle: t.historyCalendarOfflineSubtitle,
            ),
          ],
        ),
      );
    }

    final byDate = {for (final day in _days) day.date: day};
    final selected = _selected;
    final anchor = _anchor;
    final parts = month.split('-');

    return Column(
      children: [
        MonthBar(
          label: MonthBar.monthLabel(t, month),
          onBack: () => _step(-1),
          // Nothing past the month the server is in: a day that has not
          // happened has no attendance to report, and a grid of empty cells
          // reads as a month somebody failed to turn up for.
          onForward: _atCurrentMonth ? null : () => _step(1),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
              children: [
                OfflineBanner(savedAt: _cachedAt, onRetry: _load),
                _MonthGrid(
                  month: month,
                  byDate: byDate,
                  today: anchor == null ? null : _ymd(anchor),
                  selected: selected,
                  onTap: (date) => setState(() => _selected = date),
                ),
                const SizedBox(height: 14),
                const _Legend(),
                if (selected != null) ...[
                  const SizedBox(height: 16),
                  _SelectedDayCard(date: selected, day: byDate[selected]),
                ],
                if (_score != null) ...[
                  const SizedBox(height: 16),
                  _ScoreCard(score: _score!),
                ],
                if (_totals != null) ...[
                  const SizedBox(height: 16),
                  _TotalsCard(
                    totals: _totals!,
                    heading: t
                        .historyMonthHeading(
                          Fmt.monthLong(t, int.tryParse(parts.last) ?? 1),
                          parts.first,
                        )
                        .toUpperCase(),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The score and the streak (B3.5).
///
/// Above the totals rather than below, because it is the answer to the
/// question somebody opens this screen with — the five counts underneath are
/// the working.
///
/// Never a bare number. The line under it says what the number is made of, so
/// that a person who disagrees with it can point at the day they think is
/// wrong and ask for a correction, which is one tap away in the app bar.
class _ScoreCard extends StatelessWidget {
  const _ScoreCard({required this.score});

  final AttendanceScore score;

  /// Green, amber, red — the same three the day rows use, so a colour means
  /// the same thing everywhere on this screen.
  Color _tone(AppColors colors) {
    final value = score.score;
    if (value == null) return colors.neutral;
    if (value >= 90) return colors.present;
    if (value >= 75) return colors.late;
    return colors.absent;
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final t = context.t;
    final tone = _tone(colors);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.historyScoreHeading,
              style: theme.textTheme.labelSmall?.copyWith(
                letterSpacing: 1.1,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            // Wrap rather than Row: at 2x text the score and the streak will
            // not sit side by side. The Wrap alone was not enough — see the
            // Flexible below, which is what the accessibility test actually
            // caught.
            Wrap(
              spacing: 28,
              runSpacing: 16,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      score.hasScore ? '${score.score}%' : t.historyScoreNone,
                      style: (score.hasScore
                              ? theme.textTheme.displaySmall
                              : theme.textTheme.titleMedium)
                          ?.copyWith(
                        color: tone,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      score.hasScore
                          ? t.historyScoreOutOf(score.ontimeDays, score.obligedDays)
                          : t.historyScoreNoneWhy,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.local_fire_department_outlined,
                          size: 18,
                          // Neutral at zero: a flame beside "No streak" reads
                          // as a taunt.
                          color: score.streak > 0 ? colors.accent : colors.neutral,
                        ),
                        const SizedBox(width: 6),
                        // Flexible, not bare: "128 days in a row" at twice the
                        // text size is wider than the card, and a Row does not
                        // wrap for you. This overflowed before the 2x test in
                        // accessibility_test.dart was pointed at this screen.
                        Flexible(
                          child: Text(
                            t.historyStreak(score.streak),
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      t.historyStreakCaption,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.totals, required this.heading});

  final HistoryTotals totals;

  /// Named by the caller rather than built here, because the two shapes of
  /// this screen count over different windows — "LAST 30 DAYS" and "AUGUST
  /// 2026" — and a card that got it wrong would be a card of numbers for a
  /// period nobody asked about.
  final String heading;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final t = context.t;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              heading,
              style: theme.textTheme.labelSmall?.copyWith(
                letterSpacing: 1.1,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 26,
              runSpacing: 14,
              children: [
                _Stat(
                  label: t.historyStatPresent,
                  value: '${totals.presentDays}',
                  color: colors.present,
                ),
                _Stat(
                  label: t.historyStatLate,
                  value: '${totals.lateDays}',
                  color: colors.late,
                ),
                _Stat(
                  label: t.historyStatLeave,
                  value: '${totals.leaveDays}',
                  color: colors.leave,
                ),
                _Stat(
                  label: t.historyStatAbsent,
                  value: '${totals.absentDays}',
                  color: colors.absent,
                ),
                _Stat(
                  label: t.historyStatWorked,
                  value: Fmt.duration(t, totals.workedMinutes),
                  color: theme.colorScheme.onSurface,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: color,
            letterSpacing: -0.5,
          ),
        ),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _DayRow extends StatelessWidget {
  const _DayRow({required this.day});

  final HistoryDay day;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final t = context.t;
    final (color, label) = colors.statusStyle(t, day.status);

    return ListTile(
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
      title: Row(
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
          if (day.late) ...[
            const SizedBox(width: 6),
            Text(
              t.historyLateFlag,
              style: TextStyle(color: colors.late, fontSize: 11.5),
            ),
          ],
        ],
      ),
      subtitle: day.holiday != null
          ? Text(day.holiday!)
          : (day.firstIn != null
                ? Text(
                    t.historyInAt(_clock(day.firstIn!)) +
                        (day.lastOut != null
                            ? t.historyOutAt(_clock(day.lastOut!))
                            : t.historyStillOpen),
                  )
                : null),
      trailing: day.workedMinutes > 0
          ? Text(
              Fmt.duration(t, day.workedMinutes),
              style: const TextStyle(fontWeight: FontWeight.w600),
            )
          : null,
    );
  }

  /// The server sends a full ISO timestamp carrying the company's offset. Take
  /// the clock face off it directly rather than converting — converting would
  /// re-render an employee's office time in whatever zone the handset is in.
  static String _clock(String iso) {
    final time = iso.contains('T') ? iso.split('T')[1] : iso;
    final parts = time.split(':');
    return parts.length >= 2 ? '${parts[0]}:${parts[1]}' : time;
  }
}

/// What one day looks like in the grid: a tone, a shape that carries the same
/// meaning without it, and the word a screen reader says.
///
/// **The icon is not decoration.** A tint alone leaves the grid unreadable to
/// anyone who cannot separate the green from the red, and this is the screen an
/// employee opens to find the day they want to dispute.
({Color tone, IconData? icon, String label}) _dayMark(
  AppColors colors,
  AppLocalizations t,
  HistoryDay? day,
) {
  // Not "absent". In the month that is running, every day after today is one of
  // these, and calling tomorrow a day somebody missed is a lie they cannot
  // answer.
  if (day == null) {
    return (tone: colors.neutral, icon: null, label: t.historyCalendarNoRecord);
  }

  // Tested before the status rather than after it: a late arrival is still a
  // present day, so matching on status first would draw it as an ordinary one
  // and lose the only fact on the row anybody argues about.
  if (day.late) {
    return (
      tone: colors.late,
      icon: Icons.schedule,
      label: t.historyCalendarLate,
    );
  }

  final (tone, label) = colors.statusStyle(t, day.status);

  return (
    tone: tone,
    icon: switch (day.status) {
      'present' => Icons.check,
      'leave' => Icons.beach_access,
      'absent' => Icons.close,
      'holiday' => Icons.flag_outlined,
      // A day off and a weekend are shaded and left blank: nothing happened on
      // them, and nothing was supposed to.
      _ => null,
    },
    label: label,
  );
}

/// The month, one square per day (B3.4).
///
/// **Weeks start on Monday, and that is a layout choice rather than a claim
/// about the working week.** Which days are a weekend is the company's setting
/// and arrives on each day's own status, so a company working Sunday to
/// Thursday is shaded correctly however the rows happen to break.
class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.byDate,
    required this.today,
    required this.selected,
    required this.onTap,
  });

  /// `YYYY-MM`. The grid draws every day of it, whether the server sent a row
  /// for that day or not — a month with a hole in it is worse than one with a
  /// blank in it, because only one of the two is obviously a blank.
  final String month;

  final Map<String, HistoryDay> byDate;

  /// The server's own today, or null before one has been named.
  final String? today;

  final String? selected;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);

    final parts = month.split('-');
    final year = int.tryParse(parts.first);
    final index = parts.length > 1 ? int.tryParse(parts.last) : null;

    if (year == null || index == null) return const SizedBox.shrink();

    // Day zero of the next month is the last of this one, so DateTime does the
    // leap year rather than a table.
    final length = DateTime(year, index + 1, 0).day;
    final blanks = DateTime(year, index).weekday - DateTime.monday;

    final cells = <Widget>[
      for (var i = 0; i < blanks; i++) const SizedBox.shrink(),
    ];

    for (var d = 1; d <= length; d++) {
      final date = '$month-${d.toString().padLeft(2, '0')}';

      cells.add(_DayCell(
        date: date,
        dayOfMonth: d,
        day: byDate[date],
        isToday: date == today,
        isSelected: date == selected,
        onTap: () => onTap(date),
      ));
    }

    final rows = <Widget>[];

    for (var i = 0; i < cells.length; i += 7) {
      rows.add(Row(
        children: [
          for (var c = 0; c < 7; c++)
            Expanded(
              child: i + c < cells.length ? cells[i + c] : const SizedBox.shrink(),
            ),
        ],
      ));
    }

    return Column(
      children: [
        Row(
          children: [
            for (var weekday = DateTime.monday; weekday <= DateTime.sunday; weekday++)
              Expanded(
                child: Center(
                  child: Text(
                    Fmt.weekdayShort(t, weekday),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        ...rows,
      ],
    );
  }
}

/// One day of the month.
class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.dayOfMonth,
    required this.day,
    required this.isToday,
    required this.isSelected,
    required this.onTap,
  });

  final String date;
  final int dayOfMonth;

  /// Null for a day the server sent no row for. See [_dayMark].
  final HistoryDay? day;

  final bool isToday;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final t = context.t;

    final mark = _dayMark(colors, t, day);
    final status = day?.status;
    final muted = day == null ||
        status == 'weekend' ||
        status == 'day_off' ||
        status == 'holiday';

    return Semantics(
      selected: isSelected,
      button: true,
      // The cell shows a number and a 15px glyph and nothing else, so this is
      // the only place the day is actually spelled out.
      label: t.historyCalendarDay(Fmt.shortDate(t, date), mark.label),
      // The label above already says "11 Apr"; letting the bare "11" through as
      // well would have a screen reader announce the number twice and the
      // month once, which is worse than either on its own.
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AspectRatio(
          aspectRatio: 1,
          child: Container(
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              // **The selection is deliberately not accent-coloured.** Leave
              // days are tinted blue and so is the accent, so a selected day
              // read as a day off until you noticed the glyph. Selection is
              // transient feedback and has no business borrowing a colour that
              // already means something; a neutral darkening says "this one"
              // without saying anything about the day.
              color: isSelected
                  ? theme.colorScheme.onSurface.withValues(alpha: 0.12)
                  : mark.icon != null
                      ? mark.tone.withValues(alpha: 0.10)
                      : muted
                          ? theme.colorScheme.surfaceContainerHighest
                          : null,
              borderRadius: BorderRadius.circular(8),
              border: isToday
                  ? Border.all(color: colors.accent, width: 1.5)
                  : null,
            ),
            // Scaled down rather than clipped: at 2x text this cell is still a
            // square seventh of the width, and an overflowing calendar is a
            // calendar with days missing off the bottom.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$dayOfMonth',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
                        color: muted
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    SizedBox(
                      height: 16,
                      child: mark.icon == null
                          ? null
                          : Icon(mark.icon, size: 15, color: mark.tone),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What the tints and the glyphs in the grid mean.
///
/// Not optional furniture: the grid says everything it has to say in a tint and
/// a 15px shape, and a key that exists only in the head of whoever drew it is
/// not a key.
class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final t = context.t;

    final entries = <(IconData, Color, String)>[
      (Icons.check, colors.present, t.statusPresent),
      (Icons.schedule, colors.late, t.historyCalendarLate),
      (Icons.beach_access, colors.leave, t.statusOnLeave),
      (Icons.close, colors.absent, t.statusAbsent),
      (Icons.flag_outlined, colors.neutral, t.statusHoliday),
    ];

    return Wrap(
      spacing: 14,
      runSpacing: 8,
      children: [
        for (final (icon, tone, label) in entries)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: tone),
              const SizedBox(width: 4),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// The tapped day, spelled out under the grid.
///
/// Deliberately the **same row the list draws**, rather than a second rendering
/// of the same facts: two ways of writing down one day is two things to keep in
/// agreement, and the day somebody taps here is the day they are about to quote
/// in a correction request.
class _SelectedDayCard extends StatelessWidget {
  const _SelectedDayCard({required this.date, required this.day});

  final String date;
  final HistoryDay? day;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final day = this.day;

    return Card(
      child: day != null
          ? _DayRow(day: day)
          : ListTile(
              title: Text(Fmt.longDate(t, date)),
              subtitle: Text(
                t.historyCalendarNoRecord,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
    );
  }
}
