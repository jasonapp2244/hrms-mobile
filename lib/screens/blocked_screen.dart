import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_gate.dart';
import '../core/l10n.dart';
import '../core/theme.dart';
import '../main.dart';

/// Shown instead of the whole app when the server says this build must stop
/// (B6.6) — either too old, or a maintenance window.
///
/// It replaces everything, the login screen included: during a window there is
/// nothing to sign in to, and an old build failing at the API one screen at a
/// time is exactly the confusion this exists to prevent.
class BlockedScreen extends StatelessWidget {
  const BlockedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.t;
    final gate = SessionScope.of(context).gate;
    final updating = gate.action == GateAction.updateRequired;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    updating ? Icons.system_update : Icons.build_circle_outlined,
                    size: 56,
                    color: AppTheme.brand,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    updating ? t.gateUpdateTitle : t.gateMaintenanceTitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    // The server's own words where it has any: it is the only
                    // side that can say when a window ends, and "try later"
                    // with no hour in it is what makes somebody keep trying.
                    gate.message ??
                        (updating ? t.gateUpdateBody : t.gateMaintenanceBody),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 28),

                  // Only when there is somewhere to go. The server withholds
                  // the link for a platform it has none for, and answers `ok`
                  // rather than blocking — but a build that got here with no
                  // link must not draw a button that does nothing.
                  if (updating && gate.storeUrl != null) ...[
                    FilledButton.icon(
                      onPressed: () => _openStore(context, gate.storeUrl!),
                      icon: const Icon(Icons.open_in_new),
                      label: Text(t.gateOpenStore),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],

                  OutlinedButton.icon(
                    onPressed: gate.isChecking ? null : gate.check,
                    icon: gate.isChecking
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2.2),
                          )
                        : const Icon(Icons.refresh),
                    // Worth offering on both screens. An update is finished by
                    // leaving and coming back, and a window ends without the
                    // app being told.
                    label: Text(t.actionTryAgain),
                  ),

                  const SizedBox(height: 28),
                  Text(
                    t.gateFooter,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openStore(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.of(context);
    final message = context.t.gateNoStore;
    final uri = Uri.tryParse(url);

    if (uri != null && await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      return;
    }

    // A phone with no store app, or a link the server got wrong. Saying so
    // beats a button that appears to do nothing.
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}
