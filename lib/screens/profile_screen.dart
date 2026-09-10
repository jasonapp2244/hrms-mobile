import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/api_client.dart';
import '../core/biometrics.dart';
import '../core/l10n.dart';
import '../core/locale.dart';
import '../core/theme.dart';
import '../main.dart';
import '../widgets/async_view.dart';
import 'directory_screen.dart';
import 'documents_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final session = SessionScope.of(context);
    final user = session.user;
    final theme = Theme.of(context);
    final t = context.t;

    if (user == null) return const SizedBox.shrink();

    return Scaffold(
      appBar: AppBar(title: Text(t.profileTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          // This screen is drawn entirely from the signed-in user, so with no
          // signal at launch it is drawn from the saved copy of it. Say so:
          // a department or job title changed since then would otherwise read
          // as current.
          OfflineBanner(savedAt: session.offlineSince),
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
                      style: TextStyle(
                        color: colors.accent,
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
              padding: EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.late.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colors.late.withValues(alpha: 0.32)),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: colors.late, size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      t.profileNoEmployeeRecord,
                      style: TextStyle(color: colors.late, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          if (user.employee != null) ...[
            _InfoCard(rows: [
              (t.profileDepartment, user.employee!.department ?? '—'),
              (t.profileJobTitle, user.employee!.designation ?? '—'),
              (t.profileOffice, user.employee!.office ?? '—'),
              (t.profileWorkMode, _workMode(t, user.employee!.workMode)),
            ]),
            const SizedBox(height: 16),
          ],

          _InfoCard(rows: [
            (t.profileCompany, user.company?.name ?? '—'),
            (t.profileTimezone, user.company?.timezone ?? '—'),
            (t.profileRoles, user.roles.isEmpty ? '—' : user.roles.join(', ')),
          ]),
          const SizedBox(height: 24),

          // Only for somebody who has a record to hold documents against. An
          // admin login would 403 the moment the screen opened.
          if (user.hasEmployeeRecord) ...[
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const DocumentsScreen()),
              ),
              icon: const Icon(Icons.folder_outlined),
              label: Text(t.profileMyDocuments),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const DirectoryScreen()),
              ),
              icon: const Icon(Icons.people_outline),
              label: Text(t.profileColleagues),
            ),
            const SizedBox(height: 10),
          ],
          OutlinedButton.icon(
            onPressed: () => _editProfile(context),
            icon: const Icon(Icons.edit_outlined),
            label: Text(t.profileEditContact),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => _changePassword(context),
            icon: const Icon(Icons.lock_outline),
            label: Text(t.profileChangePassword),
          ),
          const SizedBox(height: 10),
          const _LanguageTile(),
          const _BiometricLockTile(),
          OutlinedButton.icon(
            onPressed: () => _signOut(context, everywhere: false),
            icon: const Icon(Icons.logout),
            label: Text(t.profileSignOut),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: () => _signOut(context, everywhere: true),
            icon: const Icon(Icons.phonelink_erase, size: 20),
            label: Text(t.profileSignOutAll),
            style: TextButton.styleFrom(foregroundColor: colors.absent),
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
            label: t.profilePrivacy,
            path: '/privacy',
          ),
          _LinkRow(
            icon: Icons.person_remove_outlined,
            label: t.profileDeleteAccount,
            path: '/account-deletion',
          ),
        ],
      ),
    );
  }

  static String _workMode(AppLocalizations t, String? mode) => switch (mode) {
        'office' => t.workModeOffice,
        'wfh' => t.workModeWfh,
        'hybrid' => t.workModeHybrid,
        _ => mode ?? '—',
      };

  Future<void> _signOut(BuildContext context, {required bool everywhere}) async {
    // Read before the first await: the palette cannot change mid-call, and
    // reaching for a BuildContext after one is the lint this avoids.
    final colors = AppColors.of(context);
    final session = SessionScope.read(context);
    final t = context.t;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          everywhere ? t.profileSignOutAllTitle : t.profileSignOutTitle,
        ),
        content: Text(
          everywhere ? t.profileSignOutAllBody : t.profileSignOutBody,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: everywhere ? colors.absent : null,
            ),
            child: Text(t.profileSignOut),
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

  Future<void> _editProfile(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _EditProfileSheet(),
    );
  }
}

/// Which language the app is drawn in (B6.2).
///
/// Sits next to the biometric switch because both describe **this handset**
/// rather than the account, and both survive a sign-out — see [AppLocale] for
/// why that is the right answer for a language in particular.
///
/// Every option is written in its own language. "Spanish" is no help to
/// somebody looking for the word Español, and the whole reason this row exists
/// is that they are reading a screen they do not follow.
class _LanguageTile extends StatelessWidget {
  const _LanguageTile();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.t;
    final locale = SessionScope.of(context).locale;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: PopupMenuButton<String>(
        // The empty string is "follow the phone", which is the default and is
        // not a language — hence a sentinel rather than a nullable value, which
        // PopupMenuButton would read as "nothing selected".
        initialValue: locale.locale?.languageCode ?? '',
        onSelected: (code) => locale.set(code.isEmpty ? null : Locale(code)),
        tooltip: t.profileLanguage,
        itemBuilder: (_) => [
          PopupMenuItem(
            value: '',
            child: Text(t.languageFollowSystem),
          ),
          for (final supported in AppLocale.supported)
            PopupMenuItem(
              value: supported.languageCode,
              child: Text(AppLocale.names[supported.languageCode] ?? supported.languageCode),
            ),
        ],
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
          leading: const Icon(Icons.translate, size: 21),
          title: Text(t.profileLanguage, style: theme.textTheme.bodyMedium),
          subtitle: Text(
            locale.followsSystem
                ? t.languageFollowSystemDetail
                : t.languageKeptOnSignOut,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          trailing: Text(
            locale.followsSystem
                ? t.languageFollowSystem
                : (AppLocale.names[locale.locale!.languageCode] ??
                    locale.locale!.languageCode),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// The switch that puts this handset behind its own biometric check (B1.3).
///
/// **Drawn only on a phone that has one enrolled.** A row offering fingerprint
/// unlock on a device with nothing but a PIN would prompt for that PIN and call
/// it a fingerprint; a row that is present but disabled would invite somebody
/// to go looking for a setting that is not the app's to change.
class _BiometricLockTile extends StatefulWidget {
  const _BiometricLockTile();

  @override
  State<_BiometricLockTile> createState() => _BiometricLockTileState();
}

class _BiometricLockTileState extends State<_BiometricLockTile> {
  /// Asked once. The answer changes only when somebody enrols a fingerprint in
  /// the phone's own settings, which takes them out of the app and back in.
  late final Future<bool> _available =
      SessionScope.read(context).lock.isAvailable();

  bool _busy = false;

  Future<void> _set(bool on) async {
    final lock = SessionScope.read(context).lock;
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;

    setState(() => _busy = true);
    try {
      if (!on) {
        // No check to turn it off: this screen is already on the far side of
        // the lock.
        await lock.disable();
        return;
      }

      final outcome = await lock.enable(reason: t.lockPromptReason);
      if (outcome == BiometricOutcome.granted) return;

      // Turning it on is the one place a refusal has to be reported. The
      // switch springs back on its own — the state is read from the lock —
      // so without this it looks like the tap simply missed.
      messenger.showSnackBar(SnackBar(
        content: Text(
          outcome == BiometricOutcome.refused
              ? t.lockNotTurnedOn
              : AppLock.messageFor(t, outcome),
        ),
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lock = SessionScope.of(context).lock;
    final theme = Theme.of(context);

    return FutureBuilder<bool>(
      future: _available,
      builder: (context, snapshot) {
        if (snapshot.data != true) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SwitchListTile(
            value: lock.isEnabled,
            onChanged: _busy ? null : _set,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
            secondary: const Icon(Icons.fingerprint, size: 21),
            title: Text(context.t.lockTileTitle, style: theme.textTheme.bodyMedium),
            subtitle: Text(
              context.t.lockTileSubtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      },
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
        SnackBar(content: Text(context.t.profileCouldNotOpen('$url'))),
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

/// Editing the contact details on the account (B3.2).
///
/// `PUT /profile` has existed since the API shipped and nothing ever called it,
/// which is the whole of what was missing here.
///
/// **The sign-in address is shown but not editable.** The endpoint accepts a new
/// `email`, and this screen deliberately declines to offer one: changing the
/// address somebody signs in with is an account takeover in two steps — set it
/// to your own, then use "forgot password" — and it would need nothing but an
/// unlocked phone. Changing the *password* already demands the current one for
/// exactly that reason. Until the endpoint asks for a password too, the address
/// is read here and posted back unchanged, because the validator requires it.
class _EditProfileSheet extends StatefulWidget {
  const _EditProfileSheet();

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  final _name = TextEditingController();
  final _phone = TextEditingController();

  /// Read from the server and posted straight back. Never bound to a field.
  String _email = '';

  bool _loading = true;
  bool _busy = false;
  String? _error;
  Map<String, String> _fieldErrors = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  /// The current values come from `GET /profile`, not from the signed-in user:
  /// `/auth/me` does not carry a phone, and prefilling a phone field with blank
  /// would look like "we have no number for you" and invite somebody to retype
  /// one they had already given.
  Future<void> _load() async {
    try {
      final res = await SessionScope.read(context).api.get('/profile');
      final account = (res['account'] as Map<String, dynamic>?) ?? const {};

      if (!mounted) return;
      setState(() {
        _name.text = '${account['name'] ?? ''}';
        _phone.text = '${account['phone'] ?? ''}';
        _email = '${account['email'] ?? ''}';
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      // Read here rather than before the request: the first load runs from
      // initState, and reaching for the strings there registers an
      // inherited-widget dependency before the element has finished
      // building, which asserts.
      final t = context.t;
      setState(() {
        _loading = false;
        _error = e.text(t);
      });
    }
  }

  Future<void> _submit() async {
    // Read before the first await: neither the palette nor the strings can
    // change mid-call, and reaching for a BuildContext after one is the lint
    // this avoids.
    final colors = AppColors.of(context);
    final t = context.t;

    setState(() {
      _busy = true;
      _error = null;
      _fieldErrors = const {};
    });

    final session = SessionScope.read(context);

    try {
      await session.api.put('/profile', body: {
        'name': _name.text.trim(),
        // Unchanged, and required by the validator. See the class comment.
        'email': _email,
        'phone': _phone.text.trim(),
      });

      // The name is on the header of this very screen and on every greeting,
      // so the cached user has to catch up or the change looks like it failed.
      await session.refreshUser();

      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t.editProfileSaved),
          backgroundColor: colors.present,
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
        _error = _fieldErrors.isEmpty ? e.text(t) : null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.t;

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
              t.editProfileTitle,
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
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
              )
            else ...[
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: t.editProfileName,
                  errorText: _fieldErrors['name'],
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: t.editProfilePhone,
                  errorText: _fieldErrors['phone'],
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                enabled: false,
                controller: TextEditingController(text: _email),
                decoration: InputDecoration(
                  labelText: t.editProfileSignInEmail,
                  helperText: t.editProfileEmailHelp,
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy ? null : _submit,
                // Same as everywhere else: the theme primary carries its own
                // label at 4.72:1, and #F26522 does not (B6.4).
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                      )
                    : Text(t.actionSave),
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
    // Read before the first await: neither the palette nor the strings can
    // change mid-call, and reaching for a BuildContext after one is the lint
    // this avoids.
    final colors = AppColors.of(context);
    final t = context.t;

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
        SnackBar(
          content: Text(t.passwordChanged),
          backgroundColor: colors.present,
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
            ? t.passwordWrong
            : (_fieldErrors.isEmpty ? e.text(t) : null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.t;

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
              t.passwordTitle,
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
                labelText: t.passwordCurrent,
                errorText: _fieldErrors['current_password'],
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _next,
              obscureText: true,
              decoration: InputDecoration(
                labelText: t.passwordNew,
                errorText: _fieldErrors['password'],
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirm,
              obscureText: true,
              decoration: InputDecoration(labelText: t.passwordConfirm),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                    )
                  : Text(t.passwordTitle),
            ),
          ],
        ),
      ),
    );
  }
}
