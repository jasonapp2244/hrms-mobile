import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Whether a tab is the one currently on screen.
///
/// `HomeShell` holds every tab in an `IndexedStack`, so a screen is built once
/// and then kept alive — switching back is instant and scroll position and
/// filters survive. The cost is that a screen keeps showing whatever it
/// fetched when it was first built. That is how checking in on Clock and then
/// opening History showed today as "Absent": the punch was recorded, but
/// History was still displaying the answer it got before the punch existed.
///
/// The shell flips one of these per tab, and each screen refetches when its
/// own flag turns true.
class TabVisibility extends ValueNotifier<bool> {
  TabVisibility({required bool visible}) : super(visible);

  /// Tells a tab that is already on screen to look again.
  ///
  /// Setting `value` to true when it is already true notifies nobody, which is
  /// right for an ordinary tap on the current tab and wrong for a tapped
  /// notification: HR sitting on the HR tab tapped "requested leave" and was
  /// left looking at "Nothing waiting". A tab off screen is left alone — it
  /// refetches when it is shown.
  void showAgain() {
    if (value) notifyListeners();
  }
}

/// Whether the app was away long enough that the tab on screen is out of date.
///
/// Switching tabs refetches; coming back to the app did not, so a phone left
/// on the HR tab still offered Approve on a request decided a quarter of an
/// hour earlier. The threshold keeps a quick trip out — the file picker for a
/// leave attachment, a permission prompt — from reloading what the person is
/// in the middle of. The same shape as the app gate's own re-check.
class ResumeCheck {
  ResumeCheck({
    this.after = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration after;
  final DateTime Function() _clock;
  DateTime? _leftAt;

  /// The app went to the background. Paused and hidden both arrive; the first
  /// one starts the clock.
  void left() => _leftAt ??= _clock();

  /// The app is back. True when it was away for at least [after].
  bool cameBack() {
    final left = _leftAt;
    _leftAt = null;
    return left != null && _clock().difference(left) >= after;
  }
}

/// Refetches a screen's data whenever the user returns to its tab.
///
/// Mix this into a screen's [State], point [visibility] at the flag the shell
/// passed in, and put the fetch in [refresh].
mixin RefreshOnShow<T extends StatefulWidget> on State<T> {
  /// The flag `HomeShell` flips for this screen.
  ValueListenable<bool> get visibility;

  /// Fetch again, because the tab just came back into view.
  ///
  /// The user is already looking at the previous answer, so this should update
  /// in place rather than clearing the screen back to a spinner.
  Future<void> refresh();

  @override
  void initState() {
    super.initState();
    visibility.addListener(_onVisibilityChanged);
  }

  @override
  void dispose() {
    visibility.removeListener(_onVisibilityChanged);
    super.dispose();
  }

  void _onVisibilityChanged() {
    if (visibility.value && mounted) {
      refresh();
    }
  }
}
