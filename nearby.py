#!/usr/bin/env python3
"""
nearby — get texted when a friend is within walking distance.

Decrypts Apple's Find My location cache on your Mac, checks who's close,
and sends you an iMessage. Runs silently every 2 minutes via launchd.

No app. No sign-up. No API keys. Just your Mac doing what it already knows.
"""

import plistlib
import os
import json
import math
import subprocess
import datetime
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

# ── Config (written by install.sh) ──────────────────────────────────────────
INSTALL_DIR = Path.home() / ".nearby"
CONFIG = json.loads((INSTALL_DIR / "config.json").read_text()) if (INSTALL_DIR / "config.json").exists() else {}
FRIENDS = json.loads((INSTALL_DIR / "friends.json").read_text()) if (INSTALL_DIR / "friends.json").exists() else {}

BEACON_KEY = bytes.fromhex(CONFIG.get("beacon_key", ""))
ALERT_RADIUS = CONFIG.get("radius_meters", 800)
COOLDOWN_HOURS = CONFIG.get("cooldown_hours", 4)
QUIET_START = CONFIG.get("quiet_start", 23)
QUIET_END = CONFIG.get("quiet_end", 8)
IMESSAGE_TO = CONFIG.get("imessage_to", "")
STATE_FILE = INSTALL_DIR / "state.json"


def haversine(lat1, lon1, lat2, lon2):
    """Distance in meters between two GPS coordinates."""
    R = 6371000
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def is_quiet():
    h = datetime.datetime.now().hour
    if QUIET_START > QUIET_END:
        return h >= QUIET_START or h < QUIET_END
    return QUIET_START <= h < QUIET_END


def notify(name, dist_m):
    """Send an iMessage and macOS notification."""
    mins = int(dist_m / 80)
    body = f"{name} is {mins} min walk away ({int(dist_m)}m)"

    if IMESSAGE_TO:
        applescript = (
            'tell application "Messages"\n'
            '  set targetService to 1st account whose service type = iMessage\n'
            f'  set targetBuddy to participant "{IMESSAGE_TO}" of targetService\n'
            f'  send "Friend Nearby! 👋\\n{body}" to targetBuddy\n'
            'end tell'
        )
        subprocess.run(["osascript", "-e", applescript], capture_output=True)

    subprocess.run(["osascript", "-e",
        f'display notification "{body}" with title "nearby 👋" sound name "Ping"'],
        capture_output=True)

    return body


def load_state():
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:
        return {}


def save_state(state):
    STATE_FILE.write_text(json.dumps(state, indent=2))


def in_cooldown(state, fmid):
    last = state.get(fmid)
    if not last:
        return False
    try:
        elapsed = (datetime.datetime.now() - datetime.datetime.fromisoformat(last)).total_seconds()
        return elapsed < COOLDOWN_HOURS * 3600
    except Exception:
        return False


def decrypt_locations():
    """Read and decrypt the Find My SecureLocationCache."""
    aes = AESGCM(BEACON_KEY)
    cache_dir = Path.home() / "Library/com.apple.icloud.searchpartyd/SecureLocationCache"
    if not cache_dir.exists():
        return {}

    locations = {}
    for record in cache_dir.glob("*.record"):
        try:
            with open(record, "rb") as f:
                data = plistlib.load(f)
            plaintext = aes.decrypt(data[0][:16], data[2] + data[1], None)
            loc = plistlib.loads(plaintext).get("secureLocation", {})
            fmid = loc.get("findMyId")
            if fmid and loc.get("latitude"):
                locations[fmid] = (loc["latitude"], loc["longitude"])
        except Exception:
            continue
    return locations


def get_my_location():
    """Get this Mac's location via IP geolocation."""
    import urllib.request
    try:
        resp = urllib.request.urlopen("http://ip-api.com/json/", timeout=5)
        d = json.loads(resp.read())
        return d["lat"], d["lon"]
    except Exception:
        return None, None


def main():
    if not BEACON_KEY or not FRIENDS:
        print("Run install.sh first.")
        return

    now = datetime.datetime.now()
    my_lat, my_lon = get_my_location()
    if not my_lat:
        return

    locations = decrypt_locations()
    if not locations:
        return

    quiet = is_quiet()
    state = load_state()

    for fmid, info in FRIENDS.items():
        if fmid not in locations:
            continue

        lat, lon = locations[fmid]
        dist = haversine(my_lat, my_lon, lat, lon)

        if dist >= ALERT_RADIUS:
            continue
        if quiet:
            continue
        if in_cooldown(state, fmid):
            continue

        msg = notify(info["name"], dist)
        print(f"[{now.strftime('%H:%M')}] 🔔 {msg}")
        state[fmid] = now.isoformat()

    save_state(state)


if __name__ == "__main__":
    main()
