import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../core/tab_visibility.dart';
import '../core/theme.dart';
import '../main.dart';
import '../widgets/async_view.dart';

/// The next fortnight, oldest first — a schedule is read forwards.
///
/// Only *published* roster days are visible. A roster still being planned falls
/// back to the standing shift as though it did not exist; staff watching draft
/// days move around is the problem publishing exists to prevent.
class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key, required this.visible});

  /// Set by `HomeShell` while this tab is the one on screen.
  final ValueListenable<bool> visible;

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> with RefreshOnShow {
  List<ScheduleDay> _days = const [];
  ShiftInfo? _standing;
  bool _loading = true;
  String? _error;

  @override
  ValueListenable<bool> get visibility => widget.visible;

  @override
  Future<void> refresh() => _load(silent: true);

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// [silent] leaves the current roster on screen while the new one is
  /// fetched, for refreshes the user did not explicitly ask for.
  Future<void> _load({bool silent = false}) async {
    setState(() {
      _loading = !silent;
      _error = null;
    });

    try {
      final res = await SessionScope.read(context).api.get('/schedule');
      if (!mounted) return;
      setState(() {
        _days = ((res['days'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ScheduleDay.fromJson)
            .toList();
        _standing = res['standing_shift'] is Map<String, dynamic>
            ? ShiftInfo.fromJson(res['standing_shift'] as Map<String, dynamic>)
            : null;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.error == 'forbidden'
            ? 'This account has no employee record, so it has no schedule.'
            : e.displayMessage;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Schedule')),
      body: AsyncView(
        loading: _loading,
        error: _error,
        onRetry: _load,
        child: RefreshIndicator(
          onRefresh: _load,
          child: _days.isEmpty
              ? ListView(
                  children: const [
                    SizedBox(height: 120),
                    EmptyState(
                      icon: Icons.calendar_month,
                      title: 'No schedule published',
                      subtitle:
                          'Your roster will appear here once HR publishes it.',
                    ),
                  ],
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  children: [
                    if (_standing != null) ...[
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              const Icon(Icons.schedule, color: AppTheme.brand),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Standing shift',
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                    Text(
                                      '${_standing!.name} · ${_standing!.window}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    Card(
                      child: Column(
                        children: [
                          for (var i = 0; i < _days.length; i++) ...[
                            if (i > 0) const Divider(height: 1),
                            _ScheduleRow(day: _days[i]),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _ScheduleRow extends StatelessWidget {
  const _ScheduleRow({required this.day});

  final ScheduleDay day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Order matters: leave and holidays override the shift that would
    // otherwise show, because they are why nobody is working it.
    final (label, color, icon) = switch (true) {
      _ when day.leave != null => (
        day.leave!,
        AppTheme.leave,
        Icons.beach_access,
      ),
      _ when day.holiday != null => (
        day.holiday!,
        AppTheme.neutral,
        Icons.celebration,
      ),
      _ when day.isDayOff => ('Day off', AppTheme.neutral, Icons.weekend),
      _ when !day.isWorkingDay => (
        'Weekend',
        AppTheme.neutral,
        Icons.weekend_outlined,
      ),
      _ when day.shift != null => (
        day.shift!.window,
        AppTheme.present,
        Icons.schedule,
      ),
      _ => ('No shift', AppTheme.neutral, Icons.remove),
    };

    return ListTile(
      leading: SizedBox(
        width: 46,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              day.weekday,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              Fmt.shortDate(day.date),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ],
        ),
      ),
      title: Row(
        children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
      subtitle: day.shift != null && day.leave == null && day.holiday == null
          ? Text(day.shift!.name)
          : null,
      // is_rostered distinguishes a planned day from the standing shift
      // filling in — worth showing, because one is a decision and one is a
      // default.
      trailing: day.isRostered
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppTheme.brand.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'rostered',
                style: TextStyle(
                  fontSize: 10.5,
                  color: AppTheme.brandDeep,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          : null,
    );
  }
}
