import 'package:flutter/foundation.dart';
import 'package:quick_actions/quick_actions.dart' as plugin;

/// B2.8 — what a launcher shortcut asks the app to do.
///
/// Long-press the app icon and the OS offers one item: **Clock in** or **Clock
/// out**, whichever the person's day calls for next. Tapping it opens the app
/// on the Clock tab and makes the punch, so the whole thing is one press and
/// one tap from the home screen rather than a launch, a wait and a hunt for
/// the button.
///
/// **The wire value is an identifier and the label is not** — trap 18 in
/// `CLAUDE.md`, and it bites harder here than anywhere else in the app. The OS
/// hands back the `type` string it was given, and that string outlives the
/// run: it sits on the launcher until something replaces it. A Spanish handset
/// publishes "Fichar entrada" as the title and `clock_in` as the type, and the
/// type is the only half this enum ever reads.
enum QuickAction {
  /// Published when the next punch would put somebody on the clock.
  clockIn('clock_in'),

  /// Published when they are already on it.
  clockOut('clock_out');

  const QuickAction(this.wireValue);

  /// The `type` handed to the OS, and handed back on a tap.
  final String wireValue;

  /// The action that matches the day the server has described.
  ///
  /// Reads the same `next_action` the big button on the Clock screen reads, so
  /// the shortcut and the button cannot disagree about which way the next
  /// punch goes.
  static QuickAction forNextPunch({required bool willClockIn}) =>
      willClockIn ? QuickAction.clockIn : QuickAction.clockOut;

  /// Null for anything this build does not recognise.
  ///
  /// Not hypothetical, and not only a version-skew question: the shortcut on
  /// the launcher was written by whichever build published it, so an app
  /// downgraded — or one whose enum was renamed — is handed a string its own
  /// code has never seen. Opening the app normally is the right answer; the
  /// person is then one tap from the button that does the same job.
  static QuickAction? parse(Object? value) {
    for (final action in QuickAction.values) {
      if (action.wireValue == value) return action;
    }
    return null;
  }
}

/// One row on the long-press menu.
///
/// No icon, deliberately. An icon here is a **native** resource — a drawable on
/// Android and an xcasset on iOS, neither of which is a Flutter asset — so
/// shipping one means two more files that no Dart test can see and that fail
/// by drawing nothing at all. The launcher falls back to the app icon, which is
/// the KEMP mark, and that is already the right picture for "clock in".
@immutable
class QuickActionItem {
  const QuickActionItem({required this.type, required this.title});

  /// A [QuickAction.wireValue]. Never a translated string.
  final String type;

  /// What the person reads. Translated, and therefore never compared against
  /// anything.
  final String title;

  @override
  bool operator ==(Object other) =>
      other is QuickActionItem && other.type == type && other.title == title;

  @override
  int get hashCode => Object.hash(type, title);
}

/// The launcher's shortcut list, behind an interface.
///
/// The same reasoning as `PushProvider` and `LocationSource`: the real one is a
/// platform channel, and a headless `flutter test` has no launcher to talk to.
/// Every caller goes through this.
abstract class QuickActionProvider {
  /// Starts listening for taps.
  ///
  /// The handler fires for a shortcut tapped while the app was running **and**
  /// for the one that launched it from cold — the plugin replays the launch
  /// selection into this callback, so unlike push there is no separate "what
  /// started me" call to remember.
  ///
  /// Implementations must not throw.
  Future<void> initialize(void Function(String type) onSelected);

  /// Replaces the whole list. An empty list is a legitimate value and means
  /// "offer nothing".
  Future<void> setItems(List<QuickActionItem> items);

  /// Takes every shortcut off the launcher.
  Future<void> clearItems();
}

/// A handset with no launcher shortcuts.
///
/// The default everywhere, exactly like `DisabledPushProvider`: tests use it,
/// desktop uses it, and so does any platform the plugin does not cover. B2.8 is
/// a convenience on top of a button that still works, so its absence has to be
/// silent.
class DisabledQuickActionProvider implements QuickActionProvider {
  const DisabledQuickActionProvider();

  @override
  Future<void> initialize(void Function(String type) onSelected) async {}

  @override
  Future<void> setItems(List<QuickActionItem> items) async {}

  @override
  Future<void> clearItems() async {}
}

/// The real thing, on top of `quick_actions`.
class PluginQuickActionProvider implements QuickActionProvider {
  const PluginQuickActionProvider([this._actions = const plugin.QuickActions()]);

  final plugin.QuickActions _actions;

  /// Android and iOS only.
  ///
  /// Checked here rather than at the call site, so nothing above this class has
  /// to know which platforms have a launcher menu. The plugin has no desktop
  /// implementation, so calling it there throws `MissingPluginException` on a
  /// path the app takes at every launch.
  static bool get isSupported =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Future<void> initialize(void Function(String type) onSelected) async {
    if (!isSupported) return;
    try {
      await _actions.initialize(onSelected);
    } catch (error) {
      debugPrint('Quick actions unavailable: $error');
    }
  }

  @override
  Future<void> setItems(List<QuickActionItem> items) async {
    if (!isSupported) return;
    try {
      await _actions.setShortcutItems([
        for (final item in items)
          plugin.ShortcutItem(type: item.type, localizedTitle: item.title),
      ]);
    } catch (error) {
      debugPrint('Quick actions could not be published: $error');
    }
  }

  @override
  Future<void> clearItems() async {
    if (!isSupported) return;
    try {
      await _actions.clearShortcutItems();
    } catch (error) {
      debugPrint('Quick actions could not be cleared: $error');
    }
  }
}

/// Keeps the launcher's shortcut in step with the person's day, and carries a
/// tap back into the app.
///
/// Owned by `Session` for the reason `PushService` is: a shortcut is worth
/// offering only while somebody is signed in, and has to come off the launcher
/// the moment they are not. **A shared work handset** is the case that makes
/// that non-negotiable — a "Clock out" left on the launcher by the last person
/// is one tap from clocking out the next one.
class QuickActionService {
  QuickActionService({
    QuickActionProvider provider = const DisabledQuickActionProvider(),
  }) : _provider = provider;

  final QuickActionProvider _provider;

  /// What is currently on the launcher, so an unchanged day does not repost the
  /// same list every time the Clock screen refreshes.
  QuickActionItem? _published;

  /// The shortcut on the launcher, for a test to read. Null when there is none.
  @visibleForTesting
  QuickActionItem? get published => _published;

  /// A tap waiting to be acted on.
  ///
  /// A [ValueNotifier] rather than a stream, for the reason
  /// `PushService.pendingRoute` is one: launching from a shortcut resolves the
  /// tap before any screen exists, and a stream event with no listener is lost
  /// where a value waits. It can wait a while, and that is correct — a handset
  /// behind the biometric lock (B1.3) holds the punch until the person unlocks,
  /// which is the only honest moment to make it.
  final ValueNotifier<QuickAction?> pending = ValueNotifier(null);

  bool _listening = false;

  /// Begins listening. Safe to call on every launch and every sign-in, which is
  /// what the session does.
  Future<void> start() async {
    if (_listening) return;
    _listening = true;
    await _provider.initialize(handleSelection);
  }

  /// Records a tap. Public for the tests, which have no launcher to tap.
  @visibleForTesting
  void handleSelection(String type) {
    final action = QuickAction.parse(type);
    if (action != null) pending.value = action;
  }

  /// Puts the one shortcut that matches the day on the launcher.
  ///
  /// **One item, never two.** Offering "Clock in" and "Clock out" side by side
  /// would let somebody pick the one that is not true, and the server decides
  /// the direction from the punches before it — so the tap would succeed, and
  /// the label would have lied about what it did.
  ///
  /// [title] arrives already translated, from the screen that holds a
  /// `BuildContext`. A service cannot reach one, and hard-coding English here
  /// would leave the most prominent string this app puts *outside* itself the
  /// one thing that never translates (B6.2).
  Future<void> publish({
    required bool willClockIn,
    required String title,
  }) async {
    final item = QuickActionItem(
      type: QuickAction.forNextPunch(willClockIn: willClockIn).wireValue,
      title: title,
    );

    if (item == _published) return;

    _published = item;
    await _provider.setItems([item]);
  }

  /// Takes the shortcut off the launcher and drops anything waiting.
  ///
  /// Called on sign-out. The pending value goes with it: a tap made a moment
  /// before somebody signed out belongs to them, not to whoever signs in next.
  Future<void> withdraw() async {
    _published = null;
    pending.value = null;
    await _provider.clearItems();
  }

  void dispose() {
    pending.dispose();
  }
}
