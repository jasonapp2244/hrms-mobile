import 'package:flutter/material.dart';

import '../core/biometrics.dart';
import '../core/l10n.dart';
import '../core/theme.dart';
import '../main.dart';

/// Stands in front of the whole app while [AppLock] holds it (B1.3).
///
/// It replaces the home shell rather than covering it, so there is nothing
/// behind it to read through a screenshot or the app switcher.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Ask straight away. Making somebody press a button to be shown a system
    // sheet is one tap that carries no decision.
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // The reason is what the OS prints inside its own sheet, so it comes
      // from here rather than from a constant in AppLock, which has no
      // context to translate one with.
      await SessionScope.read(context).lock.unlock(reason: context.t.lockPromptReason);
      // Nothing to navigate: _Root swaps the shell back in when the lock
      // reports itself open.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The way past a sensor that has stopped saying yes.
  ///
  /// Without it a phone whose fingerprints were removed, or whose face data
  /// was reset, is an app that cannot be opened *or* signed out of — and the
  /// only route back is a reinstall, which also throws away any punch still
  /// waiting in the queue for a signal.
  Future<void> _signOut() async {
    final session = SessionScope.read(context);
    final t = context.t;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.lockSignOutTitle),
        content: Text(t.lockSignOutBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.profileSignOut),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await session.logout();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final t = context.t;
    final lock = SessionScope.of(context).lock;
    final name = SessionScope.of(context).user?.name;
    final failure = lock.failure;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_outline, size: 56, color: AppTheme.brand),
                  const SizedBox(height: 24),
                  Text(
                    t.lockScreenTitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    // The name is worth showing: on a shared work phone it is
                    // the difference between "unlock this" and "unlock this,
                    // which is still signed in as somebody else".
                    name == null
                        ? t.lockScreenPrompt
                        : t.lockScreenPromptNamed(name),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 28),

                  if (failure != null) ...[
                    Container(
                      padding: EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: colors.late.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: colors.late.withValues(alpha: 0.32),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline,
                              color: colors.late, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              AppLock.messageFor(t, failure),
                              style: TextStyle(
                                  color: colors.late, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],

                  FilledButton.icon(
                    onPressed: _busy ? null : _unlock,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.fingerprint),
                    label: Text(t.lockUnlock),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: _busy ? null : _signOut,
                    child: Text(t.lockSignOutInstead),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
