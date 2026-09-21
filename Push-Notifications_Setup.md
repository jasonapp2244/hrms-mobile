# Push notifications — what is built, and what you have to do

Both halves are now built: the server sends, and the app registers, receives and
routes. Both are **switched off** until Firebase credentials exist, and neither
fails without them — a server with no key sends no push rather than failing
every notification, and an app with no `google-services.json` builds and runs
with notifications simply absent.

So the work below is the whole of what is left. It is all console and account
work; none of it can be done in code.

Three notifications carry a push version: a leave request arriving for a
manager, a decision reaching the employee, and the reminder for somebody still
clocked in after their shift ended. All three continue to write the in-app bell
and send email exactly as before; push is an addition, not a replacement.

---

## What you have to do

None of this can be done in code — it needs an account and a billing-capable
Google project.

### 1. Create the Firebase project

<https://console.firebase.google.com> → **Add project**. Free tier is sufficient;
FCM has no per-message charge.

Note the **Project ID** (Project settings → General). It is not a secret.

### 2. Register the Android app

Project settings → **Your apps** → Add app → Android.

Package name must be exactly:

```
com.hrms.attendance
```

This has to match the app's `applicationId` character for character — Firebase
issues credentials per package name, and a mismatch fails at registration with
an error that does not name the cause. The value lives in
`mobile/android/app/build.gradle.kts` and is the app's permanent Play identity;
check there rather than trusting this document if the two ever disagree.

Download `google-services.json` and place it in the Flutter repo at
`mobile/android/app/google-services.json`. It is gitignored there.

### 3. Register the iOS app (only when you have an Apple Developer account)

Same screen → iOS. Bundle ID `com.hrms.attendance` — the same string as Android,
which is what `PRODUCT_BUNDLE_IDENTIFIER` in the Xcode project is set to.
Download `GoogleService-Info.plist`.

iOS also needs an **APNs authentication key** (`.p8`) from the Apple Developer
portal, uploaded in Firebase under Project settings → Cloud Messaging. Android
works without any of this.

### 4. Generate the server key

Project settings → **Service accounts** → *Generate new private key*. A JSON
file downloads.

Put it at `hrms/storage/app/firebase/service-account.json`.

**This file is a credential.** Anyone holding it can send a notification to
every installation of the app. It is gitignored, it lives outside the web root,
and it should never be emailed or pasted into a chat.

### 5. Switch it on

In `hrms/.env`:

```env
FCM_ENABLED=true
FCM_PROJECT_ID=your-project-id
```

Then `php artisan config:clear`.

### 6. Run a queue worker

Push is queued along with email. Without a worker nothing is delivered:

```bash
php artisan queue:work
```

---

## How to tell it is working

```bash
php artisan tinker
>>> App\Models\PushDevice::count()      # handsets registered by the app
>>> config('fcm.enabled')               # true
>>> app(App\Services\Push\FcmClient::class)->configured()   # true
```

If `configured()` is false, one of these is wrong: `FCM_ENABLED`,
`FCM_PROJECT_ID`, or the credentials file is missing or unreadable.

Failures are logged to `storage/logs/laravel.log` with the reason FCM gave.

---

## What the server does on its own

**Forgets dead handsets.** When FCM answers `UNREGISTERED` — the app has been
uninstalled — that row is deleted rather than retried forever. A `503` is
treated as Google having a bad minute and the handset is kept, because deleting
it would silently unsubscribe somebody from every future notification.

**Sends to every handset a person has registered.** A phone and a tablet are two
installations and get one request each; FCM's v1 API has no batch endpoint.

**Keeps the OAuth token for an hour.** A short-lived token is minted from the
service-account key and cached, so a batch of notifications does not mint one
each.

---

## What the app does

All of it lives in `mobile/lib/core/push.dart`, owned by `Session` because
registration is a consequence of signing in.

- **Asks for permission** at sign-in, not at first launch. Android 13+ requires
  it explicitly; iOS always asks; refusing registers nothing, because a token
  the OS will never deliver to is a row that fails forever.
- **Registers with `POST /api/v1/devices`** after login *and* after every
  session restore — the OS reissues tokens on its own schedule, and a handset
  the server can no longer reach looks exactly like one that never registered.
- **Re-registers on `onTokenRefresh`**, which is the case that actually breaks
  push in the field.
- **Creates the `hrms_default` channel** natively in `MainActivity.kt`. Android
  8+ drops a notification naming a channel that does not exist, in silence, and
  the FCM send still reports success. The id must match `FCM_ANDROID_CHANNEL`.
- **Sends the token with `POST /auth/logout`**, so a shared work phone stops
  showing the previous person's leave decisions. No screen has to remember
  this — `session.logout()` reads the token itself.
- **Routes a tap** on the payload's `route` key (`clock`, `leave`, `approvals`)
  to the matching tab, including a tap that launched the app from cold, where
  the route has to wait as a value because no screen exists yet to receive an
  event.
- **Shows a snack bar** for a notification that arrives with the app already
  open, since the OS shows nothing in that state.

There is deliberately **no background message handler**. The server sends a
`notification` block with every push, so the OS draws it while the app is
backgrounded or dead; a Dart isolate woken per message would do nothing but
cost battery.

`android/app/build.gradle.kts` applies the google-services plugin **only if
`google-services.json` is present**. Applying it unconditionally fails the build
outright when the file is missing, which would make a Firebase project a
prerequisite for compiling an attendance app. Drop the file in and the next
build picks it up with no edit.

### The one iOS step that cannot be scripted

Xcode has to add the **Push Notifications** capability to the Runner target — it
writes an entitlements file and registers an App ID, and both need a signed-in
Apple Developer account. Open `mobile/ios/Runner.xcworkspace` → Runner →
Signing & Capabilities → **+ Capability** → Push Notifications. Without it iOS
never registers for remote notifications and `getToken()` returns null forever.

Android needs no equivalent step.
