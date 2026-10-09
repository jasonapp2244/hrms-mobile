# KEMP — Mobile App

Flutter client for the KEMP attendance and workforce system. Android and iOS.

The server — Laravel 12 API and the web dashboard — lives in a separate
repository, **`hr-backend`**. This app talks to it over `/api/v1` and owns none
of it.

## Getting started

```bash
flutter pub get
flutter analyze
flutter test        # 383 tests
```

`flutter pub get` generates the localisations from `lib/l10n/*.arb` into a
git-ignored `lib/l10n/generated/`. Nothing else to run after a clone.

## Pointing it at a server

The app needs a running API. Either the deployed one —
`https://hrams.devonlinetestserver.com` — or a local checkout of `hr-backend`.

**The deployed one is the default** — a plain `flutter run` or `flutter build`
talks to live data. To work against a local backend instead, pass
`--dart-define=API_BASE=http://10.0.2.2:8000/api/v1` (`lib/core/api_client.dart`).

A handset or emulator cannot reach `127.0.0.1` on the host machine. Use the
machine's LAN address, or `10.0.2.2` on the Android emulator.

Demo accounts and what each role sees on a handset are in `CLAUDE.md`, under
**Signing in**. They are all on the password `password`.

## What is in here

| | |
|---|---|
| `lib/` | The app. `core/` is session, API client, models and platform glue; `screens/` is one file per screen |
| `test/` | 383 tests, all headless. No device needed |
| `integration_test/` | Driven tests, device or emulator |
| `store/` | Store listing assets |
| `CLAUDE.md` | **Read this first.** The traps that have already cost time, and the rules at the boundary with the server |
| `API-Reference_v1.md` | The API contract. A stamped copy — the authoritative one is in `hr-backend` |
| `Feature-List_App.md` | What is built. 57 rows, all delivered |
| `Store-Submission_Checklist.md` | Pre-flight for a release |
| `Push-Notifications_Setup.md` | Firebase, when somebody sets it up. Push is silent until then |

## Four rules that cross the boundary

These are the ones that bite, in full in `CLAUDE.md`:

1. **`API-Reference_v1.md` here is a copy.** The backend's is authoritative and
   is checked against the real route table on every test run.
2. **The app never names a date the server has not named first.** The phone is
   wherever its owner is; attendance is judged in the company's timezone.
3. **The notification route lists must agree.** A route the app has not heard of
   fails silently.
4. **Capabilities come from the server**, in the `can` block on `/auth/me`.
   Never derived in Dart.
