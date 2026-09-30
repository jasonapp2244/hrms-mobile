> **This is a copy.** The authoritative version lives in `hr-backend/API-Reference_v1.md`,
> where `tests/Feature/Api/ApiDocsTest` walks the real route table and fails the build on
> an endpoint or an error code that is missing from it. Nothing enforces the freshness of
> *this* file — it is stamped instead.
>
> Taken from `hr-backend` @ **d03164b** (2026-10-01). If the API behaves differently from
> what is written here, the backend is right and this copy is stale.
>
> The content is byte-identical to the backend's copy below this stamp; re-check with
> `diff <(tail -n +12 API-Reference_v1.md) ../hr-backend/API-Reference_v1.md`.

# KEMP — Mobile API Reference (v1)

**Base URL:** `https://<host>/api/v1`
**Auth:** Laravel Sanctum personal access tokens (`Authorization: Bearer <token>`)
**Format:** JSON in, JSON out. Always send `Accept: application/json`.

> Send `Accept: application/json` on every request. Without it Laravel may answer a
> failure with an HTML redirect instead of the error shape below.

This document is checked by `tests/Feature/Api/ApiDocsTest.php`: every route the
application registers under `api/v1` must appear here, so the reference cannot
quietly fall behind the code.

---

## 1. Conventions

### Versioning

The version is in the path, not a header. An app already installed on someone's
phone cannot be forced to upgrade, so `v2` has to be able to run alongside `v1`
rather than replacing it under the same URLs.

### Language

Send `Accept-Language: en` or `Accept-Language: es`. Every `message`, every
`errors` entry, every `stage`, and the meridiem on a pre-formatted `time` come
back in that language (B6.2 in the app, C1.18 on the server).

**The `error` code never changes.** It is the field to branch on; `message` is
the field to show. That split is what let the server start answering in Spanish
without a single change on a handset already in somebody's pocket.

**The header can never make a request fail.** A language this build does not
have, a malformed header, a `q=0`, no header at all — all of them answer in
English rather than refusing. It is a preference, not a credential, and a 422
for an unreadable `Accept-Language` would be a client that cannot talk to the
server over a header it may not have set deliberately. Region is dropped:
`es-MX` and `es-419` are both `es`.

**The header is also remembered against the account.** Notifications are
rendered when a worker picks them up — no request, no header — and usually
because of somebody else's action: HR approving leave in English decides what an
employee reads in Spanish. So each authenticated call records the language on
the user, and everything sent to that person later is written in it.

Three things stay in the language they were typed in, because they are data
rather than vocabulary:

| | Why |
|---|---|
| `leave_type` | A row in `leave_types`, named per company. Rename it to translate it. |
| Office, department and designation names | Same. |
| The maintenance message on `GET /app/status` | Typed by an administrator for a specific outage. |

The **web dashboard is English only**, by decision — it is HR's and the
administrator's screen. Every message the two halves share resolves under the
default locale there, so a web response is unchanged.

### Response shape

Every response carries `ok`, so a client branches on one field rather than
inferring from the status code.

**Success**

```json
{ "ok": true, "...": "endpoint-specific keys" }
```

**Failure** — the same three keys for every failure mode, whatever caused it:

```json
{ "ok": false, "error": "validation_failed", "message": "The given data was invalid." }
```

Validation failures — and only validation failures — add per-field detail:

```json
{
  "ok": false,
  "error": "validation_failed",
  "message": "The given data was invalid.",
  "errors": { "end_date": ["The end date field is required."] }
}
```
### Paging

Every list endpoint answers with a `meta` block, and nothing else about paging
is implied:

```json
{ "meta": { "current_page": 1, "last_page": 4, "per_page": 30, "total": 106 } }
```

`?page=n` selects the page. `?per_page=n` selects its size.

**`per_page` is clamped, never refused.** Below 1, unparseable or absent takes
the endpoint's default; above the ceiling takes the ceiling. A list that 422s
because a client asked for one row too many fails a person trying to read their
own leave in order to protect a server that could have answered. Read
`meta.per_page` to see what was actually used — a client that asked for 100000
can see that it got 100, and stop asking.

The ceiling is `100` by default and is the point of the parameter being bounded
at all: without one, `?per_page=100000` is a way to ask the server to build
every row it owns into a single document.

| List | Default `per_page` |
|---|---|
| `GET /directory` | 30 |
| `GET /notifications` | 25 |
| everything else | 15 |

**These defaults are what each endpoint already served** before `per_page`
existed, so an app that sends nothing receives exactly what it received before.
Both the defaults and the ceiling are configuration (`config/pagination.php`,
overridable with `API_PER_PAGE` and `API_PER_PAGE_MAX`), so a deployment can
change them — do not hard-code the numbers above into a client.


### Error codes

| `error` | HTTP | Meaning |
|---|---|---|
| `validation_failed` | 422 | Input rejected. See `errors` for the fields. |
| `unauthenticated` | 401 | Missing, malformed or revoked token. |
| `forbidden` | 403 | Authenticated, but not allowed to do this. |
| `no_employee_record` | 403 | The account has no employee record, so no attendance, leave, schedule, documents or colleagues either. **Permanent** — an HR or administrator login belongs on the web dashboard, and retrying will never clear it. Distinct from `forbidden` for exactly that reason. |
| `not_found` | 404 | No such endpoint or record. |
| `too_many_requests` | 429 | Rate limited. See §2. |
| `invalid_credentials` | 401 | Login: wrong address or password. |
| `account_disabled` | 403 | Login: the account has been switched off. |
| `device_not_trusted` | 403 | Login: the account is bound to a different handset (B1.6). HR releases it. |
| `duplicate_scan` | 429 | Punch: within the cooldown of the last one. |
| `no_office` | 422 | Punch: the company has no office set up. |
| `qr_required` | 422 | Punch: this person checks in and out by scanning the office QR code (A4.21). Open the scanner; `/attendance/today` says so up front as `method: "qr"`. |
| `qr_invalid` | 422 | QR punch: not an office code of this company, or its screen was switched off. |
| `qr_expired` | 422 | QR punch: the code changed before it arrived. Scan the new one. |
| `qr_already_used` | 422 | QR punch: somebody else scanned that code first. Scan the new one. |
| `activation_invalid` | 422 | Sign-in with QR: no such code. |
| `activation_expired` | 422 | Sign-in with QR: the code was used already, replaced by a newer email, or is over 7 days old. |
| `wrong_password` | 422 | Password change: current password incorrect. |
| `invalid_range` | 422 | `from` is after `to`. |
| `range_too_large` | 422 | Date window exceeds the endpoint's maximum. |
| `server_error` | 500 | Unexpected. The detail is in the server log, not the response. |

A `403` always means *not allowed*, whether it came from a permission check or
an ownership check — the `message` says which.

### Dates and times

- **Dates** are `YYYY-MM-DD`.
- **Timestamps** are ISO 8601 **with the company's UTC offset**, e.g.
  `2026-07-30T16:57:07-04:00`. Render them in the company timezone
  (`user.company.timezone`), not the handset's — an employee travelling must
  still see their own office's clock.
- **Times of day** on a shift are `HH:MM:SS` in the company timezone.
- **Numbers** are JSON numbers: a whole day count arrives as `3`, a half day as
  `0.5`. Parse as a decimal, not an integer.

### Server-authoritative time

The device clock is never trusted. A punch is stamped by the server; sending a
timestamp has no effect.

---

## 2. Rate limits

Limits are per **user** where a token is present, falling back to IP for calls
made before anyone is identified. A whole office behind one address shares an
IP, so limiting on that would have one busy person throttle their colleagues.

| Limiter | Applies to | Limit |
|---|---|---|
| `api` | every endpoint | 120 / minute |
| `login` | `POST /auth/login`, `POST /auth/forgot-password`, `POST /auth/activate` | 5 / minute, per address **and** IP |
| `punch` | `POST /attendance/check`, `POST /attendance/qr`, `POST /attendance/break`, `POST /attendance/sync` | 20 / minute |
| `write` | every endpoint that creates or changes a record | 30 / minute |
| `crash` | `POST /app/crashes` | 6 / minute, per IP — it is a public write |

The stricter limiters stack on top of the ceiling. Every response carries
`X-RateLimit-Limit` and `X-RateLimit-Remaining`; a `429` adds `Retry-After`.

---

## 3. Service

### `GET /ping`

No token required. Use it to check reachability and confirm the API version
before showing a login screen.

```json
{ "ok": true, "service": "KEMP", "version": "v1", "time": "2026-07-30T19:13:39+00:00" }
```

### `GET /app/status`

No token required, and the only endpoint that keeps answering during a
maintenance window — a gate reachable only with a token cannot explain why
signing in is failing. Call it at launch and again when the app returns to the
foreground.

| Query | Type | Notes |
|---|---|---|
| `version` | string | The running build, `major.minor.patch` (a `+build` suffix is ignored). Optional. |
| `platform` | string | `android` or `ios`. Optional — without it no store link can be returned, so no update is required. |

```json
{
  "ok": true,
  "action": "ok",
  "message": null,
  "minimum_version": "1.2.0",
  "latest_version": "1.4.0",
  "store_url": null
}
```

`action` is one of:

| Value | What the app must do |
|---|---|
| `ok` | Carry on. |
| `update_required` | Stop at an update screen and open `store_url`. `message` says why. |
| `maintenance` | Stop at a "back shortly" screen showing `message`, and offer a retry. |

**The server decides; the app obeys.** The comparison is made here rather than
in the app because the app is the half that cannot be fixed — a handset with a
broken comparator has already shipped, and the answer it is given is the only
thing left that can change its behaviour.

**It fails open.** A missing or unreadable `version`, an unrecognised
`platform`, or no store link configured for that platform all answer `ok`. So
does any failure to reach this endpoint at all: the app must treat a network
error as "carry on", or a flat server would take every handset in the company
offline along with it — including the offline punch queue, whose whole purpose
is to work when the server cannot be reached.

`latest_version` is advisory. Nothing is blocked by it and the app does not read
it today; it is returned so support can see what a handset should be running.

`minimum_version` and `latest_version` are null while unset, which is the
default — an empty floor means no build is ever refused.

### `POST /app/crashes`

No token required, and a token is used if one happens to be sent. Crashes are
written to the handset at the moment they happen and delivered on its **next
launch**, so this is a batch of things that already happened, not a live feed.

Unauthenticated on purpose, and for a stronger reason than the gate above: the
crash worth having is the one that stops the app opening, and an endpoint behind
`auth:sanctum` would collect every crash except that one. Send the bearer token
when there is one and the report is attributed to that person and company;
without it the report is kept with neither.

| Field | Type | Notes |
|---|---|---|
| `reports` | array | 1–5 per call. The app never queues more than 5. |
| `reports[].exception` | string | Required. The exception class. Max 191. |
| `reports[].message` | string | Max 500, **truncated by the sender**. Never build one out of personal data — it lands in a table an administrator reads. |
| `reports[].stack` | string | Max 8000. |
| `reports[].platform` | string | `android` or `ios`. |
| `reports[].app_version` | string | The build that crashed, not the one reporting. |
| `reports[].os_version` | string | `Platform.operatingSystemVersion` — on Android this already names the handset build, which is why no separate device field is collected. Max 191. |
| `reports[].occurred_at` | ISO-8601 | When it crashed. **The device clock is trusted here**, as it is for an offline punch — a report delivered three days later is worth nothing stamped with its arrival. Bounded: a future time, or anything over 30 days old, is replaced with the arrival time. |

```json
{ "ok": true, "stored": 2 }
```

Answers `201`. Throttled on its own limiter (6/min per IP) because it is a
public write: a handset delivers what it queued once per launch, and an app
crashing hard enough to relaunch six times a minute has already said everything
the seventh report would.

The server groups reports by a fingerprint of the exception plus the top few
stack frames, so a hundred handsets hitting one bug read as one row. Nothing is
sent to any third party — there is no crash service and no analytics SDK in this
app, and the reports are readable only by an administrator, under
**Administration → App Crash Reports**.

---

## 4. Authentication

### `POST /auth/login`

No token required.

| Field | Type | Notes |
|---|---|---|
| `email` | string, required | |
| `password` | string, required | |
| `device_name` | string, required, ≤100 | Names the token so it can be recognised and revoked. Use something stable and human — "Ann's Pixel". |

Logging in again from the **same** `device_name` replaces that device's token
rather than issuing a second one, so a reinstall does not leave a valid
credential behind.

```json
{
  "ok": true,
  "token": "3|aFK5Blm...",
  "user": {
    "id": 3,
    "name": "James Smith",
    "email": "james.smith@acme.test",
    "roles": ["employee", "manager"],
    "permissions": ["view-attendance", "approve-leave", "view-team", "approve-swaps"],
    "company": { "id": 1, "name": "Acme", "timezone": "America/New_York", "currency": "EUR" },
    "employee": {
      "id": 1, "employee_code": "EMP-0001", "full_name": "James Smith",
      "department": "Engineering", "designation": "Software Engineer",
      "office": "Head Office", "work_mode": "office", "is_manager": true
    }
  }
}
```

Store the token in the platform keychain, never in plain preferences.

`employee` is `null` for an account with no employee record (an admin login, for
example). Such an account can sign in and read its profile, but every
employee-scoped endpoint answers `403`.

A wrong address and a wrong password give the **same** answer — saying which was
wrong would tell an attacker which addresses exist.

**Every outcome here lands in the security trail** (A1.8), which the web
dashboard shows under Activity Log: a sign-in, a failed attempt with the address
that was tried, a correct password on a disabled account, and being rate
limited. The entry names the door in words — *"Signed in from the mobile app"* —
because somebody reading it after an incident needs to know whether a handset
was involved. Signing out is recorded too, and `logout-all` records how many
tokens and handsets it reached.

#### Device binding (B1.6)

Send `device_id` — a UUID the app generates **once** and keeps in the platform
keychain, never a hardware identifier — and optionally `platform`. Both are
ignored unless the company has switched binding on.

| Field | Type | Notes |
|---|---|---|
| `device_id` | string, optional, ≤100 | Stable for the life of the install. Generate it on first launch and **do not clear it at sign-out** — it describes the phone, not the person, and a fresh one at each sign-out defeats the feature entirely. |
| `platform` | string, optional, ≤20 | `android`, `ios`. Display only. |

When binding is on, the **first** handset to sign an account in claims it and is
let through; a **different** handset is then refused `device_not_trusted` (403)
and **no token is issued**. HR releases the binding from the web dashboard when
somebody changes or wipes a phone.

A client that sends no `device_id` is let through rather than refused — that is
an older build, not an impostor — but it cannot be bound either, so it gets none
of the protection. The check runs **after** the password, so somebody guessing
passwords is never told that an account exists *and* is bound.

**Failures:** `invalid_credentials` (401) · `account_disabled` (403) ·
`device_not_trusted` (403) · `validation_failed` (422) · `too_many_requests` (429)

### `POST /auth/forgot-password`

Starts a password reset. **No token required** — somebody who could authenticate
would not need this.

| Field | Type | Notes |
|---|---|---|
| `email` | string, required, email | The address the person signs in with. |

```json
{
  "ok": true,
  "message": "If that email address has an account, a reset link is on its way."
}
```

**The answer is the same whatever happened** — address unknown, account
deactivated, or a link already sent a moment ago all return this. Do not try to
branch on it: there is nothing to branch on, by design. For an HR system the
staff list is exactly what an attacker is after, and a form that says "no such
user" is a way to enumerate it.

The link in the email opens the **web** reset page. The app's part of the flow
ends with this call — do not build a token entry screen. A reset has to work
from a borrowed laptop, because the phone is often the thing the person has lost
access to.

Completing a reset **revokes every API token and push registration** for that
account, so a handset that was signed in will get `unauthenticated` on its next
call and must send the person back to the login screen.

**Failures:** `validation_failed` (422) · `too_many_requests` (429, the `login`
limiter — 5/minute)

### `POST /auth/activate`

Sign a phone in with the one-time code from the **welcome email** (A4.21). The
email is sent when HR creates somebody's sign-in account, and again whenever HR
presses *Send welcome email*. Unauthenticated, on the `login` limiter.

| Field | Type | Notes |
|---|---|---|
| `code` | string, required | The scanned QR text, `KEMP1-ACT:<code>`, or the bare code. |
| `device_name` | string, required | As for `/auth/login`. |
| `device_id` | string, optional | As for `/auth/login` — device binding applies exactly as it does there. |
| `platform` | string, optional | As for `/auth/login`. |

Answers exactly like `/auth/login`: `token` and `user`.

**The code signs in and does nothing else.** It is spent on first use, a newer
email replaces it, and it expires after 7 days. It never records a punch — a
code in an inbox can be forwarded, and attendance is proved only by the office
screen's code (`POST /attendance/qr`).

**Failures:** `activation_invalid` (422) · `activation_expired` (422) ·
`account_disabled` (403) · `device_not_trusted` (403) · `validation_failed`
(422) · `too_many_requests` (429)

### `GET /auth/me`

The payload above, for a client restoring a session on launch. Call it at
startup: roles and permissions change without the app knowing.

### `POST /auth/logout`

Signs out this device.

| Field | Type | Notes |
|---|---|---|
| `push_token` | string, optional | Send the token registered with `POST /devices`. Without it the handset keeps receiving this person's notifications after they have signed out. |

### `POST /auth/logout-all`

Signs out every device and removes every registered handset — for a phone that
has been lost.

```json
{ "ok": true, "message": "Signed out on all devices.", "tokens_revoked": 2, "devices_removed": 1 }
```

### `GET /auth/devices`

Sessions currently holding a valid token, for a "where am I signed in" screen.
`current` marks the one making the call.

```json
{ "ok": true, "devices": [
  { "id": 4, "name": "Ann Pixel", "last_used_at": "2026-07-30T18:02:11-04:00", "created_at": "...", "current": true }
] }
```

---

## 5. Attendance

### `POST /attendance/check`

One endpoint for both directions. **The server decides whether this is a clock
in or a clock out** from what is already on record — the app does not say, so a
stale screen cannot post the wrong one.

| Field | Type | Notes |
|---|---|---|
| `latitude` | numeric, optional, −90…90 | Recorded for HR. Never blocks a punch. |
| `longitude` | numeric, optional, −180…180 | As above. |
| `location_mocked` | bool, optional | The OS's own word on whether *this fix* came from a mock provider — `Position.isMocked` on Android and iOS. Send it only when sending coordinates. |
| `device_rooted` | bool, optional | Whether the handset appears rooted or jailbroken. |
| `device_emulator` | bool, optional | Whether the app is running on an emulator. |

Location is a record, not a gate: office, remote and hybrid staff all clock in
from wherever they are. If the handset refuses permission, send the punch
without it.

`GET /attendance/today` carries a `geofence` object when — and **only** when — a
fence applies to the caller (B2.5):

```json
"geofence": { "office": "Head Office", "latitude": 40.758, "longitude": -73.9855, "radius": 100 }
```

`null` is the normal case, and it covers four different situations the client
must not try to tell apart: the company does not enforce, the employee works
from home or hybrid, the office has no coordinates, or this build is talking to
an older server. The server resolves all of that — **do not reimplement it.**

When it is present, a client may check the distance itself and say so instead of
posting, using **haversine on a spherical earth**, which is what the server runs.
Match its exemptions exactly, including this one: **a punch that carries no
coordinates is never refused**, so never block one locally for want of a fix.
Refusing anything the server would have accepted is worse than not checking at
all.

**The three integrity flags are recorded and never enforced** (B2.7). Nothing
here refuses a punch; the attendance register marks the row and offers a filter,
and a person decides. One flagged punch is usually nothing — a pattern is the
thing.

**Omit a flag you cannot answer; do not send `false` for it.** The column is
three-state, and `null` means *the client said nothing*, which is what every
web-portal punch and every build older than this feature carries. `false` is the
handset actively reporting a clean device, and defaulting to it would write a
bill of health nobody issued. The same three fields are accepted per punch on
`POST /attendance/sync` and on `POST /attendance/break`.

```json
{
  "ok": true,
  "punch": {
    "id": 109, "type": "in", "status": "late",
    "scanned_at": "2026-07-30T16:57:07-04:00", "time": "04:57 PM",
    "office": "Head Office", "source": "mobile"
  },
  "next_action": "out",
  "message": "You clocked IN at 04:57 PM."
}
```

`type` is `in` or `out`. `status` is `ontime`, `late` or `early_leave`, measured
against the shift rostered for that day.

**Failures:** `qr_required` (422, this person scans the office code instead —
see `method` on `/attendance/today`) · `duplicate_scan` (429, within the
cooldown of the last punch) ·
`outside_geofence` (422) · `no_office` (422) · `no_employee_record` (403) ·
`too_many_requests` (429, the `punch` limiter)

Treat `duplicate_scan` as success from the user's point of view — the punch they
wanted is already recorded.

`outside_geofence` only ever appears for a company that has switched enforcement
on (A4.16, off by default). Its `message` names the distance, so show it rather
than a generic failure — "move closer" is the one thing the person can act on.
A punch that arrives with no coordinates is never fenced, so refusing location
permission does not lock anybody out.

### `POST /attendance/qr`

Punch in or out by scanning the QR code on the office screen (A4.21). **Which
one is still decided by the server**, exactly as for `/attendance/check`; the
code adds one fact — that the person is standing at that screen.

| Field | Type | Notes |
|---|---|---|
| `qr` | string, required | The scanned text, exactly as read: `KEMP1:<office_id>:<token>`. Refuse anything not starting `KEMP1:` on the handset rather than sending it. |
| `latitude`, `longitude` | numeric, optional | As for `/attendance/check`. The geofence still applies when the company enforces one. |
| `location_mocked`, `device_rooted`, `device_emulator` | boolean, optional | As for `/attendance/check`. |

Answers exactly like `/attendance/check` (`punch`, `next_action`, `message`).
`punch.source` is `qr`, and `punch.office` is the office **on the screen**,
which may differ from the person's own — a cleaner covering another site is
still at work.

**Each code works once.** The first scan claims it; the screen shows a new one
within about a second. A code nobody scans expires after 30 seconds. So a
screenshot, a photo sent to somebody at home, or a second person scanning over a
shoulder all fail.

**Never queued offline.** The code is only worth anything while it is live, and
only the server can say whether it still is. With no connection, tell the person
to connect and scan again.

Open to anybody, whatever `method` says, so a company can put a screen up and
let staff try it before switching the button off.

**Failures:** `qr_invalid` (422) · `qr_expired` (422) · `qr_already_used`
(422) · `duplicate_scan` (429) · `outside_geofence` (422) · `no_employee_record`
(403) · `validation_failed` (422) · `too_many_requests` (429, the `punch`
limiter)

`qr_expired` and `qr_already_used` mean the same thing to the person: scan
again. Do not retry the same text — it can never succeed.

### `POST /attendance/sync`

Deliver punches made with **no signal** (B2.4). A batch, because the moment this
runs is the moment the connection is worst — four punches over a dropping link
is four chances to fail rather than one.

| Field | Type | Notes |
|---|---|---|
| `punches` | array, required, 1–50 | Oldest first is not required; the server sorts. |
| `punches[].occurred_at` | date-time, required | **When the person actually tapped**, from the device clock. |
| `punches[].latitude` | numeric, optional | |
| `punches[].longitude` | numeric, optional | |

**This is the one endpoint where the device clock is trusted**, and only within
bounds. The alternative is worse: stamping a queued punch on arrival files a
09:00 check-in as 17:00 and hands payroll a number that is simply wrong. So the
claimed time is taken, capped, and labelled — the row's `source` is
`mobile_offline`, and its `notes` record how long it sat on the handset.

- **Future times are refused**, not clamped.
- **Anything older than 48 hours is refused**, not clamped — a clamped time is a
  wrong time that looks right. Past that, raise a regularisation instead
  (`POST /attendance/regularisations`), which carries a reason and a decision.
- The **type is still the server's**, inferred from the punches *before* that
  moment rather than the last of the day, so a queued punch slots into the
  sequence instead of being appended to it.

```json
{
  "ok": true,
  "results": [
    { "occurred_at": "2026-08-03 09:00:00", "result": "accepted",
      "punch": { "id": 140, "type": "in", "status": "late", "scanned_at": "…",
                 "time": "09:40 AM", "office": "Head Office", "source": "mobile_offline" } },
    { "occurred_at": "2026-08-03 23:00:00", "result": "refused",
      "message": "That punch is dated in the future. Check the date and time on this device." }
  ],
  "accepted": 1, "duplicate": 0, "refused": 1
}
```

**Partial success is the normal case, so read `results` per punch, not the
counts.** One refused entry must not discard three good ones.

| `result` | What the app does |
|---|---|
| `accepted` | Drop it from the queue. |
| `duplicate` | Drop it from the queue — it already landed on an earlier attempt. |
| `refused` | Drop it from the queue and tell the person `message`. Retrying will not change the answer. |

Re-sending a punch already delivered returns `duplicate` rather than writing a
second row. A queue retries whenever a connection is flaky — precisely when this
endpoint is in use — and attendance is append-only, so a duplicate could only
ever be voided, never removed.

**Failures:** `no_office` (422) · `no_employee_record` (403) · `validation_failed` (422,
empty or over 50) · `too_many_requests` (429, the `punch` limiter)

### `POST /attendance/break`

Start or end a break. **The server decides which**, from the day's punches —
same reasoning as `check`, and for the same reason.

| Field | Type | Notes |
|---|---|---|
| `latitude` | numeric, optional, −90…90 | Recorded, never a gate. |
| `longitude` | numeric, optional, −180…180 | As above. |

```json
{
  "ok": true,
  "punch": {
    "id": 114, "type": "break_start", "status": "ontime",
    "scanned_at": "2026-07-30T13:02:44-04:00", "time": "01:02 PM",
    "office": "Head Office", "source": "mobile"
  },
  "on_break": true,
  "next_break_action": "end",
  "message": "Break started at 01:02 PM. Your worked time pauses until you return."
}
```

`type` is `break_start` or `break_end`. `status` is always `ontime`: a break is
neither early nor late, and reusing the punch statuses here would hang a
meaningless "late" badge on somebody's lunch.

A break is only available **on the clock**. Starting one while checked out, or
ending one nobody started, is refused rather than guessed — an unpaired break
marker has to be discarded by the hours calculation, so the button would appear
to work while the total silently did not move. Read `can_break` from
`/attendance/today` and grey the button instead of letting the tap fail.

**Failures:** `break_not_available` (422, not clocked in) · `duplicate_scan`
(429) · `no_office` (422) · `no_employee_record` (403) · `too_many_requests` (429, the
`punch` limiter)

### `GET /attendance/today`

Everything a home screen needs.

```json
{
  "ok": true,
  "date": "2026-07-30",
  "server_time": "2026-07-30T16:59:17-04:00",
  "timezone": "America/New_York",
  "next_action": "out",
  "method": "button",
  "can_check": true,
  "on_break": false,
  "break_started_at": null,
  "can_break": true,
  "next_break_action": "start",
  "is_clocked_in": true,
  "worked_minutes": 2,
  "punches": [ { "id": 109, "type": "in", "status": "late", "scanned_at": "...", "time": "04:57 PM", "office": "Head Office", "source": "mobile" } ],
  "shift": { "id": 1, "name": "Morning Shift", "start_time": "09:00:00", "end_time": "17:00:00",
             "late_grace_minutes": 15, "crosses_midnight": false,
             "break_minutes": 30, "break_is_paid": false, "break_is_minimum": false },
  "is_day_off": false,
  "holiday": null,
  "leave": null
}
```

- `date` is the day a punch made **now** would count against. On a shift that
  crosses midnight this is still yesterday — a night worker opening the app at
  02:00 sees the day their shift started, matching how the punch is filed.
- `can_check` is `false` only while the duplicate cooldown is running. Grey the
  button rather than letting a tap fail.
- `method` (A4.21) is how the in/out button works for this person **today**:
  `button` posts to `/attendance/check`; `qr` opens the camera and posts the
  scanned code to `/attendance/qr`, and `/attendance/check` and offline punches
  are refused with `qr_required`. It is `qr` only for office staff at a company
  that requires it — WFH and hybrid staff stay on `button`. Breaks are a button
  either way. Decided here so the app never works the policy out itself.
- `is_clocked_in` stays `true` **through a break** — the person has not gone
  home. Do not derive it from the last entry in `punches`: `break_end` is
  neither `in` nor `out`, and reading it as the end of the day would offer
  "Check In" to somebody already on the clock and open a second stretch.
  `next_action`, `is_clocked_in` and `can_break` are the server's answer to
  exactly that question; use them.
- `can_break` is `true` only on the clock and outside the cooldown.
  `next_break_action` (`start` / `end`) labels the break button, and is kept
  apart from `next_action` because one screen carries both and they move
  independently.
- `break_started_at` is set only while `on_break` is `true`.
- The shift's **break policy** (A5.7) travels with it, so a client can tell
  somebody what pressing the break button costs them: `break_minutes` is the
  shift's break, `break_is_paid` means it stays on the clock, and
  `break_is_minimum` means that much comes off however short the break actually
  taken. `break_is_paid` wins over `break_is_minimum` — a paid break costs
  nothing, so there is no floor to raise it to. Absent from `/schedule` and the
  `/team/*` payloads, which answer different questions.
- `worked_minutes` counts closed in/out pairs, plus the open stretch up to now
  when `is_clocked_in` is true, **less any completed break** — unless the
  shift's break is **paid** (A5.7), in which case the break stays on the clock.
  Nothing else about the break policy reaches a live number: the shift's
  nominal break has not been taken yet at five past nine, and whether a short
  break is topped up to the shift's minimum cannot be judged until it is over.
  Both of those apply to the day's **paid** figure, which is the web dashboard's
  overtime report rather than anything here.
- `leave` being set does **not** disable the button. Somebody who books a day
  off and comes in anyway worked, and the record has to say so.

### `GET /attendance/history`

One row per **day**, newest first — the question is "did I make it in, and
when", which is a day-shaped answer.

| Query | Default | Notes |
|---|---|---|
| `from` | `to` − 29 days | `YYYY-MM-DD` |
| `to` | today | Clamped to today. A day that has not happened cannot be an absence. |

Maximum window: **92 days**.

```json
{
  "ok": true, "from": "2026-07-27", "to": "2026-07-30",
  "days": [
    { "date": "2026-07-30", "weekday": "Thu", "status": "present", "late": true,
      "first_in": "2026-07-30T16:57:07-04:00", "last_out": null,
      "worked_minutes": 0, "punches": 1, "holiday": null }
  ],
  "totals": { "present_days": 1, "late_days": 1, "leave_days": 0, "absent_days": 3, "worked_minutes": 0 },
  "score": { "score": 25, "ontime_days": 1, "obliged_days": 4, "streak": 0 }
}
```

`status` is one of:

| Value | Meaning |
|---|---|
| `present` | Punched in. Wins over every reason not to be there. |
| `leave` | Approved leave, no punch. |
| `holiday` | Company holiday, no punch. |
| `day_off` | Rostered off, no punch. |
| `weekend` | Not a working day for this company. |
| `absent` | A working day nobody planned off, not booked, not shown up for. |

A day never clocked out of reports `worked_minutes: 0` — there is no honest
number for a stretch that was never closed.

#### `score` — the personal attendance score and streak (B3.5)

Two numbers with deliberately different shapes, and a client that treats them
alike will get one of them wrong.

| Field | Notes |
|---|---|
| `score` | 0–100, or **`null`**. Of the days in this window the employee was meant to be here, the percentage they made on time. |
| `ontime_days` | The numerator. Days with a punch and no `late` flag. |
| `obliged_days` | The denominator. Days whose `status` is `present` or `absent` — every other status is a day nobody expected them. |
| `streak` | Consecutive days arrived on time, counting back from **today**. Ignores `from` and `to` entirely. |

`null` is a real answer and **must not be rendered as zero**: a window of
weekends, or a fortnight of approved leave, has no score, and zero reads as a
failure to the person least deserving of one. `obliged_days: 0` is the tell.

The score is derived from the `days` array above rather than recomputed, so a
client can always account for it by pointing at the rows; showing a number that
disagrees with the list beneath it would be worse than showing none.

`streak` is **not** a property of the window. The app offers 7, 30 and 92-day
ranges and the score follows whichever is chosen; the streak does not, because
"eleven days" has to mean eleven days. Weekends, company holidays, approved
leave and rostered days off neither break it nor extend it, and **today is only
ever counted, never held against them** — asked at nine in the morning before
anybody has clocked in it still reports yesterday's streak.

**Failures:** `invalid_range` (422) · `range_too_large` (422) · `validation_failed` (422)

### Regularisation requests

Asking for the record to be corrected (A4.13) — a punch that reads wrong, or one
that should be there and isn't.

**Raising only.** There is no approve or reject endpoint and there will not be
one: approving voids a punch and writes a replacement, which is
`manage-attendance` and lives on the web. **A manager has no step here.** Leave
approval is manager-then-HR; a correction is HR's alone, so an approve button in
the app's manager tab would advertise a stage that does not exist.

Attendance is append-only. Nothing on this endpoint changes a punch — a request
is inert until HR decides it, and the correction that follows goes through the
same void-and-re-enter path HR uses by hand, so it carries the same audit trail.

#### `GET /attendance/regularisations`

| Query | Notes |
|---|---|
| `status` | `pending`\|`approved`\|`rejected`\|`cancelled` |
| `page` | 15 per page |

```json
{
  "ok": true,
  "today": "2026-08-04",
  "server_time": "2026-08-04T10:15:00-04:00",
  "requests": [
    { "id": 7, "type": "out", "work_date": "2026-08-03",
      "requested_at": "2026-08-03T18:00:00-04:00",
      "reason": "Left at 6pm but forgot to press check out",
      "status": "pending", "challenges_a_punch": false,
      "attendance_log_id": null, "can_cancel": true,
      "submitted_at": "2026-08-04T09:12:00-04:00",
      "decision_note": null, "decided_by": null, "decided_at": null }
  ],
  "meta": { "current_page": 1, "last_page": 1, "per_page": 15, "total": 1 },
  "recent_punches": [
    { "id": 109, "type": "in", "status": "late", "work_date": "2026-08-03",
      "scanned_at": "2026-08-03T09:40:00-04:00", "time": "09:40 AM", "office": "Head Office" }
  ]
}
```

`today` and `server_time` are the **company's** date and wall clock, and are
where a new request's form should open. A correction cannot be raised for a time
that has not happened, and the handset's own clock does not know where that line
is — a phone a few hours ahead of the company would propose a time this endpoint
then refuses.

`recent_punches` is the last 30, newest first, and is why this list ships them:
`/attendance/history` answers in day-shaped rows and carries no punch ids, so
without it the app cannot name the reading it is disputing. Voided punches are
never included — there is nothing to dispute about a reading already struck out.

`decided_by` is the name recorded **on the row** at the moment of the decision,
so it still reads correctly after that account is deleted.

#### `POST /attendance/regularisations`

| Field | Type | Notes |
|---|---|---|
| `attendance_log_id` | integer, optional | The punch being disputed. Omit to report one that is missing. |
| `type` | `in`\|`out`, required | What the corrected punch should be. |
| `requested_at` | date-time, required | The time it should read. |
| `reason` | string, required, 5–500 | |

Three rules beyond the shape, all shared with the portal form:

- **No future times.** A correction to a moment that has not happened is refused
  on `requested_at`.
- **Only your own punches.** An `attendance_log_id` from somebody else's record
  is refused on `attendance_log_id` — it is checked, never trusted.
- **One open request per problem** — per punch, or per date-and-type where there
  is no punch. Refused on `reason`. Without it a double submit produces two
  approvals and two corrections for one problem.

Returns **201** with the created request.

#### `POST /attendance/regularisations/{id}/cancel`

Withdraw one that is still pending. A decided request has already moved
attendance; "cancelling" it afterwards would leave the correction standing with
nothing on record explaining it, so it is refused on `status`.

**Failures for all three:** `validation_failed` (422, including the three rules
above) · `forbidden` (403, somebody else's request) · `no_employee_record` (403) ·
`not_found` (404) · `too_many_requests` (429, the `write` limiter)

---

## 6. Leave

### `GET /leave/balances`

Every type still open for booking, with this employee's balance. Render the
apply form from this list — inactive types keep their history but are not
offered.

| Query | Default |
|---|---|
| `year` | current year |

```json
{
  "ok": true, "year": 2026,
  "balances": [
    { "leave_type_id": 4, "name": "Annual Leave", "code": "AL", "color": "#4f46e5",
      "is_paid": true, "allow_half_day": true, "requires_approval": true,
      "entitled_days": 20, "carried_forward": 0, "used_days": 0,
      "available_days": 20, "is_capped": true }
  ]
}
```

**`is_capped` matters.** A type granting zero days is *uncapped*, not exhausted —
that is how unpaid leave is set up. Do not grey it out or show "0 days left".

### `POST /leave/requests`

| Field | Type | Notes |
|---|---|---|
| `leave_type_id` | int, required | Must be an active type belonging to the employee's company. |
| `start_date` | `YYYY-MM-DD`, required | |
| `end_date` | `YYYY-MM-DD`, required | On or after `start_date`; at most two years ahead. |
| `is_half_day` | bool, optional | Only for a type allowing it, and only when start and end are the same date. |
| `half_day_period` | `first_half`\|`second_half`, optional | |
| `reason` | string, optional, ≤1000 | |
| `attachment` | file, optional, ≤10 MB | `pdf jpg jpeg png webp doc docx`. **Send the whole request as `multipart/form-data`** — the file is a part, not base64 in a JSON body, and the other fields cross as form fields beside it. |

**The file is stored only if the request is accepted.** A refusal — overlapping
dates, an exhausted balance — deletes it again rather than leaving a medical
document on disk belonging to a request that does not exist.

**The server counts the days.** Weekends and company holidays inside the range
are free, so Friday-to-Monday over a two-day weekend costs **2**, not 4. Do not
compute and send a day count — the response tells you what it actually cost.

`201` on success:

```json
{
  "ok": true,
  "request": { "id": 8, "leave_type": "Annual Leave", "start_date": "2026-09-04",
               "end_date": "2026-09-07", "days": 2, "is_half_day": false,
               "status": "pending", "stage": "Awaiting HR", "can_cancel": true,
               "submitted_at": "2026-07-30T21:09:42+00:00" },
  "message": "Leave request submitted. You will be notified once it is reviewed."
}
```

A type that needs no approval comes back `approved` immediately.

Business-rule refusals arrive as `validation_failed` against the field that
caused them, so they can be shown on the form:

- `start_date` — overlaps leave you already have, or the range is entirely
  weekend and holiday so there is nothing to book
- `leave_type_id` — not available, or more days than the balance allows
- `end_date` — before the start, or more than two years ahead
- `is_half_day` — not allowed for this type, or spanning two dates

### `GET /leave/requests`

The caller's own requests, newest first, 15 per page.

| Query | Notes |
|---|---|
| `status` | `pending`, `approved`, `rejected`, `cancelled` |
| `year` | Filters on the start date |
| `page` | |

```json
{ "ok": true, "requests": [ … ], "meta": { "current_page": 1, "last_page": 1, "per_page": 15, "total": 2 } }
```

`stage` is what to show a person chasing a decision: `Awaiting Manager`,
`Awaiting HR`, or the final status. "Pending" alone does not say who to ask. An
employee with no manager set skips the manager step entirely.

### `GET /leave/requests/{id}`

The same fields plus `half_day_period`, `reason`, `manager_note`,
`manager_approved_by`, `manager_approved_at`, `decision_note`, `decided_by`,
`decided_at`.

`403` for anybody else's request.

### `GET /leave/requests/{leaveRequest}/attachment`

The supporting file, streamed. **Not JSON** — the body is the file, with
`Content-Disposition` naming it as it was uploaded. Failures still answer in
JSON, so decode only on a non-2xx.

**Two readers, and no others:** the employee who attached it, and that person's
line manager. Not a colleague, and not a manager of a different team — holding
`approve-leave` gets a manager through the door and grants nothing on its own,
which is the same rule that governs deciding. HR and administrators read it in
the web dashboard, through their own session.

Every leave payload carries `has_attachment` (bool) and `attachment_name`
(string or null) so a client knows whether to offer this at all.
`has_attachment` is computed from the disk rather than from the column, so a
row whose file has gone missing reports `false` while still carrying the name —
do not draw a link from the name alone.

**Failures:** `forbidden` (403, somebody else's request) · `no_employee_record` (403) · `not_found` (404, the row exists but the file
is gone)

### `POST /leave/requests/{id}/cancel`

Withdraws it. Approved leave gives its days back; pending leave never spent any.

Only possible while `can_cancel` is true — pending, or approved and not yet
started. Leave already under way is HR's to unwind.

**Failures:** `validation_failed` (422, with `errors.status`) · `forbidden` (403, somebody else's request) · `no_employee_record` (403)

---

## 7. Manager approvals

Requires the `approve-leave` permission **and** the request must belong to one
of the caller's own direct reports. The permission opens the door; it is not
access to anyone else's team. Show this section only when
`user.permissions` contains `approve-leave`.

### `GET /leave/approvals`

What this manager still has to act on, soonest first. A request already passed
up to HR leaves the inbox.

```json
{
  "ok": true, "pending_count": 1,
  "pending": [
    { "id": 6, "employee": "Michael Brown", "employee_id": 3,
      "leave_type": "Sick Leave", "start_date": "2026-09-21", "end_date": "2026-09-22",
      "days": 2, "is_half_day": false, "reason": null,
      "submitted_at": "2026-07-30T17:08:41+00:00",
      "clashes": [ { "employee": "Sam Fox", "start_date": "2026-09-21", "end_date": "2026-09-23" } ] }
  ]
}
```

`clashes` is who else on the team is already off over the same dates. Show it
before the approve button, not after.

### `POST /leave/approvals/{id}/approve`

Passes the request to HR for the final decision. **Nothing is deducted here** —
the manager step commits no days.

| Field | Type |
|---|---|
| `manager_note` | string, optional, ≤1000 |

### `POST /leave/approvals/{id}/reject`

| Field | Type | Notes |
|---|---|---|
| `decision_note` | string, **required**, ≤1000 | The employee sees this. |

**Failures for both:** `forbidden` (403, outside the team or the manager's own
request) · `validation_failed` (422, already decided or already passed up)

---

## 7b. Team

### `GET /team/attendance`

Who on **your own team** is in today. Requires `approve-leave`, and answers only
for your direct reports — a team lead is not HR, and the web dashboard is where
company-wide attendance lives.

| Query | Default | Notes |
|---|---|---|
| `date` | today | `YYYY-MM-DD`. A future date is refused: nobody can be absent for a day that has not happened. |

```json
{
  "ok": true, "date": "2026-08-01", "timezone": "America/New_York",
  "summary": { "total": 5, "present": 3, "in_now": 2, "late": 1,
               "on_leave": 1, "absent": 1, "off": 0 },
  "team": [
    { "employee_id": 2, "name": "Emily Johnson", "employee_code": "EMP-0002",
      "status": "present", "late": true,
      "first_in": "09:14 AM", "last_out": null,
      "is_clocked_in": true, "worked_minutes": 214,
      "shift": { "name": "Morning Shift", "start_time": "09:00:00", "end_time": "17:00:00" } }
  ]
}
```

`status` uses the same vocabulary as `/attendance/history` — `present`, `leave`,
`holiday`, `day_off`, `weekend`, `absent` — and is computed by the same code, so
a manager and the person they manage never see two different words for one day.

**`in_now` is not `present`.** Somebody who worked this morning and went home is
present for the day but not on the floor. A manager asking "who is here" wants
the first number; a manager asking "who turned up" wants the second.

A manager with nobody reporting to them gets `team: []` and a zeroed summary,
not an error.

**Failures:** `invalid_range` (422, a future date) · `forbidden` (403, no
`approve-leave` permission) · `validation_failed` (422)

---

### `GET /team/roster`

Your team's **published** roster over a stretch of days. Same gate and same team
as `/team/attendance`.

| Query | Default | Notes |
|---|---|---|
| `from` | today | `YYYY-MM-DD`, the first day of the window. |
| `days` | 7 | 1–31. |

```json
{
  "ok": true, "from": "2026-08-03", "to": "2026-08-09",
  "timezone": "America/New_York",
  "team": [
    { "employee_id": 2, "name": "Emily Johnson", "employee_code": "EMP-0002",
      "schedule": [
        { "date": "2026-08-03", "status": "working", "holiday": null,
          "shift": { "name": "Morning Shift", "start_time": "09:00:00", "end_time": "17:00:00" },
          "is_rostered": true },
        { "date": "2026-08-04", "status": "leave", "holiday": null,
          "shift": null, "is_rostered": false }
      ] }
  ]
}
```

Returned **employee-major**: a manager reads down a person to see their week.
The across-a-day view is what `/team/attendance` already answers.

`status` is one of `working`, `leave`, `holiday`, `day_off`, `weekend`.

**Published only**, exactly like the employee's own `/schedule`. A manager
seeing draft shifts their team cannot see would tell somebody to come in on a
day still being planned — which is the whole reason the roster has a draft and
a published state.

**Leave outranks the roster.** Somebody rostered on a day they later booked off
comes back as `leave` with no shift, because showing the shift would have a
manager expecting them.

`is_rostered` distinguishes a day explicitly planned on the roster from one
falling back to the person's standing shift. Both are `working`; only the first
was deliberately placed.

A manager with nobody reporting to them gets `team: []`, not an error.

**Failures:** `forbidden` (403, no `approve-leave` permission) ·
`validation_failed` (422)

---

### `GET /team/leave-calendar`

Who on your team is off, and when — a month at a time. Same gate and same team
as the two above.

| Query | Default | Notes |
|---|---|---|
| `month` | the company's current month | `YYYY-MM`. |

```json
{
  "ok": true,
  "month": "2026-08", "from": "2026-08-01", "to": "2026-08-31",
  "timezone": "America/New_York", "today": "2026-08-03", "team_size": 6,
  "days": [
    { "date": "2026-08-01", "weekend": true, "holiday": null, "people": [] },
    { "date": "2026-08-03", "weekend": false, "holiday": null,
      "people": [
        { "employee_id": 2, "name": "Emily Johnson", "employee_code": "EMP-0002",
          "leave_type": "Annual", "status": "approved",
          "is_half_day": false, "half_day_period": null,
          "start_date": "2026-07-29", "end_date": "2026-08-03" }
      ] },
    { "date": "2026-08-31", "weekend": false, "holiday": "Summer Bank Holiday",
      "people": [] }
  ]
}
```

Returned **date-major** — the opposite of `/team/roster`, and deliberately: this
answers "can I let a second person go that week", which is a question about a
day rather than about a person.

**Every day of the month is present**, including weekends, holidays and days
nobody is off. The client draws a grid, and a grid with holes in it is a grid
the client has to reconstruct.

**`status` is `approved` or `pending`, and nothing else is returned.** Pending is
drawn alongside approved on purpose: a month showing only what is already
granted is a month a manager can approve a second person onto. Rejected and
cancelled requests are not cover anybody plans around, so they are absent.

**A stretch is expanded into every day it covers**, clipped to the month — but
`start_date` and `end_date` still name the real request, so a fortnight that
began in July reads correctly on 1 August.

`today` is the **company's** today, for marking the current cell. The handset is
in whatever zone its owner is standing in and does not get a vote — see the note
under `/attendance/history`.

**The manager's own leave is not on it**, and neither is anybody outside their
direct reports: the team is exactly what the other two team endpoints use.

Unlike `/team/attendance`, a **future month is not refused** — leave is booked
ahead, so next month is the most useful month this answers for.

A manager with nobody reporting to them gets `team_size: 0` and a full month of
empty days, not an error.

**Failures:** `forbidden` (403, no `approve-leave` permission) ·
`validation_failed` (422)

---

## 8. Schedule

### `GET /schedule`

| Query | Default |
|---|---|
| `from` | today |
| `to` | `from` + 13 days |

Maximum window: **92 days**. Oldest first — a schedule is read forwards.

```json
{
  "ok": true, "from": "2026-09-04", "to": "2026-09-08",
  "standing_shift": { "id": 1, "name": "Morning Shift", "start_time": "09:00:00", "end_time": "17:00:00" },
  "days": [
    { "date": "2026-09-04", "weekday": "Fri",
      "shift": { "id": 1, "name": "Morning Shift", "start_time": "09:00:00", "end_time": "17:00:00", "color": "#22c55e" },
      "is_day_off": false, "is_rostered": false, "is_working_day": true,
      "holiday": null, "leave": null },
    { "date": "2026-09-05", "weekday": "Sat", "shift": null,
      "is_day_off": false, "is_rostered": false, "is_working_day": false,
      "holiday": null, "leave": null }
  ]
}
```

- **Only published roster days are visible.** A roster still being planned falls
  back to the standing shift as though it did not exist — staff watching draft
  days move around is the problem publishing exists to prevent.
- `is_rostered` distinguishes a planned day from the standing shift filling in.
- `is_day_off` is a *planned* day with no hours, which is not the same as a day
  nobody planned.
- `shift` is `null` on weekends and holidays unless somebody was explicitly
  rostered on — the standing shift does not leak onto days the company does not
  work.
- `leave` names the type on days covered by **approved** leave only. A pending
  request is not time off yet.

---

## 9. Profile

### `GET /profile`

```json
{
  "ok": true,
  "account": { "id": 3, "name": "James Smith", "email": "…", "phone": null, "avatar": null, "roles": ["employee", "manager"] },
  "employee": { "id": 1, "employee_code": "EMP-0001", "full_name": "James Smith",
                "email": "…", "phone": null, "date_of_birth": null, "gender": "male",
                "hire_date": "2023-09-17", "status": "active", "work_mode": "office",
                "department": "Engineering", "designation": "Software Engineer",
                "office": "Head Office", "manager": null, "is_manager": true },
  "shift": { "id": 1, "name": "Morning Shift", "start_time": "09:00:00", "end_time": "17:00:00", "working_hours": "7h" },
  "company": { "id": 1, "name": "Acme", "timezone": "America/New_York", "currency": "EUR" }
}
```

`shift` here is the **standing** shift — "my usual hours". What applies on a
particular day comes from `/schedule` or `/attendance/today`.

### `PUT /profile`

Contact details only.

| Field | Type |
|---|---|
| `name` | string, required, ≤150 |
| `email` | string, required, unique |
| `phone` | string, optional, ≤30 |

Department, manager, shift, hire date and employee code are HR's to set. Anything
else posted here is ignored, not obeyed.

### `PUT /profile/details`

Where you live and who to call — the **employee record**, not the account
(B3.2). A separate route from `PUT /profile` because it is a separate table, and
an account with no employee row has nothing here to write.

| Field | Type |
|---|---|
| `personal_email` | email, optional, ≤150 |
| `address` | string, optional, ≤500 |
| `city` | string, optional, ≤100 |
| `country` | string, optional, ≤100 |
| `emergency_contact_name` | string, optional, ≤150 |
| `emergency_contact_phone` | string, optional, ≤30 |
| `emergency_contact_relation` | string, optional, ≤60 |

**Only the fields actually sent are written.** An omitted key is left alone, so
a client that knows about six of these cannot wipe the seventh by never having
heard of it. An **empty string clears** a field — "I no longer have an emergency
contact" has to be sayable. Values are trimmed, and a field holding only spaces
is stored as null rather than as an empty field wearing a disguise.

```json
{
  "ok": true, "message": "Profile updated.",
  "employee": {
    "personal_email": "ann@home.test",
    "address": "4 Mill Lane", "city": "Leeds", "country": "United Kingdom",
    "emergency_contact_name": "Sam Lee",
    "emergency_contact_phone": "555-0199",
    "emergency_contact_relation": "Brother"
  }
}
```

Date of birth, national id, blood group, hire date, department, manager, shift
and status are **not** here: they are HR's to set, and an app that let people
edit them would be a hole in the personnel record rather than a convenience.
Anything else posted here is ignored, not obeyed.

The **sign-in address is not reachable from here either**, and for a different
reason: changing it is account takeover in two steps — set it to your own, then
ask for a password reset — and an unlocked phone would be enough. `personal_email`
is a contact field and is read by nothing in authentication.

The same seven fields come back on `GET /profile` under `employee`, so a form
can be prefilled without a second call.

**Failures:** `no_employee_record` (403) · `validation_failed` (422)

### `PUT /profile/password`

| Field | Type |
|---|---|
| `current_password` | string, required |
| `password` | string, required, ≥8, confirmed |
| `password_confirmation` | string, required |

The current password is required **even though the caller holds a valid token** —
a phone left unlocked for a minute should not be enough to take the account over.

On success every **other** device is signed out; the one making the change stays
in. Warn the user before they submit.

```json
{ "ok": true, "message": "Password changed.", "other_devices_signed_out": 1 }
```

**Failures:** `wrong_password` (422) · `validation_failed` (422)

---

## 9b. Notifications

The history behind the pushes (B5.6). Everything in the `notifications` table
that was addressed to the caller, newest first — so a notification that arrived
while the phone was in a locker can still be read after the OS banner is gone.

**Not scoped to an employee record**, unlike almost everything else here. A
notification is addressed to a *user*: an HR account with no employee row still
receives document-expiry warnings, and hiding them would be a bug rather than a
boundary. Laravel's relation does the scoping, so there is nothing here anybody
can reach that was not sent to them.

### `GET /notifications`

25 per page.

```json
{
  "ok": true,
  "notifications": [
    {
      "id": "9b1f...-...",
      "type": "leave.approved",
      "title": "Your leave was approved",
      "body": "Your Annual Leave for 12 to 14 Sep 2026 has been approved.",
      "route": "leave",
      "read_at": null,
      "created_at": "2026-09-09T10:02:11-04:00"
    }
  ],
  "unread": 3,
  "meta": { "current_page": 1, "last_page": 2, "per_page": 25, "total": 34 }
}
```

`unread` counts **everything** unread, not what is on the page — it is what the
badge shows.

`created_at` and `read_at` are on the **company's clock**, offset included —
the same instant as UTC, with the digits to print. Read the date off the string
(as `Fmt.shortDate` does); parsing it into a UTC moment dates an evening
notification in the US as the next day.

`route` is the same vocabulary as a push payload's: `clock`, `leave`,
`schedule`, `approvals`, or **null**. Null is an ordinary answer — a
document-expiry warning is addressed to HR, who work at a desk, and the app has
no screen to point at. Both this and the push route come from one mapping on the
server (`App\Support\AppRoute`), because they used to be written out separately
and drifted: `schedule` was sent for months before the app had an enum row for
it, and every roster notification landed nowhere in particular.

Only the four keys every notification class agrees on are published — `type`,
`title`, `body` and the derived route. The stored payload also carries a **web**
`url` and per-class extras; neither is returned, so a new notification type
needs no client change to appear here.

#### `type: "announcement"` (B5.5)

An HR broadcast, and the one row here whose words are **not the system's**. Every
other `title` and `body` is a translated string rendered in the recipient's
language; this one is what a person typed, delivered exactly as typed. A machine
translation of "the Croydon depot closes at 2pm on Friday" is a liability rather
than a courtesy, and whoever wrote it knows who reads what.

Its `route` is **null**, and for a different reason from the HR-facing ones
above: the body *is* the message and this list already shows it in full, so
there is nowhere else to go. The push carries only the first 180 characters —
an oversized FCM data payload is a failed send for every recipient rather than
a long notification — so a client must read the body from here, never from the
push.

### `POST /notifications/{id}/read`

Marks one read. Answers `{ "ok": true, "unread": 2 }`.

**An id that is not there is not an error.** The app may be delivering a tap
made offline, by which time the row can be gone — "it is not unread any more"
is true either way, and a 404 would leave the screen showing a badge it cannot
clear.

Unlike the web screen, reading and navigating are separate here: on a phone the
list *is* the destination for most of these, because the body is the whole
message.

### `POST /notifications/read-all`

Marks every unread one read. Answers `{ "ok": true, "unread": 0 }`.

---

## 10. Documents

The caller's own shelf of the document vault (A3.8) — contracts, ID scans,
right-to-work papers, certificates. **Read-only.** Filing is HR's job and sits
behind `manage-employees`; there is no upload, edit or delete here.

Neither route takes an employee id. There is nothing to tamper with and nothing
to forget in a `where`: the scope is the token's own employee record.

### `GET /documents`

```json
{
  "ok": true,
  "documents": [
    { "id": 12, "type": "right_to_work", "type_label": "Right to Work / Visa",
      "title": "Work visa", "original_name": "visa-2026.pdf",
      "mime_type": "application/pdf", "size_bytes": 184320, "size_label": "180 KB",
      "issued_on": "2023-04-01", "expires_on": "2026-10-01", "expiry_state": "soon" }
  ],
  "expiring_soon": 1,
  "expired": 0
}
```

Ordered **soonest to expire first**, undated last — the list is read to find what
needs renewing. `expiring_soon` and `expired` are counted server-side so a tab
badge cannot disagree with the list it opens.

| `expiry_state` | Meaning |
|---|---|
| `none` | No expiry date. A contract, usually. |
| `valid` | Expires, but not within 30 days. |
| `soon` | Expires within 30 days. HR is being chased about it too. |
| `expired` | The date has passed. |

`notes` and the uploader are **not** returned. Notes is where HR records why a
document is being chased; the employee is its subject, not its audience.

### `GET /documents/{id}`

The file itself — **the one endpoint that does not answer with `ok`.** On success
the body is the document, with `Content-Disposition: attachment` and the name it
was uploaded under. Failures are JSON as everywhere else, so parse only when the
status is not 2xx.

Streamed through the API, never a public URL: a guessable link that hands out a
passport scan without a token is the one mistake in this feature that would
matter.

**Failures:** `not_found` (404, no such document **or** somebody else's — the two
are deliberately indistinguishable) · `file_missing` (404, the row outlived its
file, which means a database was restored without
`storage/app/employee-documents/`) · `no_employee_record` (403)

### Not here: payslips

B3.7 is written as "payslip / documents". There is no payslip, because there is
no payroll module — A7.14 exports hours for whatever runs payroll elsewhere. If
payslips are ever filed into the vault they arrive through this endpoint with no
change; nothing here needs to know they are special.

---

## 11. Directory

### `GET /directory`

Who else works here (B3.8) — **the only endpoint that answers about other
people**, and for that reason the one that carries the least.

| Query | Notes |
|---|---|
| `q` | Matches first name, last name or employee code |
| `department_id` | Narrows the same company-wide list |
| `office_id` | As above |
| `page` | 30 per page |

Active staff of the caller's own company, ordered by name. Leavers are not
listed: their record survives for the audit trail, not for finding somebody who
still works here.

```json
{
  "ok": true,
  "people": [
    { "id": 4, "employee_code": "E2", "full_name": "Bo Ray",
      "designation": "Cleaner", "department": "Ops", "office": "Head Office",
      "work_mode": "office", "photo_url": null }
  ],
  "meta": { "current_page": 1, "last_page": 1, "per_page": 30, "total": 1 },
  "shows_contact_details": false
}
```

**Contact details are a company policy, off by default.** With
`directory_show_contact_details` switched on at `/settings/policies`, each person
also carries `email` and `phone`:

```json
{ "…": "…", "email": "bo@acme.test", "phone": "+1 555 0134" }
```

It defaults off because there is a single phone column on an employee record,
and for a workforce with no desk lines it holds personal mobiles — turning that
on by default would publish every one of them to every colleague on an app
update, which is not a disclosure that can be withdrawn afterwards.

Read `shows_contact_details` rather than inferring from absent keys: the app has
to tell "this company does not share contact details" from "this person has none
on file", so it can hide a call button instead of showing a dead one.

**Never returned, at any policy setting:** date of birth, home address, national
id, blood group, personal email, emergency contact, hire date, employment
status, documents, attendance, leave — and the reporting line. Those are behind
`manage-employees`, and a *manager* does not see them for their own team; a
colleague cannot see more than a manager.

---

---

## 11b. HR (client requirement, 2026-09-22)

**Two permissions, and they are not the manager's.** Everything under `/hr` is
gated `manage-leave` or `manage-employees`, which is exactly what
`routes/web.php` puts on the company-wide register and the employee screens. A
line manager holds `approve-leave` and neither of these, so the permission that
keeps them out of the register on the web keeps them out of here — there is one
definition of "may act for the company" rather than two.

**Ask `/auth/me` before drawing anything.** Its `user.can` block says which of
these areas will answer:

```json
"can": { "lead_team": false, "decide_leave": true, "view_employees": true }
```

`decide_leave` is `manage-leave` **and** `approve-leave`; `view_employees` is
`manage-employees`. Derive neither locally — the app used to work `lead_team`
out from the permission list and it drifted from the route table.

### `GET /hr/leave/approvals`

Requests waiting on **HR**, soonest first. This is the second step of the chain:
a request still with its line manager is not here, and one from an employee who
reports to nobody skips that step and arrives directly.

Paginated (`per_page`, default 20).

```json
{
  "ok": true,
  "pending_count": 1,
  "pending": [{
    "id": 7,
    "employee": "Ann Lee",
    "employee_id": 3,
    "employee_code": "EMP-0003",
    "department": "Ops",
    "office": "Head Office",
    "leave_type": "Annual Leave",
    "start_date": "2026-11-02",
    "end_date": "2026-11-03",
    "days": 2,
    "is_half_day": false,
    "reason": "Family wedding",
    "status": "pending",
    "submitted_at": "2026-10-20T09:14:00+00:00",
    "has_attachment": false,
    "attachment_name": null,
    "manager_approved_by": "Mia Manager",
    "manager_approved_at": "2026-10-21T08:02:00+00:00",
    "manager_note": "Cover arranged.",
    "balance": {
      "entitled": 20, "used": 4, "available": 16,
      "capped": true, "would_exceed": false
    },
    "clashes": [{ "employee": "Sam Cole", "start_date": "2026-11-02", "end_date": "2026-11-04" }]
  }],
  "meta": { "current_page": 1, "last_page": 1, "per_page": 20, "total": 1 }
}
```

`manager_approved_by` and `manager_note` are **null when the employee has no
line manager** — that request skipped the manager step by design. Say so on
screen rather than leaving a blank, which reads as a request that slipped past
somebody.

`balance.capped` false means the type has no annual cap, and `available` is not
meaningful — show what was taken instead. `would_exceed` is the server making
the same comparison the approve call will make, so a refusal can be shown
*before* the tap rather than after it.

`clashes` is scoped to the employee's **department**, not the company.

### `GET /hr/leave/decided`

The same shape without `balance` and `clashes`, plus `decided_by` and
`decision_note`, newest first. So the phone is not a write-only surface.

### `POST /hr/leave/{id}/approve`

Grants it and **spends the days**. Optional `decision_note` (≤1000).

The balance is re-checked at the moment of granting, because days can be spent
between the request being raised and this call. A refusal comes back as:

```json
{ "ok": false, "error": "leave_decision_refused",
  "message": "This request is 2 day(s) but Ann has only 1 day(s) of Annual Leave left." }
```

`leave_decision_refused` (422) also covers a request that has already been
decided — two people with the app open, one request. The message is the
server's own words; show it rather than substituting your own, because an
over-spent balance and an already-decided request need different answers and
the client cannot tell them apart.

### `POST /hr/leave/{id}/reject`

**`decision_note` is required** (≤1000). The employee reads it.

### `GET /hr/leave/{id}/attachment`

The supporting file, for the person deciding company-wide. Streams the file, or
`not_found` when the row names one that is no longer on disk.

### `GET /hr/employees`

The employee register. **Not `/directory`** — that one answers "who else works
here" for every member of staff and deliberately withholds these fields. This is
behind `manage-employees`.

Query: `q` (name, staff number or email), `department_id`, `office_id`,
`status` (`active` default, or `inactive`, `terminated`, `all`), `page`,
`per_page` (default 20), plus the window below.

Leavers are **included on request**, unlike the directory: most of what HR is
asked about somebody after they go is about somebody who has gone.

Each row carries `attendance` for the window — present and late **days**, not
punches. It is computed for the page you asked for and no further, so paging is
what it costs. `period`, `from`, `to` and `today` work exactly as they do on
`GET /hr/employees/{id}/attendance` below; read the dates back rather than
building them.

```json
{
  "ok": true,
  "people": [{
    "id": 3, "employee_code": "EMP-0003", "name": "Ann Lee",
    "first_name": "Ann", "last_name": "Lee",
    "department": "Ops", "designation": "Technician", "office": "Head Office",
    "status": "active", "photo_url": null,
    "email": "ann@acme.test", "phone": "+44 7700 900001",
    "attendance": {
      "present_days": 18, "late_days": 2, "early_leave_days": 0,
      "worked_minutes": 8640, "break_minutes": 1080
    }
  }],
  "period": "daily", "from": "2026-07-14", "to": "2026-08-12", "today": "2026-08-12",
  "meta": { "current_page": 1, "last_page": 1, "per_page": 20, "total": 1 }
}
```

A row whose person has no punches in the window carries zeros, not `null`.

`worked_minutes` and `break_minutes` are what the badge recorded: breaks that
were actually punched come off, and nothing else does. They are **not** payroll
figures — payroll charges a shift's nominal break on a long day nobody punched
one for, and these do not. The numbers therefore match
`GET /hr/employees/{id}/attendance` for the same window exactly, which is the
point: that endpoint is one tap away from this list.

### `GET /hr/employees/{id}`

One record in full, plus three things the stored row does not hold: every active
leave type with what is left of each, the last 30 days of attendance **counted
rather than listed**, and whether the person can sign in at all.

```json
{
  "ok": true,
  "employee": {
    "id": 3, "name": "Ann Lee", "employee_code": "EMP-0003", "status": "active",
    "date_of_birth": "1990-04-02", "gender": "female", "hire_date": "2021-06-01",
    "work_mode": "office", "personal_email": null,
    "address": "14 Orchard Lane", "city": "Croydon", "country": "UK",
    "national_id": "NI-99-88-77", "blood_group": "O+",
    "emergency_contact": { "name": "Joan Lee", "phone": "+44 7700 900002", "relation": "Mother" },
    "manager": "Mia Manager", "manager_id": 2, "shift": "Day",
    "has_login": true, "login_email": "ann@acme.test", "login_active": true
  },
  "balances": [{
    "leave_type": "Annual Leave",
    "entitled": 20, "carried": 0, "used": 4, "available": 16, "capped": true
  }],
  "attendance": {
    "from": "2026-08-24", "to": "2026-09-22",
    "days_worked": 21, "late": 2, "early_leave": 0, "on_time": 19
  }
}
```

`emergency_contact` is **always an object**. A part nobody filled in is left
out, so a person with no contact on file is `{}` — never `null`, and never `[]`.

A leave type the employee has never touched still appears, at its full
entitlement: "no balance row" and "nothing taken" look identical on a phone and
only one of them is true.

`has_login` false is the answer to the question HR is asked most often about
somebody who says the app will not let them in. Accounts are created on the web.

**Read-only.** There is no PUT here, deliberately — editing a record one-handed
writes an audit trail nobody would check, and the fields most likely to be
mistyped are the ones least likely to be noticed wrong.

### `GET /hr/employees/{id}/leave`

That person's leave history, newest first, paginated. Its own call because a
long-serving employee has a long one, and a record opened to check a phone
number should not pay for it.

### `GET /hr/employees/{id}/attendance`

That person's attendance, one row per **day**, newest first. The counts on the
record answer "roughly how is this person doing"; this answers *what happened on
the 14th*.

**Ask for a `period`, not for dates.** The server resolves the window in the
company's timezone and tells you what it used. A phone is wherever its owner is,
so a month worked out on the handset is a different month for part of every day.

| Query | Default | Notes |
|---|---|---|
| `period` | `daily` | `daily` (30 days to today), `weekly` (this week to date), `monthly` (this month to date), `custom` |
| `from` | 29 days before `to` | `YYYY-MM-DD`. Read only when `period=custom`. |
| `to` | today | Same. Clamped to today — a day that has not happened cannot be an absence. |

Maximum window: **92 days**, the same ceiling as `/attendance/history`.

`today` is the company's date. Anchor a date picker on it rather than on the
device clock, or the picker offers a day the server then refuses.

```json
{
  "ok": true,
  "employee": { "id": 3, "employee_code": "EMP-0003", "name": "Ann Lee" },
  "period": "monthly", "from": "2026-08-01", "to": "2026-08-12", "today": "2026-08-12",
  "days": [
    { "date": "2026-08-03", "weekday": "Mon", "status": "present",
      "late": false, "early_leave": false,
      "first_in": "2026-08-03T09:00:00-04:00", "last_out": "2026-08-03T18:00:00-04:00",
      "break_start": "2026-08-03T13:00:00-04:00", "break_end": "2026-08-03T14:00:00-04:00",
      "break_count": 1, "break_minutes": 60,
      "worked_minutes": 480, "punches": 4,
      "holiday": null, "shift": "Morning Shift", "remarks": null }
  ],
  "totals": {
    "present_days": 1, "absent_days": 0, "leave_days": 0,
    "late_days": 0, "early_leave_days": 0,
    "worked_minutes": 480, "break_minutes": 60
  }
}
```

`status` is the same six values `GET /attendance/history` uses.

`break_start` and `break_end` are the day's **first** start and **last** end;
`break_minutes` is what was actually punched, so several breaks in a day sum and
one left open at check-out counts as nothing — its length is unknown, and
guessing it long would cut somebody's hours. A day never clocked out reports
`worked_minutes: 0` rather than a guess.

`break_count` is how many breaks were **started**, and it is the field that
makes the other three readable. On a day with one break the two timestamps are
that break. On a day with three they are the envelope around all of them, so
`break_start` 11:00 and `break_end` 13:45 alongside `break_minutes: 60` is
correct and looks wrong. Show the times only while `break_count` is 1; above
that show the count and the total, exactly as `punches` qualifies `first_in` and
`last_out`. A break started and never ended is counted here but contributes no
minutes, so the count can exceed what the total accounts for.

**Failures:** `invalid_range` (422) · `range_too_large` (422) · `forbidden` (403) · `validation_failed` (422)

An employee on another company's books is `forbidden` on every route above.
The permission is company-blind; the controller is not.

## 12. Push devices

Registration only. Nothing is delivered yet — notifications are Phase 5. The app
can register from its first release so it does not need an update when they land.

### `POST /devices`

Call on launch and again whenever the OS issues a new token. Safe to repeat: the
same token re-registers rather than duplicating.

| Field | Type | Notes |
|---|---|---|
| `token` | string, required, ≤255 | The FCM/APNs registration token. |
| `platform` | `android`\|`ios`\|`web`, required | |
| `device_name` | string, optional, ≤100 | |
| `app_version` | string, optional, ≤30 | |

A token that already exists under **another** account is moved to the caller. The
token belongs to the installation, not the person — a handed-on phone must stop
receiving the previous owner's approvals.

### `GET /devices`

Handsets registered to the caller. The push token itself is **never** returned:
it is a credential for sending to that handset.

### `DELETE /devices`

| Field | Type |
|---|---|
| `token` | string, required |

Removing an unknown token is not an error — `removed` is simply `0`. Scoped to
the caller, so a token cannot be used to silence somebody else's phone.

---

## 13. Client checklist

1. `GET /ping` before showing login, to distinguish "server down" from "wrong
   password".
2. Store the token in the keychain. Send it as `Authorization: Bearer <token>`.
3. On **any** `401`, discard the token and return to login — it has been revoked
   or the password changed.
4. Register for push after login; unregister on logout by sending `push_token`.
5. Render every timestamp in `user.company.timezone`, not the handset's.
6. Never compute leave day counts or punch direction locally. Ask the server.
7. Show `stage`, not `status`, on a pending leave request.
8. Respect `can_check` and treat `duplicate_scan` as success.
9. On `429`, honour `Retry-After` and back off rather than retrying immediately.
