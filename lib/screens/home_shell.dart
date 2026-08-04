import 'package:flutter/material.dart';

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

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final user = session.user;

    final tabs = <_Tab>[
      const _Tab(
        icon: Icons.touch_app_outlined,
        selectedIcon: Icons.touch_app,
        label: 'Clock',
        screen: PunchScreen(),
      ),
      const _Tab(
        icon: Icons.history_outlined,
        selectedIcon: Icons.history,
        label: 'History',
        screen: HistoryScreen(),
      ),
      const _Tab(
        icon: Icons.beach_access_outlined,
        selectedIcon: Icons.beach_access,
        label: 'Leave',
        screen: LeaveScreen(),
      ),
      const _Tab(
        icon: Icons.calendar_month_outlined,
        selectedIcon: Icons.calendar_month,
        label: 'Schedule',
        screen: ScheduleScreen(),
      ),
      if (user?.canApproveLeave == true)
        const _Tab(
          icon: Icons.groups_outlined,
          selectedIcon: Icons.groups,
          label: 'Team',
          screen: ApprovalsScreen(),
        ),
      const _Tab(
        icon: Icons.person_outline,
        selectedIcon: Icons.person,
        label: 'Profile',
        screen: ProfileScreen(),
      ),
    ];

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
        onDestinationSelected: (i) => setState(() => _index = i),
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
