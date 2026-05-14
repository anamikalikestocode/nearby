# Nearby -- Complete Handoff Document

**Last updated:** 2026-05-14
**Current version:** 1.2.0
**Developer:** Anamika Bhoyrul
**Team ID:** 98F3BWXPZ2

---

## Table of Contents

1. [What Nearby Is](#what-nearby-is)
2. [Architecture Overview](#architecture-overview)
3. [The Self-Texting Problem and Solution](#the-self-texting-problem-and-solution)
4. [Repository Structure](#repository-structure)
5. [Source Files Reference](#source-files-reference)
6. [Supabase Backend](#supabase-backend)
7. [Message Queue System](#message-queue-system)
8. [Sender Script (nearby-sender.sh)](#sender-script)
9. [Find My Data Pipeline](#find-my-data-pipeline)
10. [Cryptography Layer](#cryptography-layer)
11. [Proximity Detection Logic](#proximity-detection-logic)
12. [Friend-Pair Intro System](#friend-pair-intro-system)
13. [Onboarding Flow](#onboarding-flow)
14. [State Persistence](#state-persistence)
15. [Telemetry](#telemetry)
16. [Build Pipeline](#build-pipeline)
17. [Notarization and Distribution](#notarization-and-distribution)
18. [Messaging Provider Research (Why AppleScript)](#messaging-provider-research)
19. [Known Issues](#known-issues)
20. [Developer Environment Notes](#developer-environment-notes)
21. [Debugging Cheatsheet](#debugging-cheatsheet)
22. [Product Vision and Constraints](#product-vision-and-constraints)

---

## What Nearby Is

Nearby is a macOS menu bar app that alerts users via iMessage when their friends (from Apple's Find My) are physically nearby. It reads the encrypted Find My location cache on the user's Mac, computes distances using haversine, and sends iMessage alerts through a centralized Supabase message queue.

The app targets Mac users whose friends share their location via Find My. It runs as a menu bar agent (LSUIElement = true), checks proximity every 10 minutes using `NSBackgroundActivityScheduler`, and works even when the Mac lid is closed (sleep mode).

**Why it must be a Mac app:** The Find My location cache (`~/Library/com.apple.icloud.searchpartyd/`) only exists on macOS. There is no iOS API to access friends' Find My locations. This was explicitly researched and confirmed -- Nearby cannot be an iPhone app.

**Bundle ID:** `com.nearby.app`
**Minimum macOS:** 13.0
**Distribution URL:** bit.ly/get-nearby (points to GitHub releases)

---

## Architecture Overview

```
User's Mac (Nearby.app)                    Anamika's Mac
========================                   =============
                                          
 Find My Cache                             nearby-sender.sh
 ~/Library/com.apple.icloud.searchpartyd/   (polls every 30s)
       |                                          |
       v                                          |
 Crypto.swift (decrypt AES-GCM)                   |
       |                                          |
       v                                          |
 LocationCache.swift (parse lat/lon)              |
       |                                          |
       v                                          |
 ProximityChecker.swift (haversine)               |
       |                                          |
       v                                          v
 MessageQueue.swift ----INSERT----> [Supabase message_queue] ---SELECT--> AppleScript
  (anon key, INSERT only)            (RLS: anon=INSERT,       iMessage send
                                      service_role=ALL)
       |
       v
 Notifier.swift (local macOS notification as backup)
```

Each user's Mac runs Nearby.app, which reads the local Find My cache, decrypts it, checks distances, and INSERTs messages into a Supabase `message_queue` table using the anon key. Anamika's Mac runs `nearby-sender.sh`, which polls the queue every 30 seconds using the service role key, sends iMessages via AppleScript, and marks them as sent.

---

## The Self-Texting Problem and Solution

### The Problem

The original architecture had each user's Mac sending iMessages to the user's OWN phone number via AppleScript. This fundamentally does not work because iMessage to your own number does not generate iPhone notifications. Messages to yourself show up silently in the Messages app with no banner, no sound, no badge.

### The Solution

A centralized Supabase message queue:

1. User Macs INSERT into `message_queue` table (using the Supabase anon key, which only allows INSERT -- never SELECT, protecting phone numbers).
2. Anamika's Mac runs `nearby-sender.sh`, which polls every 30 seconds with the service role key.
3. The sender script sends iMessages FROM Anamika's iMessage account TO all users via AppleScript.
4. Because the message comes from a different Apple ID (Anamika's), the recipient's iPhone generates a normal notification.

### Why Not a Third-Party Provider?

Every messaging provider was exhaustively researched and rejected:

- **LoopMessage:** $19/mo for 300 msgs. Requires reply rate >30% or account gets flagged. Users will not reply to automated proximity alerts, so the account dies. Also uses a shared number.
- **Blooio:** Marketed as $29/mo but real cost ~$89/mo. Only 15 unique contacts/day on basic plan. "Business" tier at $89/mo for 50 contacts.
- **SendBlue:** $100/mo for meaningful volume. Most expensive option.
- **Toll-free SMS (Twilio):** $60-110/mo. Requires A2P 10DLC registration (business verification, use case approval). Takes weeks. Rejected.
- **Current solution (AppleScript):** $0. Risk: Apple may throttle at ~200-300 msgs/day (temporary throttle, not permanent ban). Apple ID is not banned, just rate-limited temporarily.

---

## Repository Structure

```
nearby/
├── HANDOFF.md                          <-- this file
├── README.md
├── LICENSE
├── .gitignore
├── Nearby.dmg                          <-- latest signed/notarized DMG (gitignored)
├── message_queue.sql                   <-- message_queue schema
├── supabase_setup.sql                  <-- telemetry tables schema
├── nearby-sender.sh                    <-- sender script (runs on Anamika's Mac ONLY)
├── sender.log                          <-- sender script log output (gitignored)
├── sender.pid                          <-- sender script PID (gitignored)
├── assets/
└── NearbyApp/
    ├── Package.swift                   <-- Swift Package Manager manifest
    ├── Nearby.entitlements             <-- only com.apple.security.network.client
    ├── Nearby.app/                     <-- pre-built app bundle shell
    │   └── Contents/
    │       ├── Info.plist              <-- bundle ID, version, LSUIElement
    │       ├── MacOS/                  <-- binary goes here after build
    │       ├── Resources/
    │       │   └── AppIcon.icns        <-- app icon (exists)
    │       ├── _CodeSignature/
    │       └── CodeResources
    └── Sources/
        ├── CCryptoShim/                <-- C bridge for CommonCrypto AES-GCM
        │   ├── include/
        │   │   └── ccrypto_shim.h
        │   └── ccrypto_shim.c
        └── NearbyApp/
            ├── main.swift              <-- AppDelegate, menu bar, scheduler
            ├── AppState.swift          <-- NearbyConfig, NearbyState, persistence
            ├── SetupView.swift         <-- full onboarding UI (SwiftUI)
            ├── ProximityChecker.swift   <-- distance checks, pair intros
            ├── LocationCache.swift      <-- Find My cache reading, friend discovery
            ├── Crypto.swift            <-- Keychain + AES-GCM decryption
            ├── MessageQueue.swift      <-- Supabase queue INSERT
            ├── Notifier.swift          <-- local macOS notifications, phone normalization
            └── Telemetry.swift         <-- anonymous usage tracking
```

---

## Source Files Reference

### main.swift
Entry point. Creates `NSApplication`, sets up `AppDelegate` with:
- Menu bar status item (`NSStatusItem`) with `location.fill` icon when active, `circle.dashed` + "Finish Setup" when not configured.
- `NSBackgroundActivityScheduler` for proximity checks every 10 minutes (interval=600, tolerance=120). Uses `.utility` QoS.
- Setup window management (floating, 420x680, transparent titlebar).
- `applicationShouldHandleReopen` shows setup window when Dock icon clicked.
- `refreshFindMyData()` silently launches/quits Find My app before each check to force `searchpartyd` to update GPS coordinates.

### AppState.swift
Data models and persistence:
- `NearbyConfig`: phoneNumber, radiusMeters (default 800), cooldownHours (default 4), quietStart (default 23), quietEnd (default 8), myDeviceId.
- `NearbyState`: friends array, lastAlerted dict, pairNotifications dict, friendFrequency dict.
- `PairState`: lastNotified + lastSeenNearby dates for friend-pair cooldowns.
- `FriendFrequency`: rolling 7-day sighting window, `isRegular` = 4+ days/week.
- `StoredFriend`: findMyId, name, email.
- `AppStateManager`: singleton, loads/saves JSON to `~/Library/Application Support/com.nearby/`.
- Log rotation at 500KB (keeps last half).

### SetupView.swift
Full onboarding flow as a single SwiftUI view with `AppStatus` enum states:
- `.checking` -- initial preflight
- `.needsMove` -- not in /Applications, prompts to move
- `.connectFindMy` -- needs Full Disk Access
- `.noICloud` -- searchpartyd dir missing
- `.fdaGrantedNoData` -- FDA granted but no friend data in Find My
- `.keychainPrompt` -- warns user about upcoming Keychain password prompt
- `.discovering` -- reading/decrypting Find My data
- `.discoveryFailed` -- error with actionable message
- `.noFriends` -- no friends sharing location
- `.setup` -- friend selection, phone number, radius slider
- `.done` -- closes window

Design system uses custom colors (DS enum), 420px wide window.
Radius slider: 1-25 minute walk, converted to meters via `radiusMinutes * 55.0 / 1.4`.
Phone validation: at least 10 digits.

### ProximityChecker.swift
Core proximity logic:
- `haversine()`: standard great-circle distance in meters.
- `isQuiet()`: weekdays 11pm-8am, weekends 2am-9am. No alerts during quiet hours.
- `inCooldown()`: default cooldown from config (4 hours). Regulars (4+ days/week) get 24-hour cooldown.
- `runCheck()`: reads user's iPhone GPS, decrypts all friend locations, checks distances, queues messages, sends local notifications.
- Walking distance formula: `distance * 1.4 / 55` (1.4x Manhattan grid factor, 55 m/min walking speed).
- Friend-pair intro system (see dedicated section below).

### LocationCache.swift
Reads Apple's Find My cache:
- Base dir: `~/Library/com.apple.icloud.searchpartyd/`
- Subdirs: `SecureLocationCache` (friend GPS), `BeaconEstimatedLocation` (own devices), `OwnedBeacons` (device registry), `SecureLocationSharedKeys` (friend identities).
- `checkFDAStatus()`: returns `.granted`, `.noFDA`, `.noFindMyDir`, or `.noFriendData`.
- `decryptFriendLocations()`: decrypts all .record files, deduplicates by findMyId (keeps newest), discards locations older than 30 minutes.
- `getMyLocation()`: reads user's iPhone GPS from `BeaconEstimatedLocation/<deviceId>/`. Discards if older than 3 hours (searchpartyd updates own device infrequently).
- `discoverFriends()`: reads `SecureLocationSharedKeys`, extracts name (from email local part) and contact info. Handles both `mailto:` and `tel:` contact types.
- `detectiPhone()`: reads `OwnedBeacons`, finds iPhone models, prefers device with most recent GPS data.
- `FriendInfo`: findMyId, name (derived from email), email.
- `FriendLocation`: findMyId, latitude, longitude.

### Crypto.swift
Encryption/decryption:
- `readBeaconKey()`: reads `BeaconStoreKey` from macOS Keychain (service: "BeaconStore", account: "BeaconStoreKey"). The key is stored as hex string, converted to raw bytes.
- `decryptRecord()`: reads .record plist files (array of 3 Data elements: nonce, tag, ciphertext). Decrypts and parses inner plist.
- `decryptAESGCM()`: dual-path decryption:
  - 12-byte nonces: uses Swift CryptoKit (`AES.GCM`)
  - 16-byte nonces (Apple's non-standard size): uses CommonCrypto via C shim (`CCryptoShim` target)
- `CryptoError` enum: keyNotFound, keychainFailed(OSStatus), decryptionFailed, invalidRecord.

### CCryptoShim (C target)
C bridge to expose `CCCryptorGCMOneshotDecrypt` (available macOS 13+) which supports arbitrary nonce sizes. The Swift CommonCrypto overlay does not expose this function directly.

- `ccrypto_shim.h`: declares `nearby_aes_gcm_decrypt()`.
- `ccrypto_shim.c`: implements it by calling `CCCryptorGCMOneshotDecrypt`.

### MessageQueue.swift
Supabase queue client:
- Supabase URL: `https://tsixhtjsmwqadwgrawbs.supabase.co`
- Uses anon key (hardcoded in source -- INSERT-only via RLS).
- `enqueue(to:message:)`: POSTs to `/rest/v1/message_queue` with recipient_phone, message, device_id, status="pending".
- Fire-and-forget: failures are logged but never block the app.
- Phone numbers are normalized to E.164 format before insertion.

### Notifier.swift
- `sendNotification()`: local macOS notification via `UNUserNotificationCenter` (backup in case iMessage fails).
- `requestPermission()`: requests notification authorization.
- `normalizePhone()`: converts phone input to E.164 (`+1XXXXXXXXXX`). Handles 10-digit (adds +1), 11-digit starting with 1 (adds +), and already-prefixed formats.
- `escapeForAppleScript()`: strips control characters, escapes backslashes and quotes.
- **Dead code present:** `sendIMessage()` and `checkAutomationPermission()` from the old direct-send architecture. These are unused but have not been deleted yet.

### Telemetry.swift
Anonymous usage tracking:
- Device ID: SHA256 hash of hardware UUID, truncated to 16 hex chars (32 bytes). Stable across restarts, cannot be reversed.
- Events tracked: `app_launch`, `setup_complete`, `check`, `alert_sent`, `intro_sent`, `onboarding_step`.
- Daily rollup: upserts to `nearby_daily_active` table with `resolution=merge-duplicates` (Supabase's `ON CONFLICT` via HTTP header).
- All network calls are fire-and-forget.
- Current app version: `1.2.0` (hardcoded in `Telemetry.appVersion`).

---

## Supabase Backend

**Project URL:** https://tsixhtjsmwqadwgrawbs.supabase.co
**Dashboard:** https://supabase.com/dashboard/project/tsixhtjsmwqadwgrawbs

This Supabase project is **shared with "The Drop"** (a separate iOS app for NYC free events). The two apps have completely separate tables. The Drop has its own tables; Nearby uses:

### Tables

#### `nearby_events`
Telemetry events. One row per event.

```sql
create table nearby_events (
  id bigint generated always as identity primary key,
  device_id text not null,
  event text not null,
  friend_count int,
  radius_meters int,
  alerts_sent int default 0,
  intros_sent int default 0,
  friends_nearby int default 0,
  app_version text,
  created_at timestamptz default now()
);
```

RLS: anon can INSERT only.

#### `nearby_daily_active`
Daily rollup for dashboards.

```sql
create table nearby_daily_active (
  id bigint generated always as identity primary key,
  device_id text not null,
  date date not null default current_date,
  checks int default 0,
  alerts int default 0,
  intros int default 0,
  unique(device_id, date)
);
```

RLS: anon can INSERT and UPDATE (needed for upsert). The `on_conflict=device_id,date` with `Prefer: resolution=merge-duplicates` header handles the upsert.

#### `message_queue`
Central message queue for iMessage delivery.

```sql
create table message_queue (
    id uuid default gen_random_uuid() primary key,
    recipient_phone text not null,
    message text not null,
    status text default 'pending' check (status in ('pending', 'sent', 'failed')),
    created_at timestamptz default now(),
    sent_at timestamptz,
    device_id text,
    error text
);

create index idx_message_queue_pending on message_queue (created_at asc) where status = 'pending';
```

RLS policies:
- `anon_insert`: anon can INSERT only (queue messages). Cannot SELECT -- protects phone numbers.
- `anon_no_select`: anon cannot read the table.
- `service_select` + `service_update`: service_role has full read/update access (for the sender script).

### Keys

- **Anon key:** Hardcoded in `MessageQueue.swift` and `Telemetry.swift`. This is safe because RLS restricts anon to INSERT-only.
- **Service role key:** ONLY in `nearby-sender.sh` via the `NEARBY_SUPABASE_SERVICE_KEY` environment variable. Never distributed to users. Never committed to git.

---

## Message Queue System

### How Messages Flow

1. User's Nearby.app detects a friend within radius.
2. `ProximityChecker.runCheck()` calls `MessageQueue.enqueue(to:message:)`.
3. `MessageQueue` POSTs to Supabase REST API: `POST /rest/v1/message_queue` with anon key.
4. Row inserted with `status='pending'`.
5. `nearby-sender.sh` on Anamika's Mac polls `GET /rest/v1/message_queue?status=eq.pending&order=created_at.asc&limit=10` every 30 seconds.
6. For each pending message, sends iMessage via AppleScript: `tell application "Messages" to send "..." to buddy "..." of (1st account whose service type = iMessage)`.
7. On success: PATCHes row to `status='sent'`, sets `sent_at`.
8. On failure: PATCHes row to `status='failed'`, sets `error` field.
9. 2-second delay between messages to avoid Apple throttling.

### Message Types

- **Welcome message:** Queued at setup completion. Text: `"welcome to nearby! you'll get texts here when friends are close [wave emoji]"`
- **Proximity alert:** Format: `"Friend Nearby! [Name] is ~[N] min walk away (as of [time])"`
- **Intro opportunity:** Format: `"Intro opportunity! [Name] and [Name] are ~[N] min walk apart (as of [time]). Intro them?"` or grouped: `"[Names] are all within ~[N] min walk (as of [time]). Group hangout?"`

---

## Sender Script

**File:** `/Users/anamika/Desktop/nearby/nearby-sender.sh`
**Runs on:** Anamika's Mac ONLY
**Never distribute this file.**

### Starting the Sender

```bash
cd /Users/anamika/Desktop/nearby
export NEARBY_SUPABASE_SERVICE_KEY="<service-role-key>"
nohup ./nearby-sender.sh >> sender.log 2>&1 &
echo $! > sender.pid
```

### Stopping the Sender

```bash
kill $(cat /Users/anamika/Desktop/nearby/sender.pid)
```

### How It Works

- Polls Supabase every 30 seconds for pending messages (oldest first, max 10 per cycle).
- Uses `python3` to parse JSON responses.
- Sends via AppleScript to the Messages app.
- Escapes messages for AppleScript (backslashes, then double quotes).
- 2-second delay between messages.
- Logs to stdout (redirected to `sender.log` via nohup).

### Current Status

The sender runs via `nohup`. There is no launchd plist, so it dies on reboot and must be manually restarted. The PID file at `sender.pid` tracks the process.

---

## Find My Data Pipeline

### Data Location

All Find My data lives at `~/Library/com.apple.icloud.searchpartyd/`:

```
searchpartyd/
├── SecureLocationCache/      <-- friend GPS coordinates (.record files)
├── SecureLocationSharedKeys/ <-- friend identities/contacts (.record files)
├── BeaconEstimatedLocation/  <-- own devices, organized by device ID
│   └── <deviceId>/           <-- .record files with lat/lon/timestamp
└── OwnedBeacons/             <-- device registry (model, identifier, pairing date)
```

### Record File Format

Each `.record` file is a binary plist containing an array of 3 `Data` elements:
1. **Nonce** (first 16 bytes used, but can be 12 or 16 bytes -- see Crypto section)
2. **Authentication tag** (AES-GCM tag)
3. **Ciphertext** (encrypted plist)

The decrypted inner plist contains fields like `secureLocation.findMyId`, `secureLocation.latitude`, `secureLocation.longitude`, `secureLocation.timestamp`, `ownerHandle.destination` (for friend identity), `model`, `identifier` (for devices).

### Data Freshness

- **Friend locations** (`SecureLocationCache`): updated by searchpartyd every 5-15 minutes when syncing with iCloud. Nearby discards locations older than **30 minutes** (`maxFriendLocationAge`).
- **Own iPhone GPS** (`BeaconEstimatedLocation`): searchpartyd updates this less frequently (can be 1-2 hours stale). Nearby discards if older than **3 hours** (`maxOwnLocationAge`).
- **Forcing refresh:** Before each proximity check, Nearby silently launches the Find My app (without activating it), waits 6 seconds for searchpartyd to fetch updated locations from iCloud, then quits Find My (only if it was not already running). This is done in `AppStateManager.refreshFindMyData()`.

### Friend Name Derivation

Friend names are derived from their Apple ID email:
1. Take the local part (before @).
2. Replace `.`, `_`, `-` with spaces.
3. Remove trailing digits.
4. Capitalize each word.
5. If the contact is a phone number (`tel:` prefix), the phone number is used as the name.

### iPhone Detection

`LocationCache.detectiPhone()` scans `OwnedBeacons` for devices with "iPhone" in the model string. When multiple iPhones exist (e.g., old and new), it prefers the one with the most recent GPS data in `BeaconEstimatedLocation`, falling back to most recent pairing date.

---

## Cryptography Layer

### BeaconStoreKey

- Stored in the macOS login Keychain.
- Service: `"BeaconStore"`, Account: `"BeaconStoreKey"`.
- Stored as a hex string in the Keychain; `Crypto.readBeaconKey()` converts it to raw bytes.
- Partition ID/ACL restrictions may cause a Keychain password prompt on first access. Users must click **"Always Allow"** to avoid repeated prompts.

### AES-GCM Decryption

Two code paths depending on nonce size:

1. **12-byte nonces (standard AES-GCM):** Uses Swift `CryptoKit` (`AES.GCM.open()`). Fast, native.
2. **16-byte nonces (Apple's non-standard):** CryptoKit only supports 12-byte nonces. Falls back to CommonCrypto's `CCCryptorGCMOneshotDecrypt` via the C shim target (`CCryptoShim`). This function supports arbitrary nonce sizes and is available on macOS 13+.

### CCryptoShim C Bridge

Because Swift's CommonCrypto overlay does not expose `CCCryptorGCMOneshotDecrypt`, a minimal C target bridges it:

```c
// ccrypto_shim.c
extern CCCryptorStatus CCCryptorGCMOneshotDecrypt(CCAlgorithm alg,
    const void *key, size_t keyLength,
    const void *iv, size_t ivLength,
    const void *aData, size_t aDataLength,
    const void *dataIn, size_t dataInLength,
    void *dataOut,
    const void *tag, size_t tagLength);

int nearby_aes_gcm_decrypt(...) {
    return (int)CCCryptorGCMOneshotDecrypt(kCCAlgorithmAES, ...);
}
```

---

## Proximity Detection Logic

### Check Cycle

1. `NSBackgroundActivityScheduler` fires every 10 minutes (interval=600, tolerance=120).
2. `AppStateManager.runCheck()` acquires a lock (prevents concurrent checks).
3. Silently launches Find My to force GPS refresh (skipped on first launch to avoid interfering with setup).
4. Reads BeaconStoreKey from Keychain.
5. Gets user's iPhone GPS from `BeaconEstimatedLocation/<deviceId>/`.
6. Decrypts all friend locations from `SecureLocationCache`.
7. For each tracked friend within radius:
   - Records sighting for frequency dampening (even during quiet hours).
   - Checks quiet hours (weekday 11pm-8am, weekend 2am-9am).
   - Checks cooldown (4 hours default, 24 hours for "regulars" seen 4+ days/week).
   - Computes walking distance: `dist * 1.4 / 55` minutes (1.4x Manhattan grid factor, 55 m/min).
   - Formats age string: "just now" if <5 min, otherwise "[N] min ago".
   - Queues message via `MessageQueue.enqueue()`.
   - Sends local macOS notification as backup via `Notifier.sendNotification()`.
   - Updates `lastAlerted` timestamp.
8. Runs friend-pair intro check (see next section).
9. Saves state and logs.

### Quiet Hours

- **Weekdays:** 11pm (23:00) to 8am (08:00)
- **Weekends (Sat/Sun):** 2am (02:00) to 9am (09:00)
- Configurable via `config.quietStart` and `config.quietEnd` (defaults: 23, 8).

### Frequency Dampening

- `FriendFrequency` tracks sightings in a rolling 7-day window.
- Friends seen 4+ distinct days per week are "regulars" (e.g., coworkers, roommates).
- Regulars get a 24-hour cooldown instead of the default 4-hour cooldown.
- This prevents notification fatigue for people you see every day.

### Walking Distance Formula

```
walking_minutes = max(1, distance_meters * 1.4 / 55)
```

- `1.4x` factor accounts for Manhattan grid (can't walk in a straight line, plus traffic lights).
- `55 m/min` is realistic NYC walking speed (~3.3 km/h).

---

## Friend-Pair Intro System

Beyond alerting you when YOUR friends are near YOU, Nearby also detects when TWO of your friends are near EACH OTHER and suggests introductions. This is the "intro opportunity" feature.

### Five Protections Against Alert Spam

The naive O(n^2) approach would send `n*(n-1)/2` messages for n friends at the same location. Instead:

1. **Group Clustering (Union-Find):** 10 friends at a wedding produce 1 grouped alert, not 45. Uses union-find to cluster all nearby friends into groups.
2. **Timestamp Delta:** Skips pairs whose GPS ages differ by more than 10 minutes. If Friend A's data is 1 min old and Friend B's is 28 min old, comparing them is meaningless.
3. **Cooldown State Machine:** 4-hour cooldown per pair (`pairCooldownSeconds`). Resets if the pair was not seen nearby for 30+ minutes (`pairGapThreshold`), treating the next sighting as a new encounter.
4. **Symmetry Guard:** Pair key is alphabetically sorted (`[idA, idB].sorted().joined("|")`), so A-B and B-A are the same pair.
5. **Per-Run Rate Cap:** Maximum 3 intro alerts per 10-minute check cycle (`maxAlertsPerRun`). Closest groups sent first; extras deferred.

### Pair Proximity Threshold

Friends are considered "near each other" if their walking distance is 5 minutes or less (vs. the user-configured radius for personal alerts).

### Alert Formats

- **Two friends:** `"Alice and Bob are ~3 min walk apart (as of just now). Intro them?"`
- **Three+ friends:** `"Alice, Bob, and Carol are all within ~3 min walk (as of 2 min ago). Group hangout?"`

---

## Onboarding Flow

The onboarding is designed to feel like "15 seconds" with zero jargon. The word "Full Disk Access" is never shown to the user.

### Step 1: Move to Applications

If the app is not running from `/Applications/Nearby.app`, it prompts the user to move it. Clicking "move & continue" copies the app bundle, clears quarantine attributes (`xattr -cr`), and relaunches from `/Applications/` via a shell command (`sleep 1 && open "/Applications/Nearby.app"`).

### Step 2: Full Disk Access (called "turn on Nearby")

- Opens System Settings to Privacy > Full Disk Access automatically.
- Shows: "we opened Settings for you -- find Nearby in the list and toggle it on."
- After 5 seconds, shows hint: "don't see Nearby? click the + button at the bottom..."
- Polls every 2 seconds (`startFDAPolling()`) to detect when FDA is granted.
- If user clicks "done" before FDA takes effect, app relaunches (macOS requires relaunch for FDA to take effect).

### Step 3: Keychain Warning

Before first decryption attempt, warns user: "your Mac will ask for your password to let nearby read Find My data. this is normal -- tap Always Allow so it doesn't ask again."

### Step 4: Friend Discovery

- Reads BeaconStoreKey from Keychain (retries 3 times with 0.5s delay).
- Discovers friends from `SecureLocationSharedKeys`.
- Detects user's iPhone from `OwnedBeacons`.
- 30-second timeout for discovery.

### Step 5: Setup Screen

- Shows discovered friends with checkboxes (all selected by default).
- Shows detected iPhone model (or "no iPhone found" warning).
- Phone number input field (requires 10+ digits).
- Alert radius slider: 1-25 minute walk.
- "start nearby" button (disabled until valid phone + at least 1 friend selected).
- On completion: saves config, requests notification permission, queues welcome iMessage, closes window.

### Error States

- `noICloud`: searchpartyd directory does not exist. Prompts to sign into iCloud.
- `fdaGrantedNoData`: FDA works but no friend location data. Prompts to open Find My and ensure friends are sharing.
- `discoveryFailed`: detailed error messages for Keychain denial, locked Keychain, missing key, etc.
- `noFriends`: no friends found sharing location.

---

## State Persistence

### Config File
**Path:** `~/Library/Application Support/com.nearby/config.json`

```json
{
  "phoneNumber": "+16467310389",
  "radiusMeters": 800,
  "cooldownHours": 4,
  "quietStart": 23,
  "quietEnd": 8,
  "myDeviceId": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
}
```

### State File
**Path:** `~/Library/Application Support/com.nearby/state.json`

Contains:
- `friends`: array of `{findMyId, name, email}`
- `lastAlerted`: dict of `findMyId -> ISO8601 date` (per-friend cooldowns)
- `pairNotifications`: dict of `"idA|idB" -> {lastNotified, lastSeenNearby}` (pair cooldowns)
- `friendFrequency`: dict of `findMyId -> {sightings: [dates]}` (frequency dampening)

### Log File
**Path:** `~/Library/Application Support/com.nearby/nearby.log`

Auto-rotates at 500KB (keeps the last half of the file).

### CRITICAL: State Persists Across Reinstalls

The state files are in `~/Library/Application Support/com.nearby/`, which is NOT inside the app bundle. Reinstalling or updating the app does not clear state. This means:
- Cooldowns carry over from old versions.
- If cooldowns seem wrong after an update, clear state.json.
- For a full reset: `rm -rf ~/Library/Application\ Support/com.nearby/`

---

## Telemetry

### Anonymous Device ID

Generated from the hardware UUID (IOPlatformUUID) via SHA256, truncated to the first 16 bytes (32 hex chars). Cannot be reversed. Stable across app restarts and reinstalls.

### Events Tracked

| Event | Fields | When |
|-------|--------|------|
| `app_launch` | -- | Every app start |
| `onboarding_step` | step ("moved_to_apps", "fda_granted") | During onboarding |
| `setup_complete` | friend_count, radius_meters | Setup finished |
| `check` | friend_count, friends_nearby, alerts_sent, intros_sent | Every proximity check |
| `alert_sent` | -- | Each individual alert |
| `intro_sent` | -- | Each intro opportunity |

### Daily Rollup

The `nearby_daily_active` table aggregates per device per day: total checks, alerts, and intros. Uses Supabase's HTTP-level upsert (`Prefer: resolution=merge-duplicates` header) with `on_conflict=device_id,date`.

### No PII Collected

- Device ID is a one-way hash.
- No names, emails, phone numbers, or GPS coordinates are sent to telemetry.
- All telemetry is fire-and-forget (failures are silently ignored).

---

## Build Pipeline

### Prerequisites

- Xcode Command Line Tools (for `swift build`, `codesign`)
- Developer ID Application certificate for "Anamika Bhoyrul (98F3BWXPZ2)" in Keychain
- `notary` keychain profile (stores App Store Connect credentials for notarization)

### Full Build Sequence

```bash
# 0. Kill any running instance (CRITICAL -- "item is in use" error otherwise)
pkill -9 -x Nearby; pkill -9 -x NearbyApp

# 1. Build universal binary (arm64 + x86_64)
cd /Users/anamika/Desktop/nearby/NearbyApp
swift build -c release --arch arm64 --arch x86_64

# 2. Copy binary into app bundle
cp .build/apple/Products/Release/NearbyApp Nearby.app/Contents/MacOS/NearbyApp

# 3. Codesign with Developer ID + entitlements + hardened runtime
codesign --deep --force --options runtime \
  --entitlements Nearby.entitlements \
  --sign "Developer ID Application: Anamika Bhoyrul (98F3BWXPZ2)" \
  Nearby.app

# 4. Clean old DMG artifacts
rm -f Nearby-temp.dmg Nearby.dmg
hdiutil detach /Volumes/Nearby -force 2>/dev/null

# 5. Create DMG
hdiutil create -size 50m -fs HFS+ -volname "Nearby" -type UDIF Nearby-temp.dmg
hdiutil attach Nearby-temp.dmg -readwrite
cp -R Nearby.app /Volumes/Nearby/
ln -s /Applications /Volumes/Nearby/Applications

# 6. Set DMG icon layout (drag-to-install UX)
osascript -e '
tell application "Finder"
  tell disk "Nearby"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {400, 100, 900, 400}
    set viewOptions to the icon view options of container window
    set icon size of viewOptions to 128
    set position of item "Nearby.app" of container window to {140, 150}
    set position of item "Applications" of container window to {400, 150}
    close
    open
  end tell
end tell'

# 7. Compress to read-only DMG
hdiutil detach /Volumes/Nearby -force
hdiutil convert Nearby-temp.dmg -format UDZO -o Nearby.dmg
rm -f Nearby-temp.dmg

# 8. Sign the DMG itself
codesign --force --sign "Developer ID Application: Anamika Bhoyrul (98F3BWXPZ2)" Nearby.dmg

# 9. Notarize (submits to Apple, waits for approval)
xcrun notarytool submit Nearby.dmg --keychain-profile "notary" --wait

# 10. Staple the notarization ticket to the DMG
xcrun stapler staple Nearby.dmg

# 11. Upload to GitHub releases
gh release upload v1.2.0 Nearby.dmg --clobber
```

### Key Notes

- **Always kill the old app first.** `pkill -9 -x Nearby; pkill -9 -x NearbyApp` MUST be run before copying the new binary, or you get an "item is in use" error.
- **Always clean old DMG artifacts.** `rm -f Nearby-temp.dmg Nearby.dmg` and `hdiutil detach /Volumes/Nearby -force` before creating a new DMG.
- The `--keychain-profile "notary"` stores App Store Connect credentials (set up once via `xcrun notarytool store-credentials`).
- The binary name in the build output is `NearbyApp` (Swift package name), but it is copied as `NearbyApp` into `Nearby.app/Contents/MacOS/`. The `Info.plist` `CFBundleExecutable` is set to `Nearby` -- note this discrepancy; the MacOS directory executable must match the plist.

---

## Notarization and Distribution

### Signing Identity

- **Certificate:** Developer ID Application: Anamika Bhoyrul (98F3BWXPZ2)
- **Entitlements:** Only `com.apple.security.network.client` (outbound network access for Supabase API calls).
- **Hardened runtime:** Enabled (`--options runtime`).
- The `com.apple.security.automation.apple-events` entitlement was REMOVED -- it was needed in the old architecture where user Macs sent iMessages directly. No longer needed with the queue system.

### Distribution

- GitHub releases: DMG uploaded via `gh release upload`.
- Short URL: `bit.ly/get-nearby` points to the GitHub releases page.
- DMG includes drag-to-Applications layout.

---

## Messaging Provider Research

All alternatives to the current AppleScript solution were exhaustively researched and rejected. This section exists to prevent future developers from re-researching the same options.

| Provider | Cost | Why Rejected |
|----------|------|--------------|
| LoopMessage | $19/mo (300 msgs) | Requires >30% reply rate or account flagged. Automated alerts get 0% reply rate. Account dies. Shared number. |
| Blooio | ~$89/mo real cost | Marketed as $29/mo. Only 15 unique contacts/day on basic. Business tier ($89/mo) for 50 contacts. |
| SendBlue | $100/mo | Most expensive. No advantages over alternatives. |
| Twilio (toll-free SMS) | $60-110/mo | Requires A2P 10DLC registration. Business verification + use case approval. Takes weeks. |
| **AppleScript (current)** | **$0** | Risk: Apple throttling at ~200-300 msgs/day (temporary, not permanent ban). Acceptable at current scale. |

---

## Known Issues

1. **State persistence across reinstalls:** `~/Library/Application Support/com.nearby/` is not cleared when the app is reinstalled. Stale cooldowns and frequency data carry over, causing confusing behavior.

2. **Keychain "Always Allow" prompt:** Users see a macOS Keychain password prompt on first access to BeaconStoreKey. If they click "Deny" or just "Allow" (not "Always Allow"), the prompt recurs. The onboarding warns about this but users still get confused.

3. **Dead code in Notifier.swift:** `sendIMessage()` and `checkAutomationPermission()` from the old direct-send architecture are still in the source. They are unused but should be removed.

4. **No launchd plist for sender script:** `nearby-sender.sh` runs via `nohup` on Anamika's Mac. It dies on reboot and must be manually restarted. Should be converted to a launchd agent.

5. **No monitoring/alerting for sender script:** If the sender script dies, no one is notified. Messages pile up in the queue as "pending" indefinitely.

6. **Apple throttling risk at scale:** At >200-300 messages/day, Apple may temporarily throttle iMessage sends from Anamika's account. This is a temporary rate limit, not a permanent ban, but could cause delayed delivery.

7. **SIP disabled on dev Mac:** System Integrity Protection is OFF on Anamika's Mac. This means TCC (Full Disk Access) protections are bypassed, so `LocationCache.canAccessFindMyData()` always returns true. The FDA onboarding screen cannot be tested on her Mac -- it always skips. Normal users with SIP on will see the FDA screen properly.

8. **Info.plist CFBundleExecutable mismatch:** The plist says `Nearby` but the actual binary copied into `Contents/MacOS/` is named `NearbyApp`. Verify this works correctly or rename during the copy step.

9. **No message_queue cleanup:** Old sent/failed messages accumulate in the `message_queue` table. The SQL file includes a comment about pg_cron for auto-cleanup after 7 days, but this is not implemented.

---

## Developer Environment Notes

### SIP (System Integrity Protection)

SIP is **disabled** on Anamika's Mac (done earlier in development). This has the following effects:

- TCC (Transparency, Consent, and Control) protections are bypassed.
- Full Disk Access is effectively always granted.
- `LocationCache.canAccessFindMyData()` always returns `true`.
- The FDA onboarding screen cannot be tested -- it always skips to friend discovery.
- To reset TCC permissions for testing: `tccutil reset All com.nearby.app`
- Normal users with SIP enabled WILL see the FDA onboarding screen.

### Testing the Sender Script

```bash
cd /Users/anamika/Desktop/nearby
export NEARBY_SUPABASE_SERVICE_KEY="<key>"
./nearby-sender.sh
```

Check `sender.log` for output. The log shows the last test sent a message successfully.

### Full State Reset

```bash
rm -rf ~/Library/Application\ Support/com.nearby/
```

This clears config, state, and logs. The app will show the onboarding flow on next launch.

---

## Debugging Cheatsheet

### App not sending alerts?

1. Check if the scheduler is running: look for "Check Now" in the menu bar dropdown.
2. Check the log: `cat ~/Library/Application\ Support/com.nearby/nearby.log | tail -50`
3. Check if Find My data is fresh: log entries show GPS age.
4. Check quiet hours: alerts are suppressed 11pm-8am weekdays, 2am-9am weekends.
5. Check cooldowns: 4-hour default, 24-hour for regulars. Clear state.json to reset.

### Messages queued but not delivered?

1. Check if sender script is running: `cat /Users/anamika/Desktop/nearby/sender.pid` then `ps -p <pid>`.
2. Check sender log: `tail -50 /Users/anamika/Desktop/nearby/sender.log`.
3. Check Supabase: query `message_queue` for `status='pending'` rows.
4. Check if Messages app is open on Anamika's Mac.

### Keychain errors?

- `errSecUserCanceled` / `errSecAuthFailed`: User denied Keychain access. Open Keychain Access, find "BeaconStore", right-click, Get Info, Access Control, add Nearby.
- `errSecInteractionNotAllowed`: Keychain is locked. Open Keychain Access and enter password.
- `keyNotFound`: BeaconStoreKey doesn't exist. User may not be signed into iCloud or Find My is not enabled.

### Friend discovery finds no friends?

1. Check if anyone is sharing location with the user in Find My.
2. Open Find My app to force a sync.
3. Check if `~/Library/com.apple.icloud.searchpartyd/SecureLocationSharedKeys/` has .record files.

### Build failures?

- "item is in use": Kill the running app first (`pkill -9 -x Nearby; pkill -9 -x NearbyApp`).
- Signing errors: Ensure the Developer ID certificate is in Keychain and not expired.
- Notarization fails: Check `xcrun notarytool log <submission-id> --keychain-profile "notary"` for details.

---

## Product Vision and Constraints

### What Anamika Wants

- A "viral consumer product" -- not a utility, not a tool.
- Onboarding should feel like "15 seconds."
- Zero jargon -- never say "Full Disk Access" or "Automation" to users.
- Deep research before presenting options. Do not suggest solutions that have already been rejected (Twilio, email, LoopMessage, etc.).

### Hard Constraints

- **Must be a Mac app.** The Find My cache (`~/Library/com.apple.icloud.searchpartyd/`) only exists on macOS. There is no iOS API to access friends' Find My locations. This was explicitly confirmed.
- **iMessage is the notification channel.** Not email, not push notifications, not SMS. iMessage is the only channel that feels personal and gets opened.
- **$0 messaging cost.** The AppleScript solution works at current scale. Only revisit if user count exceeds Apple's throttle threshold (~200-300 msgs/day).
- **SwiftUI only for the setup UI.** No UIKit, no Electron, no web views.
- **Supabase is the only backend.** Shared with The Drop. No Firebase, no custom servers.

### What "The Drop" Is

The Drop is a completely separate product that shares the same Supabase project. It is a native iOS app (SwiftUI) for New Yorkers in their 20s and 30s that sends location-aware push notifications about free things happening nearby (pop-ups, brand giveaways, free food, beauty samples, culture events). It has its own tables, its own codebase, and its own deployment. The only shared resource is the Supabase project.
