import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../main.dart';
import '../widgets/async_view.dart';
import 'home_shell.dart';

/// The history behind the pushes (B5.6).
///
/// Until this existed a notification that arrived while the phone was in a
/// locker was simply gone — the OS banner gets swiped away and the app kept
/// nothing. Everything here has been in the server's `notifications` table
/// since A9; this is the app catching up with the web dashboard.
///
/// **Reading and going somewhere are separate gestures**, unlike the web
/// screen where clicking a row does both. On a phone the list *is* the
/// destination for most of these: the body is the whole message, and a leave
/// decision says what was decided without going anywhere.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<AppNotification> _notifications = const [];
  int _unread = 0;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final res = await SessionScope.read(context).api.get('/notifications');

      if (!mounted) return;
      setState(() {
        _notifications = ((res['notifications'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(AppNotification.fromJson)
            .toList();
        _unread = (res['unread'] as num?)?.toInt() ?? 0;
        _loading = false;
      });
      _publish();
    } on ApiException catch (e) {
      if (!mounted) return;
      // Read here rather than before the request: the first load runs from
      // initState, and reaching for the strings there registers an
      // inherited-widget dependency before the element has finished
      // building, which asserts.
      final t = context.t;
      setState(() {
        _error = e.text(t);
        _loading = false;
      });
    }
  }

  /// Hands the count back to the bell in the app bar behind this screen.
  void _publish() =>
      SessionScope.read(context).unreadNotifications.value = _unread;

  Future<void> _markRead(AppNotification notification) async {
    if (!notification.isUnread) return;

    // Optimistic. The row greys the moment it is tapped; a mark-read that does
    // not land is not worth making somebody wait for, and the next load is
    // authoritative anyway.
    setState(() {
      _notifications = [
        for (final n in _notifications)
          if (n.id == notification.id)
            AppNotification(
              id: n.id,
              title: n.title,
              createdAt: n.createdAt,
              type: n.type,
              body: n.body,
              route: n.route,
              readAt: DateTime.now().toIso8601String(),
            )
          else
            n,
      ];
      _unread = _unread > 0 ? _unread - 1 : 0;
    });
    _publish();

    try {
      final res = await SessionScope.read(context)
          .api
          .post('/notifications/${notification.id}/read');

      if (!mounted) return;
      setState(() => _unread = (res['unread'] as num?)?.toInt() ?? _unread);
      _publish();
    } on ApiException {
      // Left as read on screen. The server is the record; this list is not,
      // and the next open corrects it.
    }
  }

  Future<void> _markAllRead() async {
    setState(() => _busy = true);
    final t = context.t;

    try {
      await SessionScope.read(context).api.post('/notifications/read-all');
      if (!mounted) return;
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.text(t)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Sends the person where the notification points, if it points anywhere.
  ///
  /// Through `PushService.pendingRoute`, which is the same channel a tapped
  /// OS notification uses — one way in, so the shell has one thing to handle
  /// and the two cannot disagree about which tab answers `leave`.
  void _follow(AppNotification notification) {
    final route = notification.route;
    if (route == null) return;

    SessionScope.read(context).push.pendingRoute.value = route;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final t = context.t;

    return Scaffold(
      appBar: AppBar(
        title: Text(t.notificationsTitle),
        actions: [
          if (_unread > 0)
            TextButton(
              onPressed: _busy ? null : _markAllRead,
              child: Text(t.notificationsMarkAllRead),
            ),
        ],
      ),
      body: AsyncView(
        loading: _loading,
        error: _error,
        onRetry: _load,
        child: _notifications.isEmpty
            ? RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  children: [
                    const SizedBox(height: 100),
                    EmptyState(
                      icon: Icons.notifications_none,
                      title: t.notificationsEmptyTitle,
                      subtitle: t.notificationsEmptySubtitle,
                    ),
                  ],
                ),
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
                  itemCount: _notifications.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _NotificationCard(
                    notification: _notifications[i],
                    colors: colors,
                    onRead: () => _markRead(_notifications[i]),
                    onFollow: () => _follow(_notifications[i]),
                  ),
                ),
              ),
      ),
    );
  }
}

class _NotificationCard extends StatelessWidget {
  const _NotificationCard({
    required this.notification,
    required this.colors,
    required this.onRead,
    required this.onFollow,
  });

  final AppNotification notification;
  final AppColors colors;
  final VoidCallback onRead;
  final VoidCallback onFollow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.t;
    final unread = notification.isUnread;

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        // Reading it is the tap. Going somewhere is the button below, on the
        // few that have anywhere to go.
        onTap: onRead,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(_icon, size: 20, color: _tone(colors)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      notification.title.isEmpty
                          ? t.notificationsUntitled
                          : notification.title,
                      style: TextStyle(
                        fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  if (unread) ...[
                    const SizedBox(width: 8),
                    // A dot, and the weight above. Colour alone would say
                    // nothing to somebody who cannot see the difference.
                    Container(
                      width: 9,
                      height: 9,
                      margin: const EdgeInsets.only(top: 5),
                      decoration: BoxDecoration(
                        color: colors.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ],
              ),
              if (notification.body != null) ...[
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 30),
                  child: Text(
                    notification.body!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.only(left: 30, top: 8),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  children: [
                    Text(
                      Fmt.shortDate(t, notification.createdAt),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                    if (notification.route != null)
                      TextButton(
                        onPressed: onFollow,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 36),
                          tapTargetSize: MaterialTapTargetSize.padded,
                        ),
                        child: Text(
                          t.notificationsOpenTab(
                            tabLabel(t, notification.route!.tabId),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData get _icon => switch (notification.type) {
        final String type when type.startsWith('leave.') => Icons.event_available,
        final String type when type.startsWith('attendance.') => Icons.schedule,
        'schedule_updated' => Icons.calendar_month,
        'document_expiring' => Icons.description_outlined,
        'late_arrivals' => Icons.groups_outlined,
        _ => Icons.notifications_none,
      };

  Color _tone(AppColors colors) => switch (notification.type) {
        'leave.approved' => colors.present,
        'leave.rejected' => colors.absent,
        final String type when type.startsWith('attendance.') => colors.late,
        'document_expiring' => colors.late,
        _ => colors.neutral,
      };
}
