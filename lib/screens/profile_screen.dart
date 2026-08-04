import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/api_client.dart';
import '../core/theme.dart';
import '../main.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final user = session.user;
    final theme = Theme.of(context);

    if (user == null) return const SizedBox.shrink();

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: AppTheme.brand.withValues(alpha: 0.15),
                    child: Text(
                      user.initials,
                      style: const TextStyle(
                        color: AppTheme.brandDeep,
                        fontWeight: FontWeight.w700,
                        fontSize: 20,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user.employee?.fullName ?? user.name,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          user.email,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (user.employee != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            user.employee!.employeeCode,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // An account with no employee record signs in fine and then gets 403
          // from every employee-scoped endpoint. Say so, rather than leaving
          // somebody to discover it one empty screen at a time.
          if (!user.hasEmployeeRecord) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.late.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.late.withValues(alpha: 0.32)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: AppTheme.late, size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'This account is not linked to an employee record, so clocking, '
                      'leave and schedule are unavailable. Use the web dashboard.',
                      style: TextStyle(color: AppTheme.late, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          if (user.employee != null) ...[
            _InfoCard(rows: [
              ('Department', user.employee!.department ?? '—'),
              ('Job title', user.employee!.designation ?? '—'),
              ('Office', user.employee!.office ?? '—'),
              ('Work mode', _workMode(user.employee!.workMode)),
            ]),
            const SizedBox(height: 16),
          ],

          _InfoCard(rows: [
            ('Company', user.company?.name ?? '—'),
            ('Timezone', user.company?.timezone ?? '—'),
            ('Roles', user.roles.isEmpty ? '—' : user.roles.join(', ')),
          ]),
          const SizedBox(height: 24),

          OutlinedButton.icon(
            onPressed: () => _changePassword(context),
            icon: const Icon(Icons.lock_outline),
            label: const Text('Change password'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => _signOut(context, everywhere: false),
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: () => _signOut(context, everywhere: true),
            icon: const Icon(Icons.phonelink_erase, size: 20),
            label: const Text('Sign out on all devices'),
            style: TextButton.styleFrom(foregroundColor: AppTheme.absent),
          ),

          // Both stores expect the privacy policy to be reachable from inside
          // the app, not only from the listing, and Apple looks for a route to
          // account deletion. Neither page needs a login — a reviewer has no
          // account, and neither does somebody who has already left the company.
          const SizedBox(height: 28),
          const Divider(),
          const SizedBox(height: 4),
          _LinkRow(
            icon: Icons.privacy_tip_outlined,
            label: 'Privacy policy',
            path: '/privacy',
          ),
          _LinkRow(
            icon: Icons.person_remove_outlined,
            label: 'Delete my account',
            path: '/account-deletion',
          ),
        ],
      ),
    );
  }

  static String _workMode(String? mode) => switch (mode) {
        'office' => 'Office',
        'wfh' => 'Working from home',
        'hybrid' => 'Hybrid',
        _ => mode ?? '—',
      };

  Future<void> _signOut(BuildContext context, {required bool everywhere}) async {
    final session = SessionScope.read(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(everywhere ? 'Sign out everywhere?' : 'Sign out?'),
        content: Text(
          everywhere
              ? 'Every device signed in with this account is signed out, and every '
                  'registered handset stops receiving your notifications. Use this '
                  'if a phone has been lost.'
              : 'You will need your password to sign back in.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: everywhere ? AppTheme.absent : null,
            ),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    if (everywhere) {
      await session.logoutEverywhere();
    } else {
      // The push token would go here once Firebase is configured — without it
      // the handset keeps receiving this person's notifications after sign-out.
      await session.logout();
    }
  }

  Future<void> _changePassword(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _ChangePasswordSheet(),
    );
  }
}

/// A row that opens one of the server's public legal pages in the browser.
///
/// The host comes from the API base URL, so a build pointed at a staging server
/// shows that server's policy rather than silently linking to production.
class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.icon, required this.label, required this.path});

  final IconData icon;
  final String label;
  final String path;

  Future<void> _open(BuildContext context) async {
    final url = Uri.parse('${ApiClient.siteUrl}$path');

    // Outside the app rather than in a web view: a policy shown in a frame the
    // app controls is worth less than one the person can see the address of.
    final opened = await launchUrl(url, mode: LaunchMode.externalApplication);

    if (!opened && context.mounted) {
      // Failing silently would look identical to a page that opened behind the
      // app, so say what could not be reached and where it lives.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open $url')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, size: 21, color: theme.colorScheme.onSurfaceVariant),
      title: Text(label, style: theme.textTheme.bodyMedium),
      trailing: Icon(
        Icons.open_in_new,
        size: 17,
        color: theme.colorScheme.outline,
      ),
      onTap: () => _open(context),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 13),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 108,
                      child: Text(
                        rows[i].$1,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        rows[i].$2,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ChangePasswordSheet extends StatefulWidget {
  const _ChangePasswordSheet();

  @override
  State<_ChangePasswordSheet> createState() => _ChangePasswordSheetState();
}

class _ChangePasswordSheetState extends State<_ChangePasswordSheet> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();

  bool _busy = false;
  String? _error;
  Map<String, String> _fieldErrors = const {};

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
      _fieldErrors = const {};
    });

    try {
      await SessionScope.read(context).api.put('/profile/password', body: {
        'current_password': _current.text,
        'password': _next.text,
        'password_confirmation': _confirm.text,
      });

      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Password changed.'),
          backgroundColor: AppTheme.present,
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _fieldErrors = {
          for (final entry in e.fieldErrors.entries)
            if (entry.value.isNotEmpty) entry.key: entry.value.first,
        };
        _error = e.error == 'wrong_password'
            ? 'That is not your current password.'
            : (_fieldErrors.isEmpty ? e.displayMessage : null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Change password',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 20),
            if (_error != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
              const SizedBox(height: 14),
            ],
            TextField(
              controller: _current,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Current password',
                errorText: _fieldErrors['current_password'],
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _next,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'New password',
                errorText: _fieldErrors['password'],
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirm,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirm new password'),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _submit,
              style: FilledButton.styleFrom(backgroundColor: AppTheme.brand),
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                    )
                  : const Text('Change password'),
            ),
          ],
        ),
      ),
    );
  }
}
