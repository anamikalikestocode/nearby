# nearby

**Get texted when a friend is within walking distance.**

Apple doesn't let you build on Find My — no API, no SDK, nothing. `nearby` is a workaround. It reads Find My's encrypted cache on your Mac and texts you when a friend is close.

Native macOS app. No server. No sign-up. Your data never leaves your machine.

<p align="center">
  <img src="assets/imessage.png" width="360" alt="iMessage notification showing a friend is nearby" />
</p>

## Why

> living in manhattan and having your friends locations on find my iphone makes the city feel like a big adult playground — [@anamika__x](https://x.com/anamika__x/status/2050656199901606390)

I kept checking Find My like a psychopath. So I automated it.

## Install

**[Download nearby](https://github.com/anamikalikestocode/nearby/releases/latest/download/Nearby.zip)** (136 KB)

Unzip, drag to Applications, open. That's it.

<details>
<summary>Or build from source</summary>

```bash
cd NearbyApp && swift build -c release
```
</details>

## How it works

1. Apple's `searchpartyd` stores encrypted locations at `~/Library/com.apple.icloud.searchpartyd/`
2. This includes **your friends'** locations AND **your own iPhone's** GPS — all in the same cache
3. The encryption key (`BeaconStoreKey`) sits in your login Keychain
4. Each `.record` file is AES-256-GCM encrypted: `[nonce, tag, ciphertext]`
5. `nearby` decrypts them, computes distances via haversine, and texts you via iMessage
6. Runs as a background scheduler — silently, even with the lid closed

**Works even with your laptop closed.** Your Mac reads your iPhone's GPS from Find My, so it knows where *you* are even when you're walking around. Close your laptop, leave the house — it keeps checking in the background.

## What you get

A text whenever a friend is close:

```
[09:14] 📍 iPhone GPS: 40.7497, -73.9760
[09:14] 🔔 Taylor is 5 min walk away (400m)
[09:14] 📱 iMessage sent
[09:30] ⏳ Taylor is 380m away (cooldown active)
[11:42] 🔔 Rohan is 2 min walk away (150m)
[11:42] 📱 iMessage sent
[23:02] 💤 Rohan is 450m away but it's quiet hours
```

Click the menu bar icon → **Check Now** to run a manual check anytime.

## Config

Open the app → **Setup...** to change settings. Defaults:

| Setting | Default | Description |
|---|---|---|
| Alert radius | `800m` | ~10 min walk |
| Cooldown | `4 hours` | Don't re-alert about the same friend |
| Quiet hours | `11pm–8am` | No alerts while you're sleeping |

## Requirements

- macOS 13+ (Ventura)
- Signed into iCloud with Find My enabled
- At least one person sharing their location with you via Find My
- Full Disk Access (the app prompts you on first launch)

## How the encryption works

Apple's Find My uses the [offline finding network](https://support.apple.com/en-us/HT210515) to locate devices via BLE beacons relayed through nearby Apple devices. Your Mac caches these locations as binary plists encrypted with AES-256-GCM.

The decryption key is a 32-byte symmetric key stored in your login Keychain under service `BeaconStore`. Readable via the Security framework — no SIP changes, no root, no hacks.

Each `.record` file is a plist array: `[nonce (16 bytes), tag (16 bytes), ciphertext]`. The decrypted payload contains `latitude`, `longitude`, `timestamp`, and a `findMyId` identifying the device owner. Friend identities are resolved via `SecureLocationSharedKeys/` records.

## Privacy

- **Everything runs locally.** No server, no analytics, no telemetry.
- **You can only see people who already share their location with you** via Find My. This doesn't give you access to anyone new.
- **The encryption key is read from your Keychain at runtime.** It's never written to disk or stored in config files.

## Uninstall

Quit the app from the menu bar, then drag it out of Applications. Config is stored at `~/Library/Application Support/com.nearby/` — delete that folder to remove everything.

## License

MIT

---

Built by [@anamika__x](https://x.com/anamika__x) — because your phone should tell you when friends are close.
