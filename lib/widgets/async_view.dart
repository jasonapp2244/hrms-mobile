import 'package:flutter/material.dart';

import '../core/l10n.dart';
import '../core/theme.dart';

/// The three states every data screen has, in one place: loading, failed with
/// a way back, or the real content.
///
/// Worth centralising because the failure case is the one most often skipped,
/// and a screen that silently shows nothing when the server is unreachable is
/// indistinguishable from a screen with no data.
class AsyncView extends StatelessWidget {
  const AsyncView({
    super.key,
    required this.loading,
    required this.child,
    this.error,
    this.onRetry,
  });

  final bool loading;
  final String? error;
  final VoidCallback? onRetry;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (error != null) {
      final theme = Theme.of(context);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 44, color: theme.colorScheme.outline),
              const SizedBox(height: 16),
              Text(
                error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: Text(context.t.actionTryAgain),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(140, 44),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return child;
  }
}

/// Says that what is on screen came off the disk rather than off the wire
/// (B6.3).
///
/// Every screen that can serve a saved copy shows this above it, always. A
/// roster that is quietly three days old is worse than no roster: somebody
/// turns up for a shift that was moved, and nothing on the screen ever gave
/// them a reason to doubt it. The date is part of the message for the same
/// reason — "offline" alone does not say whether this is an hour stale or a
/// week.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, required this.savedAt, this.onRetry});

  /// When this copy was taken. Null hides the banner, so a screen can pass its
  /// state straight in without branching.
  final DateTime? savedAt;

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final when = savedAt;
    if (when == null) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.only(bottom: 16),
      child: Container(
        padding: EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(
          color: colors.neutral.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.neutral.withValues(alpha: 0.34)),
        ),
        child: Row(
          children: [
            Icon(Icons.cloud_off, color: colors.neutral, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                context.t.offlineSavedCopy(Fmt.savedAt(context.t, when)),
                style: TextStyle(color: colors.neutral, fontSize: 13),
              ),
            ),
            if (onRetry != null)
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(foregroundColor: colors.neutral),
                child: Text(context.t.actionRetry),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shown where a list has legitimately nothing in it — which is different from
/// a list that failed to load, and should never look the same.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: theme.colorScheme.outline),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
