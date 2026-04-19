# GuardIan Child — Background Monitoring App

![Flutter](https://img.shields.io/badge/Flutter-3.27-02569B?logo=flutter&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-3.4-0175C2?logo=dart&logoColor=white)
![Firebase](https://img.shields.io/badge/Firebase-Firestore%20%7C%20Auth%20%7C%20FCM-FFCA28?logo=firebase&logoColor=black)
![Android](https://img.shields.io/badge/Android-API%2026%2B-3DDC84?logo=android&logoColor=white)
![Version](https://img.shields.io/badge/Version-1.0.18-blue)
![CI](https://img.shields.io/github/actions/workflow/status/ibsam588-lgtm/guardian-child/ci.yml?label=CI&logo=githubactions&logoColor=white)
![License](https://img.shields.io/badge/License-Proprietary-red)

The **child-device half** of the GuardIan parental-control system. This app is installed on the child's Android device, runs silently as a foreground service, and streams activity to Firestore where the [`guardian-app`](https://github.com/ibsam588-lgtm/guardian-app) parent app reads it.

> Parents should install [`guardian-app`](https://github.com/ibsam588-lgtm/guardian-app) instead. This repo is specifically the child-side companion.

---

## Table of Contents

1. [What Guardian Child Is](#what-guardian-child-is)
2. [Key Features](#key-features)
3. [Architecture](#architecture)
4. [Native Services](#native-services)
5. [Tech Stack](#tech-stack)
6. [Required Permissions](#required-permissions)
7. [Firestore Schema (Child-Written Paths)](#firestore-schema-child-written-paths)
8. [Setup & Installation](#setup--installation)
9. [Pairing Flow](#pairing-flow)
10. [CI/CD](#cicd)

---

## What Guardian Child Is

Guardian Child is the companion Android app that runs on the child's device as part of the GuardIan parental-control system. Once paired to a parent account, the app runs silently in the background as an Android foreground service, continuously reporting device activity to Firebase Firestore. The parent's Guardian app reads this data in real time to monitor location, app usage, browser activity, and communications.

The app is designed to be tamper-resistant: it survives device reboots via a `BootReceiver`, is protected from uninstall by a `DeviceAdminReceiver`, and its core monitoring pipeline runs in native Kotlin services that remain active even when the Flutter engine is paused by the OS.

---

## Key Features

### Browser Activity Monitoring
A Kotlin `AccessibilityService` (`BrowserMonitorService`) intercepts `TYPE_WINDOW_CONTENT_CHANGED` and `TYPE_VIEW_TEXT_CHANGED` events across all major browsers (Chrome, Firefox, Edge, Samsung Internet, and the Google Search widget). It extracts URL bar text and page titles, deduplicates transient states (e.g., `Loading...`), and writes each visit as a discrete Firestore document under `children/{childId}/browser_history/`. Writes happen directly from Kotlin so data is captured even when the Flutter engine is suspended.

### App Usage Tracking and Enforcement
`UsageStatsManager` is polled on a 2-minute cycle to report per-app foreground usage to Firestore. The parent can set a daily time limit (in minutes) or hard-block any app. The child app evaluates enforcement every 15 seconds: if a blocked or over-limit app is in the foreground, `AppBlockedActivity` is launched as a full-screen overlay that suppresses the back button. The child can optionally submit a time-extension request from the block screen.

### SOS Button
The child's home screen features a prominent SOS button. Tapping it writes an `sos` alert doc to the top-level `alerts` collection (with current GPS coordinates), triggers an FCM push to the parent, and automatically initiates a phone call to the first emergency contact stored in `children/{childId}/emergencyContacts`. The SOS screen can also be triggered remotely by the parent via a `child_commands` Firestore document.

### Geofence Entry/Exit Reporting
The app subscribes to the parent-defined geofences in `children/{childId}/geo_fences/`. Every GPS update (fired on ≥50 m movement and on a 30-second heartbeat) is evaluated against active fences. On a state transition the app writes a `geofence_enter` or `geofence_exit` alert to Firestore, posts a local notification on the child device, and triggers an FCM push to the parent. A 60-second repeat timer fires `isRepeat: true` alerts while the child remains outside an active fence. Fences flagged as muted by the parent are silently skipped.

### Request System
The child can submit two types of requests to the parent from within the app:
- **Time request** — asks for additional minutes for a specific app that has hit its daily limit.
- **App install request** — asks the parent to approve installing a new app.

Requests are written to the top-level `timeRequests` collection with `status: "pending"`. The child can cancel a pending request, and resolved requests (approved or denied) can be dismissed from the requests screen.

### Mute Alerts
The parent app can flag individual geofences as muted. When a fence is muted, the child app skips writing entry/exit alerts for that fence, preventing notification noise without fully disabling the fence.

### Ambient Listen and Siren (Parent-Initiated)
The parent can remotely start an ambient-listen session. `ListenService` records 5-second AAC audio chunks (16 kHz / 24 kbps mono), base64-encodes them, and writes them to `children/{childId}/listen_chunks/`. A 15-minute absolute TTL acts as a battery safety cut-off. The parent can also trigger a maximum-volume looping siren via `SirenService` that cannot be silenced from the child device.

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
│  MonitorService (Dart)   │◄─────►  BrowserMonitorService│
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

**Why some things write to Firestore natively**: browser URL capture and ambient-listen audio chunks are written to Firestore **directly from Kotlin**, not through Dart. This is deliberate — if the Flutter engine is paused (e.g., the OS reclaims memory while the child uses another app) the Dart timers stop firing but native services keep running, so a pure Dart pipeline would drop data. A SharedPreferences-backed queue plus a Dart drain loop serves as a fallback for when native writes fail (offline, auth not yet ready, etc.).

---

## Native Services

| Service | Type | Purpose |
|---|---|---|
| `MonitorService.kt` | Foreground (`location`) | Keeps the process alive and holds the location permission while GPS reporting runs. On Android 14+, if the location permission is missing the service starts with a basic notification (no location type) instead of stopping itself — this prevents watchdog restart loops. |
| `ServiceWatchdogWorker.kt` | WorkManager | 15-minute periodic watchdog. Checks if `MonitorService` is running and restarts it if not. On Android 12+ catches `ForegroundServiceStartNotAllowedException` and falls back to `startService()` with `Result.retry()`. |
| `BrowserMonitorService.kt` | Accessibility | Listens to `TYPE_WINDOW_CONTENT_CHANGED` and `TYPE_VIEW_TEXT_CHANGED` events across browser packages. Extracts URL bar text and page titles and writes each visit directly to Firestore. Also runs a 30-second watchdog loop that independently checks whether `MonitorService` is running and restarts it if not. |
| `ListenService.kt` | Foreground (`microphone`) | Ambient listen. Records 5-second AAC chunks at 16 kHz / 24 kbps mono, base64-encodes them, and writes to `children/{id}/listen_chunks`. 15-minute absolute TTL as a battery safety cut-off. |
| `SirenService.kt` | Foreground (`mediaPlayback`) | Loops a loud alarm sound on `STREAM_ALARM`. `stopWithTask=false` so swiping the app from recents does not silence it. |
| `AppBlockedActivity.kt` | Activity | Full-screen block overlay shown when the child opens a blocked or over-limit app. Back button suppressed. Includes a time-request picker. |
| `BootReceiver.kt` | BroadcastReceiver | Restarts `MonitorService` on `BOOT_COMPLETED` so monitoring resumes after a device reboot. |
| `GuardianMessagingService.kt` | FCM | Receives push commands from the parent (siren, SOS trigger, listen start/stop). |

---

## Background Service Reliability

Three independent layers ensure monitoring survives app swipe, battery optimization, and Android OS restrictions:

### Layer 1 — WorkManager Watchdog (`ServiceWatchdogWorker.kt`)
A `PeriodicWorkRequest` fires every 15 minutes. It queries `ActivityManager.getRunningServices` and calls `startForegroundService()` if `MonitorService` is not found. On Android 12+ where `ForegroundServiceStartNotAllowedException` can be thrown from a background worker, the code catches the exception, falls back to `startService()`, and returns `Result.retry()` so WorkManager will attempt again at the next interval.

### Layer 2 — Accessibility Service Watchdog (`BrowserMonitorService.kt`)
The accessibility service is harder for the OS to kill than a foreground service. It runs a 30-second `Handler` loop that independently checks for `MonitorService` and restarts it if missing. This provides a much faster recovery time than WorkManager's 15-minute window.

### Layer 3 — Battery Optimization Exemption (`MainActivity.kt`)
On first launch, `MainActivity.onCreate()` checks whether the app is already exempted from battery optimization. If not, it fires `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` to prompt the user to allow unrestricted background activity. Without this exemption, the OS aggressively kills foreground services on many Android OEM variants (especially Samsung, Xiaomi, OnePlus).

### Android 14+ Fix
Prior to this fix, `MonitorService.onCreate()` called `stopSelf()` when the location permission was not yet granted, which caused every watchdog restart to immediately kill the service again. The fix starts the service with a basic (non-location-type) foreground notification when the permission is missing, keeping the process alive until the user grants the permission.

---

## Tech Stack

| Layer | Technology |
|---|---|
| UI & app logic | Flutter 3.27 / Dart 3.4 |
| State management | Provider |
| Navigation | go_router |
| Auth | Firebase Authentication |
| Database | Firebase Firestore (real-time sync) |
| Push messaging | Firebase Cloud Messaging (FCM) |
| Crash reporting | Firebase Crashlytics |
| Background services | Kotlin foreground services (Android API 26+) |
| Browser monitoring | Android AccessibilityService (Kotlin) |
| App enforcement | UsageStatsManager + AccessibilityService |
| Location | geolocator / geocoding |
| Build | Gradle + flutter build appbundle |
| CI/CD | GitHub Actions → Google Play internal track |

---

## Required Permissions

| Permission | Purpose | Grant Method |
|---|---|---|
| `ACCESS_FINE_LOCATION` | GPS tracking | Runtime prompt |
| `ACCESS_BACKGROUND_LOCATION` | Location reporting while backgrounded | Android 10+ requires "Allow all the time" in system settings |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_LOCATION` / `_MICROPHONE` / `_MEDIA_PLAYBACK` | Keep services alive | Android 14+ requires per-type declaration |
| `RECORD_AUDIO` | Ambient listen | Runtime prompt |
| `READ_CALL_LOG` | Call log monitoring | Runtime prompt |
| `READ_SMS` | SMS monitoring | Runtime prompt |
| `READ_CONTACTS` | Resolve emergency contact for auto-call on SOS | Runtime prompt |
| `PACKAGE_USAGE_STATS` | App usage tracking and enforcement | **Not a runtime permission** — must be granted in system Usage Access settings; the app deep-links there |
| `BIND_ACCESSIBILITY_SERVICE` | App blocking + browser URL capture | Must be enabled in system Accessibility settings; the app deep-links there |
| `SYSTEM_ALERT_WINDOW` | Launching `AppBlockedActivity` over other apps | System settings |
| `RECEIVE_BOOT_COMPLETED` | Restart after reboot | Normal permission |
| `BIND_DEVICE_ADMIN` | Uninstall protection | Enabled via Device Admin settings |
| `POST_NOTIFICATIONS` | Foreground service notifications on Android 13+ | Runtime prompt |
| `VIBRATE`, `WAKE_LOCK` | SOS haptic feedback and keeping services awake | Normal permissions |

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

children/{childId}/browser_history/{autoId}        — written natively
  url, pageTitle, browser, visitedAt

children/{childId}/listen_chunks/{autoId}          — written natively
  data: <base64 AAC>, mime: "audio/aac",
  durationMs, timestamp

children/{childId}/listen_status/current           — written natively
  state: "starting" | "recording" | "error" | "stopped"
  message?: string
  updatedAt

alerts/{autoId}
  parentUid, childId, type: "sos" | "geofence_enter" | "geofence_exit",
  title, message, fenceId?, fenceName?, lat?, lng?,
  isRepeat?: bool, timestamp

timeRequests/{autoId}
  parentUid, childId, childName,
  appName, packageName, requestedMinutes, childNote?,
  kind: "time" | "permission",
  status: "pending", createdAt, expiresAt
```

The child app **reads** `children/{childId}/geo_fences/*`, `children/{childId}/appLimits/*`, `children/{childId}/emergencyContacts/*`, and `child_commands` to receive instructions from the parent.

---

## Setup & Installation

### Prerequisites

| Requirement | Version |
|---|---|
| Flutter | 3.27+ (stable channel) |
| Dart | 3.4+ |
| Java | 17+ |
| Android SDK | API 26+ target |

### 1. Clone and install dependencies

```bash
git clone https://github.com/ibsam588-lgtm/guardian-child.git
cd guardian-child
flutter pub get
```

### 2. Firebase setup

This app and the parent [`guardian-app`](https://github.com/ibsam588-lgtm/guardian-app) must share the same Firebase project — that is how they see each other's Firestore writes.

1. Open the [Firebase Console](https://console.firebase.google.com/) and select the project used by the parent app (or create one).
2. Add an Android app with package name `com.guardian.child`.
3. Download `google-services.json` and place it at `android/app/google-services.json`.
4. Enable **Firestore**, **Authentication** (Email/Password or Anonymous), and **Cloud Messaging** in the Firebase Console.

### 3. Run on a device

```bash
flutter run
```

### 4. Release build

```bash
flutter build appbundle --release
# Output: build/app/outputs/bundle/release/app-release.aab
```

### 5. Permissions onboarding

On first launch the app walks the child (or the person setting up the device) through granting all required permissions. Special-access permissions that cannot be granted at runtime (Usage Access, Accessibility, Device Admin) open directly to the relevant system settings screen.

---

## Pairing Flow

1. A parent (on [`guardian-app`](https://github.com/ibsam588-lgtm/guardian-app)) taps **Add Child** and is shown a 6-digit code with a 15-minute TTL, written to `pairing_codes/{code}`.
2. The child opens this app and enters the code on the pairing screen.
3. The app looks up the code in Firestore, creates `children/{childId}` with `parentUid`, `deviceId`, `fcmToken`, etc., marks the pairing code `used: true`, and stores the `childId` in `SharedPreferences` under `flutter.paired_child_id`.
4. `MonitorService` starts and begins reporting.

The child app intentionally has no "unpair" option. To unpair, the parent removes the child from their account in the parent app. The child app detects the deletion of `children/{childId}` via a Firestore document listener and clears its local state automatically.

**Manual pairing (development):** You can also pair manually by writing a `children/{childId}` document in Firestore with the correct `parentUid` and setting `flutter.paired_child_id` to the same `childId` via Flutter DevTools or `adb shell`.

---

## CI/CD

GitHub Actions runs on every push to `main` and on pull requests targeting `main`. A concurrency guard cancels any in-flight run for the same ref to prevent concurrent Play Store edit conflicts.

```
push to main / PR
        │
        ├─► [test] Analyze & Test
        │       flutter analyze --no-fatal-infos --no-fatal-warnings
        │       flutter test
        │
        └─► [build-and-deploy] Build & Deploy Android  (needs: test, main branch only)
                flutter build appbundle --release \
                  --build-number=${{ github.run_number }}
                → uploads AAB artifact (7-day retention)
                → deploys to Play Store internal track via
                  r0adkll/upload-google-play@v1
```

### Required Repository Secrets

| Secret | Purpose |
|---|---|
| `KEYSTORE_BASE64` | Release keystore, base64-encoded |
| `KEY_ALIAS` | Key alias within the keystore |
| `KEY_PASSWORD` | Key password |
| `STORE_PASSWORD` | Keystore store password |
| `PLAY_STORE_SERVICE_ACCOUNT_JSON` | Google Play service account JSON for the `r0adkll/upload-google-play` action |

If `KEYSTORE_BASE64` is absent the build falls back to debug signing (useful for fork CI runs). The Play Store deploy step only runs on `main`.

---

_© 2024–2026 Corsair Labs. All rights reserved._
