import 'dart:async';

import 'package:flutter/material.dart';

import '../core/l10n.dart';
import '../core/models.dart';
import '../core/push.dart';
import '../core/session.dart';
import '../core/tab_visibility.dart';
import '../main.dart';
import 'approvals_screen.dart';
import 'history_screen.dart';
import 'leave_screen.dart';
import 'profile_screen.dart';
import 'punch_screen.dart';
import 'schedule_screen.dart';

/// What each tab is called, in one place.
///
/// The shell draws these under the icons and a notification row names one in
/// its "Open …" button; two lists would eventually disagree about a word.
/// Keyed on the tab's stable id, never on the label itself.
String tabLabel(AppLocalizations t, String id) => switch (id) {
      'clock' => t.tabClock,
      'history' => t.tabHistory,
      'leave' => t.tabLeave,
      'schedule' => t.tabSchedule,
      'team' => t.tabTeam,
      _ => t.tabProfile,
    };

/// The signed-in frame.
///
/// Which tabs exist depends on the signed-in user, not on a hardcoded list.
/// The manager section appears only when `approve-leave` is present — the
/// reference is explicit that the endpoints behind it are permission-gated,
/// so showing the tab to somebody without it would only produce a 403 screen.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  /// One per tab, keyed by the tab's **id** so that the map survives both the
  /// manager tab appearing or disappearing and the language changing under it.
  /// See [TabVisibility] for why screens need it.
  final Map<String, TabVisibility> _visibility = {};

  TabVisibility _flagFor(String id, {required bool visible}) =>
      _visibility.putIfAbsent(id, () => TabVisibility(visible: visible));

  Session? _session;
  StreamSubscription<PushMessage>? _foreground;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final session = SessionScope.of(context);
    if (identical(session, _session)) return;

    _detachPush();
    _session = session;
    session.push.pendingRoute.addListener(_openPendingRoute);
    session.actions.pending.addListener(_openPendingAction);
    _foreground = session.push.foregroundMessages.listen(_announce);

    // A notification tapped from cold launches the app, and the tap is resolved
    // before this shell is built — so the route is already waiting rather than
    // arriving as an event. Check once on attach.
    _openPendingRoute();

    // And the same for a launcher shortcut (B2.8), which is *always* this case:
    // tapping one is how the app started.
    _openPendingAction();
  }

  void _detachPush() {
    _session?.push.pendingRoute.removeListener(_openPendingRoute);
    _session?.actions.pending.removeListener(_openPendingAction);
    _foreground?.cancel();
    _foreground = null;
  }

  /// Brings the Clock tab forward for a launcher shortcut (B2.8).
  ///
  /// **Switches the tab and nothing else.** The punch itself belongs to the
  /// Clock screen, which owns the fence check, the GPS fix, the cooldown and
  /// the offline queue — reproducing any of that here would be the second
  /// definition of a rule this codebase keeps having to prove it only has one
  /// of. So this does not clear the pending value; `PunchScreen` does, when it
  /// has acted on it.
  ///
  /// The tab is named through [PushRoute.clock] rather than by index or by a
  /// second `'clock'` literal: the manager tab shifts every index after it, and
  /// the label under the icon is translated.
  void _openPendingAction() {
    final session = _session;
    if (session == null || session.actions.pending.value == null || !mounted) {
      return;
    }

    final tabs = _tabsFor(context.t, session.user);
    final target = tabs.indexWhere((tab) => tab.id == PushRoute.clock.tabId);
    if (target == -1) return;

    _select(target, tabs);
  }

  /// Switches to the tab a tapped notification asked for.
  void _openPendingRoute() {
    final session = _session;
    final route = session?.push.pendingRoute.value;
    if (session == null || route == null || !mounted) return;

    // Cleared whether or not it resolves to a tab. A route this build cannot
    // show — `approvals` for somebody whose manager permission was withdrawn
    // this morning — must not sit in the notifier retrying on every rebuild.
    session.push.pendingRoute.value = null;

    final tabs = _tabsFor(context.t, session.user);
    final target = tabs.indexWhere((tab) => tab.id == route.tabId);
    if (target == -1) return;

    _select(target, tabs);
  }

  /// A notification that arrived with the app already open.
  ///
  /// The OS shows nothing in this state, and a full-screen interruption for
  /// somebody who is looking at the app anyway would be worse than the problem.
  /// A snack bar says it, and offers the same destination the tap would have.
  void _announce(PushMessage message) {
    if (!mounted) return;

    // The row is already in the server's table by the time this arrives, so
    // the badge moves now rather than at the next refresh (B5.6). Counted
    // locally rather than re-fetched: one snack bar is not worth a round trip,
    // and opening the inbox replaces the number with the authoritative one.
    final unread = _session?.unreadNotifications;
    if (unread != null) unread.value = unread.value + 1;

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message.body ?? message.title ?? ''),
        duration: const Duration(seconds: 6),
        action: message.route == null
            ? null
            : SnackBarAction(
                label: context.t.actionView,
                onPressed: () {
                  _session?.push.pendingRoute.value = message.route;
                },
              ),
      ),
    );
  }

  /// Moves to [target], telling the screen being left that it is off show and
  /// the one arriving that it is on — the latter is what makes it refetch.
  void _select(int target, List<_Tab> tabs) {
    for (var j = 0; j < tabs.length; j++) {
      _visibility[tabs[j].id]?.value = j == target;
    }
    if (target != _index) setState(() => _index = target);
  }

  @override
  void dispose() {
    _detachPush();
    for (final flag in _visibility.values) {
      flag.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final tabs = _tabsFor(context.t, session.user);

    // A permission can be revoked while the app is open. Clamp rather than
    // letting the index run off the end of a list that just got shorter.
    final index = _index.clamp(0, tabs.length - 1);

    return Scaffold(
      body: IndexedStack(
        index: index,
        children: [for (final tab in tabs) tab.screen],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => _select(i, tabs),
        destinations: [
          for (final tab in tabs)
            NavigationDestination(
              icon: Icon(tab.icon),
              selectedIcon: Icon(tab.selectedIcon),
              label: tab.label,
            ),
        ],
      ),
    );
  }

  /// The tabs this user has, in order.
  ///
  /// A method rather than a `build`-local so that a push route can be resolved
  /// to a position outside a build — the manager tab shifts everything after
  /// it, so the mapping from route to index is not a constant.
  List<_Tab> _tabsFor(AppLocalizations t, AppUser? user) {
    return <_Tab>[
      _Tab(
        id: 'clock',
        icon: Icons.touch_app_outlined,
        selectedIcon: Icons.touch_app,
        label: tabLabel(t, 'clock'),
        screen: PunchScreen(visible: _flagFor('clock', visible: _index == 0)),
      ),
      _Tab(
        id: 'history',
        icon: Icons.history_outlined,
        selectedIcon: Icons.history,
        label: tabLabel(t, 'history'),
        screen: HistoryScreen(
          visible: _flagFor('history', visible: _index == 1),
        ),
      ),
      _Tab(
        id: 'leave',
        icon: Icons.beach_access_outlined,
        selectedIcon: Icons.beach_access,
        label: tabLabel(t, 'leave'),
        screen: LeaveScreen(visible: _flagFor('leave', visible: _index == 2)),
      ),
      _Tab(
        id: 'schedule',
        icon: Icons.calendar_month_outlined,
        selectedIcon: Icons.calendar_month,
        label: tabLabel(t, 'schedule'),
        screen: ScheduleScreen(
          visible: _flagFor('schedule', visible: _index == 3),
        ),
      ),
      if (user?.leadsATeam == true)
        _Tab(
          id: 'team',
          icon: Icons.groups_outlined,
          selectedIcon: Icons.groups,
          label: tabLabel(t, 'team'),
          screen: ApprovalsScreen(
            visible: _flagFor('team', visible: _index == 4),
          ),
        ),
      _Tab(
        id: 'profile',
        icon: Icons.person_outline,
        selectedIcon: Icons.person,
        label: tabLabel(t, 'profile'),
        screen: const ProfileScreen(),
      ),
    ];
  }
}

class _Tab {
  const _Tab({
    required this.id,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.screen,
  });

  /// Stable across languages and across builds. Everything that has to *find* a
  /// tab matches on this — the visibility map and a tapped notification's
  /// route — because [label] is translated and would find nothing.
  final String id;

  final IconData icon;
  final IconData selectedIcon;

  /// What is drawn under the icon. Display only.
  final String label;

  final Widget screen;
}
