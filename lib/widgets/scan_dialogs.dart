import 'package:flutter/material.dart';

import '../core/l10n.dart';
import '../core/models.dart';
import '../core/theme.dart';

// What the person holding the phone sees between the camera closing and the
// server answering, and then the answer (A4.21).
//
// A snackbar was not enough: the scan is the moment somebody is standing at a
// screen with a queue behind them, and a strip of text at the foot of the
// screen reads as nothing having happened. The loader appears the instant the
// camera lets go, so there is never a still screen in which to scan twice.

/// Shows a spinner that cannot be dismissed, and returns a function that takes
/// it down again. The caller must call it exactly once, before showing anything
/// else.
VoidCallback showScanBusy(BuildContext context, String label) {
  final navigator = Navigator.of(context, rootNavigator: true);

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(width: 20),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 16))),
          ],
        ),
      ),
    ),
  );

  var closed = false;
  return () {
    if (closed) return;
    closed = true;
    navigator.pop();
  };
}

/// The punch the scan recorded: what it was, when, where, and whether it was
/// late or early — the four things somebody walking away wants to be sure of.
Future<void> showPunchRecorded(BuildContext context, Punch punch) {
  final t = context.t;
  final colors = AppColors.of(context);

  final flag = switch (punch.status) {
    'late' => t.historyLateFlag,
    'early_leave' => t.historyEarlyFlag,
    _ => null,
  };

  return showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (dialogContext) => AlertDialog(
      icon: Icon(Icons.check_circle, color: colors.present, size: 56),
      title: Text(punch.label(t), textAlign: TextAlign.center),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            punch.time,
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
          ),
          if (punch.office != null) ...[
            const SizedBox(height: 4),
            Text(punch.office!, textAlign: TextAlign.center),
          ],
          if (flag != null) ...[
            const SizedBox(height: 8),
            Text(
              flag,
              style: TextStyle(color: colors.late, fontWeight: FontWeight.w600),
            ),
          ],
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(t.actionDone),
        ),
      ],
      actionsAlignment: MainAxisAlignment.center,
    ),
  );
}

/// A scan that did not become a punch. Resolves to true when the person asked
/// to scan again.
Future<bool> showScanRefused(
  BuildContext context, {
  required String message,
  required Color color,
  bool offerRescan = false,
}) async {
  final t = context.t;

  final again = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (dialogContext) => AlertDialog(
      icon: Icon(Icons.error_outline, color: color, size: 48),
      title: Text(t.scanNotRecorded, textAlign: TextAlign.center),
      content: Text(message, textAlign: TextAlign.center),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        if (offerRescan) ...[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(t.scanAgain),
          ),
        ] else
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(t.actionOk),
          ),
      ],
    ),
  );

  return again ?? false;
}
