# nearby

**Get texted when a friend is within walking distance.**

Your Mac already knows where your friends are — Apple's Find My silently caches the real-time location of everyone sharing with you. `nearby` decrypts that cache and texts you when someone's close.

No app to install. No account to create. No API keys. One terminal command.

## How it works

1. Apple's `searchpartyd` daemon keeps an encrypted cache of shared device locations on your Mac
2. The encryption key (`BeaconStoreKey`) sits in your login Keychain
3. `nearby` reads the key, decrypts the cache, and checks distances every 2 minutes
4. If a friend is within walking distance → you get an iMessage

**Your location data never leaves your Mac.** There's no server. The script runs locally via `launchd`.

## Install

```bash
curl -sL https://raw.githubusercontent.com/anabhoyrul/nearby/main/install.sh | bash
```

Takes ~30 seconds. You'll:
- See a Keychain popup → click **Allow**
- See your friends auto-discovered from Find My
- Enter your iMessage email/phone (to text yourself)
- Pick an alert radius (default: 800m ≈ 10 min walk)

That's it. It's running.

## Requirements

- macOS 14+ (Sonoma) — may work on earlier versions
- Signed into iCloud with Find My enabled
- At least one person sharing their location with you via Find My
- Python 3 (pre-installed on macOS)

## What you get

A text like this whenever a friend is nearby:

> **Friend Nearby! 👋**
> Emma is 6 min walk away (480m)

## Settings

Edit `~/.nearby/config.json`:

```json
{
  "radius_meters": 800,
  "cooldown_hours": 4,
  "quiet_start": 23,
  "quiet_end": 8
}
```

| Setting | Default | What it does |
|---|---|---|
| `radius_meters` | 800 | Alert when a friend is within this distance (~10 min walk) |
| `cooldown_hours` | 4 | Don't re-alert about the same friend for this long |
| `quiet_start` | 23 | No alerts after 11pm... |
| `quiet_end` | 8 | ...until 8am |

## Commands

```bash
# Run manually (see who's nearby right now)
python3 ~/.nearby/nearby.py

# Check logs
cat ~/.nearby/nearby.log

# Stop
launchctl unload ~/Library/LaunchAgents/com.nearby.bot.plist

# Start
launchctl load ~/Library/LaunchAgents/com.nearby.bot.plist

# Uninstall
~/.nearby/uninstall.sh
```

## How the encryption works

Apple's Find My uses the [offline finding network](https://support.apple.com/en-us/HT210515) to locate devices via BLE beacons relayed through nearby Apple devices. Your Mac stores these locations in `~/Library/com.apple.icloud.searchpartyd/SecureLocationCache/` as binary plists encrypted with AES-256-GCM.

The decryption key (`BeaconStoreKey`) is a 32-byte symmetric key stored in your login Keychain under the service name `BeaconStore`. It's readable with a single `security` command — no SIP changes, no root access, no hacks.

Each `.record` file is a plist array: `[nonce (16 bytes), tag (16 bytes), ciphertext]`. Standard AES-GCM authenticated decryption with no additional authenticated data.

The decrypted payload is a plist containing `secureLocation` with `latitude`, `longitude`, `timestamp`, `speed`, and `findMyId` (a base64-encoded Apple DSID identifying the device owner).

Friend identities come from `SecureLocationSharedKeys/` records, which map each `findMyId` to an `ownerHandle` containing the person's email address.

## Privacy

- **Everything runs locally.** No data is sent anywhere. No server, no analytics, no telemetry.
- **You can only see people who already share their location with you** via Find My. This doesn't give you access to anyone new.
- **The encryption key never leaves your machine.** It's read from your Keychain and stored in `~/.nearby/config.json` (readable only by you).

## Uninstall

```bash
~/.nearby/uninstall.sh
```

Removes everything: the daemon, config, logs, and the `~/.nearby` directory.

## License

MIT

## Author

Built by [Anamika](https://twitter.com/anaborhoyrul) — because your phone should tell you when friends are close.
