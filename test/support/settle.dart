import 'package:flutter_test/flutter_test.dart';

/// Let a screen finish a load that goes through the offline cache.
///
/// Three things here are not decoration. `pumpAndSettle` never returns, because
/// the loading indicator animates until the fetch lands and the fetch cannot
/// land while it is pumping. The cache writes every reply to a real file, which
/// only advances inside [WidgetTester.runAsync] — without that the request is
/// sent, the write blocks for ever, and the screen sits on its spinner having
/// quietly never applied the response.
///
/// And the two must **alternate**. `runAsync` gives the disk real time; `pump`
/// drains the continuations that finish because of it — and a load is a chain
/// of them (reply, then write, then `setState`), so one of each is not enough.
/// With a single pass the request goes out, the response never reaches the
/// state, and the screen asks its next question with nothing learnt from the
/// first — which reads exactly like the bug most of these tests are about.
///
/// **The rounds are real wall-clock time, so the count is a bet on how busy the
/// machine is.** `flutter test` runs files concurrently: a budget that is
/// comfortable for one file on an idle box is not comfortable for sixteen of
/// them on a loaded one, and when it runs out the failure looks like a screen
/// that ignored its own response rather than like a test that did not wait for
/// it. Twelve rounds rather than the six this started at, because the cost of
/// the extra ones is a few seconds across the suite and the cost of being short
/// is an intermittent red build nobody can reproduce.
///
/// Lives here rather than in each file because three of them had byte-identical
/// copies, and a timing budget that has to be raised in three places will be
/// raised in one.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
  }
  await tester.pump(const Duration(milliseconds: 400));
}
