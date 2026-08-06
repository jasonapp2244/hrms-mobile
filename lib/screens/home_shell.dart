import 'dart:async';

import 'package:flutter/material.dart';

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

  /// One per tab, keyed by label so that the map survives the manager tab
  /// appearing or disappearing. See [TabVisibility] for why screens need it.
  final Map<String, TabVisibility> _visibility = {};

  TabVisibility _flagFor(String label, {required bool visible}) =>
      _visibility.putIfAbsent(label, () => TabVisibility(visible: visible));

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
    _foreground = session.push.foregroundMessages.listen(_announce);

    // A notification tapped from cold launches the app, and the tap is resolved
    // before this shell is built — so the route is already waiting rather than
    // arriving as an event. Check once on attach.
    _openPendingRoute();
  }

  void _detachPush() {
    _session?.push.pendingRoute.removeListener(_openPendingRoute);
    _foreground?.cancel();
    _foreground = null;
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

    final tabs = _tabsFor(session.user);
    final target = tabs.indexWhere((tab) => tab.label == route.tabLabel);
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
                label: 'View',
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
      _visibility[tabs[j].label]?.value = j == target;
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
    final tabs = _tabsFor(session.user);

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
  List<_Tab> _tabsFor(AppUser? user) {
    return <_Tab>[
      _Tab(
        icon: Icons.touch_app_outlined,
        selectedIcon: Icons.touch_app,
        label: 'Clock',
        screen: PunchScreen(visible: _flagFor('Clock', visible: _index == 0)),
      ),
      _Tab(
        icon: Icons.history_outlined,
        selectedIcon: Icons.history,
        label: 'History',
        screen: HistoryScreen(
          visible: _flagFor('History', visible: _index == 1),
        ),
      ),
      _Tab(
        icon: Icons.beach_access_outlined,
        selectedIcon: Icons.beach_access,
        label: 'Leave',
        screen: LeaveScreen(visible: _flagFor('Leave', visible: _index == 2)),
      ),
      _Tab(
        icon: Icons.calendar_month_outlined,
        selectedIcon: Icons.calendar_month,
        label: 'Schedule',
        screen: ScheduleScreen(
          visible: _flagFor('Schedule', visible: _index == 3),
        ),
      ),
      if (user?.canApproveLeave == true)
        _Tab(
          icon: Icons.groups_outlined,
          selectedIcon: Icons.groups,
          label: 'Team',
          screen: ApprovalsScreen(
            visible: _flagFor('Team', visible: _index == 4),
          ),
        ),
      const _Tab(
        icon: Icons.person_outline,
        selectedIcon: Icons.person,
        label: 'Profile',
        screen: ProfileScreen(),
      ),
    ];
  }
}

class _Tab {
  const _Tab({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.screen,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final Widget screen;
}
