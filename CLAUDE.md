# KEMP — Klutch Employment Management Program (mobile app)

*Known internally as the Employment Management Portal (EMP) until the rebrand.
`emp` still appears in identifiers on the server side; it is not the product
name.*

Working notes for the **Flutter client**. The Laravel API and the web dashboard
live in their own repository, `hr-backend`; this app talks to it over `/api/v1`
and owns none of that. See **The boundary between this repo and the other one**,
below, before changing anything that crosses it.

This file records the things that are **not** obvious from reading the code, and
the traps that have already cost time.

**The trap numbers below are not contiguous, and that is deliberate.** They were
numbered while both halves lived in one repository; the Laravel ones stayed in
`hr-backend` keeping their numbers, because about ten traps refer to each other
by number in prose and renumbering would have broken those references silently.
A gap means a trap that belongs to the server.

---

## Running it

```bash
flutter pub get
flutter analyze
flutter test -j 1            # 375 tests
```

The app's strings are generated from `lib/l10n/*.arb` on `flutter pub get` and
on every build, into a git-ignored `lib/l10n/generated/`. Nothing extra to run
after a clone; `flutter gen-l10n` regenerates them by hand.

### Pointing it at a server

The app needs a running API. Either the deployed one —
`https://hrams.devonlinetestserver.com` — or a local checkout of `hr-backend`
(`php artisan serve`, and **MySQL started from the XAMPP Control Panel**;
launching `mysqld.exe` as a background task does not persist, it exits).

**The deployed one is the default** — a plain `flutter run` or `flutter build`
talks to live data. To work against a local backend instead, pass
`--dart-define=API_BASE=http://10.0.2.2:8000/api/v1` (`lib/core/api_client.dart`).

A handset or emulator cannot reach `127.0.0.1` on the host machine. Use the
machine's LAN address, or `10.0.2.2` on the Android emulator.

### Signing in

`hr-backend` seeds a demo company with seven accounts, all on the password
`password`. What each one gets **on a handset**:

| Email | Roles | On the phone |
|---|---|---|
| `james.smith@acme.test` | employee + manager | Everything, **including the Team tab** |
| `emily.johnson@acme.test` | employee | The five employee tabs |
| `michael.brown@acme.test` | employee | The five employee tabs |
| `jessica.davis@acme.test` | employee | The five employee tabs |
| `david.wilson@acme.test` | employee | The five employee tabs |
| `hr@emp.test` | hr | The five employee tabs **plus the HR tab**, no Team tab |
| `admin@emp.test` | admin | Signs in, then the no-employee-record state |

**The five demo employees differ in what they have *done*** — leave taken,
punches made — not only in the role they hold, so which one you sign in as is a
real choice.

**`admin@emp.test` deliberately has no employee record**, and must not be given
one. An administrator operates the system rather than working for the company.
The refusal it produces is a designed, tested screen with no retry button, and
it is the empty state four screens are built around.

**HR holds `approve-leave` and leads nobody.** That pair is why the Team tab
asks for the permission *and* a direct report — see the boundary section, rule 4.

---

## Traps that have already bitten

These are not hypothetical. Each one shipped, and each was invisible until
something specific broke.

### 8. Real file I/O inside `testWidgets` hangs, it does not fail

`testWidgets` runs in a fake-async zone. It advances timers when you `pump`, and
it **never delivers a real file completion at all** — so a widget whose build or
`initState` reaches `OfflineCache`, `PunchQueue` or any other `dart:io` call
sits there for ever. No assertion fires, no timeout fires, the whole
`flutter test` run just stops with the test name on screen and nothing after it.
That looks exactly like an infinite `pumpAndSettle`, which is what you will
waste the time looking for.

Prime the stores first, inside `tester.runAsync`, and pump a screen that only
reads memory:

```dart
await tester.runAsync(() async {
  final store = OfflineCache(directory: dir);
  await store.write(OfflineCache.keyProfile, {'user': ...});  // loads the file
  final queue = PunchQueue(directory: dir);
  await queue.load();
  session = Session(api: ..., cache: store, queue: queue);
  await session.restore();
});

await tester.pumpWidget(app(session));   // memory only from here
```

Both stores read their file once and hold it, so this is also what a real
handset does after the first launch.

Where a screen has to load *through* the cache rather than be handed a primed
one, `test/support/settle.dart` is the only way to let it finish: `runAsync`
gives the disk real time and `pump` drains the continuations that finish because
of it, alternating, because a load is a chain of them. Those rounds are real
wall-clock time, so **the budget is a bet on how busy the machine is** — and
`flutter test` runs the files concurrently. Three files each carried their own
copy of the loop at six rounds, which was comfortable alone and intermittently
short with sixteen files running; the failure reads as a screen that ignored its
own response, not as a test that did not wait. One copy, twelve rounds.

### 9. The biometric lock can lock its own owner out

`AppLock.enable()` runs the check **before** it writes the preference, and that
order is the whole feature. A switch that saves first and asks afterwards puts
the app behind a sensor that has just refused somebody, on a phone they cannot
sign out of either — the way back is a reinstall, which also discards every
punch still queued for a signal.

Three more rules go with it, and each is there because the phone is not a
reliable partner:

- **The lock screen always offers *Sign out instead*.** Fingerprints get
  removed, face data gets reset, a sensor breaks. `BiometricOutcome.unavailable`
  is the one outcome that must never be retried into a dead end.
- **The switch is drawn only where `isAvailable()` is true**, which means a
  biometric actually *enrolled* — not merely "the device supports
  authentication". With a PIN and no fingerprint, `authenticate()` still
  succeeds by prompting for that PIN, so the row would offer fingerprint unlock
  on a phone that has none and then ask for something else.
- **`backgroundGrace` must stay well above zero.** The OS backgrounds the app
  for its own dialogs — the location prompt at the first punch, a document
  opening elsewhere, *and the biometric sheet itself*. Locking on every resume
  puts the lock behind the sheet it just opened. `_prompting` guards the sheet;
  the minute covers the rest.

The preference lives in the keystore beside the token and is cleared with it:
it says "this phone is shared", which is a statement about the person who set
it, not about the handset.

**Android needs three native changes, and two of them fail only at runtime.**
`MainActivity` extends `FlutterFragmentActivity` — androidx.biometric's prompt
is a Fragment and there is no FragmentManager under a plain `FlutterActivity`,
so the first press of Unlock throws. `LaunchTheme` and `NormalTheme` descend
from `Theme.AppCompat` for the same reason, and without it the prompt crashes on
Android 8 and below only. `USE_BIOMETRIC` is declared; there is deliberately no
`<uses-feature>`, which would hide the app in the Play Store from every device
without a sensor. On iOS, `NSFaceIDUsageDescription` is the same trap as the
location key — iOS kills the app rather than refusing, and only on a Face ID
handset.

**A Kotlin plugin builds noisily from a different drive.** With the pub cache on
`C:` and the project on `F:`, `local_auth_android`'s incremental compile logs a
stack of `IllegalArgumentException: this and base files have different roots`.
The build succeeds — `flutter build apk` finishes and the APK is written. It is
the first plugin in this app with Kotlin sources, so this noise is new, and it
is not a failure.

### 10. The app gate is the one switch that can stop everybody

`GET /app/status` decides whether a build may carry on (B6.6), and it is driven
by two values typed into an env file. Get either wrong and every handset in the
company stops at a screen — and the people it stops are the ones who clock in
with it. Nothing on the server side goes wrong when that happens, so there is
no alarm to notice.

Everything about it is therefore built to **fail open**, at every level:

- `AppVersion::compare()` returns **null**, not `-1`, for anything it cannot
  read. A caller treating that as "older" would refuse a whole fleet over a
  typo. `isOlderThan()` is the only thing that turns it into a bool, and it
  answers false whenever it does not know.
- The endpoint does **not** validate its query. A 422 is the one shape the app
  cannot act on — it asks this before it knows anything, so a refusal leaves it
  with no verdict at all. Junk in either parameter falls through to `ok`.
- A minimum version with no store link for that platform answers `ok`. An
  update screen with a dead button cannot be dismissed *or* acted on.
- `AppGate` in the app treats an unreachable server, an unparseable body and an
  action invented after the build shipped as `ok`. **This one matters most**:
  the app is deliberately usable with no signal, and a gate that blocked on a
  failed request would take the offline cache and the punch queue away in
  exactly the conditions they exist for.

**The comparison lives on the server, not in the app.** The app is the half
that cannot be fixed — a handset with a broken comparator has already shipped,
and the answer it is given is the only thing left that can change what it does.

**Maintenance is a flag of its own, not `php artisan down`.** `down` returns
503 to everything, which the app cannot tell apart from an outage: it would
fall back to its cache and let somebody queue punches into a server being
migrated underneath them. Both settings live in `config/mobile.php` rather than
in the database, because the moment they matter most is the moment the database
is unavailable. `emp:preflight` fails a deploy that leaves maintenance on.

### 11. The store declarations drift silently, and only Apple notices

Four documents describe what the app collects and a reviewer compares them: the
data-safety table in `Store-Submission_Checklist.md`, `/privacy` on the server,
`mobile/ios/Runner/PrivacyInfo.xcprivacy`, and the forms on both consoles.

**Two of them said the app does not collect location for some time after B2.3
shipped** — the checklist row read "not collected" and the Apple manifest had no
location entry at all, both with comments promising to be updated "when B2.3
ships". Nothing failed. An app that collects location without declaring it is
the most common cause of an enforcement removal, and the removal arrives after
review, not at upload.

Re-read all four against the code before any submission. The same trap is now
armed for push: an FCM token is a device identifier, and the day
`google-services.json` lands in a build, the data forms change with it.

### 12. A guard claimed after an `await` is not a guard

`PunchQueue.flush()` shipped with this, and `CrashReporter.flush()` was written
with it before it was caught:

```dart
await load();
if (_pending.isEmpty || _flushing) return;   // wrong
_flushing = true;
```

`await load()` yields to the microtask queue **even when `load()` has nothing to
read and returns immediately** — an `async` function's caller always suspends.
So two callers arriving together both get past the check, both set the flag, and
both send the same batch. The pair that does it in practice is a resume and a
manual retry landing in the same turn, which is exactly the case the guard was
written for.

Nothing looked broken: the server recognises the second delivery of a punch as
duplicates, so no attendance was written twice. The cost was on the app side —
a `SyncOutcome` reporting punches as *duplicate* that had in fact just been
accepted by its own first call.

**Claim the flag before the first `await`, and release it in a `finally`.**

### 13. Crash reports go to this server, and nowhere else

B6.5 is a table on the employer's own server, not Crashlytics, not Sentry. That
is a decision, not an oversight: a stack trace routinely carries fragments of
whatever the app was holding, and four documents — `/privacy`, the Apple
privacy manifest, and both store data forms — say the app shares nothing with
any third party. Since push was switched on (2026-09-28, Firebase project
`kemp-805c6`) it contacts **two** hosts: the employer's server, and Google's FCM,
which holds only the push token, as a service provider. That is the one
exception and all four documents now say so. A crash SDK would falsify all four
at once. If one is ever added, they all change with it, and so does the answer
to the tracking question.

The rest of the design follows from what a crash reporter has to survive:

- **Written to disk at the moment of the crash, delivered on the next launch.**
  A reporter that posts from inside a dying process loses the crash that killed
  it, which is the only kind worth having.
- **`POST /app/crashes` is unauthenticated.** The crash worth having most is the
  one that stops the app opening; an endpoint behind `auth:sanctum` would
  collect every crash except that one. The controller reads a token if one is
  present, so a report from a signed-in handset is attributed anyway. Being a
  public write, it has its own tight limiter and a hard cap on every field.
- **Nothing in `CrashReporter` may throw.** An error handler that fails turns
  one crash into a loop, so every path swallows its own failures.
- A report the server *refuses* is dropped rather than kept — holding it would
  retry one rejection at every launch for ever. A report that never *arrived* is
  kept. `ApiException.isNetworkFailure` is the difference, the same distinction
  the offline cache turns on.

### 14. A status colour cannot be one value

`AppTheme.present` and its four siblings used to be `static const Color`, chosen
against a white card and then drawn unchanged on a #161C22 one. Three of the
five came out between 2.8:1 and 3.4:1 in dark mode — under AA for the 11–13px
text they are almost always used for, and under *everything* on the raised
surfaces.

There is no fixing that by picking a better value. Body text on white needs a
relative luminance at or below about 0.17; body text on #1E262E needs one at or
above about 0.26. Nothing is both. So the colours live on **`AppColors`**, which
resolves by brightness:

```dart
final colors = AppColors.of(context);   // in build(), or before the first await
```

Every value clears **4.5:1 on the worst surface it meets, including its own
10–15% tint** — the house pattern for a banner or a chip puts the colour on a
wash of itself, which is the tightest pairing in the app and the one most easily
got wrong. `test/accessibility_test.dart` measures all of that; it does not
consult this comment.

**`AppTheme.brand` is identity, not text.** #F26522 is 3.15:1 on white: enough
for the 21px Check-in label (large text, 3:1), the splash mark and the focus
ring, and nowhere near enough for a caption or a 16px button label. It was
`primary` with white on it, which failed on every ordinary button in the app;
`primary` is `brandDeep` now in light mode and near-black-on-orange in dark.
Putting the bright orange back on `primary` fails a test.

### 15. Fixed heights clip at the OS's larger font sizes

Nothing in the app clamps `textScaler`, which is right — an employee who has
turned the system font up has done so deliberately. The cost is that a
`SizedBox(height: …)` wrapped round text is a clipping bug waiting for the first
person who uses that setting, and it had claimed the punch button, the break
button and two rows on the clock screen.

Use `ConstrainedBox(minHeight:)` and a matching `minimumSize` on the button
style — the theme's own `Size.fromHeight` will otherwise pull it back down — and
give a `Row` carrying text an `Expanded`, or make it a `Wrap`.

`test/accessibility_test.dart` pumps five screens at 2× in both themes. Flutter
raises an overflow as a rendering exception, which `testWidgets` fails on, so
that is a real check and not a screenshot somebody has to look at.

### 16. One list per side for the notification route

`route` decides which tab a notification opens, and it used to be written out
by hand in every `toPush()` on the server and listed again in `PushRoute` on
the app. The two drifted: `schedule` was sent for months to a build whose enum
had never heard of it, and because an unknown route opens the app normally
rather than crashing, nothing ever said so.

There is now one list on each side. On the server, **`App\Support\AppRoute`**
maps a notification's `type` to its route, and both the push payload and the
notification history (B5.6) read it. In the app, `PushRoute.parse` handles
both a pushed route and a listed one, so `AppNotification` cannot invent a
second answer.

It is keyed on `type` rather than on anything only a push carries, because
`toDatabase()` has never recorded a route — so every row already in the
`notifications` table has to get its answer from the type alone.

**Null is an ordinary answer.** `document_expiring` and `late_arrivals` are
addressed to HR, who work at a desk; the app has no screen for either, and a
notification with nowhere to go simply offers no button.

### 17. Not everything in the keystore belongs to the account

Four things on the handset are cleared when the token is: the punch queue, the
offline cache, the biometric preference and the unread badge. Each belongs to
the person who was signed in, and the next one on a shared phone must not
inherit it.

**The onboarding flag is the exception** (B1.1). It describes the *handset* —
whether this phone has ever been introduced to the app — and signing out at the
end of a shift is not a request to be walked through the carousel again in the
morning. `Session._clearToken` deliberately does not touch
`hrms_onboarding_seen`, and there is a test that says so.

**The language is the second exception, and for the same shape of reason**
(B6.2). `hrms_locale` describes the handset, and clearing it at sign-out would
put the *login form* back into a language the person standing there cannot read
— on the one screen they cannot get past in order to change it. `_clearToken`
deliberately does not touch it either, and `test/locale_test.dart` says so.

Two more rules go with it. `needsOnboarding` is read **once, inside
`restore()`**, because `_Root` builds synchronously and an answer arriving a
frame later has already flashed the login form at the person it was meant to
introduce. And it is never true for a session that restored: somebody signed in
on this handset has used it before, whatever the keystore says.


### 18. A translated label cannot also be an identifier

The app is drawn in English or Spanish (B6.2), and two things in it were
matching on **the word under an icon** rather than on a key.

`HomeShell` keyed its per-tab visibility map on the tab's label, and `PushRoute`
carried a `tabLabel` that a tapped notification was matched against. Translate
the labels and both stop finding anything — a notification tap would have opened
the app on whatever tab it happened to be on, on every Spanish handset, and
nothing would have thrown. `_Tab` has an `id` now, `PushRoute` has `tabId`, and
one function — `tabLabel(t, id)` in `home_shell.dart` — turns an id into the
word, so the shell and the notification row cannot disagree about what a tab is
called.

The rule generalises: **anything that has to *find* something matches on a key,
and only the last step turns a key into words.** The same shape applies to
`AppColors.statusStyle` and `punchTypeLabel`, both of which take a server key
and hand back a translated label.

### 19. `context.t` in `initState` is an assertion, not a warning

`AppLocalizations.of` is `dependOnInheritedWidgetOfExactType`, and Flutter
refuses that before the element has finished its first build. Every data screen
here calls `_load()` from `initState`, so a `final t = context.t;` at the top of
`_load` — the obvious place, because the `catch` is what needs it — takes the
screen down with *"dependOnInheritedWidgetOfExactType() was called before
initState() completed"*.

Nothing fails at compile time and `flutter analyze` says nothing. It shows up as
a widget test that finds none of the text it was looking for.

**Read the strings inside the `catch`, after the `mounted` check.** That is
already the house pattern for a `BuildContext` on the far side of an `await`,
and the strings are only ever needed there:

```dart
} on ApiException catch (e) {
  if (!mounted) return;
  final t = context.t;          // here, never above the `try`
```

A handler invoked by a button is fine — the constraint is `initState` alone.

### 20. Spanish does not build a date the way English does

"4 August 2026" is "4 **de** agosto **de** 2026". A date assembled in Dart as
`'$day $month $year'` cannot express that, so `dateShort` and `dateLong` are
**messages with placeholders** and the ordering belongs to whoever writes the
translation. The same goes for anything that reads as a sentence:
`Regularisation.summary` is four separate messages rather than "disputing a "
plus a punch name, because lower-casing an assembled English sentence is not a
translation strategy.

**The month names live in the ARB files, not in `intl`'s `DateFormat`.** That is
deliberate. `DateFormat('d MMM', 'es')` needs `initializeDateFormatting` to have
been called first and throws `LocaleDataException` when it has not — at the
moment a date is drawn, which is every screen in the app. A launch-time step
that a future translation change could quietly come to depend on is a worse
trade than twenty-four extra rows.

### 29. The 2x accessibility pass only covers the screens pointed at it

`test/accessibility_test.dart` pumps screens at `TextScaler.linear(2.0)` in both
themes, and an overflow is a rendering exception, so it fails rather than
producing a screenshot nobody looks at. That only works for screens that are in
the file — and a screen needing an API was not, which is why B3.5's score card
shipped its first draft with a `Row` that overflowed by 180 pixels at the
largest text size.

A screen that loads from the server is pumped by **seeding the offline cache
and letting the mock client throw** — `offlineSession(tester, history: {...})` —
the same trick the clock screen already used. There is no reason left for a
screen to be missing from that file.

A `Wrap` is not enough on its own: it wraps its own children, not the contents
of a `Row` inside one. Text beside an icon needs `Flexible`.

### 30. The end of a window is only today when nobody asked for less

The app never names a date the server has not named first: it asks for the
default window, reads `to` out of the reply, and counts from that. Everything
dated on the History and Roster screens is built that way, because the phone is
wherever its owner is and attendance is judged in the company's zone.

`to` is the window's end. It is today **only because nothing earlier was
asked for**. The month grid (B3.4) is the first caller to send both ends, and
paging back to March gets `to: 2025-03-31` — a true statement about that
window, and not a statement about today. Anchoring on it moved the app's idea of
today to the end of whichever month was being read: the forward arrow went dead
one month back, and switching to the list then asked for thirty days ending
three weeks before today. Both screens looked internally consistent. Nothing
errored.

**So the anchor is taken only from a reply to a request that named no `to`.**
Widening the rule — "read the echo, it comes from the server" — is what broke
it; the echo is only today's date when the request left `to` alone. A reply to a
bounded window can be drawn, but it cannot be used to tell the time.

The same applies to `from`: it may never be later than the anchor, because a
window starting after today comes back empty and reads as a month nobody
attended. `test/history_calendar_test.dart` runs its mock server in **April
2025**, nowhere near the machine, so a date built from the handset fails on the
first expectation instead of passing for eleven months of the year.

**A screen that *offers* a date is covered by this rule too, and two were not.**
`showDateRangePicker` and `showDatePicker` take `currentDate` — the day they
draw a ring around — and Material defaults it to `DateTime.now()`. Caught on the
handset: the phone was on 15 September, the company (America/New_York) on the
14th, and the Clock, History and Schedule tabs all said the 14th while the leave
picker ringed the 15th. Somebody booking "from today" books the wrong day, and
the app visibly disagrees with itself.

On the corrections form it was worse than cosmetic: `lastDate` is a **rule** —
the server refuses a correction to a time that has not happened — so the picker
offered a date the app itself would then be refused for. `/leave/balances` and
`/attendance/regularisations` now carry `today` in the company's zone, and both
pickers take `currentDate`, `firstDate` and `lastDate` from it. `date('Y')` went
with them: PHP's `date()` reads the machine clock and ignores
`Carbon::setTestNow` entirely, so that line could not be made to fail in a test
no matter what timezone the company was in — an unfreezable clock is its own
reason not to ask one the time.

### 31. `flutter build apk` can ship a Dart kernel that is weeks old

Two consecutive `flutter build apk --debug` runs produced a **byte-identical**
APK that did not contain the source in front of them. The build reported
success in nine seconds, `adb install` reported success, the app launched, and
the feature simply was not there — which reads as the feature being broken, not
the build being stale. Deleting `.dart_tool/flutter_build` did **not** clear it.
Only `flutter clean` did.

So when a change does not appear on the device, **check the artifact before
debugging the code**:

```bash
unzip -p build/app/outputs/flutter-apk/app-debug.apk \
  assets/flutter_assets/kernel_blob.bin | grep -ac "some new string"
```

Zero means the APK is stale; `flutter clean` and rebuild. It costs about a
minute, and it is cheaper than the hour spent looking for a bug in code that was
never running. `uiautomator dump` is the other half of the same check — Flutter
paints to a canvas, so a screenshot cannot be grepped, but every `tooltip` and
`Semantics(label:)` lands in the accessibility tree and can be:

```bash
adb shell uiautomator dump /data/local/tmp/ui.xml
adb shell cat /data/local/tmp/ui.xml | tr '<' '\n<' | grep -oE 'content-desc="[^"]+"'
```

### 32. A Flutter package can add permissions you never asked for

`flutter pub add file_picker` (B4.1) put four permissions into the merged
manifest: `READ_EXTERNAL_STORAGE` and all three `READ_MEDIA_*`. The package
declares them for the modes that browse media; this app uses
`FileType.custom`, which is `ACTION_OPEN_DOCUMENT` — the system picker, which
grants access to the one file the user chose and **needs no permission at all**.

Nothing fails at runtime, which is why this is only ever found at review.
`READ_MEDIA_IMAGES` and `READ_MEDIA_VIDEO` put an app on Google Play's Photo and
Video Permissions policy path, wanting a declaration and a justification for
access the app never exercises — on top of asking every user for more than the
feature needs.

They are removed explicitly, with `tools:node="remove"` in
`android/app/src/main/AndroidManifest.xml`, so a future reader sees a decision
rather than an absence. **After adding any plugin, read what it merged in:**

```bash
flutter build apk --debug
grep -oE 'android:name="android\.permission\.[A-Z_]+"' \
  build/app/intermediates/merged_manifest/debug/processDebugMainManifest/AndroidManifest.xml | sort -u
```

The list should be the eight in the main manifest plus `CAMERA` (A4.21), and
nothing else.

### 33. `useSafeArea: true` does not cover the bottom of a bottom sheet

`showModalBottomSheet(useSafeArea: true)` wraps the sheet in
`SafeArea(bottom: false)` — deliberately, because a sheet usually has a keyboard
under it and the caller is expected to handle the bottom with `viewInsets`.
Every sheet in this app did exactly that and no more, so with the keyboard
**down** the end of the sheet was drawn underneath the navigation bar.

The end of a sheet is where the submit button lives. On the handset the **Save**
on *Home & emergency contact* was half-covered by 48dp of opaque black and the
sheet had nothing left to scroll: the only way to press it was to aim at the top
half of a button you could not fully see. The leave sheet lost the last line of
its footnote the same way.

`lib/widgets/sheet_padding.dart` is now the one expression, and the term that
matters is `padding.bottom` rather than `viewPadding.bottom`: `padding` is
already the system inset **minus** whatever `viewInsets` covers, so it is the
navigation bar when the keyboard is down and zero when the keyboard is up over
it. Adding it to `viewInsets.bottom` is correct in both states and
double-counts in neither.

### 34. A retry button is a claim that retrying can work, and an icon is a claim about why

HR and administrator accounts are not employees — `emp:install` creates an
administrator with no employee row, and HR's work is on the web. Signing one
into the app is ordinary, and every employee-facing endpoint refuses it.

All seven screens rendered that as the ordinary error card, each offering **Try
again** for a condition that will still be true on the hundredth press. The
Profile tab already said the true thing and pointed at the web dashboard; the
rest implied the server was having a moment.

**The refusal needed a name of its own before the app could act on it.** It was
a bare `abort(403)`, which the handler renders as `forbidden` — and so does an
employee reaching for somebody else's leave request, and so does one
withdrawing somebody else's correction. Three unrelated conditions under one
name is fine for a log and wrong for a client, because the app treats this one
as permanent and those two as ordinary. Matching on `forbidden` meant a
mistyped id would have been relabelled "this account has no employee record" —
untrue — and stripped of the retry that would have cleared it. So
`App\Exceptions\NoEmployeeRecord`, an arm in `bootstrap/app.php` ahead of the
generic status-to-code mapping, and `no_employee_record` on the wire.

**Then the words were right and the picture was not.** `AsyncView` drew
`Icons.cloud_off` on every failure, so an administrator was told the network was
down, seven times, immediately above a sentence saying it was not — and the
picture is what gets read first, which is how somebody ends up checking their
wifi over an account setting. It now takes `permanent`, which owns **both** the
icon and the retry suppression: one flag, because the two always agreed and
were stated separately as `onRetry: _fatal ? null : _load` at seven call sites.
A rule restated seven times is a rule that will be got wrong in one of them.

`_fatal` is cleared at the top of every `_load`, because a screen that dropped
its retry for good after one refusal would strand a user who later has no
signal. `test/no_employee_record_test.dart` pins all four claims — the message,
the missing retry, the icon, and `forbidden` **not** being treated as this — on
all seven screens.

### 35. A launcher shortcut outlives the app that wrote it

Everything else this app writes dies with the process or lives in a store it
controls. A quick action (B2.8) does neither: `setShortcutItems` hands the OS a
`type` string, the **launcher keeps it**, and it is handed back verbatim on a
tap — days later, after a reinstall's worth of upgrades, from whichever build
last published it.

Three consequences, and none of them shows up in a test that only runs one
build:

- **The type can never be a translated label.** Publishing `t.punchCheckIn` as
  the type puts `Fichar entrada` on a Spanish launcher, and `QuickAction.parse`
  has never heard of it. `wireValue` is the identifier and `title` is the
  words — trap 18 again, in the one place where the two live in different
  processes.
- **`parse` must tolerate a string this build does not know.** A downgrade, or
  a renamed enum row, hands back a type from the future or the past. Null, and
  the app opens normally.
- **It must be withdrawn on sign-out.** It is in `_clearToken` beside the punch
  queue and the cache, for the same reason they are: on a shared work handset a
  *Check out* left on the menu by the last person is one tap from clocking out
  the next one, and unlike anything on screen it is reachable **without opening
  the app at all**.

The tap is also held rather than dropped while `/attendance/today` is in
flight. Launching *from* the shortcut is the normal case, so the tap always
arrives before there is a day to punch against; clearing it there leaves the
feature working only when the app was already open. `_load`'s `finally` asks
again once the day has settled, and the tap is spent either way at that point —
one that survived into the next refresh would punch twice for one press.

The punch itself goes through the screen's own `_punch()`, so the fence, the
fix, the cooldown and the offline queue are not reimplemented behind it.

---

### QR check-in (B2.9 / A4.21) — added 2026-09-30

- **The server decides the method.** `GET /attendance/today` carries `method`
  (`button` | `qr`); the app never reads the policy or the work mode. `qr` turns
  the Clock button into *Scan to check in / out*, which opens `QrScanScreen` and
  posts to `/attendance/qr`. `_punch()` branches to `_scanPunch()` at the top, so
  the launcher shortcut follows automatically. Breaks stay a button.
- **A scan is never queued.** A code is good for one scan and 30 seconds. The
  offline queue (B2.4) still exists for button staff; for QR staff the server
  refuses queued in/out punches with a per-punch `refused`.
- **The scanner is `flutter_zxing`, not `mobile_scanner`.** `mobile_scanner` is
  Google ML Kit on Android, which reports usage to Google — a third host, and
  trap 13 says four documents promise two. ZXing decodes on the handset. Its
  gallery button is **off**: the code proves presence, a gallery picture does not.
  It needs the NDK and CMake at build time (both in the Android SDK here).
- **Tests replace `QrScanScreen.open`** (a static function) because there is no
  camera; nothing in `lib/` assigns it. Restore it in `tearDown`.
- **`CAMERA` is now the ninth permission in the merged manifest** (trap 32).
  iOS has `NSCameraUsageDescription`. Camera frames never leave the phone, so no
  data type changed on the store forms — see the checklist §7 note, which also
  says what to do if the first iOS upload asks for a photo-library string.

## The boundary between this repo and the other one

**This section is the one thing deliberately written in both repositories.**
Everything else was split; these four rules describe the seam itself, and a rule
about a seam that lives on only one side of it is a rule the other side will
break. **Change it in both, in the same week, or it becomes the drift it exists
to prevent.**

The two halves:

| Repo | Holds | Deploys to |
|---|---|---|
| `hr-backend` | Laravel 12 API + web dashboard, `deploy/`, the API reference | `hrams.devonlinetestserver.com` |
| `hr-mobile` | The Flutter app | Play Store / App Store |

### 1. `API-Reference_v1.md` is authoritative in `hr-backend`

`tests/Feature/Api/ApiDocsTest` walks the real route table and **fails the build**
on an endpoint or an error code that is not in that file. So the backend copy
cannot drift from the API; it is checked on every run.

`hr-mobile` carries a **copy**, and the copy names the backend commit it was
taken from in its first line. Nothing enforces that stamp — it is the one place
in this arrangement where staleness is possible. When the API changes, the
backend PR updates the reference and the app PR re-copies it, quoting the new
commit. If the stamp looks old, trust the backend.

### 2. The app never names a date the server has not named first

Trap 30 in both files, and it is the mistake this codebase has made four times.
The phone is wherever its owner is; attendance is judged in the company's
timezone. The app asks for a default window, reads `from`/`to` out of the reply,
and counts from those. **A screen that builds a date from `DateTime.now()` is a
bug even when it looks right on the machine it was written on.**

### 3. The notification route lists must agree

Trap 16 in both files. `App\Support\AppRoute` on the server decides where a
notification points; `PushRoute` in the app decides what it can open. A value
the app has never heard of opens the app normally and does nothing, which is
safe and completely silent — `schedule` was being sent for months before the app
knew it. **Adding a route means a change in both repos**, and the server one
lands first because the app ignores what it cannot parse.

### 4. Capabilities are decided by the server, never derived by the app

`/auth/me` returns a `can` block — `lead_team`, `decide_leave`,
`view_employees`. The app reads the conclusion. It used to work `leadsATeam` out
from the permission list while the route table enforced something subtly
different, which is how every HR user came to have a permanently empty Team tab.
**A new area in the app is a new key in that block, not a new rule in Dart.**

---

## What the app does not own

Not a list of gaps — a list of things that are somebody else's and must not be
reimplemented here.

- **Who may see what.** The server decides and sends `can` on `/auth/me`. The
  app draws what it is told. See boundary rule 4.
- **What day it is.** The company's timezone is the server's; the phone's clock
  is not a vote. See boundary rule 2.
- **Attendance status.** `late`, `ontime`, `early_leave` are decided where the
  punch is written. The app never computes one.
- **Leave balance.** Sent with the request it applies to. The app never
  subtracts days itself.
- **Employee records.** Read-only on the phone by decision, not by omission —
  editing one-handed writes an audit trail nobody would check. Onboarding is a
  desk job on the web dashboard.

## Releasing

`Store-Submission_Checklist.md` in this repository is the pre-flight. Two of its
items are the ones that have actually bitten — see traps 11 and 31.

Push notifications stay silent until a Firebase project exists;
`Push-Notifications_Setup.md` is the runbook, and it is a configuration job
rather than a code change.

---

## Git

`git push` can hang on a hidden credential-manager dialog —
**`GIT_TERMINAL_PROMPT=0 git push`** completes instantly. `gh` is not installed,
so PRs must be opened through a browser link.

**History before the split is intact.** This repository was carved out of the
combined one with `git subtree split --prefix=mobile`, so every commit that ever
touched the app is here, with its original message and author. What is *not*
here is the Laravel side of any commit that touched both — `git log` for those
shows only the app half, which is the point.
