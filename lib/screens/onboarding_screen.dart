import 'package:flutter/material.dart';

import '../core/l10n.dart';
import '../core/theme.dart';
import '../main.dart';

/// What the app is for, once, before the first sign-in (B1.1).
///
/// Four cards, and each one earns its place by answering a question somebody
/// actually asks on their first day: *is the time it records mine or theirs*,
/// *what happens on a site with no signal*, *where do I book a day off*, and
/// *will it tell me anything*. A carousel of stock illustrations saying
/// "Welcome!" would be worse than none, because it would train people to skip
/// it before the one useful card.
///
/// It appears **before the login screen and only on a handset that has not seen
/// it** — an employee being handed a phone, not somebody signing back in after
/// a shift.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pages = PageController();
  int _index = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// Both the skip and the finish come here. Skipping is a decision about this
  /// app, not a request to be asked again next launch.
  Future<void> _done() async {
    // Read before the await: this pops the screen out from under itself.
    final session = SessionScope.read(context);

    await session.completeOnboarding();
  }

  void _next() {
    if (_index >= _cardCount - 1) {
      _done();
      return;
    }

    _pages.nextPage(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.t;
    final cards = _cardsFor(t);
    final last = _index == cards.length - 1;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _done,
                child: Text(t.onboardSkip),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pages,
                itemCount: cards.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) => _Card(card: cards[i]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Hand-rolled rather than a package: four dots is not a
                  // dependency, and the ones that do this bring a page
                  // controller of their own to disagree with.
                  Semantics(
                    label: t.onboardPageOf(_index + 1, cards.length),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < cards.length; i++)
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            width: i == _index ? 22 : 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: i == _index
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.outlineVariant,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _next,
                    child: Text(last ? t.onboardStart : t.onboardNext),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One card's worth of copy.
@immutable
class _OnboardingCard {
  const _OnboardingCard({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;
}

/// How many cards there are, without the strings.
///
/// `_next` runs from a button handler and only needs to know whether this is
/// the last one; reaching for a `BuildContext` there to count a list whose
/// length never changes would be work for nothing.
const _cardCount = 4;

List<_OnboardingCard> _cardsFor(AppLocalizations t) => <_OnboardingCard>[
      _OnboardingCard(
        icon: Icons.touch_app_outlined,
        title: t.onboardClockTitle,
        // The first thing anybody wants to know about an attendance app, and
        // the answer is reassuring: the phone's clock has no say in it.
        body: t.onboardClockBody,
      ),
      _OnboardingCard(
        icon: Icons.cloud_off_outlined,
        title: t.onboardOfflineTitle,
        body: t.onboardOfflineBody,
      ),
      _OnboardingCard(
        icon: Icons.event_available_outlined,
        title: t.onboardLeaveTitle,
        body: t.onboardLeaveBody,
      ),
      _OnboardingCard(
        icon: Icons.notifications_none,
        title: t.onboardNotifyTitle,
        body: t.onboardNotifyBody,
      ),
    ];

class _Card extends StatelessWidget {
  const _Card({required this.card});

  final _OnboardingCard card;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Scrollable, and nothing given a fixed height: at the OS's larger font
    // sizes this copy is taller than a phone screen, and a carousel that clips
    // its own explanation would be a poor advertisement for the rest (B6.4).
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          Icon(card.icon, size: 72, color: AppTheme.brandOf(context)),
          const SizedBox(height: 32),
          Text(
            card.title,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            card.body,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
