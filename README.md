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
flutter run --dart-define=API_BASE=https://hr.example.com/api/v1
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

## Not built yet

Push on the handset — `firebase_messaging` is a dependency but is never
initialised, there is no `google-services.json`, and `POST /devices` is never
called — plus GPS capture at punch, biometric unlock, and offline queueing.
`../Feature-List_Web-and-App.md` Part B has the full list.
