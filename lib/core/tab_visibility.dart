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
