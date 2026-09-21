# Store submission — Google Play & App Store

What the two stores require, what the repository already satisfies, and what is
left. Written against the app in `mobile/` and the Laravel server in `hrms/`.

**The server is live and that blocker is gone.** `https://hrams.devonlinetestserver.com`
serves over TLS, `/privacy` and `/account-deletion` both load logged out — which
is exactly what the two stores fetch during review — and `/api/v1/ping` answers
`{"ok":true,"service":"KEMP","version":"v1"}`.

Two consequences for everything below:

- **Every build must point at that domain**, not the one this document used to
  name: `--dart-define=API_BASE=https://hrams.devonlinetestserver.com/api/v1`.
  A release build refuses to start on a non-https base URL, so a wrong one
  fails loudly rather than shipping.
- **The demo quick-login panel is currently ON at that public URL**, with
  `admin@hrms.test` still on the seeded password. Turn it off before you hand
  the URL to a store reviewer — a reviewer who lands on a login page offering
  one-click admin will take it, and what they find is not the app you are
  submitting.

---

## Done in the repository

| Requirement | Where |
|---|---|
| Privacy policy at a public URL, no login | `GET /privacy` — `hrms/resources/views/legal/privacy.blade.php` |
| Account-deletion route, no login | `GET /account-deletion` — `hrms/resources/views/legal/deletion.blade.php` |
| Both reachable from inside the app | Profile screen → Privacy policy / Delete my account |
| Real launcher icon, all densities | `mobile/android/.../mipmap-*`, `mobile/ios/.../AppIcon.appiconset` |
| Adaptive icon (Android 8+) | `mipmap-anydpi-v26/ic_launcher.xml` + `values/colors.xml` |
| iOS icon with no alpha channel | `remove_alpha_ios: true` in `pubspec.yaml` |
| App Store icon, 1024×1024 | `mobile/store/app-store-icon-1024.png` — RGB, no alpha channel |
| Release signing separate from the debug key | `android/app/build.gradle.kts` reads `key.properties` |
| Permissions declared and used | `INTERNET`, `POST_NOTIFICATIONS`, `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` (B2.3), `USE_BIOMETRIC` (B1.3). No `<uses-feature>` for the biometric sensor, and location's implied ones are declared `required="false"` — in both cases requiring the hardware would hide the app from every device without it |
| iOS usage strings for both prompts | `NSLocationWhenInUseUsageDescription`, `NSFaceIDUsageDescription`. Missing either is a termination on a real device, not a refusal |
| Biometric data leaves nothing to declare | The check is made by the OS; the app is told yes or no and stores only a per-handset on/off flag. Neither store's data form has a row to fill in for it |
| Android 11 package visibility for links | `<queries>` https VIEW intent |
| Auth token excluded from backup and transfer | `xml/data_extraction_rules.xml`, `xml/backup_rules.xml` |
| Export-compliance answer | `ITSAppUsesNonExemptEncryption = false` in `Info.plist` |
| Apple privacy manifest — contents | `ios/Runner/PrivacyInfo.xcprivacy`. Tracking false, precise location, crash data, name, email and user id all declared; `NSPrivacyAccessedAPITypes` is empty because the app's own code uses no required-reason API and the plugins that do ship their own manifests |
| Cleartext traffic blocked in release | `ApiClient.assertSecureBaseUrl()` refuses a non-https release build |
| A way to retire a shipped build | `GET /app/status` (B6.6) — a server-side minimum version and a maintenance flag, both empty/off by default. Set `MOBILE_STORE_URL_ANDROID` / `MOBILE_STORE_URL_IOS` to the real listings once they exist, or the update screen has nowhere to send anybody and the gate declines to fire |
| English and Spanish in the app | `mobile/lib/l10n/app_en.arb` and `app_es.arb` (B6.2). Every string, including the OS's own biometric prompt and the name in the task switcher. The app follows the phone's language by default and offers a picker on the Profile screen |
| Accessibility — WCAG 2.1 AA | `mobile/test/accessibility_test.dart` (B6.4). Contrast is measured, not eyeballed: every colour clears 4.5:1 on the worst surface it meets, including its own tint. The OS font size is respected up to 2× with no clipping, and every icon-only control has a name. Both stores ask; Apple's review has rejected apps for text that vanishes at the larger accessibility sizes |
| Privacy manifest **in the built bundle** | `ios/Runner/PrivacyInfo.xcprivacy`, referenced from `project.pbxproj` as a file in the `Runner` group **and** a build file in Copy Bundle Resources. It sat in the folder unreferenced for a long time, which ships as if absent — see the note under "Fixed in this pass" |
| Play feature graphic, 1024×500 | `mobile/store/play-feature-graphic-1024x500.png`. Mandatory on every Play listing; the console will not let the release out without one |
| Play hi-res icon, 512×512 | `mobile/store/play-listing-icon-512.png` — a true downscale of the source mark. The previous file was a crop of one corner |
| GPS declared as **not required** hardware | `<uses-feature android:required="false"/>` for `android.hardware.location.gps` and `android.hardware.location` in `AndroidManifest.xml`. Without these Play hides the listing from every device with no GPS |
| Android 13+ themed icon | `<monochrome>` layer in `mipmap-anydpi-v26/ic_launcher.xml` |
| iPhone-only, declared consistently | `TARGETED_DEVICE_FAMILY = 1` in all three build configurations, and no `~ipad` orientation key in `Info.plist`. No iPad screenshots needed, and no reviewer opening the app on hardware it was never laid out for |
| App name is KEMP everywhere it shows | `android:label` in the manifest, `CFBundleDisplayName` and `CFBundleName` in `Info.plist`, and `appTitle` in **both** ARB files — the name is a brand, so Spanish carries the identical string rather than a translation. The bundle id stays `com.hrms.attendance`: it is not user-visible and cannot be changed after the first upload to either store |
| KEMP brand mark on every icon | `mobile/assets/icon/app_icon.png` (opaque square master) and `app_icon_foreground.png` (keyed mark on transparency), regenerated through `dart run flutter_launcher_icons`. Store icons and the feature graphic are cut from the same master — see "Regenerating the icons" |

---

## Fixed in this pass

Five things that were either missing or wrong, all of them invisible at build
time and none of them caught by a test:

1. **The privacy manifest was not in the iOS bundle.** It existed as a file and
   was referenced by nothing, so every build shipped without it and Apple
   auto-rejects on submission. It is now a `PBXFileReference` in the `Runner`
   group and a `PBXBuildFile` in the target's Copy Bundle Resources phase. If
   the target is ever rebuilt from scratch, re-add it and confirm with
   `unzip -l Runner.app` that the manifest is at the bundle root.
2. **`ACCESS_FINE_LOCATION` was hiding the app from GPS-less devices.** Play
   derives implied `<uses-feature>` entries from permissions and treats them as
   **required**, then filters the listing off every device that lacks the
   hardware — wifi-only tablets, Chromebooks, managed handsets. A punch works
   perfectly well with no fix at all (B2.3), so the hardware is genuinely
   optional and the manifest now says so. This is a distribution bug, not a
   runtime one: nothing fails, the app is simply not there to install.
3. **The 512×512 Play icon was a crop of one corner of the mark**, not a
   downscale. It is the largest single thing on the listing page.
4. **There was no feature graphic at all.** Play requires 1024×500 on every
   listing.
5. **No themed-icon layer.** On an Android 13+ home screen with themed icons on,
   this app kept its orange tile while every neighbour recoloured.

---

## Regenerating the icons

The brand mark is KEMP — Klutch Employment Management Program: a navy plate
(`#033C93` down to `#01174B`) carrying a white K, a gold swoosh (`#FDD810`) and
three figures. The client supplies it as a **pre-rounded plate on transparency**,
which is the wrong shape for both stores, so two masters are derived from it and
everything else is cut from those:

| Master | What it is | Why it is shaped that way |
|---|---|---|
| `mobile/assets/icon/app_icon.png` | 1024×1024, **opaque**, mark on a full-bleed navy field | Apple rejects an icon with an alpha channel outright, and a pre-rounded plate handed to a launcher renders as a rounded rect inside the OS's own rounded mask. The whole plate is fitted with a small margin and its corners land on a navy underlay sampled from the artwork, so the join is invisible; the drop shadow is excluded by clipping to the plate's own rounded rectangle |
| `mobile/assets/icon/app_icon_foreground.png` | 1024×1024, **transparent**, the mark alone | The Android adaptive foreground has to float on a flat background layer. The navy is keyed out — dark with blue dominant is background, near-white and gold are the mark — and `adaptive_icon_background` is `#052C6E`, so any navy missed at an anti-aliased edge lands on navy and is invisible by construction |

```bash
cd mobile
dart run flutter_launcher_icons     # Android mipmaps + drawables, iOS AppIcon set
```

**That command rewrites `android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml`
and silently drops the `<monochrome>` block**, because flutter_launcher_icons has
no themed-icon support. Re-add it afterwards — the file carries a warning saying
so — and confirm it survived into the bundle:

```bash
flutter build appbundle --dart-define=API_BASE=https://hrams.devonlinetestserver.com/api/v1
unzip -p build/app/outputs/bundle/release/app-release.aab \
      base/res/mipmap-anydpi-v26/ic_launcher.xml | strings | grep monochrome
```

The three store images are **not** produced by that command and have to be cut
from `app_icon.png` by hand whenever the mark changes:
`store/play-listing-icon-512.png`, `store/app-store-icon-1024.png` (both plain
downscales, RGB, no alpha) and `store/play-feature-graphic-1024x500.png` (the
keyed foreground on a navy banner beside the wordmark).

**The app's interior is still the old brand orange** (`#F26522` — the check-in
button, accents, the status palette), by decision: that palette is the one
`mobile/test/accessibility_test.dart` measures at 4.5:1 against every surface it
meets in both themes, and rethemeing to navy and gold means redoing that audit
rather than swapping a constant. The icon and the web dashboard are KEMP; the
app interior is not, yet.

---

## Left to do, and who has to do it

### 1. Reviewer sign-in account — **both stores block on this**

The app opens on a login screen and there is no self-service sign-up, by design:
accounts are provisioned by HR. A reviewer therefore cannot see past the first
screen without credentials, and "we were unable to sign in" is the most common
first-submission rejection there is.

Both consoles have a field for it and **Play's is mandatory** — the release
cannot be rolled out until it is answered:

- **App Store Connect** → App Review Information → tick *Sign-In Required*, then
  a username and password that work on the production server.
- **Play Console** → App content → **App access** → *All or some functionality
  is restricted* → add instructions plus the same credentials.

Create a real employee account on the deployed server for this, not an admin
one: an admin signs in and then 403s on every screen, because an administrator
has no employee record (see the roles table in `Feature-List_Web-and-App.md`) —
a reviewer handed admin credentials sees an app that appears broken.

Give the account some history before submitting — a few weeks of punches, a
booked leave day, a published roster — or the reviewer opens a set of correct
but entirely empty screens. Leave the account live: Apple re-reviews every
update with it.

Add to the notes: the app records a location with each punch, so the reviewer
should expect the location prompt at the first clock-in, and it is *when in use*
only; and that a punch made with no signal is queued and sent later, which is
the behaviour behind `source: mobile_offline`.

### 2. Choose the name on the listing — it is not the name on the phone

The app installs as **KEMP**, which is right for the home screen: four characters,
no truncation, and it matches the icon. The **store listing** name is a separate
field and should not be just "KEMP" — both stores allow 30 characters, both rank
on that field, and a bare four-letter acronym is close to unfindable for anybody
who was not already told what to search for.

Use the full name, or the name plus what it does:

- `KEMP – Klutch Employment Management` (35 — trim to fit)
- `KEMP – Employee Attendance & Leave` (34 — trim to fit)
- `KEMP: Clock In & Leave` (22)

Neither store requires the listing name to match the launcher name, and the
launcher name should stay short regardless of what the listing says.

### 3. Decide the distribution channel before building the listing

This is a single-employer app: accounts are provisioned by one company's HR,
there is no sign-up, and multi-company tenancy (A2.10) is not built. That shape
has a supported route on both stores that is **not** the public listing, and it
is worth choosing deliberately rather than by default:

| | Public listing | Private / custom distribution |
|---|---|---|
| Apple | Normal App Store review. Passes on a demo account, but Apple may direct an employee-only app to Custom Apps instead | **Apple Business Manager custom app** — private link, no public page, no screenshots or marketing copy, lighter review |
| Google | Normal Play listing, feature graphic and screenshots required | **Managed Google Play private app** — published to the organisation only |

Public distribution is not wrong and this checklist assumes it, but the private
route removes the screenshot and marketing work in section 4 entirely and avoids
the "why is this on the public store" conversation with an Apple reviewer. If the
client wants it public, keep it public — just make the choice on purpose.

### 4. Create the release keystore — one-off, never committed

```bash
keytool -genkey -v -keystore ~/hrms-release.jks -keyalg RSA \
        -keysize 2048 -validity 10000 -alias hrms
```

Then `mobile/android/key.properties`:

```properties
storePassword=…
keyPassword=…
keyAlias=hrms
storeFile=/absolute/path/to/hrms-release.jks
```

`key.properties` and the `.jks` must stay out of git — anyone holding them can
sign an update Play will accept as genuine. Losing them means the app can never
be updated under the same listing.

### 5. Build against the real server

The default API base is the emulator's view of a development machine. A release
build must override it, and will refuse to start if it does not:

```bash
flutter build appbundle --dart-define=API_BASE=https://hrams.devonlinetestserver.com/api/v1
flutter build ipa       --dart-define=API_BASE=https://hrams.devonlinetestserver.com/api/v1
```

Play takes the `.aab`, not an APK.

### 6. Screenshots — needs the deployed server

Play: at least 2 phone screenshots. The 1024×500 feature graphic is already
drawn — `mobile/store/play-feature-graphic-1024x500.png` — and needs no server.

App Store: a 6.7" iPhone set is required, 6.5" and 5.5" are useful. **No iPad
set is needed** — see below.

**This is an iPhone-only app, by decision.** `TARGETED_DEVICE_FAMILY` is `1` in
all three build configurations, and `Info.plist` carries no
`UISupportedInterfaceOrientations~ipad` key to match. The Flutter template ships
`1,2`, which claims iPad support and then obliges a 13" iPad screenshot set and
a reviewer opening the app on one; stretched iPhone layouts are a documented
rejection under guideline 4.5, and nobody has run this app on an iPad. Staff
clock in on the handset in their pocket.

Reverting is two lines if an iPad build is ever wanted: set the three
`TARGETED_DEVICE_FAMILY` values back to `"1,2"` and restore the `~ipad`
orientation key. The iPad icons (76×76, 83.5×83.5) are still in the asset
catalogue, so nothing has to be regenerated — but do not do it without opening
the app on an iPad first.

The seeded demo company produces presentable screens. Take them after the server
is up, since the app cannot reach data before then.

**Both consoles list a language per set, and both let a listing declare more
than one.** The app ships English and Spanish (B6.2), so the listing should say
so — Play under *Store listing → Manage translations*, App Store under
*Localizations* — and each language wants its own screenshots. A store page in
one language for an app that opens in another is not a rejection, but it is the
reason somebody uninstalls before the first sign-in.

Switching the app for a Spanish set is a phone setting, not a build: change the
handset's language, or pick Spanish on the Profile screen.

### 7. Fill in the data-safety and privacy forms

Both must agree with `/privacy` and with `PrivacyInfo.xcprivacy` — a reviewer
compares them, and a mismatch is a rejection.

| Data | Collected | Shared | Purpose | Linked to identity |
|---|---|---|---|---|
| Name | Yes | No | App functionality | Yes |
| Email address | Yes | No | App functionality, account management | Yes |
| Employee ID, department, job title | Yes | No | App functionality | Yes |
| Attendance times, worked hours, leave | Yes | No | App functionality | Yes |
| IP address | Yes | No | Security / fraud prevention | Yes |
| Precise location | Yes — see below | No | App functionality | Yes |
| Crash logs / diagnostics | Yes — B6.5 | No | App functionality | Yes |
| Advertising ID / analytics | No | No | — | — |

Answer **no** to tracking on both forms: there is no advertising SDK, no
analytics, and the only host the app contacts is the employer's own server.

> **Crash logs (B6.5) are collected, and that answer stays "no third party".**
> Crashes are written on the handset and posted to the employer's own server,
> where an administrator reads them. There is no Crashlytics and no Sentry, and
> **there should not be**: a stack trace routinely carries fragments of whatever
> the app was holding, and sending those to a third party would falsify the "not
> shared" column above, the `/privacy` page and `NSPrivacyTracking` in one go.
> If a crash service is ever added, all four declarations change with it.

Say data is encrypted in transit (yes), and that users can request deletion
(yes, via `/account-deletion`).

> **Location — declare it, and declare it as precise.** B2.3 shipped: the app
> reads a fix through `geolocator` at the moment of a punch and sends it with
> the punch. It asks for `ACCESS_FINE_LOCATION` and
> `NSLocationWhenInUseUsageDescription`, and the declaration describes what is
> *asked for* rather than what the user then grants — so this is precise, not
> approximate, even though a punch is recorded perfectly well without any fix
> at all.
>
> It is **when in use** only. There is no `ACCESS_BACKGROUND_LOCATION` and no
> `NSLocationAlwaysAndWhenInUseUsageDescription`, which is what keeps this off
> the Play Console's sensitive-permission declaration path. Do not add either.
>
> Four descriptions of one behaviour have to agree, and a reviewer compares
> them: this row, the `/privacy` page on the server, `PrivacyInfo.xcprivacy`,
> and the data forms on both consoles. **This row said "not collected" for
> some time after B2.3 shipped, and the Apple manifest omitted the entry
> entirely** — nothing about that fails at build time, and an app that collects
> location without declaring it is the single most common cause of an
> enforcement removal. Re-read all four against the code before every
> submission rather than trusting any one of them.

### 8. Notification permission — wired

`POST_NOTIFICATIONS` is declared and the app now requests it at runtime, at
sign-in rather than at first launch, so the prompt arrives with a reason
visible. Android 13+ requires that explicit request; below 13 it is granted on
install.

Whether a notification can actually appear depends on the build: without
`google-services.json` Firebase does not initialise, nothing is registered and
nothing arrives. Both states are consistent with the declaration — the
permission may be asked for and unused.

**Before submitting a build that has the Firebase config in it**, revisit the
data-safety form: an FCM token is a device identifier, and both stores treat
"registers a push token" as data collection even when the notifications
themselves carry no personal data.

### 9. Console forms that block publication, and are nobody's code

None of these live in the repository, and each one stops a release on its own.
Listed because a checklist that only covers the code reads as complete while the
release sits unsubmittable.

**Google Play**

| Form | Note |
|---|---|
| Content rating questionnaire | Mandatory. A workforce attendance tool rates as *Everyone* on every question — no user-generated content, no ads, no purchases |
| Target audience and content | Answer 18+. Answering anything that includes children pulls the app into the Families policy and its SDK restrictions for no reason |
| Data safety | Section 6 above has the answers |
| App access | Section 1 above — credentials, mandatory for this app |
| Government apps / financial features / health | All **no**. Attendance and leave are neither health nor financial data |
| Ads | **No**. There is no ad SDK, and saying yes would require `AD_ID` and a consent flow the app does not have |
| EU trader status | Required since Feb 2024 to distribute in the EU. A company shipping this to its own staff is a trader; the name, address, phone and email get verified and then appear on the listing |
| Closed testing, 12 testers for 14 continuous days | **Only for developer accounts created as personal accounts.** An organisation account skips it. If it applies and nobody knows until submission, it is a fortnight of delay from a standing start — check which account type the client has *now*, not on submission day |
| App bundle, not an APK | `flutter build appbundle`. Section 4 |

**App Store Connect**

| Form | Note |
|---|---|
| App Privacy questionnaire | Must match `PrivacyInfo.xcprivacy` line for line — a reviewer compares them |
| Age rating | 4+ on every question |
| App Review Information | Section 1 — sign-in required, credentials, and the notes about location and offline punches |
| Export compliance | Already answered in `Info.plist` (`ITSAppUsesNonExemptEncryption = false`), so the upload stops asking |
| EU Digital Services Act trader status | Required since Feb 2025. **A non-trader cannot distribute in the EU at all** |
| Content rights | The icon and every string are original; there is no licensed material in the app |

---

## Checked and deliberately not changed

- **No ATS exception on iOS.** The default blocks plain HTTP, which is what a
  release build should do. Development reaches `http://10.0.2.2` through
  `dart:io`, which does not consult ATS.
- **`allowBackup` left on.** Only the sign-in token needed excluding, and it is
  excluded by name. Turning backup off wholesale would be a bigger promise than
  the privacy policy makes.
- **Account deletion is a support route, not an in-app button.** Accounts are
  provisioned by an employer and an employee cannot delete their own attendance
  record — that is the point of an audit trail. Apple's in-app deletion rule is
  written for apps that let users *create* accounts; this one does not. The page
  says plainly who to contact and what will and will not be erased.
- **R8 is off — `minifyEnabled` and `shrinkResources` are not set.** Neither
  store requires them and the bundle is already small. Turning them on is a
  one-line change whose failure mode is a crash in the release build only, in
  code paths no test here exercises, on a device nobody has yet run this app on.
  That trade is worth taking *after* the first real-device pass, not before it,
  and an attendance app that will not open costs more than the megabytes save.
- **The notification prompt has no rationale screen in front of it.** It fires
  straight after a successful sign-in, which is contextual enough for both
  stores — what Apple actually objects to is asking at first launch, before
  anybody knows what the app is. It is still worth adding one day: iOS never
  re-asks after a refusal, so somebody who declines an unexplained prompt can
  never be reminded to clock out again. That is a product change, not a
  submission gate, so it is recorded here rather than done quietly.
- **The location prompt likewise has no pre-prompt**, and needs none: it appears
  the first time somebody taps Check In, the `NSLocationWhenInUseUsageDescription`
  string explains why, and Play's prominent-disclosure rule applies to background
  location, which this app does not request and must not.
- **`debugPrint` calls are left in.** They are diagnostics on paths that
  deliberately swallow their errors — a failed push registration, an unreadable
  preference — and none of them prints anything about a person.
