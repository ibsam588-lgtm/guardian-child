# GuardIan Child — Background Monitoring App

![Flutter](https://img.shields.io/badge/Flutter-3.27-02569B?logo=flutter&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-3.4-0175C2?logo=dart&logoColor=white)
![Firebase](https://img.shields.io/badge/Firebase-Firestore%20%7C%20Auth%20%7C%20FCM-FFCA28?logo=firebase&logoColor=black)
![Android](https://img.shields.io/badge/Android-API%2026%2B-3DDC84?logo=android&logoColor=white)
![Version](https://img.shields.io/badge/Version-1.0.16-blue)
![CI](https://img.shields.io/github/actions/workflow/status/ibsam588-lgtm/guardian-child/ci.yml?label=CI&logo=githubactions&logoColor=white)
![License](https://img.shields.io/badge/License-Proprietary-red)

The **child-device half** of the GuardIan parental-control system. This app is installed on the child's Android device, runs silently as a foreground service, and streams activity to Firestore where the [`guardian-app`](https://github.com/ibsam588-lgtm/guardian-app) parent app reads it.

> Parents should install [`guardian-app`](https://github.com/ibsam588-lgtm/guardian-app) instead. This repo is specifically the child-side companion.

---

## Table of Contents

1. [What This App Does](#what-this-app-does)
2. [Recent Changes — v1.0.16](#recent-changes--v1016)
3. [Architecture](#architecture)
4. [Native Services](#native-services)
5. [Required Permissions](#required-permissions)
6. [Firestore Schema (Child-Written Paths)](#firestore-schema-child-written-paths)
7. [Setup & Installation](#setup--installation)
8. [Pairing Flow](#pairing-flow)
9. [CI/CD](#cicd)

---

## What This App Does

Once paired to a parent account via a 6-digit code, this app:

- Reports GPS location on significant movement (≥50 m) and on a 30-second heartbeat.
- Evaluates every location update against the parent-defined geofences and writes `geofence_enter` / `geofence_exit` alerts to Firestore on transition.
- Tracks foreground app usage via `UsageStatsManager` and enforces parent-set daily limits by launching a full-screen `AppBlockedActivity` that the child cannot dismiss with the back button.
- Captures browser URL bar contents across all major browsers through an `AccessibilityService`, writing them directly to Firestore from native Kotlin so sync survives the Flutter engine being paused or the app being killed from recents.
- On parent command, starts an ambient-listen session that records the microphone in 5-second AAC chunks and streams them to Firestore for the parent to play back.
- On parent command, plays a maximum-volume looping siren that cannot be silenced without the parent stopping it remotely.
- Sends an SOS alert with current location when the child taps the SOS button.
- Is protected from uninstall by a `DeviceAdminReceiver` — removing the app requires first revoking Device Admin in system settings.

---

## Recent Changes — v1.0.16

Follow-on fixes from live-Firestore-driven investigation.

| # | Area | Change |
|---|------|--------|
| Comms | SMS | Query Inbox, Sent, Outbox URIs explicitly and merge with dedup. `Telephony.Sms.CONTENT_URI` returns inbox-only on modern Samsung One UI unless the caller is the default SMS app — confirmed via live Firestore that only `type='received'` rows were being captured |
| Comms | Window | Call log + SMS queries widened from 24h to 7 days so the parent card (also 7-day) isn't empty on days the child had no recent activity |
| Comms | Call types | Added `VOICEMAIL_TYPE` and `BLOCKED_TYPE` to the call-type mapping so those don't fall through to `unknown` |
| Browser | Google Widget | `com.google.android.googlequicksearchbox` + Samsung Finder now have a dedicated fast-path that captures the typed query directly from the EditText and synthesizes a `google.com/search?q=` URL |
| Browser | Edge | Expanded Microsoft Edge URL-bar IDs (`omnibox_text`, `search_box_text`) |
| Browser | Firefox | Expanded Fenix IDs (`mozac_browser_toolbar_edit_url_view`, `awesome_bar_edit_text`, `toolbar_wrapper`) + URL-empty fallback writes a browser_history entry from pageTitle / titleQuery when URL extraction fails |

---

## Recent Changes — v1.0.15

Runtime bug-fix arc v1.0.7 through v1.0.15, investigated against live Firestore data.

| # | Area | Change |
|---|------|--------|
| AR | Geofence | Baseline now seeds `_lastOutsideAlertTs` and fires an initial "outside" alert for any active fence the child starts outside of. Also re-evaluates when a new fence appears in the Firestore subscription mid-session. Confirmed root cause: fences created while child was already outside never generated an enter→exit transition, so no alert ever fired |
| AJ | Geofence | Every-1-minute "still outside" reminder alerts via `_geofenceRepeatTimer` (30-second tick, 60-second floor per fence). `isRepeat: true` flag on the alert doc so the cloud function can branch the push copy |
| AH | Geofence | Child device now posts a local high-priority notification on every enter/exit/repeat transition via `MainActivity.showGeofenceLocalNotification`, in addition to the FCM push the parent gets via the cloud function |
| AL | Enforcement | `AppLimitInfo.fromMap` drops the legacy `(isEnabled && limit == 0)` derivation of `isBlocked`. Matches the parent-side enforcement policy |
| Usage sync | Enforcement | `_reportAppUsage` now stamps `dailyUsageMinutes` + `dailyUsageDate` + `lastUsageSync` back onto each `appLimits/{pkg}` doc. Without this, parent-side time-limit detection always saw 0 minutes used and never triggered over-limit blocks |
| AQ | Browser | `findPageTitle` walks the accessibility tree for a plausible page-title node, preferring `paneTitle` on Android O+. Written as an optional `pageTitle` field on each browser_history doc |
| AQ | Browser | `looksLikeUrl` now rejects Chrome's transient URL-bar placeholders (`Loading...`, `Connecting`, `Redirecting`, etc.) and requires at least one letter in the captured text. Confirmed via live Firestore that `url: "Loading..."` was a common garbage capture |
| X | Retention | Browser history and communications older than 7 days auto-pruned every 2 hours |
| AO | Requests | Child can now cancel a pending time request via a "Cancel Request" button that deletes the `timeRequests` doc |
| AC | App block | Modern themed unblock dialog in `AppBlockedActivity` with a `BadTokenException` guard and a time-picker spinner (hidden for pure unblock requests) |

---

## Recent Changes — v1.0.6 (bug-sweep)

| # | Area | Change |
|---|------|--------|
| 3B | Geofence | New child-side enforcement: every location update is checked against active zones, and enter/exit transitions fire `geofence_enter` / `geofence_exit` alerts. First-tick baseline prevents spurious alerts on app restart. |
| 5/6 | Listen Live | Fixed a method-channel mismatch between the Dart `CommandService` (calling `startListen` / `stopListen`) and `MainActivity` (which only registered `startRecording` / `stopRecording`). Parent's "Connecting…" state now progresses. Because `ListenService` is already a foreground service, fixing #5 also fixes #6 (mic previously only worked while the child app was foregrounded). |
| 7 | Permissions UX | Permission onboarding screen wrapped in `SafeArea` with an explicit `MediaQuery.viewPadding.bottom` inset so the Continue button is never clipped by the system gesture pill on tall-chin devices. |

---

## Architecture

```
┌──────────────────────────┐      ┌───────────────────────┐
│   Flutter UI (Dart)      │      │   Native Android      │
│                          │      │                       │
│  splash → permissions    │      │  MonitorService.kt    │
│        → pairing         │      │    (foreground loc)   │
│        → home / SOS      │      │                       │
│                          │      │  ListenService.kt     │
│  MonitorService (Dart)   │◄─────►  BrowserMonitor.kt    │
│    timers:               │  MC  │    (accessibility)    │
│      30s heartbeat       │      │                       │
│      2m usage/comms      │      │  AppBlockedActivity   │
│      2m browser drain    │      │  SirenService         │
│      15s enforcement     │      │  BootReceiver         │
│                          │      │                       │
│  CommandService (Dart)   │◄─────►  Firebase SDK (native)│
│    listens for remote    │      │    direct writes for  │
│    siren / listen / SOS  │      │    browser + listen   │
└────────────┬─────────────┘      └───────────┬───────────┘
             │                                │
             └──────────────┬─────────────────┘
                            ▼
              ┌──────────────────────────┐
              │  Firebase Firestore      │
              │  children/{childId}/...  │
              │  alerts, child_commands, │
              │  timeRequests            │
              └──────────────────────────┘
```

**MC** = MethodChannel (`com.guardian.child/monitor`).

**Why some things write to Firestore natively**: browser URL capture and ambient-listen audio chunks are written to Firestore **directly from Kotlin**, not through Dart. This is deliberate — if the Flutter engine is paused (e.g., the OS reclaims memory while the child uses another app) the Dart timers stop firing but native services keep running, so a pure Dart pipeline would drop data. The pref-backed queue + Dart drain remains as a fallback for when native writes fail (offline, auth not yet ready, etc.).

---

## Native Services

| Service | Type | Purpose |
|---|---|---|
| `MonitorService.kt` | Foreground (`location`) | Keeps the app alive and holds the location permission. |
| `ListenService.kt` | Foreground (`microphone`) | Ambient listen. Records 5-second AAC chunks at 16 kHz / 24 kbps mono, base64-encodes them, writes to `children/{id}/listen_chunks`. 15-minute absolute TTL as a battery safety. |
| `SirenService.kt` | Foreground (`mediaPlayback`) | Loops a loud alarm sound on `STREAM_ALARM`. `stopWithTask=false` so swiping the app from recents doesn't silence it. |
| `BrowserMonitorService.kt` | Accessibility | Listens to `TYPE_WINDOW_CONTENT_CHANGED` events in browser packages and extracts the URL bar text. Writes to `browser_history/recent` in Firestore and also to a SharedPreferences queue as a fallback. |
| `BootReceiver.kt` | BroadcastReceiver | Restarts `MonitorService` on `BOOT_COMPLETED` so monitoring resumes after the device reboots. |
| `GuardianMessagingService.kt` | FCM | Receives push commands from the parent (e.g., siren, SOS trigger). |
| `AppBlockedActivity.kt` | Activity | Full-screen block overlay shown when the child opens a blocked or over-limit app. Back button suppressed. |

---

## Required Permissions

| Permission | Purpose | Notes |
|---|---|---|
| `ACCESS_FINE_LOCATION` | GPS tracking | Runtime prompt |
| `ACCESS_BACKGROUND_LOCATION` | Location reporting while backgrounded | Android 10+ requires a separate "Allow all the time" selection in system settings |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_LOCATION` / `_MICROPHONE` / `_MEDIA_PLAYBACK` | Keep services alive | Android 14+ requires per-type declaration |
| `RECORD_AUDIO` | Ambient listen | Runtime prompt. The listen service refuses to start without it and writes an "error" state to `listen_status/current`. |
| `READ_CALL_LOG` | Call monitoring | Runtime prompt |
| `READ_SMS` | SMS monitoring | Runtime prompt |
| `PACKAGE_USAGE_STATS` | App usage | **Not a runtime permission** — must be granted in system Usage Access settings; the app deep-links there. |
| `BIND_ACCESSIBILITY_SERVICE` | App blocking + browser URL capture | Must be enabled in system Accessibility settings; the app deep-links there. |
| `SYSTEM_ALERT_WINDOW` | Launching `AppBlockedActivity` over other apps | |
| `RECEIVE_BOOT_COMPLETED` | Restart after reboot | |
| `BIND_DEVICE_ADMIN` | Uninstall protection | Enabled via Device Admin settings |
| `POST_NOTIFICATIONS` | Foreground service notifications on Android 13+ | Runtime prompt |
| `VIBRATE`, `WAKE_LOCK` | SOS feedback and keeping services awake | Normal permissions |

---

## Firestore Schema (Child-Written Paths)

The child app writes to:

```
children/{childId}
  lastLat, lastLng, lastLocation, lastSeen, isOnline, batteryLevel

children/{childId}/location_history/{autoId}
  lat, lng, address, timestamp

children/{childId}/app_usage/{yyyy-MM-dd}
  apps: { <packageName>: { minutesUsed, appName } }

children/{childId}/installed_apps/current
  apps: [{ appName, packageName, isSystem }], updatedAt

children/{childId}/browser_history/recent        — written natively
  entries: [{ url, browser, visitedAt }]         — capped at 100

children/{childId}/listen_chunks/{autoId}        — written natively
  data: <base64 AAC>, mime: "audio/aac",
  durationMs, timestamp

children/{childId}/listen_status/current         — written natively
  state: "starting" | "recording" | "error" | "stopped"
  message?: string
  updatedAt

alerts/{autoId}
  parentUid, childId, type: "sos" | "geofence_enter" | "geofence_exit",
  title, message, fenceId?, fenceName?, lat?, lng?, timestamp

timeRequests/{autoId}
  parentUid, childId, childName,
  appName, packageName, requestedMinutes, childNote?,
  kind: "time" | "permission",
  status: "pending", createdAt, expiresAt
```

The child app **reads** `children/{childId}/geo_fences/*`, `children/{childId}/appLimits/*`, and `child_commands` to receive instructions from the parent.

---

## Setup & Installation

### Prerequisites

| Requirement | Version |
|---|---|
| Flutter | 3.27+ (stable channel) |
| Dart | 3.4+ |
| Java | 17+ |
| Android SDK | API 26+ target |

### 1. Clone and install

```bash
git clone https://github.com/ibsam588-lgtm/guardian-child.git
cd guardian-child
flutter pub get
```

### 2. Firebase config

Place `google-services.json` (from the same Firebase project used by the parent app) in `android/app/google-services.json`. Both apps must share the same project — that's how they see each other's writes.

### 3. Run

```bash
flutter run
```

### 4. Release build

```bash
flutter build appbundle --release
# Output: build/app/outputs/bundle/release/app-release.aab
```

---

## Pairing Flow

1. A parent (on [`guardian-app`](https://github.com/ibsam588-lgtm/guardian-app)) taps **Add Child** and is shown a 6-digit code with a 15-minute TTL, written to `pairing_codes/{code}`.
2. The child opens this app and enters the code on the pairing screen.
3. The app creates `children/{childId}` with `parentUid`, `deviceId`, `fcmToken`, etc., marks the pairing code `used: true`, and stores the `childId` in `SharedPreferences` under `flutter.paired_child_id`.
4. `MonitorService` starts and begins reporting.

The child app intentionally has no "unpair" option. To unpair, the parent removes the child from their account; the child app detects the deletion of `children/{childId}` and clears its local state.

---

## CI/CD

GitHub Actions runs on every push to `main` and on PRs targeting `main`:

```
push / PR
    │
    ├─► [test] Analyze & Test
    │       flutter analyze --no-fatal-infos
    │       flutter test
    │
    └─► [build] Build Android  (needs: test)
            flutter build apk --release
```

### Required Secrets

Same Firebase / keystore secrets as the parent app. See [`guardian-app` README](https://github.com/ibsam588-lgtm/guardian-app#cicd-pipeline) for the full list.

---

_© 2024–2026 Corsair Labs. All rights reserved._
