# HR & Attendance — mobile app

Flutter client for the Laravel API in `../hrms`. Employee-facing: clock in and
out, attendance history, leave, roster, and — for a line manager — an approval
inbox and who on the team is in today.

Every screen talks to `/api/v1`. Nothing is decided on the handset: the punch
time comes from the server, and the device clock is never trusted.

## Running it

The app needs the API reachable. From inside an Android emulator the host
machine is `10.0.2.2` — `localhost` there is the emulator itself, which serves
nothing.

```bash
# in ../hrms — must bind 0.0.0.0, or the emulator cannot reach it
php artisan serve --host=0.0.0.0 --port=8000

# here
flutter run -d emulator-5554
```

Against a real device or a deployed server, override the base URL:

```bash
flutter run --dart-define=API_BASE=https://hrams.devonlinetestserver.com/api/v1
```

## Tests

```bash
flutter analyze
flutter test                                   # models, formatting, error parsing
flutter test integration_test -d emulator-5554 # needs the API up and seeded
```

The integration tests drive the real app against a live server, signing in as
seeded accounts (`emily.johnson@acme.test`, `james.smith@acme.test` and
`admin@hrms.test`, all with the password `password`). They run in-process rather
than through `adb shell input`: `@` does not survive `input text`, and the soft
keyboard shifts the layout out from under tap coordinates.

## Languages

English and Spanish. The app follows the phone unless somebody picks a language
on the Profile screen, and that choice is kept on the handset — it survives
signing out, so the login form stays in the language the person can read.

Strings live in `lib/l10n/app_en.arb` and `lib/l10n/app_es.arb`. English is the
template; `lib/l10n/generated/` is build output and is not committed, because
`flutter pub get` and every build regenerate it from those two files.

```bash
flutter gen-l10n     # only needed to regenerate by hand
```

**A key missing from `app_es.arb` does not fail anything** — it falls back to
the English text and ships as an English sentence inside a Spanish app. That is
what `test/locale_test.dart` is for: it reads gen_l10n's own
`lib/l10n/untranslated.json` and fails when it is not empty, and separately
catches a row left as the English text pasted across.

Two things are worth knowing before adding a language:

- **`context.t` must not be read in `initState`** — it registers an inherited
  widget dependency, which Flutter refuses before the first build completes.
  Every `_load()` here reads it inside the `catch`, after the `mounted` check.
- **Nothing matches on a translated string.** A tab is found by its id, a status
  by the server's key. See the `tabLabel` function in `screens/home_shell.dart`.

The API still answers in English — a punch confirmation, a leave stage, a
validation message. The app sends `Accept-Language` on every request, so the day
the server reads it, nothing here changes (C1.15 on the feature list).

## With no signal

The app is usable offline, and says so rather than pretending.

- The session restores from the last verified `/auth/me`, so a handset that
  cannot reach the server opens signed in instead of on a login screen that
  needs the network too. Bounded to a week — see `Session.offlineIdentityGrace`.
- Profile, roster, attendance history and today's clock screen fall back to the
  last copy this handset saw, each labelled on screen with when it was taken.
- A punch that cannot be sent is kept at the moment it was tapped and delivered
  by `POST /attendance/sync` later.

Only a request that **never arrived** reaches the cache. A refusal — a 403, a
validation failure — is the server telling the truth about now, and is shown.

## The biometric lock

Off until somebody turns it on under **Profile → Unlock with biometrics**, and
the switch is drawn only on a handset with a fingerprint or a face actually
enrolled. Turning it on runs the check first: a preference saved before a
sensor has agreed to say yes locks its owner out of an app they cannot sign out
of either.

It engages before the splash lifts, and again after the app has been away for
longer than `AppLock.backgroundGrace` — a minute, which is long enough that the
OS's own dialogs, the biometric sheet included, do not lock the app behind
themselves. The lock screen always offers **Sign out instead**, because a phone
that has forgotten its fingerprints must not be the only way in.

The device passcode is allowed as a fallback — it already protects the keystore
the token lives in. The preference is per handset, never sent anywhere, and
cleared with the token on sign-out.

## The app gate

`GET /app/status` is asked at launch and again after the app has been in the
background for `AppGate.recheckAfter`. It can answer three things: carry on,
update, or a maintenance window — and only the last two stop anything.

**It fails open at every level.** An unreachable server, an answer it cannot
parse, a verdict invented after this build shipped, a version it cannot read,
a platform the server has no store link for — all of them carry on. That is the
point rather than caution: this app is meant to work with no signal, and a gate
that blocked whenever it could not reach the server would take the offline
cache and the punch queue away in exactly the conditions they were built for.

Both settings are off by default and live in the server's `config/mobile.php`.
`php artisan emp:preflight` fails a deploy that leaves maintenance on, or that
sets a minimum version with no store link to send anybody to.

## When it crashes

`CrashReporter` takes over `FlutterError.onError` and
`PlatformDispatcher.onError`, writes the exception, a truncated message and the
stack to a file **at the moment of the crash**, and delivers it on the next
launch — after the session restore, so a signed-in handset's report says whose
it was. A reporter that posts from inside a dying process loses precisely the
crash that killed it.

Reports go to `POST /app/crashes` on the employer's own server and nowhere
else. There is no Crashlytics, no Sentry and no analytics SDK, and there should
not be: a stack trace carries fragments of whatever the app was holding, and
four separate declarations promise this app shares nothing with a third party.

Nothing in the reporter throws — an error handler that fails turns one crash
into a loop — and a report the server *refuses* is dropped, while one that never
*arrived* is kept for next time.

## Accessibility

Audited against WCAG 2.1 AA, and the audit is `test/accessibility_test.dart` —
it measures, so it cannot quietly go stale.

**Colour.** Status colours are not constants; they live on `AppColors` and
resolve by brightness, because no single value carries body text on both a white
card and a #161C22 one. Read them with `AppColors.of(context)`. Every value
clears 4.5:1 on the worst surface it meets, including its own 10–15% tint, which
is what a banner or a chip puts behind it.

`AppTheme.brand` is identity, not text: 3.15:1 on white is enough for the 21px
Check-in label, the splash mark and a focus ring, and not for anything smaller.
`primary` is the deeper orange for that reason.

**Font scaling.** Nothing clamps the OS text size. That means a fixed height
around text is a clipping bug — use `ConstrainedBox(minHeight:)` with a matching
`minimumSize` on the button style, and give a `Row` carrying text an `Expanded`
or make it a `Wrap`. Five screens are pumped at 2× in both themes; an overflow
is an exception, so the test catches it.

**Screen readers.** Every icon-only control carries a `tooltip`, which is what
gives it a name — without one it announces "button" and nothing else.

## Notifications

A bell on the Clock tab, with an unread count, opening the history behind the
pushes. Nothing is stored on the handset — `GET /notifications` reads the same
table the web dashboard has read since A9, so a message survives the OS banner
being swiped away and is still there on a reinstall.

Reading and going somewhere are separate here, unlike the web screen: tapping a
row marks it read, and only the few that point at a tab get an **Open** button.
`AppNotification.route` is parsed by the same `PushRoute` enum a push tap goes
through — one list, so the two cannot disagree about which tab answers `leave`.

The badge is `Session.unreadNotifications`, a `ValueNotifier`: refreshed once at
launch, replaced by the server's number when the inbox is read, nudged up by a
push arriving with the app open, and cleared with the token on sign-out.

## First run

A four-card introduction sits in front of the first sign-in on a handset, and
nowhere else. Each card answers a question somebody asks on their first day —
whose clock the recorded time comes from, what happens with no signal, where
leave lives, what it will tell them — rather than saying "Welcome!" over an
illustration.

`needsOnboarding` is read once inside `Session.restore()`, because `_Root`
builds synchronously and an answer a frame late has already flashed the login
form. It is never true for a session that restored: somebody signed in here has
used the app before.

**The flag is not cleared with the token.** Unlike the punch queue, the offline
cache, the biometric preference and the unread badge — all of which belong to
whoever was signed in — this one describes the phone. Signing out at the end of
a shift is not a request to be introduced to the app again in the morning.
Skipping settles it as firmly as finishing does.

## Not built yet

Multi-language. `../Feature-List_Web-and-App.md` Part B has the full list.
