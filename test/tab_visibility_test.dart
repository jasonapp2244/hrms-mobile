import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:attendance/core/tab_visibility.dart';

/// A screen that counts how often it was asked to refetch.
class _Counting extends StatefulWidget {
  const _Counting(this.flag);

  final TabVisibility flag;

  @override
  State<_Counting> createState() => _CountingState();
}

class _CountingState extends State<_Counting> with RefreshOnShow<_Counting> {
  int refreshes = 0;

  @override
  ValueListenable<bool> get visibility => widget.flag;

  @override
  Future<void> refresh() async => refreshes++;

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets('returning to a tab refetches it', (tester) async {
    final flag = TabVisibility(visible: false);
    await tester.pumpWidget(_Counting(flag));
    final state = tester.state<_CountingState>(find.byType(_Counting));

    flag.value = true;
    expect(state.refreshes, 1);
  });

  testWidgets('a notification for the tab already on screen refetches it too', (tester) async {
    // Found on a handset: HR sat on the HR tab, a "requested leave" push
    // arrived, and tapping it left "Nothing waiting" on screen — true to true
    // is no change to a ValueNotifier, so nothing told the screen to look.
    final flag = TabVisibility(visible: true);
    await tester.pumpWidget(_Counting(flag));
    final state = tester.state<_CountingState>(find.byType(_Counting));

    flag.value = true;
    expect(state.refreshes, 0, reason: 'setting the same value is silent');

    flag.showAgain();
    expect(state.refreshes, 1);
  });

  group('coming back to the app', () {
    // Found on a handset: HR left the app on the HR tab, the request on it was
    // decided elsewhere, and a quarter of an hour later the phone still offered
    // Approve on it. Nothing refetched on the way back in.
    var now = DateTime(2026, 9, 29, 9);
    ResumeCheck check() => ResumeCheck(clock: () => now);

    test('a long absence asks for fresh data', () {
      final c = check();
      c.left();
      now = now.add(const Duration(minutes: 15));
      expect(c.cameBack(), isTrue);
    });

    test('a quick trip out — the file picker, a permission — does not', () {
      final c = check();
      c.left();
      now = now.add(const Duration(seconds: 5));
      expect(c.cameBack(), isFalse);
    });

    test('the absence is measured from the first time it left', () {
      // Paused then hidden arrive together; the second must not restart the clock.
      final c = check();
      c.left();
      now = now.add(const Duration(seconds: 25));
      c.left();
      now = now.add(const Duration(seconds: 10));
      expect(c.cameBack(), isTrue);
    });

    test('coming back without having left is not an absence', () {
      expect(check().cameBack(), isFalse);
    });
  });

  testWidgets('showing again a tab that is off screen does nothing', (tester) async {
    final flag = TabVisibility(visible: false);
    await tester.pumpWidget(_Counting(flag));
    final state = tester.state<_CountingState>(find.byType(_Counting));

    flag.showAgain();
    expect(state.refreshes, 0);
  });
}
